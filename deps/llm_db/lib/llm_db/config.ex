defmodule LLMDB.Config do
  @moduledoc """
  Configuration reading and normalization for LLMDB.

  Reads from Application environment and provides normalized config maps
  and compiled filter patterns.
  """

  @doc """
  Returns the list of sources to load, in precedence order.

  These sources provide raw data that will be merged ON TOP of the packaged
  base snapshot. The packaged snapshot is always loaded first and is not
  included in this sources list.

  ## Configuration

      config :llm_db,
        sources: [
          {LLMDB.Sources.ModelsDev, %{}},
          {LLMDB.Sources.Local, %{dir: "priv/llm_db"}}
        ]

  ## Default Behavior

  If not configured, returns an empty list `[]`, meaning only the packaged
  snapshot will be used (stable, version-pinned behavior).

  ## Returns

  List of `{module, opts}` tuples in precedence order (first = lowest precedence).
  """
  @spec sources!() :: [{module(), map()}]
  def sources! do
    config = Application.get_all_env(:llm_db)

    case Keyword.get(config, :sources) do
      nil ->
        # Default: Empty list - only use packaged snapshot (stable mode)
        []

      sources when is_list(sources) ->
        sources
    end
  end

  @doc """
  Returns normalized configuration map from Application environment.

  Reads `:llm_db` application config and normalizes with defaults.

  ## Configuration Format

      config :llm_db,
        allow: :all,  # or [:openai, :anthropic] or %{openai: ["gpt-4*"]}
        deny: %{},    # or [:provider] or %{provider: ["pattern"]}
        prefer: [:openai, :anthropic],
        custom: %{
          vllm: [
            name: "Local vLLM Provider",
            base_url: "http://localhost:8000/v1",
            models: %{
              "llama-3" => %{capabilities: %{chat: true}},
              "mistral-7b" => %{capabilities: %{chat: true, tools: %{enabled: true}}}
            }
          ],
          custom_provider: [
            name: "My Custom Provider",
            models: %{
              "model-1" => %{capabilities: %{chat: true}}
            }
          ]
        }

  Provider keys can be atoms or strings. Patterns support glob syntax with `*` wildcards.

  Custom providers are defined with provider ID as key, and a keyword list containing:
  - `:name` - Provider name (optional)
  - `:base_url` - Base URL for API (optional)
  - `:models` - Map of model ID to model config

  ## Returns

  A map with keys:
  - `:compile_embed` - Whether to compile-time embed snapshot (default: false)
  - `:snapshot_source` - Snapshot source descriptor (default: `:packaged`)
  - `:allow` - Allow patterns (`:all` or `%{provider => [patterns]}`)
  - `:deny` - Deny patterns (`%{provider => [patterns]}`)
  - `:prefer` - List of preferred provider atoms
  - `:custom` - Custom providers map (provider_id => provider_config)
  """
  @spec get() :: map()
  def get do
    config = Application.get_all_env(:llm_db)

    # Support both new top-level keys and legacy :filter key
    filter = Keyword.get(config, :filter, %{}) || %{}
    allow = Keyword.get(config, :allow, Map.get(filter, :allow, :all))
    deny = Keyword.get(config, :deny, Map.get(filter, :deny, %{}))

    %{
      compile_embed: Keyword.get(config, :compile_embed, false),
      snapshot_source: Keyword.get(config, :snapshot_source, :packaged),
      allow: allow,
      deny: deny,
      prefer: Keyword.get(config, :prefer, []),
      custom: Keyword.get(config, :custom, %{})
    }
  end

  @doc """
  Compiles allow/deny filter patterns to regexes for performance.

  ## Parameters

  - `allow` - `:all` or `%{provider_atom => [pattern_strings]}`
  - `deny` - `%{provider_atom => [pattern_strings]}`
  - `known_providers` - Optional list of known provider atoms for validation (defaults to all existing atoms)

  Patterns support glob syntax with `*` wildcards via `LLMDB.Merge.compile_pattern/1`.

  Provider keys that don't correspond to existing atoms are silently ignored.

  Deny patterns always win over allow patterns.

  ## Returns

  `{%{allow: compiled_patterns, deny: compiled_patterns}, unknown_providers}`

  Where `compiled_patterns` is either `:all` or `%{provider => [%Regex{}]}`,
  and `unknown_providers` is a list of provider keys that were ignored.
  """
  @spec compile_filters(allow :: :all | map(), deny :: map(), known_providers :: [atom()] | nil) ::
          {%{allow: :all | map(), deny: map()}, unknown: [term()]}
  def compile_filters(allow, deny, known_providers \\ nil) do
    {compiled_allow, unknown_allow} = compile_patterns(allow, known_providers)
    {compiled_deny, unknown_deny} = compile_patterns(deny, known_providers)

    unknown = Enum.uniq(unknown_allow ++ unknown_deny)

    {
      %{
        allow: compiled_allow,
        deny: compiled_deny
      },
      [unknown: unknown]
    }
  end

  # Private helpers

  defp compile_patterns(:all, _known_providers), do: {:all, []}

  defp compile_patterns(patterns, known_providers) when is_map(patterns) do
    {compiled, unknown} =
      Enum.reduce(patterns, {%{}, []}, fn {provider, patterns_list},
                                          {acc_compiled, acc_unknown} ->
        case resolve_provider_key(provider, known_providers) do
          {:ok, provider_atom} ->
            # Ensure patterns_list is a list
            list = List.wrap(patterns_list)

            # Compile each pattern (string glob or Regex)
            compiled =
              Enum.map(list, fn
                %Regex{} = r ->
                  r

                s when is_binary(s) ->
                  LLMDB.Merge.compile_pattern(s)

                other ->
                  raise ArgumentError,
                        "llm_db: filter pattern must be string or Regex, got: #{inspect(other)} for provider #{inspect(provider_atom)}"
              end)

            {Map.put(acc_compiled, provider_atom, compiled), acc_unknown}

          {:error, _reason} ->
            # Unknown provider - add to unknown list, don't compile
            {acc_compiled, [provider | acc_unknown]}
        end
      end)

    {compiled, Enum.reverse(unknown)}
  end

  defp compile_patterns(_, _known_providers), do: {%{}, []}

  defp resolve_provider_key(provider, known_providers) when is_atom(provider) do
    # If known_providers specified, validate; otherwise trust the atom
    if known_providers == nil or provider in known_providers do
      {:ok, provider}
    else
      {:error, :unknown}
    end
  end

  defp resolve_provider_key(provider, known_providers) when is_binary(provider) do
    # Try to convert string to existing atom only
    try do
      provider_atom = String.to_existing_atom(provider)

      # If known_providers specified, validate
      if known_providers == nil or provider_atom in known_providers do
        {:ok, provider_atom}
      else
        {:error, :unknown}
      end
    rescue
      ArgumentError ->
        # String doesn't correspond to an existing atom
        {:error, :not_existing_atom}
    end
  end

  defp resolve_provider_key(provider, _known_providers) do
    raise ArgumentError,
          "llm_db: filter provider keys must be atoms or strings, got: #{inspect(provider)}"
  end
end
