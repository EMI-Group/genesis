defmodule EvoGit.Runtime.Evolution.Engine do
  @moduledoc """
  Open-ended evolution engine — orchestrates the novelty-driven evolutionary loop.

  Implements the core algorithmic loop:
  1. Initialize: Populate the Entropy Pool with diverse seed fragments
  2. Evolve: Iterate generations of selection, synthesis, and replacement
  3. Synthesize: Combine evolved material into a solution
  4. Apply: Use a Manager agent to apply the solution to the codebase
  """

  require Logger

  alias EvoGit.Runtime.Evolution.{Fragment, SeedFragments, EntropyPool, MapElites,
    NoveltyMetric, LLMSynthesis, ConceptExpander}

  alias EvoGit.{AgentSpec, AgentScheduler, Config, Defaults}
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Runtime.PullRequest

  @type state :: %__MODULE__{}

  defstruct [
    :objective, :repo_path, :base_sha, :node_path, :model,
    :generation, :max_generations, :pool_size, :selection_size,
    :crossover_rate, :mutation_rate, :convergence_threshold,
    :novelty_neighbors, :stagnation_limit, :event_sink, :user_seeds,
    :concepts, :opts,
    :supervisor,
    best_novelty: 0.0, stagnation_count: 0, started_at: nil
  ]

  # ── Defaults ──────────────────────────────────────────────────────

  @default_max_generations 10
  @default_pool_size 30
  @default_selection_size 6
  @default_crossover_rate 0.7
  @default_mutation_rate 0.3
  @default_convergence_threshold 0.01
  @default_novelty_neighbors 5
  @default_stagnation_limit 3
  @default_llm_seeds 10
  @default_concept_breadth 10
  @default_implementation_depth 5

  # ── Public API ────────────────────────────────────────────────────

  @doc """
  Runs the open-ended evolution loop.

  Called from `Evolution.run_complex_mode/5`. Returns a result map matching
  the existing evolution return shape:
  `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}`
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(objective, repo_path, current_sha, node_path, opts \\ []) do
    Logger.info("Evolution Engine: Starting open-ended evolution for: #{objective}")

    # Note: EntropyPool and MapElites use their default __MODULE__ names.
    # The Engine cannot run multiple concurrent instances due to this limitation.
    state = build_state(objective, repo_path, current_sha, node_path, opts)

    # Start a supervisor tree for the EntropyPool and MapElites GenServers
    supervisor_name = :"evolution_sup_#{:erlang.unique_integer([:positive])}"
    {:ok, sup_pid} = start_supervisor(supervisor_name, state)

    try do
      state = %{state | supervisor: sup_pid, started_at: DateTime.utc_now()}

      emit_event(state, 0, :initialized, %{
        pool_size: state.pool_size,
        max_generations: state.max_generations,
        model: state.model
      })

      with {:ok, state} <- initialize(state),
           {:ok, state} <- evolution_loop(state),
           {:ok, solution} <- synthesize_solution(state),
           {:ok, result_map} <- apply_solution(state, solution) do
        Logger.info("Evolution Engine: Completed successfully after #{state.generation} generations")
        {:ok, result_map}
      else
        {:error, reason} = err ->
          Logger.error("Evolution Engine: Failed: #{inspect(reason)}")
          err
      end
    after
      cleanup_genservers(state, supervisor_name)
    end
  end

  # ── State Construction ────────────────────────────────────────────

  defp build_state(objective, repo_path, current_sha, node_path, opts) do
    evo_config = get_evolution_config()

    %__MODULE__{
      objective: objective,
      repo_path: repo_path,
      base_sha: current_sha,
      node_path: node_path,
      model: resolve_model(opts),
      generation: 0,
      max_generations: Keyword.get(opts, :max_generations, Map.get(evo_config, :max_generations, @default_max_generations)),
      pool_size: Keyword.get(opts, :pool_size, Map.get(evo_config, :pool_size, @default_pool_size)),
      selection_size: Keyword.get(opts, :selection_size, Map.get(evo_config, :selection_size, @default_selection_size)),
      crossover_rate: Keyword.get(opts, :crossover_rate, Map.get(evo_config, :crossover_rate, @default_crossover_rate)),
      mutation_rate: Keyword.get(opts, :mutation_rate, Map.get(evo_config, :mutation_rate, @default_mutation_rate)),
      convergence_threshold: Keyword.get(opts, :convergence_threshold, Map.get(evo_config, :convergence_threshold, @default_convergence_threshold)),
      novelty_neighbors: Keyword.get(opts, :novelty_neighbors, Map.get(evo_config, :novelty_neighbors, @default_novelty_neighbors)),
      stagnation_limit: Keyword.get(opts, :stagnation_limit, Map.get(evo_config, :stagnation_limit, @default_stagnation_limit)),
      event_sink: Keyword.get(opts, :event_sink),
      user_seeds: load_user_seeds_from_opts(opts),
      concepts: Keyword.get(opts, :concepts, []),
      opts: opts
    }
  end

  defp get_evolution_config do
    case Config.resolve(:evolution) do
      nil -> %{}
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp load_user_seeds_from_opts(opts) do
    file_seeds =
      case Keyword.get(opts, :seeds) do
        nil -> []
        paths when is_list(paths) -> SeedFragments.load_user_seeds(paths)
      end

    content_seeds =
      case Keyword.get(opts, :seed_content) do
        nil -> []
        content when is_binary(content) -> SeedFragments.seeds_from_content(content)
      end

    file_seeds ++ content_seeds
  end

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> Defaults.llm_model()
      model -> model
    end
  end

  # ── Supervisor & GenServer Management ─────────────────────────────

  defp start_supervisor(name, state) do
    children = [
      {EntropyPool, max_size: state.pool_size},
      {MapElites, []}
    ]

    import Supervisor, only: [start_link: 2]
    opts = [strategy: :one_for_one, name: name, max_restarts: 0]
    start_link(children, opts)
  end

  defp cleanup_genservers(_state, supervisor_name) do
    # Stop the supervisor — this terminates all children (EntropyPool, MapElites)
    case Process.whereis(supervisor_name) do
      nil -> :ok
      pid ->
        Supervisor.stop(pid, :shutdown, 5_000)
    end
  rescue
    _ -> :ok
  end

  # ── Delegated GenServer calls ─────────────────────────────────────

  # EntropyPool and MapElites use their default __MODULE__ names.
  # Direct delegation keeps the Engine decoupled from internal naming.

  defp pool_insert(_state, fragment), do: EntropyPool.insert(fragment)
  defp pool_insert_all(_state, fragments), do: EntropyPool.insert_all(fragments)
  defp pool_all(_state), do: EntropyPool.all()
  defp pool_select_novel(_state, n), do: EntropyPool.select_novel(n)
  defp pool_evict_redundant(_state), do: EntropyPool.evict_most_redundant()

  defp elites_insert(_state, fragment), do: MapElites.insert(fragment)
  defp elites_all(_state), do: MapElites.all_fragments()

  # ── Phase 1: Initialization ───────────────────────────────────────

  defp initialize(state) do
    Logger.info("Evolution Engine: Initializing entropy pool")

    # 1. Load user seeds (if provided) or fall back to built-in seeds
    user_seeds = state.user_seeds || []

    {seeds, seed_label} =
      if user_seeds != [] do
        {user_seeds, "user-provided"}
      else
        {SeedFragments.all(), "built-in"}
      end

    Logger.debug("Evolution Engine: Loaded #{length(seeds)} #{seed_label} seed fragments")

    # 2. Generate additional fragments via LLM
    llm_seeds =
      safe_llm_call({:evolution, :init}, fn ->
        SeedFragments.generate_with_llm(
          state.objective,
          @default_llm_seeds,
          %{model: state.model}
        )
      end)
      |> List.wrap()

    Logger.debug("Evolution Engine: Generated #{length(llm_seeds)} LLM seed fragments")

    # 2b. Expand concepts into code fragments (if provided)
    concept_fragments =
      state.concepts
      |> Enum.flat_map(fn concept ->
        Logger.info("Evolution Engine: Expanding concept '#{concept}' into fragments...")

        expand_opts = [
          model: state.model,
          concept_breadth: get_concept_config(:concept_breadth, @default_concept_breadth),
          implementation_depth: get_concept_config(:implementation_depth, @default_implementation_depth)
        ]

        safe_llm_call({:evolution, :concept_expand, concept}, fn ->
          ConceptExpander.expand(concept, expand_opts)
        end)
        |> List.wrap()
      end)

    Logger.debug("Evolution Engine: Generated #{length(concept_fragments)} concept expansion fragments")

    # 3. Process all fragments: extract features, compute profiles, score novelty
    all_raw = seeds ++ llm_seeds ++ concept_fragments

    # Extract structural features (no LLM needed)
    all_with_features =
      Enum.map(all_raw, fn fragment ->
        features = Fragment.extract_structural_features(fragment)
        %{fragment | structural_features: features}
      end)

    # Compute behavioral profiles (requires LLM)
    all_with_profiles =
      Enum.map(all_with_features, fn fragment ->
        profile =
          safe_llm_call({:evolution, :profile, fragment.id}, fn ->
            NoveltyMetric.behavioral_profile(fragment.content, state.model)
          end)

        %{fragment | behavioral_profile: profile || %{}}
      end)

    # Compute novelty scores against the growing reference set
    all_scored = compute_batch_novelty(all_with_profiles, state)

    # 4. Insert all into EntropyPool and MapElites
    pool_insert_all(state, all_scored)

    Enum.each(all_scored, fn fragment ->
      elites_insert(state, fragment)
    end)

    # Update best novelty
    best = all_scored |> Enum.map(& &1.novelty_score) |> Enum.max(fn -> 0.0 end)
    state = %{state | best_novelty: best}

    emit_event(state, 0, :pool_stats, %{
      total: length(all_scored),
      best_novelty: best,
      sources: Enum.frequencies_by(all_scored, & &1.source)
    })

    Logger.info("Evolution Engine: Initialized pool with #{length(all_scored)} fragments (best novelty: #{Float.round(best, 4)})")

    {:ok, state}
  end

  # ── Phase 2: Evolution Loop ───────────────────────────────────────

  defp evolution_loop(state) do
    cond do
      state.generation >= state.max_generations ->
        Logger.info("Evolution Engine: Reached max generations (#{state.max_generations})")
        {:ok, state}

      state.stagnation_count >= state.stagnation_limit ->
        Logger.info("Evolution Engine: Stagnation limit reached (#{state.stagnation_limit})")
        {:ok, state}

      true ->
        {:ok, state} = run_generation(state)
        evolution_loop(state)
    end
  end

  defp run_generation(state) do
    state = %{state | generation: state.generation + 1}
    gen = state.generation

    Logger.debug("Evolution Engine: Starting generation #{gen}/#{state.max_generations}")

    # 1. Select parents
    parents = pool_select_novel(state, state.selection_size)

    if parents == [] do
      Logger.warning("Evolution Engine: No fragments in pool for generation #{gen}")
      {:ok, %{state | stagnation_count: state.stagnation_count + 1}}
    else
      # 2. Synthesize children via crossover and mutation
      children = synthesize_children(parents, state)

      # 3. Process and insert viable children
      {inserted_count, state} = process_children(children, state)

      # 4. Check convergence
      current_best = state.best_novelty
      pool = pool_all(state)
      pool_best = pool |> Enum.map(& &1.novelty_score) |> Enum.max(fn -> 0.0 end)

      improvement = pool_best - current_best
      stagnation_count =
        if improvement > state.convergence_threshold do
          0
        else
          state.stagnation_count + 1
        end

      state = %{state | best_novelty: pool_best, stagnation_count: stagnation_count}

      emit_event(state, gen, :generation_complete, %{
        parents_selected: length(parents),
        children_synthesized: length(children),
        children_inserted: inserted_count,
        pool_size: length(pool),
        best_novelty: pool_best,
        improvement: Float.round(improvement, 6),
        stagnation_count: stagnation_count
      })

      if improvement > state.convergence_threshold do
        emit_event(state, gen, :novel_fragment, %{
          best_novelty: pool_best,
          improvement: improvement
        })
      end

      Logger.debug("Evolution Engine: Gen #{gen} complete — inserted #{inserted_count}, best novelty: #{Float.round(pool_best, 4)}, stagnation: #{stagnation_count}")

      {:ok, state}
    end
  end

  # ── Child Synthesis ───────────────────────────────────────────────

  defp synthesize_children(parents, state) do
    # Pair up parents for crossover; unpaired parents go through mutation
    {crossover_pairs, mutation_candidates} = partition_for_synthesis(parents)

    # Crossover
    crossover_children =
      crossover_pairs
      |> Enum.flat_map(fn {a, b} ->
        if :rand.uniform() < state.crossover_rate do
          case safe_llm_call({:evolution, :crossover, state.generation, a.id}, fn ->
                 LLMSynthesis.crossover(a, b, state.objective, model: state.model)
               end) do
            {:ok, child} -> [child]
            {:error, reason} ->
              Logger.debug("Evolution Engine: Crossover failed: #{inspect(reason)}")
              []
          end
        else
          []
        end
      end)

    # Mutation — parents not selected for crossover + single remaining parent
    mutation_children =
      mutation_candidates
      |> Enum.flat_map(fn parent ->
        if :rand.uniform() < state.mutation_rate do
          case safe_llm_call({:evolution, :mutate, state.generation, parent.id}, fn ->
                 LLMSynthesis.mutate(parent, state.objective, model: state.model)
               end) do
            {:ok, child} -> [child]
            {:error, reason} ->
              Logger.debug("Evolution Engine: Mutation failed: #{inspect(reason)}")
              []
          end
        else
          []
        end
      end)

    crossover_children ++ mutation_children
  end

  defp partition_for_synthesis(parents) do
    # Pair adjacent parents for crossover; leftover goes to mutation
    {pairs, leftover} =
      parents
      |> Enum.chunk_every(2)
      |> Enum.split_with(fn chunk -> length(chunk) == 2 end)

    crossover_pairs = Enum.map(pairs, fn [a, b] -> {a, b} end)
    mutation_candidates = List.flatten(leftover)

    {crossover_pairs, mutation_candidates}
  end

  # ── Child Processing ──────────────────────────────────────────────

  defp process_children(children, state) do
    reference_set = pool_all(state)

    inserted =
      children
      |> Enum.filter(&child_viable?/1)
      |> Enum.map(fn child ->
        # Extract features and profile
        child = enrich_fragment(child, state)

        # Compute novelty against current pool
        novelty = NoveltyMetric.novelty_score(child, reference_set, k: state.novelty_neighbors)
        %{child | novelty_score: novelty}
      end)
      |> Enum.filter(fn child -> child.novelty_score > 0.0 end)
      |> Enum.sort_by(& &1.novelty_score, :desc)

    # Insert novel children, evicting redundant ones to maintain pool size
    Enum.each(inserted, fn child ->
      pool_insert(state, child)
      pool_evict_redundant(state)
      elites_insert(state, child)

      # Update reference set for subsequent novelty calculations
      reference_set = [child | reference_set]
      reference_set
    end)

    {length(inserted), state}
  end

  defp child_viable?(fragment) do
    case LLMSynthesis.evaluate_viability(fragment.content) do
      {:ok, _} -> true
      {:error, _} ->
        Logger.debug("Evolution Engine: Fragment #{fragment.id} not viable, skipping")
        false
    end
  end

  defp enrich_fragment(fragment, state) do
    features = Fragment.extract_structural_features(fragment)

    profile =
      safe_llm_call({:evolution, :enrich, fragment.id}, fn ->
        NoveltyMetric.behavioral_profile(fragment.content, state.model)
      end)

    %{fragment | structural_features: features, behavioral_profile: profile || %{}}
  end

  # ── Phase 3: Synthesize Solution ──────────────────────────────────

  defp synthesize_solution(state) do
    Logger.info("Evolution Engine: Synthesizing final solution")

    # Gather top fragments from pool and all MAP-Elites elites
    pool_fragments = pool_select_novel(state, 10)
    elite_fragments = elites_all(state)

    # Combine and deduplicate
    all_fragments =
      (pool_fragments ++ elite_fragments)
      |> Enum.uniq_by(& &1.id)

    summaries =
      all_fragments
      |> Enum.map(&Fragment.summarize/1)
      |> Enum.join("\n\n---\n\n")

    prompt = build_synthesis_prompt(state.objective, summaries, state.generation)

    solution =
      safe_llm_call({:evolution, :synthesize}, fn ->
        call_llm(prompt, state.model)
      end)

    case solution do
      {:ok, text} when is_binary(text) ->
        Logger.info("Evolution Engine: Solution synthesized from #{length(all_fragments)} fragments")
        {:ok, text}

      {:error, reason} ->
        Logger.warning("Evolution Engine: LLM synthesis failed, using fallback: #{inspect(reason)}")
        {:ok, build_fallback_solution(pool_fragments)}

      nil ->
        {:ok, build_fallback_solution(pool_fragments)}
    end
  end

  defp build_synthesis_prompt(objective, fragment_summaries, generations) do
    """
    You are a software synthesis engine. Given an evolution objective and a collection of \
    evolved code fragments, synthesize a coherent solution approach.

    ## Objective
    #{objective}

    ## Evolved Fragments (after #{generations} generations of novelty-driven evolution)
    #{fragment_summaries}

    ## Task
    Based on the evolved material above, provide a detailed, actionable implementation plan \
    that addresses the objective. The plan should incorporate the most promising ideas and \
    patterns from the evolved fragments. Be specific about:
    1. What files to create or modify
    2. What code to write (include key functions and data structures)
    3. How the pieces fit together
    4. Any important design decisions

    Provide the solution as a clear, well-structured description that a developer agent can execute.
    """
  end

  defp build_fallback_solution(top_fragments) do
    parts =
      top_fragments
      |> Enum.take(3)
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n")

    "Based on evolved material:\n\n#{parts}"
  end

  # ── Phase 4: Apply Solution ───────────────────────────────────────

  defp apply_solution(state, solution) do
    Logger.info("Evolution Engine: Applying synthesized solution via Manager agent")

    phylo_node = PhyloGraphNode.new(state.repo_path, state.base_sha)
    context_node = ContextNode.load(state.node_path, state.repo_path)

    # Build a detailed objective for the Manager agent
    agent_objective = """
    [Evolution Engine] Apply the following evolved solution to the codebase.

    ## Original Objective
    #{state.objective}

    ## Evolved Solution (after #{state.generation} generations)
    #{solution}

    Apply this solution carefully, making minimal changes to achieve the objective. \
    Commit your work when done.
    """

    spec =
      AgentSpec.new(
        context_node,
        phylo_node,
        EvoGit.Agents.Manager,
        agent_objective,
        event_sink: state.event_sink
      )

    case AgentScheduler.run_agent(spec) do
      {:ok, %Result{} = agent_output} ->
        notify_finalizing(state)
        merge_and_report(state, agent_output)

      {:error, reason} = err ->
        Logger.error("Evolution Engine: Manager agent failed: #{inspect(reason)}")
        err
    end
  end

  # ── Merge & Report (mirrors Evolution.merge_and_report) ───────────

  defp merge_and_report(state, %Result{} = agent_output) do
    final_sha = agent_output.commit_sha
    result = agent_output.result
    tag = agent_output.tag

    {:ok, base_sha} = Git.rev_parse(state.repo_path)

    if final_sha && final_sha != base_sha do
      Logger.info("Evolution Engine: Agent produced changes (#{String.slice(base_sha, 0, 7)} -> #{String.slice(final_sha, 0, 7)})")

      branch_name = generate_branch_name("evolve")
      {:ok, _} = Git.create_branch(state.repo_path, branch_name, final_sha)
      Logger.info("Evolution Engine: Created branch '#{branch_name}'")

      {pr_url, pr_title} = PullRequest.try_create(state.repo_path, branch_name, state.objective, result)

      {:ok, %{
        commit_sha: final_sha,
        result: result,
        tag: tag,
        branch_name: branch_name,
        pr_url: pr_url,
        pr_title: pr_title
      }}
    else
      Logger.info("Evolution Engine: No changes detected from agent")
      {:ok, %{
        commit_sha: final_sha || base_sha,
        result: result,
        tag: tag,
        branch_name: nil,
        pr_url: nil,
        pr_title: nil,
        no_changes: true
      }}
    end
  end

  defp notify_finalizing(state) do
    if task_id = state.opts[:task_id] do
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})
    end
  end

  defp generate_branch_name(prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "evogit/#{prefix}_#{short_id}"
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp compute_batch_novelty(fragments, state) do
    # Compute novelty scores against each other as the reference set grows
    {scored, _} =
      Enum.reduce(fragments, {[], []}, fn fragment, {acc, reference} ->
        novelty = NoveltyMetric.novelty_score(fragment, reference, k: state.novelty_neighbors)
        scored = %{fragment | novelty_score: novelty}
        {[scored | acc], [scored | reference]}
      end)

    Enum.reverse(scored)
  end

  defp get_concept_config(key, default) do
    evo_config = get_evolution_config()
    Map.get(evo_config, key, default)
  end

  defp safe_llm_call(agent_id, fun) do
    AgentScheduler.with_llm_slot(agent_id, fn ->
      try do
        fun.()
      rescue
        e ->
          Logger.warning("Evolution Engine: LLM call failed: #{inspect(e)}")
          nil
      end
    end)
  rescue
    e ->
      Logger.warning("Evolution Engine: Slot acquisition failed: #{inspect(e)}")
      nil
  end

  defp emit_event(state, generation, event_type, data) do
    case state.event_sink do
      nil -> :ok
      pid when is_pid(pid) ->
        send(pid, {:evolution_event, generation, event_type, data})
      _ -> :ok
    end
  end

  defp call_llm(prompt, model) do
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
