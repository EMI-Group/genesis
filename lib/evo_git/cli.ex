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
          model: :string
        ],
        aliases: [
          h: :help,
          f: :file,
          c: :concurrency,
          r: :retries,
          p: :path,
          m: :model
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
    prompt = get_input(rest, opts)

    if prompt do
      # Pass runtime opts (like max_concurrency for task stream)
      runtime_opts = []

      runtime_opts =
        if c = opts[:concurrency],
          do: Keyword.put(runtime_opts, :max_concurrency, c),
          else: runtime_opts

      runtime_opts = Keyword.put(runtime_opts, :repo_path, opts[:path] || File.cwd!())

      Genesis.run(prompt, runtime_opts)
    else
      IO.puts("Error: Genesis requires a prompt (via argument or --file).")
      print_help()
    end
  end

  defp dispatch(["evolve" | rest], opts) do
    objective = get_input(rest, opts)

    if objective do
      runtime_opts = []
      runtime_opts = Keyword.put(runtime_opts, :repo_path, opts[:path] || File.cwd!())

      Evolution.run(objective, runtime_opts)
    else
      IO.puts("Error: Evolve requires an objective (via argument or --file).")
      print_help()
    end
  end

  defp dispatch(_, _opts) do
    IO.puts("Error: Unknown command or missing arguments.")
    print_help()
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
      evogit genesis [options] <prompt>
      evogit evolve [options] <objective>

    Options:
      -f, --file <path>           Read prompt/objective from a file.
      -c, --concurrency <n>       Set number of concurrent workers (default: 3).
      -r, --retries <n>           Set max retries for failed agents (default: 3).
      -p, --path <path>           Path to the git repository (default: current directory).
      -m, --model <model>         Override the default LLM model.
      -h, --help                  Show this help message.

    Examples:
      evogit genesis "Create a snake game in Python"
      evogit genesis -f design.md -p /path/to/repo
      evogit evolve "Fix the login bug" --concurrency 5
    """)
  end
end
