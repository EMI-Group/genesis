defmodule LLMDB.DeepMergeShim do
  @moduledoc """
  Shim to call DeepMerge.deep_merge/3 with a 3-arity resolver without Dialyzer false positives.

  DeepMerge's typespec advertises a 2-arity resolver `(any(), any() -> any())` but the actual
  runtime implementation calls the resolver with 3 arguments `(key, left, right)`.

  This shim hides the call from Dialyzer while providing the correct typespec for our usage.
  """

  @type resolver3 :: (any(), any(), any() -> any())

  @spec deep_merge(any(), any(), resolver3) :: any()
  def deep_merge(left, right, resolver3) do
    :erlang.apply(DeepMerge, :deep_merge, [left, right, resolver3])
  end
end
