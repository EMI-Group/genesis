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
        %{id: "claude-opus-4-7", display_name: "Claude Opus 4.7"},
        %{id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6"}
      ]
    },
    %{
      id: :openai,
      display_name: "OpenAI",
      provider_atoms: [:openai],
      env_var: "OPENAI_API_KEY",
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
      models: [
        %{id: "qwen-3.7-max", display_name: "Qwen 3.7 Max"},
        %{id: "qwen-3.6-plus", display_name: "Qwen 3.6 Plus"}
      ]
    },
    %{
      id: :zai,
      display_name: "Z.ai (Zhipu AI)",
      provider_atoms: [:zai],
      env_var: "ZAI_API_KEY",
      models: [
        %{id: "glm-5", display_name: "GLM-5"},
        %{id: "glm-5.1", display_name: "GLM-5.1"}
      ]
    },
    %{
      id: :zai_coding_plan,
      display_name: "Z.ai Coding Plan",
      provider_atoms: [:zai_coding_plan],
      env_var: "ZAI_API_KEY",
      models: [
        %{id: "glm-5", display_name: "GLM-5"},
        %{id: "glm-5.1", display_name: "GLM-5.1"}
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
