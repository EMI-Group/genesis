defmodule EvoGit.ToolRuntime.Tracking do
  @moduledoc """
  The `EvoGit.ProcessManager` side of the tool-call runtime.

  Every dispatched tool call becomes ONE `:tool_call` execution record with the
  AGENT-visible identity (`tool`, `command`, `label`, `agent_id`, `task_id`,
  `owner_pid`, `cwd`, `repo_root`, `backend`, `runtime: :foreground`). A shell
  call additionally carries the command text and a human label; a non-shell tool
  is tracked too and simply never attaches an OS handle.

  Tracking is OBSERVABILITY: it must never change a tool result. Every call here
  is therefore failure-isolated, and `track/4` returns `nil` when the registry is
  unavailable (every downstream helper tolerates a `nil` id).
  """

  require Logger

  alias EvoGit.Agent.ToolNames
  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.Handle
  alias EvoGit.ToolRuntime.Request

  # Roughly one terminal line of a shell command in the dashboard label.
  @label_command_chars 80

  @doc """
  The active sandbox backend in `EvoGit.ProcessManager`'s vocabulary
  (`:systemd | :bwrap | :sandbox_exec | :none`).

  Resolving it reads configuration, so the executor calls this ONCE per batch
  and threads the result into `track/4`.
  """
  @spec backend() :: :systemd | :bwrap | :sandbox_exec | :none
  def backend do
    isolated(fn -> Handle.execution_backend(%Handle{backend: EvoGit.Sandbox.backend()}) end) ||
      :none
  end

  @doc """
  Records one foreground tool call and returns its execution id, or `nil` when
  the process manager is unavailable.
  """
  @spec track(Request.t(), String.t() | nil, term(), atom()) :: String.t() | nil
  def track(%Request{} = request, name, args, backend) do
    meta = %{
      tool: name,
      command: shell_command(name, args),
      label: label(name, args),
      agent_id: request.agent_id,
      task_id: request.task_id,
      owner_pid: request.agent_pid,
      cwd: request.repo_path,
      repo_root: request.repo_root,
      backend: backend,
      runtime: :foreground
    }

    case isolated(fn -> ProcessManager.track(:tool_call, meta) end) do
      {:ok, id} when is_binary(id) -> id
      _unavailable -> nil
    end
  end

  @doc """
  Marks the execution terminal (`:completed`, `:failed` or `:killed`).

  Total and idempotent: a `nil` id, an unknown id and a second `finish` for an
  already-terminal execution are all no-ops.
  """
  @spec finish(String.t() | nil, :completed | :failed | :killed) :: :ok
  def finish(nil, _status), do: :ok

  def finish(id, status) when is_binary(id) do
    isolated(fn -> ProcessManager.finish(id, status, exit_code: nil) end)
    :ok
  end

  @doc """
  Stops the execution's OS handle (a timed-out call must not be left running)
  and finishes the record itself.
  """
  @spec kill(String.t() | nil, term()) :: :ok
  def kill(nil, _reason), do: :ok

  def kill(id, reason) when is_binary(id) do
    isolated(fn -> ProcessManager.kill(id, reason: reason, actor: :tool_runtime) end)
    :ok
  end

  ## Isolation

  # Reason for the rescue/catch: tracking talks to a GenServer registry that may
  # be crashed, restarting or simply not started (an isolated test registry, a
  # bare script). A dead registry must NEVER affect a tool result — the agent
  # still has to receive the tool's output — so every failure degrades to a
  # debug log plus the caller's documented "unavailable" value.
  defp isolated(fun) do
    fun.()
  rescue
    exception ->
      Logger.debug(fn ->
        "ToolRuntime tracking failed: " <> Exception.format_banner(:error, exception)
      end)

      nil
  catch
    kind, reason ->
      Logger.debug(fn -> "ToolRuntime tracking failed: #{kind} #{inspect(reason)}" end)
      nil
  end

  ## Identity helpers

  # ALIAS-AWARE shell detection: the model-facing name is `bash` while the
  # internal dispatch keys are `run_bash` / `run_powershell`, so compare through
  # the alias spine rather than a hardcoded name list.
  defp shell?(name), do: ToolNames.normalize(name) == ToolNames.shell_tool_name()

  # The shell call's command text, or `nil`. TOTAL: `args` may be a RAW string
  # on the tolerant-parse path (undecodable arguments), so only a map can carry
  # a command.
  defp shell_command(name, args) when is_map(args) do
    if shell?(name) do
      case Map.get(args, "command") do
        command when is_binary(command) -> command
        _absent -> nil
      end
    end
  end

  defp shell_command(_name, _args), do: nil

  # Non-shell calls are labelled by tool name. A shell call gets
  # `"<name>: <first line of the command>"` (single line, truncated) and falls
  # back to the tool name when there is no usable command.
  defp label(name, args) do
    case shell_command(name, args) do
      command when is_binary(command) ->
        command
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.trim()
        |> case do
          "" -> name
          line -> "#{name}: #{truncate(line)}"
        end

      _absent ->
        name
    end
  end

  defp truncate(line) do
    if String.length(line) <= @label_command_chars do
      line
    else
      String.slice(line, 0, @label_command_chars) <> "…"
    end
  end
end
