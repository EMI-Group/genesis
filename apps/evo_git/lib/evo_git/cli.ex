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
          starting_commit: :string,
          archive: :boolean,
          build_system: :string
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
          b: :build_system
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
      |> maybe_put_model_override(opts[:model])

    if scheduler_opts != [] do
      Logger.info("Applying session-level config overrides: #{inspect(scheduler_opts)}")
      EvoGit.AgentScheduler.update_config(scheduler_opts)
    end
  end

  # Parses the -m/--model CLI flag value into scheduler override opts.
  #
  # The flag accepts two formats:
  #   1. A bare model string (e.g., "anthropic:claude-sonnet-4-20250514")
  #      → overrides the default profile's model. Passes `{:llm_model, model}`
  #      to update_config (backward-compatible).
  #   2. An "id:model" prefixed string (e.g., "fast:anthropic:claude-haiku")
  #      → targets a specific profile by id. Currently only the default
  #      profile's model is live in AgentScheduler, so the id prefix is
  #      passed as `:model_id` for the runtime to bind to a specific profile.
  defp maybe_put_model_override(keyword, nil), do: keyword

  defp maybe_put_model_override(keyword, model_flag) do
    {model_id, model_string} = parse_model_flag(model_flag)

    keyword
    |> maybe_put(:llm_model, model_string)
    |> maybe_put(:model_id, model_id)
  end

  # Parses the -m flag value into {model_id :: String.t() | nil, model_string :: String.t()}.
  #
  # "id:provider:model" → {"id", "provider:model"} (two colons = id prefix present)
  # "provider:model"     → {nil, "provider:model"} (one colon = bare model string)
  # A bare string with no colon is treated as a model string with nil id.
  @spec parse_model_flag(String.t()) :: {String.t() | nil, String.t()}
  def parse_model_flag(value) when is_binary(value) do
    parts = String.split(value, ":", parts: 3)

    case parts do
      # Three parts: "id:provider:model"
      [id, provider, model] when id != "" and provider != "" and model != "" ->
        {id, "#{provider}:#{model}"}

      # Everything else is treated as a bare model string (no id prefix)
      _ ->
        {nil, value}
    end
  end

  @doc false
  # Public test wrapper for parse_model_flag/1
  def do_parse_model_flag(value), do: parse_model_flag(value)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, val), do: Keyword.put(keyword, key, val)

  # Passes model_id into runtime_opts when -m uses "id:provider:model" syntax.
  # A bare model string (no id prefix) passes model_id as nil — the default
  # profile (already overridden via update_config) is used.
  defp maybe_put_model_id(keyword, nil), do: keyword

  defp maybe_put_model_id(keyword, model_flag) do
    {model_id, _model_string} = parse_model_flag(model_flag)
    maybe_put(keyword, :model_id, model_id)
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

          runtime_opts = maybe_put_model_id(runtime_opts, opts[:model])

          foreign_repos = parse_foreign_repos(opts)
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

        foreign_repos = parse_foreign_repos(opts)
        runtime_opts = Keyword.put(runtime_opts, :foreign_repos, foreign_repos)
        runtime_opts = maybe_put(runtime_opts, :node_path, opts[:node])

        runtime_opts = Keyword.put(runtime_opts, :starting_commit, opts[:starting_commit])
        runtime_opts = Keyword.put(runtime_opts, :archive, opts[:archive] == true)

        runtime_opts = maybe_put_model_id(runtime_opts, opts[:model])

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
    run_setup_wizard()
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
    alias EvoGit.Config.LLMCatalog

    IO.puts("\nSelected: #{provider.display_name}")
    IO.puts("API key credential key: #{provider.credential_key}\n")

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

    # Variant selection — only for providers that offer multiple endpoint
    # variants (e.g. Alibaba Global/CN, Z.ai Normal/Coding Plan).
    variant = prompt_variant(provider)

    # Build a map model spec via the catalog. Named providers generally do not
    # need a base_url, so the resulting map is %{provider: atom, id: string}.
    model_spec =
      LLMCatalog.resolve_model_spec(hd(provider.provider_atoms), model_id, variant: variant)

    # Step 3: API key
    IO.puts("\nStep 3: Enter your API key.")
    IO.puts("  This will be stored in your credentials file.\n")

    api_key = prompt_input("Enter #{provider.credential_key}: ")

    if api_key == "" do
      IO.puts("\nNo API key entered. API key can be set later in credentials.toml.")
    end

    # Save everything
    save_setup_result(model_spec, provider.credential_key, api_key)
  end

  defp setup_custom_provider do
    IO.puts("\n" <> String.trim(EvoGit.Config.LLMCatalog.unknown_provider_help()))
    IO.puts("")

    provider = prompt_input("Enter the provider name (e.g. openai, mistral, deepseek): ")

    if provider == "" do
      IO.puts("\nNo provider entered. Setup cancelled.")
    else
      model_id = prompt_input("Enter the model id (e.g. gpt-4o, custom-model): ")

      if model_id == "" do
        IO.puts("\nNo model id entered. Setup cancelled.")
      else
        # The whole point of the custom path is proxy/aggregator endpoints.
        base_url = prompt_input("Enter the base_url (e.g. https://my-proxy.com/v1): ")

        if base_url == "" do
          IO.puts(
            "\n  ⚠ No base_url provided. The endpoint will not work for OpenAI-compatible providers that require it."
          )
        end

        # Atomize the provider name (returns the atom if it exists, else the string).
        provider_atom = safe_to_existing_atom(String.downcase(provider))

        IO.puts("\n  Provider: #{provider}")
        IO.puts("  Model id: #{model_id}")

        if base_url != "" do
          IO.puts("  Base URL: #{base_url}")
        end

        credential_key = String.upcase(provider) <> "_API_KEY"
        IO.puts("  Expected API key credential key: #{credential_key}")

        IO.puts(
          "  (If this is incorrect, check https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html)\n"
        )

        # Build the map model spec. base_url is included only when non-empty
        # (resolve_model_spec omits nil/"" values).
        model_spec =
          EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_id, base_url: base_url)

        api_key = prompt_input("Enter #{credential_key}: ")

        save_setup_result(model_spec, credential_key, api_key)
      end
    end
  end

  defp save_setup_result(model_spec, credential_key, api_key) do
    # Save model to config.toml using the [[llm.models]] array format
    existing_config = EvoGit.Config.user_config()

    # Build atom-keyed config with the model added as a profile
    config =
      existing_config
      |> atomize_config_keys()
      |> ensure_llm_section()
      |> add_model_profile(model_spec)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        IO.puts("\n  ✓ Model saved to config.toml: #{format_model_for_display(model_spec)}")

        # Save API key to credentials.toml if provided
        if api_key != "" do
          case EvoGit.Config.save_credentials(%{credential_key => api_key}) do
            :ok ->
              IO.puts("  ✓ API key saved to credentials.toml: #{credential_key}")

            {:error, reason} ->
              IO.puts("  ✗ Failed to save API key: #{inspect(reason)}")
              IO.puts("    You can manually add it to your credentials.toml:")
              IO.puts("    #{credential_key} = \"your-api-key\"")
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
        # Justified: String.to_existing_atom/1 has no non-throwing variant.
        # It is deliberately used (instead of String.to_atom/1) to avoid
        # atom-table exhaustion from arbitrary user-supplied config keys.
        # When the atom doesn't already exist, we keep the key as a string.
        atom_key = safe_to_existing_atom(key)

        {atom_key, atomize_config_keys(value)}

      {key, value} ->
        {key, atomize_config_keys(value)}
    end)
  end

  defp atomize_config_keys(value), do: value

  # Returns the existing atom for `key`, or the original string if the atom
  # does not exist.
  #
  # Justified: String.to_existing_atom/1 has no non-throwing variant
  # (no {:ok, _} | :error tuple form). It is deliberately used (instead of
  # String.to_atom/1) to avoid atom-table exhaustion from arbitrary
  # user-supplied config keys. When the atom doesn't already exist, we
  # return the original string.
  defp safe_to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp ensure_llm_section(config) do
    llm = Map.get(config, :llm, %{})
    Map.put(config, :llm, Map.put_new(llm, :models, []))
  end

  # Adds a model spec to the [[llm.models]] array.
  #
  # `model` may be either:
  #   * a string in "provider:model" form (legacy — normalized to a map later
  #     by Config.resolve/0), or
  #   * a map spec like %{provider: :openai, id: "gpt-5.5", base_url: "..."}
  #     (new — stored directly).
  #
  # If a profile with the id "default" already exists, its model is updated.
  # Otherwise a new "default" profile is created/appended. This keeps the
  # setup wizard simple — it always operates on the default profile.
  # Each profile gets its own concurrency setting (defaults to 3).
  defp add_model_profile(config, model) do
    llm = Map.get(config, :llm, %{})
    models = Map.get(llm, :models, [])

    updated_models =
      case models do
        [] ->
          # No profiles yet — create the default profile
          [%{id: "default", model: model, concurrency: 3}]

        existing ->
          case Enum.find_index(existing, fn p -> Map.get(p, :id) == "default" end) do
            nil ->
              # Profiles exist but none is "default" — append a new one
              existing ++ [%{id: "default", model: model, concurrency: 3}]

            idx ->
              # Update the existing default profile's model
              List.update_at(existing, idx, fn p ->
                Map.put(p, :model, model)
              end)
          end
      end

    llm = Map.put(llm, :models, updated_models)
    # Mirror the default profile's model to llm.model for backward compat
    llm = Map.put(llm, :model, model)
    Map.put(config, :llm, llm)
  end

  @doc false
  # Public test wrapper for add_model_profile/2
  def do_add_model_profile(config, model), do: add_model_profile(config, model)

  # Prompts the user to select a variant when the provider offers multiple
  # endpoint variants (e.g. Alibaba Global/CN). Returns the chosen variant id
  # (atom) or `nil` when the provider has no variants.
  defp prompt_variant(provider) do
    variants = provider[:variants]

    if is_list(variants) and variants != [] do
      IO.puts("\nThis provider offers multiple endpoint variants:\n")

      variants
      |> Enum.with_index(1)
      |> Enum.each(fn {variant, idx} ->
        IO.puts("  #{idx}. #{variant.display_name}")
      end)

      IO.puts("")
      choice = prompt_input("Enter your choice [1-#{length(variants)}] (default: 1): ")

      case parse_int(choice) do
        n when n >= 1 and n <= length(variants) ->
          Enum.at(variants, n - 1).id

        _ ->
          # Default to the first/canonical variant on invalid input.
          hd(variants).id
      end
    else
      nil
    end
  end

  # Formats a model spec for human-friendly display in the setup success
  # message. Accepts either a map spec (new) or a "provider:model" string
  # (legacy).
  defp format_model_for_display(%{provider: provider, id: id} = model) do
    base = "#{provider}:#{id}"
    extra = Map.get(model, :base_url)

    if extra do
      "#{base} (base_url: #{extra})"
    else
      base
    end
  end

  defp format_model_for_display(model) when is_map(model), do: inspect(model)
  defp format_model_for_display(model) when is_binary(model), do: model

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

  defp evolution_mode_atom("simple"), do: :simple

  defp evolution_mode_atom(other),
    do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  defp parse_foreign_repos(opts) do
    case Keyword.get_values(opts, :foreign_repo) do
      [] ->
        []

      values ->
        Enum.map(values, fn spec ->
          case String.split(spec, ":", parts: 2) do
            [path] ->
              # No id specified, use directory basename
              id = path |> Path.basename()
              EvoGit.Core.ForeignRepo.new(id, path)

            [id_str, path] ->
              EvoGit.Core.ForeignRepo.new(id_str, path)
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
