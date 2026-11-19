defmodule EvoDashWeb.SettingsLive.Navigation do
  @moduledoc """
  Pure category-NAVIGATION contracts for the Settings page (`/settings`).

  Extracted from `EvoDashWeb.SettingsLive` so the two things that must never
  disagree — the sidebar's category list and the active category — are decided
  by one total, I/O-free module:

    * `category_from_param/2` whitelists a client/URL category string against
      the categories actually DISPLAYABLE for the viewed node (the platform +
      nix filtered schemas map), with the two dashboard-only pseudo-categories
      (`:remote_connections`, `:agents`) as ordinary map keys.
    * `resolve/3` turns a requested category into an atom GUARANTEED to be a
      key of that map (never `nil`, never a hidden category).
    * `seed/3` decides what the SHELL render shows before the async node-data
      result lands, using the LAST-KNOWN filtered map so the seeded nav is
      exactly the nav the settled page renders.
    * `path/2` builds the `push_patch` target (`?category=` + the preserved
      `?node=`), building the query by hand because the shared
      `EvoDashWeb.Helpers.with_node_param/2` appends with `?` and would corrupt
      an existing query string.

  Every function is TOTAL on nil/garbage input: unknown shapes degrade to
  `:llm` (when that category exists) or to the first available category, and a
  non-map schemas argument yields `nil`/`:llm` rather than raising. There is no
  I/O and deliberately no `try/rescue` (the settings page's contract: a crash
  must be visible, not masked by a fabricated default).
  """

  alias EvoDashWeb.SettingsLive.ConfigIO

  @default_category :llm
  @settings_path "/settings"

  @doc """
  Whitelists `param` against the categories present in `schemas_by_category`.

  Accepts a string (the HTML/URL form, as delivered by `phx-value-category` and
  `?category=`) or an atom. Returns the matching category atom, or `nil` when
  the value is absent, unknown, or filtered out for the viewed node — so a
  gated category can never be selected through either entry point.
  """
  def category_from_param(param, schemas_by_category) when is_binary(param) do
    Map.get(whitelist(schemas_by_category), param)
  end

  def category_from_param(param, schemas_by_category) when is_atom(param) and not is_nil(param) do
    if visible?(param, schemas_by_category), do: param
  end

  def category_from_param(_param, _schemas_by_category), do: nil

  @doc """
  Resolves a requested category against `schemas_by_category`, guaranteeing a
  key of that map.

  Order: the requested category when it is displayable → `fallback` when IT is
  displayable → `:llm` → the first available category. `:llm` is never returned
  when it is absent from the map, and the result is never `nil` for a map with
  at least one key (an empty map — never produced in practice — degrades to
  `:llm`).
  """
  def resolve(category_param, fallback, schemas_by_category) do
    cond do
      category = category_from_param(category_param, schemas_by_category) ->
        category

      visible?(fallback, schemas_by_category) ->
        fallback

      true ->
        default_category(schemas_by_category)
    end
  end

  @doc """
  The SHELL-render category: `params["category"]` resolved against the
  LAST-KNOWN platform-filtered map, falling back to `current` while that is
  still displayable, else the default.

  Never returns a category absent from `last_filtered`, so the seeded render
  can neither advertise nor activate a platform-gated category, and it can
  never un-select a category that is still visible (a later `handle_params`
  with the same params therefore leaves the selection alone).
  """
  def seed(params, current, last_filtered) do
    resolve(category_param(params), current, last_filtered)
  end

  @doc """
  The default category: `:llm` when the map has it, else the first available
  category in stable (alphabetical) order, else `:llm`.
  """
  def default_category(schemas_by_category) do
    cond do
      visible?(@default_category, schemas_by_category) -> @default_category
      true -> schemas_by_category |> available_categories() |> List.first() || @default_category
    end
  end

  @doc "True when `category` is an atom key of `schemas_by_category`."
  def visible?(category, schemas_by_category) when is_atom(category) and not is_nil(category) do
    is_map(schemas_by_category) and Map.has_key?(schemas_by_category, category)
  end

  def visible?(_category, _schemas_by_category), do: false

  @doc "Every displayable category, in stable alphabetical order."
  def available_categories(schemas_by_category) when is_map(schemas_by_category) do
    schemas_by_category
    |> Map.keys()
    |> Enum.filter(&is_atom/1)
    |> Enum.sort_by(&Atom.to_string/1)
  end

  def available_categories(_schemas_by_category), do: []

  @doc """
  The `push_patch` target for a category: `"/settings?category=<cat>"`, with
  `?node=` preserved (URL-encoded) when the current navigation carries it.

  Returns `"/settings"` for a nil category. `params` is the map delivered to
  `handle_params/3` (string or atom `:node` keys both work).
  """
  def path(category, params) when is_atom(category) and not is_nil(category) do
    query = "category=" <> URI.encode_www_form(Atom.to_string(category))

    case node_param(params) do
      nil -> @settings_path <> "?" <> query
      node -> @settings_path <> "?" <> query <> "&node=" <> URI.encode_www_form(node)
    end
  end

  def path(_category, _params), do: @settings_path

  # ───────────────────────────────────────────────────────────────────────────
  # Internals
  # ───────────────────────────────────────────────────────────────────────────

  # The ONE whitelist: `ConfigIO.category_str_to_atom/1` over atom-keyed
  # schemas. Non-map input (or a non-atom key) degrades to an empty whitelist
  # instead of raising inside `Atom.to_string/1`.
  defp whitelist(schemas_by_category) when is_map(schemas_by_category) do
    atom_keyed =
      schemas_by_category
      |> Enum.filter(fn {category, _schemas} -> is_atom(category) end)
      |> Map.new()

    ConfigIO.category_str_to_atom(atom_keyed)
  end

  defp whitelist(_schemas_by_category), do: %{}

  defp category_param(%{"category" => category}), do: category
  defp category_param(%{category: category}), do: category
  defp category_param(_params), do: nil

  defp node_param(params) when is_map(params) do
    case Map.get(params, "node") || Map.get(params, :node) do
      node when is_binary(node) and node != "" -> node
      _ -> nil
    end
  end

  defp node_param(params) when is_list(params) do
    case Keyword.get(params, :node) do
      node when is_binary(node) and node != "" -> node
      _ -> nil
    end
  end

  defp node_param(_params), do: nil
end
