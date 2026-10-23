defmodule EvoGit.Agent.Tools.Lsp do
  @moduledoc """
  Lightweight Elixir code-intelligence tool — diagnostics, hover and
  go-to-definition obtained by speaking the Language Server Protocol to a
  language server **the user configures**.

  ## No bundled language server

  This tool never installs, downloads or vendors a language server, and it never
  leaves a daemon running. Each call:

    1. reads the `[lsp]` section of the user config,
    2. spawns the configured command on stdio, performs ONE LSP handshake
       (`initialize` → `initialized` → `textDocument/didOpen`), issues at most one
       analysis request, then
    3. tears the child down (`didClose` → `shutdown` → `exit` → SIGKILL) and
       closes the port — always, including on every timeout and error path.

  Nothing survives the call: no GenServer, no background process, no listening
  port, no orphaned OS process.

  Configuration (`config.toml`):

      [lsp]
      enabled = true                              # required — the tool is off by default
      command = "lexical"                         # required — e.g. "lexical", or the
      args = ["start"]                            #   absolute path of an elixir-ls launcher
      timeout = 30000                             # overall per-call budget (ms)
      diagnostics_timeout = 10000                 # settle window for publishDiagnostics (ms)

  When `enabled` is not true or `command` is empty the tool returns
  `Error: no language server configured — set [lsp] command in config.toml`.

  ## Actions

    * `diagnostics` — opens the file, collects `textDocument/publishDiagnostics`
      for it until the stream is quiet for a settle window (or the diagnostics
      budget elapses), and renders one
      `<path>:<line>:<col> <severity> <message>` line per diagnostic.
    * `hover` — `textDocument/hover` at a 1-based line/column, rendering the
      returned markup text.
    * `definition` — `textDocument/definition` at a 1-based line/column, rendering
      one `<path>:<line>:<col>` line per returned location.

  ## Wire protocol

  Frames are `Content-Length: <bytes>\\r\\n\\r\\n<json>` — the ASCII-header base
  protocol, never a `packet: 4` prefix. Framing/decoding/URI/result-shape helpers
  live in the pure sibling module `EvoGit.Agent.Tools.Lsp.Protocol`.

  ## Bounds (all enforced)

    * 2 MB per analysed file (rejected before `didOpen`),
    * 4 MB frame buffer (`Protocol.decode/1`),
    * 30 s overall per call, 10 s diagnostics settle window (both configurable),
    * 100 rendered lines / 8000 characters of returned text,
    * every `receive` is bounded — there is no `:infinity` wait anywhere.

  ## Test seam

  `execute/4` takes an `opts` keyword list that overrides the configured values:
  `:command`, `:args`, `:timeout`, `:diagnostics_timeout`, `:enabled`, and
  `:settle_ms` (the quiet window after a diagnostics batch, default #{500} ms).
  `execute/3` delegates with `[]`, so production reads only `config.toml`.

  ## Process hygiene (see `lib/evo_git/CONTEXT.md`, "Windows-Only Runtime Hazards")

  `Port.info(port, :os_pid)` returns `{:os_pid, pid}` (never a bare integer) and
  `Port.close/1` RAISES on an already-closed port — both are respected here: the
  pid is unwrapped, and the port is closed through the shared idempotent
  `EvoGit.Sandbox.Helpers.close_port/1`.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Lsp.Protocol
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Sandbox.Helpers, as: SandboxHelpers

  @actions ["diagnostics", "hover", "definition"]

  @default_timeout 30_000
  @default_diagnostics_timeout 10_000
  @default_settle_ms 500

  @max_file_bytes 2 * 1024 * 1024
  @max_output_chars 8_000
  @max_lines 100
  @max_stderr_bytes 2_048

  @not_configured "no language server configured — set [lsp] command in config.toml"

  # The LSP `initialize` request id, and the ids of the per-action requests. Fixed
  # values (not counters) because every call is a brand-new server process.
  @initialize_id 1
  @hover_id 2
  @definition_id 3
  @shutdown_id 4

  @doc """
  Returns the tool schema for ReqLLM. The model-facing name is `lsp`.
  """
  def schema do
    ReqLLM.tool(
      name: "lsp",
      description:
        "Ask an Elixir language server (configured by the user under [lsp] in config.toml) " <>
          "for code intelligence instead of guessing. " <>
          "action \"diagnostics\" returns the errors/warnings the server reports for one file, " <>
          "action \"hover\" returns the type/signature/docs at a 1-based line and column, and " <>
          "action \"definition\" returns the file locations a symbol is defined at. " <>
          "Line and column are required for \"hover\"/\"definition\" and 1-based. " <>
          "The path must be inside the repository. " <>
          "This tool requires a configured Elixir language server (for example " <>
          "command \"lexical\" with args [\"start\"], or an elixir-ls launcher); when none is " <>
          "configured it returns an Error explaining what to set — fall back to read_file/rg then.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" =>
              "Which LSP request to run: \"diagnostics\", \"hover\", or \"definition\"."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "The Elixir file to analyse — absolute or repo-relative. Must resolve inside the repository."
          },
          "line" => %{
            "type" => "integer",
            "description" =>
              "1-based line number. Required for \"hover\" and \"definition\"; ignored for \"diagnostics\"."
          },
          "column" => %{
            "type" => "integer",
            "description" =>
              "1-based column number. Required for \"hover\" and \"definition\"; ignored for \"diagnostics\"."
          }
        },
        "required" => ["action", "path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the `lsp` tool, reading its settings from the user config.

  Returns a plain `String.t()`; every failure is a single-sentence `Error: …`
  message (never a raise, never a crash).
  """
  def execute(args, repo_path, repo_root), do: execute(args, repo_path, repo_root, [])

  @doc """
  Executes the `lsp` tool with per-call overrides.

  `opts` overrides the config values (`:command`, `:args`, `:timeout`,
  `:diagnostics_timeout`, `:enabled`) and adds the `:settle_ms` quiet window — a
  documented test seam so specs can drive a fake language server without a
  user-level `config.toml`.
  """
  def execute(args, repo_path, repo_root, opts) do
    do_execute(args, repo_path, repo_root, opts)
  rescue
    # Tool-output boundary: an unexpected failure (a malformed arg type, an
    # unencodable file, a port that vanished mid-write) must reach the model as an
    # `Error:` string, never as a raise that kills the calling agent.
    error -> Failure.error("language server request failed: #{Exception.message(error)}")
  catch
    kind, reason ->
      Failure.error("language server request failed: #{inspect({kind, reason})}")
  end

  defp do_execute(args, repo_path, repo_root, opts) do
    with {:ok, settings} <- settings(opts),
         {:ok, action} <- fetch_action(args),
         {:ok, target} <- resolve_target(args, repo_path, repo_root),
         {:ok, position} <- fetch_position(args, action),
         {:ok, executable} <- resolve_executable(settings.command),
         {:ok, text} <- read_target(target) do
      case run(settings, executable, action, target, text, position, repo_root) do
        {:ok, output} -> output
        {:error, message} -> Failure.error(message)
      end
    else
      {:error, message} -> Failure.error(message)
    end
  end

  # ── Settings ──────────────────────────────────────────────────────────────

  defp settings(opts) do
    config = lsp_config()

    enabled = Keyword.get(opts, :enabled, Map.get(config, :enabled, false))
    command = Keyword.get(opts, :command) || Map.get(config, :command)
    args = Keyword.get(opts, :args) || Map.get(config, :args) || []
    timeout = positive_integer(Keyword.get(opts, :timeout), Map.get(config, :timeout))
    diagnostics_timeout = positive_integer(Keyword.get(opts, :diagnostics_timeout), nil)
    settle_ms = positive_integer(Keyword.get(opts, :settle_ms), nil)

    cond do
      enabled not in [true, "true"] ->
        {:error, @not_configured}

      not is_binary(command) or String.trim(command) == "" ->
        {:error, @not_configured}

      true ->
        {:ok,
         %{
           command: String.trim(command),
           args: normalize_args(args),
           timeout: timeout || @default_timeout,
           diagnostics_timeout:
             diagnostics_timeout || Map.get(config, :diagnostics_timeout) ||
               @default_diagnostics_timeout,
           settle_ms: settle_ms || @default_settle_ms
         }}
    end
  end

  defp lsp_config do
    case EvoGit.Config.resolve([:lsp]) do
      config when is_map(config) -> config
      _other -> %{}
    end
  end

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback) when is_integer(fallback) and fallback > 0, do: fallback
  defp positive_integer(_value, _fallback), do: nil

  # ── Arguments ─────────────────────────────────────────────────────────────

  defp fetch_action(args) do
    with {:ok, action} <- Shared.fetch_string_arg(args, "action") do
      if action in @actions do
        {:ok, action}
      else
        {:error, "argument 'action' must be one of #{Enum.join(@actions, ", ")}, got: #{action}"}
      end
    end
  end

  defp fetch_position(_args, "diagnostics"), do: {:ok, %{line: nil, column: nil}}

  defp fetch_position(args, _action) do
    with {:ok, line} <- fetch_position_number(args, "line"),
         {:ok, column} <- fetch_position_number(args, "column") do
      # LSP positions are 0-based; the model-facing contract is 1-based.
      {:ok, %{line: line, column: column, line0: line - 1, character0: column - 1}}
    end
  end

  defp fetch_position_number(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 1 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {int, ""} when int >= 1 -> {:ok, int}
          _other -> invalid_position(key, value)
        end

      value ->
        invalid_position(key, value)
    end
  end

  defp invalid_position(key, value) do
    {:error,
     "argument '#{key}' must be a 1-based integer for hover/definition, got: #{inspect(value)}"}
  end

  defp resolve_target(args, repo_path, repo_root) do
    with {:ok, raw} <- Shared.fetch_string_arg(args, "path") do
      expanded = Shared.expand_path(raw, repo_path)

      cond do
        not inside_repo?(expanded, repo_path, repo_root) ->
          {:error,
           "path #{raw} is outside the repository — the lsp tool only analyses files inside " <>
             "#{repo_path}"}

        true ->
          {:ok, %{path: expanded, display: display_path(expanded, repo_root, raw)}}
      end
    end
  end

  defp inside_repo?(path, repo_path, repo_root) do
    Enum.any?([repo_path, repo_root], fn root ->
      is_binary(root) and EvoGit.Platform.path_under?(path, EvoGit.Platform.safe_expand(root))
    end)
  end

  defp display_path(path, repo_root, fallback) do
    case Path.relative_to(path, repo_root) do
      relative when is_binary(relative) ->
        if EvoGit.Platform.absolute_path?(relative), do: fallback, else: relative
    end
  end

  defp resolve_executable(command) do
    # `EvoGit.Executable.resolve/1` layers the bundled-binary fallback under the
    # system PATH lookup; only git/rg are ever bundled, so for a user-configured
    # language server it is effectively a PATH lookup — but going through it keeps
    # the resolution strategy in ONE place.
    resolved = command |> EvoGit.Executable.resolve() |> System.find_executable()

    case resolved do
      nil -> {:error, "language server executable not found or not executable: #{command}"}
      path -> {:ok, path}
    end
  end

  defp read_target(target) do
    case File.stat(target.path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_file_bytes ->
        {:error,
         "file is too large to analyse (#{size} bytes, limit #{@max_file_bytes}): " <>
           target.display}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(target.path) do
          {:ok, text} ->
            if String.valid?(text) do
              {:ok, text}
            else
              {:error, "file is not valid UTF-8: #{target.display}"}
            end

          {:error, reason} ->
            {:error, "could not read #{target.display}: #{format_file_error(reason)}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "not a regular file (#{type}): #{target.display}"}

      {:error, reason} ->
        {:error, "could not open #{target.display}: #{format_file_error(reason)}"}
    end
  end

  defp format_file_error(reason), do: reason |> :file.format_error() |> to_string()

  # ── Session ───────────────────────────────────────────────────────────────

  defp run(settings, executable, action, target, text, position, repo_root) do
    session = %{
      port: nil,
      buffer: "",
      uri: Protocol.uri_for(target.path),
      stderr_path: nil,
      deadline: now_ms() + settings.timeout,
      timeout: settings.timeout
    }

    with {:ok, stderr_path} <- stderr_path(),
         {:ok, port} <- spawn_server(executable, settings.args, stderr_path) do
      session = %{session | port: port, stderr_path: stderr_path}

      try do
        with {:ok, session} <- initialize(session, repo_root),
             {:ok, session} <- open_document(session, text) do
          case action do
            "diagnostics" -> collect_diagnostics(session, target.display, settings)
            "hover" -> hover(session, target, position)
            "definition" -> definition(session, target, position)
          end
        end
      after
        teardown(session)
      end
    end
  end

  # ── Spawning ──────────────────────────────────────────────────────────────

  # A language server writes its human-readable logs to stderr. A raw Erlang port
  # cannot deliver stderr separately from stdout (`stderr_to_stdout` would interleave
  # log lines INTO the frame stream and corrupt it), so on POSIX systems the child is
  # started through a tiny `sh` trampoline that redirects stderr to a scratch file we
  # read for the error excerpt. `exec` replaces the shell, so the OS pid we later
  # SIGKILL is the server itself. Without a POSIX shell (e.g. Windows) the server is
  # spawned directly and error messages carry the exit status only.
  @stderr_script ~S(err="$1"; shift; exec "$@" 2>"$err")

  defp spawn_server(executable, args, stderr_path) do
    {program, argv} = server_command(executable, args, stderr_path)
    options = [:binary, :exit_status, :hide, {:args, argv}]

    try do
      {:ok, Port.open({:spawn_executable, program}, options)}
    rescue
      error ->
        {:error,
         "could not start the language server (#{executable}): #{Exception.message(error)}"}
    end
  end

  defp server_command(executable, args, stderr_path) do
    case posix_shell() do
      nil ->
        {executable, [executable | args]}

      sh ->
        # `$0` is the placeholder name, `$1` the stderr path, `$2..` the server argv —
        # nothing is interpolated into the script, so paths/args with spaces or quotes
        # are safe.
        {sh, ["-c", @stderr_script, "evogit-lsp", stderr_path, executable | args]}
    end
  end

  defp posix_shell do
    case :os.type() do
      {:unix, _} -> System.find_executable("sh")
      _other -> nil
    end
  end

  defp stderr_path do
    dir = scratch_dir()
    File.mkdir_p(dir)

    path =
      Path.join(
        dir,
        "evogit_lsp_#{System.unique_integer([:positive])}_#{:erlang.phash2(self())}.stderr"
      )

    case File.write(path, "") do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not create the language server log file: #{reason}"}
    end
  end

  # A managed per-task scratch dir when there is one (so the file lands inside the
  # task's own writable scope), otherwise the platform temp dir — never a
  # hardcoded "/tmp".
  defp scratch_dir do
    case EvoGit.TaskTmpdir.current() do
      path when is_binary(path) -> path
      _other -> System.tmp_dir!()
    end
  end

  # ── Handshake ─────────────────────────────────────────────────────────────

  defp initialize(session, repo_root) do
    root_uri = Protocol.uri_for(Path.expand(repo_root || "."))

    params = %{
      "processId" => beam_os_pid(),
      "clientInfo" => %{"name" => "evogit"},
      "rootUri" => root_uri,
      "workspaceFolders" => [%{"uri" => root_uri, "name" => "root"}],
      "capabilities" => %{}
    }

    case request(session, @initialize_id, "initialize", params) do
      {:ok, _result, session} ->
        case send_frame(session, Protocol.notification("initialized", %{})) do
          :ok -> {:ok, session}
          {:error, :closed} -> {:error, exit_error(session)}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp open_document(session, text) do
    params = %{
      "textDocument" => %{
        "uri" => session.uri,
        "languageId" => "elixir",
        "version" => 1,
        "text" => text
      }
    }

    case send_frame(session, Protocol.notification("textDocument/didOpen", params)) do
      :ok -> {:ok, session}
      {:error, :closed} -> {:error, exit_error(session)}
    end
  end

  defp beam_os_pid do
    case Integer.parse(System.pid()) do
      {pid, _rest} -> pid
      :error -> nil
    end
  end

  # ── Actions ───────────────────────────────────────────────────────────────

  defp collect_diagnostics(session, display_path, settings) do
    deadline = min(session.deadline, now_ms() + settings.diagnostics_timeout)

    collect(
      %{session | buffer: session.buffer},
      display_path,
      deadline,
      settings.settle_ms,
      [],
      false
    )
  end

  # `received?` flips as soon as a batch for THIS file arrives (even an empty one —
  # a clean file is published as `diagnostics: []`), after which only a short quiet
  # window is waited for, so a clean file never burns the whole diagnostics budget.
  defp collect(session, display_path, deadline, settle_ms, lines, received?) do
    wait = if received?, do: min(remaining(deadline), settle_ms), else: remaining(deadline)

    case next_message(session, now_ms() + wait) do
      {:ok, %{"method" => "textDocument/publishDiagnostics", "params" => params}, buffer} ->
        session = %{session | buffer: buffer}

        if same_document?(params, session.uri) do
          lines = lines ++ Protocol.diagnostics_lines(params, display_path)
          collect(session, display_path, deadline, settle_ms, lines, true)
        else
          collect(session, display_path, deadline, settle_ms, lines, received?)
        end

      {:ok, _other, buffer} ->
        collect(%{session | buffer: buffer}, display_path, deadline, settle_ms, lines, received?)

      {:timeout, _buffer} ->
        {:ok, render_diagnostics(lines, display_path)}

      {:exit, status} ->
        {:error, exit_error(session, status)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp same_document?(params, uri) when is_map(params) do
    case Map.get(params, "uri") do
      nil -> true
      other -> other == uri or Protocol.path_from_uri(other) == Protocol.path_from_uri(uri)
    end
  end

  defp same_document?(_params, _uri), do: true

  # Renders the collected diagnostics, capped at `@max_lines` / `@max_output_chars`.
  defp render_diagnostics(lines, display_path) when is_list(lines) and is_binary(display_path) do
    case lines do
      [] ->
        "No diagnostics for #{display_path}."

      lines ->
        body =
          lines
          |> Enum.take(@max_lines)
          |> Enum.join("\n")
          |> truncate_output()

        suffix =
          if length(lines) > @max_lines,
            do: "\n...[truncated at #{@max_lines} diagnostics]",
            else: ""

        "#{display_path} — #{length(lines)} diagnostic(s):\n#{body}#{suffix}"
    end
  end

  defp hover(session, target, position) do
    params = %{
      "textDocument" => %{"uri" => session.uri},
      "position" => %{"line" => position.line0, "character" => position.character0}
    }

    case request(session, @hover_id, "textDocument/hover", params) do
      {:ok, result, _session} ->
        case Protocol.hover_text(result) do
          "" ->
            {:ok, "No hover information at #{location_label(target, position)}."}

          text ->
            {:ok, truncate_output("Hover at #{location_label(target, position)}\n\n#{text}")}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp definition(session, target, position) do
    params = %{
      "textDocument" => %{"uri" => session.uri},
      "position" => %{"line" => position.line0, "character" => position.character0}
    }

    case request(session, @definition_id, "textDocument/definition", params) do
      {:ok, result, _session} ->
        case Protocol.locations(result) do
          [] ->
            {:ok, "No definition found at #{location_label(target, position)}."}

          locations ->
            lines = Enum.map(locations, &location_line/1)

            {:ok, truncate_output(Enum.join(Enum.take(lines, @max_lines), "\n"))}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp location_label(target, position),
    do: "#{target.display}:#{position.line}:#{position.column}"

  defp location_line(%{path: path, line: line, column: column}),
    do: "#{path}:#{line}:#{column}"

  # ── Requests / reads ──────────────────────────────────────────────────────

  defp request(session, id, method, params) do
    case send_frame(session, Protocol.request(id, method, params)) do
      :ok ->
        case await_response(session, id, method) do
          {:ok, %{"error" => error}, _buffer} ->
            {:error, "#{method} failed: #{describe_error(error)}"}

          {:ok, %{"result" => result}, buffer} ->
            {:ok, result, %{session | buffer: buffer}}

          {:ok, _other, buffer} ->
            {:ok, nil, %{session | buffer: buffer}}

          {:timeout, _buffer} ->
            {:error,
             "the language server did not answer #{method} within " <>
               "#{session.timeout} ms" <> stderr_suffix(session)}

          {:exit, status} ->
            {:error, exit_error(session, status)}

          {:error, message} ->
            {:error, message}
        end

      {:error, :closed} ->
        {:error, exit_error(session)}
    end
  end

  defp await_response(session, id, method) do
    case next_message(session, session.deadline) do
      {:ok, %{"id" => ^id} = message, buffer} -> {:ok, message, buffer}
      {:ok, _other, buffer} -> await_response(%{session | buffer: buffer}, id, method)
      {:timeout, buffer} -> {:timeout, buffer}
      {:exit, status} -> {:exit, status}
      {:error, message} -> {:error, message}
    end
  end

  # Reads the next JSON-RPC message, honouring `deadline` (absolute monotonic ms) on
  # every wait — no `:infinity` receive anywhere.
  defp next_message(session, deadline) do
    case Protocol.decode(session.buffer) do
      {:ok, message, rest} ->
        {:ok, message, rest}

      {:error, message} ->
        {:error, message <> stderr_suffix(session)}

      :more ->
        case remaining(deadline) do
          0 ->
            {:timeout, session.buffer}

          wait ->
            receive do
              {port, {:data, data}} when port == session.port ->
                next_message(%{session | buffer: session.buffer <> data}, deadline)

              {port, {:exit_status, status}} when port == session.port ->
                {:exit, status}

              {port, _other} when port == session.port ->
                next_message(session, deadline)
            after
              wait -> {:timeout, session.buffer}
            end
        end
    end
  end

  defp send_frame(session, data) do
    try do
      Port.command(session.port, data)
      :ok
    rescue
      # `Port.command/2` raises ArgumentError once the port is closed (server gone).
      ArgumentError -> {:error, :closed}
    end
  end

  # ── Teardown (always runs) ────────────────────────────────────────────────

  defp teardown(session) do
    # Best-effort LSP handshake so a well-behaved server releases its index before
    # the kill; every send is tolerated (the child may already be gone).
    _ =
      send_frame(
        session,
        Protocol.notification("textDocument/didClose", did_close_params(session))
      )

    _ = send_frame(session, Protocol.request(@shutdown_id, "shutdown", %{}))
    _ = send_frame(session, Protocol.notification("exit", %{}))

    kill_server(session.port)
    SandboxHelpers.drain_port_messages(session.port)
    SandboxHelpers.close_port(session.port)
    remove_stderr(session.stderr_path)
    :ok
  end

  defp did_close_params(session), do: %{"textDocument" => %{"uri" => session.uri}}

  # SIGKILL by OS pid — the ONLY reliable way to guarantee no language server
  # survives the call (a server ignoring `exit` would otherwise linger forever).
  defp kill_server(nil), do: :ok

  defp kill_server(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> kill_os_pid(os_pid)
      _already_gone -> :ok
    end
  end

  defp kill_os_pid(os_pid) do
    case :os.type() do
      {:unix, _} ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _other ->
        # Windows has no SIGKILL from the BEAM; taskkill /T /F walks the process tree
        # (`Sandbox.None` uses the same invocation for its tree kills).
        System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"],
          stderr_to_stdout: true
        )

        :ok
    end
  rescue
    # The kill binary is missing, or the pid vanished between Port.info and the
    # call — either way there is nothing left to do.
    _error -> :ok
  end

  defp remove_stderr(nil), do: :ok

  defp remove_stderr(path) when is_binary(path) do
    File.rm(path)
    :ok
  end

  defp stderr_excerpt(session) do
    case session.stderr_path do
      nil ->
        ""

      path ->
        case File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_stderr_bytes) end) do
          {:ok, data} when is_binary(data) -> data |> String.trim() |> collapse()
          _other -> ""
        end
    end
  end

  defp collapse(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  rescue
    ArgumentError -> ""
  end

  defp stderr_suffix(session) do
    case stderr_excerpt(session) do
      "" -> ""
      excerpt -> " (language server stderr: #{excerpt})"
    end
  end

  # ── Error shaping ─────────────────────────────────────────────────────────

  defp exit_error(session, status \\ nil) do
    base =
      case status do
        nil -> "the language server exited unexpectedly"
        0 -> "the language server exited unexpectedly (exit status 0)"
        other -> "the language server exited unexpectedly (exit status #{other})"
      end

    base <> stderr_suffix(session)
  end

  defp describe_error(%{"message" => message} = error) do
    code = Map.get(error, "code")
    if is_nil(code), do: to_string(message), else: "#{message} (code #{code})"
  end

  defp describe_error(other), do: inspect(other)

  # ── Bounds ────────────────────────────────────────────────────────────────

  defp truncate_output(text) when is_binary(text), do: Shared.truncate(text, @max_output_chars)
  defp truncate_output(other), do: to_string(other)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp remaining(deadline) do
    case deadline - now_ms() do
      left when left > 0 -> left
      _expired -> 0
    end
  end
end
