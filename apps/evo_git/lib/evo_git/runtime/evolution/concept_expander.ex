defmodule EvoGit.Runtime.Evolution.ConceptExpander do
  @moduledoc """
  Expands rough concept prompts into diverse code fragments through multi-stage LLM expansion.

  Pipeline: concept → sub-topics → implementations → code fragments
  """

  require Logger

  alias EvoGit.Runtime.Evolution.Fragment

  @default_concept_breadth 10
  @default_implementation_depth 5

  @doc """
  Expands a concept into a list of code fragments.

  Options:
    - :model - LLM model to use (required)
    - :concept_breadth - number of sub-topics per concept (default: 10)
    - :implementation_depth - number of implementations per sub-topic (default: 5)
    - :llm_caller - function to use for LLM calls (for test injection)
  """
  @spec expand(String.t(), keyword()) :: [Fragment.t()]
  def expand(concept, opts \\ []) do
    Logger.info("ConceptExpander: Expanding concept '#{concept}' into sub-topics...")

    case expand_to_subtopics(concept, opts) do
      [] ->
        Logger.warning("ConceptExpander: Failed to generate sub-topics for concept '#{concept}'")
        []

      subtopics ->
        Logger.info(
          "ConceptExpander: Generated #{length(subtopics)} sub-topics from concept '#{concept}'"
        )

        fragments =
          subtopics
          |> Enum.flat_map(&expand_subtopic(&1, opts))

        total = length(fragments)
        subtopic_count = length(subtopics)
        impl_count = if subtopic_count > 0, do: div(total, subtopic_count), else: 0

        Logger.info(
          "ConceptExpander: Generated #{total} fragments from concept '#{concept}' " <>
            "(#{subtopic_count} sub-topics × ~#{impl_count} implementations)"
        )

        fragments
    end
  end

  # Stage 1: concept → sub-topics

  @doc """
  Stage 1: Expands a concept into a list of sub-topics using LLM.

  Returns a list of sub-topic strings, or `[]` on failure.
  """
  @spec expand_to_subtopics(String.t(), keyword()) :: [String.t()]
  def expand_to_subtopics(concept, opts) do
    breadth = Keyword.get(opts, :concept_breadth, @default_concept_breadth)
    model = Keyword.fetch!(opts, :model)
    prompt = build_subtopics_prompt(concept, breadth)

    try do
      case call_llm(prompt, model, opts) do
        {:ok, text} ->
          parse_subtopics(text)

        {:error, reason} ->
          Logger.warning("ConceptExpander: Sub-topic expansion failed: #{inspect(reason)}")
          []
      end
    rescue
      e ->
        Logger.warning(
          "ConceptExpander: Sub-topic expansion raised: #{Exception.message(e)}"
        )

        []
    end
  end

  # Stage 2: sub-topic → implementations

  @doc """
  Stage 2: Expands a sub-topic into concrete implementation descriptions using LLM.

  Returns a list of implementation description strings, or `[]` on failure.
  """
  @spec expand_to_implementations(String.t(), keyword()) :: [String.t()]
  def expand_to_implementations(subtopic, opts) do
    depth = Keyword.get(opts, :implementation_depth, @default_implementation_depth)
    model = Keyword.fetch!(opts, :model)
    prompt = build_implementations_prompt(subtopic, depth)

    try do
      case call_llm(prompt, model, opts) do
        {:ok, text} ->
          parse_implementations(text)

        {:error, reason} ->
          Logger.warning(
            "ConceptExpander: Implementation expansion failed: #{inspect(reason)}"
          )

          []
      end
    rescue
      e ->
        Logger.warning(
          "ConceptExpander: Implementation expansion raised: #{Exception.message(e)}"
        )

        []
    end
  end

  # Stage 3: implementation → code fragment

  @doc """
  Stage 3: Generates a code fragment from an implementation description using LLM.

  Returns `{:ok, Fragment.t()}` on success or `{:error, reason}` on failure.
  """
  @spec generate_fragment(String.t(), String.t(), keyword()) ::
          {:ok, Fragment.t()} | {:error, term()}
  def generate_fragment(implementation, domain, opts) do
    model = Keyword.fetch!(opts, :model)
    prompt = build_fragment_prompt(implementation)

    case call_llm(prompt, model, opts) do
      {:ok, text} ->
        case parse_code(text) do
          nil ->
            {:error, :no_code_block_found}

          code ->
            fragment =
              Fragment.new(code,
                language: "elixir",
                domain: domain,
                source: :concept_expanded
              )

            {:ok, fragment}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp expand_subtopic(subtopic, opts) do
    Logger.info(
      "ConceptExpander: Expanding sub-topic '#{subtopic}' into implementations..."
    )

    try do
      case expand_to_implementations(subtopic, opts) do
        [] ->
          Logger.warning(
            "ConceptExpander: No implementations generated for '#{subtopic}'"
          )

          []

        implementations ->
          Logger.info(
            "ConceptExpander: Generated #{length(implementations)} implementations for '#{subtopic}'"
          )

          domain = slugify_domain(subtopic)

          Enum.flat_map(implementations, fn implementation ->
            generate_single_fragment(implementation, domain, opts)
          end)
      end
    rescue
      e ->
        Logger.warning(
          "ConceptExpander: Failed to expand sub-topic '#{subtopic}': #{Exception.message(e)}"
        )

        []
    end
  end

  defp generate_single_fragment(implementation, domain, opts) do
    Logger.info("ConceptExpander: Generating fragment for: #{implementation}")

    try do
      case generate_fragment(implementation, domain, opts) do
        {:ok, fragment} ->
          [fragment]

        {:error, reason} ->
          Logger.warning(
            "ConceptExpander: Failed to generate fragment for '#{implementation}': #{inspect(reason)}"
          )

          []
      end
    rescue
      e ->
        Logger.warning(
          "ConceptExpander: Fragment generation raised for '#{implementation}': #{Exception.message(e)}"
        )

        []
    end
  end

  # ── Prompt builders ────────────────────────────────────────────────

  defp build_subtopics_prompt(concept, breadth) do
    """
    You are a creative domain researcher. Given the following broad concept, generate exactly #{breadth} distinct, specific sub-topics that could each be implemented as a software simulation.

    Concept: "#{concept}"

    Requirements:
    - Each sub-topic should be a specific, implementable concept (not vague)
    - Sub-topics should be diverse and cover different aspects of the broad concept
    - Return ONLY a numbered list, one sub-topic per line
    - Do not include any explanation, just the sub-topics

    Example format:
    1. Bird flocking with predator avoidance
    2. Wolf pack hunting coordination
    ...
    """
  end

  defp build_implementations_prompt(subtopic, depth) do
    """
    You are a creative software designer. Given the following sub-topic, generate exactly #{depth} distinct, concrete software implementation ideas. Each should be a self-contained simulation that could be written in ~40 lines of code.

    Sub-topic: "#{subtopic}"

    Requirements:
    - Each implementation should be unique in its approach and focus
    - Vary the simulation style (agent-based, cellular automata, event-driven, state-machine, etc.)
    - Return ONLY a numbered list, one implementation idea per line
    - Keep each idea to a single descriptive sentence
    - Do not include any explanation

    Example format:
    1. Agent-based flocking with separation/alignment/cohesion rules
    2. Grid-based bird migration with seasonal patterns
    ...
    """
  end

  defp build_fragment_prompt(implementation) do
    """
    You are an expert Elixir programmer. Write a self-contained Elixir module (~20-60 lines) that implements the following simulation concept.

    Implementation: "#{implementation}"

    Requirements:
    - Write idiomatic, working Elixir code
    - Include a module name that reflects the implementation
    - The code should be a complete, runnable module
    - Use appropriate Elixir idioms (pattern matching, pipes, etc.)
    - Add a brief @moduledoc comment describing the simulation
    - Return ONLY the code in a single code block, no explanation

    Format:
    ```elixir
    defmodule ... do
      ...
    end
    ```
    """
  end

  # ── Parsing ────────────────────────────────────────────────────────

  defp parse_subtopics(text) do
    ~r/^\s*\d+\.\s+(.+)$/m
    |> Regex.scan(text)
    |> Enum.map(fn [_, item] -> String.trim(item) end)
  end

  defp parse_implementations(text) do
    ~r/^\s*\d+\.\s+(.+)$/m
    |> Regex.scan(text)
    |> Enum.map(fn [_, item] -> String.trim(item) end)
  end

  defp parse_code(text) do
    case Regex.run(~r/```(?:elixir)?\s*\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  # ── Domain slugification ───────────────────────────────────────────

  defp slugify_domain(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 40)
  end

  # ── LLM calling ────────────────────────────────────────────────────

  defp call_llm(prompt, model, opts) do
    caller = Keyword.get(opts, :llm_caller)

    if caller do
      caller.(prompt, model)
    else
      do_call_llm(prompt, model)
    end
  end

  defp do_call_llm(prompt, model) do
    try do
      alias ReqLLM.Context, as: C

      context = C.new([C.user(prompt)])

      with {:ok, stream_response} <- ReqLLM.stream_text(model, context),
           {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
           text <- ReqLLM.Response.text(response) do
        {:ok, text}
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
