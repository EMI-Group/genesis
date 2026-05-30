defmodule EvoGit.Runtime.Evolution.Fragment do
  @moduledoc """
  A code fragment in the entropy pool — the genetic material for open-ended evolution.

  Each fragment represents a piece of executable code from any domain,
  along with metadata about its structural features, behavioral profile,
  and novelty score within the population.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          language: String.t(),
          domain: String.t(),
          source: :seed | :generated | :crossover | :mutation,
          generation: non_neg_integer(),
          behavioral_profile: map(),
          structural_features: map(),
          novelty_score: float(),
          parents: [String.t()],
          inserted_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :content, :language, :domain]
  defstruct [
    :id,
    :content,
    :language,
    :domain,
    source: :seed,
    generation: 0,
    behavioral_profile: %{},
    structural_features: %{},
    novelty_score: 0.0,
    parents: [],
    inserted_at: nil
  ]

  @doc """
  Creates a new fragment with an auto-generated ID.

  ## Options

    * `:language` — the programming language (default: `"elixir"`)
    * `:domain` — the domain label (required)
    * `:source` — `:seed`, `:generated`, `:crossover`, or `:mutation` (default: `:seed`)
    * `:generation` — evolution generation (default: `0`)
    * `:parents` — list of parent fragment IDs (default: `[]`)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      content: content,
      language: Keyword.get(opts, :language, "elixir"),
      domain: Keyword.fetch!(opts, :domain),
      source: Keyword.get(opts, :source, :seed),
      generation: Keyword.get(opts, :generation, 0),
      parents: Keyword.get(opts, :parents, []),
      inserted_at: DateTime.utc_now()
    }
  end

  @doc """
  Extracts structural features from the fragment's content via AST analysis.

  Returns a map with:
    * `:ast_depth` — maximum nesting depth of the AST
    * `:function_count` — number of function definitions (def, defp, defmacro, defmacrop)
    * `:pattern_match_count` — number of match operators (=)
    * `:macro_count` — number of use/import/require directives
    * `:module_count` — number of defmodule
    * `:guard_count` — number of when clauses
    * `:pipeline_count` — number of |> operators
    * `:struct_count` — number of struct/map creations
    * `:line_count` — number of lines
    * `:char_count` — string length

  Returns `%{parse_error: true, line_count: ..., char_count: ...}` if parsing fails.
  """
  @spec extract_structural_features(t()) :: map()
  def extract_structural_features(%__MODULE__{content: content}) do
    lines = String.split(content, "\n", trim: true)
    line_count = length(lines)
    char_count = String.length(content)

    case Code.string_to_quoted(content, literal_encoder: &{:ok, {:__block__, &1, [&2]}}) do
      {:ok, ast} ->
        %{
          ast_depth: compute_ast_depth(ast),
          function_count: count_nodes(ast, &function_def?/1),
          pattern_match_count: count_nodes(ast, &match_op?/1),
          macro_count: count_nodes(ast, &macro_directive?/1),
          module_count: count_nodes(ast, &module_def?/1),
          guard_count: count_nodes(ast, &guard_clause?/1),
          pipeline_count: count_nodes(ast, &pipeline_op?/1),
          struct_count: count_nodes(ast, &struct_creation?/1),
          line_count: line_count,
          char_count: char_count
        }

      {:error, _} ->
        %{parse_error: true, line_count: line_count, char_count: char_count}
    end
  end

  @doc """
  Converts the fragment's features into a normalized numeric vector for distance calculations.

  Combines structural features (normalized by expected maxima) with behavioral profile
  features (complexity, abstraction, paradigm one-hot encoding).

  Returns an empty list if features are missing.
  """
  @spec to_feature_vector(t()) :: [float()]
  def to_feature_vector(%__MODULE__{
        structural_features: sf,
        behavioral_profile: bp
      }) do
    struct_vec =
      if sf == %{} or Map.get(sf, :parse_error) do
        []
      else
        [
          normalize(sf[:ast_depth], 20),
          normalize(sf[:function_count], 10),
          normalize(sf[:pattern_match_count], 10),
          normalize(sf[:macro_count], 5),
          normalize(sf[:module_count], 5),
          normalize(sf[:guard_count], 5),
          normalize(sf[:pipeline_count], 10),
          normalize(sf[:struct_count], 10),
          normalize(sf[:line_count], 100),
          normalize(sf[:char_count], 10_000)
        ]
      end

    behavior_vec =
      if bp == %{} do
        []
      else
        paradigm_onehot =
          case bp[:paradigm] do
            :functional -> [1.0, 0.0, 0.0, 0.0]
            :mixed -> [0.0, 1.0, 0.0, 0.0]
            :declarative -> [0.0, 0.0, 1.0, 0.0]
            :imperative -> [0.0, 0.0, 0.0, 1.0]
            _ -> [0.0, 0.0, 0.0, 0.0]
          end

        [
          Map.get(bp, :complexity, 0.5),
          Map.get(bp, :abstraction, 0.5)
          | paradigm_onehot
        ]
      end

    if struct_vec == [] and behavior_vec == [], do: [], else: struct_vec ++ behavior_vec
  end

  @doc """
  Returns a brief description suitable for LLM synthesis prompts.
  """
  @spec summarize(t()) :: String.t()
  def summarize(%__MODULE__{} = fragment) do
    preview =
      if String.length(fragment.content) > 200 do
        String.slice(fragment.content, 0, 200) <> "..."
      else
        fragment.content
      end

    "[#{fragment.domain}] (#{fragment.language}, gen #{fragment.generation}, novelty: #{Float.round(fragment.novelty_score, 3)})\n#{preview}"
  end

  # --- Private Helpers ---

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp normalize(nil, _max), do: 0.0
  defp normalize(value, max) when max > 0, do: min(value / max, 1.0)
  defp normalize(_, _max), do: 0.0

  # AST depth computation
  defp compute_ast_depth(ast) when is_tuple(ast) do
    [_head | args] = Tuple.to_list(ast)

    child_depths =
      Enum.map(args, fn
        list when is_list(list) ->
          list
          |> Enum.map(&compute_ast_depth/1)
          |> Enum.max(fn -> 0 end)

        node ->
          compute_ast_depth(node)
      end)

    max_child = Enum.max(child_depths, fn -> 0 end)
    1 + max_child
  end

  defp compute_ast_depth(list) when is_list(list) do
    list
    |> Enum.map(&compute_ast_depth/1)
    |> Enum.max(fn -> 0 end)
  end

  defp compute_ast_depth(_), do: 0

  # Node counting via AST traversal
  defp count_nodes(ast, predicate) do
    {_, count} = walk_and_count(ast, predicate)
    count
  end

  defp walk_and_count(ast, predicate) when is_tuple(ast) do
    count = if predicate.(ast), do: 1, else: 0

    [_head | args] = Tuple.to_list(ast)

    child_counts =
      Enum.map(args, fn
        list when is_list(list) ->
          list
          |> Enum.map(&walk_and_count(&1, predicate))
          |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)

        node ->
          {_, c} = walk_and_count(node, predicate)
          c
      end)

    {:ok, count + Enum.sum(child_counts)}
  end

  defp walk_and_count(list, predicate) when is_list(list) do
    count =
      list
      |> Enum.map(&walk_and_count(&1, predicate))
      |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)

    {:ok, count}
  end

  defp walk_and_count(_, _), do: {:ok, 0}

  # AST predicate helpers
  defp function_def?({name, _, _})
       when name in [:def, :defp, :defmacro, :defmacrop],
       do: true

  defp function_def?(_), do: false

  defp match_op?({:=, _, _}), do: true
  defp match_op?(_), do: false

  defp macro_directive?({name, _, _})
       when name in [:use, :import, :require],
       do: true

  defp macro_directive?(_), do: false

  defp module_def?({:defmodule, _, _}), do: true
  defp module_def?(_), do: false

  defp guard_clause?({:when, _, _}), do: true
  defp guard_clause?(_), do: false

  defp pipeline_op?({:|>, _, _}), do: true
  defp pipeline_op?(_), do: false

  defp struct_creation?({:%{}, _, _}), do: true
  defp struct_creation?({:%, _, _}), do: true
  defp struct_creation?(_), do: false
end
