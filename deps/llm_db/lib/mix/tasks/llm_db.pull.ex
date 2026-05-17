defmodule Mix.Tasks.LlmDb.Pull do
  use Mix.Task

  @shortdoc "Pull latest data from all configured remote sources"

  @moduledoc """
  Pulls latest model metadata from all configured remote sources and caches locally.

  This task iterates through all sources configured in `Config.sources!()` and calls
  their optional `pull/1` callback (if implemented). Sources without a `pull/1` callback
  are skipped. Fetched data is saved to cache directories (typically `priv/llm_db/upstream/`
  or `priv/llm_db/remote/`).

  To build the final canonical snapshot from fetched data, run `mix llm_db.build`.

  ## Usage

      mix llm_db.pull
      mix llm_db.pull --source openai
      mix llm_db.pull --source anthropic

  ## Switches

  - `--source` - Pull from a specific source only (openai, anthropic, google, xai, models_dev, openrouter, zenmux, llmfit, azure_foundry)

  ## Configuration

  Configure sources in your application config:

      config :llm_db,
        sources: [
          {LLMDB.Sources.ModelsDev, %{}},
          {LLMDB.Sources.Local, %{dir: "priv/llm_db"}}
        ]

  Only sources that implement the optional `pull/1` callback will be pulled.
  Typically only remote sources like `ModelsDev` implement this callback.

  ## Examples

      # Pull from all configured remote sources
      mix llm_db.pull

      # Pull from OpenAI only
      mix llm_db.pull --source openai

  ## Output

  The task prints a summary of pull results:

      Pulling from configured sources...

      ✓ LLMDB.Sources.ModelsDev: Updated (709.2 KB)
      ○ LLMDB.Sources.OpenRouter: Not modified
      - LLMDB.Sources.Local: No pull callback (skipped)

      Summary: 1 updated, 1 unchanged, 1 skipped, 0 failed

      Run 'mix llm_db.build' to generate the canonical snapshot artifact
  """

  @source_modules %{
    "openai" => LLMDB.Sources.OpenAI,
    "anthropic" => LLMDB.Sources.Anthropic,
    "google" => LLMDB.Sources.Google,
    "xai" => LLMDB.Sources.XAI,
    "models_dev" => LLMDB.Sources.ModelsDev,
    "openrouter" => LLMDB.Sources.OpenRouter,
    "zenmux" => LLMDB.Sources.Zenmux,
    "llmfit" => LLMDB.Sources.Llmfit,
    "azure_foundry" => LLMDB.Enrich.AzureWireProtocol
  }

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    load_runtime_config_and_dotenv()

    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [source: :string])

    sources =
      case opts[:source] do
        nil ->
          # Pull from all available sources
          Enum.map(@source_modules, fn {_name, module} -> {module, %{}} end)

        source_name ->
          # Pull from specific source
          case Map.get(@source_modules, source_name) do
            nil ->
              Mix.shell().error("Unknown source: #{source_name}")
              Mix.shell().info("Available sources: #{Enum.join(Map.keys(@source_modules), ", ")}")
              Mix.raise("Invalid source")

            module ->
              [{module, %{}}]
          end
      end

    if sources == [] do
      Mix.shell().info("No sources configured. Add sources to your config:")
      Mix.shell().info("")
      Mix.shell().info("  config :llm_db,")
      Mix.shell().info("    sources: [")
      Mix.shell().info("      {LLMDB.Sources.ModelsDev, %{}}")
      Mix.shell().info("    ]")
      Mix.shell().info("")
      Mix.raise("No sources configured")
    end

    Mix.shell().info("Pulling from configured sources...\n")

    # Clean up old cache files before pulling
    cleanup_old_cache_files()

    results = pull_all_sources(sources)
    print_summary(results)

    Mix.shell().info("\nRun 'mix llm_db.build' to generate the canonical snapshot artifact")
  end

  @doc false
  def load_runtime_config_and_dotenv do
    # Load runtime.exs before consulting :load_dotenv so runtime configuration
    # can disable dotenv loading for this task.
    Mix.Task.run("app.config")
    LLMDB.Dotenv.load!()
  end

  # Pull from all sources and return list of {module, result} tuples
  defp pull_all_sources(sources) do
    Enum.map(sources, fn {module, opts} ->
      {module, pull_source(module, opts)}
    end)
  end

  # Pull from a single source
  defp pull_source(module, opts) do
    if has_pull_callback?(module) do
      case module.pull(opts) do
        :noop -> :not_modified
        {:ok, path} -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      :no_callback
    end
  end

  # Check if module implements pull/1 callback
  defp has_pull_callback?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :pull, 1)
  end

  # Print summary of pull results
  defp print_summary(results) do
    updated = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    unchanged = Enum.count(results, fn {_, r} -> r == :not_modified end)
    skipped_no_callback = Enum.count(results, fn {_, r} -> r == :no_callback end)
    skipped_no_key = Enum.count(results, fn {_, r} -> r == {:error, :no_api_key} end)
    skipped = skipped_no_callback + skipped_no_key
    failed = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end) - skipped_no_key

    Enum.each(results, fn {module, result} ->
      print_source_result(module, result)
    end)

    Mix.shell().info("")

    Mix.shell().info(
      "Summary: #{updated} updated, #{unchanged} unchanged, #{skipped} skipped, #{failed} failed"
    )
  end

  # Print result for a single source
  defp print_source_result(module, result) do
    module_name = inspect(module)

    case result do
      {:ok, path} ->
        size = file_size_kb(path)
        Mix.shell().info("✓ #{module_name}: Updated (#{size} KB)")

      :not_modified ->
        Mix.shell().info("○ #{module_name}: Not modified")

      :no_callback ->
        Mix.shell().info("- #{module_name}: No pull callback (skipped)")

      {:error, :no_api_key} ->
        Mix.shell().info("⚠ #{module_name}: Skipped (no API key)")

      {:error, reason} ->
        Mix.shell().error("✗ #{module_name}: Failed - #{format_error(reason)}")
    end
  end

  # Get file size in KB
  defp file_size_kb(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        kb = div(size, 1024)
        Float.round(kb * 1.0, 1)

      _ ->
        "?"
    end
  end

  # Format error reason for display
  defp format_error({:http_status, status}), do: "HTTP #{status}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  # Clean up old cache files, keeping only the most recent version per URL hash
  defp cleanup_old_cache_files do
    upstream_dir = Application.get_env(:llm_db, :upstream_cache_dir, "priv/llm_db/upstream")

    if File.dir?(upstream_dir) do
      # Group files by hash prefix (before .json or .manifest.json)
      upstream_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, [".json", ".manifest.json"]))
      |> Enum.group_by(&extract_hash/1)
      |> Enum.each(fn {_hash, files} ->
        # Keep only the most recent cache + manifest pair
        keep_most_recent_only(upstream_dir, files)
      end)
    end
  end

  # Extract hash from filename (e.g., "models-dev-abc123.json" -> "models-dev-abc123")
  defp extract_hash(filename) do
    filename
    |> String.replace_suffix(".manifest.json", "")
    |> String.replace_suffix(".json", "")
  end

  # Keep only the most recent cache file and its manifest
  defp keep_most_recent_only(dir, files) do
    files_with_mtime =
      files
      |> Enum.map(fn file ->
        path = Path.join(dir, file)

        mtime =
          case File.stat(path) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> {{1970, 1, 1}, {0, 0, 0}}
          end

        {file, path, mtime}
      end)
      |> Enum.sort_by(fn {_, _, mtime} -> mtime end, :desc)

    # If we have more than 2 files (cache + manifest), remove older ones
    if length(files_with_mtime) > 2 do
      files_with_mtime
      |> Enum.drop(2)
      |> Enum.each(fn {_, path, _} ->
        File.rm(path)
      end)
    end
  end

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.pull can only be run inside the llm_db project itself.

      This task fetches upstream data and writes to priv/llm_db/upstream/. Running
      it from a downstream application would write files into your project that
      belong in the :llm_db package.

      If you need to pull fresh data (maintainers only):

          cd path/to/llm_db
          mix llm_db.pull

      For downstream applications, use the data shipped with :llm_db.
      """)
    end
  end
end
