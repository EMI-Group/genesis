defmodule EvoGit.CLI do
  @moduledoc """
  Entry point for the EvoGit CLI.
  """

  # Terminal task statuses the CLI waits for after enqueueing a task through
  # the shared task data plane (EvoGit.TaskRegistry.start_task/2).
  @terminal_statuses [:completed, :failed, :cancelled]

  # Task type labels (literal — the dispatch arms below match the command
  # strings at compile time; nothing here is derived from user input).
  @type_labels %{genesis: "genesis", evolve: "evolve", reflect: "reflect"}

  # Session-level scheduler override flags removed from the CLI. OptionParser
  # cannot surface them as invalid (their atoms still exist in the VM, so they
  # parse as ordinary options) — main/1 scans the raw args for these tokens
  # and prints a pointer to config.toml instead.
  @removed_flag_notices [
    {"--concurrency",
     "option --concurrency was removed; set concurrency in config.toml ([[llm.providers]] concurrency (shared per provider/account)) instead"},
    {"-c",
     "option -c (--concurrency) was removed; set concurrency in config.toml ([[llm.providers]] concurrency (shared per provider/account)) instead"},
    {"--tool-concurrency",
     "option --tool-concurrency was removed; set max_tool_concurrency in config.toml ([scheduler]) instead"},
    {"--retries",
     "option --retries was removed; set max_retries in config.toml ([scheduler]) instead"},
    {"-r",
     "option -r (--retries) was removed; set max_retries in config.toml ([scheduler]) instead"},
    {"--max-turns",
     "option --max-turns was removed; set max_turns in config.toml ([scheduler]) instead"},
    {"-t",
     "option -t (--max-turns) was removed; set max_turns in config.toml ([scheduler]) instead"},
    {"--max-turns-root",
     "option --max-turns-root was removed; set max_turns_root in config.toml ([scheduler]) instead"}
  ]

  def main(args) do
    # The `run` subcommand is handled BEFORE OptionParser so command strings
    # containing `-`-prefixed tokens (e.g. 'StartTask.start_task evolve "-f"')
    # are never interpreted as CLI flags.
    case args do
      ["run" | rest] ->
        run_subcommand(rest)

      _ ->
        {opts, argv, _invalid} = EvoGit.CLI.Parser.parse_args_full(args)
        print_removed_flag_notices(args)

        cond do
          opts[:version] ->
            print_version()

          opts[:help] ->
            print_help()

          true ->
            dispatch(argv, opts)
        end
    end
  end

  defp dispatch(["genesis" | rest], opts) do
    mode = opts[:mode] || "new"
    mode = String.downcase(mode)
    prompt = get_input(rest, opts)

    if mode in ["new", "existing"] do
      if mode == "new" and is_nil(prompt) do
        IO.puts("Error: Genesis in 'new' mode requires a prompt (via argument or --file).")
        print_help()
      else
        repo_path = resolve_repo_path(opts)

        proceed? =
          if mode == "new" and not dir_empty?(repo_path) do
            confirm_non_empty_dir()
          else
            true
          end

        if proceed? do
          case validate_custom_agent(opts[:agent]) do
            :ok ->
              case resolve_model_opt(opts) do
                {:ok, model_opts} ->
                  task_opts = genesis_task_opts(mode, prompt, opts, repo_path) ++ model_opts
                  enqueue_and_wait(:genesis, task_opts)

                {:error, msg} ->
                  IO.puts("Error: #{msg}")
              end

            {:error, msg} ->
              IO.puts("Error: #{msg}")
          end
        else
          IO.puts("Aborting.")
        end
      end
    else
      if mode == "custom" do
        IO.puts(
          "Error: custom mode is evolve-only; use: genesis evolve --mode custom --agent <id> <objective>"
        )
      else
        IO.puts("Error: Invalid mode for genesis. Use 'new' or 'existing'.")
      end

      print_help()
    end
  end

  defp dispatch(["evolve" | rest], opts) do
    mode = opts[:mode] || "simple"
    mode = String.downcase(mode)
    objective = get_input(rest, opts)

    if mode in ["simple", "custom"] do
      if mode == "custom" and (is_nil(opts[:agent]) or opts[:agent] == "") do
        IO.puts(
          "Error: --mode custom requires --agent <id> to select the custom agent (defined in agents.toml)."
        )
      else
        if objective do
          case validate_custom_agent(opts[:agent]) do
            :ok ->
              case resolve_model_opt(opts) do
                {:ok, model_opts} ->
                  task_opts = evolve_task_opts(mode, objective, opts) ++ model_opts
                  enqueue_and_wait(:evolve, task_opts)

                {:error, msg} ->
                  IO.puts("Error: #{msg}")
              end

            {:error, msg} ->
              IO.puts("Error: #{msg}")
          end
        else
          IO.puts("Error: Evolve requires an objective (via argument or --file).")
          print_help()
        end
      end
    else
      IO.puts("Error: Invalid mode for evolve. Use 'simple' or 'custom'.")
      print_help()
    end
  end

  defp dispatch(["setup" | _rest], _opts) do
    EvoGit.CLI.Setup.run()
  end

  defp dispatch(["reflect" | rest], opts) do
    objective = get_input(rest, opts)

    if objective do
      case resolve_model_opt(opts) do
        {:ok, model_opts} ->
          # Repo-less: NO :path, NO :mode — TaskExecutor executes :reflect
          # without build_common_runtime_opts (which fetch!s :path).
          task_opts = [objective: objective] ++ model_opts
          enqueue_and_wait(:reflect, task_opts)

        {:error, msg} ->
          IO.puts("Error: #{msg}")
      end
    else
      IO.puts("Error: Reflect requires an objective (via argument or --file).")
      print_help()
    end
  end

  defp dispatch(_, _opts) do
    IO.puts("Error: Unknown command or missing arguments.")
    print_help()
  end

  # ── Task data plane (TaskRegistry.start_task/2) ───────────────────────────

  # Enqueues a task through the shared task data plane and waits for its
  # terminal status (foreground semantics — this BEAM hosts the scheduler).
  defp enqueue_and_wait(type_atom, task_opts) do
    case EvoGit.TaskRegistry.start_task(type_atom, task_opts) do
      {:ok, task} ->
        IO.puts("Task #{task.id} started (type: #{Map.fetch!(@type_labels, type_atom)})")
        wait_for_terminal(task.id)

      {:error, reason} ->
        IO.puts("Error: Task could not be started: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Blocks until the task reaches a terminal status. Subscribes to the "tasks"
  # PubSub topic FIRST, then does one get_task read to cover a terminal
  # broadcast that fired between the enqueue reply and the subscribe.
  defp wait_for_terminal(task_id) do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    case EvoGit.TaskRegistry.get_task(task_id) do
      %EvoGit.TaskInfo{status: status} when status in @terminal_statuses ->
        report_terminal(task_id, status)

      _ ->
        wait_for_terminal_loop(task_id)
    end
  end

  defp wait_for_terminal_loop(task_id) do
    receive do
      {:task_updated, ^task_id, status, node}
      when node == node() and status in @terminal_statuses ->
        report_terminal(task_id, status)

      _other ->
        wait_for_terminal_loop(task_id)
    end
  end

  defp report_terminal(task_id, :completed) do
    IO.puts("Task #{task_id} completed.")
    {:ok, task_id}
  end

  defp report_terminal(task_id, status) do
    line = "Task #{task_id} #{status}."
    IO.puts(line)
    {:error, line}
  end

  # Builds the task opts for a genesis task. :mode stays a STRING — the
  # RuntimeOpts converters raise ArgumentError on atoms. :path is resolved to
  # an absolute path here, in the CLI process.
  defp genesis_task_opts(mode, prompt, opts, repo_path) do
    task_opts =
      [path: repo_path, mode: mode]
      |> EvoGit.CLI.Parser.maybe_put(
        :prompt,
        if(mode == "existing" and is_nil(prompt), do: nil, else: prompt || "")
      )
      |> EvoGit.CLI.Parser.maybe_put(:agent, opts[:agent])
      |> EvoGit.CLI.Parser.maybe_put(:archive, if(opts[:archive] == true, do: true, else: nil))
      |> Keyword.put(:foreign_repos, EvoGit.CLI.Parser.parse_foreign_repos(opts))

    if mode == "new" do
      Keyword.put(task_opts, :build_system, resolve_build_system(opts))
    else
      task_opts
    end
  end

  defp evolve_task_opts(mode, objective, opts) do
    [path: resolve_repo_path(opts), mode: mode, objective: objective]
    |> EvoGit.CLI.Parser.maybe_put(:node_path, opts[:node])
    |> EvoGit.CLI.Parser.maybe_put(:starting_commit, opts[:starting_commit])
    |> EvoGit.CLI.Parser.maybe_put(:agent, opts[:agent])
    |> EvoGit.CLI.Parser.maybe_put(:archive, if(opts[:archive] == true, do: true, else: nil))
    |> Keyword.put(:foreign_repos, EvoGit.CLI.Parser.parse_foreign_repos(opts))
  end

  # Resolves the absolute repo path in the CLI process. Background task
  # wrappers must never resolve a relative path against a changed cwd.
  defp resolve_repo_path(opts) do
    (opts[:path] || File.cwd!()) |> Path.expand()
  end

  # ── Task-level provider/model selection ───────────────────────────────────

  # Runs BEFORE enqueue for every task type; invalid selections never start a task.
  defp resolve_model_opt(opts), do: resolve_model_opts(opts, EvoGit.Config.resolve())

  @doc """
  Validates CLI selection flags and returns task-level options.

  Auto returns no model keys or lock, leaving runtime selection rules in control.
  Explicit `--provider-profile` / `--model` flags take precedence over legacy
  model ids and are validated against the configured account's inventory.
  A lone `-m` retains profile-id, `id:provider:model` and model-string compatibility.

  The returned `:model_spec` is a STRING-keyed TASK SELECTION map containing
  `provider_profile_id`, `model` and optional `reasoning_effort`, NOT the schema's
  `resolved.model_spec` (a ReqLLM identifier string or provider/id override map).
  Selection fields come from the resolved top-level fields, never that identifier.
  """
  @spec resolve_model_opts(keyword(), map()) :: {:ok, keyword()} | {:error, String.t()}
  def resolve_model_opts(opts, config) do
    case EvoGit.CLI.Parser.parse_model_selection(opts) do
      {:ok, :auto} ->
        {:ok, []}

      {:ok, {:legacy, value}} ->
        with {:ok, selection} <- resolve_legacy_selection(value, config) do
          resolve_task_selection(config, selection)
        end

      {:ok, selection} ->
        resolve_task_selection(config, selection)

      {:error, message} ->
        {:error, message}
    end
  end

  defp resolve_legacy_selection(value, config) do
    alias EvoGit.Config.Schema

    profiles = Schema.provider_profiles(config)
    {id, _model_string} = EvoGit.CLI.Parser.parse_model_flag(value)

    cond do
      Enum.any?(profiles, &(&1["id"] == value)) ->
        {:ok, value}

      not is_nil(id) ->
        if Enum.any?(profiles, &(&1["id"] == id)),
          do: {:ok, id},
          else: {:error, model_error_message(value, legacy_profile_ids(profiles), id)}

      true ->
        case Enum.find(Schema.model_selections(config), fn selection ->
               value in [selection.model, "#{selection.provider}:#{selection.model}"]
             end) do
          nil ->
            {:error, model_error_message(value, legacy_profile_ids(profiles), nil)}

          selection ->
            {:ok,
             %{
               "provider_profile_id" => selection.provider_profile_id,
               "model" => selection.model
             }}
        end
    end
  end

  defp legacy_profile_ids(profiles), do: Enum.map(profiles, &%{id: &1["id"]})

  defp resolve_task_selection(config, selection) do
    case EvoGit.Config.Schema.resolve_model_spec(config, selection) do
      {:ok, resolved} ->
        spec = %{
          "provider_profile_id" => resolved.provider_profile_id,
          "model" => resolved.model
        }

        spec =
          if is_nil(resolved.reasoning_effort),
            do: spec,
            else: Map.put(spec, "reasoning_effort", resolved.reasoning_effort)

        {:ok, [model_spec: spec, model_id_locked: true]}

      {:error, reason} ->
        {:error, "model selection could not be resolved: #{inspect(reason)}"}
    end
  end

  @doc false
  # Resolves a -m/--model flag value to a configured LLM profile id.
  #
  # `profiles` is the list of configured `[[llm.models]]` maps (atom-keyed
  # `:id` / `:model`; `:model` may be a map for map-spec profiles — only
  # binary model strings are matched). Resolution order:
  #
  #   1. exact match on `profile.id == value`
  #   2. "id:provider:model" — the id segment must match a configured profile
  #      id (an unconfigured id is an error — no fallback to model matching)
  #   3. a bare model string matching some profile's `model` string
  #   4. otherwise {:error, message} listing the available profile ids
  def resolve_model_id(value, profiles) when is_binary(value) and is_list(profiles) do
    if Enum.any?(profiles, &(&1[:id] == value)) do
      {:ok, value}
    else
      {id, _model_string} = EvoGit.CLI.Parser.parse_model_flag(value)

      if not is_nil(id) do
        if Enum.any?(profiles, &(&1[:id] == id)) do
          {:ok, id}
        else
          {:error, model_error_message(value, profiles, id)}
        end
      else
        case Enum.find(profiles, &(is_binary(&1[:model]) and &1[:model] == value)) do
          nil -> {:error, model_error_message(value, profiles, nil)}
          profile -> {:ok, profile[:id]}
        end
      end
    end
  end

  defp model_error_message(value, profiles, attempted_id) do
    case profiles do
      [] ->
        "model '#{value}' could not be resolved: no LLM models are configured. " <>
          "Run `genesis setup` or add [[llm.providers]] to config.toml."

      _ ->
        ids = profiles |> Enum.map(& &1[:id]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")

        prefix =
          if attempted_id do
            "no configured LLM profile with id '#{attempted_id}'"
          else
            "no configured LLM profile matches '#{value}'"
          end

        "model '#{value}' could not be resolved: #{prefix}. Available profile ids: #{ids}. " <>
          "Pass an exact profile id or id:provider:model targeting a configured profile, " <>
          "or add the model to config.toml."
    end
  end

  # ── Removed-flag notices ──────────────────────────────────────────────────

  defp print_removed_flag_notices(args) do
    Enum.each(args, fn token ->
      case removed_flag_notice(token) do
        nil -> :ok
        notice -> IO.puts(notice)
      end
    end)
  end

  defp removed_flag_notice(token) do
    Enum.find_value(@removed_flag_notices, fn {flag, notice} ->
      if removed_flag_token?(token, flag), do: notice
    end)
  end

  defp removed_flag_token?(token, flag) do
    # Short aliases may carry a joined value (`-c4`); never treat a
    # `--`-prefixed long flag as a short-alias prefix match.
    token == flag or
      String.starts_with?(token, flag <> "=") or
      (not String.starts_with?(flag, "--") and not String.starts_with?(token, "--") and
         String.starts_with?(token, flag))
  end

  # ── The `run` subcommand ──────────────────────────────────────────────────

  # Terminal access to EvoGit.CommandShell. The approval gate is bypassed
  # (`approval: :auto`) because the terminal user IS the human authorizer.
  defp run_subcommand(rest) do
    command = rest |> Enum.join(" ") |> String.trim()

    if command == "" do
      IO.puts("Error: run requires a command string, e.g. genesis run 'ListTasks.list_tasks'")
      :ok
    else
      case EvoGit.CommandShell.execute(command, approval: :auto) do
        {:ok, output} ->
          IO.puts(output)
          :ok

        {:error, err} ->
          IO.puts("Error: #{err}")
          {:error, err}
      end
    end
  end

  # ── Validation / input helpers ────────────────────────────────────────────

  defp dir_empty?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      {:ok, files} -> Enum.empty?(files -- [".git", ".genesis"])
      _ -> true
    end
  end

  defp confirm_non_empty_dir do
    response =
      IO.gets(
        "Warning: The target directory is not empty. Genesis in 'new' mode may overwrite files. Continue? [y/N] "
      )

    if response do
      answer = response |> String.trim() |> String.downcase()
      answer in ["y", "yes"]
    else
      false
    end
  end

  defp get_input(rest, opts) do
    cond do
      opts[:file] ->
        case EvoGit.PromptFile.read(opts[:file]) do
          {:ok, text} ->
            text

          {:error, reason} ->
            IO.puts("Error: #{EvoGit.PromptFile.describe_error(reason, opts[:file])}")
            nil
        end

      rest != [] ->
        Enum.join(rest, " ") |> String.trim()

      true ->
        nil
    end
  end

  # Resolves the build system for Genesis Mode B (new codebase).
  # If --build-system is provided, converts it to an atom and validates it.
  # Otherwise, prompts the user interactively (when stdin is a tty).
  # Returns the atom id (:elixir, :node, :python, :rust, :go, :none).
  defp resolve_build_system(opts) do
    case opts[:build_system] do
      nil ->
        if stdin_tty?() do
          prompt_build_system()
        else
          :none
        end

      value when is_binary(value) ->
        atom = String.to_atom(value)

        if EvoGit.Runtime.WorktreeInitScript.get_build_system(atom) do
          atom
        else
          IO.puts("Warning: Unknown build system '#{value}', defaulting to 'none'.")
          :none
        end
    end
  end

  defp stdin_tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp prompt_build_system do
    alias EvoGit.Runtime.WorktreeInitScript

    build_systems = WorktreeInitScript.build_systems()
    count = length(build_systems)

    IO.puts(
      "\nSelect the build system for this project (used to cache dependencies in worktrees):\n"
    )

    build_systems
    |> Enum.with_index(1)
    |> Enum.each(fn {bs, idx} ->
      IO.puts("  #{idx}. #{bs.name}")
    end)

    IO.puts("")

    choice = prompt_input("Enter your choice [1-#{count}] (default: #{count}): ")

    case parse_int(choice) do
      nil ->
        IO.puts("Invalid choice, defaulting to 'none'.")
        :none

      n when n >= 1 and n <= count ->
        Enum.at(build_systems, n - 1).id

      _ ->
        IO.puts("Out of range, defaulting to 'none'.")
        :none
    end
  end

  # Local helpers (used by prompt_build_system) — these are simple enough to
  # keep inline rather than adding another cross-module dependency.
  defp prompt_input(prompt) do
    case IO.gets(prompt) do
      nil -> ""
      input -> String.trim(input)
    end
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  # Validates a --agent custom-agent id against agents.toml. Returns :ok or
  # {:error, message}. Defensive: when EvoGit.CustomAgents is not loaded
  # (shouldn't happen), the error message tells the user the id is unknown.
  defp validate_custom_agent(nil), do: :ok

  defp validate_custom_agent(id) do
    if Code.ensure_loaded?(EvoGit.CustomAgents) do
      case apply(EvoGit.CustomAgents, :get, [id]) do
        nil -> {:error, unknown_agent_message(id)}
        _definition -> :ok
      end
    else
      {:error, unknown_agent_message(id)}
    end
  end

  defp unknown_agent_message(id) do
    agents_path = Path.join(EvoGit.Config.config_dir(), "agents.toml")
    "Unknown custom agent id '#{id}'. Define it in #{agents_path}."
  end

  # ── Backward-compatible test-wrappers ──────────────────────────────────────

  @doc false
  defdelegate do_parse_model_flag(value), to: EvoGit.CLI.Parser

  @doc false
  defdelegate do_parse_foreign_repos(opts), to: EvoGit.CLI.Parser

  @doc false
  def do_validate_custom_agent(id), do: validate_custom_agent(id)

  @doc false
  defdelegate do_add_model_profile(config, model), to: EvoGit.CLI.Setup

  # ── Help / version ─────────────────────────────────────────────────────────

  defp print_version do
    version = Application.spec(:evo_git, :vsn) |> to_string()
    IO.puts("genesis #{version}")
  end

  defp print_help do
    IO.puts("""
    Genesis CLI - Evolutionary Software Development

    Usage:
      genesis genesis [options] [<prompt>]
      genesis evolve [options] <objective>
      genesis reflect [options] <objective>
      genesis run '<command>'

    Commands:
      genesis    Bootstrap the Context Tree and Phylogenetic Graph.
                 Modes:
                   'new'      (Default) Start a new codebase. Requires a <prompt>.
                   'existing' Analyze an existing codebase. <prompt> is optional.
      evolve     Mutate the codebase based on an objective.
                 Modes:
                   'simple'   (Default) Top-down evolution for clear tasks.
                   'custom'   Run a custom agent (defined in agents.toml) as
                              the root agent. Requires --agent <id>.
      reflect    Run a repo-less self-reflective agent that introspects the
                 Genesis source itself (chatbot-style system Q&A). No repo
                 changes, no merge — requires an <objective>.
      setup      Configure LLM provider and API key interactively.
                 A guided wizard helps you select a provider, choose a
                 model, and set your API key without manual file editing.
      run        Execute a task-control command string directly from the
                 terminal (approvals are granted to you — you are the human
                 authorizer). Examples:
                   genesis run 'StartTask.start_task evolve "Fix bug"'
                   genesis run 'ListTasks.list_tasks'
                   genesis run 'help'

      genesis, evolve, and reflect run as registered background tasks through
      the shared task system: each prints "Task <id> started", then blocks
      until the task reaches a terminal status.

    Options:
      -f, --file <path>           Read prompt/objective from a file.
      -p, --path <path>           Path to the git repository (default: current directory).
      -m, --model <model>         Select a model for this task (never a scheduler override).
                                  With --provider-profile, selects from that account's inventory.
                                  Alone, accepts a profile id, legacy "id:provider:model",
                                  or a configured model string.
          --provider-profile <id> Select a configured [[llm.providers]] account; requires --model.
          --reasoning-effort <effort>
                                  Optional effort for --provider-profile + --model;
                                  validated against the configured model's allowed efforts.
                                  Explicit selection locks this task; omit all selection
                                  flags for Auto (runtime rules choose the model).
          --agent <id>            Use a custom agent (defined in agents.toml) as the
                                  root agent for the task.
      -d, --mode <mode>           Execution mode (new/existing for genesis, simple/custom for evolve).
      -b, --build-system <name>   Build system for dependency caching in worktrees (genesis 'new'
                                  mode only). One of: elixir, node, python, rust, go, none.
                                  If omitted, prompts interactively.
      -R, --foreign-repo <path>
                                  Add a foreign repository for cross-repo operations.
                                  Can be specified multiple times. To assign a custom id,
                                  prefix the path with `id:`. If omitted, the directory
                                  basename is used as the id. (e.g., -R original:/Source/proj)
      -n, --node <path>           Starting node path for evolution (subdirectory within
                                  repo, default: root). Only used with 'evolve'.
      -h, --help                  Show this help message.
      -v, --version               Print the genesis version and exit.

      The scheduler override flags (-c/--concurrency, --tool-concurrency,
      -r/--retries, -t/--max-turns, --max-turns-root) were removed.
      Concurrency belongs to each [[llm.providers]] account and is shared by
      all models and reasoning efforts in its inventory (not per model).
      Configure concurrency there; retry counts and turn limits go in [scheduler]:
        [[llm.providers]]
        id = "default"
        provider = "your-provider"
        models = ["model-name"]
        default_model = "model-name"
        concurrency = 3
        [scheduler]
        max_tool_concurrency = 4
        max_retries = 3
        max_turns = 128
        max_turns_root = 1000

    Getting Started:
      Quick setup (recommended):
        genesis setup

      Manual setup:
        Step 1: Create the config directory
          Linux:   mkdir -p ~/.config/genesis
          macOS:   mkdir -p ~/Library/Application\\ Support/genesis
          Windows: mkdir %APPDATA%\\genesis

        Step 2: Create credentials.toml with your API key(s)
          echo 'GOOGLE_API_KEY = "YOUR_API_KEY_HERE"' > credentials.toml

        Step 3: Create config.toml with your LLM model and username
          echo '[[llm.providers]]'                        > config.toml
          echo 'id = "default"'                            >> config.toml
          echo 'provider = "your-provider"'               >> config.toml
          echo 'models = ["model-name"]'                   >> config.toml
          echo 'default_model = "model-name"'              >> config.toml
          echo 'concurrency = 3'                           >> config.toml
          echo '[user]'                                    >> config.toml
          echo 'github_username = "your-username"'         >> config.toml

        Step 4: Run Genesis!
          genesis genesis "your prompt"

    Configuration:
      Genesis requires API keys to communicate with LLM providers. Keys are stored
      in a credentials file (NOT in genesis.toml or environment variables alone).

      Credentials file location (by platform):
        Linux:   ~/.config/genesis/credentials.toml
        macOS:   ~/Library/Application Support/genesis/credentials.toml
        Windows: %APPDATA%\\genesis\\credentials.toml

      credentials.toml format:
        GOOGLE_API_KEY = "AIza..."
        ZAI_API_KEY = "sk-..."
        DEEPSEEK_API_KEY = "sk-..."
        GROQ_API_KEY = "gsk_..."
        TAVILY_API_KEY = "tvly-..."
        ANTHROPIC_API_KEY = "sk-ant-..."
        OPENAI_API_KEY = "sk-..."

      Note: Only one API key is required. Choose the provider matching your LLM model.

      Tip: You can also set API keys directly via environment variables (e.g., GOOGLE_API_KEY).

      API keys from credentials.toml are automatically set as environment variables.
      You can also set API keys directly via environment variables (e.g., GOOGLE_API_KEY).

      At least one API key is required to use Genesis.

      Additional settings (scheduler, LLM model, user preferences) can be
      configured in the user config file:
        Linux:   ~/.config/genesis/config.toml
        macOS:   ~/Library/Application Support/genesis/config.toml
        Windows: %APPDATA%\\genesis\\config.toml

      agents.toml lives next to config.toml and defines custom agents plus an
      optional model-selection script (select one with --agent <id>). Run a
      custom agent as the root agent via:
        genesis evolve --mode custom --agent <id> <objective>

    Examples:
      genesis genesis "Create a snake game in Python" --mode new
      genesis genesis --mode existing -p /path/to/legacy/repo
      genesis evolve "Fix the login bug" --mode simple
      genesis evolve "Fix the login bug" --mode custom --agent code-reviewer
      genesis evolve "Fix the login bug" -m default
      genesis evolve "Fix the login bug" --provider-profile default --model model-name --reasoning-effort high
      genesis run 'StartTask.start_task evolve "Fix bug"'
    """)
  end
end
