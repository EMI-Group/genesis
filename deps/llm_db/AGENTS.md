# AGENTS.md

## Commands

- **Setup**: `mix setup` (install deps, git hooks auto-install on compile)
- **Test all**: `mix test`
- **Test single file**: `mix test test/path/to/file_test.exs`
- **Test single test**: `mix test test/path/to/file_test.exs:12` (line number)
- **Test with coverage**: `mix test --cover`
- **Format code**: `mix format`
- **Compile**: `mix compile`
- **Quality check**: `mix quality` (format, compile warnings, dialyzer, credo)
- **Build local snapshot artifact**: `mix llm_db.build --install`
- **Pull upstream metadata**: `mix llm_db.pull`
- **Publish snapshot to GitHub Releases**: `mix llm_db.snapshot.publish`
- **Fetch published snapshot locally**: `mix llm_db.snapshot.fetch --ref latest --install`
- **Migrate reachable Git history (one-time)**: `mix llm_db.history.migrate_git --force`
- **Rebuild/publish history bundle**: `mix llm_db.history.rebuild --publish`
- **Sync published history bundle**: `mix llm_db.history.sync`
- **Check published history drift**: `mix llm_db.history.check --allow-missing`
- **Dependencies**: `mix deps.get`
- **Release**: `mix llm_db.version && mix git_ops.release && git push && git push --tags` (bumps to date-based version, updates CHANGELOG, tags, and pushes)

## Git Hooks

Hooks auto-install via `git_hooks` on `mix compile` in dev:

| Hook | Action |
|------|--------|
| **commit-msg** | Validates conventional commit format via `git_ops.check_message` |
| **pre-commit** | `mix format --check-formatted` |
| **pre-push** | `mix quality` |

Conventional commit types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

## Configuration

### Development/Test (default in dev.exs and test.exs)

```elixir
config :llm_db,
  compile_embed: false,     # Load from file at runtime
  integrity_policy: :warn   # Warn on hash mismatch instead of failing
```

With `:warn` policy, snapshot regeneration via `mix llm_db.build` triggers automatic recompilation on next `mix test` or `mix compile` - no need for manual `mix clean`.

### Production

Use compile-time embedded snapshot to eliminate runtime atom creation and file I/O:

```elixir
# config/prod.exs
config :llm_db,
  compile_embed: true,       # Embed snapshot at compile time
  integrity_policy: :strict, # Fail on any hash mismatch (default)
  filter: %{
    allow: :all,  # or restrict to specific providers
    deny: %{}
  }
```

## Architecture

- **Type**: Elixir library providing fast, persistent_term-backed LLM model metadata catalog
- **Core modules**: `LLMDB` (main API), `LLMDB.Engine` (ETL pipeline), `LLMDB.Store` (persistent_term storage)
- **Data structures**: `LLMDB.Provider`, `LLMDB.Model` with Zoi validation schemas in `lib/llm_db/schema/`
- **Storage**: O(1) lock-free queries via `:persistent_term`, packaged catalog snapshot in `priv/llm_db/snapshot.json`
- **ETL Pipeline**: Ingest → Normalize → Validate → Merge → Enrich → Filter → Index + Publish (7 stages)
- **Startup**: Catalog automatically loads on application start via `LLMDB.Application` (no manual `load()` needed in IEx or runtime)

## Code Style

- **Validation**: Use `Zoi.parse/2` for all schema validation and defaulting (not NimbleOptions or typed_struct)
- **Format**: Run `mix format` before committing (configured in .formatter.exs)
- **Naming**: Snake_case for functions/vars, PascalCase for modules, atoms for provider IDs (`:openai`, `:anthropic`)
- **Error handling**: Return `{:ok, result}` or `{:error, reason}` tuples, use `:error` atom for simple failures
- **Specs**: Provider IDs are atoms, model IDs are strings, spec format is `"provider:model"`
- **Tests**: Use `async: false` for tests that modify Store, `setup` blocks to clear state with `Store.clear!()`
- **Atom safety**: Use `String.to_existing_atom/1` for runtime conversions; `String.to_atom/1` only in build-time code (mix tasks, Engine normalization with `unsafe: true` flag)
