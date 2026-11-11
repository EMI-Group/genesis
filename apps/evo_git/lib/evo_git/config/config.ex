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
      default_llm_max_concurrency = 3
      max_tool_concurrency = 8   # default = detected CPU thread count
      agent_max_retries = 3
      max_agent_depth = 8
      max_retries = 15
      max_turns = 128
      max_turns_root = 1000

      [llm]
      # REQUIRED: LLM model identifier (format: "provider:model")
      # Example models:
      # - "anthropic:claude-sonnet-4-20250514"
      # - "google:gemini-2.0-flash-exp"
      # - "zai:glm-5.1"
      model = "your-model-here"
      tool_result_pruning = true                  # Stage-1 model-free pruning of old tool results
      tool_result_pruning_target_fraction = 0.5   # Stage-1 pruning target, fraction of the context window
      # Optional model profile — the profile's context window drives the
      # context-compression threshold.
      # [[llm.models]]
      # id = "default"
      # model = "your-model-here"
      # context_window = 200_000               # optional; default 200_000
      # compression_threshold_tokens = 150_000 # optional EXPLICIT override; default nil = derived from context_window

      [user]
      github_username = "your-username"

      [sandbox]
      mode = "auto"  # "auto" | "enabled" | "disabled"

      [sandbox.resources]
      # Slice-level limits (aggregate across all sandboxed processes)
      cpu_quota = "800%"       # default = detected CPU thread count × 100%
      cpu_weight = 30          # CPU allocation weight (1-10000)
      memory_max = "16G"       # Total memory limit (e.g., "16G", "8G")
      tasks_max = 8196         # Max tasks/processes across the slice

      [sandbox.process]
      # Per-process limits (applied to each tool call)
      cpu_quota = "800%"       # default = detected CPU thread count × 100%
      memory_max = "12G"       # Memory limit per process
      limit_nofile = 65536     # Max open file descriptors
      oom_score_adjust = 1000  # OOM killer preference (-1000 to 1000)

      [sandbox.linux]
      # Toggle individual systemd-run security features. All default to true.
      # Disable features that your systemd version does not support.
      # protect_system = true           # ProtectSystem=strict (v214+)
      # protect_home = true             # ProtectHome=read-only (v214+)
      # protect_kernel_tunables = true  # ProtectKernelTunables=yes (v218+)
      # protect_control_groups = true   # ProtectControlGroups=yes (v214+)
      # system_call_filter = true       # SystemCallFilter=~ @clock @module ... (v214+)
      # no_new_privileges = true        # NoNewPrivileges=yes (v214+)
      # private_pids = false            # PrivatePIDs=yes (v239+)
      # protect_proc = false            # ProtectProc=invisible (v247+)

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
      listen_port = 9999

      [data]
      # Optional: relocate the runtime data/state directory (tasks.sqlite,
      # logs, caches) to an absolute path (or ~/ home-relative path).
      # Absent/nil = platform default ($XDG_DATA_HOME/genesis or equivalent).
      # Takes effect at next boot.
      dir = "/abs/path/to/data"

      [tools.search]
      enabled = false   # Enable web search tool for agents
      # provider = "tavily"           # Search service provider
      # tavily.api_key_credential_key = "TAVILY_API_KEY"  # credential key for API key
      # tavily.base_url = "https://api.tavily.com/search"
      # tavily.search_depth = "basic"  # "basic" | "advanced"
      # tavily.max_results = 10        # 1-50
      # tavily.timeout = 60000         # milliseconds
      # tavily.max_bytes = 16384       # max output bytes
      # perplexity.api_key_credential_key = "PERPLEXITY_API_KEY"
      # perplexity.base_url = "https://api.perplexity.ai/chat/completions"
      # perplexity.search_depth = "basic"
      # perplexity.model = "sonar"
      # exa.api_key_credential_key = "EXA_API_KEY"
      # exa.base_url = "https://api.exa.ai/search"
      # bing.api_key_credential_key = "BING_SEARCH_API_KEY"
      # bing.base_url = "https://api.bing.microsoft.com/v7.0/search"
      # brave.api_key_credential_key = "BRAVE_SEARCH_API_KEY"
      # brave.base_url = "https://api.search.brave.com/res/v1/web/search"

  ## Credentials File Format (credentials.toml)

      # API keys as environment variable names — they are loaded by the runtime
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

  # Optional extra keys a [[llm.models]] profile may carry beyond the schema's
  # key paths. Model profiles are untyped maps, so `safe_atomize/1`'s
  # `String.to_existing_atom/1` can only convert these TOML keys when the atom
  # already exists — this module attribute makes the atoms part of this
  # module's literal table, which is loaded before any user TOML is atomized.
  @model_profile_extra_keys [:context_window]

  # --- Public API ---

  @doc false
  # The atoms in `@model_profile_extra_keys`, exposed so the attribute is read
  # (keeping the literal atoms in the compiled module).
  def __model_profile_extra_keys__, do: @model_profile_extra_keys

  # Test-only helpers to access private pipeline steps. Underscore-prefixed
  # to signal they are internal and not part of the public contract.
  @doc false
  def __atomize_enum_values__(config), do: atomize_enum_values(config)

  @doc false
  def __migrate_llm_models__(config), do: migrate_llm_models(config)

  @doc false
  def __strip_flat_llm_fields__(config), do: strip_flat_llm_fields(config)

  @doc false
  def __stringify_keys__(config), do: stringify_keys(config)

  @doc false
  def __deep_merge__(base, override), do: deep_merge(base, override)

  @doc """
  Returns the fully merged configuration map (defaults + user config).

  Runtime overrides are NOT included here — those are managed by
  `AgentScheduler` and applied at the scheduler level.
  """
  @spec resolve() :: map()
  def resolve do
    config = resolve_user_config(user_config())

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

  defp resolve_user_config(user_config) do
    defaults()
    |> deep_merge(atomize_keys(user_config))
    |> atomize_enum_values()
    |> migrate_llm_models()
  end

  defp atomize_enum_values(config) when is_map(config) do
    Enum.reduce(config, config, fn
      # Sandbox mode: "auto" | "enabled" | "disabled" -> :auto | :enabled | :disabled
      {:sandbox, sandbox_config}, acc when is_map(sandbox_config) ->
        mode = Map.get(sandbox_config, :mode)
        new_mode = atomize_if_string(mode, [:auto, :enabled, :disabled])
        acc = put_in(acc, [:sandbox, :mode], new_mode)

        # Sandbox backend: "auto" | "systemd" | "bwrap" -> :auto | :systemd | :bwrap
        backend = Map.get(sandbox_config, :backend)
        new_backend = atomize_if_string(backend, [:auto, :systemd, :bwrap])
        put_in(acc, [:sandbox, :backend], new_backend)

      # Git CoW worktree creation: "auto" | "enabled" | "disabled" -> :auto | :enabled | :disabled
      {:git, git_config}, acc when is_map(git_config) ->
        cow = Map.get(git_config, :cow_worktree_creation)
        new_cow = atomize_if_string(cow, [:auto, :enabled, :disabled])
        put_in(acc, [:git, :cow_worktree_creation], new_cow)

      # Tmp directory mode: "system" | "custom" | "per_repo" -> :system | :custom | :per_repo
      {:tmp, tmp_config}, acc when is_map(tmp_config) ->
        mode = Map.get(tmp_config, :mode)
        new_mode = atomize_if_string(mode, [:system, :custom, :per_repo])
        put_in(acc, [:tmp, :mode], new_mode)

      # LLM model normalization:
      # 1. Flat [llm].model map → normalize to string or atomized map
      # 2. [[llm.models]] → normalize model maps in each profile; strings pass through
      {:llm, llm_config}, acc when is_map(llm_config) ->
        # Normalize the flat model (backward compat). Map model specs are
        # normalized to string or atomized map; strings pass through as-is.
        acc =
          case Map.get(llm_config, :model) do
            model when is_map(model) ->
              put_in(acc, [:llm, :model], normalize_model_map(model))

            _ ->
              acc
          end

        # Provider profiles (including nested model/option maps) deliberately
        # use string keys, independent of which atoms have been loaded.
        # Keep malformed entries intact so schema validation can report them.
        acc =
          case Map.fetch(llm_config, :providers) do
            {:ok, providers} ->
              put_in(
                acc,
                [:llm, :providers],
                EvoGit.Config.Schema.ProviderProfiles.Normalize.stringify(providers)
              )

            :error ->
              acc
          end

        # Normalize each legacy profile's model map in the models list.
        # Defensive: skip non-map entries (e.g. `models = "foo"`) — the
        # schema validator reports the type error.
        case Map.get(llm_config, :models) do
          models when is_list(models) ->
            normalized_models =
              Enum.map(models, fn
                profile when is_map(profile) ->
                  profile = normalize_profile_keys(profile)

                  case Map.get(profile, :model) do
                    model when is_map(model) ->
                      Map.put(profile, :model, normalize_model_map(model))

                    _ ->
                      profile
                  end

                _non_map_profile ->
                  %{}
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
          providers = EvoGit.Config.Schema.Definitions.search_providers()
          provider = Map.get(search_config, :provider)
          new_provider = atomize_if_string(provider, providers)
          acc = put_in(acc, [:tools, :search, :provider], new_provider)

          # Atomize each provider section's search_depth generically — the
          # provider list comes from the schema (single source of truth).
          Enum.reduce(providers, acc, fn prov, acc ->
            provider_config = Map.get(search_config, prov, %{})

            if is_map(provider_config) do
              search_depth = Map.get(provider_config, :search_depth)
              new_depth = atomize_if_string(search_depth, [:basic, :advanced])
              put_in(acc, [:tools, :search, prov, :search_depth], new_depth)
            else
              acc
            end
          end)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  # Canonical providers take precedence without materializing runtime mirrors.
  # Otherwise preserve legacy [[llm.models]] profiles verbatim, or migrate a
  # flat model into a single "default" profile with the original flat fields.
  #
  # Defensive against malformed config: if `:llm` or `:scheduler` is not a map
  # (e.g. user wrote `llm = "claude"` — a scalar — instead of a `[llm]` table),
  # we treat it as an empty section. The deep_merge in resolve/0 already
  # discards such type mismatches at the top level, but this guard provides
  # defense-in-depth for direct/test callers.
  defp migrate_llm_models(config) when is_map(config) do
    raw_llm = Map.get(config, :llm, %{})
    llm = if is_map(raw_llm), do: raw_llm, else: %{}
    # Canonical providers are authoritative. LLM.model_profiles/1 supplies their
    # legacy-compatible runtime projection lazily; do not materialize that
    # derived projection here or reinterpret stale legacy mirrors as accounts.
    if canonical_providers?(llm) do
      Map.put(config, :llm, llm)
    else
      migrate_legacy_llm_models(config, llm)
    end
  end

  defp canonical_providers?(llm) do
    case get_key(llm, :providers) do
      providers when is_list(providers) and providers != [] -> true
      _ -> false
    end
  end

  defp migrate_legacy_llm_models(config, llm) do
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
            []
          else
            [EvoGit.Config.Schema.LLM.build_legacy_default_profile(config)]
          end
      end

    # Ensure the flat [llm].model mirrors the default profile's model for
    # backward compatibility (Config.resolve([:llm, :model]) still works).
    # Defensive: the first profile may lack a :model key (e.g. a manually
    # edited config.toml or an incomplete dashboard profile). Use Map.get
    # so we don't crash on such profiles — the flat field is simply left
    # unchanged when the first profile has no model.
    llm =
      case models do
        [first | _] when is_map(first) ->
          case Map.get(first, :model) do
            nil -> llm
            default_model -> Map.put(llm, :model, default_model)
          end

        _ ->
          llm
      end

    put_in(config, [:llm], Map.put(llm, :models, models))
  end

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
  # an atom. Produces LLMDB-compatible output instead of a plain map:
  #   - Simple models (only :provider + :id) → "provider:id" string
  #   - Models with override keys (:base_url, :extra, etc.) → atomized map
  #     (returned as-is so ReqLLM.model/1's map clause handles overrides correctly)
  # req_llm's ReqLLM.model/1 natively resolves both formats through LLMDB for
  # cost tracking and model metadata.
  defp normalize_model_map(model) when is_map(model) do
    # Ensure atom keys (atomize_keys may have left string keys if the atom
    # didn't exist yet — e.g. "base_url").
    atomized =
      Map.new(model, fn
        {key, value} when is_binary(key) -> {safe_atomize(key), value}
        {key, value} -> {key, value}
      end)

    # Convert the provider VALUE to an atom if it's a string.
    atomized =
      case Map.get(atomized, :provider) do
        provider when is_binary(provider) -> Map.put(atomized, :provider, safe_atomize(provider))
        _ -> atomized
      end

    provider = Map.get(atomized, :provider)
    id = Map.get(atomized, :id)

    # Collect override keys (anything beyond :provider and :id).
    override_keys = Map.keys(atomized) -- [:provider, :id]

    if provider != nil and id != nil and override_keys == [] do
      # Simple model: format as "provider:id" string (resolved through LLMDB).
      "#{provider}:#{id}"
    else
      # Model with overrides (keep as atomized map so ReqLLM.model/1's map
      # clause handles base_url and other overrides correctly) OR a defensive
      # fallback for missing provider/id (the schema validator reports the error).
      atomized
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
      #=> %{default_llm_max_concurrency: 3, max_tool_concurrency: 8, ...}

      Config.resolve([:scheduler, :default_llm_max_concurrency])
      #=> 3

      Config.resolve([:llm, :model])
      #=> "zai:glm-5" (or nil if not configured)
  """
  @spec resolve(atom() | [atom()]) :: term()
  def resolve(key) when is_atom(key) do
    Map.get(resolve(), key) || Map.get(EvoGit.Config.Schema.defaults(), key)
  end

  def resolve(path) when is_list(path) do
    case EvoGit.Config.Schema.safe_get_in(resolve(), path) do
      nil -> get_in(EvoGit.Config.Schema.defaults(), path)
      value -> value
    end
  end

  @doc """
  Reads and returns the parsed user config TOML file.

  Returns `%{}` if the file is not found or cannot be parsed.

  The parsed map is cached in `:persistent_term` keyed by file path and
  validated against `File.stat` mtime+size on every call, so external edits
  to `config.toml` are picked up automatically. See `cached_file_read/2`.
  """
  @spec user_config() :: map()
  def user_config do
    path = config_path()
    cached_file_read(path, fn -> read_toml_file(path, %{}, description: "config") end)
  end

  @doc """
  Strictly re-reads configuration and credentials before a runtime reload.

  Unlike the tolerant startup reader, rejects unreadable or malformed files
  and invalid schema values. Refreshes the file caches even for same-second,
  same-size edits. Errors name the file or invalid keys without its contents.
  Missing files are allowed, as with startup. Does not update the scheduler.
  """
  @spec reload() :: {:ok, map()} | {:error, String.t()}
  def reload do
    with {:ok, user_config} <- read_reload_file(config_path()),
         {:ok, creds} <- read_reload_file(credentials_path()),
         :ok <- validate_reload_tables(atomize_keys(user_config), defaults(), []) do
      config = resolve_user_config(user_config)

      case EvoGit.Config.Schema.validate(config) do
        {:ok, _} ->
          invalidate_file_cache(config_path())
          invalidate_file_cache(credentials_path())
          _ = load_credentials(creds)
          {:ok, config}

        {:error, errors} ->
          keys = Enum.map_join(errors, ", ", &Enum.join(&1.key_path, "."))
          {:error, "Invalid configuration in #{config_path()}: #{keys}."}
      end
    end
  end

  # The tolerant merge retains default tables when given a scalar override.
  # Strict reload must reject that shape before the original value is lost.
  defp validate_reload_tables(config, defaults, path) do
    Enum.reduce_while(config, :ok, fn {key, value}, :ok ->
      default = Map.get(defaults, key)

      result =
        cond do
          path ++ [key] == [:llm, :models] and not is_list(value) ->
            {:error, "Expected an array of model tables at llm.models in #{config_path()}."}

          is_map(default) and is_map(value) ->
            validate_reload_tables(value, default, path ++ [key])

          is_map(default) ->
            {:error, "Expected a table at #{Enum.join(path ++ [key], ".")} in #{config_path()}."}

          true ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp read_reload_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case TomlElixir.decode(contents) do
          {:ok, config} -> {:ok, config}
          {:error, _} -> {:error, "Invalid TOML in #{path}."}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}."}
    end
  end

  @doc false
  def read_toml_file(path, default, opts \\ []) do
    description = Keyword.get(opts, :description, Path.basename(path))

    case File.read(path) do
      {:ok, contents} ->
        case TomlElixir.decode(contents) do
          {:ok, data} ->
            data

          {:error, reason} ->
            Logger.warning("Failed to parse #{description} at #{path}: #{inspect(reason)}")
            default
        end

      {:error, reason} ->
        Logger.warning("Failed to read #{description} at #{path}: #{inspect(reason)}")
        default
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
             config = strip_flat_llm_fields(config),
             string_config = stringify_keys(config),
             {:ok, toml} <- TomlElixir.encode(string_config),
             :ok <- File.write(path, toml) do
          # Explicit invalidation: the mtime+size check would eventually
          # catch the rewrite, but erasing now covers coarse-mtime
          # filesystems and same-second same-size rewrites.
          invalidate_file_cache(path)
          :ok
        end
    end
  end

  # Canonical providers own all account/model settings; their legacy runtime
  # projection and flat mirrors must never become a second persisted inventory.
  # Legacy-only configs keep the established [[llm.models]] save format.
  @flat_llm_gen_param_keys ~w(model temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty)a
  @canonical_llm_mirror_keys @flat_llm_gen_param_keys ++
                               [:models, :auth_mode, :oauth_file, :provider_options]

  defp strip_flat_llm_fields(config) when is_map(config) do
    llm = get_key(config, :llm)

    case llm do
      llm when is_map(llm) ->
        models = get_key(llm, :models)

        keys =
          cond do
            canonical_providers?(llm) -> @canonical_llm_mirror_keys
            is_list(models) and models != [] -> @flat_llm_gen_param_keys
            true -> []
          end

        stripped_llm =
          Enum.reduce(keys, llm, fn key, acc ->
            acc
            |> Map.delete(key)
            |> Map.delete(Atom.to_string(key))
          end)

        put_key(config, :llm, stripped_llm)

      _ ->
        config
    end
  end

  # Reads a key from a map, checking both the atom and string forms.
  defp get_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # Puts a key into a map, preserving the original key type when possible.
  defp put_key(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)) and not Map.has_key?(map, key) do
      Map.put(map, Atom.to_string(key), value)
    else
      Map.put(map, key, value)
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

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(nil), do: nil

  defp stringify_keys({provider, opts}) when is_atom(provider) and is_list(opts) do
    stringify_model_tuple({provider, opts})
  end

  defp stringify_keys(value), do: value

  # Convert an LLMDB-compatible model tuple back to a map for TOML serialization.
  # {:provider, [id: "x", base_url: "..."]} → %{"provider" => "provider", "id" => "x", ...}
  defp stringify_model_tuple({provider, opts}) when is_atom(provider) and is_list(opts) do
    Enum.reduce(opts, %{"provider" => Atom.to_string(provider)}, fn {key, value}, acc ->
      key_str = if is_atom(key), do: Atom.to_string(key), else: key
      Map.put(acc, key_str, stringify_keys(value))
    end)
  end

  @doc """
  Returns the status of critical configuration values.

  Checks for required settings and returns a map with:
  - `:missing` — list of missing critical config keys (as atoms)
  - `:warnings` — list of human-readable warning messages for missing values
  - `:ok?` — boolean, true if all critical config is present and validation succeeds
  - `:validation_errors` — list of `EvoGit.Config.Schema.ValidationError` structs from
    this invocation's initial `resolve/0` call, or empty list if none

  The `:api_key` check is OAuth-aware: it passes when an API key is configured
  OR when at least one configured model profile authenticates through a
  subscription (OAuth) credential that actually resolves — a subscription-only
  setup must never be reported as "missing an API key". When it does fail and
  OAuth profile(s) are configured, the warning names the vendor login step
  (`EvoGit.Auth.login_instructions/1`) and the per-profile managed credential
  file resolved by `EvoGit.Config.Schema.LLM.oauth_file_for/1` instead of only
  the generic API-key text — or,
  when the vendor login exists but the managed file could not be written, the
  writable-path remedy from `EvoGit.Auth.managed_file_unwritable_remedy/2`
  (the login step needs no repeat).
  """
  @spec config_status() :: %{
          missing: [atom()],
          warnings: [String.t()],
          ok?: boolean(),
          validation_errors: [EvoGit.Config.Schema.ValidationError.t()]
        }
  def config_status do
    resolved = resolve()
    # Later health checks may resolve again and overwrite the process-local errors.
    validation_errors = Process.get(:evo_git_config_validation_errors, [])
    profiles = EvoGit.Config.Schema.model_profiles(resolved)

    checks = [
      {:llm_model, "LLM model is not configured. Set [llm] model in config.toml.",
       fn ->
         # Check that at least one model profile has a non-nil/non-empty model
         has_model =
           Enum.any?(profiles, fn profile ->
             case Map.get(profile, :model) do
               model when is_binary(model) and model != "" ->
                 true

               model when is_map(model) ->
                 map_size(model) > 0 and
                   Map.get(model, :provider) != nil and
                   is_binary(Map.get(model, :id)) and Map.get(model, :id) != ""

               _ ->
                 false
             end
           end)

         not has_model
       end},
      {:api_key, fn -> api_key_warning(profiles) end,
       fn ->
         not api_key_ok?(profiles, resolved)
       end},
      {:search_api_key, "Web search is enabled but the API key is not configured.",
       fn ->
         # Use safe_get_in (safe accessor) instead of get_in: if a user wrote
         # `tools = "string"` instead of a [tools] table, get_in would crash
         # because strings don't implement Access.
         tools_search_enabled?() == false and
           EvoGit.Config.Schema.safe_get_in(resolved, [:tools, :search, :enabled]) == true
       end}
    ]

    # Evaluate each check once, collecting {key, message} pairs for failing
    # checks. A check's message may be a 0-arity fun when it depends on the
    # config state (the :api_key warning names the vendor login step for an
    # OAuth profile, and stays byte-identical otherwise).
    failing =
      for {key, msg, check} <- checks, check.() do
        {key, if(is_function(msg, 0), do: msg.(), else: msg)}
      end

    %{
      missing: Enum.map(failing, &elem(&1, 0)),
      warnings: Enum.map(failing, &elem(&1, 1)),
      ok?: failing == [] and validation_errors == [],
      validation_errors: validation_errors
    }
  end

  # The generic API-key warning — kept byte-identical for a config with no OAuth
  # profile, so the well-known message never changes out from under the UI.
  @missing_api_key_warning "No API key found. Add keys to credentials.toml or configure via the settings page."

  # The :api_key check passes when an API key is configured OR when at least one
  # configured model profile authenticates through a subscription (OAuth)
  # credential that resolves. Everything here is fault-isolated (see
  # `EvoGit.Config.Schema.LLM.oauth_credential_status/1`): a broken or missing
  # auth file degrades to "not configured", never raises.
  defp api_key_ok?(profiles, config) do
    api_key_present?(credentials()) or provider_api_key_present?(config) or
      oauth_credentials_resolve?(profiles)
  end

  defp provider_api_key_present?(config) do
    config
    |> EvoGit.Config.Schema.provider_profiles()
    |> Enum.any?(fn profile ->
      case {profile["auth_mode"], profile["api_key_env_var"]} do
        {"api_key", name} when is_binary(name) and name != "" ->
          case System.get_env(name) do
            value when is_binary(value) and value != "" ->
              true

            _ ->
              value = Map.get(credentials(), name)
              is_binary(value) and value != ""
          end

        _ ->
          false
      end
    end)
  end

  defp api_key_warning(profiles) do
    case oauth_providers(profiles) do
      [] ->
        @missing_api_key_warning

      providers ->
        "No API key found and no usable subscription (OAuth) credential for " <>
          Enum.map_join(providers, ", ", &to_string/1) <>
          ". " <>
          oauth_failure_detail(providers, profiles) <>
          managed_oauth_file_line(profiles)
    end
  end

  # The managed OAuth credential file(s) named in the warning. They are resolved
  # from the configured OAuth profiles (the file is a per-profile setting, there
  # is no global override), falling back to the default `<config_dir>/auth.json`.
  defp managed_oauth_file_line(profiles) do
    case managed_oauth_files(profiles) do
      [path] -> "\nManaged OAuth file: #{path}"
      paths -> "\nManaged OAuth files: #{Enum.join(paths, ", ")}"
    end
  end

  defp managed_oauth_files(profiles) do
    paths =
      profiles
      |> oauth_profiles()
      |> Enum.map(&EvoGit.Config.Schema.LLM.oauth_file_for/1)
      |> Enum.uniq()

    if paths == [], do: [EvoGit.Auth.default_oauth_file()], else: paths
  end

  # The detail clause of the OAuth-aware warning. When a managed file could not
  # be written the vendor login DOES exist, so repeating the login instructions
  # would be wrong advice — the remedy (path + cause + writable location) takes
  # their place.
  defp oauth_failure_detail(providers, profiles) do
    case managed_file_failure(profiles) do
      nil ->
        providers
        |> Enum.map(&EvoGit.Auth.login_instructions/1)
        |> Enum.map_join("\n", &String.trim/1)

      remedy ->
        remedy
    end
  end

  # The first OAuth profile whose managed credential file could not be written,
  # rendered as its remedy. `oauth_credential_status/1` is fault-isolated and
  # its only side effect is the (idempotent) lazy import.
  defp managed_file_failure(profiles) do
    profiles
    |> oauth_profiles()
    |> Enum.find_value(fn profile ->
      case EvoGit.Config.Schema.LLM.oauth_credential_status(profile) do
        {:error, {:managed_file_unwritable, _} = error} ->
          EvoGit.Auth.managed_file_unwritable_remedy(
            error,
            EvoGit.Config.Schema.LLM.oauth_file_for(profile)
          )

        _other ->
          nil
      end
    end)
  end

  # Configured model profiles that authenticate through a subscription.
  defp oauth_profiles(profiles) do
    Enum.filter(profiles, &EvoGit.Config.Schema.LLM.oauth_profile?/1)
  end

  # The distinct OAuth providers behind those profiles, normalized so an
  # `:openai` model reports the same login step as `:openai_codex`.
  defp oauth_providers(profiles) do
    profiles
    |> oauth_profiles()
    |> Enum.map(&EvoGit.Config.Schema.LLM.provider_from_model(Map.get(&1, :model)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&EvoGit.Auth.normalize_provider/1)
    |> Enum.uniq()
  end

  defp oauth_credentials_resolve?(profiles) do
    profiles
    |> oauth_profiles()
    |> Enum.any?(&match?({:ok, _}, EvoGit.Config.Schema.LLM.oauth_credential_status(&1)))
  end

  @doc """
  Returns `true` if any known provider API key is present.

  A key counts as "present" if it is stored in ReqLLM's key store via
  `ReqLLM.put_key/2` OR present as a non-nil, non-empty-string value in
  the given `creds` map (parsed from `credentials.toml`, which uses string keys).
  """
  @spec api_key_present?(map()) :: boolean()
  def api_key_present?(creds) do
    providers = EvoGit.Config.LLMCatalog.known_credential_keys()

    Enum.any?(providers, fn var ->
      reqllm_key_set?(var) or cred_set?(creds, var)
    end)
  end

  defp reqllm_key_set?(var) do
    reqllm_key = credential_key_to_reqllm_key(var)
    not is_nil(reqllm_key) and ReqLLM.get_key(reqllm_key) != nil
  end

  defp cred_set?(creds, var) do
    case Map.get(creds, var) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc """
  Reads and returns the parsed credentials TOML file.

  Returns `%{}` if the file is not found or cannot be parsed.

  Cached like `user_config/0` (persistent_term + `File.stat` mtime/size
  validation). The ReqLLM `put_key` side effects in `read_credentials_file/1`
  run only on an actual file read (cache miss) — on a cache hit the keys were
  already loaded at first read, and `save_credentials/1` sets them explicitly.
  """
  @spec credentials() :: map()
  def credentials do
    path = credentials_path()
    cached_file_read(path, fn -> read_credentials_file(path) end)
  end

  defp read_credentials_file(path) when is_binary(path) do
    path
    |> read_toml_file(%{}, description: "credentials")
    |> load_credentials()
  end

  defp load_credentials(creds) do
    Enum.each(creds, fn {key, value} ->
      if is_binary(value) and value != "" do
        # Set via ReqLLM for immediate in-process effect.
        if key_atom = credential_key_to_reqllm_key(key) do
          ReqLLM.put_key(key_atom, value)
        end
      end
    end)

    creds
  end

  @doc """
  Derives a ReqLLM atom key from a credential key name.

  Strips the `_API_KEY` or `_api_key` suffix, downcases, and appends
  `_api_key`. Returns `nil` if the credential key does not end with a
  recognized suffix.
  """
  def credential_key_to_reqllm_key(credential_key) when is_binary(credential_key) do
    # Derive from credential key name: strip _API_KEY or _api_key suffix, downcase,
    # append _api_key. The config file is a trusted source, so String.to_atom/1
    # is safe here.
    base =
      case String.replace_suffix(credential_key, "_API_KEY", "") do
        result when result != credential_key -> result
        _ -> String.replace_suffix(credential_key, "_api_key", "")
      end

    if base != "" and base != credential_key do
      String.to_atom("#{String.downcase(base)}_api_key")
    end
  end

  @doc """
  Saves credential key-value pairs to the credentials TOML file.

  Takes a map of `%{"ENV_VAR_NAME" => "api_key_value"}` (string keys).
  Deep merges the new credentials into any existing ones (new values override)
  and writes the merged map to `credentials.toml`.

  Creates the credentials file if it doesn't exist yet.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec save_credentials(map()) :: :ok | {:error, term()}
  def save_credentials(new_creds) when is_map(new_creds) do
    path = credentials_path()
    dir = config_dir()

    existing = credentials()

    # New credentials override existing ones with the same key.
    merged = Map.merge(existing, new_creds)

    # Set each new key-value pair via ReqLLM for immediate in-process effect.
    # This guarantees the keys are usable in the current session even if
    # persistence to disk fails (e.g., Windows path issues).
    Enum.each(new_creds, fn {key, value} ->
      if is_binary(value) and value != "" do
        # Set via ReqLLM for immediate in-process effect.
        if key_atom = credential_key_to_reqllm_key(key) do
          ReqLLM.put_key(key_atom, value)
        end
      end
    end)

    with :ok <- File.mkdir_p(dir),
         # Ensure all keys are strings for TOML serialization
         string_creds = stringify_credential_keys(merged),
         {:ok, toml} <- TomlElixir.encode(string_creds),
         {:ok, contents} <- ensure_trailing_newline(toml),
         :ok <- File.write(path, contents) do
      invalidate_file_cache(path)
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

  @doc false
  def ensure_trailing_newline(content) when is_binary(content) do
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

  Delegates to `EvoGit.Platform.config_dir/1`.
  """
  @spec config_dir() :: String.t()
  def config_dir do
    EvoGit.Platform.config_dir("genesis")
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

  Checks both the config flag AND that the required API key is configured
  via ReqLLM. Both must be true for search to work.
  """
  @spec tools_search_enabled?() :: boolean()
  def tools_search_enabled? do
    config = resolve()

    case get_in(config, [:tools, :search, :enabled]) do
      true ->
        provider = get_in(config, [:tools, :search, :provider]) || :tavily

        default_credential_key =
          get_in(config, [:tools, :search, :tavily, :api_key_credential_key]) || "TAVILY_API_KEY"

        api_key_credential_key =
          get_in(config, [:tools, :search, provider, :api_key_credential_key]) ||
            default_credential_key

        reqllm_key = credential_key_to_reqllm_key(api_key_credential_key)

        if is_nil(reqllm_key) do
          false
        else
          key = ReqLLM.get_key(reqllm_key)
          key != nil and key != ""
        end

      _ ->
        false
    end
  end

  @doc """
  Returns whether the `lsp` tool is enabled and configured.

  This is the SINGLE gate for offering the `lsp` tool at all: while it is
  `false` (the default) the tool is not offered to ANY agent — no schema is
  built and no prompt tokens are spent on it. The tool reappears in every
  agent's tool list only once the `[lsp]` section sets `enabled = true` AND
  a non-empty `command`.

  Tolerance/never raises: the section is resolved through `resolve/1` (so
  schema defaults apply when `[lsp]` is absent) and a nil/non-map section,
  an `enabled` value other than `true`/`"true"`, and a nil/non-binary/blank
  `command` all yield `false`.
  """
  @spec lsp_enabled?() :: boolean()
  def lsp_enabled? do
    case resolve([:lsp]) do
      %{} = config ->
        enabled = Map.get(config, :enabled)
        command = Map.get(config, :command)

        enabled in [true, "true"] and is_binary(command) and String.trim(command) != ""

      _other ->
        false
    end
  end

  # --- Private Helpers ---

  # Deep merges two maps. `override` values take precedence.
  # Only merges maps; non-map values in `override` replace defaults.
  #
  # Type-mismatch safety: if the override value is a non-map but the default
  # value at that key is a map (e.g. user wrote `llm = "claude"` — a string —
  # instead of a `[llm]` table), the user value is a type error. We discard it
  # and keep the default (the schema validator will report the error). This
  # prevents the downstream pipeline from crashing on `Map.get/3` against a
  # string. The reverse — user has a map where a default is a leaf — is fine
  # and uses the user value.
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      cond do
        is_map(base_val) and is_map(override_val) ->
          deep_merge(base_val, override_val)

        is_map(base_val) and not is_map(override_val) ->
          # Type mismatch: default is a map but user gave a leaf value
          # (e.g. `llm = "x"` instead of `[llm]`). Keep the default — the
          # wrong user value would crash downstream map operations.
          base_val

        true ->
          override_val
      end
    end)
  end

  defp deep_merge(base, _override) when is_map(base), do: base
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

  # --- File Caching (config.toml / credentials.toml) ---

  # Caches the parsed content of a config file in `:persistent_term`, keyed by
  # file path, storing `{mtime, size, parsed_map}`. Every call stats the file
  # (cheap) and only reuses the cache entry when BOTH mtime and size match, so
  # external edits are picked up automatically. Cache misses run `reader` (the
  # read + TOML-decode step) and store its result — including the
  # default-on-parse-failure case, so a corrupt-file warning is not re-emitted
  # on every call until the file changes.
  #
  # Only `user_config/0` and `credentials/0` use this. `read_toml_file/3` is
  # deliberately NOT cached here — it is also used for `genesis.toml` and
  # `remote_connections.toml`, which must stay fresh.
  defp cached_file_read(path, reader) when is_binary(path) do
    case File.stat(path) do
      {:ok, stat} ->
        case :persistent_term.get(file_cache_key(path), :not_cached) do
          {mtime, size, parsed} when mtime == stat.mtime and size == stat.size ->
            parsed

          _ ->
            parsed = reader.()
            :persistent_term.put(file_cache_key(path), {stat.mtime, stat.size, parsed})
            parsed
        end

      {:error, _} ->
        # Missing or unreadable file — same result as the old File.exists? gate.
        %{}
    end
  end

  defp file_cache_key(path) when is_binary(path) do
    {__MODULE__, :file_cache, path}
  end

  defp invalidate_file_cache(path) when is_binary(path) do
    :persistent_term.erase(file_cache_key(path))
  end
end
