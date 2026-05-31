defmodule EvoGit.Runtime.Evolution.NoveltyMetric do
  @moduledoc """
  Novelty search scoring — behavioral and structural uniqueness metrics.

  Implements novelty search via k-nearest-neighbor distance in feature space.
  Fragments are scored based on how structurally and behaviorally distinct
  they are from the rest of the population, NOT on how close they are to
  a target objective.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  @default_k 5

  @doc """
  Compute novelty as the average Euclidean distance to the k-nearest neighbors
  in feature space.

  ## Options

    * `:k` — number of nearest neighbors to consider (default: #{@default_k})

  Returns `1.0` (maximally novel) if the reference set is empty.
  If the reference set has fewer than `k` elements, all of them are used.
  """
  @spec novelty_score(Fragment.t(), [Fragment.t()], keyword()) :: float()
  def novelty_score(fragment, reference_set, opts \\ [])

  def novelty_score(_fragment, [], _opts), do: 1.0

  def novelty_score(fragment, reference_set, opts) do
    k = Keyword.get(opts, :k, @default_k)
    actual_k = min(k, length(reference_set))

    reference_set
    |> Enum.map(&distance(fragment, &1))
    |> Enum.sort()
    |> Enum.take(actual_k)
    |> Enum.sum()
    |> Kernel./(actual_k)
  end

  @doc """
  Compute Euclidean distance between two fragments' feature vectors.

  Handles mismatched vector lengths by padding the shorter vector with zeros.
  Returns `1.0` if either vector is empty.
  """
  @spec distance(Fragment.t(), Fragment.t()) :: float()
  def distance(fragment_a, fragment_b) do
    vec_a = Fragment.to_feature_vector(fragment_a)
    vec_b = Fragment.to_feature_vector(fragment_b)

    cond do
      vec_a == [] or vec_b == [] ->
        1.0

      true ->
        {padded_a, padded_b} = pad_vectors(vec_a, vec_b)
        euclidean_distance(padded_a, padded_b)
    end
  end

  @doc """
  Compute novelty for all fragments against the reference set.

  Returns a list of `{fragment, score}` tuples sorted by score descending
  (most novel first).
  """
  @spec batch_novelty_scores([Fragment.t()], [Fragment.t()], keyword()) ::
          [{Fragment.t(), float()}]
  def batch_novelty_scores(fragments, reference_set, opts) do
    fragments
    |> Enum.map(fn fragment ->
      score = novelty_score(fragment, reference_set, opts)
      {fragment, score}
    end)
    |> Enum.sort_by(fn {_fragment, score} -> score end, :desc)
  end

  @doc """
  Language-agnostic structural feature extraction of a code string.

  Delegates to `Fragment.extract_structural_features/1` to avoid code duplication.
  Works for any programming language.
  """
  @spec structural_features(String.t()) :: map()
  def structural_features(content) when is_binary(content) do
    fragment = Fragment.new(content, domain: "temp")
    Fragment.extract_structural_features(fragment)
  end

  @doc """
  Use LLM to classify code behavior.

  Takes an LLM model string and constructs a prompt asking the model to
  respond with a JSON object describing the code's behavioral profile:
  complexity, paradigm, domain, and abstraction level.

  Returns a map with atom keys. On any error, returns a default profile.
  """
  @spec behavioral_profile(String.t(), String.t()) :: map()
  def behavioral_profile(content, model) when is_binary(content) and is_binary(model) do
    prompt = """
    Analyze the following code and respond with ONLY a JSON object (no markdown, no explanation).
    The JSON object must have exactly these fields:
    {"complexity": <float 0.0-1.0>, "paradigm": "<functional|mixed|declarative|imperative>", "domain": "<string>", "abstraction": <float 0.0-1.0>}

    Code:
    ```
    #{content}
    ```
    """

    try do
      context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

      with {:ok, stream_response} <- ReqLLM.stream_text(model, context),
           {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
           {:ok, text} <- get_response_text(response),
           {:ok, decoded} <- JSON.decode(text) do
        %{
          complexity: parse_float(decoded["complexity"], 0.5),
          paradigm: parse_paradigm(decoded["paradigm"]),
          domain: decoded["domain"] || "unknown",
          abstraction: parse_float(decoded["abstraction"], 0.5)
        }
      else
        _ -> default_behavioral_profile()
      end
    rescue
      _ -> default_behavioral_profile()
    end
  end

  @doc """
  Return the fragment with the LOWEST novelty score (most redundant).

  Returns `nil` if the list is empty. Each fragment's novelty is computed
  against all other fragments in the list.
  """
  @spec most_redundant([Fragment.t()]) :: Fragment.t() | nil
  def most_redundant([]), do: nil

  def most_redundant(fragments) do
    fragments
    |> Enum.map(fn fragment ->
      others = List.delete(fragments, fragment)
      score = novelty_score(fragment, others)
      {fragment, score}
    end)
    |> Enum.min_by(fn {_fragment, score} -> score end)
    |> elem(0)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp default_behavioral_profile do
    %{complexity: 0.5, paradigm: :mixed, domain: "unknown", abstraction: 0.5}
  end

  defp get_response_text(response) do
    text = ReqLLM.Response.text(response)
    if is_binary(text) and text != "", do: {:ok, text}, else: {:error, :empty_response}
  end

  defp parse_float(value, _default) when is_number(value), do: value / 1.0
  defp parse_float(_value, default), do: default

  defp parse_paradigm("functional"), do: :functional
  defp parse_paradigm("declarative"), do: :declarative
  defp parse_paradigm("imperative"), do: :imperative
  defp parse_paradigm(_), do: :mixed

  defp pad_vectors(vec_a, vec_b) do
    len_a = length(vec_a)
    len_b = length(vec_b)

    case len_a - len_b do
      0 ->
        {vec_a, vec_b}

      diff when diff > 0 ->
        {vec_a, vec_b ++ List.duplicate(0.0, diff)}

      diff ->
        {vec_a ++ List.duplicate(0.0, -diff), vec_b}
    end
  end

  defp euclidean_distance(vec_a, vec_b) do
    sum_of_squares =
      Enum.zip(vec_a, vec_b)
      |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - b) * (a - b) end)

    :math.sqrt(sum_of_squares)
  end

end
