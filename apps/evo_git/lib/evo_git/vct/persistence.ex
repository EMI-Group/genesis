defmodule EvoGit.VCT.Persistence do
  @moduledoc """
  Persistence for the Virtual Context Tree (VCT) mount table.

  The mount table is a single JSON file whose path the caller supplies (the
  application decides where it lives; this module knows nothing about the data
  directory). The on-disk shape is:

      {
        "version": 1,
        "legacy_projects_imported": true,
        "mounts": [ {"point": "vct:///projects/foo", ...}, ... ]
      }

  `load/1` is TOTAL: a missing file, unreadable file, corrupt JSON or an
  unexpected top-level shape yields the empty state (with a `Logger.warning`)
  rather than raising, so a bad file can never take down the caller. Individual
  invalid mount entries are skipped with a warning.

  `save/3` writes through a temporary file in the SAME directory and atomically
  renames it into place, so a reader never observes a partially written table.
  """

  require Logger

  alias EvoGit.VCT.Mount

  @version 1

  @type state :: %{mounts: [Mount.t()], legacy_projects_imported: boolean()}

  @doc """
  Loads the mount table from `path`.

  Always returns `%{mounts: [...], legacy_projects_imported: boolean()}`. A
  missing/unreadable/corrupt file yields the empty state.
  """
  @spec load(String.t()) :: state()
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode(contents)

      {:error, :enoent} ->
        empty()

      {:error, reason} ->
        Logger.warning("VCT mount table unreadable at #{path}: #{inspect(reason)}")
        empty()
    end
  end

  @doc """
  Encodes a mount table as JSON.

  Returns `{:ok, json}` or `{:error, reason}`.
  """
  @spec encode([Mount.t()], boolean()) :: {:ok, String.t()} | {:error, term()}
  def encode(mounts, legacy_projects_imported?) when is_list(mounts) do
    payload = %{
      "version" => @version,
      "legacy_projects_imported" => legacy_projects_imported? == true,
      "mounts" => Enum.map(mounts, &Mount.to_map/1)
    }

    Jason.encode(payload)
  end

  def encode(_mounts, _legacy_projects_imported?), do: {:error, :invalid_mounts}

  @doc """
  Decodes a JSON mount table.

  Never raises: corrupt JSON or an unexpected top-level shape yields the empty
  state (with a warning), and invalid individual mounts are skipped.
  """
  @spec decode(String.t()) :: state()
  def decode(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"mounts" => mounts} = payload} when is_list(mounts) ->
        %{
          mounts: decode_mounts(mounts),
          legacy_projects_imported: Map.get(payload, "legacy_projects_imported") == true
        }

      {:ok, _other} ->
        Logger.warning("VCT mount table has an unexpected shape; starting empty")
        empty()

      {:error, reason} ->
        Logger.warning("VCT mount table is not valid JSON: #{inspect(reason)}")
        empty()
    end
  end

  def decode(_contents) do
    Logger.warning("VCT mount table has an unexpected shape; starting empty")
    empty()
  end

  @doc """
  Saves the mount table to `path`.

  Creates the parent directory when needed, writes the encoded JSON to a
  temporary file in that same directory and renames it into place atomically.
  Returns `:ok` or a tagged `{:error, reason}` — never raises.
  """
  @spec save(String.t(), [Mount.t()], boolean()) :: :ok | {:error, term()}
  def save(path, mounts, legacy_projects_imported?)
      when is_binary(path) and is_list(mounts) do
    with {:ok, json} <- encode(mounts, legacy_projects_imported?),
         :ok <- ensure_dir(path),
         temp = temp_path(path),
         :ok <- write_temp(temp, json) do
      rename_into_place(temp, path)
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  def save(_path, _mounts, _legacy_projects_imported?), do: {:error, :invalid_input}

  ## Helpers

  defp empty, do: %{mounts: [], legacy_projects_imported: false}

  defp decode_mounts(entries) do
    Enum.flat_map(entries, fn entry ->
      case Mount.from_map(entry) do
        {:ok, mount} ->
          [mount]

        {:error, reason} ->
          Logger.warning("Skipping invalid VCT mount entry: #{inspect(reason)}")
          []
      end
    end)
  end

  defp ensure_dir(path), do: path |> Path.dirname() |> File.mkdir_p()

  defp temp_path(path),
    do: path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

  defp write_temp(temp, json), do: File.write(temp, json, [:binary])

  defp rename_into_place(temp, path) do
    case File.rename(temp, path) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temp)
        {:error, reason}
    end
  end
end
