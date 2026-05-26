defmodule LLMDB.Sources.Local do
  @moduledoc """
  Loads model metadata from local TOML files in a directory structure.

  Directory structure:
  ```
  priv/llm_db/local/
  ├── openai/
  │   ├── provider.toml         # Provider definition
  │   ├── gpt-4o.toml           # Model
  │   └── gpt-4o-mini.toml      # Model
  ├── anthropic/
  │   ├── provider.toml
  │   └── claude-3-5-sonnet.toml
  └── ...
  ```

  Provider TOML files are always named `provider.toml` and contain provider metadata.
  Model TOML files contain model metadata with `provider` field linking to provider.

  ## Options

  - `:dir` - Directory path to scan (required)
  - `:file_reader` - Function for reading files (default: `&File.read!/1`)
  - `:dir_reader` - Function for listing directories (default: `&File.ls!/1`)

  ## Examples

      iex> Local.load(%{dir: "priv/llm_db"})
      {:ok, %{"openai" => %{id: :openai, models: [...]}, ...}}

  ## Error Handling

  Individual file parse failures are logged and skipped. Returns `{:error, :directory_not_found}`
  if the directory doesn't exist.
  """

  require Logger

  @behaviour LLMDB.Source

  @impl true
  def load(%{dir: dir} = opts) when is_binary(dir) do
    file_reader = Map.get(opts, :file_reader, &File.read!/1)
    dir_reader = Map.get(opts, :dir_reader, &File.ls!/1)

    if File.dir?(dir) do
      scan_directory(dir, file_reader, dir_reader)
    else
      {:error, :directory_not_found}
    end
  end

  def load(_opts), do: {:error, :dir_required}

  # Private helpers

  defp scan_directory(dir, file_reader, dir_reader) do
    provider_dirs = dir_reader.(dir)

    data =
      Enum.reduce(provider_dirs, %{}, fn subdir, acc ->
        subdir_path = Path.join(dir, subdir)

        if File.dir?(subdir_path) do
          scan_provider_directory(subdir_path, subdir, acc, file_reader, dir_reader)
        else
          acc
        end
      end)

    {:ok, data}
  rescue
    e ->
      Logger.error("Failed to scan local directory #{dir}: #{inspect(e)}")
      {:error, {:scan_failed, e}}
  end

  defp scan_provider_directory(provider_dir, provider_id, acc, file_reader, dir_reader) do
    files = dir_reader.(provider_dir)

    # Convert provider_id string to atom for canonical format
    provider_atom = String.to_atom(provider_id)
    provider_data = %{id: provider_atom, models: []}

    result =
      Enum.reduce(files, provider_data, fn file, provider_acc ->
        if String.ends_with?(file, ".toml") do
          file_path = Path.join(provider_dir, file)
          load_toml_file(file_path, provider_atom, file, provider_acc, file_reader)
        else
          provider_acc
        end
      end)

    Map.put(acc, provider_id, result)
  rescue
    e ->
      Logger.warning("Failed to scan provider directory #{provider_dir}: #{inspect(e)}")
      acc
  end

  defp load_toml_file(file_path, provider_atom, filename, provider_data, file_reader) do
    content = file_reader.(file_path)
    decoded = Toml.decode!(content)

    # Provider definition file (always named "provider.toml")
    if filename == "provider.toml" do
      # Atomize keys for provider data
      atomized = atomize_map(decoded)
      Map.merge(provider_data, atomized)
    else
      # Model definition file - atomize keys and ensure provider is set
      model =
        decoded
        |> atomize_map()
        |> Map.put(:provider, provider_atom)

      %{provider_data | models: [model | provider_data.models]}
    end
  rescue
    e ->
      Logger.warning("Failed to parse TOML file #{file_path}: #{inspect(e)}")
      provider_data
  end

  # Recursively atomize string keys in maps
  defp atomize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      atom_key = if is_binary(key), do: String.to_atom(key), else: key
      {atom_key, atomize_value(value)}
    end)
  end

  defp atomize_value(map) when is_map(map), do: atomize_map(map)
  defp atomize_value(list) when is_list(list), do: Enum.map(list, &atomize_value/1)
  defp atomize_value(value), do: value
end
