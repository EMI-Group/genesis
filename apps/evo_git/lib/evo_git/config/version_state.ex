defmodule EvoGit.Config.VersionState do
  @moduledoc """
  Tracks the last-seen Genesis version so the runtime can detect upgrades.

  The version state is persisted as a TOML file (`version_state.toml`) in the
  platform config directory (`EvoGit.Platform.config_dir/0` — e.g.
  `~/.config/genesis/version_state.toml`). This lets the dashboard (or any
  caller) determine whether Genesis was upgraded since the last launch and,
  in the future, display an update log.

  ## Default version

  When no version-state file exists yet (existing users who have never
  recorded a version), `get_version/0` defaults to `"0.8.0"` — the version
  at which this feature was introduced. This prevents a spurious "upgrade"
  detection for users who were already on 0.8.0 before this feature shipped.
  """

  require Logger

  @version_state_filename "version_state.toml"
  @default_version "0.8.0"

  @doc """
  Returns the full path to the version-state TOML file.
  """
  @spec path() :: String.t()
  def path do
    Path.join(EvoGit.Platform.config_dir(), @version_state_filename)
  end

  @doc """
  Returns the recorded version string from the version-state file.

  Defaults to `"0.8.0"` when the file is absent, unparseable, or missing the
  `version` key. This default ensures existing users (who have no
  version-state file) are treated as already being on 0.8.0 rather than
  triggering a spurious upgrade detection.

  Returns a plain version string like `"0.8.0"`.
  """
  @spec get_version() :: String.t()
  def get_version do
    case read_toml_file(path()) do
      {:ok, data} ->
        case Map.get(data, "version") do
          version when is_binary(version) and version != "" -> version
          _ -> @default_version
        end

      :error ->
        @default_version
    end
  end

  @doc """
  Returns the current runtime Genesis version as a string.

  Reads from `Application.spec(:evo_git, :vsn)`, which the umbrella `mix.exs`
  populates dynamically from the root `VERSION` file.
  """
  @spec current_version() :: String.t()
  def current_version do
    Application.spec(:evo_git, :vsn) |> to_string()
  end

  @doc """
  Persists the given version string to the version-state file.

  Creates the config directory if it doesn't exist. Ensures a trailing
  newline on the written file.

  Returns `:ok` on success, `{:error, reason}` on failure.

  ## Examples

      iex> EvoGit.Config.VersionState.save_version("0.9.0")
      :ok

  Can also be called with no argument, in which case it persists
  `current_version/0`:

      iex> EvoGit.Config.VersionState.save_version()
      :ok
  """
  @spec save_version(String.t()) :: :ok | {:error, term()}
  def save_version(version \\ current_version())

  def save_version(version) when is_binary(version) do
    file_path = path()
    dir = EvoGit.Platform.config_dir()

    with :ok <- File.mkdir_p(dir),
         {:ok, toml} <- TomlElixir.encode(%{"version" => version}),
         {:ok, contents} <- ensure_trailing_newline(toml),
         :ok <- File.write(file_path, contents) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `true` if the recorded version differs from the current runtime
  version, `false` if they are equal.

  This lets callers detect that Genesis was upgraded since the last time the
  version was recorded via `record_current_version/0` or `save_version/1`.
  """
  @spec upgraded?() :: boolean()
  def upgraded? do
    get_version() != current_version()
  end

  @doc """
  Convenience that persists `current_version/0` to the version-state file.

  Call this after showing the welcome page / update log so that future
  launches won't re-trigger the upgrade notification.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec record_current_version() :: :ok | {:error, term()}
  def record_current_version do
    save_version(current_version())
  end

  # --- Private Helpers ---

  # Reads and decodes a TOML file. Returns `{:ok, map}` on success or
  # `:error` on any read/parse failure (including file-not-found). No
  # exceptions — follows the project's no-try/rescue policy by using
  # non-crashing variants (`File.read/1`, `TomlElixir.decode/1`).
  defp read_toml_file(file_path) do
    case File.read(file_path) do
      {:ok, contents} ->
        case TomlElixir.decode(contents) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:error, reason} ->
            Logger.warning("Failed to parse version state at #{file_path}: #{inspect(reason)}")
            :error
        end

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("Failed to read version state at #{file_path}: #{inspect(reason)}")
        :error
    end
  end

  defp ensure_trailing_newline(content) when is_binary(content) do
    {:ok, String.trim_trailing(content) <> "\n"}
  end
end
