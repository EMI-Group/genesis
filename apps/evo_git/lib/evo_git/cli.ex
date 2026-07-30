defmodule EvoGit.CLI do
  @moduledoc """
  Entry point for the EvoGit CLI.
  """
  alias EvoGit.Runtime.Genesis
  alias EvoGit.Runtime.Evolution

  def main(args) do
    {opts, argv} = EvoGit.CLI.Parser.parse_args(args)

    cond do
      opts[:version] ->
        print_version()

      opts[:help] ->
        print_help()

      true ->
        EvoGit.CLI.Parser.configure_scheduler(opts)
        dispatch(argv, opts)
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
        repo_path = opts[:path] || File.cwd!()

        proceed? =
          if mode == "new" and not dir_empty?(repo_path) do
            confirm_non_empty_dir()
          else
            true
          end

        if proceed? do
          runtime_opts = [
            repo_path: repo_path,
            mode: genesis_mode_atom(mode),
            archive: opts[:archive] == true
          ]

          runtime_opts = EvoGit.CLI.Parser.maybe_put_model_id(runtime_opts, opts[:model])

          foreign_repos = EvoGit.CLI.Parser.parse_foreign_repos(opts)
          runtime_opts = Keyword.put(runtime_opts, :foreign_repos, foreign_repos)

          runtime_opts =
            if mode == "new" do
              build_system = resolve_build_system(opts)
              Keyword.put(runtime_opts, :build_system, build_system)
            else
              runtime_opts
            end

          Genesis.run(prompt || "", runtime_opts)
        else
          IO.puts("Aborting.")
        end
      end
    else
      IO.puts("Error: Invalid mode for genesis. Use 'new' or 'existing'.")
      print_help()
    end
  end

  defp dispatch(["evolve" | rest], opts) do
    mode = opts[:mode] || "simple"
    mode = String.downcase(mode)
    objective = get_input(rest, opts)

    if mode == "simple" do
      if objective do
        runtime_opts = []
        runtime_opts = Keyword.put(runtime_opts, :repo_path, opts[:path] || File.cwd!())
        runtime_opts = Keyword.put(runtime_opts, :mode, evolution_mode_atom(mode))

        foreign_repos = EvoGit.CLI.Parser.parse_foreign_repos(opts)
        runtime_opts = Keyword.put(runtime_opts, :foreign_repos, foreign_repos)
        runtime_opts = EvoGit.CLI.Parser.maybe_put(runtime_opts, :node_path, opts[:node])

        runtime_opts = Keyword.put(runtime_opts, :starting_commit, opts[:starting_commit])
        runtime_opts = Keyword.put(runtime_opts, :archive, opts[:archive] == true)

        runtime_opts = EvoGit.CLI.Parser.maybe_put_model_id(runtime_opts, opts[:model])

        Evolution.run(objective, runtime_opts)
      else
        IO.puts("Error: Evolve requires an objective (via argument or --file).")
        print_help()
      end
    else
      IO.puts("Error: Invalid mode for evolve. Use 'simple'.")
      print_help()
    end
  end

  defp dispatch(["setup" | _rest], _opts) do
    EvoGit.CLI.Setup.run()
  end

  defp dispatch(_, _opts) do
    IO.puts("Error: Unknown command or missing arguments.")
    print_help()
  end

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
        if File.exists?(opts[:file]) do
          File.read!(opts[:file]) |> String.trim()
        else
          IO.puts("Error: File not found: #{opts[:file]}")
          nil
        end

      rest != [] ->
        Enum.join(rest, " ") |> String.trim()

      true ->
        nil
    end
  end

  defp genesis_mode_atom("new"), do: :new
  defp genesis_mode_atom("existing"), do: :existing

  defp genesis_mode_atom(other),
    do: raise(ArgumentError, "invalid genesis mode: #{inspect(other)}")

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

  defp evolution_mode_atom("simple"), do: :simple

  defp evolution_mode_atom(other),
    do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  # ── Backward-compatible test-wrappers ──────────────────────────────────────

  @doc false
  defdelegate do_parse_model_flag(value), to: EvoGit.CLI.Parser

  @doc false
  defdelegate do_parse_foreign_repos(opts), to: EvoGit.CLI.Parser

  @doc false
  defdelegate do_add_model_profile(config, model), to: EvoGit.CLI.Setup

  # ── Help / version ─────────────────────────────────────────────────────────

  defp print_version do
    version = Application.spec(:evo_git, :vsn) |> to_string()
    IO.puts("evogit #{version}")
  end

  defp print_help do
    IO.puts("""
    Genesis CLI - Evolutionary Software Development

    Usage:
      evogit genesis [options] [<prompt>]
      evogit evolve [options] <objective>

    Commands:
      genesis    Bootstrap the Context Tree and Phylogenetic Graph.
                 Modes:
                   'new'      (Default) Start a new codebase. Requires a <prompt>.
                   'existing' Analyze an existing codebase. <prompt> is optional.
      evolve     Mutate the codebase based on an objective.
                 Mode:
                   'simple'   (Default) Top-down evolution for clear tasks.
      setup      Configure LLM provider and API key interactively.
                 A guided wizard helps you select a provider, choose a
                 model, and set your API key without manual file editing.

    Options:
      -f, --file <path>           Read prompt/objective from a file.
      -c, --concurrency <n>       Set number of concurrent workers.
          --tool-concurrency <n>  Set number of concurrent tool executions.
      -r, --retries <n>           Set max retries for failed agents.
      -t, --max-turns <n>         Set max turns per agent (default: 128).
      -p, --path <path>           Path to the git repository (default: current directory).
      -m, --model <model>         Override the LLM model (default profile).
                                  Format: "provider:model" (e.g. "anthropic:claude-sonnet-4-20250514")
                                  or "id:provider:model" to target a specific profile by id.
      -d, --mode <mode>           Execution mode (new/existing for genesis, simple for evolve).
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
      -v, --version               Print the evogit version and exit.
    Getting Started:
      Quick setup (recommended):
        evogit setup

      Manual setup:
        Step 1: Create the config directory
          Linux:   mkdir -p ~/.config/genesis
          macOS:   mkdir -p ~/Library/Application\\ Support/genesis
          Windows: mkdir %APPDATA%\\genesis

        Step 2: Create credentials.toml with your API key(s)
          echo 'GOOGLE_API_KEY = "YOUR_API_KEY_HERE"' > credentials.toml

        Step 3: Create config.toml with your LLM model and username
          echo '[[llm.models]]'                           > config.toml
          echo 'id = "default"'                            >> config.toml
          echo 'model = "provider:model-name"'             >> config.toml
          echo 'concurrency = 3'                           >> config.toml
          echo '[user]'                                    >> config.toml
          echo 'github_username = "your-username"'         >> config.toml

        Step 4: Run Genesis!
          evogit genesis "your prompt"

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

    Examples:
      evogit genesis "Create a snake game in Python" --mode new
      evogit genesis --mode existing -p /path/to/legacy/repo
      evogit evolve "Fix the login bug" --mode simple
    """)
  end
end
