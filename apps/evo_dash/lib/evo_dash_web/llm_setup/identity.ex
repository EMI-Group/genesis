defmodule EvoDashWeb.LLMSetup.Identity do
  @moduledoc """
  Provider-DERIVED account identity for a `[[llm.providers]]` account.

  This is the fix for the "a new profile is named after the model the user
  happened to pick" defect: an account's `id` and `name` come from the
  PROVIDER (`EvoGit.Config.LLMCatalog`), never from a model id.

  A provider account is identified by two fields:
    * `"id"` — the stable TOML key (lowercase slug, e.g. `"zai"`);
    * `"name"` — the display label (the provider's catalog `display_name`,
      e.g. `"Z.ai (Zhipu AI)"`).

  Both must be unique within the config, so `unique_id/2` / `unique_name/2`
  append `-2`, `-3`, … ONLY on collision — the first account of a provider
  keeps the bare provider-derived value.

  ## Totality

  Pure, no I/O, never raises. Existing accounts may arrive as a list of
  string-keyed maps, atom-keyed maps, bare ids (strings or atoms), a map keyed
  by id, or `nil`; anything unrecognized is ignored instead of crashing.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Config.LLMCatalog

  @doc """
  The PROVIDER's display name for an atom, a catalog id atom, or a string.

  - `:deepseek` / `"deepseek"` → `"DeepSeek"`
  - `:zai` / `"zai"` → `"Z.ai (Zhipu AI)"`
  - an unknown non-blank value → its titleized/cleaned spelling
    (`"my_proxy"` → `"My Proxy"`)
  - `nil` / blank → the gettext "Custom endpoint"

  Never derived from a model name.
  """
  @spec provider_display_name(term()) :: String.t()
  def provider_display_name(provider) do
    case catalog_entry(provider) do
      %{display_name: display_name} when is_binary(display_name) and display_name != "" ->
        display_name

      _ ->
        case clean(provider) do
          "" -> gettext("Custom endpoint")
          value -> titleize(value)
        end
    end
  end

  @doc """
  A lowercase ASCII slug of the provider's catalog id (else of its display
  name) — the collision-safe input for a generated account `id`.

  `:zai` → `"zai"`, `:openai_compatible` → `"openai-compatible"`,
  `"My Proxy"` → `"my-proxy"`.

  A `nil` / blank provider (and anything `provider_display_name/1` cannot
  resolve to a non-blank name) slugs to `"custom-endpoint"`, because the slug
  resolves THROUGH `provider_display_name/1`, whose nil/blank answer is the
  gettext "Custom endpoint". That is a meaningful account id, so
  `default_identity(nil, existing)` yields
  `%{"id" => "custom-endpoint", "name" => "Custom endpoint"}` (with `-2`,
  `-3`, … suffixes on collision) — it never falls through to the `profile-N`
  scheme, which only applies when a caller hands a blank BASE straight to
  `unique_id/2`.
  """
  @spec provider_slug(term()) :: String.t()
  def provider_slug(provider) do
    case catalog_entry(provider) do
      %{id: id} -> slugify(Atom.to_string(id))
      _ -> provider |> provider_display_name() |> slugify()
    end
  end

  @doc """
  A free `id` derived from `base`: `base` itself when free, else `base-2`,
  `base-3`, …

  Comparison is case-insensitive (an account `"ZAI"` blocks `"zai"`). A blank
  base or blank/invalid `existing` input falls back to the `profile-N` scheme
  (`profile-1`, `profile-2`, …). Deterministic and pure.
  """
  @spec unique_id(term(), term()) :: String.t()
  def unique_id(base, existing_ids) do
    base = clean(base)
    taken = taken_set(existing_ids, &id_of/1)

    if base == "" do
      numbered("profile", taken, 1)
    else
      suffixed(base, taken, 1)
    end
  end

  @doc """
  A free display `name` derived from `base`: `base`, else `base-2`, `base-3`,
  … — the same rules (and case-insensitive comparison) as `unique_id/2`.

  A blank base falls back to the gettext "Account".
  """
  @spec unique_name(term(), term()) :: String.t()
  def unique_name(base, existing_names) do
    base =
      case clean(base) do
        "" -> gettext("Account")
        value -> value
      end

    suffixed(base, taken_set(existing_names, &name_of/1), 1)
  end

  @doc """
  The default `%{"id" => …, "name" => …}` identity for a new account of
  `provider`, uniquified against the already-configured accounts.

  The caller keeps the last word: an explicitly typed name/id simply replaces
  the corresponding value, and nothing here re-derives it.
  """
  @spec default_identity(term(), term()) :: %{String.t() => String.t()}
  def default_identity(provider, existing_accounts) do
    %{
      "id" => unique_id(provider_slug(provider), account_ids(existing_accounts)),
      "name" => unique_name(provider_display_name(provider), account_names(existing_accounts))
    }
  end

  @doc """
  Every `id` reachable in `accounts`, as strings (deduped, blanks dropped).

  Understands a list of account maps (string- or atom-keyed), bare ids as
  strings/atoms, a map keyed by id, or `nil`.
  """
  @spec account_ids(term()) :: [String.t()]
  def account_ids(accounts) do
    accounts |> collect(&id_of/1)
  end

  @doc """
  Every display `name` reachable in `accounts` (falling back to the id), as
  strings — the same input tolerance as `account_ids/1`.
  """
  @spec account_names(term()) :: [String.t()]
  def account_names(accounts) do
    accounts |> collect(&name_of/1)
  end

  # ── catalog resolution ─────────────────────────────────────────────────────

  defp catalog_entry(nil), do: nil

  defp catalog_entry(provider) when is_atom(provider) do
    Enum.find(LLMCatalog.providers(), fn entry ->
      entry.id == provider or provider in provider_atoms(entry)
    end)
  end

  defp catalog_entry(provider) when is_binary(provider) do
    wanted = provider |> String.trim() |> String.downcase()

    if wanted == "" do
      nil
    else
      Enum.find(LLMCatalog.providers(), &matches_binary?(&1, wanted))
    end
  end

  defp catalog_entry(_provider), do: nil

  defp matches_binary?(entry, wanted) do
    String.downcase(Atom.to_string(entry.id)) == wanted or
      String.downcase(to_string_value(entry.display_name)) == wanted or
      Enum.any?(provider_atoms(entry), &(Atom.to_string(&1) == wanted))
  end

  defp provider_atoms(entry), do: List.wrap(Map.get(entry, :provider_atoms))

  # ── uniqueness ─────────────────────────────────────────────────────────────

  defp taken_set(accounts, extractor) do
    accounts
    |> collect(extractor)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp collect(accounts, extractor) do
    accounts
    |> entries()
    |> Enum.map(extractor)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp entries(nil), do: []
  defp entries(accounts) when is_list(accounts), do: accounts

  defp entries(accounts) when is_map(accounts) do
    if account_map?(accounts) do
      [accounts]
    else
      accounts |> Map.values() |> Enum.reject(&is_nil/1)
    end
  end

  defp entries(other), do: [other]

  defp account_map?(map) do
    has_key?(map, "id") or has_key?(map, "name") or has_key?(map, "display_name")
  end

  defp has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, existing_atom(key))
  end

  # A static key → atom table: user input never interns a new atom.
  defp existing_atom("id"), do: :id
  defp existing_atom("name"), do: :name
  defp existing_atom("display_name"), do: :display_name

  defp id_of(account) when is_map(account) do
    first_clean([get_value(account, "id"), get_value(account, "name")])
  end

  defp id_of(account), do: scalar_string(account)

  defp name_of(account) when is_map(account) do
    first_clean([
      get_value(account, "name"),
      get_value(account, "display_name"),
      get_value(account, "id")
    ])
  end

  defp name_of(account), do: scalar_string(account)

  defp get_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, existing_atom(key))
    end
  end

  defp first_clean(values) do
    cleaned = Enum.map(values, &clean/1)

    case Enum.find(cleaned, &(&1 != "")) do
      nil -> nil
      value -> value
    end
  end

  defp scalar_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp scalar_string(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp scalar_string(_value), do: nil

  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value) when is_atom(value), do: scalar_string(value) || ""
  defp clean(_value), do: ""

  defp numbered(prefix, taken, n) do
    candidate = prefix <> "-" <> Integer.to_string(n)

    if MapSet.member?(taken, String.downcase(candidate)) do
      numbered(prefix, taken, n + 1)
    else
      candidate
    end
  end

  defp suffixed(base, taken, n) do
    candidate = if n <= 1, do: base, else: base <> "-" <> Integer.to_string(n)

    if MapSet.member?(taken, String.downcase(candidate)) do
      suffixed(base, taken, n + 1)
    else
      candidate
    end
  end

  # ── text helpers ───────────────────────────────────────────────────────────

  defp slugify(value) do
    value
    |> to_string_value()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp titleize(value) do
    value
    |> to_string_value()
    |> String.split(~r/[_\-.\s]+/u, trim: true)
    |> Enum.map_join(" ", &titleize_part/1)
  end

  defp titleize_part(part) do
    if part == String.upcase(part) and String.length(part) > 1 do
      part
    else
      String.capitalize(part)
    end
  end

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(_value), do: ""
end
