# Evolution — Open-Ended Evolution Engine

## Intent
Implements the open-ended evolution engine for Mode B (Complex Evolution). Uses novelty search, quality diversity (MAP-Elites), and LLM-powered semantic crossover to discover creative solutions. The engine maintains a pool of cross-domain code fragments ("genetic material"), iteratively evolves them through crossover and mutation, synthesizes a solution from the most novel fragments, and applies it via a Manager agent.

## API Surface

### Modules

| Module | File | Public API | Description |
|--------|------|------------|-------------|
| `EvoGit.Runtime.Evolution.Engine` | `engine.ex` | `run/5` | Main orchestrator. Runs the full evolution loop: initialize → evolve → synthesize → apply. Called from `Evolution.run_complex_mode/5`. Returns `{:ok, %{commit_sha, result, tag, branch_name, pr_url}}` or `{:error, reason}`. |
| `EvoGit.Runtime.Evolution.Fragment` | `fragment.ex` | `new/2`, `extract_structural_features/1`, `to_feature_vector/1`, `summarize/1` | Core data structure — a code fragment with structural features, behavioral profile, novelty score, and lineage tracking. AST-based feature extraction for Elixir code. |
| `EvoGit.Runtime.Evolution.SeedFragments` | `seed_fragments.ex` | `all/0`, `by_category/1`, `random/1`, `generate_with_llm/3` | 15 built-in cross-domain Elixir code fragments (physics, game dev, data pipelines, HTTP, graph algorithms, etc.) plus LLM-powered generation of additional diverse fragments. |
| `EvoGit.Runtime.Evolution.EntropyPool` | `entropy_pool.ex` | `start_link/1`, `insert/1`, `insert_all/1`, `get/1`, `all/0`, `size/0`, `select_novel/1`, `select_random/1`, `evict_most_redundant/0`, `update_fragment/1`, `clear/0`, `stop/0` | ETS-backed GenServer storing Fragment structs. Supports novelty-ranked selection, random sampling, and automatic eviction of redundant fragments when pool exceeds `max_size`. |
| `EvoGit.Runtime.Evolution.MapElites` | `map_elites.ex` | `start_link/1`, `insert/1`, `get_elites/0`, `get_elite/1`, `all_fragments/0`, `size/0`, `descriptor_for/1`, `clear/0`, `stop/0` | MAP-Elites quality diversity archive. Grid indexed by behavior descriptors (complexity × paradigm). Retains only the most novel fragment per cell. |
| `EvoGit.Runtime.Evolution.NoveltyMetric` | `novelty_metric.ex` | `novelty_score/3`, `distance/2`, `batch_novelty_scores/3`, `structural_features/1`, `behavioral_profile/2`, `most_redundant/1` | Novelty search scoring via k-nearest-neighbor distance in feature space. Includes LLM-based behavioral profiling and pure AST structural analysis. |
| `EvoGit.Runtime.Evolution.LLMSynthesis` | `llm_synthesis.ex` | `crossover/4`, `mutate/3`, `evaluate_viability/1`, `generate_diverse_fragments/4` | LLM-powered crossover (semantic fusion of two fragments) and mutation (structural transformation of one fragment). Includes syntax viability checking and diverse fragment generation. |

### `Engine.run/5` — Step by Step

1. **Build state**: Reads evolution config from `EvoGit.Config.resolve(:evolution)`, resolves model, constructs engine state with tunable parameters (max_generations, pool_size, crossover_rate, mutation_rate, convergence_threshold, stagnation_limit, novelty_neighbors).
2. **Start supervisor**: Starts a temporary `Supervisor` with `EntropyPool` and `MapElites` as children.
3. **Initialize** (`initialize/1`):
   - Loads 15 built-in seed fragments from `SeedFragments`.
   - Generates additional LLM seed fragments via `SeedFragments.generate_with_llm/3`.
   - Extracts structural features (AST analysis) and behavioral profiles (LLM) for each fragment.
   - Computes novelty scores against the growing reference set.
   - Inserts all fragments into `EntropyPool` and `MapElites`.
4. **Evolution loop** (`evolution_loop/1`): Iterates until max generations or stagnation limit:
   - Selects top-k novel parents from the pool.
   - Partitions parents into crossover pairs and mutation candidates.
   - Synthesizes children via `LLMSynthesis.crossover/4` and `LLMSynthesis.mutate/3`.
   - Filters children by syntax viability (`evaluate_viability/1`).
   - Enriches viable children with features and profiles, computes novelty.
   - Inserts novel children into pool and archive, evicts redundant fragments.
   - Tracks convergence via improvement threshold and stagnation counter.
5. **Synthesize solution** (`synthesize_solution/1`):
   - Gathers top-10 novel pool fragments + all MAP-Elites elites.
   - Builds a synthesis prompt with fragment summaries.
   - LLM generates a coherent implementation plan from evolved material.
   - Falls back to concatenating top fragments if LLM fails.
6. **Apply solution** (`apply_solution/1`):
   - Spawns a `Manager` agent with the synthesized solution as objective.
   - `merge_and_report/2` creates an `evogit/evolve_<hex>` branch and optionally a PR.

## Constraints

- **All LLM calls** go through `AgentScheduler.with_llm_slot/2` (via `safe_llm_call/2`) — the engine never calls `ReqLLM` directly outside of slot acquisition.
- **GenServers are per-run**: `EntropyPool` and `MapElites` are started under a temporary supervisor for each `Engine.run/5` invocation and stopped in the `after` block. The engine cannot run multiple concurrent instances due to the use of default `__MODULE__` GenServer names.
- **Fragments use string domains**: Domain labels are free-form strings (e.g., `"physics"`, `"game_loop"`, `"data_pipeline"`), not atoms.
- **Elixir-only AST analysis**: `Fragment.extract_structural_features/1` and `NoveltyMetric.structural_features/1` parse Elixir code via `Code.string_to_quoted/2`. Non-Elixir fragments will produce `%{parse_error: true, ...}`.
- **Behavioral profiles require LLM**: `NoveltyMetric.behavioral_profile/2` calls the LLM to classify code complexity, paradigm, domain, and abstraction. Failures default to `%{complexity: 0.5, paradigm: :mixed, domain: "unknown", abstraction: 0.5}`.
- **Configuration via 3-level system**: Evolution parameters come from `EvoGit.Config.resolve(:evolution)` (defaults → TOML → runtime overrides), with CLI opts taking highest priority.
- **Event emission**: The engine emits `{:evolution_event, generation, event_type, data}` tuples to the `event_sink` pid (if provided) for dashboard integration.
