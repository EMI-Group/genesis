defmodule ReqLLM.Pricing do
  @moduledoc false

  alias ReqLLM.MapAccess

  @spec components(LLMDB.Model.t() | map() | nil) :: list()
  def components(nil), do: []

  def components(%LLMDB.Model{} = model) do
    components(MapAccess.get(model, :pricing))
  end

  def components(pricing) when is_map(pricing) do
    case MapAccess.get(pricing, :components) do
      components when is_list(components) -> components
      _ -> []
    end
  end

  def components(_), do: []

  @spec tool_component(LLMDB.Model.t() | map() | nil, atom() | String.t()) :: map() | nil
  def tool_component(pricing_or_model, tool) when is_atom(tool) or is_binary(tool) do
    pricing_or_model
    |> components()
    |> Enum.find(fn component ->
      kind = MapAccess.get(component, :kind)
      tool_value = MapAccess.get(component, :tool)
      tool_match?(tool_value, tool) and kind in [:tool, "tool"]
    end)
  end

  def tool_component(_, _), do: nil

  @spec tool_unit(LLMDB.Model.t() | map() | nil, atom() | String.t()) :: any()
  def tool_unit(pricing_or_model, tool) do
    case tool_component(pricing_or_model, tool) do
      nil -> nil
      component -> MapAccess.get(component, :unit)
    end
  end

  defp tool_match?(value, tool) do
    normalized_value = normalize_tool_value(value)
    normalized_tool = normalize_tool_value(tool)

    normalized_value != nil and normalized_tool != nil and normalized_value == normalized_tool
  end

  defp normalize_tool_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_tool_value(value) when is_binary(value), do: value
  defp normalize_tool_value(_), do: nil
end
