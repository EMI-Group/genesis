defmodule EvoGit.CommandShell do
  @moduledoc """
  A simple, secure command-shell dispatcher for the self-reflective agent.

  Parses a command STRING (e.g. `ListTasks.list_tasks` or
  `StartTask.start_task evolve "Write a parser"`)
  and dispatches it through a declarative, compile-time registry of the existing
  task-control tool modules (`EvoGit.Agent.Tools.*`). Each registered handler is
  invoked as `apply(module, :execute, [parsed_args, nil, nil])`; the handlers
  never raise and return a plain string.

  This is a core-domain utility (a sibling of `EvoGit.PeakHours`) — it does NOT
  own a `tools/` subdirectory.

  ## Security model

  - The command registry is a **compile-time literal module attribute**. There is
    no `Code.eval_string`, no dynamic `apply` with input-derived module/function
    names, and no runtime registry mutation: input only selects WHICH literal
    registry entry runs, and `apply/3` uses only the compile-time-constant module
    atoms stored in the registry.
  - **No atoms are ever created from input**: enum/bool/list values are validated
    against fixed literal lookup lists and passed through as strings (the handler
    modules perform their own validated atom conversion, e.g. `StartTask`'s
    `@task_type_map`).
  - Only the whitelisted commands are callable, and handlers are only ever
    invoked with the parsed argument map built from their declared arg specs —
    never with arbitrary arguments.
  - **Security levels** (`level` per registry entry; `security_level/1`): level
    1 = safe read-only commands that execute immediately; level 2 = commands
    that need the user's attention (a transient dashboard guide); level 3 =
    commands with real side effects (task start/cancel/force-kill/delete).
    Levels 2 and 3 are enforced at the dispatch choke point
    (`run_command/3`): the handler runs ONLY after the user approves the
    command in the /help chat via `EvoGit.CommandApproval` (blocking, bounded
    approval window, task-lifecycle auto-deny). Any non-`:approved` outcome
    (denied, timed out, approval service unavailable) fails closed — the
    handler never runs. This is defense-in-depth: it gates the actual dispatch,
    not just LLM prompt guidance.
  """

  alias EvoGit.Agent.Tools.{
    CancelTask,
    DeleteTask,
    ForceKillTask,
    GetTask,
    GuideUser,
    ListRecentProjects,
    ListTasks,
    SpawnInvestigator,
    StartTask,
    SystemInfo
  }

  @max_command_length 4000
  @max_tokens 40
  @max_token_length 2000

  @typedoc "Declarative argument specification for one registry entry."
  @type arg_spec :: %{
          key: String.t(),
          type: :string | :enum | :bool | :string_list | :enum_list,
          values: [String.t()] | nil,
          required: boolean(),
          positional: non_neg_integer() | nil,
          default: term()
        }

  # The registry: a compile-time literal map of command path → handler entry.
  # `module` is the existing task-control tool module; `args` declares how the
  # shell parses and validates the command's tokens into the handler's
  # STRING-keyed argument map (e.g. `%{"task_type" => "evolve"}`). `level` is
  # the command's security level, enforced at the dispatch choke point
  # (`run_command/3`): level 1 = safe read-only (executes immediately), level 2
  # = needs the user's attention (a transient dashboard guide), level 3 = real
  # side effects (task start/cancel/force-kill/delete). Levels 2 and 3 do NOT
  # execute until the user approves them in the /help chat via
  # `EvoGit.CommandApproval` (see `security_level/1`).
  @registry %{
    "ListTasks.list_tasks" => %{
      module: ListTasks,
      level: 1,
      summary: "Lists tasks from the task registry, optionally filtered by status.",
      args: [
        %{
          key: "statuses",
          type: :enum_list,
          values: ~w(pending running finalizing completed failed cancelled cancelling),
          required: false,
          positional: nil,
          default: nil
        }
      ]
    },
    "GetTask.get_task" => %{
      module: GetTask,
      level: 1,
      summary: "Fetches the details of a single task by id.",
      args: [
        %{key: "task_id", type: :string, required: true, positional: 1, default: nil}
      ]
    },
    "StartTask.start_task" => %{
      module: StartTask,
      level: 3,
      summary: "Starts a new background task (genesis / evolve / reflect / extract_skills).",
      args: [
        %{
          key: "task_type",
          type: :enum,
          values: ~w(genesis evolve reflect extract_skills),
          required: true,
          positional: 1,
          default: nil
        },
        %{key: "objective", type: :string, required: false, positional: 2, default: ""},
        %{key: "path", type: :string, required: false, positional: nil, default: nil},
        %{key: "mode", type: :string, required: false, positional: nil, default: nil},
        %{key: "resume_from", type: :string, required: false, positional: nil, default: nil},
        %{key: "starting_commit", type: :string, required: false, positional: nil, default: nil},
        %{key: "model_id", type: :string, required: false, positional: nil, default: nil}
      ]
    },
    "CancelTask.cancel_task" => %{
      module: CancelTask,
      level: 3,
      summary: "Gracefully cancels a task by id (intermediate results preserved).",
      args: [
        %{key: "task_id", type: :string, required: true, positional: 1, default: nil}
      ]
    },
    "ForceKillTask.force_kill_task" => %{
      module: ForceKillTask,
      level: 3,
      summary: "Force-kills a task by id (all progress lost).",
      args: [
        %{key: "task_id", type: :string, required: true, positional: 1, default: nil}
      ]
    },
    "DeleteTask.delete_task" => %{
      module: DeleteTask,
      level: 3,
      summary: "Permanently deletes a task by id (history removed).",
      args: [
        %{key: "task_id", type: :string, required: true, positional: 1, default: nil}
      ]
    },
    "SpawnInvestigator.spawn_investigator" => %{
      module: SpawnInvestigator,
      level: 1,
      summary: "Investigates a codebase path (v1 placeholder — does NOT spawn a subagent).",
      args: [
        %{key: "path", type: :string, required: true, positional: 1, default: nil},
        %{key: "objective", type: :string, required: true, positional: 2, default: nil}
      ]
    },
    "GuideUser.guide_user" => %{
      module: GuideUser,
      level: 2,
      summary: "Shows a transient user-facing guide in the dashboard UI.",
      args: [
        %{key: "message", type: :string, required: true, positional: 1, default: nil},
        %{key: "page", type: :string, required: false, positional: nil, default: nil},
        %{key: "selector", type: :string, required: false, positional: nil, default: nil},
        %{key: "dismissible", type: :bool, required: false, positional: nil, default: true}
      ]
    },
    "ListRecentProjects.list_recent_projects" => %{
      module: ListRecentProjects,
      level: 1,
      summary: "Lists the user's recently opened projects, most recent first.",
      args: []
    },
    "SystemInfo.system_info" => %{
      module: SystemInfo,
      level: 1,
      summary: "Reports local platform and system information.",
      args: []
    }
  }

  @doc """
  Parses `command_string` and dispatches it to the registered command handler.

  Returns `{:ok, output}` where `output` is the handler's result string, or
  `{:error, message}` for parse, validation, or registry errors. The handler
  modules are only ever invoked with the parsed argument map built from their
  declared arg specs.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(command) when is_binary(command) do
    with :ok <- check_command_length(command),
         {:ok, tokens} <- tokenize(command),
         :ok <- check_token_limits(tokens) do
      dispatch(tokens)
    end
  end

  def execute(_other) do
    {:error, "Command must be a string."}
  end

  @doc """
  Returns the registered command paths (sorted).
  """
  @spec list_commands() :: [String.t()]
  def list_commands do
    @registry |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the security level of a command path: `1` (safe read-only — executes
  immediately), `2` (needs the user's attention — guide), or `3` (real side
  effects — task start/cancel/force-kill/delete).

  Levels 2 and 3 require interactive user confirmation via
  `EvoGit.CommandApproval` before the command's handler runs (enforced in
  `run_command/3`). The built-in `help` command is level 1. Unknown paths
  report `1` (they fail dispatch fast with an error regardless).

  The tool-dispatch layer uses this to size the per-call timeout of
  approval-requiring `run_command` calls (`EvoGit.Agent.ToolDispatch`).
  """
  @spec security_level(String.t()) :: 1 | 2 | 3
  def security_level("help"), do: 1
  def security_level("Help"), do: 1

  def security_level(path) when is_binary(path) do
    case Map.fetch(@registry, path) do
      {:ok, entry} -> Map.get(entry, :level, 1)
      :error -> 1
    end
  end

  def security_level(_other), do: 1

  @doc """
  Returns a human-readable catalog of every registered command with its
  argument syntax and summary — the LLM-facing help text. Also returned by the
  built-in `help` command.
  """
  @spec help() :: String.t()
  def help do
    rows = Enum.sort_by(@registry, fn {path, _entry} -> path end)

    lefts =
      Enum.map(rows, fn {path, entry} ->
        String.trim_trailing(path <> " " <> usage_syntax(entry.args))
      end)

    width =
      case Enum.map(lefts, &String.length/1) do
        [] -> 0
        lengths -> Enum.max(lengths)
      end

    lines =
      rows
      |> Enum.zip(lefts)
      |> Enum.map(fn {{_path, entry}, left} ->
        "  " <>
          String.pad_trailing(left, width) <> "   " <> entry.summary <> confirmation_marker(entry)
      end)

    (["Available commands:"] ++
       lines ++
       ["", "  help [command]  Show this help or details for one command."])
    |> Enum.join("\n")
  end

  @doc """
  Returns the detailed help for a single command path.
  """
  @spec help(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def help(command_path) when is_binary(command_path) do
    case Map.fetch(@registry, command_path) do
      {:ok, entry} ->
        {:ok, format_command_detail(command_path, entry)}

      :error ->
        {:error, "Unknown command '#{command_path}'. Run 'help' to list available commands."}
    end
  end

  # --- Dispatch ---

  defp dispatch([]), do: {:error, "Empty command. Run 'help' to list available commands."}

  defp dispatch([path | rest]) do
    case path do
      "help" ->
        handle_help(rest)

      _ ->
        case Map.fetch(@registry, path) do
          {:ok, entry} -> run_command(path, entry, rest)
          :error -> {:error, "Unknown command '#{path}'. Run 'help' to list available commands."}
        end
    end
  end

  defp handle_help([]), do: {:ok, help()}
  defp handle_help([path]), do: help(path)
  defp handle_help(_more), do: {:error, "help accepts at most one command path argument."}

  # Dispatch choke point. After the command tokenizes and its arguments parse
  # and validate, the security-level gate runs BEFORE the handler: level-1
  # commands execute immediately (unchanged behavior); level-2/3 commands route
  # through EvoGit.CommandApproval and run ONLY on `:approved`. Denied, timed
  # out, or an unavailable approval service fail closed — the handler never
  # runs.
  defp run_command(path, entry, tokens) do
    with {:ok, args_map} <- parse_args(path, entry.args, tokens),
         :ok <- approval_gate(path, entry, args_map) do
      # The module/function atoms come from the compile-time registry literal —
      # never derived from input. The handler returns a plain string and never
      # raises; wrap it defensively anyway.
      output = apply(entry.module, :execute, [args_map, nil, nil])

      if is_binary(output) do
        {:ok, output}
      else
        {:error, "Unexpected handler output: #{inspect(output)}"}
      end
    end
  end

  # Security-level gate: level-1 commands (and entries without an explicit
  # level — default 1) never gate; zero behavioral change for the read-only
  # inspection commands. Levels 2 and 3 block on user approval.
  defp approval_gate(path, entry, args_map) when is_map(entry) do
    level = Map.get(entry, :level, 1)

    if level >= 2 do
      request_approval(path, level, args_map)
    else
      :ok
    end
  end

  # Blocks until the user approves/denies the command in the /help chat (or
  # the approval window expires). The requesting agent/task are read from the
  # process dictionary — the tool-dispatch layer re-establishes these keys
  # inside the spawned tool task (spawned tasks do not inherit the caller's
  # process dictionary); direct/test callers have neither and pass nil (the
  # request still gates by request_id and its own task lifecycle).
  defp request_approval(path, level, args_map) do
    agent_id = Process.get(:evogit_agent_id)
    task_id = Process.get(:evogit_task_id)

    case EvoGit.CommandApproval.request(path, human_args(args_map), level, agent_id, task_id) do
      :approved ->
        :ok

      :denied ->
        {:error,
         "Action denied by the user: #{path} was not executed. Tell the user what you " <>
           "intended and let them decide."}

      :timeout ->
        {:error,
         "The user did not confirm #{path} in time, so it was not executed. " <>
           "You can ask again if still needed."}
    end
  end

  # Renders the validated argument map as a compact human-readable string for
  # the approval request (nil/default entries omitted).
  defp human_args(args_map) when is_map(args_map) do
    case Enum.reject(args_map, fn {_key, value} -> is_nil(value) end) do
      [] -> "(no arguments)"
      kvs -> kvs |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end) |> Enum.join(", ")
    end
  end

  # --- Parsing ---

  # Splits the token list into key=value pairs and positional tokens. A token
  # of the form `key=value` counts as key=value ONLY when `key` is a declared
  # arg key for the command; otherwise it stays a positional token (so bare
  # text containing `=` does not break).
  defp split_tokens(path, specs, tokens) do
    declared = MapSet.new(Enum.map(specs, & &1.key))

    case Enum.reduce_while(tokens, {:ok, %{}, []}, fn token, {:ok, kv, positionals} ->
           case split_kv(token, declared) do
             {:kv, key, value} ->
               if Map.has_key?(kv, key) do
                 {:halt, {:error, "Duplicate argument '#{key}' for '#{path}'."}}
               else
                 {:cont, {:ok, Map.put(kv, key, value), positionals}}
               end

             :positional ->
               {:cont, {:ok, kv, [token | positionals]}}
           end
         end) do
      {:ok, kv, positionals} -> {:ok, kv, Enum.reverse(positionals)}
      {:error, _} = error -> error
    end
  end

  defp split_kv(token, declared) do
    case String.split(token, "=", parts: 2) do
      [key, value] when key != "" ->
        if MapSet.member?(declared, key), do: {:kv, key, value}, else: :positional

      _ ->
        :positional
    end
  end

  # Binds positional tokens to the declared positional arg specs (1-based, in
  # declaration order). Extra positional tokens beyond the declared count are an
  # error.
  defp bind_positionals(path, specs, positional_tokens) do
    pos_specs = specs |> Enum.filter(&(&1.positional != nil)) |> Enum.sort_by(& &1.positional)

    if length(positional_tokens) > length(pos_specs) do
      {:error,
       "Too many positional arguments for '#{path}': expected at most #{length(pos_specs)}."}
    else
      bindings =
        positional_tokens
        |> Enum.zip(pos_specs)
        |> Map.new(fn {token, spec} -> {spec.positional, token} end)

      {:ok, bindings}
    end
  end

  defp parse_args(path, specs, tokens) do
    with {:ok, kv, positional_tokens} <- split_tokens(path, specs, tokens),
         {:ok, bindings} <- bind_positionals(path, specs, positional_tokens) do
      build_args_map(path, specs, kv, bindings)
    end
  end

  # Builds the STRING-keyed argument map the handler expects. Required args must
  # be present (positional or key=value); optional args with a non-nil default
  # are filled in; optional args without a default are omitted (the handlers
  # default those themselves).
  defp build_args_map(path, specs, kv, bindings) do
    Enum.reduce_while(specs, {:ok, %{}}, fn spec, {:ok, acc} ->
      case resolve_arg_value(path, spec, kv, bindings) do
        {:ok, :omit} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, spec.key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_arg_value(path, spec, kv, bindings) do
    cond do
      Map.has_key?(kv, spec.key) ->
        validate_value(path, spec, Map.fetch!(kv, spec.key))

      spec.positional != nil and Map.has_key?(bindings, spec.positional) ->
        validate_value(path, spec, Map.fetch!(bindings, spec.positional))

      spec.required ->
        {:error, "Missing required argument '#{spec.key}' for '#{path}'."}

      spec.default != nil ->
        {:ok, spec.default}

      true ->
        {:ok, :omit}
    end
  end

  # Type validation. Token values are always binaries; enum/bool/list values are
  # checked against fixed literal lookup lists and passed through as STRINGS (or
  # literal booleans) — no atoms are ever created from input.
  defp validate_value(path, spec, value) do
    case spec.type do
      :string -> {:ok, value}
      :enum -> validate_enum(path, spec, value)
      :bool -> validate_bool(path, spec, value)
      :string_list -> {:ok, parse_string_list(value)}
      :enum_list -> validate_enum_list(path, spec, value)
    end
  end

  defp validate_enum(path, spec, value) when is_binary(value) do
    if value in spec.values do
      {:ok, value}
    else
      {:error,
       "Invalid value '#{value}' for argument '#{spec.key}' of '#{path}'; valid values: " <>
         Enum.join(spec.values, ", ") <> "."}
    end
  end

  defp validate_bool(_path, _spec, "true"), do: {:ok, true}
  defp validate_bool(_path, _spec, "false"), do: {:ok, false}

  defp validate_bool(path, spec, value) do
    {:error,
     "Invalid boolean value '#{value}' for argument '#{spec.key}' of '#{path}'; " <>
       "use 'true' or 'false'."}
  end

  defp parse_string_list(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&String.trim/1)
  end

  defp validate_enum_list(path, spec, value) when is_binary(value) do
    entries = parse_string_list(value)

    case Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
           if entry in spec.values do
             {:cont, {:ok, [entry | acc]}}
           else
             {:halt,
              {:error,
               "Invalid value '#{entry}' for argument '#{spec.key}' of '#{path}'; valid values: " <>
                 Enum.join(spec.values, ", ") <> "."}}
           end
         end) do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  # --- Tokenizer ---

  # Whitespace-splits the command into tokens, honoring double-quoted sections
  # (with `\"` and `\\` escapes) so objectives with spaces work. Returns
  # `{:ok, tokens}` or `{:error, message}` for an unterminated quote.
  defp tokenize(command) do
    case tokenize_loop(command, [], false, []) do
      {:error, _} = error -> error
      tokens -> {:ok, tokens}
    end
  end

  # Converts an accumulated (reversed) codepoint list into a binary token.
  defp finish_token(current), do: List.to_string(Enum.reverse(current))

  # End of input: flush the current token (if any).
  defp tokenize_loop(<<>>, [], _in_quote, tokens), do: Enum.reverse(tokens)

  defp tokenize_loop(<<>>, current, false, tokens),
    do: Enum.reverse([finish_token(current) | tokens])

  defp tokenize_loop(<<>>, _current, true, _tokens),
    do: {:error, "Unterminated double quote in command."}

  # A double quote toggles quoting.
  defp tokenize_loop(<<?", rest::binary>>, current, in_quote, tokens) do
    tokenize_loop(rest, current, not in_quote, tokens)
  end

  # Escaped double quote / backslash inside a quoted section.
  defp tokenize_loop(<<?\\, ?", rest::binary>>, current, true, tokens) do
    tokenize_loop(rest, [?\" | current], true, tokens)
  end

  defp tokenize_loop(<<?\\, ?\\, rest::binary>>, current, true, tokens) do
    tokenize_loop(rest, [?\\ | current], true, tokens)
  end

  # Inside a quoted section: accumulate any character.
  defp tokenize_loop(<<c, rest::binary>>, current, true, tokens) do
    tokenize_loop(rest, [c | current], true, tokens)
  end

  # Whitespace outside quotes with an empty current token: skip.
  defp tokenize_loop(<<c, rest::binary>>, [], false, tokens) when c in [?\s, ?\t, ?\r, ?\n] do
    tokenize_loop(rest, [], false, tokens)
  end

  # Whitespace outside quotes ends the current token.
  defp tokenize_loop(<<c, rest::binary>>, current, false, tokens)
       when c in [?\s, ?\t, ?\r, ?\n] do
    tokenize_loop(rest, [], false, [finish_token(current) | tokens])
  end

  # Any other character outside quotes accumulates.
  defp tokenize_loop(<<c, rest::binary>>, current, false, tokens) do
    tokenize_loop(rest, [c | current], false, tokens)
  end

  # --- Guardrails ---

  defp check_command_length(command) do
    if String.length(command) > @max_command_length do
      {:error, "Command exceeds the maximum length of #{@max_command_length} characters."}
    else
      :ok
    end
  end

  defp check_token_limits(tokens) do
    cond do
      tokens == [] ->
        {:error, "Empty command. Run 'help' to list available commands."}

      length(tokens) > @max_tokens ->
        {:error, "Command has too many tokens (maximum #{@max_tokens})."}

      Enum.any?(tokens, &(String.length(&1) > @max_token_length)) ->
        {:error, "Command token exceeds the maximum length of #{@max_token_length} characters."}

      true ->
        :ok
    end
  end

  # --- Help rendering ---

  # Positional args first (in positional order), then key=value args in
  # declaration order.
  defp usage_syntax(args) do
    {positionals, kvs} = Enum.split_with(args, &(&1.positional != nil))
    positionals = Enum.sort_by(positionals, & &1.positional)
    (positionals ++ kvs) |> Enum.map_join(" ", &arg_syntax/1)
  end

  defp arg_syntax(spec) do
    cond do
      spec.positional != nil and spec.required -> "<#{spec.key}>"
      spec.positional != nil -> "[<#{spec.key}>]"
      spec.required -> kv_token(spec)
      spec.default != nil -> "[#{spec.key}=#{format_default(spec.default)}]"
      true -> "[#{kv_token(spec)}]"
    end
  end

  defp kv_token(spec) do
    case spec.type do
      :enum -> "#{spec.key}=<#{Enum.join(spec.values, "|")}>"
      :enum_list -> "#{spec.key}=<#{Enum.join(spec.values, "|")}>"
      :string_list -> "#{spec.key}=<a,b,...>"
      :bool -> "#{spec.key}=true|false"
      :string -> "#{spec.key}=..."
    end
  end

  defp format_default(true), do: "true"
  defp format_default(false), do: "false"
  defp format_default(value), do: to_string(value)

  defp format_command_detail(path, entry) do
    arg_lines =
      case entry.args do
        [] -> ["  (no arguments)"]
        args -> Enum.map(args, &describe_arg/1)
      end

    ([
       "#{path} — #{entry.summary}#{confirmation_marker(entry)}",
       "Usage: #{path} #{usage_syntax(entry.args)}",
       "",
       "Arguments:"
     ] ++ arg_lines)
    |> Enum.join("\n")
  end

  # Level >= 2 commands need interactive user confirmation before they execute;
  # reflect that in every help surface so the catalog the LLM sees is accurate.
  defp confirmation_marker(entry) do
    if Map.get(entry, :level, 1) >= 2 do
      " — requires user confirmation"
    else
      ""
    end
  end

  defp describe_arg(spec) do
    required = if spec.required, do: "required", else: "optional"
    positional = if spec.positional != nil, do: " (positional #{spec.positional})", else: ""

    type =
      case spec.type do
        :enum -> "enum: " <> Enum.join(spec.values, " | ")
        :enum_list -> "comma-separated list of enums: " <> Enum.join(spec.values, " | ")
        :string_list -> "comma-separated list of strings"
        :bool -> "boolean (true|false)"
        :string -> "string"
      end

    default = if spec.default != nil, do: ", default: #{format_default(spec.default)}", else: ""

    "#{spec.key} — #{required}#{positional}, #{type}#{default}"
  end
end
