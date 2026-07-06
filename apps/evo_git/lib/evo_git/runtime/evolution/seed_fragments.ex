defmodule EvoGit.Runtime.Evolution.SeedFragments do
  @moduledoc """
  Built-in cross-domain code fragments for entropy pool initialization.

  Provides a curated collection of diverse Elixir code fragments spanning
  multiple paradigms and domains. The fragments are intentionally unrelated
  to each other to maximize diversity in the initial gene pool.
  """

  alias EvoGit.Runtime.Evolution.Fragment
  alias EvoGit.Runtime.Evolution.SeedFragments.{Generators, LLM}

  require Logger

  @blank_line_sep_re ~r/\n\s*\n/

  @doc """
  Returns all built-in seed fragments.

  Each fragment is a `Fragment.t` containing 20–60 lines of idiomatic Elixir
  from a distinct domain: physics, game development, data pipelines, HTTP,
  graph algorithms, pattern matching, concurrency, streaming, sorting,
  encoding, middleware, tree traversal, rate limiting, caching, and events.
  """
  @spec all() :: [Fragment.t()]
  def all do
    [
      Generators.physics_fragment(),
      Generators.game_loop_fragment(),
      Generators.data_pipeline_fragment(),
      Generators.http_handler_fragment(),
      Generators.graph_algorithm_fragment(),
      Generators.pattern_matching_fragment(),
      Generators.process_pool_fragment(),
      Generators.stream_processing_fragment(),
      Generators.sorting_fragment(),
      Generators.encoding_fragment(),
      Generators.middleware_fragment(),
      Generators.tree_traversal_fragment(),
      Generators.rate_limiter_fragment(),
      Generators.cache_ttl_fragment(),
      Generators.event_emitter_fragment()
    ]
  end

  @doc """
  Filters built-in fragments by domain category.

  ## Example

      iex> fragments = EvoGit.Runtime.Evolution.SeedFragments.by_category(:physics)
      iex> length(fragments)
      1
  """
  @spec by_category(atom() | String.t()) :: [Fragment.t()]
  def by_category(category) when is_atom(category) or is_binary(category) do
    cat_str = if is_atom(category), do: Atom.to_string(category), else: category
    Enum.filter(all(), &(&1.domain == cat_str))
  end

  @doc """
  Returns `n` random fragments sampled without replacement from the full set.
  """
  @spec random(pos_integer()) :: [Fragment.t()]
  def random(n) when is_integer(n) and n > 0 do
    all()
    |> Enum.shuffle()
    |> Enum.take(n)
  end

  @doc """
  Generates `n` additional diverse fragments using the LLM.

  The LLM is asked to produce Elixir code snippets from domains *unrelated*
  to the given `objective`, maximizing entropy-pool diversity.

  ## Parameters

    * `objective` — the current evolution objective (used to avoid overlap).
    * `n`         — number of fragments to request.
    * `config`    — map with `:model` (LLM model string) and optional `:agent_id`.

  The caller is responsible for slot acquisition; this function does **not**
  call `AgentScheduler.with_llm_slot/2`.

  Returns a list of `Fragment.t` with `source: :generated`, or `[]` on error.
  """
  @spec generate_with_llm(String.t(), pos_integer(), map()) :: [Fragment.t()]
  def generate_with_llm(objective, n, %{model: model} = _config) when is_binary(objective) and is_integer(n) and n > 0 do
    prompt = LLM.build_generation_prompt(objective, n)

    context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

    with {:ok, stream_response} <- ReqLLM.stream_text(model, context),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
         text <- ReqLLM.Response.text(response) do
      LLM.parse_code_blocks(text)
    else
      {:error, reason} ->
        Logger.warning("SeedFragments LLM generation failed: #{inspect(reason)}")
        []

      _ ->
        Logger.warning("SeedFragments LLM generation returned unexpected result")
        []
    end
  end

  def generate_with_llm(_objective, _n, _config), do: []

  @doc """
  Loads seed fragments from user-provided file paths.

  Each file is read and converted to a Fragment with the language inferred from
  the file extension. Invalid paths are logged as warnings and skipped.

  Returns a list of `Fragment.t` with `source: :seed` and `domain: "user_seed"`.
  """
  @spec load_user_seeds([String.t()]) :: [Fragment.t()]
  def load_user_seeds(file_paths) when is_list(file_paths) do
    file_paths
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} ->
          language = Generators.infer_language(path)
          [Fragment.new(content, language: language, domain: "user_seed", source: :seed)]

        {:error, reason} ->
          Logger.warning("SeedFragments: Failed to read seed file #{path}: #{inspect(reason)}")
          []
      end
    end)
  end

  @doc """
  Creates seed fragments from pasted text content.

  Splits the content on blank lines as a heuristic for separating multiple seed
  fragments. Each resulting fragment gets `language: "unknown"` and
  `domain: "user_seed"`.

  Returns a list of `Fragment.t` with `source: :seed`.
  """
  @spec seeds_from_content(String.t()) :: [Fragment.t()]
  def seeds_from_content(content) when is_binary(content) do
    content
    |> String.split(@blank_line_sep_re, trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn fragment_content ->
      Fragment.new(fragment_content, language: "unknown", domain: "user_seed", source: :seed)
    end)
  end
end
