import Config

System.put_env("GOOGLE_API_KEY", "AIzaSyAE86wFyYgxiCGVxrvJEYxUkpDRryaCXBU")
System.put_env("ZAI_API_KEY", "904e861ea44f47c1bdb2c64ec6be6c46.X8N67zkfi2c6nEvD")
# System.put_env("ZAI_API_KEY", "0c4ec19fe9314b8f97224d14c57fcab4.CnuoIMM6Gw8BxnHE")
System.put_env("DEEPSEEK_API_KEY", "sk-bdc90a24b5664572a177b60a91f93dc1")
System.put_env("GROQ_API_KEY", "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")
System.put_env("TAVILY_API_KEY", "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")

# config :evo_git,
#   max_concurrency: 5,
#   # llm_model: "zai_coding_plan:glm-5.1"
#   llm_model: %{provider: :deepseek, id: "deepseek-v4-pro"},
#   compression_threshold_tokens: 150_000

config :evo_git,
  max_concurrency: 5,
  llm_model: "zai_coding_plan:glm-5.1",
  compression_threshold_tokens: 150_000

# High-scale configuration
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      # More connections
      :default => [protocols: [:http1], size: 8, count: 8]
    }
  ]

config :evo_dash, EvoDashWeb.Endpoint, code_reloader: false
