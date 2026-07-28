defmodule EvoGit.Config.VersionState do
  @moduledoc """
  Tracks the last-seen Genesis version so the runtime can detect upgrades.

  The version state is persisted as a TOML file (`version_state.toml`) in the
  platform config directory (`EvoGit.Platform.config_dir/0` — e.g.
  `~/.config/genesis/version_state.toml`). This lets the dashboard (or any
  caller) determine whether Genesis was upgraded since the last launch and,
  in the future, display an update log.

  ## In-memory caching

  The version-state file is loaded once per VM lifetime into `:persistent_term`
  and served from memory on subsequent reads. The cache stores both the
  classified file state and the path it was read from. When `path/0` changes
  (e.g. the config directory differs), the cache is transparently reloaded
  from disk — so production (single fixed path) gets a true one-time load,
  while tests that vary the path per-case still see fresh data.

  ## Onboarding detection

  `onboarding_needed?/0` reports whether the version-state file exists at all
  (i.e. this is a first-time user). `complete_onboarding/0` persists the
  current version, creating the file and flipping `onboarding_needed?/0` to
  `false`.

  ## Default version

  When no version-state file exists yet (existing users who have never
  recorded a version), `get_version/0` defaults to `"0.8.0"` — the version
  at which this feature was introduced. This prevents a spurious "upgrade"
  detection for users who were already on 0.8.0 before this feature shipped.
  """

  require Logger

  @version_state_filename "version_state.toml"
  @default_version "0.8.0"

  @cache_key {__MODULE__, :version_state}

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

  Reads from the in-memory `:persistent_term` cache, populated on first access.
  """
  @spec get_version() :: String.t()
  def get_version do
    case load_cached() do
      {:exists, data} when is_map(data) ->
        case Map.get(data, "version") do
          version when is_binary(version) and version != "" -> version
          _ -> @default_version
        end

      {:exists, :unparseable} ->
        @default_version

      :not_found ->
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
  newline on the written file. After a successful write the in-memory cache
  is invalidated so the next read reloads from disk.

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
      refresh_cache()
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

  @doc """
  Returns `true` when no version-state file exists yet (first-time user).

  This is independent of version comparison — it simply checks whether the
  file has ever been created. Use this to decide whether to run first-run
  onboarding flows.
  """
  @spec onboarding_needed?() :: boolean()
  def onboarding_needed? do
    load_cached() == :not_found
  end

  @doc """
  Completes onboarding by persisting the current runtime version.

  Creates the version-state file if it doesn't already exist (which flips
  `onboarding_needed?/0` to `false`) and refreshes the in-memory cache.
  Idempotent — calling when onboarding is already complete just re-saves the
  same version.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec complete_onboarding() :: :ok | {:error, term()}
  def complete_onboarding do
    save_version(current_version())
  end

  # --- Private Helpers ---

  # Loads the classified file state from the `:persistent_term` cache,
  # repopulating it from disk when the cache is empty or the cached path no
  # longer matches `path/0` (e.g. tests change the config directory).
  #
  # Returns one of:
  #   * `{:exists, data_map}` — file exists and parses successfully
  #   * `{:exists, :unparseable}` — file exists but fails to parse
  #   * `:not_found` — file does not exist
  defp load_cached do
    current_path = path()

    case :persistent_term.get(@cache_key, :not_cached) do
      {^current_path, result} ->
        result

      _ ->
        result = classify_file_state()
        :persistent_term.put(@cache_key, {current_path, result})
        result
    end
  end

  # Reads the version-state file from disk and classifies its state.
  # Uses non-crashing variants (`File.exists?/1`, `File.read/1`,
  # `TomlElixir.decode/1`) — no try/rescue. Follows the project's crash
  # philosophy by surfacing unexpected read errors as warnings.
  defp classify_file_state do
    file_path = path()

    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, contents} ->
          case TomlElixir.decode(contents) do
            {:ok, data} when is_map(data) -> {:exists, data}
            {:error, reason} ->
              Logger.warning("Failed to parse version state at #{file_path}: #{inspect(reason)}")
              {:exists, :unparseable}
          end

        {:error, reason} ->
          Logger.warning("Failed to read version state at #{file_path}: #{inspect(reason)}")
          {:exists, :unparseable}
      end
    else
      :not_found
    end
  end

  # Invalidates the in-memory cache so the next `load_cached/0` call reloads
  # from disk. Erasing (rather than re-reading) is simplest and safest — the
  # next read repopulates the cache.
  defp refresh_cache do
    :persistent_term.erase(@cache_key)
  end

  defp ensure_trailing_newline(content) when is_binary(content) do
    {:ok, String.trim_trailing(content) <> "\n"}
  end
end
