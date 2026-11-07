defmodule EvoGit.Config.Schema.LLM do
  @moduledoc """
  LLM generation parameter extraction from config/model profiles.

  Besides assembling the parameter keyword list, this module is the place where
  parameters are made **provider/model-aware**:

  - `provider_options_for_model/1` returns the provider options a bare model
    spec needs: the OpenAI-only default (`store: false`) for a genuine NATIVE
    OpenAI endpoint only, and the subscription (OAuth) options for an
    OAuth-only provider (`:openai_codex`).
  - `profile_generation_params/1` — the single choke point for every parameter
    consumer (scheduler state, dispatch, agent state, both the legacy-flat and
    the explicit-profile path) — runs the assembled list through
    `EvoGit.Config.Schema.LLMConstraints.filter/3`, which omits parameters the
    target provider/model does not accept.

  ## OAuth (subscription) profiles

  A model profile authenticates through a subscription OAuth credential when
  its `auth_mode` is `"oauth"` / `:oauth`, OR when its model's provider is
  OAuth-only (`EvoGit.Config.LLMCatalog.oauth_only?/1`) — so
  `model = "openai_codex:gpt-5.6-terra"` works with no other configuration.
  Such a profile's `provider_options` always carry `auth_mode: :oauth` plus the
  managed `oauth_file`, resolved by `EvoGit.Auth.oauth_file/1` (the profile's
  own `oauth_file` → `<config_dir>/auth.json`), and the credential is imported
  lazily from the vendor CLI login at assembly time via
  `EvoGit.Auth.ensure_credentials/2`.
  That call is fault-isolated: a missing vendor login never blocks assembly —
  the request then fails with ReqLLM's own credential message and
  `EvoGit.Config.config_status/0` reports the login step.

  ## Model metadata seam (tests + catalog availability)

  `model_metadata/1` resolves `%{limits: map(), capabilities: map()}` for a model
  spec. It reads the app-env seam `:llm_model_metadata_fun` (a 1-arity fun over
  the model spec) at CALL time; when unset it resolves the model through
  ReqLLM's public model API (i.e. the model catalog ReqLLM ships with). The
  lookup is non-raising and degrades to `nil` — the constraint table in
  `LLMConstraints` stays effective without it. Tests inject stub metadata
  through the seam, so no catalog is needed.
  """

  require Logger
  alias EvoGit.Auth
  alias EvoGit.Config.LLMCatalog
  alias EvoGit.Config.Schema.LLMConstraints
  alias EvoGit.Config.Schema.ProviderProfiles

  # Default context window (tokens) for context-compression decisions when a
  # model profile carries no explicit `context_window`.
  @default_context_window 200_000
  # Providers whose request path understands a prompt-cache/routing identity.
  # An UNDECLARED `provider_options` key is a hard request-time validation
  # error for every other provider, so this gate is mandatory.
  @cache_identity_providers [:openai, :openai_codex]
  @cache_identity_prefix "genesis-"
  @cache_identity_max_length 64

  # Normalizes the metadata-source result (app-env seam or catalog lookup) to the
  # documented `%{limits:, capabilities:}` / `nil` contract.
  defp normalize_metadata(metadata), do: LLMConstraints.normalize_metadata(metadata)

  @doc """
  Extracts LLM generation parameters, filtering out nil values.
  Returns a keyword list suitable for passing to `ReqLLM.stream_text/3`.
  Accepts either:
  - A **model profile map** (e.g. `%{id: "default", temperature: 0.7, ...}`) —
    extracts params directly from the profile.
  - A **resolved config map** (e.g. `%{llm: %{temperature: 0.7, ...}}`) —
    delegates to the default model profile.

  ## Example

      iex> Schema.LLM.llm_generation_params(%{id: "default", temperature: 0.7, max_tokens: 4096})
      [temperature: 0.7, max_tokens: 4096]

      iex> Schema.LLM.llm_generation_params(%{llm: %{models: [%{id: "default", temperature: 0.7}]}})
      [temperature: 0.7]
  """
  @spec llm_generation_params(map()) :: keyword()
  def llm_generation_params(config) when is_map(config) do
    cond do
      # Model profile map: has an :id key (profiles always have id)
      Map.has_key?(config, :id) ->
        profile_generation_params(config)

      # Resolved config map: delegate to default profile
      Map.has_key?(config, :llm) or Map.has_key?(config, "llm") ->
        case default_model_profile(config) do
          {:ok, profile} -> profile_generation_params(profile)
          {:error, :not_found} -> []
        end

      true ->
        []
    end
  end

  @doc """
  Returns legacy-compatible runtime profiles from a resolved config map.

  A non-empty `llm.providers` list supplies one profile per provider account,
  using that account's default model and reasoning effort. This projection does
  not import credentials or read catalog metadata. Invalid selections are logged
  and omitted; they never fall through to stale legacy configuration.
  With no canonical providers, `llm.models` retains its legacy shape unchanged.
  Malformed `llm` sections return `[]`.

  ## Example

      iex> Schema.LLM.model_profiles(%{llm: %{models: [%{id: "default", model: "x:y"}]}})
      [%{id: "default", model: "x:y"}]
  """
  @spec model_profiles(map()) :: [map()]
  def model_profiles(config) when is_map(config) do
    llm = llm_section(config)

    if canonical_providers?(llm) do
      config
      |> ProviderProfiles.provider_profiles()
      |> Enum.flat_map(fn profile ->
        case ProviderProfiles.resolve_runtime_profile(config, profile["id"]) do
          {:ok, runtime_profile} ->
            [runtime_profile]

          {:error, reason} ->
            Logger.warning("Invalid LLM provider profile selection: #{inspect(reason)}")
            []
        end
      end)
    else
      case profile_field(llm, :models) do
        models when is_list(models) -> models
        _ -> []
      end
    end
  end

  def model_profiles(_config), do: []

  @doc """
  Runtime profiles with the model-less legacy fallback used by scheduler boot.

  Canonical providers never fall back to flat keys, even when every selection is
  invalid. The parent Schema entry point must delegate here for that guarantee.
  """
  @spec effective_model_profiles(map()) :: [map()]
  def effective_model_profiles(config) when is_map(config) do
    case model_profiles(config) do
      [] ->
        if canonical_providers?(llm_section(config)),
          do: [],
          else: [build_legacy_default_profile(config)]

      profiles ->
        profiles
    end
  end

  defp llm_section(config) do
    case profile_field(config, :llm) do
      %{} = llm -> llm
      _ -> %{}
    end
  end

  defp canonical_providers?(llm) do
    case profile_field(llm, :providers) do
      providers when is_list(providers) and providers != [] -> true
      _ -> false
    end
  end

  @doc """
  Resolves a model profile by id.

  Returns `{:ok, profile}` if found, or `{:error, :not_found}`.

  ## Example

      iex> Schema.LLM.get_model_profile(%{llm: %{models: [%{id: "fast", model: "x:y"}]}}, "fast")
      {:ok, %{id: "fast", model: "x:y"}}
  """
  @spec get_model_profile(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_model_profile(config, id) when is_map(config) and is_binary(id) do
    case Enum.find(model_profiles(config), fn
           %{} = profile -> profile_field(profile, :id) == id
           _ -> false
         end) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Returns the configured default runtime profile.

  `llm.default_provider_profile` selects an account by id for both canonical and
  legacy profiles. Absent a selector, the first account/profile is selected.
  An invalid explicit selector returns `{:error, :not_found}`, never the first
  profile as a silent fallback.

  ## Example

      iex> Schema.LLM.default_model_profile(%{llm: %{models: [%{id: "default", model: "x:y"}]}})
      {:ok, %{id: "default", model: "x:y"}}
  """
  @spec default_model_profile(map()) :: {:ok, map()} | {:error, :not_found}
  def default_model_profile(config) when is_map(config) do
    llm = llm_section(config)

    if canonical_providers?(llm) do
      case ProviderProfiles.resolve_runtime_profile(config, nil) do
        {:ok, profile} -> {:ok, profile}
        {:error, _reason} -> {:error, :not_found}
      end
    else
      case profile_field(llm, :default_provider_profile) do
        nil ->
          case model_profiles(config) do
            [] -> {:error, :not_found}
            [profile | _] -> {:ok, profile}
          end

        id when is_binary(id) ->
          get_model_profile(config, id)

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Default context window (tokens) assumed when a model profile does not carry
  an explicit `context_window`.
  """
  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_context_window

  @doc """
  Resolves the context window (tokens) declared by a single model profile.

  Reads the optional `context_window` profile key (atom- OR string-keyed —
  TOML decoding may leave string keys). A present positive integer is
  returned as-is; an absent/nil value or ANY invalid value (non-integer,
  zero, negative) yields `default_context_window/0`, logging a warning for
  the invalid case. Never raises.

  ## Example

      iex> Schema.LLM.context_window(%{id: "default", context_window: 123_456})
      123_456

      iex> Schema.LLM.context_window(%{id: "default"})
      200_000

      iex> Schema.LLM.context_window(%{"context_window" => 50_000})
      50_000
  """
  @spec context_window(map()) :: pos_integer()
  def context_window(profile) when is_map(profile) do
    case profile_field(profile, :context_window) do
      nil ->
        @default_context_window

      value when is_integer(value) and value > 0 ->
        value

      value ->
        Logger.warning(
          "Invalid LLM model profile context_window #{inspect(value)} " <>
            "(expected a positive integer) — using default #{@default_context_window}"
        )

        @default_context_window
    end
  end

  def context_window(_other), do: @default_context_window

  @doc """
  Resolves the context window (tokens) for a model profile selected by id
  from a resolved config map.

  `{:error, :not_found}` (unknown or non-binary id, or a malformed config
  map) yields `default_context_window/0`. Never raises.

  ## Example

      iex> Schema.LLM.context_window_for(%{llm: %{models: [%{id: "fast", context_window: 64_000}]}}, "fast")
      64_000

      iex> Schema.LLM.context_window_for(%{llm: %{models: []}}, "missing")
      200_000
  """
  @spec context_window_for(map(), String.t()) :: pos_integer()
  def context_window_for(config, model_id) when is_map(config) and is_binary(model_id) do
    case get_model_profile(config, model_id) do
      {:ok, profile} -> context_window(profile)
      {:error, :not_found} -> default_context_window()
    end
  end

  def context_window_for(_config, _model_id), do: default_context_window()

  # Reads a model-profile field from an atom- or string-keyed map. A
  # `case Map.get` (not `||`) distinguishes "absent" from "present but nil".
  defp profile_field(profile, key) do
    case Map.get(profile, key) do
      nil -> Map.get(profile, Atom.to_string(key))
      value -> value
    end
  end

  @doc """
  Builds a single "default" model profile from flat (legacy) `[llm]` and
  `[scheduler]` config sections.

  Used when `[[llm.models]]` is empty or absent, so the runtime always has at
  least one profile to work with. Generation params from the flat `[llm]`
  section are included; nil values are omitted. The optional `[llm] auth_mode`
  key is carried into the profile so a legacy-flat OAuth configuration
  (`[llm] auth_mode = "oauth"`) authenticates exactly like an explicit
  `[[llm.models]]` profile.

  The returned profile always has at least `:id`, `:model`, and `:concurrency`
  keys. The `:model` value may be `nil` when no model is configured.

  ## Example

      iex> Schema.LLM.build_legacy_default_profile(%{
      ...>   llm: %{model: "anthropic:claude", temperature: 0.7},
      ...>   scheduler: %{default_llm_max_concurrency: 5}
      ...> })
      %{id: "default", model: "anthropic:claude", concurrency: 5, temperature: 0.7}

      iex> Schema.LLM.build_legacy_default_profile(%{
      ...>   llm: %{model: "anthropic:claude", auth_mode: "oauth"}
      ...> })
      %{id: "default", model: "anthropic:claude", concurrency: 3, auth_mode: "oauth"}
  """
  @spec build_legacy_default_profile(map()) :: map()
  def build_legacy_default_profile(config) when is_map(config) do
    raw_llm = Map.get(config, :llm, %{})
    llm = if is_map(raw_llm), do: raw_llm, else: %{}
    raw_scheduler = Map.get(config, :scheduler, %{})
    scheduler = if is_map(raw_scheduler), do: raw_scheduler, else: %{}
    concurrency = Map.get(scheduler, :default_llm_max_concurrency, 3)

    %{
      id: "default",
      model: Map.get(llm, :model),
      concurrency: concurrency
    }
    |> maybe_put(:temperature, Map.get(llm, :temperature))
    |> maybe_put(:max_tokens, Map.get(llm, :max_tokens))
    |> maybe_put(:reasoning_effort, Map.get(llm, :reasoning_effort))
    |> maybe_put(:top_p, Map.get(llm, :top_p))
    |> maybe_put(:top_k, Map.get(llm, :top_k))
    |> maybe_put(:frequency_penalty, Map.get(llm, :frequency_penalty))
    |> maybe_put(:presence_penalty, Map.get(llm, :presence_penalty))
    |> maybe_put(:auth_mode, Map.get(llm, :auth_mode))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Default provider options for OpenAI models.

  Disables the OpenAI Responses API server-side storage (`store: false`), which in turn
  prevents the automatic injection of `previous_response_id` — a field only supported
  on WebSocket v2, not the default HTTP/SSE streaming transport. EvoGit manages its own
  full conversation history, so server-side response chaining/storage is never needed.

  This is **OpenAI-specific** — the `store` option only exists for OpenAI's *own*
  Responses API. It is therefore applied ONLY to a genuine native OpenAI endpoint:
  a model spec carrying a custom `:base_url` or `:extra` describes an
  OpenAI-**compatible** third-party endpoint (e.g. the dashboard's
  "OpenAI-Compatible API" catalog entry, which maps to provider `:openai` with a
  custom `base_url`), and such endpoints do not implement `store`. Use
  `provider_options_for_model/1` at call sites instead, which encodes that rule.

  Subscription (OAuth) providers do NOT get this default: `store` is not part of
  the `:openai_codex` provider schema at all, so an OAuth model must never be
  handed `store: false` — see `provider_options_for_model/1`.
  """
  @spec default_provider_options() :: keyword()
  def default_provider_options, do: [store: false]

  @doc """
  Extracts the provider atom from a model spec.

  Supports the three model spec formats used throughout EvoGit:

  - **String** like `"openai:gpt-5"` — splits on the first `":"` and atomizes the
    provider part via `String.to_atom/1`.
  - **Map** like `%{provider: :openai, id: "gpt-5"}` — returns `Map.get(model, :provider)`,
    normalizing string values to atoms.
  - **Tuple** `{:openai, opts}` — returns the first element (the provider atom).

  Returns `nil` for string specs without a colon, or any unrecognized format.
  """
  @spec provider_from_model(String.t() | map() | tuple() | nil) :: atom() | nil
  def provider_from_model(nil), do: nil

  def provider_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _id] when provider != "" -> String.to_atom(provider)
      _ -> nil
    end
  end

  def provider_from_model({provider, _opts}) when is_atom(provider), do: provider

  def provider_from_model(model) when is_map(model) do
    case Map.get(model, :provider) do
      provider when is_atom(provider) and not is_nil(provider) -> provider
      provider when is_binary(provider) -> String.to_atom(provider)
      _ -> nil
    end
  end

  def provider_from_model(_other), do: nil

  @doc """
  Attaches a stable, per-conversation cache/routing identity to request params.
  OpenAI's prompt cache is keyed by the request PREFIX **and** a cache/routing
  identity. ReqLLM derives none of its own — it sends `prompt_cache_key` only
  when the caller supplies one (`provider_options[:prompt_cache_key] ||
  provider_options[:session_id]`), and codex's `session-id`/`thread-id` headers
  likewise exist only when supplied — so without an identity every turn of an
  otherwise byte-stable conversation misses the cache.
  The identity is derived from `conversation_id` and is stable for the whole
  life of that conversation (one agent run), which is exactly the granularity
  the provider caches at.
  ## Provider gating
  Only `:openai` and `:openai_codex` understand these options; an undeclared
  `provider_options` key is a hard request-time error everywhere else, so every
  other provider's params are returned byte-identical.
  - `:openai_codex` gets `prompt_cache_key:` AND `session_id:` (the latter also
    emits the `session-id` header, matching Codex CLI parity).
  - `:openai` gets `prompt_cache_key:` only (`session_id` is not in the
    `:openai` provider schema and would fail validation).
  ## Explicit user configuration wins
  When `provider_options` already carries `:prompt_cache_key` (or, for
  `:openai_codex`, `:session_id`, which already implies the cache key), the
  params are returned untouched. Otherwise the appended keys extend the EXISTING
  `provider_options` list — they never replace it, so `auth_mode: :oauth` and
  `oauth_file:` survive.
  """
  @spec with_cache_identity(keyword(), String.t() | nil, term()) :: keyword()
  def with_cache_identity(params, conversation_id, model) do
    provider = provider_from_model(model)

    if Keyword.keyword?(params) and is_binary(conversation_id) and conversation_id != "" and
         provider in @cache_identity_providers do
      provider_options = Keyword.get(params, :provider_options, [])

      cond do
        # An option list we do not understand is left byte-identical rather
        # than guessed at.
        not Keyword.keyword?(provider_options) ->
          params

        # Explicit user configuration always wins.
        Keyword.has_key?(provider_options, :prompt_cache_key) ->
          params

        provider == :openai_codex and Keyword.has_key?(provider_options, :session_id) ->
          params

        true ->
          key = cache_identity(conversation_id)

          additions =
            case provider do
              :openai_codex -> [prompt_cache_key: key, session_id: key]
              :openai -> [prompt_cache_key: key]
            end

          Keyword.put(params, :provider_options, provider_options ++ additions)
      end
    else
      params
    end
  end

  # Deterministic, ASCII, <= 64 characters. The readable `genesis-<id>` form is
  # used when it fits; otherwise (too long, or non-ASCII) the SHA-256 digest is
  # url-base64 encoded so the provider key is always well-formed and bounded.
  defp cache_identity(conversation_id) do
    readable = @cache_identity_prefix <> conversation_id

    if byte_size(readable) <= @cache_identity_max_length and ascii?(readable) do
      readable
    else
      @cache_identity_prefix <>
        Base.url_encode64(:crypto.hash(:sha256, conversation_id), padding: false)
    end
  end

  defp ascii?(binary) do
    Enum.all?(:binary.bin_to_list(binary), fn byte -> byte >= 0x20 and byte <= 0x7E end)
  end

  @doc """
  Returns the appropriate `provider_options` keyword list for a given model spec.

  Three branches:

  - **OAuth-only provider** (`EvoGit.Config.LLMCatalog.oauth_only?/1`, e.g.
    `:openai_codex`) → `[auth_mode: :oauth, oauth_file: <managed file>]`, with a
    lazy, fault-isolated `EvoGit.Auth.ensure_credentials/2` (the vendor CLI
    login is imported on first use). This is what makes a call site that holds
    only a model spec and no profile — `EvoGit.SystemCheck`'s LLM test,
    `EvoGit.Runtime.PullRequest` — authenticate a subscription model.
  - **Native OpenAI endpoint** → `[store: false]` (via
    `default_provider_options/0`). "Native" means the spec's provider is
    `:openai` AND the spec carries no custom endpoint override (`:base_url` or
    `:extra`) — a custom endpoint is an OpenAI-compatible third-party service,
    which does not implement the OpenAI-only options (a presence check is used,
    so even an empty `extra` map counts as an override).
  - **Everything else** → `[]`.

  `:openai_codex` is deliberately NEVER given `store: false`: it is a
  Responses-API provider with a completely different provider schema, `store`
  is not in that schema, and sending it would raise at request time.
  """
  @spec provider_options_for_model(String.t() | map() | tuple() | nil) :: keyword()
  def provider_options_for_model(model) do
    provider = provider_from_model(model)

    cond do
      LLMCatalog.oauth_only?(provider) -> oauth_provider_options(%{model: model})
      provider == :openai and not custom_endpoint?(model) -> default_provider_options()
      true -> []
    end
  end

  @doc """
  Returns `true` when a model profile authenticates through a subscription
  (OAuth) credential.

  A profile is OAuth when its `auth_mode` normalizes to `:oauth` (both `"oauth"`
  and `:oauth` are accepted) OR when its model's provider is OAuth-only
  (`EvoGit.Config.LLMCatalog.oauth_only?/1`, e.g. `openai_codex:gpt-5.6-terra`).
  Any other / absent `auth_mode` value means the API-key default.

  `profile` is any map with a `:model` (and optionally `:auth_mode` /
  `:oauth_file`) key, so a bare `%{model: model, auth_mode: ...}` spec works too.
  Never raises.

  ## Example

      iex> Schema.LLM.oauth_profile?(%{model: "openai_codex:gpt-5.6-terra"})
      true

      iex> Schema.LLM.oauth_profile?(%{model: "anthropic:claude-opus-5-5", auth_mode: "oauth"})
      true

      iex> Schema.LLM.oauth_profile?(%{model: "anthropic:claude-opus-5-5"})
      false
  """
  @spec oauth_profile?(map()) :: boolean()
  def oauth_profile?(profile) when is_map(profile) do
    oauth_auth_mode?(profile_field(profile, :auth_mode)) or
      LLMCatalog.oauth_only?(oauth_provider(profile))
  end

  def oauth_profile?(_profile), do: false

  @doc """
  Ensures the managed subscription credential for an OAuth model profile is
  present, importing it from the vendor CLI login when appropriate.

  Resolves the provider from the profile's `:model` and the managed file
  through `EvoGit.Auth.oauth_file/1` (the profile's own `oauth_file` →
  `<config_dir>/auth.json`), then delegates to the fault-isolated
  `EvoGit.Auth.ensure_credentials/2`. Returns `:ok` when a
  usable credential exists (including a provider env token) and
  `{:error, reason}` otherwise — never raises and never blocks.

  A caller that only has a model spec can pass `%{model: model}`.
  """
  @spec ensure_profile_credentials(map()) :: :ok | {:error, term()}
  def ensure_profile_credentials(profile) when is_map(profile) do
    ensure_credentials(oauth_provider(profile), oauth_file_for(profile))
  end

  def ensure_profile_credentials(_profile), do: {:error, :invalid_profile}

  @doc """
  Reports whether the subscription credential of an OAuth model profile
  resolves, importing it lazily first (like `ensure_profile_credentials/1`).

  Returns `{:ok, %{expires: ms_epoch | nil, account_id: String.t() | nil}}` when
  the managed entry carries an access or a refresh token (or a provider env
  token is set), `{:error, :no_credentials}` when nothing is available,
  `{:error, {:managed_file_unwritable, reason}}` when the vendor login exists but
  the managed copy could not be written (`reason` is a POSIX atom — see
  `EvoGit.Auth.managed_file_unwritable_remedy/2`), and
  `{:error, :invalid_credentials}` for an unusable/broken managed file. Never
  raises: a broken or missing auth file degrades to "not configured".

  Used by `EvoGit.Config.config_status/0` to decide whether an OAuth profile
  satisfies the API-credential health check.
  """
  @spec oauth_credential_status(map()) ::
          {:ok, %{expires: integer() | nil, account_id: String.t() | nil}}
          | {:error, :no_credentials | :invalid_credentials | term()}
  def oauth_credential_status(profile) when is_map(profile) do
    provider = oauth_provider(profile)
    oauth_file = oauth_file_for(profile)

    # Import first (the one-time vendor-CLI import), then report what the
    # managed entry actually holds. A managed-file write failure is threaded
    # into the status so the caller can name the real cause (and its remedy)
    # instead of only "no credentials".
    managed_file_error = managed_file_error(ensure_credentials(provider, oauth_file))

    Auth.credential_status(provider,
      oauth_file: oauth_file,
      managed_file_error: managed_file_error
    )
  end

  def oauth_credential_status(_profile), do: {:error, :no_credentials}

  # The POSIX reason of a write-side credential failure, or nil when the import
  # did not fail that way (`EvoGit.Auth.ensure_credentials/2`).
  defp managed_file_error({:error, {:managed_file_unwritable, reason}}), do: reason
  defp managed_file_error(_result), do: nil

  # The provider a profile's subscription credential belongs to. `nil` when the
  # model spec carries no resolvable provider — `EvoGit.Auth` then reports "no
  # credentials" instead of raising.
  defp oauth_provider(profile), do: provider_from_model(profile_field(profile, :model))

  @doc """
  Returns the managed OAuth file a profile's subscription credential uses: the
  profile's `oauth_file` wins, otherwise the default `<config_dir>/auth.json`.
  """
  @spec oauth_file_for(map()) :: String.t()
  def oauth_file_for(profile) when is_map(profile) do
    Auth.oauth_file(oauth_file: profile_field(profile, :oauth_file))
  end

  # `EvoGit.Auth.ensure_credentials/2` is the designated fault-isolation
  # boundary for this path: a missing vendor login, a corrupt managed file or an
  # unwritable config dir degrades to an error tuple, so provider-option
  # assembly always succeeds.
  defp ensure_credentials(provider, oauth_file) do
    Auth.ensure_credentials(provider, oauth_file: oauth_file)
  end

  # The OAuth defaults for a profile: `auth_mode: :oauth` plus the resolved
  # managed file. The credential import runs HERE (assembly time, lazily) and is
  # gated on the OAuth branch, so an api_key profile stays allocation-identical.
  # It is cheap — a couple of `File.stat`/`File.read` of small files, no network
  # and no subprocess — and never blocks on a credential failure.
  defp oauth_provider_options(profile) do
    oauth_file = oauth_file_for(profile)
    _ = ensure_credentials(oauth_provider(profile), oauth_file)

    [auth_mode: :oauth, oauth_file: oauth_file]
  end

  # Both `"oauth"` and `:oauth` mean OAuth; anything else (including nil) is the
  # API-key default. The schema validator reports invalid values separately.
  defp oauth_auth_mode?(:oauth), do: true
  defp oauth_auth_mode?("oauth"), do: true
  defp oauth_auth_mode?(_value), do: false

  defp custom_endpoint?(model) when is_map(model) do
    Map.get(model, :base_url) != nil or Map.get(model, :extra) != nil
  end

  defp custom_endpoint?(_model), do: false

  @doc """
  Extracts generation params from a single profile map.

  The assembled keyword list is passed through
  `EvoGit.Config.Schema.LLMConstraints.filter/3` against the profile's model spec,
  dropping parameters the target provider/model does not accept (see that module
  for the constraint table and the degradation rules).

  `provider_options` is assembled with OAuth awareness:

  - an OAuth profile (see `oauth_profile?/1`) always gets `auth_mode: :oauth`
    plus its resolved `oauth_file`, so a subscription profile needs no extra
    configuration;
  - a user-supplied profile `provider_options` map/keyword list is a PARTIAL
    override on top of those OAuth defaults: its own keys win (an explicit
    `oauth_file:` inside the options is honoured, for instance) while the OAuth
    defaults it does not set survive;
  - without a profile override the OAuth defaults WIN over the model-derived
    options (`provider_options_for_model/1`), so a profile that overrides
    `oauth_file` keeps it even for an OAuth-only provider whose model-derived
    list carries the DEFAULT managed file;
  - an EMPTY resolved option list omits the `:provider_options` key entirely.

  Precedence, highest first: the profile's explicit `provider_options` keys →
  the profile-derived OAuth defaults → the model-derived options.

  API-key profiles with a nonempty `api_key_env_var` use that exact name:
  a nonempty environment value wins over a nonempty persisted credential.
  Missing custom credentials emit an empty `:api_key` so ReqLLM rejects the
  request rather than falling back to a provider-wide key; OAuth is excluded.
  """
  @spec profile_generation_params(map()) :: keyword()
  def profile_generation_params(profile) when is_map(profile) do
    model = Map.get(profile, :model)

    []
    |> maybe_param(:temperature, Map.get(profile, :temperature))
    |> maybe_param(:max_tokens, Map.get(profile, :max_tokens))
    |> maybe_param(
      :reasoning_effort,
      profile |> Map.get(:reasoning_effort) |> convert_reasoning_effort()
    )
    |> maybe_param(:top_p, Map.get(profile, :top_p))
    |> maybe_param(:top_k, Map.get(profile, :top_k))
    |> maybe_param(:frequency_penalty, Map.get(profile, :frequency_penalty))
    |> maybe_param(:presence_penalty, Map.get(profile, :presence_penalty))
    |> maybe_provider_options(profile)
    |> LLMConstraints.filter(model, model_metadata(model))
    |> maybe_api_key(profile)
  end

  # Keep account-specific API keys at the same assembly boundary as generation
  # and OAuth options, including callers using the runtime compatibility profile.
  defp maybe_api_key(params, profile) do
    name = Map.get(profile, :api_key_env_var)

    if is_binary(name) and name != "" and not oauth_profile?(profile) do
      key =
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> value
          _ -> Map.get(EvoGit.Config.credentials(), name)
        end

      # An explicit empty key makes ReqLLM reject missing account credentials
      # instead of silently using another account's provider-wide default key.
      case key do
        value when is_binary(value) and value != "" -> Keyword.put(params, :api_key, value)
        _ -> Keyword.put(params, :api_key, "")
      end
    else
      params
    end
  end

  @doc false
  @spec model_metadata(String.t() | map() | tuple() | nil) ::
          %{limits: map(), capabilities: map()} | nil
  def model_metadata(model) do
    case Application.get_env(:evo_git, :llm_model_metadata_fun) do
      fun when is_function(fun, 1) ->
        normalize_metadata(safe_metadata(model, fn -> fun.(model) end))

      _ ->
        catalog_metadata(model)
    end
  end

  defp safe_metadata(model, fun) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "LLM model metadata lookup failed for #{inspect(model)}: #{Exception.message(error)}"
      )

      nil
  catch
    kind, reason ->
      Logger.warning(
        "LLM model metadata lookup failed for #{inspect(model)}: #{inspect({kind, reason})}"
      )

      nil
  end

  # Model catalog lookup through ReqLLM's public model API (which resolves the
  # model from the catalog ReqLLM ships with and returns the enriched model
  # struct carrying `:limits` and `:capabilities`). Deliberately NEVER raises and
  # never forces a catalog load: this runs on every agent spawn (and for every
  # profile read), so a missing/unresolvable catalog simply degrades to "no
  # metadata" — in which case the declarative constraints in `LLMConstraints`
  # still apply and no parameter is dropped for lack of metadata.
  defp catalog_metadata(model) do
    with {provider, id} when is_atom(provider) and is_binary(id) <- catalog_key(model),
         {:ok, result} <- catalog_lookup(provider, id) do
      extract_metadata(result)
    else
      _ -> nil
    end
  end

  defp catalog_lookup(provider, id) do
    ReqLLM.model({provider, id, []})
  rescue
    error ->
      {:error, {:lookup_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:lookup_failed, {kind, reason}}}
  end

  defp extract_metadata(result) when is_map(result) do
    limits = Map.get(result, :limits)
    capabilities = Map.get(result, :capabilities)

    if is_map(limits) or is_map(capabilities) do
      %{
        limits: if(is_map(limits), do: limits, else: %{}),
        capabilities: if(is_map(capabilities), do: capabilities, else: %{})
      }
    else
      nil
    end
  end

  defp extract_metadata(_result), do: nil

  # The catalog resolves a model from a `{provider_atom, model_id}` pair; a map
  # spec (and the 2-tuple form) has no such clause, so the key is normalized
  # here. Returns nil when the spec carries no resolvable provider or id — no
  # lookup is then possible and the metadata stays absent (rules stay inert).
  # `String.to_existing_atom/1` (never `to_atom/1`) keeps a bad user-supplied
  # provider string from growing the atom table.
  defp catalog_key(nil), do: nil

  defp catalog_key(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" -> existing_atom_key(provider, id)
      _ -> nil
    end
  end

  defp catalog_key(%{} = model) do
    with provider when not is_nil(provider) <- Map.get(model, :provider),
         id when is_binary(id) and id != "" <- Map.get(model, :id) do
      existing_atom_key(provider, id)
    else
      _ -> nil
    end
  end

  defp catalog_key({provider, opts}) when is_list(opts) do
    case Keyword.get(opts, :id) do
      id when is_binary(id) and id != "" -> existing_atom_key(provider, id)
      _ -> nil
    end
  end

  defp catalog_key({provider, id}) when is_binary(id) and id != "",
    do: existing_atom_key(provider, id)

  defp catalog_key(_other), do: nil

  defp existing_atom_key(provider, id) when is_atom(provider) and not is_nil(provider),
    do: {provider, id}

  defp existing_atom_key(provider, id) when is_binary(provider) do
    {String.to_existing_atom(provider), id}
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_provider, _id), do: nil

  # Resolves provider_options for a profile. Precedence, highest first:
  #
  #   1. the profile's explicit `provider_options` map/keyword list — a PARTIAL
  #      override, its own keys win (an explicit `oauth_file:` inside the
  #      options is honoured) while the OAuth defaults it does not set survive;
  #   2. the profile-derived OAuth defaults (`auth_mode: :oauth` + the managed
  #      file resolved from THIS profile's `oauth_file`, else
  #      `<config_dir>/auth.json`) — `oauth_profile?/1` covers both an
  #      explicit `auth_mode = "oauth"` and auto-detection of an OAuth-only
  #      provider, and this is also where the lazy vendor-login import runs;
  #   3. the model-derived options from `provider_options_for_model/1`
  #      (`store: false` only for a native OpenAI endpoint, the OAuth-only
  #      defaults for a caller holding just a model spec).
  #
  # Without a profile override, level 2 therefore WINS over level 3: the
  # model-derived list's own `oauth_file` is only ever the DEFAULT managed file,
  # so letting it win would clobber a profile's `oauth_file` override.
  #
  # An EMPTY resolved list means the caller omits the `:provider_options` key
  # entirely (a non-native-OpenAI api_key profile must NOT get store: false).
  defp maybe_provider_options(keyword_list, profile) do
    case resolve_provider_options(profile) do
      [] -> keyword_list
      opts -> keyword_list ++ [{:provider_options, opts}]
    end
  end

  defp resolve_provider_options(profile) do
    defaults = if oauth_profile?(profile), do: oauth_provider_options(profile), else: []

    case Map.get(profile, :provider_options) do
      nil -> merge_options(provider_options_for_model(Map.get(profile, :model)), defaults)
      override -> merge_options(defaults, options_list(override))
    end
  end

  defp options_list(override) when is_map(override), do: Map.to_list(override)
  defp options_list(override) when is_list(override), do: override

  # Key-wise merge where the override wins and the defaults fill the gaps. Not
  # `Keyword.merge/2`: the override comes from user config and may carry
  # non-atom keys, which `Keyword.merge/2` does not accept.
  defp merge_options(defaults, override) do
    overridden = for {key, _value} <- override, into: MapSet.new(), do: key

    Enum.reject(defaults, fn {key, _value} -> MapSet.member?(overridden, key) end) ++ override
  end

  @doc """
  Conditionally appends a key/value pair to a keyword list, skipping nil values.
  """
  @spec maybe_param(keyword(), atom(), term()) :: keyword()
  def maybe_param(keyword_list, _key, nil), do: keyword_list
  def maybe_param(keyword_list, key, value), do: keyword_list ++ [{key, value}]

  @doc """
  Converts reasoning_effort string from config (TOML) to atom expected by ReqLLM.
  Uses explicit case matching rather than String.to_existing_atom for safety.
  """
  @spec convert_reasoning_effort(String.t() | nil | atom()) :: atom() | String.t() | nil
  def convert_reasoning_effort(nil), do: nil
  def convert_reasoning_effort("none"), do: :none
  def convert_reasoning_effort("minimal"), do: :minimal
  def convert_reasoning_effort("low"), do: :low
  def convert_reasoning_effort("medium"), do: :medium
  def convert_reasoning_effort("high"), do: :high
  def convert_reasoning_effort("xhigh"), do: :xhigh
  def convert_reasoning_effort("default"), do: :default
  def convert_reasoning_effort(other), do: other
end
