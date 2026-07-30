defmodule EvoGit.CLI.Setup do
  @moduledoc """
  Interactive setup wizard for LLM provider and API key configuration.

  Extracted from `EvoGit.CLI` to separate the guided setup workflow
  from command dispatch.
  """

  @doc """
  Runs the interactive LLM configuration setup wizard.

  Guides the user through provider selection, model choice, and API key
  entry, then persists the results to `config.toml` and `credentials.toml`.
  """
  def run do
    alias EvoGit.Config.LLMCatalog

    IO.puts("""

    ╔══════════════════════════════════════════════════════╗
    ║            EvoGit LLM Configuration Setup           ║
    ╚══════════════════════════════════════════════════════╝
    """)

    # Step 1: Provider selection
    providers = LLMCatalog.providers()

    IO.puts("Step 1: Choose your LLM provider:\n")

    providers
    |> Enum.with_index(1)
    |> Enum.each(fn {provider, idx} ->
      IO.puts("  #{idx}. #{provider.display_name}")
    end)

    IO.puts("  #{length(providers) + 1}. Other (custom provider)")
    IO.puts("  0. Exit")
    IO.puts("")

    provider_choice = prompt_input("Enter your choice [0-#{length(providers) + 1}]: ")

    case parse_int(provider_choice) do
      nil ->
        IO.puts("\nInvalid choice. Aborting.")

      0 ->
        IO.puts("\nSetup cancelled.")

      n when n >= 1 and n <= length(providers) ->
        provider = Enum.at(providers, n - 1)
        setup_provider(provider)

      n when n == length(providers) + 1 ->
        setup_custom_provider()

      _ ->
        IO.puts("\nInvalid choice. Aborting.")
    end
  end

  defp setup_provider(provider) do
    alias EvoGit.Config.LLMCatalog

    IO.puts("\nSelected: #{provider.display_name}")
    IO.puts("API key credential key: #{provider.credential_key}\n")

    # Step 2: Model selection
    models = provider.models

    IO.puts("Step 2: Choose a model:\n")

    models
    |> Enum.with_index(1)
    |> Enum.each(fn {model, idx} ->
      IO.puts("  #{idx}. #{model.display_name} (#{model.id})")
    end)

    IO.puts("  #{length(models) + 1}. Custom model name")
    IO.puts("")

    model_choice = prompt_input("Enter your choice [1-#{length(models) + 1}]: ")

    model_id =
      case parse_int(model_choice) do
        nil ->
          IO.puts("\nInvalid choice. Using custom input.")
          prompt_input("Enter model name: ")

        n when n >= 1 and n <= length(models) ->
          model = Enum.at(models, n - 1)
          IO.puts("\n  ✓ Selected: #{model.display_name}")
          model.id

        n when n == length(models) + 1 ->
          prompt_input("Enter model name: ")

        _ ->
          IO.puts("\nInvalid choice. Using custom input.")
          prompt_input("Enter model name: ")
      end

    # Variant selection — only for providers that offer multiple endpoint
    # variants (e.g. Alibaba Global/CN, Z.ai Normal/Coding Plan).
    variant = prompt_variant(provider)

    # Build a map model spec via the catalog. Named providers generally do not
    # need a base_url, so the resulting map is %{provider: atom, id: string}.
    model_spec =
      LLMCatalog.resolve_model_spec(hd(provider.provider_atoms), model_id, variant: variant)

    # Step 3: API key
    IO.puts("\nStep 3: Enter your API key.")
    IO.puts("  This will be stored in your credentials file.\n")

    api_key = prompt_input("Enter #{provider.credential_key}: ")

    if api_key == "" do
      IO.puts("\nNo API key entered. API key can be set later in credentials.toml.")
    end

    # Save everything
    save_setup_result(model_spec, provider.credential_key, api_key)
  end

  defp setup_custom_provider do
    IO.puts("\n" <> String.trim(EvoGit.Config.LLMCatalog.unknown_provider_help()))
    IO.puts("")

    provider = prompt_input("Enter the provider name (e.g. openai, mistral, deepseek): ")

    if provider == "" do
      IO.puts("\nNo provider entered. Setup cancelled.")
    else
      model_id = prompt_input("Enter the model id (e.g. gpt-4o, custom-model): ")

      if model_id == "" do
        IO.puts("\nNo model id entered. Setup cancelled.")
      else
        # The whole point of the custom path is proxy/aggregator endpoints.
        base_url = prompt_input("Enter the base_url (e.g. https://my-proxy.com/v1): ")

        if base_url == "" do
          IO.puts(
            "\n  ⚠ No base_url provided. The endpoint will not work for OpenAI-compatible providers that require it."
          )
        end

        # Atomize the provider name (returns the atom if it exists, else the string).
        provider_atom = safe_to_existing_atom(String.downcase(provider))

        IO.puts("\n  Provider: #{provider}")
        IO.puts("  Model id: #{model_id}")

        if base_url != "" do
          IO.puts("  Base URL: #{base_url}")
        end

        credential_key = String.upcase(provider) <> "_API_KEY"
        IO.puts("  Expected API key credential key: #{credential_key}")

        IO.puts(
          "  (If this is incorrect, check https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html)\n"
        )

        # Build the map model spec. base_url is included only when non-empty
        # (resolve_model_spec omits nil/"" values).
        model_spec =
          EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_id, base_url: base_url)

        api_key = prompt_input("Enter #{credential_key}: ")

        save_setup_result(model_spec, credential_key, api_key)
      end
    end
  end

  defp save_setup_result(model_spec, credential_key, api_key) do
    # Save model to config.toml using the [[llm.models]] array format
    existing_config = EvoGit.Config.user_config()

    # Build atom-keyed config with the model added as a profile
    config =
      existing_config
      |> atomize_config_keys()
      |> ensure_llm_section()
      |> add_model_profile(model_spec)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        IO.puts("\n  ✓ Model saved to config.toml: #{format_model_for_display(model_spec)}")

        # Save API key to credentials.toml if provided
        if api_key != "" do
          case EvoGit.Config.save_credentials(%{credential_key => api_key}) do
            :ok ->
              IO.puts("  ✓ API key saved to credentials.toml: #{credential_key}")

            {:error, reason} ->
              IO.puts("  ✗ Failed to save API key: #{inspect(reason)}")
              IO.puts("    You can manually add it to your credentials.toml:")
              IO.puts("    #{credential_key} = \"your-api-key\"")
          end
        end

        IO.puts("\n  Config file: #{EvoGit.Config.config_path()}")
        IO.puts("  Credentials file: #{EvoGit.Config.credentials_path()}")
        IO.puts("\n✅ Setup complete! You can now run:")
        IO.puts("  evogit genesis \"your prompt here\"")

      {:error, reason} ->
        IO.puts("\n  ✗ Failed to save config: #{inspect(reason)}")
    end
  end

  defp prompt_input(prompt) do
    case IO.gets(prompt) do
      nil -> ""
      input -> String.trim(input)
    end
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp atomize_config_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        # Justified: String.to_existing_atom/1 has no non-throwing variant.
        # It is deliberately used (instead of String.to_atom/1) to avoid
        # atom-table exhaustion from arbitrary user-supplied config keys.
        # When the atom doesn't already exist, we keep the key as a string.
        atom_key = safe_to_existing_atom(key)

        {atom_key, atomize_config_keys(value)}

      {key, value} ->
        {key, atomize_config_keys(value)}
    end)
  end

  defp atomize_config_keys(value), do: value

  # Returns the existing atom for `key`, or the original string if the atom
  # does not exist.
  #
  # Justified: String.to_existing_atom/1 has no non-throwing variant
  # (no {:ok, _} | :error tuple form). It is deliberately used (instead of
  # String.to_atom/1) to avoid atom-table exhaustion from arbitrary
  # user-supplied config keys. When the atom doesn't already exist, we
  # return the original string.
  defp safe_to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp ensure_llm_section(config) do
    llm = Map.get(config, :llm, %{})
    Map.put(config, :llm, Map.put_new(llm, :models, []))
  end

  # Adds a model spec to the [[llm.models]] array.
  #
  # `model` may be either:
  #   * a string in "provider:model" form (legacy — normalized to a map later
  #     by Config.resolve/0), or
  #   * a map spec like %{provider: :openai, id: "gpt-5.5", base_url: "..."}
  #     (new — stored directly).
  #
  # If a profile with the id "default" already exists, its model is updated.
  # Otherwise a new "default" profile is created/appended. This keeps the
  # setup wizard simple — it always operates on the default profile.
  # Each profile gets its own concurrency setting (defaults to 3).
  defp add_model_profile(config, model) do
    llm = Map.get(config, :llm, %{})
    models = Map.get(llm, :models, [])

    updated_models =
      case models do
        [] ->
          # No profiles yet — create the default profile
          [%{id: "default", model: model, concurrency: 3}]

        existing ->
          case Enum.find_index(existing, fn p -> Map.get(p, :id) == "default" end) do
            nil ->
              # Profiles exist but none is "default" — append a new one
              existing ++ [%{id: "default", model: model, concurrency: 3}]

            idx ->
              # Update the existing default profile's model
              List.update_at(existing, idx, fn p ->
                Map.put(p, :model, model)
              end)
          end
      end

    llm = Map.put(llm, :models, updated_models)
    # Mirror the default profile's model to llm.model for backward compat
    llm = Map.put(llm, :model, model)
    Map.put(config, :llm, llm)
  end

  @doc false
  # Public test wrapper for add_model_profile/2
  def do_add_model_profile(config, model), do: add_model_profile(config, model)

  # Prompts the user to select a variant when the provider offers multiple
  # endpoint variants (e.g. Alibaba Global/CN). Returns the chosen variant id
  # (atom) or `nil` when the provider has no variants.
  defp prompt_variant(provider) do
    variants = provider[:variants]

    if is_list(variants) and variants != [] do
      IO.puts("\nThis provider offers multiple endpoint variants:\n")

      variants
      |> Enum.with_index(1)
      |> Enum.each(fn {variant, idx} ->
        IO.puts("  #{idx}. #{variant.display_name}")
      end)

      IO.puts("")
      choice = prompt_input("Enter your choice [1-#{length(variants)}] (default: 1): ")

      case parse_int(choice) do
        n when n >= 1 and n <= length(variants) ->
          Enum.at(variants, n - 1).id

        _ ->
          # Default to the first/canonical variant on invalid input.
          hd(variants).id
      end
    else
      nil
    end
  end

  # Formats a model spec for human-friendly display in the setup success
  # message. Accepts either a map spec (new) or a "provider:model" string
  # (legacy).
  defp format_model_for_display(%{provider: provider, id: id} = model) do
    base = "#{provider}:#{id}"
    extra = Map.get(model, :base_url)

    if extra do
      "#{base} (base_url: #{extra})"
    else
      base
    end
  end

  defp format_model_for_display(model) when is_map(model), do: inspect(model)
  defp format_model_for_display(model) when is_binary(model), do: model
end
