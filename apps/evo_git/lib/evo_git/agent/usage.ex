defmodule EvoGit.Agent.Usage do
  @moduledoc """
  Cumulative token and cost usage tracking for agents.
  """

  defstruct input_tokens: 0, output_tokens: 0, total_tokens: 0,
            input_cost: 0.0, output_cost: 0.0, total_cost: 0.0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_cost: float(),
          output_cost: float(),
          total_cost: float()
        }

  @doc "Creates a zero-usage struct."
  def zero, do: %__MODULE__{}

  @doc "Creates a Usage from ReqLLM.Response.usage/1 map. Returns zero struct for nil."
  def from_response_usage(nil), do: zero()

  def from_response_usage(%{} = usage) do
    %__MODULE__{
      input_tokens: Map.get(usage, :input_tokens, 0) || 0,
      output_tokens: Map.get(usage, :output_tokens, 0) || 0,
      total_tokens: Map.get(usage, :total_tokens, 0) || 0,
      input_cost: Map.get(usage, :input_cost, 0.0) || 0.0,
      output_cost: Map.get(usage, :output_cost, 0.0) || 0.0,
      total_cost: Map.get(usage, :total_cost, 0.0) || 0.0
    }
  end

  @doc "Adds two Usage structs together (accumulates tokens and costs)."
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      total_tokens: a.total_tokens + b.total_tokens,
      input_cost: a.input_cost + b.input_cost,
      output_cost: a.output_cost + b.output_cost,
      total_cost: a.total_cost + b.total_cost
    }
  end
end
