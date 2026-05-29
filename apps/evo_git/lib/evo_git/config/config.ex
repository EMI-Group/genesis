defmodule EvoGit.Config do
  @moduledoc """
  Unified configuration resolver for EvoGit.

  Merges three levels of configuration with increasing priority:

  1. **Application defaults** — Built-in sensible defaults (no model, no username)
  2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant)
  3. **Runtime overrides** — Dynamic session-level settings via AgentScheduler

  User credentials (API keys) are stored separately in
  `~/.config/evogit/credentials.toml` for security.

  ## Config File Format (config.toml)

      [scheduler]
      max_concurrency = 3
      max_tool_concurrency = 2
      agent_max_retries = 3
      max_agent_depth = 8
      max_retries = 15

      [llm]
      # REQUIRED: LLM model identifier (format: "provider:model")
      # Example models:
      # - "anthropic:claude-sonnet-4-20250514"
      # - "google:gemini-2.0-flash-exp"
      # - "zai_coding_plan:glm-5.1"
      model = "your-model-here"
      compression_threshold_tokens = 100_000

      [user]
      github_username = "your-username"

      [sandbox]
      mode = "auto"  # "auto" | "enabled" | "disabled"

  ## Credentials File Format (credentials.toml)

      [api_keys]
      google    = "AIza..."
      zai       = "sk-..."
      deepseek  = "sk-..."
      groq      = "gsk_..."
      tavily    = "tvly-..."
      anthropic = "sk-ant-..."
      openai    = "sk-..."
  """

  require Logger

  @config_filename "config.toml"
  @credentials_filename "credentials.toml"

  # --- Public API ---

  @doc """
  Returns the fully merged configuration map (defaults + user config).

  Runtime overrides are NOT included here — those are managed by
  `AgentScheduler` and applied at the scheduler level.
  """
  @spec resolve() :: map()
  def resolve do
    defaults()
    |> deep_merge(user_config())
    |> atomize_keys()
    |> atomize_enum_values()
  end

  defp atomize_enum_values(config) when is_map(config) do
    Enum.reduce(config, config, fn
      # Sandbox mode: "auto" | "enabled" | "disabled" -> :auto | :enabled | :disabled
      {:sandbox, sandbox_config}, acc when is_map(sandbox_config) ->
        mode = Map.get(sandbox_config, :mode)
        new_mode = atomize_if_string(mode, [:auto, :enabled, :disabled])
        put_in(acc, [:sandbox, :mode], new_mode)

      _, acc ->
        acc
    end)
  end

  defp atomize_if_string(value, valid_atoms) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in valid_atoms, do: atom, else: value
  rescue
    ArgumentError -> value
  end

  defp atomize_if_string(value, _valid_atoms), do: value

  @doc """
  Returns the resolved value for a specific key path.

  Accepts either a single atom key or a list of atoms representing
  a nested path.

  ## Examples

      Config.resolve(:scheduler)
      #=> %{max_concurrency: 3, max_tool_concurrency: 2, ...}

      Config.resolve([:scheduler, :max_concurrency])
      #=> 3

      Config.resolve([:llm, :model])
      #=> "zai_coding_plan:glm-5" (or nil if not configured)
  """
  @spec resolve(atom() | [atom()]) :: term()
  def resolve(key) when is_atom(key) do
    Map.get(resolve(), key)
  end

  def resolve(path) when is_list(path) do
    resolve()
    |> get_in_path(path)
  end

  @doc """
  Reads and returns the parsed user config TOML file.

  Returns `%{}` if the file is not found or cannot be parsed.
  """
  @spec user_config() :: map()
  def user_config do
    path = config_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, contents} ->
          case TomlElixir.decode(contents) do
            {:ok, config} ->
              config

            {:error, reason} ->
              Logger.warning("Failed to parse config at #{path}: #{inspect(reason)}")
              %{}
          end

        {:error, reason} ->
          Logger.warning("Failed to read config at #{path}: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Writes the provided map to the user config TOML file.

  Creates the config directory if it doesn't exist.
  Atom keys are automatically converted to strings for TOML serialization.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec save_user_config(map()) :: :ok | {:error, term()}
  def save_user_config(config) when is_map(config) do
    path = config_path()
    dir = config_dir()

    with :ok <- File.mkdir_p(dir),
         string_config = stringify_keys(config),
         {:ok, toml} <- TomlElixir.encode(string_config) do
      File.write(path, toml)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(value), do: value

  @doc """
  Returns the status of critical configuration values.

  Checks for required settings and returns a map with:
  - `:missing` — list of missing critical config keys (as atoms)
  - `:warnings` — list of human-readable warning messages for missing values
  - `:ok?` — boolean, true if all critical config is present
  """
  @spec config_status() :: %{missing: [atom()], warnings: [String.t()], ok?: boolean()}
  def config_status do
    resolved = resolve()

    checks = [
      {:llm_model, "LLM model is not configured. Set [llm] model in config.toml.", fn ->
        case get_in(resolved, [:llm, :model]) do
          nil -> true
          "" -> true
          _ -> false
        end
      end},
      {:api_key, "No API key found. Add keys to credentials.toml or set environment variables.", fn ->
        providers = [:google, :zai, :deepseek, :groq, :anthropic, :openai]
        Enum.all?(providers, fn p -> api_key(p) == nil end)
      end},
      {:github_username, "GitHub username is not configured. Set [user] github_username in config.toml.", fn ->
        case get_in(resolved, [:user, :github_username]) do
          nil -> true
          "" -> true
          _ -> false
        end
      end}
    ]

    missing = for {key, _msg, check} <- checks, check.(), do: key
    warnings = for {_key, msg, check} <- checks, check.(), do: msg

    %{missing: missing, warnings: warnings, ok?: missing == []}
  end

  @doc """
  Reads and returns the parsed credentials TOML file.

  Returns `%{}` if the file is not found or cannot be parsed.
  """
  @spec credentials() :: map()
  def credentials do
    path = credentials_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, contents} ->
          case TomlElixir.decode(contents) do
            {:ok, creds} ->
              creds

            {:error, reason} ->
              Logger.warning("Failed to parse credentials at #{path}: #{inspect(reason)}")
              %{}
          end

        {:error, reason} ->
          Logger.warning("Failed to read credentials at #{path}: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Convenience function to get a specific API key.

  Checks the credentials file first, then falls back to environment variables.
  The env var convention is `EVOGIT_API_KEY_<PROVIDER>` (uppercase), then
  common provider-specific env vars like `GOOGLE_API_KEY`, `ZAI_API_KEY`, etc.

  ## Examples

      Config.api_key(:google)
      Config.api_key(:zai)
      Config.api_key(:deepseek)
  """
  @spec api_key(atom()) :: String.t() | nil
  def api_key(provider) when is_atom(provider) do
    provider_str = Atom.to_string(provider)

    # 1. Check credentials file
    file_key = get_from_credentials(provider_str)

    # 2. Check EVOGIT_API_KEY_<PROVIDER> env var
    evogit_env = "EVOGIT_API_KEY_#{String.upcase(provider_str)}"

    # 3. Check common provider-specific env vars
    common_env = common_env_var(provider)

    file_key || System.get_env(evogit_env) || (common_env && System.get_env(common_env))
  end

  @doc """
  Returns the built-in application defaults map.

  These are the ONLY hardcoded defaults. No default model or username
  is provided — users must configure those explicitly.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      scheduler: %{
        max_concurrency: 3,
        max_tool_concurrency: 2,
        agent_max_retries: 3,
        max_agent_depth: 8,
        max_retries: 15
      },
      llm: %{},
      user: %{},
      sandbox: %{
        mode: :auto
      }
    }
  end

  @doc """
  Returns the platform config directory path.

  Follows XDG conventions:
  - **Linux**: `$XDG_CONFIG_HOME/evogit` (defaults to `~/.config/evogit`)
  - **macOS**: `~/Library/Application Support/evogit`
  - **Windows**: `%APPDATA%/evogit` (defaults to `~/evogit`)
  """
  @spec config_dir() :: String.t()
  def config_dir do
    case EvoGit.Platform.os() do
      os when os in [:linux, :unknown] ->
        xdg = System.get_env("XDG_CONFIG_HOME")
        base = if xdg && xdg != "", do: xdg, else: Path.join(System.user_home!(), ".config")
        Path.join(base, "evogit")

      :macos ->
        Path.join([System.user_home!(), "Library", "Application Support", "evogit"])

      :windows ->
        appdata = System.get_env("APPDATA")
        base = if appdata && appdata != "", do: appdata, else: System.user_home!()
        Path.join(base, "evogit")
    end
  end

  @doc """
  Returns the full path to `config.toml`.
  """
  @spec config_path() :: String.t()
  def config_path do
    Path.join(config_dir(), @config_filename)
  end

  @doc """
  Returns the full path to `credentials.toml`.
  """
  @spec credentials_path() :: String.t()
  def credentials_path do
    Path.join(config_dir(), @credentials_filename)
  end

  # --- Private Helpers ---

  defp get_from_credentials(provider_str) do
    case credentials() do
      %{"api_keys" => keys} when is_map(keys) ->
        Map.get(keys, provider_str)

      _ ->
        nil
    end
  end

  # Maps provider atoms to their common environment variable names
  @common_env_vars %{
    google: "GOOGLE_API_KEY",
    zai: "ZAI_API_KEY",
    deepseek: "DEEPSEEK_API_KEY",
    groq: "GROQ_API_KEY",
    tavily: "TAVILY_API_KEY",
    anthropic: "ANTHROPIC_API_KEY",
    openai: "OPENAI_API_KEY"
  }

  defp common_env_var(provider) do
    Map.get(@common_env_vars, provider)
  end

  # Deep merges two maps. `override` values take precedence.
  # Only merges maps; non-map values in `override` replace defaults.
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end

  defp deep_merge(_base, override), do: override

  # Recursively converts string keys to atom keys in a map.
  # Only converts top-level and nested map keys; list elements are left as-is.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key = String.to_atom(key)
        {atom_key, atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(value), do: value

  # Walks a nested map following a list of atom keys.
  defp get_in_path(map, []), do: map

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_map, _path), do: nil
end
