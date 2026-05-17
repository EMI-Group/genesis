import Config

# LLM Models configuration
config :llm_db,
  # Default sources for loading model metadata (first = lowest precedence, last = highest)
  sources: [
    {LLMDB.Sources.ModelsDev, %{}},
    {LLMDB.Sources.OpenRouter, %{}},
    {LLMDB.Sources.OpenAI, %{}},
    {LLMDB.Sources.Anthropic, %{}},
    {LLMDB.Sources.Google, %{}},
    {LLMDB.Sources.XAI, %{}},
    {LLMDB.Sources.Zenmux, %{}},
    {LLMDB.Sources.Local, %{dir: "priv/llm_db/local"}}
  ],

  # Cache directory for remote sources
  models_dev_cache_dir: "priv/llm_db/upstream",
  openrouter_cache_dir: "priv/llm_db/upstream",
  llmfit_cache_dir: "priv/llm_db/upstream",
  upstream_cache_dir: "priv/llm_db/upstream",
  openai_cache_dir: "priv/llm_db/remote",
  anthropic_cache_dir: "priv/llm_db/remote",
  google_cache_dir: "priv/llm_db/remote",
  xai_cache_dir: "priv/llm_db/remote",
  zenmux_cache_dir: "priv/llm_db/remote",
  llmfit_enrichment: true,
  azure_foundry_cache_dir: "priv/llm_db/remote"

if Mix.env() == :dev do
  config :git_ops,
    mix_project: LLMDB.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/llm_db",
    manage_mix_version?: false,
    manage_readme_version: false,
    version_tag_prefix: "v"

  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "MIX_ENV=dev mix git_ops.check_message", include_hook_args: true}
        ]
      ],
      pre_commit: [
        tasks: [
          {:mix_task, :format, ["--check-formatted"]},
          {:cmd, "mix llm_db.build --check --install"}
        ]
      ],
      pre_push: [
        tasks: [
          {:mix_task, :test},
          {:mix_task, :quality}
        ]
      ]
    ]
end

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
