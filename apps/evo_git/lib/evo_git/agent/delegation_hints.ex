defmodule EvoGit.Agent.DelegationHints do
  @moduledoc """
  Delegation hinting logic extracted from `EvoGit.Agent.__using__/1`.

  Tracks how many write-tool and read-tool calls target child directories of the
  agent's assigned node. When the count exceeds configurable thresholds, a
  friendly nudge is appended to the tool output suggesting the agent spawn a
  subagent for that child directory instead of editing/reading files there
  directly.
  """

  # Write tools whose file paths should be tracked for delegation hints
  @write_tools_for_delegation ~w(write_file edit_file)
  # Read/investigation tools whose paths should be tracked for read delegation hints
  @read_tools_for_delegation ~w(read_file rg glob list_dir)

  # --- Threshold accessors ---

  def delegation_hint_threshold do
    EvoGit.Config.resolve([:scheduler, :delegation_hint_threshold])
  end

  def max_tool_timeout do
    EvoGit.Config.resolve([:scheduler, :max_tool_timeout])
  end

  def default_tool_timeout do
    EvoGit.Config.resolve([:scheduler, :default_tool_timeout])
  end

  # --- Write-tool child path extraction ---

  @doc false
  def extract_child_paths(tool_name, args, node_path, repo_path) do
    if tool_name in @write_tools_for_delegation do
      do_extract_child_paths(tool_name, args, node_path, repo_path)
    else
      []
    end
  end

  def do_extract_child_paths("create_files", args, node_path, repo_path) do
    case EvoGit.Agent.Tools.Shared.fetch_array_arg(args, "paths") do
      {:ok, paths} -> Enum.flat_map(paths, &path_to_child_dir(&1, node_path, repo_path))
      _ -> []
    end
  end

  def do_extract_child_paths("make_dir", args, node_path, repo_path) do
    case EvoGit.Agent.Tools.Shared.fetch_array_arg(args, "paths") do
      {:ok, paths} -> Enum.flat_map(paths, &path_to_child_dir(&1, node_path, repo_path))
      _ -> []
    end
  end

  def do_extract_child_paths(tool_name, args, node_path, repo_path)
      when tool_name in ~w(write_context edit_context) do
    case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "dir_path") do
      {:ok, dir_path} -> path_to_child_dir(dir_path, node_path, repo_path)
      _ -> []
    end
  end

  def do_extract_child_paths(_tool_name, args, node_path, repo_path) do
    # write_file, edit_file
    case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "file_path") do
      {:ok, file_path} -> file_path_to_child_dir(file_path, node_path, repo_path)
      _ -> []
    end
  end

  # For file paths: extract the directory and find the first child segment
  def file_path_to_child_dir(file_path, node_path, repo_path) do
    dir_path = Path.dirname(file_path)
    path_to_child_dir(dir_path, node_path, repo_path)
  end

  # For directory paths: find the first child directory segment under node_path
  def path_to_child_dir(dir_path, node_path, repo_path) do
    expanded = EvoGit.Agent.Tools.Shared.expand_path(dir_path, repo_path)
    relative = Path.relative_to(expanded, repo_path)
    normalized_target = EvoGit.Agent.Tools.Shared.normalize_relpath(relative)
    normalized_node = EvoGit.Agent.Tools.Shared.normalize_relpath(node_path)

    # An absolute or out-of-repo path (e.g. "/tmp/foo") has no meaningful
    # child directory to track for delegation hints — normalize_relpath
    # returns {:error, _} for such paths, so bail out gracefully instead of
    # crashing the hinting code (which runs in the main agent process).
    with normalized_target when is_binary(normalized_target) <- normalized_target,
         normalized_node when is_binary(normalized_node) <- normalized_node do
      # Only track strict children (not the node itself)
      if normalized_node == "./" do
        # Root node: extract first path segment as child
        extract_first_segment(normalized_target)
      else
        if EvoGit.Platform.path_under?(normalized_target, normalized_node) do
          # Extract the first segment under node_path
          remainder = String.replace_prefix(normalized_target, normalized_node <> "/", "")
          extract_first_segment_from_remainder(remainder, normalized_node)
        else
          []
        end
      end
    else
      _ -> []
    end
  end

  def extract_first_segment("./"), do: []

  def extract_first_segment(path) do
    # Remove leading "./" and take first segment
    stripped = String.replace_prefix(path, "./", "")

    case String.split(stripped, "/", parts: 2) do
      [first | _] when first != "" ->
        normalized = "./" <> first
        [normalized]

      _ ->
        []
    end
  end

  def extract_first_segment_from_remainder(remainder, node_path) do
    case String.split(remainder, "/", parts: 2) do
      [first | _] when first != "" ->
        [node_path <> "/" <> first]

      _ ->
        []
    end
  end

  def update_delegation_hints(hints, child_paths) do
    Enum.reduce(child_paths, hints, fn child_path, acc ->
      current = Map.get(acc, child_path, %{count: 0, hint_shown: false})
      Map.put(acc, child_path, %{current | count: current.count + 1})
    end)
  end

  # When the agent is resolving merge conflicts, it MUST edit files
  # directly (subagents start on clean commits and can't see conflict
  # markers).  Suppress delegation nudges so the agent isn't distracted.
  def filter_child_paths_if_conflicts(child_paths, []) do
    child_paths
  end

  def filter_child_paths_if_conflicts(_child_paths, _conflict_files) do
    []
  end

  def maybe_append_delegation_hint(output, hints, child_paths, threshold) do
    new_hints = update_delegation_hints(hints, child_paths)

    # Check if any child path has crossed the threshold for the first time
    hint =
      child_paths
      |> Enum.filter(fn child_path ->
        entry = Map.get(new_hints, child_path)
        entry && entry.count >= threshold && !entry.hint_shown
      end)
      |> Enum.map(fn child_path ->
        "💡 **Delegation Hint**: You've been editing files in `#{child_path}` for #{threshold}+ turns. " <>
          "Consider finishing your current changes, committing them, and then spawning a subagent at `#{child_path}` to continue the work. " <>
          "The subagent will run in its own isolated worktree on top of your committed changes and can handle the implementation autonomously."
      end)
      |> Enum.join("\n\n")

    {updated_output, updated_hints} =
      if hint != "" do
        # Mark these paths as hint-shown
        marked_hints =
          Enum.reduce(child_paths, new_hints, fn child_path, acc ->
            entry = Map.get(acc, child_path)

            if entry && entry.count >= threshold do
              Map.put(acc, child_path, %{entry | hint_shown: true})
            else
              acc
            end
          end)

        {output <> "\n\n" <> hint, marked_hints}
      else
        {output, new_hints}
      end

    {updated_output, updated_hints}
  end

  # --- Read-Tool Delegation Hinting ---
  # Tracks how many read-tool calls (read_file, rg, glob, list_dir) target
  # child directories of the agent's assigned node. When the count exceeds a
  # threshold, a friendly nudge is appended to the tool output suggesting the
  # agent delegate investigation to a subagent instead of reading files
  # directly. Only fires for high-level agents.

  def read_delegation_hint_threshold do
    EvoGit.Config.resolve([:scheduler, :read_delegation_hint_threshold])
  end

  @doc false
  def extract_read_child_paths(tool_name, args, node_path, repo_path) do
    if tool_name in @read_tools_for_delegation do
      do_extract_read_child_paths(tool_name, args, node_path, repo_path)
    else
      []
    end
  end

  def do_extract_read_child_paths("read_file", args, node_path, repo_path) do
    case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "file_path") do
      {:ok, file_path} -> file_path_to_child_dir(file_path, node_path, repo_path)
      _ -> []
    end
  end

  def do_extract_read_child_paths("list_dir", args, node_path, repo_path) do
    case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "dir_path") do
      {:ok, dir_path} -> path_to_child_dir(dir_path, node_path, repo_path)
      _ -> []
    end
  end

  def do_extract_read_child_paths(tool_name, args, node_path, repo_path)
      when tool_name in ~w(rg glob) do
    case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "path") do
      {:ok, path} -> path_to_child_dir(path, node_path, repo_path)
      _ -> []
    end
  end

  def update_read_delegation_hints(read_hints, child_paths) do
    Enum.reduce(child_paths, read_hints, fn child_path, acc ->
      current = Map.get(acc, child_path, %{count: 0, hint_shown: false})
      Map.put(acc, child_path, %{current | count: current.count + 1})
    end)
  end

  def maybe_append_read_delegation_hint(
        output,
        read_hints,
        child_paths,
        threshold,
        delegation_level
      ) do
    new_read_hints = update_read_delegation_hints(read_hints, child_paths)

    # Only emit read delegation hints for high-level agents
    {updated_output, updated_read_hints} =
      if delegation_level == :high do
        # Check if any child path has crossed the threshold for the first time
        hint =
          child_paths
          |> Enum.filter(fn child_path ->
            entry = Map.get(new_read_hints, child_path)
            entry && entry.count >= threshold && !entry.hint_shown
          end)
          |> Enum.map(fn child_path ->
            "💡 **Delegation Hint**: You've been reading/investigating files in `#{child_path}` for #{entry_count(new_read_hints, child_path)} turns. " <>
              "As a high-level agent, investigation of child subtrees should be delegated — spawn a `subagent_codebase_investigator` (or `subagent_manager`) at `#{child_path}` and let it investigate its own domain. " <>
              "Your turns are for routing decisions, coordination, and review — not deep investigation."
          end)
          |> Enum.join("\n\n")

        if hint != "" do
          # Mark these paths as hint-shown
          marked_read_hints =
            Enum.reduce(child_paths, new_read_hints, fn child_path, acc ->
              entry = Map.get(acc, child_path)

              if entry && entry.count >= threshold do
                Map.put(acc, child_path, %{entry | hint_shown: true})
              else
                acc
              end
            end)

          {output <> "\n\n" <> hint, marked_read_hints}
        else
          {output, new_read_hints}
        end
      else
        {output, new_read_hints}
      end

    {updated_output, updated_read_hints}
  end

  def entry_count(hints, child_path) do
    case Map.get(hints, child_path) do
      %{count: count} -> count
      _ -> 0
    end
  end
end
