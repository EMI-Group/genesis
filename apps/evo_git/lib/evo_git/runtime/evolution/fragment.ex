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
          source: :seed | :generated | :crossover | :mutation | :concept_expanded,
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

  @func_re ~r/\b(def|defp|function|fn|func|void|class|method|sub|defn)\s+\w/
  @ctrl_re ~r/\b(if|else|elif|for|while|switch|case|cond|match|try|catch|unless|foreach)\b/
  @import_re ~r/\b(use|import|require|include|from\s+\w+\s+import|#include|#import)\b/
  @string_literal_re ~r/"[^"]*"|'[^']*'/
  @numeric_literal_re ~r/\b\d+\.?\d*\b/
  @indent_re ~r/^(\s+)/

  @doc """
  Creates a new fragment with an auto-generated ID.

  ## Options

    * `:language` — the programming language (default: `"elixir"`)
    * `:domain` — the domain label (required)
    * `:source` — `:seed`, `:generated`, `:crossover`, `:mutation`, or `:concept_expanded` (default: `:seed`)
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
  Extracts structural features from the fragment's content via text/regex analysis.
  Works for any programming language.

  Returns a map with 10 structural dimensions:
    * `:nesting_depth` — maximum indentation nesting depth
    * `:function_count` — number of function/method definitions
    * `:control_flow_count` — number of control flow constructs (if, for, while, etc.)
    * `:comment_density` — percentage of lines that are comments (0.0–100.0)
    * `:import_count` — number of import/use/require/include directives
    * `:avg_line_length` — average length of non-empty lines
    * `:string_literal_count` — number of string literals
    * `:numeric_literal_count` — number of numeric literals
    * `:line_count` — number of lines
    * `:char_count` — string length
  """
  @spec extract_structural_features(t() | String.t()) :: map()
  def extract_structural_features(%__MODULE__{content: content}) do
    lines = String.split(content, "\n", trim: true)
    line_count = length(lines)
    char_count = String.length(content)

    %{
      nesting_depth: compute_nesting_depth(lines),
      function_count: count_matches(content, @func_re),
      control_flow_count: count_matches(content, @ctrl_re),
      comment_density: compute_comment_density(lines),
      import_count: count_matches(content, @import_re),
      avg_line_length: compute_avg_line_length(lines),
      string_literal_count: count_matches(content, @string_literal_re),
      numeric_literal_count: count_matches(content, @numeric_literal_re),
      line_count: line_count,
      char_count: char_count
    }
  end

  def extract_structural_features(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: true)
    line_count = length(lines)
    char_count = String.length(content)

    %{
      nesting_depth: compute_nesting_depth(lines),
      function_count: count_matches(content, @func_re),
      control_flow_count: count_matches(content, @ctrl_re),
      comment_density: compute_comment_density(lines),
      import_count: count_matches(content, @import_re),
      avg_line_length: compute_avg_line_length(lines),
      string_literal_count: count_matches(content, @string_literal_re),
      numeric_literal_count: count_matches(content, @numeric_literal_re),
      line_count: line_count,
      char_count: char_count
    }
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
      if sf == %{} do
        []
      else
        [
          normalize(sf[:nesting_depth], 20),
          normalize(sf[:function_count], 10),
          normalize(sf[:control_flow_count], 20),
          normalize(sf[:comment_density], 100),
          normalize(sf[:import_count], 10),
          normalize(sf[:avg_line_length], 120),
          normalize(sf[:string_literal_count], 20),
          normalize(sf[:numeric_literal_count], 20),
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

  # Language-agnostic feature extraction helpers

  defp compute_nesting_depth(lines) do
    lines
    |> Enum.map(fn line ->
      case Regex.run(@indent_re, line) do
        [_, spaces] ->
          # Count indentation level: tabs count as 4, spaces count as-is
          spaces
          |> String.replace("\t", "    ")
          |> String.length()
          |> Kernel./(2)
          |> round()

        _ ->
          0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp count_matches(content, regex) do
    Regex.scan(regex, content) |> length()
  end

  defp compute_comment_density(lines) do
    if lines == [] do
      0.0
    else
      comment_count =
        Enum.count(lines, fn line ->
          trimmed = String.trim(line)

          String.starts_with?(trimmed, "#") or
            String.starts_with?(trimmed, "//") or
            String.starts_with?(trimmed, "/*") or
            String.starts_with?(trimmed, "--") or
            String.starts_with?(trimmed, ";") or
            String.starts_with?(trimmed, "%")
        end)

      comment_count / length(lines) * 100
    end
  end

  defp compute_avg_line_length([]), do: 0.0

  defp compute_avg_line_length(lines) do
    total = Enum.reduce(lines, 0, fn line, acc -> acc + String.length(line) end)
    total / length(lines)
  end
end
