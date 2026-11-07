defmodule EvoGit.CLI.Setup do
  @moduledoc """
  Interactive setup wizard for LLM provider and API key configuration.

  Extracted from `EvoGit.CLI` to separate the guided setup workflow
  from command dispatch.

  OAuth-capable providers (see `EvoGit.Config.LLMCatalog.auth_modes/1`) get an
  extra authentication-mode step: instead of pasting an API key the user may
  reuse an existing vendor subscription login (`codex login` / `claude`), which
  `EvoGit.Auth` imports into the managed OAuth credential file.
  """

  alias EvoGit.Config.{LLMCatalog, Schema}

  @doc """
  Runs the interactive LLM configuration setup wizard.

  Guides the user through provider selection, model choice, and either API key
  entry or a subscription (OAuth) login, then persists the results to
  `config.toml` (and `credentials.toml` for the API-key branch).
  """
  def run do
    IO.puts("""

    ╔══════════════════════════════════════════════════════╗
    ║            Genesis LLM Configuration Setup          ║
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
    IO.puts("\nSelected: #{provider.display_name}")

    if LLMCatalog.oauth_only?(provider.id) do
      IO.puts("Authentication: subscription (OAuth) — no API key is used.\n")
    else
      IO.puts("Default API key credential key: #{provider.credential_key}\n")
    end

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

    # Step 3: Authentication mode. Only OAuth-capable providers get the choice;
    # everything else keeps the original numbering (API key = "Step 3").
    auth_provider = model_spec.provider

    if LLMCatalog.supports_oauth?(auth_provider) do
      case prompt_auth_mode(provider, auth_provider) do
        :oauth -> setup_oauth_credentials(provider, model_spec)
        :api_key -> prompt_api_key(provider, model_spec, 4)
      end
    else
      prompt_api_key(provider, model_spec, 3)
    end
  end

  # Step 3, dual-mode providers: ask whether this provider should authenticate
  # with a pasted API key or with an existing subscription (OAuth) login.
  # An OAuth-only provider has nothing to ask — the step only announces the
  # branch so the user is not surprised by the missing API-key prompt.
  defp prompt_auth_mode(provider, provider_atom) do
    if LLMCatalog.oauth_only?(provider_atom) do
      IO.puts("\nStep 3: Subscription (OAuth) — #{provider.display_name} uses an existing login.")
      IO.puts("  No API key is needed (or accepted) for this provider.")

      :oauth
    else
      IO.puts("\nStep 3: Choose how to authenticate #{provider.display_name}:\n")
      IO.puts("  1. API key (paste a key; billed per token)")
      IO.puts("  2. Subscription (OAuth) — use an existing ChatGPT/Claude login")
      IO.puts("")

      choice = prompt_input("Enter your choice [1-2] (default: 1): ")

      resolve_auth_choice(provider_atom, choice)
    end
  end

  # Resolve the selected account before prompting, just as for its OAuth path.
  defp prompt_api_key(provider, model_spec, step) do
    credential_key = setup_credential_key(model_spec, provider.credential_key)
    IO.puts("\nStep #{step}: Enter your API key.")
    IO.puts("  This will be stored in your credentials file.\n")

    api_key = prompt_input("Enter #{credential_key}: ")

    if api_key == "" do
      IO.puts("\nNo API key entered. API key can be set later in credentials.toml.")
    end

    save_setup_result(model_spec, credential_key, api_key)
  end

  # The OAuth branch: reuse the vendor CLI's existing login. Nothing is ever
  # written to credentials.toml here and no API key is ever requested — the
  # managed OAuth file (`EvoGit.Auth.oauth_file/1`) is the only credential
  # store involved, and ReqLLM keeps it fresh.
  defp setup_oauth_credentials(provider, model_spec) do
    provider_atom = model_spec.provider
    oauth_opts = setup_oauth_opts(model_spec)

    IO.puts("\nStep 4: Subscription (OAuth) login")

    case find_vendor_login(provider_atom) do
      nil ->
        IO.puts("  • No local #{login_source_label(provider_atom)} login found.")

      path ->
        IO.puts("  • Found local login: #{path}")
    end

    case EvoGit.Auth.ensure_credentials(provider_atom, oauth_opts) do
      :ok ->
        IO.puts("  ✓ OAuth credentials ready: #{EvoGit.Auth.oauth_file(oauth_opts)}")
        save_setup_result(model_spec, provider.credential_key, "", auth_mode: "oauth")

      {:error, reason} ->
        print_auth_failure(provider_atom, reason, oauth_opts)

        if confirm("\n  Save the profile with OAuth auth mode anyway? [Y/n]: ") do
          save_setup_result(model_spec, provider.credential_key, "", auth_mode: "oauth")
        else
          IO.puts("\nSetup cancelled. Re-run `genesis setup` once you are logged in.")
        end
    end
  end

  # A managed-file write failure is NOT a missing login: the vendor login was
  # found, so printing the login instructions would send the user in circles.
  # The writable-path remedy is printed instead, and setup can still finish.
  defp print_auth_failure(_provider_atom, {:managed_file_unwritable, _} = error, oauth_opts) do
    IO.puts("  ⚠ The subscription login was found, but Genesis could not write its")
    IO.puts("  managed OAuth copy.\n")

    IO.puts(
      indent(
        EvoGit.Auth.managed_file_unwritable_remedy(error, EvoGit.Auth.oauth_file(oauth_opts))
      )
    )

    IO.puts("")
    IO.puts("  You can still finish setup: save the profile now and requests start")
    IO.puts("  working once the managed file is writable.")
  end

  defp print_auth_failure(provider_atom, reason, _oauth_opts) do
    IO.puts("  ⚠ No usable OAuth credentials yet (#{format_auth_error(reason)}).\n")
    IO.puts(indent(EvoGit.Auth.login_instructions(provider_atom)))
    IO.puts("")
    IO.puts("  Re-run `genesis setup` after logging in — or save the profile now and it")
    IO.puts("  starts working as soon as the login exists.")
  end

  # Which vendor CLI wrote the login we are about to import — used only for the
  # human-facing "no local login found" line.
  defp login_source_label(provider_atom) do
    case LLMCatalog.oauth_source(provider_atom) do
      :codex_cli -> "Codex CLI"
      :claude_code -> "Claude Code"
      _other -> "vendor CLI"
    end
  end

  # Short human-readable form of an `EvoGit.Auth.ensure_credentials/2` error.
  defp format_auth_error(:no_credentials), do: "no credentials found"
  defp format_auth_error(:invalid_credentials), do: "the stored credential is unusable"
  defp format_auth_error(:expired_credentials), do: "the stored credential has expired"
  defp format_auth_error(reason), do: inspect(reason)

  # Indents every line of a multi-line guidance block by two spaces so the
  # vendor login instructions line up with the rest of the wizard output.
  defp indent(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  # Yes/no confirmation. The EMPTY answer is the documented default in the
  # prompt text, so it maps to `true` (keep going).
  defp confirm(prompt) do
    case prompt_input(prompt) do
      "" -> true
      input -> String.downcase(input) in ["y", "yes"]
    end
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

        # Build the map model spec before resolving the selected account's key.
        model_spec =
          EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_id, base_url: base_url)

        credential_key = setup_credential_key(model_spec, String.upcase(provider) <> "_API_KEY")
        IO.puts("  Expected API key credential key: #{credential_key}")

        IO.puts(
          "  (If this is incorrect, check https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html)\n"
        )

        api_key = prompt_input("Enter #{credential_key}: ")

        save_setup_result(model_spec, credential_key, api_key)
      end
    end
  end

  # `opts[:auth_mode]` is "oauth" for the subscription branch; nil selects
  # API-key authentication and clears an earlier OAuth choice.
  defp save_setup_result(model_spec, credential_key, api_key, opts \\ []) do
    existing_config = EvoGit.Config.user_config()
    config = prepare_config(existing_config, model_spec, Keyword.get(opts, :auth_mode))
    credential_key = credential_key_for_config(config, credential_key)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        IO.puts("\n  ✓ Model saved to config.toml: #{format_model_for_display(model_spec)}")

        if Keyword.get(opts, :auth_mode) == "oauth" do
          IO.puts("  ✓ Auth mode: subscription (OAuth) — no API key required")
        end

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

        if Keyword.get(opts, :auth_mode) == "oauth" do
          IO.puts(
            "  OAuth credentials file: #{EvoGit.Auth.oauth_file(oauth_opts_for_config(config))}"
          )
        else
          IO.puts("  Credentials file: #{EvoGit.Config.credentials_path()}")
        end

        IO.puts("\n✅ Setup complete! You can now run:")
        IO.puts("  genesis genesis \"your prompt here\"")

      {:error, reason} ->
        IO.puts("\n  ✗ Failed to save config: #{inspect(reason)}")
    end
  end

  defp setup_oauth_opts(model_spec) do
    EvoGit.Config.user_config()
    |> prepare_config(model_spec, "oauth")
    |> oauth_opts_for_config()
  end

  defp setup_credential_key(model_spec, fallback) do
    EvoGit.Config.user_config()
    |> prepare_config(model_spec, nil)
    |> credential_key_for_config(fallback)
  end

  # Config.save_credentials/1 merges by the exact string key, so retain account
  # isolation instead of overwriting the provider-wide catalog credential.
  defp credential_key_for_config(config, fallback) do
    case selected_profile(config)[:api_key_env_var] do
      name when is_binary(name) and name != "" -> name
      _ -> fallback
    end
  end

  defp selected_profile(%{llm: llm}),
    do: Enum.find(llm.providers, &(&1.id == llm.default_provider_profile))

  defp oauth_opts_for_config(config) do
    case selected_profile(config)[:oauth_file] do
      path when is_binary(path) and path != "" -> [oauth_file: path]
      _ -> []
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

  # Lists MUST recurse: `[[llm.models]]` decodes to a list of STRING-keyed
  # profile maps, so a profile lookup would otherwise never match the existing
  # "default" profile (and a stale `auth_mode` could never be cleared).
  defp atomize_config_keys(list) when is_list(list),
    do: Enum.map(list, &atomize_config_keys/1)

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

  # Schema owns legacy migration: setup never reimplements how flat [llm] or
  # [[llm.models]] becomes provider profiles, and never saves both formats.
  @legacy_llm_fields ~w(models model temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty)a

  defp add_model_profile(config, model, auth_mode \\ nil) do
    config = atomize_config_keys(config)
    llm = Map.get(config, :llm, %{})
    profiles = config |> Schema.provider_profiles() |> atomize_config_keys()
    model = setup_model(model)
    provider = to_string(model.provider)
    default_id = Map.get(llm, :default_provider_profile)
    # Match Schema's default selection: absent an explicit ID, the FIRST
    # account wins, not an unrelated account that happens to be named "default".
    current =
      if is_nil(default_id),
        do: List.first(profiles),
        else: Enum.find(profiles, &(&1[:id] == default_id))

    # Updating an account on the same provider preserves its shared limits,
    # generation defaults, nested model overrides and custom OAuth path.
    # Choosing a different provider creates another profile rather than
    # overwriting an existing account's endpoint/authentication settings.

    {profile, profiles} =
      if current && to_string(current[:provider]) == provider do
        profile = update_provider_profile(current, model, auth_mode)
        {profile, Enum.map(profiles, fn p -> if p[:id] == current[:id], do: profile, else: p end)}
      else
        id = available_profile_id(profiles, if(profiles == [], do: "default", else: provider))

        profile =
          update_provider_profile(
            %{id: id, concurrency: 3, reasoning_efforts: []},
            model,
            auth_mode
          )

        {profile, profiles ++ [profile]}
      end

    llm =
      llm
      |> Map.drop(@legacy_llm_fields)
      |> Map.put(:providers, profiles)
      |> Map.put(:default_provider_profile, profile.id)

    Map.put(config, :llm, llm)
  end

  defp update_provider_profile(profile, model, auth_mode) do
    models = Map.get(profile, :models, [])

    # The default must belong to the account's ordered inventory. Keep an
    # existing entry verbatim so its per-model limits/efforts are not erased.
    models =
      if Enum.any?(models, &(&1[:model] == model.id)),
        do: models,
        else: models ++ [%{model: model.id}]

    profile
    |> Map.merge(Map.drop(model, [:id]))
    |> Map.put(:provider, to_string(model.provider))
    |> Map.put(:models, models)
    |> Map.put(:default_model, model.id)
    |> apply_auth_mode(auth_mode)
  end

  defp available_profile_id(profiles, base) do
    ids = MapSet.new(profiles, & &1[:id])

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      id = if n == 1, do: base, else: "#{base}-#{n}"
      if not MapSet.member?(ids, id), do: id
    end)
  end

  defp setup_model(model) when is_map(model), do: atomize_config_keys(model)

  defp setup_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" -> %{provider: provider, id: id}
      _ -> raise ArgumentError, "setup model must be a provider:model string or model map"
    end
  end

  @doc false
  # Retained public test seams; both now produce canonical provider profiles.
  def do_add_model_profile(config, model), do: add_model_profile(config, model)

  @doc false
  def do_add_model_profile(config, model, auth_mode),
    do: add_model_profile(config, model, auth_mode)

  defp prepare_config(existing_config, model_spec, auth_mode) do
    add_model_profile(existing_config, model_spec, auth_mode)
  end

  @doc false
  # Public test wrapper for prepare_config/3.
  def do_prepare_config(existing_config, model_spec, auth_mode),
    do: prepare_config(existing_config, model_spec, auth_mode)

  # Applies an auth mode to a profile map: `"oauth"` sets the key, anything
  # else (the API-key default) REMOVES it — an absent key is the documented
  # default, and a stale `"oauth"` value must never survive a switch back.
  @doc false
  def apply_auth_mode(profile, "oauth") when is_map(profile),
    do: Map.put(profile, :auth_mode, "oauth")

  def apply_auth_mode(profile, _auth_mode) when is_map(profile),
    do: Map.drop(profile, [:auth_mode, "auth_mode"])

  # Resolves the Step-3 answer into an auth mode.
  #
  #   * an OAuth-ONLY provider always resolves to `:oauth` (there is no
  #     question to answer — `:api_key` does not exist for it)
  #   * a provider that does not support OAuth always resolves to `:api_key`
  #   * a dual-mode provider takes `:oauth` only for an explicit option 2
  #     ("2" / "oauth" / "subscription"); EMPTY and invalid input default to
  #     `:api_key` — the wizard never defaults INTO OAuth.
  @doc false
  def resolve_auth_choice(provider_atom, input) when is_atom(provider_atom) do
    cond do
      LLMCatalog.oauth_only?(provider_atom) -> :oauth
      not LLMCatalog.supports_oauth?(provider_atom) -> :api_key
      normalize_auth_choice(input) == :oauth -> :oauth
      true -> :api_key
    end
  end

  def resolve_auth_choice(_provider_atom, _input), do: :api_key

  defp normalize_auth_choice(input) when is_binary(input) do
    case String.downcase(String.trim(input)) do
      "2" -> :oauth
      "oauth" -> :oauth
      "subscription" -> :oauth
      _other -> :api_key
    end
  end

  defp normalize_auth_choice(_input), do: :api_key

  # Returns the FIRST existing vendor login file for `provider_atom` (see
  # `EvoGit.Auth.OAuthImport.sources/2`), or `nil` when the user has not
  # logged in with the vendor CLI yet. Never touches the network.
  @doc false
  def find_vendor_login(provider_atom, opts \\ []) do
    provider_atom
    |> EvoGit.Auth.OAuthImport.sources(opts)
    |> Enum.find(&File.exists?/1)
  end

  @doc false
  def oauth_available?(provider_atom, opts \\ []),
    do: not is_nil(find_vendor_login(provider_atom, opts))

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
