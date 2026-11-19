defmodule EvoDashWeb.SettingsComponents.ProviderWizard.Helpers do
  @moduledoc """
  Shared value/label/formatting helpers for the ProviderWizard step renderers.

  These functions are used by more than one `ProviderWizard` step, so they live
  here instead of in a single step module: string normalization, the
  atom-or-string key lookup (`value_of/2`), label fallbacks, the total
  reason formatter and the shared provider/auth card class pair.
  """

  use EvoDashWeb, :html

  @doc """
  Looks a value up under the first present key of `keys`.

  Keys are STRINGS; the static table below maps them to atoms so caller input
  never interns an atom.
  """
  def value_of(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, static_key_atom(key))
      end
    end)
  end

  def value_of(_value, _keys), do: nil

  # Static key → atom table: caller input never interns an atom.
  defp static_key_atom("id"), do: :id
  defp static_key_atom("value"), do: :value
  defp static_key_atom("provider"), do: :provider
  defp static_key_atom("label"), do: :label
  defp static_key_atom("name"), do: :name
  defp static_key_atom("note"), do: :note
  defp static_key_atom("description"), do: :description
  defp static_key_atom("subtitle"), do: :subtitle
  defp static_key_atom("display_name"), do: :display_name
  defp static_key_atom("model"), do: :model
  defp static_key_atom("variant"), do: :variant
  defp static_key_atom("variant_label"), do: :variant_label
  defp static_key_atom("variant_id"), do: :variant_id
  defp static_key_atom(_key), do: nil

  @doc "Trims a string-ish value (atom → string), anything else → nil."
  def clean_string(nil), do: nil
  def clean_string(value) when is_binary(value), do: String.trim(value)

  def clean_string(value) when is_atom(value) and value not in [true, false],
    do: Atom.to_string(value)

  def clean_string(_value), do: nil

  @doc "The cleaned `value`, or `id` when it is blank."
  def label_or_id(value, id) do
    case clean_string(value) do
      "" -> id
      label -> label
    end
  end

  @doc "Total display formatter for an error/reason term."
  def format_reason(reason) when is_binary(reason), do: reason

  def format_reason(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def format_reason({tag, reason}) when tag in [:error, :ok], do: format_reason(reason)

  def format_reason(reason), do: inspect(reason)

  @doc "Selectable card class used by the provider and auth steps."
  def card_class(true) do
    "w-full rounded-lg border border-primary bg-primary/5 px-4 py-3 text-left transition hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

  def card_class(_selected?) do
    "w-full rounded-lg border border-base-300 bg-base-100 px-4 py-3 text-left transition hover:border-base-content/30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end
end
