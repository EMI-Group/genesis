defmodule EvoGit.Runtime.Evolution.SeedFragments.Generators do
  @moduledoc """
  Fragment generator functions for built-in cross-domain code fragments.

  Each generator produces a `Fragment.t` containing 20–60 lines of idiomatic
  Elixir from a distinct domain. Also includes language inference utilities
  for user-provided seed files.

  The fragment implementations are delegated to domain-specific sub-modules
  under `EvoGit.Runtime.Evolution.SeedFragments.Generators`.
  """

  alias EvoGit.Runtime.Evolution.SeedFragments.Generators.{Applications, Algorithms, Systems, WebProtocols}

  # ===========================================================================
  # Delegates — one per domain
  # ===========================================================================

  defdelegate physics_fragment(), to: Applications
  defdelegate game_loop_fragment(), to: Applications
  defdelegate data_pipeline_fragment(), to: Applications

  defdelegate http_handler_fragment(), to: WebProtocols
  defdelegate encoding_fragment(), to: WebProtocols
  defdelegate middleware_fragment(), to: WebProtocols

  defdelegate graph_algorithm_fragment(), to: Algorithms
  defdelegate pattern_matching_fragment(), to: Algorithms
  defdelegate sorting_fragment(), to: Algorithms
  defdelegate tree_traversal_fragment(), to: Algorithms

  defdelegate process_pool_fragment(), to: Systems
  defdelegate stream_processing_fragment(), to: Systems
  defdelegate rate_limiter_fragment(), to: Systems
  defdelegate cache_ttl_fragment(), to: Systems
  defdelegate event_emitter_fragment(), to: Systems

  # ===========================================================================
  # Language inference
  # ===========================================================================

  def infer_language(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".py" -> "python"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".rs" -> "rust"
      ".go" -> "go"
      ".rb" -> "ruby"
      ".java" -> "java"
      ".kt" -> "kotlin"
      ".c" -> "c"
      ".cpp" -> "cpp"
      ".h" -> "c"
      ".hpp" -> "cpp"
      ".cs" -> "csharp"
      ".swift" -> "swift"
      ".scala" -> "scala"
      ".hs" -> "haskell"
      ".clj" -> "clojure"
      ".lua" -> "lua"
      ".php" -> "php"
      ".sh" -> "shell"
      ".sql" -> "sql"
      _ -> "unknown"
    end
  end
end
