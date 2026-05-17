import Config

# Test configuration
config :llm_db,
  compile_embed: false,
  integrity_policy: :warn,
  skip_packaged_load: true,
  snapshot_path: "priv/llm_db/snapshot.json",
  # Use test-specific cache directory to avoid polluting production cache
  models_dev_cache_dir: "tmp/test/upstream",
  openrouter_cache_dir: "tmp/test/upstream",
  llmfit_cache_dir: "tmp/test/upstream",
  llmfit_enrichment: true,
  upstream_cache_dir: "tmp/test/upstream"
