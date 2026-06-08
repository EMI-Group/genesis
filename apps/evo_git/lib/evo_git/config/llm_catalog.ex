defmodule EvoGit.Config.LLMCatalog do
  @moduledoc """
  Predefined catalog of LLM providers and their popular models.

  Provides shortcuts for common provider/model combinations, so users don't need
  to memorize the "provider:model" string format. Also provides guidance for
  providers not in the catalog.
  """

  @type provider_entry :: %{
          id: atom(),
          display_name: String.t(),
          provider_atoms: [atom()],
          env_var: String.t(),
          models: [model_entry()]
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
      models: [
        %{id: "claude-opus-4-20250514", display_name: "Claude Opus 4"},
        %{id: "claude-sonnet-4-20250514", display_name: "Claude Sonnet 4"},
        %{id: "claude-haiku-4-20250514", display_name: "Claude Haiku 4"},
        %{id: "claude-3.5-sonnet-20241022", display_name: "Claude 3.5 Sonnet"},
        %{id: "claude-3.5-haiku-20241022", display_name: "Claude 3.5 Haiku"},
        %{id: "claude-3-opus-20240229", display_name: "Claude 3 Opus"}
      ]
    },
    %{
      id: :openai,
      display_name: "OpenAI",
      provider_atoms: [:openai],
      env_var: "OPENAI_API_KEY",
      models: [
        %{id: "gpt-4.1", display_name: "GPT-4.1"},
        %{id: "gpt-4.1-mini", display_name: "GPT-4.1 Mini"},
        %{id: "gpt-4.1-nano", display_name: "GPT-4.1 Nano"},
        %{id: "gpt-4o", display_name: "GPT-4o"},
        %{id: "gpt-4o-mini", display_name: "GPT-4o Mini"},
        %{id: "o3", display_name: "o3"},
        %{id: "o4-mini", display_name: "o4 Mini"}
      ]
    },
    %{
      id: :google,
      display_name: "Google",
      provider_atoms: [:google],
      env_var: "GOOGLE_API_KEY",
      models: [
        %{id: "gemini-2.5-pro-preview-06-05", display_name: "Gemini 2.5 Pro"},
        %{id: "gemini-2.5-flash-preview-05-20", display_name: "Gemini 2.5 Flash"},
        %{id: "gemini-2.0-flash", display_name: "Gemini 2.0 Flash"},
        %{id: "gemini-2.0-flash-lite", display_name: "Gemini 2.0 Flash Lite"},
        %{id: "gemini-1.5-pro", display_name: "Gemini 1.5 Pro"},
        %{id: "gemini-1.5-flash", display_name: "Gemini 1.5 Flash"}
      ]
    },
    %{
      id: :deepseek,
      display_name: "DeepSeek",
      provider_atoms: [:deepseek],
      env_var: "DEEPSEEK_API_KEY",
      models: [
        %{id: "deepseek-r1", display_name: "DeepSeek R1"},
        %{id: "deepseek-chat", display_name: "DeepSeek V3 (Chat)"},
        %{id: "deepseek-coder", display_name: "DeepSeek Coder"},
        %{id: "deepseek-reasoner", display_name: "DeepSeek Reasoner"}
      ]
    },
    %{
      id: :zai_coding_plan,
      display_name: "ZAI (Coding Plan)",
      provider_atoms: [:zai, :zai_coding_plan, :zai_coder],
      env_var: "ZAI_API_KEY",
      models: [
        %{id: "glm-4.1v", display_name: "GLM-4.1V"},
        %{id: "glm-4-plus", display_name: "GLM-4 Plus"},
        %{id: "glm-4-air", display_name: "GLM-4 Air"},
        %{id: "glm-4-airx", display_name: "GLM-4 AirX"},
        %{id: "glm-4-long", display_name: "GLM-4 Long"},
        %{id: "glm-4-flash", display_name: "GLM-4 Flash"},
        %{id: "glm-4-flashx", display_name: "GLM-4 FlashX"}
      ]
    },
    %{
      id: :alibaba,
      display_name: "Alibaba Cloud (Qwen)",
      provider_atoms: [:alibaba, :alibaba_cn],
      env_var: "DASHSCOPE_API_KEY",
      models: [
        %{id: "qwen-max", display_name: "Qwen Max"},
        %{id: "qwen-plus", display_name: "Qwen Plus"},
        %{id: "qwen-turbo", display_name: "Qwen Turbo"},
        %{id: "qwen-coder-plus", display_name: "Qwen Coder Plus"},
        %{id: "qwen-coder-turbo", display_name: "Qwen Coder Turbo"},
        %{id: "qwen-long", display_name: "Qwen Long"}
      ]
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
