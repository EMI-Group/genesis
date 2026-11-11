defmodule EvoGit.Config.LLMCatalog do
  @moduledoc """
  Predefined catalog of LLM providers and their popular models.

  Provides shortcuts for common provider/model combinations, so users don't need
  to memorize the "provider:model" string format. Also provides guidance for
  providers not in the catalog.

  ## Auth modes

  Each entry's `auth_modes` / `oauth_source` describe HOW a provider can be
  authenticated, and drive the "API key" vs "Subscription (OAuth)" choice in the
  dashboard. A provider with `[:api_key]` (the default
  when the field is absent) authenticates with an API key only; one that also
  lists `:oauth` may instead reuse a subscription credential imported from the
  vendor CLI named by `oauth_source` (`:codex_cli` / `:claude_code`). The
  `:openai_codex` entry is OAuth-only — it can never be used with an API key.
  """

  @type variant_entry :: %{
          id: atom(),
          display_name: String.t(),
          provider_atom: atom(),
          credential_key: String.t()
        }

  @typedoc """
  A catalog provider entry.

  `auth_modes` lists the auth modes the provider supports (`[:api_key]` when
  absent) and `oauth_source` names the vendor CLI login the OAuth credential is
  imported from (`:codex_cli` or `:claude_code`; `nil` otherwise).
  """
  @type provider_entry :: %{
          id: atom(),
          display_name: String.t(),
          provider_atoms: [atom()],
          credential_key: String.t(),
          models: [model_entry()],
          variants: [variant_entry()] | nil,
          custom_model: boolean() | nil,
          requires_base_url: boolean() | nil,
          auth_modes: [atom()] | nil,
          oauth_source: atom() | nil
        }

  @type model_entry :: %{
          id: String.t(),
          display_name: String.t()
        }

  @providers [
    %{
      id: :anthropic,
      display_name: "Anthropic",
      provider_atoms: [:anthropic],
      credential_key: "anthropic_api_key",
      variants: nil,
      auth_modes: [:api_key, :oauth],
      oauth_source: :claude_code,
      models: [
        %{id: "claude-haiku-5-5", display_name: "Claude Haiku 5.5"},
        %{id: "claude-sonnet-5-5", display_name: "Claude Sonnet 5.5"},
        %{id: "claude-opus-5-5", display_name: "Claude Opus 5.5"},
        %{id: "claude-fable-5-1", display_name: "Claude Fable 5.1"},
        %{id: "claude-opus-5", display_name: "Claude Opus 5"},
        %{id: "claude-sonnet-5", display_name: "Claude Sonnet 5"}
      ]
    },
    %{
      id: :openai,
      display_name: "OpenAI",
      provider_atoms: [:openai],
      credential_key: "openai_api_key",
      variants: nil,
      models: [
        %{id: "gpt-6.1-sol", display_name: "GPT-6.1 Sol"},
        %{id: "gpt-6-sol", display_name: "GPT-6 Sol"},
        %{id: "gpt-6-luna", display_name: "GPT-6 Luna"},
        %{id: "gpt-6-astra", display_name: "GPT-6 Astra"},
        %{id: "gpt-5.6-sol", display_name: "GPT-5.6 Sol"},
        %{id: "gpt-5.6-terra", display_name: "GPT-5.6 Terra"}
      ]
    },
    %{
      id: :openai_codex,
      display_name: "ChatGPT Codex (OAuth)",
      provider_atoms: [:openai_codex],
      credential_key: "openai_codex_api_key",
      variants: nil,
      auth_modes: [:oauth],
      oauth_source: :codex_cli,
      models: [
        %{id: "gpt-6.1-sol", display_name: "GPT-6.1 Sol"},
        %{id: "gpt-6-astra", display_name: "GPT-6 Astra"},
        %{id: "gpt-6.1-terra", display_name: "GPT-6.1 Terra"},
        %{id: "gpt-6-sol", display_name: "GPT-6 Sol"},
        %{id: "gpt-6-luna", display_name: "GPT-6 Luna"},
        %{id: "gpt-5.6-sol", display_name: "GPT-5.6 Sol"},
        %{id: "gpt-5.6-terra", display_name: "GPT-5.6 Terra"},
        %{id: "gpt-5.6-luna", display_name: "GPT-5.6 Luna"}
      ]
    },
    %{
      id: :google,
      display_name: "Google",
      provider_atoms: [:google],
      credential_key: "google_api_key",
      variants: nil,
      models: [
        %{id: "gemini-4-argon", display_name: "Gemini 4 Argon"},
        %{id: "gemini-3.8-flash", display_name: "Gemini 3.8 Flash"},
        %{id: "gemini-3.7-flash", display_name: "Gemini 3.7 Flash"},
        %{id: "gemini-3.6-flash", display_name: "Gemini 3.6 Flash"},
        %{id: "gemini-3.5-flash", display_name: "Gemini 3.5 Flash"},
        %{id: "gemini-3.5-flash-lite", display_name: "Gemini 3.5 Flash Lite"}
      ]
    },
    %{
      id: :deepseek,
      display_name: "DeepSeek",
      provider_atoms: [:deepseek],
      credential_key: "deepseek_api_key",
      variants: nil,
      models: [
        %{id: "deepseek-v4-flash-vision-exp", display_name: "DeepSeek V4 Flash Vision (Exp)"},
        %{id: "deepseek-v4-flash", display_name: "DeepSeek V4 Flash"},
        %{id: "deepseek-flash", display_name: "DeepSeek V4.1 Flash"},
        %{id: "deepseek-v4-pro", display_name: "DeepSeek V4 Pro"}
      ]
    },
    %{
      id: :alibaba,
      display_name: "Alibaba Cloud (Qwen)",
      provider_atoms: [:alibaba, :alibaba_cn],
      credential_key: "alibaba_api_key",
      variants: [
        %{
          id: :global,
          display_name: "Global",
          provider_atom: :alibaba,
          credential_key: "alibaba_api_key"
        },
        %{
          id: :cn,
          display_name: "CN",
          provider_atom: :alibaba_cn,
          credential_key: "alibaba_cn_api_key"
        }
      ],
      models: [
        %{id: "qwen3.8-omni-flash", display_name: "Qwen3.8 Omni Flash"},
        %{id: "qwen3.8-flash", display_name: "Qwen3.8 Flash"},
        %{id: "qwen3.8-max", display_name: "Qwen3.8 Max"},
        %{id: "qwen3.7-flash", display_name: "Qwen3.7 Flash"},
        %{id: "qwen3.7-plus", display_name: "Qwen3.7 Plus"},
        %{id: "qwen3.7-max", display_name: "Qwen3.7 Max"}
      ]
    },
    %{
      id: :zai,
      display_name: "Z.ai (Zhipu AI)",
      provider_atoms: [:zai, :zai_coding_plan],
      credential_key: "zai_api_key",
      variants: [
        %{
          id: :normal,
          display_name: "Normal API",
          provider_atom: :zai,
          credential_key: "zai_api_key"
        },
        %{
          id: :coding_plan,
          display_name: "Coding Plan",
          provider_atom: :zai_coding_plan,
          credential_key: "zai_coding_plan_api_key"
        }
      ],
      models: [
        %{id: "glm-5.3-flashx", display_name: "GLM-5.3 FlashX"},
        %{id: "glm-5.3-flash", display_name: "GLM-5.3 Flash"},
        %{id: "glm-5.3", display_name: "GLM-5.3"},
        %{id: "glm-5.2", display_name: "GLM-5.2"},
        %{id: "glm-5.1", display_name: "GLM-5.1"}
      ]
    },
    %{
      id: :minimax,
      display_name: "MiniMax",
      provider_atoms: [:minimax],
      credential_key: "minimax_api_key",
      variants: nil,
      models: [
        %{id: "MiniMax-M3.1-Flash", display_name: "MiniMax-M3.1-Flash"},
        %{id: "MiniMax-M3", display_name: "MiniMax-M3"},
        %{id: "MiniMax-M2.7", display_name: "MiniMax-M2.7"},
        %{id: "MiniMax-M2.7-highspeed", display_name: "MiniMax-M2.7 Highspeed"}
      ]
    },
    %{
      id: :moonshotai,
      display_name: "Moonshot AI (Kimi)",
      provider_atoms: [:moonshotai],
      credential_key: "moonshotai_api_key",
      variants: nil,
      models: [
        %{id: "kimi-k3.1-pro", display_name: "Kimi K3.1 Pro"},
        %{id: "kimi-k3.1-pro-highspeed", display_name: "Kimi K3.1 Pro Highspeed"},
        %{id: "kimi-k3", display_name: "Kimi K3"},
        %{id: "kimi-k2.7-code-highspeed", display_name: "Kimi K2.7 Code Highspeed"},
        %{id: "kimi-k2.7-code", display_name: "Kimi K2.7 Code"}
      ]
    },
    %{
      id: :xai,
      display_name: "xAI",
      provider_atoms: [:xai],
      credential_key: "xai_api_key",
      variants: nil,
      models: [
        %{id: "grok-4.7", display_name: "Grok 4.7"},
        %{id: "grok-4.6", display_name: "Grok 4.6"},
        %{id: "grok-4.5", display_name: "Grok 4.5"},
        %{id: "grok-4.3", display_name: "Grok 4.3"},
        %{id: "grok-build-0.1", display_name: "Grok Build 0.1"}
      ]
    },
    %{
      id: :openrouter,
      display_name: "OpenRouter",
      provider_atoms: [:openrouter],
      credential_key: "openrouter_api_key",
      variants: nil,
      models: [],
      custom_model: true
    },
    %{
      id: :openai_compatible,
      display_name: "OpenAI-Compatible API",
      provider_atoms: [:openai],
      credential_key: "openai_api_key",
      variants: nil,
      models: [],
      custom_model: true,
      requires_base_url: true
    }
  ]

  # --- Public API ---

  @doc """
  Returns the full provider catalog.
  """
  @spec providers() :: [provider_entry()]
  def providers, do: @providers

  @doc """
  Returns models for a given provider atom.

  Returns `[]` if the provider is not found in the catalog.
  """
  @spec provider_models(atom()) :: [model_entry()]
  def provider_models(provider_atom) when is_atom(provider_atom) do
    case find_provider(provider_atom) do
      nil -> []
      provider -> provider.models
    end
  end

  @doc """
  Returns variants for a given provider atom.
  Returns `nil` if the provider has no variants.
  """
  @spec provider_variants(atom()) :: [variant_entry()] | nil
  def provider_variants(provider_atom) when is_atom(provider_atom) do
    case find_provider(provider_atom) do
      nil -> nil
      provider -> provider[:variants]
    end
  end

  @doc """
  Resolves the canonical provider atom for a provider, optionally using a variant.
  If a variant_id is given and the provider has variants, returns the variant's provider_atom.
  Otherwise returns the first (canonical) provider_atom.
  """
  @spec resolve_provider_atom(atom(), atom() | nil) :: atom()
  def resolve_provider_atom(provider_atom, variant_id \\ nil) when is_atom(provider_atom) do
    case find_provider(provider_atom) do
      nil ->
        provider_atom

      provider ->
        variants = provider[:variants]

        if variants && variant_id do
          case Enum.find(variants, &(&1.id == variant_id)) do
            %{provider_atom: atom} -> atom
            nil -> hd(provider.provider_atoms)
          end
        else
          hd(provider.provider_atoms)
        end
    end
  end

  @doc """
  Converts a provider atom to the expected credential key name.

  Lowercases the atom name and appends `_api_key`.

  ## Examples

      iex> LLMCatalog.credential_key_for_atom(:anthropic)
      "anthropic_api_key"

      iex> LLMCatalog.credential_key_for_atom(:zai_coding_plan)
      "zai_coding_plan_api_key"

      iex> LLMCatalog.credential_key_for_atom(:alibaba_cn)
      "alibaba_cn_api_key"
  """
  @spec credential_key_for_atom(atom()) :: String.t()
  def credential_key_for_atom(atom) when is_atom(atom) do
    "#{String.downcase(Atom.to_string(atom))}_api_key"
  end

  @doc """
  Resolves a provider atom + model shortcut or full model name to "provider:model" string.

  Resolution logic:
  1. If `model_input` matches a model's `id` exactly, use it.
  2. If `model_input` matches a model's `display_name` (case-insensitive, trimmed),
     use the corresponding `id`.
  3. Otherwise use `model_input` as the raw model name (user entered a custom name).

  The canonical provider atom (first in the `provider_atoms` list) is used for the
  "provider:model" string.
  """
  @spec resolve_model(atom(), String.t()) :: String.t()
  def resolve_model(provider_atom, model_input)
      when is_atom(provider_atom) and is_binary(model_input) do
    provider = find_provider(provider_atom)
    canonical = if provider, do: hd(provider.provider_atoms), else: provider_atom

    model_id =
      if provider do
        find_model_id(provider.models, model_input)
      else
        model_input
      end

    "#{canonical}:#{model_id}"
  end

  @doc """
  Resolves a provider atom + model shortcut/full name to a map model spec.

  This is the map-producing analog of `resolve_model/2` (which returns a
  "provider:model" string). Returns a map of the shape ReqLLM natively
  accepts: `%{provider: atom, id: string}`.

  ## Options

    * `:base_url` — when provided and non-empty, included in the returned map.
    * `:variant` — variant atom used to resolve the canonical provider atom
      (e.g. `:cn` for Alibaba CN).
    * `:extra` — when provided and non-nil, included in the returned map as
      the `:extra` key (must be a map).

  ## Examples

      iex> EvoGit.Config.LLMCatalog.resolve_model_spec(:anthropic, "claude-sonnet-4")
      %{provider: :anthropic, id: "claude-sonnet-4"}

      iex> EvoGit.Config.LLMCatalog.resolve_model_spec(:openai, "gpt-6-sol", base_url: "https://my.proxy/v1")
      %{provider: :openai, id: "gpt-6-sol", base_url: "https://my.proxy/v1"}

  """
  @spec resolve_model_spec(atom(), String.t(), keyword()) :: map()
  def resolve_model_spec(provider_atom, model_input, opts \\ [])
      when is_atom(provider_atom) and is_binary(model_input) do
    variant_id = Keyword.get(opts, :variant)
    canonical = resolve_provider_atom(provider_atom, variant_id)

    provider = find_provider(provider_atom)
    model_id = if provider, do: find_model_id(provider.models, model_input), else: model_input

    spec = %{provider: canonical, id: model_id}

    spec =
      case Keyword.get(opts, :base_url) do
        base_url when is_binary(base_url) and base_url != "" ->
          Map.put(spec, :base_url, base_url)

        _ ->
          spec
      end

    case Keyword.get(opts, :extra) do
      nil -> spec
      extra -> Map.put(spec, :extra, extra)
    end
  end

  @doc """
  Returns whether the given provider requires a custom `base_url` to function.

  Looks up the provider entry by its atom and returns its `requires_base_url`
  flag. Defaults to `false` for providers that do not declare the flag and for
  unknown providers.
  """
  @spec requires_base_url?(atom()) :: boolean()
  def requires_base_url?(provider_atom) when is_atom(provider_atom) do
    case resolve_entry(provider_atom) do
      nil -> false
      provider -> provider[:requires_base_url] == true
    end
  end

  @doc """
  Returns the auth modes the given provider supports.

  Accepts a catalog entry id (e.g. `:openai_codex`) or a raw provider atom (e.g.
  `:anthropic`). Defaults to `[:api_key]` for providers that do not declare the
  field and for unknown providers.

  ## Examples

      iex> EvoGit.Config.LLMCatalog.auth_modes(:anthropic)
      [:api_key, :oauth]

      iex> EvoGit.Config.LLMCatalog.auth_modes(:openai_codex)
      [:oauth]

      iex> EvoGit.Config.LLMCatalog.auth_modes(:mistral)
      [:api_key]
  """
  @spec auth_modes(atom()) :: [atom()]
  def auth_modes(provider_atom) when is_atom(provider_atom) do
    case resolve_entry(provider_atom) do
      nil -> [:api_key]
      provider -> provider[:auth_modes] || [:api_key]
    end
  end

  @doc """
  Returns which vendor CLI login the provider's OAuth credential is imported
  from: `:codex_cli` or `:claude_code`. Returns `nil` for API-key-only and
  unknown providers.

  Accepts a catalog entry id or a raw provider atom.

  ## Examples

      iex> EvoGit.Config.LLMCatalog.oauth_source(:openai_codex)
      :codex_cli

      iex> EvoGit.Config.LLMCatalog.oauth_source(:anthropic)
      :claude_code

      iex> EvoGit.Config.LLMCatalog.oauth_source(:openai)
      nil
  """
  @spec oauth_source(atom()) :: atom() | nil
  def oauth_source(provider_atom) when is_atom(provider_atom) do
    case resolve_entry(provider_atom) do
      nil -> nil
      provider -> provider[:oauth_source]
    end
  end

  @doc """
  Returns `true` when the provider cannot be used with an API key at all — i.e.
  `:api_key` is NOT among its `auth_modes/1`.

  The config layer uses this to auto-detect OAuth (e.g. for
  `openai_codex:gpt-5.6-terra`) when the user did not write an `auth_mode`.
  Unknown providers are not OAuth-only.
  """
  @spec oauth_only?(atom()) :: boolean()
  def oauth_only?(provider_atom) when is_atom(provider_atom) do
    :api_key not in auth_modes(provider_atom)
  end

  @doc """
  Returns `true` when the provider supports a subscription OAuth credential
  (`:oauth` is among its `auth_modes/1`). Unknown providers return `false`.
  """
  @spec supports_oauth?(atom()) :: boolean()
  def supports_oauth?(provider_atom) when is_atom(provider_atom) do
    :oauth in auth_modes(provider_atom)
  end

  @doc """
  Finds the provider entry for a given provider atom.

  Checks if the atom is in the provider's `provider_atoms` list.
  Returns `nil` if not found.
  """
  @spec find_provider(atom()) :: provider_entry() | nil
  def find_provider(provider_atom) when is_atom(provider_atom) do
    Enum.find(@providers, fn provider ->
      provider_atom in provider.provider_atoms
    end)
  end

  @doc """
  Returns help text for users whose provider is not in the catalog.
  """
  @spec unknown_provider_help() :: String.t()
  def unknown_provider_help do
    """
    Your provider is not in the shortcut list. Here's how to find the right settings:

    1. Look up your model at https://llmdb.xyz/ to find the provider name and model identifier.
    2. Use the format "provider:model-name" (e.g., "mistral:mistral-large-latest").
    3. Set the API key environment variable — usually <PROVIDER>_API_KEY (e.g., MISTRAL_API_KEY).
    4. For a full list of supported providers, see https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html\
    """
  end

  @doc """
  Returns all unique credential key names from the catalog, including both provider
  and variant entries (since variants may use different credential keys).

  A provider's `credential_key` is contributed ONLY when the provider supports
  API-key auth (`:api_key` in its `auth_modes`); an OAuth-only provider (e.g.
  `:openai_codex`) therefore never reports a key, so
  `EvoGit.Config.api_key_present?/1` cannot mistake an OAuth subscription for a
  configured API key. Variants keep contributing theirs unconditionally.
  """
  @spec known_credential_keys() :: [String.t()]
  def known_credential_keys do
    provider_vars =
      @providers
      |> Enum.filter(&(:api_key in (&1[:auth_modes] || [:api_key])))
      |> Enum.map(& &1.credential_key)

    variant_vars =
      @providers
      |> Enum.flat_map(fn p ->
        case p[:variants] do
          nil -> []
          variants -> Enum.map(variants, & &1.credential_key)
        end
      end)

    (provider_vars ++ variant_vars)
    |> Enum.uniq()
  end

  # --- Private Helpers ---

  # Resolves a catalog entry from either an entry id or a provider atom.
  # Look up by :id first (each catalog entry has a unique :id atom, e.g.
  # :openai_compatible). This is needed because :openai_compatible shares the
  # :openai provider atom with the regular OpenAI entry, so find_provider/1
  # (which matches by provider_atoms) cannot distinguish them. Falling back to
  # find_provider/1 covers raw provider atoms.
  defp resolve_entry(provider_atom) do
    Enum.find(@providers, fn p -> p.id == provider_atom end) || find_provider(provider_atom)
  end

  defp find_model_id(models, input) do
    trimmed = String.trim(input)
    lower = String.downcase(trimmed)

    # Check exact id match first
    case Enum.find(models, fn m -> m.id == trimmed end) do
      %{id: id} ->
        id

      nil ->
        # Check display_name match (case-insensitive, trimmed)
        case Enum.find(models, fn m -> String.downcase(String.trim(m.display_name)) == lower end) do
          %{id: id} -> id
          nil -> trimmed
        end
    end
  end
end
