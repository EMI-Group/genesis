defmodule EvoGit.Runtime.Evolution.SeedFragments.LLM do
  @moduledoc """
  LLM helper functions for seed fragment generation.

  Provides prompt construction and response parsing for generating
  diverse code fragments via LLM.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  @domain_code_re ~r/\[(\w+)\]\s*\n```elixir\s*\n(.*?)```/s

  # ---------------------------------------------------------------------------
  # Prompt construction
  # ---------------------------------------------------------------------------

  def build_generation_prompt(objective, n) do
    """
    Generate #{n} diverse, working Elixir code snippets. Each snippet should be
    20–60 lines of idiomatic Elixir from a distinct domain. The domains should
    be UNRELATED to the following objective:

    "#{objective}"

    Suggested domains (pick #{n} that differ from the objective):
    cryptography, music theory, compiler design, robotics, bioinformatics,
    financial modeling, image processing, natural language processing,
    distributed systems, math/linear algebra, database query planner,
    scheduling/optimization, parser combinators, statistics, networking.

    For each snippet:
    1. Wrap it in a ```elixir ... ``` code block.
    2. On the line IMMEDIATELY before the code block, write the domain as a
       single word in square brackets, e.g. [cryptography].

    Output ONLY the code blocks with their domain labels — no other text.
    """
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  def parse_code_blocks(text) when is_binary(text) do
    # Match patterns like [domain]\n```elixir\n...code...\n```
    Regex.scan(@domain_code_re, text, capture: :all_but_first)
    |> Enum.map(fn [domain_str, code] ->
      Fragment.new(String.trim(code),
        language: "elixir",
        domain: domain_str,
        source: :generated
      )
    end)
  end

  def parse_code_blocks(_), do: []
end
