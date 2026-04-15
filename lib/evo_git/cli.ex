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
          retries: :integer,
          path: :string,
          model: :string,
          mode: :string
        ],
        aliases: [
          h: :help,
          f: :file,
          c: :concurrency,
          r: :retries,
          p: :path,
          m: :model,
          d: :mode
        ]
      )

    if opts[:help] do
      print_help()
    else
      configure_system(opts)
      dispatch(argv, opts)
    end
  end

  defp configure_system(opts) do
    # Update application config if provided
    updated? =
      Enum.reduce([:concurrency, :retries, :path, :model], false, fn key, acc ->
        if val = opts[key] do
          app_key =
            case key do
              :concurrency -> :max_concurrency
              :retries -> :max_retries
              :path -> :repo_path
              :model -> :llm_model
            end

          Application.put_env(:evo_git, app_key, val)
          true
        else
          acc
        end
      end)

    # Restart AgentScheduler if config changed
    if updated? do
      Logger.info("Reconfiguring AgentScheduler with opts: #{inspect(opts)}")
      Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.AgentScheduler)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.AgentScheduler)
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
          # Pass runtime opts (like max_concurrency for task stream)
          runtime_opts = []

          runtime_opts =
            if c = opts[:concurrency],
              do: Keyword.put(runtime_opts, :max_concurrency, c),
              else: runtime_opts

          runtime_opts = Keyword.put(runtime_opts, :repo_path, repo_path)
          runtime_opts = Keyword.put(runtime_opts, :mode, String.to_atom(mode))

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
      -c, --concurrency <n>       Set number of concurrent workers (default: 3).
      -r, --retries <n>           Set max retries for failed agents (default: 3).
      -p, --path <path>           Path to the git repository (default: current directory).
      -m, --model <model>         Override the default LLM model.
      -d, --mode <mode>           Execution mode (new/existing for genesis, simple/complex for evolve).
      -h, --help                  Show this help message.

    Examples:
      evogit genesis "Create a snake game in Python" --mode new
      evogit genesis --mode existing -p /path/to/legacy/repo
      evogit evolve "Fix the login bug" --mode simple
      evogit evolve "Optimize database queries" --mode complex --concurrency 5
    """)
  end
end
