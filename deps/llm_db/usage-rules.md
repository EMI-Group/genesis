# LLM Models Usage Rules

This document defines how AI coding assistants should interact with the `llm_db` library.

## Core Principles

1. **Separation of Concerns**: Build-time operations (ETL pipeline, fetching) are completely separate from runtime operations (loading, querying)
2. **Explicit Over Implicit**: No automatic updates, no magic—everything is manual and predictable
3. **Stability First**: The packaged snapshot is stable and version-pinned; sources are optional overlays
4. **Performance**: All runtime queries are O(1) lock-free reads from `:persistent_term`
5. **Execution Metadata Lives Upstream**: Typed provider runtime and model execution metadata belong in `LLMDB`, not in downstream runtime heuristics

## Build-Time Operations

Build-time operations run during development/CI to prepare data. They do NOT run in production.

### Fetching Remote Data

```bash
# Fetch from models.dev and cache with HTTP metadata
mix llm_db.pull
```

**What it does:**
- Downloads upstream model metadata (Models.dev and OpenRouter currently)
- Caches to `priv/llm_db/upstream/models-dev-<hash>.json` and `priv/llm_db/upstream/openrouter-<hash>.json`
- Stores HTTP metadata (ETag, Last-Modified) in manifest file
- Generates `lib/llm_db/generated/valid_providers.ex` to prevent atom leaking

**When to use:**
- You need fresh model data from models.dev
- You want to update the upstream cache

**Never:**
- Call this in production code
- Assume it runs automatically

### Building the Snapshot

```bash
# Run ETL pipeline to process sources into snapshot.json
mix llm_db.build
```

**What it does:**
- Loads configured sources from application config
- Runs 7-stage ETL pipeline: Ingest → Normalize → Validate → Merge → Enrich → Filter → Index
- Writes output to `priv/llm_db/snapshot.json`

**When to use:**
- After pulling new upstream data
- After modifying local TOML files
- After changing configuration overrides

**Sources configuration** (in `config/config.exs`):

```elixir
config :llm_db,
  sources: [
    {LLMDB.Sources.ModelsDev, %{}},                    # From upstream cache
    {LLMDB.Sources.Local, %{dir: "priv/llm_db"}}      # From TOML files (highest precedence)
  ]
```

**Important:** The packaged snapshot is NOT a source—it's the final output that ships with the Hex package.

### Typed Runtime Metadata

Packaged providers and models can carry typed execution metadata:

- `LLMDB.Provider.runtime`
  - `base_url`
  - `auth`
  - `default_headers`
  - `default_query`
  - `config_schema`
  - `doc_url`
- `LLMDB.Model.execution`
  - `text`
  - `object`
  - `embed`
  - `image`
  - `transcription`
  - `speech`
  - `realtime`

These fields are the source of truth for executable support. Legacy fields such
as `base_url` and free-form `extra` metadata may still exist during migration,
but downstream runtimes should prefer the typed contract when it is present.

Snapshot builds should enrich these fields deterministically. If a packaged
provider or model cannot be executed safely, mark it `catalog_only: true`
instead of relying on downstream heuristics.

### Versioning and Release

```bash
# Update version to current date (YYYY.MM.DD)
mix llm_db.version

# Generate changelog and tag release
mix git_ops.release

# Push to trigger CI/CD
git push && git push --tags
```

**Versioning strategy:**
- Date-based: `YYYY.MM.DD` or `YYYY.MM.DD.N` for multiple releases per day
- Version comes from current date, NOT from snapshot timestamp
- `mix llm_db.version` updates `@version` in mix.exs

## Runtime Operations

Runtime operations happen when your application starts or when you manually reload.

### Loading the Catalog

```elixir
# Automatic on application start
# Loads packaged snapshot + optional runtime overrides

# Manual reload
:ok = LLMDB.reload()

# Check current epoch (increments on each load)
epoch = LLMDB.epoch()
```

**What happens:**
1. `LLMDB.Packaged.snapshot()` loads pre-built snapshot from `priv/llm_db/snapshot.json`
2. Normalizes provider IDs (string → atom)
3. Builds runtime indexes
4. Applies optional runtime overrides (filters, preferences)
5. Publishes to `:persistent_term` for lock-free access

**Important:** Runtime does NOT run the ETL pipeline or fetch remote data.

### Querying Providers

```elixir
# Get all providers as Provider structs
providers = LLMDB.providers()

# Get specific provider
{:ok, provider} = LLMDB.get_provider(:openai)
provider.name        #=> "OpenAI"
provider.base_url    #=> "https://api.openai.com"
provider.env         #=> ["OPENAI_API_KEY"]

# List provider IDs only
provider_ids = LLMDB.list_providers()
```

