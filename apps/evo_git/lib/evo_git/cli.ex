defmodule EvoGit.CLI do
  @moduledoc """
  Entry point for the EvoGit CLI.
  """
  alias EvoGit.Runtime.Genesis
  alias EvoGit.Runtime.Evolution
  require Logger

  def main(args) do
    {opts, argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          version: :boolean,
          file: :string,
          concurrency: :integer,
          tool_concurrency: :integer,
          retries: :integer,
          max_turns: :integer,
          max_turns_root: :integer,
          path: :string,
          model: :string,
          mode: :string,
          foreign_repo: [:string, :keep],
          node: :string,
          pool_size: :integer,
          generations: :integer,
          crossover_rate: :float,
          mutation_rate: :float,
          seeds: [:string, :keep],
          concepts: [:string, :keep],
          starting_commit: :string
        ],
        aliases: [
          h: :help,
          v: :version,
          f: :file,
          c: :concurrency,
          r: :retries,
          t: :max_turns,
          p: :path,
          m: :model,
          d: :mode,
          R: :foreign_repo,
          n: :node,
          s: :pool_size,
          g: :generations,
          S: :seeds,
          C: :concepts
        ]
      )

    cond do
      opts[:version] ->
        print_version()

      opts[:help] ->
        print_help()

      true ->
        configure_scheduler(opts)
        dispatch(argv, opts)
    end
  end

  defp configure_scheduler(opts) do
    scheduler_opts =
      []
      |> maybe_put(:max_concurrency, opts[:concurrency])
      |> maybe_put(:max_tool_concurrency, opts[:tool_concurrency])
      |> maybe_put(:max_retries, opts[:retries])
      |> maybe_put(:max_turns, opts[:max_turns])
      |> maybe_put(:max_turns_root, opts[:max_turns_root])
      |> maybe_put(:llm_model, opts[:model])

    if scheduler_opts != [] do
      Logger.info("Applying session-level config overrides: #{inspect(scheduler_opts)}")
      EvoGit.AgentScheduler.update_config(scheduler_opts)
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, val), do: Keyword.put(keyword, key, val)

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
            mode: String.to_atom(mode)
          ]

          foreign_repos = parse_foreign_repos(opts)
          runtime_opts = Keyword.put(runtime_opts, :foreign_repos, foreign_repos)

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

    if mode in ["simple", "complex"] do
      if objective do
        runtime_opts = []
        runtime_opts = Keyword.put(runtime_opts, :repo_path, opts[:path] || File.cwd!())
        runtime_opts = Keyword.put(runtime_opts, :mode, String.to_atom(mode))

        foreign_repos = parse_foreign_repos(opts)
        runtime_opts = Keyword.put(runtime_opts, :foreign_repos, foreign_repos)
        runtime_opts = maybe_put(runtime_opts, :node_path, opts[:node])
        runtime_opts = maybe_put(runtime_opts, :pool_size, opts[:pool_size])
        runtime_opts = maybe_put(runtime_opts, :max_generations, opts[:generations])
        runtime_opts = maybe_put(runtime_opts, :crossover_rate, opts[:crossover_rate])
        runtime_opts = maybe_put(runtime_opts, :mutation_rate, opts[:mutation_rate])
        seeds = parse_seeds(opts)
        runtime_opts = if seeds, do: Keyword.put(runtime_opts, :seeds, seeds), else: runtime_opts
        concepts = parse_concepts(opts)
        runtime_opts = if concepts, do: Keyword.put(runtime_opts, :concepts, concepts), else: runtime_opts
        runtime_opts = maybe_put(runtime_opts, :starting_commit, opts[:starting_commit])

        Evolution.run(objective, runtime_opts)
      else
        IO.puts("Error: Evolve requires an objective (via argument or --file).")
        print_help()
      end
    else
      IO.puts("Error: Invalid mode for evolve. Use 'simple' or 'complex'.")
      print_help()
    end
  end

  defp dispatch(["setup" | _rest], _opts) do
    run_setup_wizard()
  end

  defp dispatch(_, _opts) do
    IO.puts("Error: Unknown command or missing arguments.")
    print_help()
  end

  defp dir_empty?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      {:ok, files} -> Enum.empty?(files -- [".git", ".evogit"])
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

  defp run_setup_wizard do
    alias EvoGit.Config.LLMCatalog

    IO.puts("""

    ╔══════════════════════════════════════════════════════╗
    ║            EvoGit LLM Configuration Setup           ║
    ╚══════════════════════════════════════════════════════╝
    """)

    # Step 1: Provider selection
    providers = LLMCatalog.providers()

    IO.puts("Step 1: Choose your LLM provider:\n")

    providers
    |> Enum.with_index(1)
    |> Enum.each(fn {provider, idx} ->
      IO.puts("  #{idx}. #{provider.display_name}")
    end)

    IO.puts("  #{length(providers) + 1}. Other (custom provider)")
    IO.puts("  0. Exit")
    IO.puts("")

    provider_choice = prompt_input("Enter your choice [0-#{length(providers) + 1}]: ")

    case parse_int(provider_choice) do
      nil ->
        IO.puts("\nInvalid choice. Aborting.")

      0 ->
        IO.puts("\nSetup cancelled.")

      n when n >= 1 and n <= length(providers) ->
        provider = Enum.at(providers, n - 1)
        setup_provider(provider)

      n when n == length(providers) + 1 ->
        setup_custom_provider()

      _ ->
        IO.puts("\nInvalid choice. Aborting.")
    end
  end

  defp setup_provider(provider) do
    IO.puts("\nSelected: #{provider.display_name}")
    IO.puts("API key environment variable: #{provider.env_var}\n")

    # Step 2: Model selection
    models = provider.models

    IO.puts("Step 2: Choose a model:\n")

    models
    |> Enum.with_index(1)
    |> Enum.each(fn {model, idx} ->
      IO.puts("  #{idx}. #{model.display_name} (#{model.id})")
    end)

    IO.puts("  #{length(models) + 1}. Custom model name")
    IO.puts("")

    model_choice = prompt_input("Enter your choice [1-#{length(models) + 1}]: ")

    model_id =
      case parse_int(model_choice) do
        nil ->
          IO.puts("\nInvalid choice. Using custom input.")
          prompt_input("Enter model name: ")

        n when n >= 1 and n <= length(models) ->
          model = Enum.at(models, n - 1)
          IO.puts("\n  ✓ Selected: #{model.display_name}")
          model.id

        n when n == length(models) + 1 ->
          prompt_input("Enter model name: ")

        _ ->
          IO.puts("\nInvalid choice. Using custom input.")
          prompt_input("Enter model name: ")
      end

    model_string = "#{hd(provider.provider_atoms)}:#{model_id}"

    # Step 3: API key
    IO.puts("\nStep 3: Enter your API key.")
    IO.puts("  This will be stored in your credentials file.\n")

    api_key = prompt_input("Enter #{provider.env_var}: ")

    if api_key == "" do
      IO.puts("\nNo API key entered. API key can be set later in credentials.toml.")
    end

    # Save everything
    save_setup_result(model_string, provider.env_var, api_key)
  end

  defp setup_custom_provider do
    IO.puts("\n" <> String.trim(EvoGit.Config.LLMCatalog.unknown_provider_help()))
    IO.puts("")

    model_string = prompt_input("Enter the full model string (provider:model): ")

    if model_string == "" or not String.contains?(model_string, ":") do
      IO.puts("\nInvalid model string. Expected format: \"provider:model-name\"")
      IO.puts("Setup cancelled.")
    else
      [provider_part | _] = String.split(model_string, ":", parts: 2)
      env_var = String.upcase(provider_part) <> "_API_KEY"

      IO.puts("\n  Provider: #{provider_part}")
      IO.puts("  Expected API key env var: #{env_var}")
      IO.puts("  (If this is incorrect, check https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html)\n")

      api_key = prompt_input("Enter #{env_var}: ")

      save_setup_result(model_string, env_var, api_key)
    end
  end

  defp save_setup_result(model_string, env_var, api_key) do
    # Save model to config.toml
    existing_config = EvoGit.Config.user_config()

    # Build atom-keyed config with the model set
    config =
      existing_config
      |> atomize_config_keys()
      |> ensure_llm_section()
      |> put_in([:llm, :model], model_string)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        IO.puts("\n  ✓ Model saved to config.toml: #{model_string}")

        # Save API key to credentials.toml if provided
        if api_key != "" do
          case EvoGit.Config.save_credentials(%{env_var => api_key}) do
            :ok ->
              IO.puts("  ✓ API key saved to credentials.toml: #{env_var}")

            {:error, reason} ->
              IO.puts("  ✗ Failed to save API key: #{inspect(reason)}")
              IO.puts("    You can manually add it to your credentials.toml:")
              IO.puts("    #{env_var} = \"your-api-key\"")
          end
        end

        IO.puts("\n  Config file: #{EvoGit.Config.config_path()}")
        IO.puts("  Credentials file: #{EvoGit.Config.credentials_path()}")
        IO.puts("\n✅ Setup complete! You can now run:")
        IO.puts("  evogit genesis \"your prompt here\"")

      {:error, reason} ->
        IO.puts("\n  ✗ Failed to save config: #{inspect(reason)}")
    end
  end

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

  defp atomize_config_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end

        {atom_key, atomize_config_keys(value)}

      {key, value} ->
        {key, atomize_config_keys(value)}
    end)
  end

  defp atomize_config_keys(value), do: value

  defp ensure_llm_section(config) do
    Map.put_new(config, :llm, %{model: nil})
  end

  defp get_input(rest, opts) do
    cond do
      opts[:file] ->
        if File.exists?(opts[:file]) do
          File.read!(opts[:file])
        else
          IO.puts("Error: File not found: #{opts[:file]}")
          nil
        end

      rest != [] ->
        Enum.join(rest, " ")

      true ->
        nil
    end
  end

  defp parse_seeds(opts) do
    case Keyword.get_values(opts, :seeds) do
      [] -> nil
      paths -> Enum.map(paths, &Path.expand/1)
    end
  end

  defp parse_concepts(opts) do
    case Keyword.get_values(opts, :concepts) do
      [] -> nil
      concepts -> concepts
    end
  end

  defp parse_foreign_repos(opts) do
    case Keyword.get_values(opts, :foreign_repo) do
      [] -> []
      values ->
        Enum.map(values, fn spec ->
          case String.split(spec, ":", parts: 2) do
            [path] ->
              # No id specified, use directory basename
              id = path |> Path.basename() |> String.to_atom()
              EvoGit.Core.ForeignRepo.new(id, path)
            [id_str, path] ->
              id = String.to_atom(id_str)
              EvoGit.Core.ForeignRepo.new(id, path)
          end
        end)
    end
  end

  @doc false
  def do_parse_foreign_repos(opts), do: parse_foreign_repos(opts)

  defp print_version do
    version = Application.spec(:evo_git, :vsn) |> to_string()
    IO.puts("evogit #{version}")
  end

  defp print_help do
    IO.puts("""
    EvoX Genesis CLI - Evolutionary Software Development

    Usage:
      evogit genesis [options] [<prompt>]
      evogit evolve [options] <objective>

    Commands:
      genesis    Bootstrap the Context Tree and Phylogenetic Graph.
                 Modes:
                   'new'      (Default) Start a new codebase. Requires a <prompt>.
                   'existing' Analyze an existing codebase. <prompt> is optional.
      evolve     Mutate the codebase based on an objective.
                 Modes:
                   'simple'   (Default) Top-down evolution for clear tasks.
                   'complex'  Bottom-up evolution for open-ended tasks.
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
      -m, --model <model>         Override the default LLM model.
      -d, --mode <mode>           Execution mode (new/existing for genesis, simple/complex for evolve).
      -R, --foreign-repo <path>
                                  Add a foreign repository for cross-repo operations.
                                  Can be specified multiple times. To assign a custom id,
                                  prefix the path with `id:`. If omitted, the directory
                                  basename is used as the id. (e.g., -R original:/Source/proj)
      -S, --seeds <path>          Path to a seed code file for bottom-up evolution.
                                  Can be specified multiple times. User seeds are
                                  preferred over built-in seeds. (complex mode only)
      -C, --concepts <idea>       Rough concept/idea for concept expansion seeding.
                                  The LLM expands each concept into sub-topics, then
                                  into concrete implementations, generating hundreds of
                                  diverse code fragments. Can be specified multiple times.
                                  (complex mode only)
      -n, --node <path>           Starting node path for evolution (subdirectory within
                                  repo, default: root). Only used with 'evolve'.
      -s, --pool-size <n>         Max fragments in entropy pool (default: 50).
      -g, --generations <n>       Max evolution generations (default: 20).
          --crossover-rate <f>    Crossover probability 0.0-1.0 (default: 0.7).
          --mutation-rate <f>     Mutation probability 0.0-1.0 (default: 0.3).
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
          echo '[llm]'                                  > config.toml
          echo 'model = "your-model-name"'              >> config.toml
          echo '[user]'                                 >> config.toml
          echo 'github_username = "your-username"'      >> config.toml

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
      evogit evolve "Optimize database queries" --mode complex --concurrency 5
    """)
  end
end
