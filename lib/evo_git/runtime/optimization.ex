defmodule EvoGit.Runtime.Optimization do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Agent
  alias EvoGit.Adapters.Git
  alias EvoGit.Adapters.Gemini
  require Logger

  def run(objective) do
    Logger.info("Optimization: Starting for objective: #{objective}")

    {:ok, current_sha} = Git.rev_parse(File.cwd!())

    # 1. Diagnosis
    # List all files to help identify context
    {:ok, file_tree} = Git.run(["ls-tree", "-r", "--name-only", current_sha], File.cwd!())

    diag_prompt =
      "Objective: #{objective}\n" <>
        "File Tree:\n#{file_tree}\n" <>
        "Identify the single most relevant directory or file path to modify.\n" <>
        "Return ONLY the path as a JSON string under key 'path'."

    # Diagnosis does not need context files, just the file tree string
    target_path =
      case Gemini.call(diag_prompt, [], nil, cd: File.cwd!()) do
        {:ok, %{"path" => path}} ->
          String.trim(path)

        {:ok, %{"response" => path}} ->
          String.trim(path)

        {:error, :json_decode_error, text} ->
          # Attempt to extract path from text (heuristic)
          # Often LLM returns "The path is `lib/foo`" or just "lib/foo"
          # We take the last line or just the text if it looks like a path
          text |> String.split() |> List.last() |> String.trim()

        _ ->
          "."
      end

    # Validate target path (simple check if it appears in file tree or is root)
    target_path =
      if target_path == "." or String.contains?(file_tree, target_path) do
        target_path
      else
        Logger.warning(
          "Optimization: Invalid target path '#{target_path}', falling back to root."
        )

        "."
      end

    Logger.info("Optimization: Diagnosed target path: #{target_path}")

    # 2. Dispatch (Single Agent)
    state = %{commit_sha: current_sha, node_path: target_path}

    case Agent.mutate(state, objective) do
      {:ok, new_state} ->
        Logger.info(
          "Optimization: Evolution successful. New commit: #{String.slice(new_state.commit_sha, 0, 7)}"
        )

        {:ok, new_state.commit_sha}

      error ->
        Logger.error("Optimization: Agent failed: #{inspect(error)}")
        error
    end
  end
end