**Performance:** O(N) where N = number of providers (typically < 20)

### Querying Models

```elixir
# Get model by spec string (returns Model struct)
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")

# Or by provider and ID
{:ok, model} = LLMDB.get_model(:openai, "gpt-4o-mini")

# Access capabilities
model.capabilities.tools.enabled    #=> true
model.capabilities.json.native      #=> true
model.cost.input                    #=> 0.15
model.limits.context                #=> 128000

# List models for a provider (returns maps, not structs)
models = LLMDB.list_models(:openai)

# Filter by capabilities
models = LLMDB.list_models(:openai,
  require: [tools: true, json_native: true]
)
```

**Performance:**
- `model/1` and `get_model/2`: O(1) hash lookup
- `list_models/2`: O(M) where M = models for provider (typically < 50)

### Model Selection

```elixir
# Find best model matching requirements
{:ok, {provider, model_id}} = LLMDB.select(
  require: [chat: true, tools: true, json_native: true],
  prefer: [:openai, :anthropic]
)

# Select from specific provider
{:ok, {provider, model_id}} = LLMDB.select(
  require: [tools: true],
  scope: :openai
)

# Handle no match
case LLMDB.select(require: [impossible: true]) do
  {:ok, {provider, model_id}} -> # use model
  {:error, :no_match} -> # fallback
end
```

**Supported capability keys:**
- `:chat`, `:embeddings`, `:reasoning`
- `:tools`, `:tools_streaming`, `:tools_strict`, `:tools_parallel`
- `:json_native`, `:json_schema`, `:json_strict`
- `:streaming_text`, `:streaming_tool_calls`

### Checking Availability

```elixir
# Check if model passes allow/deny filters
true = LLMDB.allowed?({:openai, "gpt-4o-mini"})
true = LLMDB.allowed?("openai:gpt-4o-mini")
```

**Performance:** O(1) with pre-compiled regex patterns

## Configuration

### Runtime Configuration

```elixir
# config/config.exs
config :llm_db,
  # Embed snapshot at compile time (default: false)
  compile_embed: true,

  # Optional sources (overlay on top of packaged snapshot)
  sources: [
    {LLMDB.Sources.ModelsDev, %{}},
    {LLMDB.Sources.Local, %{dir: "priv/llm_db"}},
    {LLMDB.Sources.Config, %{overrides: %{...}}}
  ],

  # Global filters
  allow: %{
    openai: :all,
    anthropic: ["claude-3-*", "claude-4-*"]
  },
  deny: %{
    openai: ["*-preview"]
  },

  # Provider preference order
  prefer: [:openai, :anthropic, :google_vertex]
```

### Precedence Rules

**Loading precedence (lowest to highest):**
1. Packaged snapshot (always loaded)
2. Configured sources (optional, if specified)
3. Runtime overrides (if provided to `load/1`)

