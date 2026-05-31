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
          file: :string,
          concurrency: :integer,
          tool_concurrency: :integer,
          retries: :integer,
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
          concepts: [:string, :keep]
        ],
        aliases: [
          h: :help,
          f: :file,
          c: :concurrency,
          r: :retries,
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

    if opts[:help] do
      print_help()
    else
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
              # No name specified, use directory basename
              name = path |> Path.basename() |> String.to_atom()
              EvoGit.Core.ForeignRepo.new(name, path)
            [name_str, path] ->
              name = String.to_atom(name_str)
              EvoGit.Core.ForeignRepo.new(name, path)
          end
        end)
    end
  end

  defp print_help do
    IO.puts("""
    EvoGit CLI - Evolutionary Software Development

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

    Options:
      -f, --file <path>           Read prompt/objective from a file.
      -c, --concurrency <n>       Set number of concurrent workers.
          --tool-concurrency <n>  Set number of concurrent tool executions.
      -r, --retries <n>           Set max retries for failed agents.
      -p, --path <path>           Path to the git repository (default: current directory).
      -m, --model <model>         Override the default LLM model.
      -d, --mode <mode>           Execution mode (new/existing for genesis, simple/complex for evolve).
      -R, --foreign-repo <name:path | path>
                                  Add a foreign repository for cross-repo operations.
                                  Can be specified multiple times. If name is omitted,
                                  the directory basename is used. (e.g., -R original:/Source/proj)
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

    Getting Started:
      Step 1: Create the config directory
        Linux:   mkdir -p ~/.config/evogit
        macOS:   mkdir -p ~/Library/Application\\ Support/evogit
        Windows: mkdir %APPDATA%\\evogit

      Step 2: Create credentials.toml with your API key(s)
        echo 'GOOGLE_API_KEY = "YOUR_API_KEY_HERE"' > credentials.toml

      Step 3: Create config.toml with your LLM model and username
        echo '[llm]'                                  > config.toml
        echo 'model = "your-model-name"'              >> config.toml
        echo '[user]'                                 >> config.toml
        echo 'github_username = "your-username"'      >> config.toml

      Step 4: Run EvoGit!
        evogit genesis "your prompt"

    Configuration:
      EvoGit requires API keys to communicate with LLM providers. Keys are stored
      in a credentials file (NOT in evogit.toml or environment variables alone).

      Credentials file location (by platform):
        Linux:   ~/.config/evogit/credentials.toml
        macOS:   ~/Library/Application Support/evogit/credentials.toml
        Windows: %APPDATA%\\evogit\\credentials.toml

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

      At least one API key is required to use EvoGit.

      Additional settings (scheduler, LLM model, user preferences) can be
      configured in the user config file:
        Linux:   ~/.config/evogit/config.toml
        macOS:   ~/Library/Application Support/evogit/config.toml
        Windows: %APPDATA%\\evogit\\config.toml

    Examples:
      evogit genesis "Create a snake game in Python" --mode new
      evogit genesis --mode existing -p /path/to/legacy/repo
      evogit evolve "Fix the login bug" --mode simple
      evogit evolve "Optimize database queries" --mode complex --concurrency 5
    """)
  end
end
