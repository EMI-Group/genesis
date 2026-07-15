defmodule EvoGit.Runtime.Evolution.LLMSynthesis do
  @moduledoc """
  LLM-powered semantic crossover and mutation of code fragments.

  The LLM acts as the crossover/mutation operator in the evolutionary loop.
  It semantically fuses concepts from different domains to produce novel code
  that combines structural strengths of both parents.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  @max_retries 2

  @elixir_block_re ~r/```elixir\s*\n([\s\S]*?)```/m
  @generic_block_re ~r/```\s*\n([\s\S]*?)```/m
  @domain_label_re ~r/^#\s*\[(\S+)\]\s*/u

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Semantically fuses two code fragments via LLM crossover.

  Returns `{:ok, fragment}` with the synthesized child, or `{:error, reason}`.

  ## Options

    * `:model` — (required) the LLM model string, e.g. `"anthropic:claude-sonnet-4-20250514"`
  """
  @spec crossover(Fragment.t(), Fragment.t(), String.t(), keyword()) ::
          {:ok, Fragment.t()} | {:error, term()}
  def crossover(parent_a, parent_b, objective, opts \\ []) do
    model = Keyword.fetch!(opts, :model)
    prompt = build_crossover_prompt(parent_a, parent_b, objective)

    do_crossover(prompt, model, parent_a, parent_b, 0)
  end

  @doc """
  Applies a creative structural mutation to a single fragment via LLM.

  Returns `{:ok, fragment}` with the mutated child, or `{:error, reason}`.

  ## Options

    * `:model` — (required) the LLM model string
  """
  @spec mutate(Fragment.t(), String.t(), keyword()) ::
          {:ok, Fragment.t()} | {:error, term()}
  def mutate(fragment, objective, opts \\ []) do
    model = Keyword.fetch!(opts, :model)
    prompt = build_mutation_prompt(fragment, objective)

    do_mutate(prompt, model, fragment, 0)
  end

  @doc """
  Checks the syntax viability of Elixir code content.

  Returns `{:ok, %{syntax_ok: true}}` on success,
  or `{:error, %{syntax_ok: false, error: message}}` on failure.
  """
  @spec evaluate_viability(String.t()) :: {:ok, map()} | {:error, map()}
  def evaluate_viability(content) do
    case Code.string_to_quoted(content) do
      {:ok, _ast} ->
        {:ok, %{syntax_ok: true}}

      {:error, {line, error, token}} ->
        {:error, %{syntax_ok: false, error: "Line #{line}: #{error} #{inspect(token)}"}}
    end
  end

  @doc """
  Generates `n` diverse fragments from the given domains via LLM.

  Returns a list of Fragments with `source: :generated`, or an empty list on error.

  ## Options

    * `:model` — (required) the LLM model string
  """
  @spec generate_diverse_fragments([String.t()], pos_integer(), String.t(), keyword()) ::
          [Fragment.t()]
  def generate_diverse_fragments(domains, n, objective, opts) do
    model = Keyword.fetch!(opts, :model)
    prompt = build_diverse_prompt(domains, n, objective)

    case call_llm(prompt, model) do
      {:ok, response} ->
        response
        |> parse_code_blocks()
        |> Enum.map(fn {code, domain} ->
          Fragment.new(code, source: :generated, domain: domain)
        end)

      {:error, _reason} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private — crossover
  # ---------------------------------------------------------------------------

  defp do_crossover(prompt, model, parent_a, parent_b, attempt) when attempt <= @max_retries do
    case call_llm(prompt, model) do
      {:ok, response} ->
        case parse_code_block(response) do
          {:ok, {code, domain}} ->
            fragment =
              Fragment.new(code,
                source: :crossover,
                domain: domain,
                generation: max(parent_a.generation, parent_b.generation) + 1,
                parents: [parent_a.id, parent_b.id]
              )

            {:ok, fragment}

          {:error, reason} ->
            if attempt < @max_retries do
              clarifying_prompt =
                prompt <> "\n\nYour previous response could not be parsed (#{reason}). Please output ONLY a single ```elixir ... ``` code block with a domain label like [domain_name] on the first line comment."

              do_crossover(clarifying_prompt, model, parent_a, parent_b, attempt + 1)
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_crossover(_prompt, _model, _parent_a, _parent_b, _attempt) do
    {:error, :max_retries_exceeded}
  end

  # ---------------------------------------------------------------------------
  # Private — mutation
  # ---------------------------------------------------------------------------

  defp do_mutate(prompt, model, fragment, attempt) when attempt <= @max_retries do
    case call_llm(prompt, model) do
      {:ok, response} ->
        case parse_code_block(response) do
          {:ok, {code, domain}} ->
            mutated =
              Fragment.new(code,
                source: :mutation,
                domain: domain,
                generation: fragment.generation + 1,
                parents: [fragment.id]
              )

            {:ok, mutated}

          {:error, reason} ->
            if attempt < @max_retries do
              clarifying_prompt =
                prompt <> "\n\nYour previous response could not be parsed (#{reason}). Please output ONLY a single ```elixir ... ``` code block with a domain label like [domain_name] on the first line comment."

              do_mutate(clarifying_prompt, model, fragment, attempt + 1)
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_mutate(_prompt, _model, _fragment, _attempt) do
    {:error, :max_retries_exceeded}
  end

  # ---------------------------------------------------------------------------
  # Private — prompt builders
  # ---------------------------------------------------------------------------

  defp build_crossover_prompt(parent_a, parent_b, objective) do
    """
    You are a creative code synthesist. Your task is to semantically fuse two code fragments.

    Objective: #{objective}

    Parent A (domain: #{parent_a.domain}):
    #{Fragment.summarize(parent_a)}

    Parent B (domain: #{parent_b.domain}):
    #{Fragment.summarize(parent_b)}

    Combine the core logic of Parent A with the structure/approach of Parent B.
    The result should be a novel, working piece of Elixir code that could inform solving the objective.
    Output ONLY the code in a single ```elixir ... ``` block. Include a brief domain label like [domain_name] on the first line comment.
    """
    |> String.trim()
  end

  defp build_mutation_prompt(fragment, objective) do
    """
    You are a creative code mutator. Your task is to apply a fundamental structural transformation to a code fragment.

    Objective: #{objective}

    Fragment (domain: #{fragment.domain}):
    #{Fragment.summarize(fragment)}

    Apply a fundamental structural transformation — change its paradigm, invert its logic, or apply it to a completely different domain.
    The result should be a novel, working piece of Elixir code that could inform solving the objective.
    Output ONLY the code in a single ```elixir ... ``` block. Include a brief domain label like [domain_name] on the first line comment.
    """
    |> String.trim()
  end

  defp build_diverse_prompt(domains, n, objective) do
    domains_str = Enum.join(domains, ", ")

    """
    You are a creative code generator. Generate #{n} diverse Elixir code fragments from unrelated domains.

    Objective: #{objective}
    Suggested domains: #{domains_str}

    Each fragment should be from a different domain and use a fundamentally different approach or paradigm.
    Output EACH fragment in its own ```elixir ... ``` code block. Include a brief domain label like [domain_name] on the first line comment of each block.
    """
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Private — LLM call
  # ---------------------------------------------------------------------------

  defp call_llm(prompt, model) do
    alias ReqLLM.Context, as: C

    context = C.new([C.user(prompt)])

    with {:ok, stream_response} <-
           ReqLLM.stream_text(model, context, provider_options: EvoGit.Config.Schema.LLM.default_provider_options()),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
         text <- ReqLLM.Response.text(response) do
      {:ok, text}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — code block parsing
  # ---------------------------------------------------------------------------

  @doc false
  # Made accessible for testing but semantically private.
  def parse_code_block(response) do
    # Try ```elixir ... ``` first, then fall back to ``` ... ```
    case Regex.run(@elixir_block_re, response) do
      [_, raw_code] ->
        {:ok, extract_domain_and_code(raw_code)}

      nil ->
        case Regex.run(@generic_block_re, response) do
          [_, raw_code] ->
            {:ok, extract_domain_and_code(raw_code)}

          nil ->
            {:error, "no code block found in LLM response"}
        end
    end
  end

  defp extract_domain_and_code(raw_code) do
    stripped = String.trim(raw_code)

    case Regex.run(@domain_label_re, stripped) do
      [prefix, domain] ->
        code = String.trim_leading(stripped, prefix)
        {String.trim(code), domain}

      nil ->
        {stripped, "unknown"}
    end
  end

  defp parse_code_blocks(response) do
    # Find all ```elixir ... ``` blocks, then all ``` ... ``` blocks
    elixir_blocks =
      Regex.scan(@elixir_block_re, response)
      |> Enum.map(fn [_, raw_code] -> extract_domain_and_code(raw_code) end)

    generic_blocks =
      Regex.scan(@generic_block_re, response)
      |> Enum.map(fn [_, raw_code] -> extract_domain_and_code(raw_code) end)

    # Prefer elixir-tagged blocks; augment with generic if needed
    elixir_blocks ++ generic_blocks
  end
end