**Merging rules:**
- Maps: Deep merge (higher precedence wins per field)
- Lists (except `:aliases`): Last wins (replace, don't merge)
- `:aliases`: Union (merge and dedupe)
- Scalars: Higher precedence wins

**Filtering:**
- Deny always wins over allow
- Patterns compiled once at load time

## Data Structures

### Provider Struct

```elixir
%LLMDB.Provider{
  id: :openai,
  name: "OpenAI",
  base_url: "https://api.openai.com",
  env: ["OPENAI_API_KEY"],
  doc: "https://platform.openai.com/docs",
  extra: %{}  # Extension point
}
```

### Model Struct

```elixir
%LLMDB.Model{
  id: "gpt-4o-mini",
  provider: :openai,
  name: "GPT-4o mini",
  family: "gpt-4o",  # Derived from ID
  limits: %{context: 128000, output: 16384},
  cost: %{input: 0.15, output: 0.60},  # Per 1M tokens
  capabilities: %{
    chat: true,
    tools: %{enabled: true, streaming: true, strict: false, parallel: true},
    json: %{native: true, schema: true, strict: false},
    streaming: %{text: true, tool_calls: true}
  },
  modalities: %{input: [:text], output: [:text]},
  tags: ["fast", "efficient"],
  deprecated?: false,
  aliases: ["gpt-4-mini"],
  extra: %{}  # Extension point
}
```

## Common Patterns

### Get Model with Fallback

```elixir
case LLMDB.model("openai:gpt-4o-mini") do
  {:ok, model} -> model
  {:error, _} -> get_fallback_model()
end
```

### Select with Requirements

```elixir
{:ok, {provider, id}} = LLMDB.select(
  require: [tools: true, streaming_text: true],
  prefer: [:openai, :anthropic]
)

{:ok, model} = LLMDB.get_model(provider, id)
```

### Filter by Cost

```elixir
cheap_models =
  LLMDB.list_models(:openai)
  |> Enum.filter(fn model -> model.cost.input < 1.0 end)
```

### Check Capability

```elixir
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")

if model.capabilities.tools.enabled do
  # Use tools
end
```

## Anti-Patterns

### ❌ Don't Run Build Tasks in Production

```elixir
# NEVER do this
def refresh_models do
  System.cmd("mix", ["llm_db.pull"])
  System.cmd("mix", ["llm_db.build"])
  LLMDB.reload()
end
```

**Why:** Build tasks are for development/CI only. Production uses the packaged snapshot.

### ❌ Don't Assume Auto-Updates

```elixir
# WRONG - models don't auto-update
def get_latest_models do
  # This won't fetch new data
  LLMDB.providers()
end
```

**Why:** Updates are manual only. Use `mix llm_db.pull` + `mix llm_db.build` during development.

### ❌ Don't Bypass the Public API

```elixir
# WRONG - internal implementation details
:persistent_term.get(:llm_db_snapshot)
```

**Why:** Use the public API (`LLMDB.snapshot()`) for stability and forward compatibility.

### ❌ Don't Modify Structs Directly

```elixir
# WRONG - structs are read-only
model = %{model | cost: %{input: 0.0, output: 0.0}}
```

**Why:** Models are immutable. Use configuration overrides to customize data.

## Extension Points

### Custom Source

Implement `LLMDB.Source` behaviour:

```elixir
defmodule MyApp.CustomSource do
  @behaviour LLMDB.Source

  @impl true
  def load(_opts) do
    data = %{
      custom_provider: %{
        id: :custom_provider,
        name: "Custom Provider",
        models: [
          %{id: "model-1", name: "Custom Model"}
        ]
      }
    }

    {:ok, data}
  end
end
```

Configure in `config/config.exs`:

```elixir
config :llm_db,
  sources: [
    {LLMDB.Sources.ModelsDev, %{}},
    {MyApp.CustomSource, %{}}
  ]
```

### Custom Metadata

Use the `extra` field:

```elixir
# In source
%{
  id: "gpt-4o-mini",
  provider: :openai,
  extra: %{
    my_custom_tier: "premium",
    my_custom_region: "us-east-1"
  }
}

# At runtime
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")
model.extra.my_custom_tier  #=> "premium"
```

## Performance Characteristics

### Query Performance

- **Provider/model lookup**: O(1) hash lookup in `:persistent_term`
- **List providers**: O(N) where N = providers (typically < 20)
- **List models**: O(M) where M = models per provider (typically < 50)
- **Select**: O(P×M) but short-circuits on first match

### Memory Usage

- **Snapshot size**: ~50-200 KB (JSON)
- **In-memory size**: ~100-400 KB (parsed + indexes)
- **`:persistent_term`**: Shared across all processes, no copying

### Load Time

- **Compile-time embed**: ~0 ms load (in memory), +50-100 ms compile
- **Runtime load**: ~10-25 ms (file read + JSON decode + indexing)

## Testing

### Test with Specific Models

```elixir
test "works with GPT-4o mini" do
  {:ok, model} = LLMDB.model("openai:gpt-4o-mini")
  assert model.capabilities.tools.enabled
end
```

### Test Model Selection

```elixir
test "selects appropriate model" do
  {:ok, {provider, id}} = LLMDB.select(
    require: [tools: true],
    prefer: [:openai]
  )

  assert provider == :openai
end
```

### Test with Runtime Overrides

```elixir
test "respects deny filters" do
  :ok = LLMDB.load(deny: %{openai: :all})
  refute LLMDB.allowed?({:openai, "gpt-4o-mini"})
end
```

## Summary

**Build-time:** Pull → Build → Release
- `mix llm_db.pull` - Fetch and cache
- `mix llm_db.build` - Run ETL pipeline
- `mix llm_db.version && mix git_ops.release` - Version and release

**Runtime:** Load → Query
- Auto-loads packaged snapshot on app start
- O(1) queries via `:persistent_term`
- Optional runtime filtering/preferences

**Remember:**
- Build and runtime are separate
- Updates are manual, not automatic
- Packaged snapshot is stable and version-pinned
- Sources are optional overlays for development
