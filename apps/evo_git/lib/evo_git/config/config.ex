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
      # keenable.api_key_credential_key = "KEENABLE_API_KEY"
      # keenable.base_url = "https://api.keenable.ai/v1/search"
      # The Keenable API key is OPTIONAL: with no key configured, Keenable
      # falls back to its keyless public endpoint (<base_url>/public).

  ## Credentials File Format (credentials.toml)

      # API keys as environment variable names — they are loaded by the runtime
      GOOGLE_API_KEY = "AIza..."
      ZAI_API_KEY = "sk-..."
      DEEPSEEK_API_KEY = "sk-..."
      GROQ_API_KEY = "gsk_..."
      TAVILY_API_KEY = "tvly-..."
      # Optional — Keenable works without a key via its public endpoint.
      KEENABLE_API_KEY = "..."
      ANTHROPIC_API_KEY = "sk-ant-..."
      OPENAI_API_KEY = "sk-..."
  """

  require Logger

  alias EvoGit.Config.{Keys, Normalization, Settings}

  import Normalization,
    only: [
      atomize_enum_values: 1,
      migrate_llm_models: 1,
      deep_merge: 2,
      canonical_providers?: 1,
      get_key: 2
    ]

  @config_filename "config.toml"
  @credentials_filename "credentials.toml"

  # The SIWC registrations `EvoGit.Auth.ChatGPT.Store` keeps beside the config
  # (`<config_dir>/chatgpt/`). They carry no config.toml/credentials.toml
  # bytes, yet a login, logout or token refresh DOES change what the provider
  # profiles can do, so their signature is part of the snapshot fingerprint.
  @siwc_dirname "chatgpt"
  @siwc_host_id "host-id"
  @siwc_account_prefix "account-"

  # Optional extra keys a [[llm.models]] profile may carry beyond the schema's
  # key paths. Model profiles are untyped maps, so `safe_atomize/1`'s
  # `String.to_existing_atom/1` can only convert these TOML keys when the atom
  # already exists — this module attribute makes the atoms part of this
  # module's literal table, which is loaded before any user TOML is atomized.
  @model_profile_extra_keys [:context_window]

  @typedoc """
  Any value the config surface can hold: section maps, lists (model inventories,
  writable paths), atoms (normalized enums, booleans, `nil`) and scalars.
  """
  @type config_value :: map() | [config_value()] | atom() | String.t() | number()

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
  @spec __stringify_keys__(term()) :: term()
  def __stringify_keys__(config), do: stringify_keys(config)

  @doc false
  def __deep_merge__(base, override), do: deep_merge(base, override)

  @doc """
  Returns the fully merged configuration map (defaults + user config).

  Runtime overrides are NOT included here — those are managed by
  `AgentScheduler` and applied at the scheduler level.

  The value comes from the RAM snapshot in `EvoGit.Config.Cache` (built by
  `build_snapshot/1`), so this performs NO file I/O and NO schema validation;
  validation runs once per snapshot build and its errors ride along in the
  snapshot.
  """
  @spec resolve() :: map()
  def resolve do
    EvoGit.Config.Cache.get().resolved
  end

  @doc "Returns schema descriptors for every supported setting, in schema order."
  @spec list_settings() :: [EvoGit.Config.Schema.schema_map()]
  def list_settings, do: Settings.list_settings()

  @doc """
  Returns the snapshot's defaults plus persisted configuration, not scheduler overrides.

  The same value as `resolve/0` — one implementation, two readings: `resolve`
  answers "what does a runtime reader see", `show` answers "what is configured".
  Neither includes live scheduler runtime overrides.
  """
  @spec show() :: map()
  def show, do: resolve()

  @doc """
  Returns a snapshot value at an atom, dotted string or nonempty atom/string
  list path (including section paths), without creating atoms.

  Missing paths return `{:error, {:unknown_setting, path}}`; malformed paths
  return `{:error, :invalid_path}`.

  Compare `resolve/1`: for a MISSING path `resolve/1` answers the schema default
  (possibly `nil`), while `show/1` — the operator/settings read — answers an
  explicit `{:error, {:unknown_setting, path}}` so a typo is visible instead of
  silently reading a default. A path that exists and holds `nil` returns `nil`
  from both.
  """
  @spec show(atom() | String.t() | [atom() | String.t()]) ::
          config_value() | {:error, :invalid_path | {:unknown_setting, [String.t()]}}
  def show(path), do: Settings.show(path)

  @doc """
  Applies a partial settings map to the current persisted user configuration.

  Nested maps, dotted keys and atom/string list keys address schema settings.
  Unknown paths, malformed sections and colliding aliases are rejected before
  writing; list-valued settings (including provider inventories) replace the
  whole value, and nested provider keys remain strings.
  The complete candidate is normalized and validated with defaults, but only
  user data is saved, preserving unrelated and unknown existing keys.
  Returns the actual `:ok | {:error, reason}` validation/serialization/file
  result; refreshes the config snapshot but never reloads scheduler state.
  Like `save_user_config/1`, this read-modify-save operation is not atomic.
  """
  @spec update(map()) :: :ok | {:error, term()}
  def update(patch), do: Settings.update(patch)

  @doc false
  # Builds one complete config snapshot for `dir` from disk. This is the ONLY
  # place that reads `config.toml`/`credentials.toml`; `EvoGit.Config.Cache`
  # stores the result and every reader (including `resolve/0`) is a term
  # lookup afterwards.
  #
  # Deliberately does NOT call `resolve/0,1` (that would recurse through the
  # cache). ReqLLM credential side effects run here — on a build only, never on
  # a cache hit.
  @spec build_snapshot(String.t()) :: EvoGit.Config.Cache.snapshot()
  def build_snapshot(dir) when is_binary(dir) do
    config_path = Path.join(dir, @config_filename)
    credentials_path = Path.join(dir, @credentials_filename)

    config_bytes = read_raw_file(config_path)
    credentials_bytes = read_raw_file(credentials_path)

    user_config = decode_raw_file(config_bytes, config_path, "config")

    credentials =
      load_credentials(decode_raw_file(credentials_bytes, credentials_path, "credentials"))

    resolved = Normalization.resolve(user_config)

    validation_errors =
      case EvoGit.Config.Schema.validate(resolved) do
        {:ok, _validated} ->
          []

        {:error, errors} ->
          Enum.each(errors, fn err ->
            kp = Map.get(err, :key_path, [])
            msg = Map.get(err, :message, "unknown error")
            val = Map.get(err, :value, nil)

            Logger.warning(
              "Config validation error at #{inspect(kp)}: #{msg} (got: #{inspect(val)})"
            )
          end)

          errors
      end

    %{
      dir: dir,
      user_config: user_config,
      credentials: credentials,
      resolved: resolved,
      validation_errors: validation_errors,
      generation: 1,
      fingerprint: :erlang.phash2({config_bytes, credentials_bytes, siwc_auth_signature(dir)})
    }
  end

  # A TOTAL, cheap signature of this node's SIWC registrations: for every
  # `chatgpt/account-*.json` document and the `chatgpt/host-id` file, its
  # basename plus a hash of its bytes, sorted by basename.
  #
  # The registration BYTES (not the mtime) are what the signature folds, so
  # re-writing identical content — a model-list refresh, a re-install of the
  # same record — is a fingerprint no-op and never bumps the snapshot
  # generation. `registrations.sqlite3` is deliberately EXCLUDED: it is the
  # credential-free cross-VM write lock, and its churn must never look like a
  # config change.
  #
  # A missing/unreadable `chatgpt/` dir (the state before the first sign-in) is
  # simply an empty signature. Snapshots are built on an event only — never per
  # read — so this one `File.ls` + a couple of small reads cost nothing.
  defp siwc_auth_signature(dir) do
    case File.ls(Path.join(dir, @siwc_dirname)) do
      {:ok, names} ->
        names
        |> Enum.filter(&siwc_registration_file?/1)
        |> Enum.sort()
        |> Enum.map(&siwc_signature_entry(Path.join([dir, @siwc_dirname, &1])))

      {:error, _reason} ->
        []
    end
  end

  defp siwc_registration_file?(@siwc_host_id), do: true
  defp siwc_registration_file?(@siwc_account_prefix <> rest), do: String.ends_with?(rest, ".json")
  defp siwc_registration_file?(_name), do: false

  defp siwc_signature_entry(path) do
    name = Path.basename(path)

    case File.read(path) do
      {:ok, contents} -> {name, :erlang.phash2(contents)}
      {:error, _reason} -> {name, :unreadable}
    end
  end

  # Raw bytes of a config file, or `:missing` when it is absent/unreadable.
  # A missing file is NOT an error: the old read path silently yielded `%{}`
  # without logging, and that behaviour is preserved.
  defp read_raw_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> :missing
    end
  end

  defp decode_raw_file(:missing, _path, _description), do: %{}

  defp decode_raw_file(contents, path, description) when is_binary(contents) do
    case TomlElixir.decode(contents) do
      {:ok, data} ->
        data

      {:error, reason} ->
        Logger.warning("Failed to parse #{description} at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  # Credentials carry a side effect: every non-empty binary value is also put
  # into ReqLLM's key store so it is usable in this BEAM immediately.
  defp load_credentials(creds) when is_map(creds) do
    Enum.each(creds, fn {key, value} ->
      if is_binary(value) and value != "" do
        if key_atom = credential_key_to_reqllm_key(key) do
          ReqLLM.put_key(key_atom, value)
        end
      end
    end)

    creds
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

  A MISSING path answers the schema default (which is `nil` for a key with no
  default) and never an error — unlike `show/1`, which is the operator read and
  reports `{:error, {:unknown_setting, path}}` so a typo is visible.
  """
  @spec resolve(atom() | [atom()]) :: config_value()
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
  Returns the parsed user config TOML file from the RAM snapshot.

  Returns `%{}` if the file is not found or cannot be parsed.

  The map comes from `EvoGit.Config.Cache` — no `File.stat` and no read on
  every call. A save raises `EvoGit.Config.Watcher`'s config-changed event,
  which runs the same reload as a watched file event and falls back to a
  guarded reload when no watcher is running (synchronous either way).
  """
  @spec user_config() :: map()
  def user_config do
    EvoGit.Config.Cache.get().user_config
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
  Validates the config against the schema before writing; a valid map is then
  persisted by `persist_user_config/1`.

  A save raises `EvoGit.Config.Watcher`'s config-changed event, which runs the
  same reload as a watched file event and falls back to a guarded reload when
  no watcher is running (synchronous either way).

  Returns `:ok` on success, `{:error, reason}` on failure.
  `reason` can be a list of `EvoGit.Config.Schema.ValidationError` structs
  on validation failure, or a filesystem error term.
  """
  @spec save_user_config(map()) :: :ok | {:error, term()}
  def save_user_config(config) when is_map(config) do
    # Validate before writing
    case EvoGit.Config.Schema.validate(config) do
      {:error, errors} -> {:error, errors}
      {:ok, _valid} -> persist_user_config(config)
    end
  end

  # The persistence half of `save_user_config/1`, WITHOUT validation: the map is
  # assumed to be valid already. `EvoGit.Config.Settings.update/1` calls this
  # after its own single `Schema.validate/1` pass over the normalized
  # (atom-keyed) candidate, so a settings save validates once instead of twice —
  # the second pass over the raw string-keyed candidate was inert anyway, because
  # `Schema.validate/1` walks atom-keyed schema paths only.
  #
  # Callers that have NOT validated must use `save_user_config/1`. The error
  # shapes are the persistence ones: `{:error, toml_encode_error}` or a
  # filesystem error term.
  @doc false
  @spec persist_user_config(map()) :: :ok | {:error, term()}
  def persist_user_config(config) when is_map(config) do
    path = config_path()
    dir = config_dir()

    with :ok <- File.mkdir_p(dir),
         config = strip_flat_llm_fields(config),
         string_config = stringify_keys(config),
         {:ok, toml} <- TomlElixir.encode(string_config),
         :ok <- File.write(path, toml) do
      # Synchronous refresh so the caller (and the settings page via
      # `RemoteAPI.save_user_config/1`) sees the new values immediately:
      # the watcher's config-changed event runs the same reload as a file
      # event, falling back to a guarded reload when no watcher runs.
      EvoGit.Config.Watcher.notify_change(dir)
      :ok
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

  # Puts a key into a map, preserving the original key type when possible.
  defp put_key(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)) and not Map.has_key?(map, key) do
      Map.put(map, Atom.to_string(key), value)
    else
      Map.put(map, key, value)
    end
  end

  # TOML serialization: string keys, `nil` map entries dropped (TOML has no
  # null) and an LLMDB model tuple rendered as its map form
  # (`{:provider, [id: "x"]}` → `%{"provider" => "provider", "id" => "x"}`).
  # Delegates to the ONE shared transform, `EvoGit.Config.Keys.stringify/2`.
  defp stringify_keys(value) do
    Keys.stringify(value, drop_nils: true, model_tuples: true)
  end

  @doc """
  Returns the status of critical configuration values.

  Checks for required settings and returns a map with:
  - `:missing` — list of missing critical config keys (as atoms)
  - `:warnings` — list of human-readable warning messages for missing values
  - `:ok?` — boolean, true if all critical config is present and validation succeeds
  - `:validation_errors` — list of `EvoGit.Config.Schema.ValidationError` structs from
    the current config snapshot, or empty list if none

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
    snapshot = EvoGit.Config.Cache.get()
    resolved = snapshot.resolved
    validation_errors = snapshot.validation_errors
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
  Returns the parsed credentials TOML file from the RAM snapshot.

  Returns `%{}` if the file is not found or cannot be parsed.

  Cached in `EvoGit.Config.Cache` for the config directory. The ReqLLM
  `put_key/2` side effects run only on an actual snapshot BUILD (cold miss or
  reload), never on a cache hit; the keys were already loaded at build time,
  and `save_credentials/1` sets them explicitly.
  """
  @spec credentials() :: map()
  def credentials do
    EvoGit.Config.Cache.get().credentials
  end

  @doc """
  Derives a ReqLLM atom key from a credential key name.

  Strips the `_API_KEY` or `_api_key` suffix, downcases, and appends
  `_api_key`. Returns `nil` if the credential key does not end with a
  recognized suffix.
  """
  @spec credential_key_to_reqllm_key(String.t()) :: atom() | nil
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
  Merges the new credentials into any existing ones per key — a SHALLOW merge:
  `credentials.toml` is a flat `ENV_VAR_NAME = "value"` table, so there is no
  nesting to merge, a new value replaces the existing one on the SAME key, and
  unknown existing keys are preserved unchanged. Passing `nil`/`""` for a key
  writes that empty value rather than deleting the key.

  Creates the credentials file if it doesn't exist yet.

  A save raises `EvoGit.Config.Watcher`'s config-changed event, which runs the
  same reload as a watched file event and falls back to a guarded reload when
  no watcher is running (synchronous either way).

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
      # Synchronous refresh so the caller sees the merged credentials straight
      # away (the snapshot's build also re-applies the ReqLLM key side
      # effects): the watcher's config-changed event runs the same reload as a
      # file event, falling back to a guarded reload when no watcher runs.
      EvoGit.Config.Watcher.notify_change(dir)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # `credentials.toml` is a FLAT `ENV_VAR_NAME = "value"` table, so the shared
  # transform's recursion never descends past the one key level.
  defp stringify_credential_keys(map), do: Keys.stringify(map)

  @doc false
  @spec ensure_trailing_newline(String.t()) :: {:ok, String.t()}
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
  via ReqLLM. Both must be true for search to work, except for a
  keyless-capable provider (see
  `EvoGit.Config.Schema.Definitions.search_provider_keyless?/1`), which is
  usable with no key because it falls back to its public endpoint.
  """
  @spec tools_search_enabled?() :: boolean()
  def tools_search_enabled? do
    config = resolve()

    case get_in(config, [:tools, :search, :enabled]) do
      true ->
        provider = get_in(config, [:tools, :search, :provider]) || :tavily

        if EvoGit.Config.Schema.Definitions.search_provider_keyless?(provider) do
          true
        else
          default_credential_key =
            get_in(config, [:tools, :search, :tavily, :api_key_credential_key]) ||
              "TAVILY_API_KEY"

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
end
