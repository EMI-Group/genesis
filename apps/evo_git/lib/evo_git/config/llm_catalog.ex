defmodule EvoGit.Config.LLMCatalog do
  @moduledoc """
  Predefined catalog of LLM providers and their popular models.

  Provides shortcuts for common provider/model combinations, so users don't need
  to memorize the "provider:model" string format. Also provides guidance for
  providers not in the catalog.
  """

  @type variant_entry :: %{
          id: atom(),
          display_name: String.t(),
          provider_atom: atom()
        }

  @type provider_entry :: %{
          id: atom(),
          display_name: String.t(),
          provider_atoms: [atom()],
          env_var: String.t(),
          models: [model_entry()],
          variants: [variant_entry()] | nil,
          custom_model: boolean() | nil,
          requires_base_url: boolean() | nil
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
      env_var: "ANTHROPIC_API_KEY",
      variants: nil,
      models: [
        %{id: "claude-opus-4-7", display_name: "Claude Opus 4.7"},
        %{id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6"}
      ]
    },
    %{
      id: :openai,
      display_name: "OpenAI",
      provider_atoms: [:openai],
      env_var: "OPENAI_API_KEY",
      variants: nil,
      models: [
        %{id: "gpt-5.5", display_name: "GPT-5.5"},
        %{id: "gpt-5.4", display_name: "GPT-5.4"}
      ]
    },
    %{
      id: :google,
      display_name: "Google",
      provider_atoms: [:google],
      env_var: "GOOGLE_API_KEY",
      variants: nil,
      models: [
        %{id: "gemini-3.1-pro", display_name: "Gemini 3.1 Pro"},
        %{id: "gemini-3.1-flash", display_name: "Gemini 3.1 Flash"}
      ]
    },
    %{
      id: :deepseek,
      display_name: "DeepSeek",
      provider_atoms: [:deepseek],
      env_var: "DEEPSEEK_API_KEY",
      variants: nil,
      models: [
        %{id: "deepseek-v4-pro", display_name: "DeepSeek V4 Pro"},
        %{id: "deepseek-v4-flash", display_name: "DeepSeek V4 Flash"}
      ]
    },
    %{
      id: :alibaba,
      display_name: "Alibaba Cloud (Qwen)",
      provider_atoms: [:alibaba, :alibaba_cn],
      env_var: "DASHSCOPE_API_KEY",
      variants: [
        %{id: :global, display_name: "Global", provider_atom: :alibaba},
        %{id: :cn, display_name: "CN", provider_atom: :alibaba_cn}
      ],
      models: [
        %{id: "qwen-3.7-max", display_name: "Qwen 3.7 Max"},
        %{id: "qwen-3.6-plus", display_name: "Qwen 3.6 Plus"}
      ]
    },
    %{
      id: :zai,
      display_name: "Z.ai (Zhipu AI)",
      provider_atoms: [:zai, :zai_coding_plan],
      env_var: "ZAI_API_KEY",
      variants: [
        %{id: :normal, display_name: "Normal API", provider_atom: :zai},
        %{id: :coding_plan, display_name: "Coding Plan", provider_atom: :zai_coding_plan}
      ],
      models: [
        %{id: "glm-5", display_name: "GLM-5"},
        %{id: "glm-5.1", display_name: "GLM-5.1"},
        %{id: "glm-5.2", display_name: "GLM-5.2"}
      ]
    },
    %{
      id: :minimax,
      display_name: "MiniMax",
      provider_atoms: [:minimax],
      env_var: "MINIMAX_API_KEY",
      variants: nil,
      models: [
        %{id: "MiniMax-M2.7", display_name: "MiniMax-M2.7"},
        %{id: "MiniMax-M2.7-highspeed", display_name: "MiniMax-M2.7 Highspeed"},
        %{id: "MiniMax-M3", display_name: "MiniMax-M3"}
      ]
    },
    %{
      id: :openrouter,
      display_name: "OpenRouter",
      provider_atoms: [:openrouter],
      env_var: "OPENROUTER_API_KEY",
      variants: nil,
      models: [],
      custom_model: true
    },
    %{
      id: :openai_compatible,
      display_name: "OpenAI-Compatible API",
      provider_atoms: [:openai],
      env_var: "OPENAI_API_KEY",
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
      nil -> provider_atom
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
  def resolve_model(provider_atom, model_input) when is_atom(provider_atom) and is_binary(model_input) do
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

      iex> EvoGit.Config.LLMCatalog.resolve_model_spec(:openai, "gpt-5.5", base_url: "https://my.proxy/v1")
      %{provider: :openai, id: "gpt-5.5", base_url: "https://my.proxy/v1"}

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
        nil -> spec
        "" -> spec
        base_url -> Map.put(spec, :base_url, base_url)
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
    case find_provider(provider_atom) do
      nil -> false
      provider -> provider[:requires_base_url] == true
    end
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
  Returns all unique env var names from the catalog.
  """
  @spec known_env_vars() :: [String.t()]
  def known_env_vars do
    @providers
    |> Enum.map(& &1.env_var)
    |> Enum.uniq()
  end

  # --- Private Helpers ---

  defp find_model_id(models, input) do
    trimmed = String.trim(input)
    lower = String.downcase(trimmed)

    # Check exact id match first
    case Enum.find(models, fn m -> m.id == trimmed end) do
      %{id: id} -> id
      nil ->
        # Check display_name match (case-insensitive, trimmed)
        case Enum.find(models, fn m -> String.downcase(String.trim(m.display_name)) == lower end) do
          %{id: id} -> id
          nil -> trimmed
        end
    end
  end
end
