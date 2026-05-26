defmodule ReqLLM.ModelId do
  @moduledoc false

  @spec normalize(LLMDB.Model.t() | String.t() | nil, String.t()) :: String.t()
  def normalize(%LLMDB.Model{id: id}, _fallback) when is_binary(id), do: id
  def normalize(id, _fallback) when is_binary(id), do: id
  def normalize(_, fallback), do: fallback
end
