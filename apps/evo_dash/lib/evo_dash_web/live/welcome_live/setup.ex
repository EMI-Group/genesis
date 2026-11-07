defmodule EvoDashWeb.WelcomeLive.Setup do
  @moduledoc """
  Catalog-backed onboarding drafts and canonical provider-profile persistence.

  No legacy model profiles are created or edited here.
  Reads the user file afresh before saving, rather than persisting resolved
  defaults or migration-generated `llm.models` into the user's configuration.
  """

  use Gettext, backend: EvoDashWeb.Gettext
  alias EvoGit.Config.LLMCatalog, as: Catalog
  alias EvoGit.Config.Schema

  @reasoning_efforts ~w(none minimal low medium high xhigh default)
  def reasoning_efforts, do: @reasoning_efforts

  # The inventory and the default are independent: selecting a default must
  # never make the other advertised efforts unavailable to later task picks.
  def reasoning_efforts(entry), do: value(entry, :reasoning_efforts) || @reasoning_efforts

  def flatten_models(providers) do
    providers
    |> Enum.reject(&(&1[:custom_model] == true))
    |> Enum.flat_map(fn provider ->
      for variant <- provider[:variants] || [nil], model <- provider.models do
        resolved =
          Catalog.resolve_provider_atom(hd(provider.provider_atoms), variant && variant.id)

        %{
          provider_id: provider.id,
          provider_display_name: provider.display_name,
          variant_id: variant && variant.id,
          variant_display_name: variant && variant.display_name,
          credential_key: if(variant, do: variant.credential_key, else: provider.credential_key),
          model_id: model.id,
          model_display_name: model.display_name,
          reasoning_efforts: reasoning_efforts(model),
          resolved_atom: resolved,
          model_string: "#{resolved}:#{model.id}"
        }
      end
    end)
  end

  def provider_models(entries, provider_id, variant_id) do
    Enum.filter(entries, &(&1.provider_id == provider_id and &1.variant_id == variant_id))
  end

  def filtered_models(entries, query) do
    needle = String.downcase(String.trim(query || ""))

    Enum.filter(entries, fn entry ->
      String.contains?(String.downcase(entry.model_display_name), needle) or
        String.contains?(String.downcase(entry.variant_display_name || ""), needle)
    end)
  end

  def has_model?(config), do: Schema.model_selections(config) != []

  def auth_mode(provider) do
    if Catalog.oauth_only?(provider), do: "oauth", else: "api_key"
  end

  def can_save?(assigns) do
    entry = assigns.selected_entry

    entry != nil and
      (assigns.auth_mode == "oauth" or String.trim(assigns.api_key_input) != "" or
         Map.get(assigns.credentials, entry.credential_key) not in [nil, ""])
  end

  @doc "Validates every draft field before either credentials or config can be written."
  def prepare(config, assigns, params) do
    available =
      provider_models(
        assigns.flat_models,
        assigns.selected_provider_id,
        assigns.selected_variant_id
      )

    selected = Enum.filter(available, &(&1.model_string in assigns.selected_models))
    default = Enum.find(selected, &(&1.model_string == assigns.default_model))
    mode = assigns.auth_mode
    api_key = String.trim(Map.get(params, "api_key", assigns.api_key_input) || "")
    base_url = String.trim(Map.get(params, "base_url", assigns.base_url_input) || "")

    cond do
      selected == [] or length(selected) != length(assigns.selected_models) or is_nil(default) ->
        {:error, gettext("Choose models and a default model from the selected provider.")}

      mode not in ["api_key", "oauth"] or
        (mode == "oauth" and not Catalog.supports_oauth?(default.resolved_atom)) or
          (mode == "api_key" and Catalog.oauth_only?(default.resolved_atom)) ->
        {:error, gettext("Invalid authentication mode for this provider.")}

      mode == "api_key" and api_key == "" and
          Map.get(assigns.credentials, default.credential_key) in [nil, ""] ->
        {:error, gettext("Please enter your API key first.")}

      Catalog.requires_base_url?(default.provider_id) and base_url == "" ->
        {:error, gettext("Base URL cannot be empty.")}

      Enum.any?(selected, fn entry ->
        effort = Map.get(assigns.model_reasoning, entry.model_string, "")
        inventory = reasoning_efforts(entry)

        effort not in ["" | @reasoning_efforts] or
            (effort != "" and inventory != [] and effort not in inventory)
      end) ->
        {:error, gettext("Invalid reasoning effort.")}

      true ->
        profile =
          build_profile(config, selected, default, mode, base_url, assigns.model_reasoning)

        llm = value(config, :llm) || %{}
        providers = value(llm, :providers) || []
        llm = llm |> delete_key(:providers) |> delete_key(:default_provider_profile)

        llm =
          Map.merge(llm, %{
            providers: providers ++ [profile],
            default_provider_profile: profile["id"]
          })

        config = config |> delete_key(:llm) |> Map.put(:llm, llm)

        case Schema.validate(config) do
          {:ok, _} ->
            {:ok, config, profile, default, api_key}

          {:error, errors} ->
            # Validation errors carry raw config values, potentially credentials.
            # Only schema paths are safe to return to the browser-facing caller.
            paths = errors |> Enum.map(&Enum.join(&1.key_path, ".")) |> Enum.uniq()
            {:error, gettext("Invalid configuration: %{reason}", reason: Enum.join(paths, ", "))}
        end
    end
  end

  defp build_profile(config, entries, default, mode, base_url, reasoning) do
    existing = (value(value(config, :llm) || %{}, :providers) || []) |> Enum.map(&value(&1, :id))
    stem = Atom.to_string(default.resolved_atom) <> "-onboarding"
    id = unique_id(stem, existing, 1)

    models =
      Enum.map(entries, fn entry ->
        effort = Map.get(reasoning, entry.model_string, "")
        model = %{"model" => entry.model_id, "reasoning_efforts" => reasoning_efforts(entry)}

        if effort == "" do
          model
        else
          Map.put(model, "default_reasoning_effort", effort)
        end
      end)

    %{
      "id" => id,
      "name" => default.provider_display_name,
      "provider" => Atom.to_string(default.resolved_atom),
      "auth_mode" => mode,
      "models" => models,
      "default_model" => default.model_id
    }
    |> then(fn profile ->
      if base_url == "", do: profile, else: Map.put(profile, "base_url", base_url)
    end)
  end

  defp unique_id(stem, existing, index) do
    candidate = if index == 1, do: stem, else: "#{stem}-#{index}"
    if candidate in existing, do: unique_id(stem, existing, index + 1), else: candidate
  end

  @doc "Read without defaults/migrations; malformed or unreadable files must never be overwritten."
  def read_config do
    case File.read(EvoGit.Config.config_path()) do
      {:ok, text} ->
        case TomlElixir.decode(text) do
          {:ok, config} ->
            {:ok, config}

          {:error, reason} ->
            {:error, gettext("Cannot read configuration: %{reason}", reason: inspect(reason))}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, gettext("Cannot read configuration: %{reason}", reason: inspect(reason))}
    end
  end

  @doc """
  Resolves a validated draft into `{reqllm_model, generation_params}` for the
  server-side connection-test worker, using the same canonical resolver as tasks.

  Neither the resolved config nor generation params may be pushed to a client.
  The resolver's `model_spec` is a ReqLLM identifier, NOT a canonical task-picker
  map. Invalid drafts raise here and are reported by the worker's SafeCall boundary.
  """
  def test_request(profile, entry, reasoning) do
    config = %{llm: %{providers: [profile], default_provider_profile: profile["id"]}}
    spec = %{"provider_profile_id" => profile["id"], "model" => entry.model_id}
    effort = Map.get(reasoning, entry.model_string, "")
    spec = if effort == "", do: spec, else: Map.put(spec, "reasoning_effort", effort)
    {:ok, resolved} = Schema.resolve_model_spec(config, spec)
    {resolved.model_spec, resolved.generation_params}
  end

  def write(fun) do
    case EvoDash.SafeCall.run(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  def value(_, _), do: nil
  defp delete_key(map, key), do: map |> Map.delete(key) |> Map.delete(Atom.to_string(key))
end
