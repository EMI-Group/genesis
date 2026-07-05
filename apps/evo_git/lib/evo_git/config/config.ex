defmodule EvoGit.Config do
  @moduledoc """
  Unified configuration resolver for EvoGit.

  Merges three levels of configuration with increasing priority:

  1. **Application defaults** — Built-in sensible defaults (no model, no username)
  2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant)
  3. **Runtime overrides** — Dynamic session-level settings via AgentScheduler

  User credentials (API keys) are stored separately in
  `~/.config/genesis/credentials.toml` for security.

  ## Config File Format (config.toml)

      [scheduler]
      max_concurrency = 3
      max_tool_concurrency = 2
      agent_max_retries = 3
      max_agent_depth = 8
      max_retries = 15
      max_turns = 128
      max_turns_root = 128

      [llm]
      # REQUIRED: LLM model identifier (format: "provider:model")
      # Example models:
      # - "anthropic:claude-sonnet-4-20250514"
      # - "google:gemini-2.0-flash-exp"
      # - "zai:glm-5.1"
      model = "your-model-here"
      compression_threshold_tokens = 100_000

      [user]
      github_username = "your-username"

      [sandbox]
      mode = "auto"  # "auto" | "enabled" | "disabled"

      [sandbox.resources]
      # Slice-level limits (aggregate across all sandboxed processes)
      cpu_quota = "1000%"      # CPU quota (e.g., "1000%" = 10 cores)
      cpu_weight = 30          # CPU allocation weight (1-10000)
      memory_max = "16G"       # Total memory limit (e.g., "16G", "8G")
      tasks_max = 8196         # Max tasks/processes across the slice

      [sandbox.process]
      # Per-process limits (applied to each tool call)
      cpu_quota = "800%"       # CPU quota per process (e.g., "800%" = 8 cores)
      memory_max = "12G"       # Memory limit per process
      limit_nofile = 65536     # Max open file descriptors
      oom_score_adjust = 1000  # OOM killer preference (-1000 to 1000)

      [truncation]
      tool_output_max_bytes = 131_072    # 128 KB — threshold to trigger truncation
      tool_output_default_max_bytes = 16_384 # 16 KB — default max for high-output tools
      tool_output_truncate_size = 8_192  # 8 KB — size of truncated output
      context_max_bytes = 65_536         # 64 KB — max CONTEXT.md file size

      [task_history]
      max_tasks = 100        # max number of recent tasks to retain
      max_age_days = 14      # max age in days for retained tasks

      [nix]
      # When enabled, all tool calls run inside a Nix develop environment.
      # Requires the `nix` binary in PATH and a `flake.nix` in the config
      # directory (e.g. ~/.config/genesis/flake.nix).
      enabled = false
      # Optional flake output attribute (e.g. "devShells.x86_64-linux.default").
      # When nil, uses the default devShell.
      # flake_output = "devShells.x86_64-linux.default"

      [server]
      # IP address the web dashboard binds to. Defaults to loopback for security.
      listen_ip = "127.0.0.1"
      # Port the web dashboard listens on. Must be between 1024 and 65535.
      listen_port = 4000

      [tools.search]
      enabled = false   # Enable web search tool for agents
      # provider = "tavily"           # Search service provider
      # tavily.api_key_env_var = "TAVILY_API_KEY"  # env var for API key
      # tavily.base_url = "https://api.tavily.com/search"
      # tavily.search_depth = "basic"  # "basic" | "advanced"
      # tavily.max_results = 10        # 1-50
      # tavily.timeout = 60000         # milliseconds
      # tavily.max_bytes = 16384       # max output bytes

  ## Credentials File Format (credentials.toml)

      # API keys as environment variable names — they are set as env vars on load
      GOOGLE_API_KEY = "AIza..."
      ZAI_API_KEY = "sk-..."
      DEEPSEEK_API_KEY = "sk-..."
      GROQ_API_KEY = "gsk_..."
      TAVILY_API_KEY = "tvly-..."
      ANTHROPIC_API_KEY = "sk-ant-..."
      OPENAI_API_KEY = "sk-..."
  """

  require Logger

  @config_filename "config.toml"
  @credentials_filename "credentials.toml"

  # --- Public API ---

  # Test-only helpers to access private pipeline steps. Underscore-prefixed
  # to signal they are internal and not part of the public contract.
  @doc false
  def __atomize_enum_values__(config), do: atomize_enum_values(config)

  @doc false
  def __migrate_llm_models__(config), do: migrate_llm_models(config)

  @doc """
  Returns the fully merged configuration map (defaults + user config).

  Runtime overrides are NOT included here — those are managed by
  `AgentScheduler` and applied at the scheduler level.
  """
  @spec resolve() :: map()
  def resolve do
    config =
      defaults()
      |> deep_merge(atomize_keys(user_config()))
      |> atomize_enum_values()
      |> migrate_llm_models()

    case EvoGit.Config.Schema.validate(config) do
      {:ok, _validated} ->
        Process.delete(:evo_git_config_validation_errors)

      {:error, errors} ->
        Process.put(:evo_git_config_validation_errors, errors)

        Enum.each(errors, fn err ->
          kp = Map.get(err, :key_path, [])
          msg = Map.get(err, :message, "unknown error")
          val = Map.get(err, :value, nil)
          Logger.warning(
            "Config validation error at #{inspect(kp)}: #{msg} (got: #{inspect(val)})"
          )
        end)
    end

    config
  end

  defp atomize_enum_values(config) when is_map(config) do
    Enum.reduce(config, config, fn
      # Sandbox mode: "auto" | "enabled" | "disabled" -> :auto | :enabled | :disabled
      {:sandbox, sandbox_config}, acc when is_map(sandbox_config) ->
        mode = Map.get(sandbox_config, :mode)
        new_mode = atomize_if_string(mode, [:auto, :enabled, :disabled])
        put_in(acc, [:sandbox, :mode], new_mode)

      # LLM model normalization:
      # 1. Flat [llm].model map → normalize provider atom
      # 2. [[llm.models]] → normalize model maps in each profile
      {:llm, llm_config}, acc when is_map(llm_config) ->
        # Normalize the flat model map (backward compat)
        acc =
          case Map.get(llm_config, :model) do
            model when is_map(model) ->
              normalized = normalize_model_map(model)
              put_in(acc, [:llm, :model], normalized)

            _ ->
              acc
          end

        # Normalize each profile's model map in the models list
        case Map.get(llm_config, :models) do
          models when is_list(models) ->
            normalized_models =
              Enum.map(models, fn profile when is_map(profile) ->
                profile = normalize_profile_keys(profile)

                case Map.get(profile, :model) do
                  model when is_map(model) ->
                    Map.put(profile, :model, normalize_model_map(model))

                  _ ->
                    profile
                end
              end)

            put_in(acc, [:llm, :models], normalized_models)

          _ ->
            acc
        end

      # Tools search: convert string enum values to atoms
      # (e.g., "tavily" -> :tavily, "basic" -> :basic)
      {:tools, tools_config}, acc when is_map(tools_config) ->
        search_config = Map.get(tools_config, :search, %{})

        if is_map(search_config) do
          provider = Map.get(search_config, :provider)
          new_provider = atomize_if_string(provider, [:tavily])
          acc = put_in(acc, [:tools, :search, :provider], new_provider)

          tavily_config = Map.get(search_config, :tavily, %{})
          if is_map(tavily_config) do
            search_depth = Map.get(tavily_config, :search_depth)
            new_depth = atomize_if_string(search_depth, [:basic, :advanced])
            put_in(acc, [:tools, :search, :tavily, :search_depth], new_depth)
          else
            acc
          end
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  # Migrates old flat [llm] config into the models list format.
  #
  # If config.llm.models already exists (new format), it is used directly.
  # If config.llm.model is set but models is empty/absent (old flat format),
  # a single "default" profile is created from the flat fields.
  #
  # This always ensures config.llm.models is present after resolution.
  defp migrate_llm_models(config) when is_map(config) do
    llm = Map.get(config, :llm, %{})
    existing_models = Map.get(llm, :models, [])

    models =
      cond do
        # New format: models list already has profiles
        is_list(existing_models) and existing_models != [] ->
          existing_models

        # Old flat format: migrate model into a single "default" profile
        true ->
          flat_model = Map.get(llm, :model)

          if flat_model == nil or flat_model == "" do
            # No model configured at all — keep empty list
            []
          else
            # Build default profile from flat fields.
            # Concurrency comes from scheduler.max_concurrency (the old global limit).
            scheduler = Map.get(config, :scheduler, %{})
            concurrency = Map.get(scheduler, :max_concurrency, 3)

            profile =
              %{
                id: "default",
                model: flat_model,
                concurrency: concurrency
              }
              |> maybe_put_gen_param(:temperature, Map.get(llm, :temperature))
              |> maybe_put_gen_param(:max_tokens, Map.get(llm, :max_tokens))
              |> maybe_put_gen_param(:reasoning_effort, Map.get(llm, :reasoning_effort))
              |> maybe_put_gen_param(:top_p, Map.get(llm, :top_p))
              |> maybe_put_gen_param(:top_k, Map.get(llm, :top_k))
              |> maybe_put_gen_param(:frequency_penalty, Map.get(llm, :frequency_penalty))
              |> maybe_put_gen_param(:presence_penalty, Map.get(llm, :presence_penalty))

            [profile]
          end
      end

    # Ensure the flat [llm].model mirrors the default profile's model for
    # backward compatibility (Config.resolve([:llm, :model]) still works).
    llm =
      case models do
        [%{model: default_model} | _] ->
          Map.put(llm, :model, default_model)

        _ ->
          llm
      end

    put_in(config, [:llm], Map.put(llm, :models, models))
  end

  defp maybe_put_gen_param(map, _key, nil), do: map
  defp maybe_put_gen_param(map, key, value), do: Map.put(map, key, value)

  # Atomizes the string keys of a model profile map.
  # atomize_keys recurses into map values but NOT list elements, so profiles
  # inside the models list may still have string keys after the initial pass.
  defp normalize_profile_keys(profile) when is_map(profile) do
    Map.new(profile, fn
      {key, value} when is_binary(key) -> {safe_atomize(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Normalizes a model map so that keys are atoms and the :provider value is
  # an atom. req_llm's ReqLLM.model/1 expects the provider to be an atom.
  defp normalize_model_map(model) when is_map(model) do
    # Ensure atom keys (atomize_keys may have left string keys if the atom
    # didn't exist yet — e.g. "base_url").
    atomized =
      Map.new(model, fn
        {key, value} when is_binary(key) -> {safe_atomize(key), value}
        {key, value} -> {key, value}
      end)

    # Convert the provider VALUE to an atom if it's a string.
    case Map.get(atomized, :provider) do
      provider when is_binary(provider) -> Map.put(atomized, :provider, safe_atomize(provider))
      _ -> atomized
    end
  end

  defp atomize_if_string(value, valid_atoms) when is_binary(value) do
    # Build a string→atom lookup from the known valid atoms. This avoids
    # String.to_existing_atom/1 + rescue entirely — unknown values (typos)
    # simply pass through as strings via Map.get's default.
    lookup = Map.new(valid_atoms, &{Atom.to_string(&1), &1})
    Map.get(lookup, value, value)
  end

  defp atomize_if_string(value, _valid_atoms), do: value

  defp safe_atomize(string) when is_binary(string) do
    # KEPT: try/rescue is the idiomatic pattern for safely atomizing
    # user-supplied TOML config keys. The Elixir atom table is not queryable,
    # so there is no non-crashing way to check whether an atom exists before
    # converting. String.to_existing_atom/1 raises ArgumentError for unknown
    # atoms, which we catch to gracefully reject typo'd config keys — they are
    # kept as strings rather than crashing or exhausting the atom table.
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> string
    end
  end

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
      #=> "zai:glm-5" (or nil if not configured)
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

  Checks the primary ("genesis") config path first. If `config.toml` is not
  found there, falls back to the legacy ("evogit") config directory for
  backwards compatibility with existing users.

  Returns `%{}` if the file is not found or cannot be parsed in either location.
  """
  @spec user_config() :: map()
  def user_config do
    path = config_path()

    cond do
      File.exists?(path) ->
        read_config_file(path)

      true ->
        legacy_path = Path.join(legacy_config_dir(), @config_filename)

        if File.exists?(legacy_path), do: read_config_file(legacy_path), else: %{}
    end
  end

  defp read_config_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case TomlElixir.decode(contents) do
          {:ok, config} ->
            Map.delete(config, "evolution")

          {:error, reason} ->
            Logger.warning("Failed to parse config at #{path}: #{inspect(reason)}")
            %{}
        end

      {:error, reason} ->
        Logger.warning("Failed to read config at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  @doc """
  Writes the provided map to the user config TOML file.

  Creates the config directory if it doesn't exist.
  Atom keys are automatically converted to strings for TOML serialization.
  Validates the config against the schema before writing.

  Returns `:ok` on success, `{:error, reason}` on failure.
  `reason` can be a list of `EvoGit.Config.Schema.ValidationError` structs
  on validation failure, or a filesystem error term.
  """
  @spec save_user_config(map()) :: :ok | {:error, term()}
  def save_user_config(config) when is_map(config) do
    # Validate before writing
    case EvoGit.Config.Schema.validate(config) do
      {:error, errors} ->
        {:error, errors}

      {:ok, _valid} ->
        path = config_path()
        dir = config_dir()

        with :ok <- File.mkdir_p(dir),
             config = Map.delete(config, :evolution),
             string_config = stringify_keys(config),
             {:ok, toml} <- TomlElixir.encode(string_config) do
          File.write(path, toml)
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Map.new()
  end

  defp stringify_keys(nil), do: nil
  defp stringify_keys(value), do: value

  @doc """
  Returns the status of critical configuration values.

  Checks for required settings and returns a map with:
  - `:missing` — list of missing critical config keys (as atoms)
  - `:warnings` — list of human-readable warning messages for missing values
  - `:ok?` — boolean, true if all critical config is present
  - `:validation_errors` — list of `EvoGit.Config.Schema.ValidationError` structs from
    the last `resolve/0` call, or empty list if none
  """
  @spec config_status() :: %{
    missing: [atom()],
    warnings: [String.t()],
    ok?: boolean(),
    validation_errors: [EvoGit.Config.Schema.ValidationError.t()]
  }
  def config_status do
    resolved = resolve()

    checks = [
      {:llm_model, "LLM model is not configured. Set [llm] model in config.toml.", fn ->
        # Check that at least one model profile has a non-nil/non-empty model
        profiles = EvoGit.Config.Schema.model_profiles(resolved)

        has_model =
          Enum.any?(profiles, fn profile ->
            case Map.get(profile, :model) do
              nil -> false
              "" -> false
              _ -> true
            end
          end)

        not has_model
      end},
      {:api_key, "No API key found. Add keys to credentials.toml or set environment variables.", fn ->
        providers = EvoGit.Config.LLMCatalog.known_env_vars()
        Enum.all?(providers, fn p -> System.get_env(p) == nil end)
      end},
      {:github_username, "GitHub username is not configured. Set [user] github_username in config.toml.", fn ->
        case get_in(resolved, [:user, :github_username]) do
          nil -> true
          "" -> true
          _ -> false
        end
      end},
      {:search_api_key, "Web search is enabled but the API key environment variable is not set.", fn ->
        tools_search_enabled?() == false and get_in(resolved, [:tools, :search, :enabled]) == true
      end}
    ]

    missing = for {key, _msg, check} <- checks, check.(), do: key
    warnings = for {_key, msg, check} <- checks, check.(), do: msg

    %{
      missing: missing,
      warnings: warnings,
      ok?: missing == [],
      validation_errors: Process.get(:evo_git_config_validation_errors, [])
    }
  end

  @doc """
  Reads and returns the parsed credentials TOML file.

  Checks the primary ("genesis") credentials path first. If `credentials.toml`
  is not found there, falls back to the legacy ("evogit") config directory for
  backwards compatibility with existing users.

  Returns `%{}` if the file is not found or cannot be parsed in either location.
  """
  @spec credentials() :: map()
  def credentials do
    path = credentials_path()
    legacy_path = Path.join(legacy_config_dir(), @credentials_filename)

    cond do
      File.exists?(path) ->
        read_credentials_file(path)

      File.exists?(legacy_path) ->
        read_credentials_file(legacy_path)

      true ->
        %{}
    end
  end

  defp read_credentials_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case TomlElixir.decode(contents) do
          {:ok, creds} ->
            Enum.each(creds, fn {key, value} ->
              if is_binary(value), do: System.put_env(key, value)
            end)

            creds

          {:error, reason} ->
            Logger.warning("Failed to parse credentials at #{path}: #{inspect(reason)}")
            %{}
        end

      {:error, reason} ->
        Logger.warning("Failed to read credentials at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  @doc """
  Saves credential key-value pairs to the credentials TOML file.

  Takes a map of `%{"ENV_VAR_NAME" => "api_key_value"}` (string keys).
  Deep merges the new credentials into any existing ones (new values override),
  writes the merged map to `credentials.toml`, and sets each new key-value pair
  as an environment variable via `System.put_env/2`.

  Creates the credentials file if it doesn't exist yet.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec save_credentials(map()) :: :ok | {:error, term()}
  def save_credentials(new_creds) when is_map(new_creds) do
    path = credentials_path()
    dir = config_dir()

    existing = credentials()

    merged =
      Map.merge(existing, new_creds, fn _key, _existing_val, new_val -> new_val end)

    # Set each new key-value pair in the environment FIRST, unconditionally.
    # This guarantees the keys are usable in the current session even if
    # persistence to disk fails (e.g., Windows path issues).
    Enum.each(new_creds, fn {key, value} ->
      if is_binary(value), do: System.put_env(key, value)
    end)

    with :ok <- File.mkdir_p(dir),
         # Ensure all keys are strings for TOML serialization
         string_creds = stringify_credential_keys(merged),
         {:ok, toml} <- TomlElixir.encode(string_creds),
         {:ok, contents} <- ensure_trailing_newline(toml),
         :ok <- File.write(path, contents) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_credential_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp ensure_trailing_newline(content) when is_binary(content) do
    {:ok, String.trim_trailing(content) <> "\n"}
  end

  @doc """
  Returns the built-in application defaults map.

  Delegates to `EvoGit.Config.Schema.defaults/0` which defines the
  canonical defaults derived from the schema definitions. No default
  model or username is provided — those have nil defaults.
  """
  @spec defaults() :: map()
  def defaults do
    EvoGit.Config.Schema.defaults()
  end

  @doc """
  Returns the platform config directory path.

  Follows XDG conventions:
  - **Linux**: `$XDG_CONFIG_HOME/genesis` (defaults to `~/.config/genesis`)
  - **macOS**: `~/Library/Application Support/genesis`
  - **Windows**: `%APPDATA%/genesis` (defaults to `~/genesis`)
  """
  @spec config_dir() :: String.t()
  def config_dir do
    case EvoGit.Platform.os() do
      os when os in [:linux, :unknown] ->
        xdg = System.get_env("XDG_CONFIG_HOME")
        base = if xdg && xdg != "", do: xdg, else: Path.join(System.user_home!(), ".config")
        Path.join(base, "genesis")

      :macos ->
        Path.join([System.user_home!(), "Library", "Application Support", "genesis"])

      :windows ->
        appdata = System.get_env("APPDATA")
        base = if appdata && appdata != "", do: appdata, else: System.user_home!()
        Path.join(base, "genesis")
    end
  end

  @doc """
  Returns the legacy config directory path (using the old "evogit" segment).

  Used as a fallback when the new "genesis" config directory does not contain a
  `config.toml`, preserving backwards compatibility for existing users.
  """
  @spec legacy_config_dir() :: String.t()
  def legacy_config_dir do
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

  @doc """
  Returns whether the web search tool is enabled and fully configured.

  Checks both the config flag AND that the required API key environment
  variable is actually set. Both must be true for search to work.
  """
  @spec tools_search_enabled?() :: boolean()
  def tools_search_enabled? do
    config = resolve()
    
    case get_in(config, [:tools, :search, :enabled]) do
      true ->
        provider = get_in(config, [:tools, :search, :provider]) || :tavily
        default_env_var =
          get_in(config, [:tools, :search, :tavily, :api_key_env_var]) || "TAVILY_API_KEY"

        api_key_env_var =
          get_in(config, [:tools, :search, provider, :api_key_env_var]) || default_env_var
        
        key = System.get_env(api_key_env_var)
        key != nil and key != ""
      
      _ -> false
    end
  end

  # --- Private Helpers ---

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
  # Uses `String.to_existing_atom/1` to prevent atom-table DoS.
  # Unknown keys are kept as strings.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key = safe_atomize(key)
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
