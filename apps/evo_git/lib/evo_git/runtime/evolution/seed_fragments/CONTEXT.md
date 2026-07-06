# SeedFragments — Built-in and Generated Code Fragments

## Intent

Provides cross-domain Elixir code fragments for initializing the entropy pool in complex evolution mode. Includes 15 built-in fragments spanning diverse domains (physics, game dev, data pipelines, HTTP, graph algorithms, pattern matching, concurrency, streaming, sorting, encoding, middleware, tree traversal, rate limiting, caching, events) plus LLM-powered generation of additional diverse fragments.

## API Surface

### Modules

| Module | File | Public API | Description |
|--------|------|------------|-------------|
| `EvoGit.Runtime.Evolution.SeedFragments` | `seed_fragments.ex` | `all/0`, `by_category/1`, `random/1`, `generate_with_llm/3`, `load_user_seeds/1`, `seeds_from_content/1` | Public entry point for seed fragment access, generation, and loading |
| `EvoGit.Runtime.Evolution.SeedFragments.Generators` | `generators.ex` | `physics_fragment/0` ... `event_emitter_fragment/0` (15 total), `infer_language/1` | Fragment generator functions — one per domain. Pure data functions with no inter-dependencies. |
| `EvoGit.Runtime.Evolution.SeedFragments.LLM` | `llm.ex` | `build_generation_prompt/2`, `parse_code_blocks/1` | LLM prompt construction and response parsing for fragment generation |

## Constraints

- Fragment generators are pure data functions — no side effects or external dependencies beyond `Fragment.new/1`
- `infer_language/1` maps file extensions to language strings (used by `load_user_seeds/1`)
- `@domain_code_re` is duplicated in both `seed_fragments.ex` and `llm.ex` — they serve different callers (`seeds_from_content/1` and `parse_code_blocks/1` respectively)
- All 15 fragment functions must remain in the same order in `all/0` to preserve deterministic output
