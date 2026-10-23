defmodule EvoGit.Agent.DelegationHints do
  @moduledoc """
  Delegation hinting logic extracted from `EvoGit.Agent.__using__/1`.

  Tracks how many write-tool and read-tool calls target child directories of the
  agent's assigned node. When the count exceeds configurable thresholds, a
  friendly nudge is appended to the tool output suggesting the agent spawn a
  subagent for that child directory instead of editing/reading files there
  directly.

  ## Wrap boundary (BINARY-ONLY contract)

  This module is BINARY-ONLY: `maybe_append_delegation_hint/4` and
  `maybe_append_read_delegation_hint/6` take a string and return a string. They
  never receive or return a `%EvoGit.Agent.ToolOutput{}` — the wrap/unwrap
  between a binary and a `%ToolOutput{}` happens ONLY inside
  `EvoGit.Agent.ToolDispatch` (see `EvoGit.Agent.ToolOutput` → "Wrap boundary
  invariant"). `ToolDispatch.apply_tool_output_tracking/3` unwraps the text
  component (`ToolOutput.text/1`) before calling these hint appenders and
  re-attaches the extended text with `ToolOutput.with_text/2`, so any media a
  tool attached survives the nudge.
  """
  alias EvoGit.Agent.ToolNames
  alias EvoGit.Platform

  # Write tools whose file paths should be tracked for delegation hints. These
  # are INTERNAL dispatch keys: the incoming tool name is matched AFTER alias
  # normalisation (`EvoGit.Agent.ToolNames.normalize/1`), so the model-facing
  # names (`write`, `edit`) resolve to the entries here.
  @write_tools_for_delegation ~w(write_file edit_file)
  # Read/investigation tools whose paths should be tracked for read delegation
  # hints — likewise matched AFTER alias normalisation, so the model-facing
  # `read` resolves to `read_file` here.
  @read_tools_for_delegation ~w(read_file rg glob list_dir)

  # The subagent tool names the read hint may suggest. Which of them a nudge
  # actually names is decided per RECEIVING role (see `investigator_hint_names/1`)
  # — never hardcoded into the message text.
  @investigator_subagent_tool "subagent_investigator"
  @manager_subagent_tool "subagent_manager"
  @suggestable_subagent_tools [@investigator_subagent_tool, @manager_subagent_tool]
  # Shape of a per-child-path hint entry (shared by the write- and read-tool
  # hint families): `count` holds the number of tracked tool calls, `hint_shown`
  # gates the once-only emission of the delegation nudge.
  @type hint_entry :: %{count: non_neg_integer(), hint_shown: boolean()}
  @type hints :: %{optional(String.t()) => hint_entry()}

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
    # The dispatcher hands us the RAW tool-call name, which is the MODEL-FACING
    # schema name (`write`, `edit`, …). Normalise it to the internal dispatch
    # vocabulary the clause heads below are written in BEFORE the membership
    # test — otherwise the new names never match and no nudge ever fires.
    normalized = ToolNames.normalize(tool_name)

    if normalized in @write_tools_for_delegation do
      do_extract_child_paths(normalized, args, node_path, repo_path)
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
        # Only track STRICT children — editing files directly inside the
        # agent's own node is normal work, never delegation-worthy.
        if normalized_target != normalized_node and
             EvoGit.Platform.path_under?(normalized_target, normalized_node) do
          # Extract the first segment under node_path
          node_clean = Platform.trim_trailing_separators(normalized_node)
          remainder = String.replace_prefix(normalized_target, node_clean <> "/", "")

          remainder =
            if remainder == normalized_target do
              String.replace_prefix(normalized_target, node_clean <> "\\", "")
            else
              remainder
            end

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

    case Platform.split_path(stripped, parts: 2) do
      # A "." first segment (e.g. "./." — the node itself) is not a child
      [first | _] when first != "" and first != "." ->
        normalized = "./" <> first
        [normalized]

      _ ->
        []
    end
  end

  def extract_first_segment_from_remainder(remainder, node_path) do
    case Platform.split_path(remainder, parts: 2) do
      # A "." first segment means the remainder is the node itself — not a
      # child directory (defense-in-depth; the strict-child check in
      # path_to_child_dir/3 already excludes this case).
      [first | _] when first != "" and first != "." ->
        [node_path <> "/" <> first]

      _ ->
        []
    end
  end

  # --- Shared internal helpers (used by both write- and read-tool hint families) ---

  # Increments the delegation-hint counter for each child path in the hints
  # map. `counter_key` is the entry key holding the call count (`:count` for
  # both the write- and read-tool families); `hint_shown` is the once-only
  # emission flag.
  defp update_hints(hints, child_paths, counter_key) do
    Enum.reduce(child_paths, hints, fn child_path, acc ->
      current = Map.get(acc, child_path, %{counter_key => 0, hint_shown: false})
      Map.put(acc, child_path, Map.update!(current, counter_key, &(&1 + 1)))
    end)
  end

  # Shared hint-append pipeline: bumps the counters, collects the child paths
  # that crossed `threshold` for the first time, renders each via
  # `message_builder.(child_path, count, threshold)`, marks them hint-shown,
  # and appends the joined hint text to the output.
  defp maybe_append_hint(output, hints, child_paths, threshold, counter_key, message_builder) do
    new_hints = update_hints(hints, child_paths, counter_key)

    hint =
      child_paths
      |> Enum.filter(fn child_path ->
        entry = Map.get(new_hints, child_path)
        entry && Map.get(entry, counter_key) >= threshold && !entry.hint_shown
      end)
      |> Enum.map(fn child_path ->
        message_builder.(child_path, entry_count(new_hints, child_path), threshold)
      end)
      |> Enum.join("\n\n")

    if hint != "" do
      # Mark these paths as hint-shown
      marked_hints =
        Enum.reduce(child_paths, new_hints, fn child_path, acc ->
          entry = Map.get(acc, child_path)

          if entry && Map.get(entry, counter_key) >= threshold do
            Map.put(acc, child_path, %{entry | hint_shown: true})
          else
            acc
          end
        end)

      {output <> "\n\n" <> hint, marked_hints}
    else
      {output, new_hints}
    end
  end

  defp write_hint_message(child_path, _count, threshold) do
    "💡 **Delegation Hint**: You've been editing files in `#{child_path}` for #{threshold}+ turns. " <>
      "Consider finishing your current changes, committing them, and then spawning a subagent at `#{child_path}` to continue the work. " <>
      "The subagent will run in its own isolated worktree on top of your committed changes and can handle the implementation autonomously."
  end

  defp read_hint_message(child_path, count, _threshold, names) do
    "💡 **Delegation Hint**: You've been reading/investigating files in `#{child_path}` for #{count} turns. " <>
      "As a high-level agent, investigation of child subtrees should be delegated — spawn #{spawn_phrase(names)} at `#{child_path}` and let it investigate its own domain. " <>
      "Your turns are for routing decisions, coordination, and review — not deep investigation."
  end

  # Renders the subagent tool name(s) the hint suggests, in the historical
  # wording when both are available: "a `subagent_investigator` (or
  # `subagent_manager`)".
  defp spawn_phrase([investigator, manager])
       when investigator == @investigator_subagent_tool and manager == @manager_subagent_tool,
       do: "a `#{investigator}` (or `#{manager}`)"

  defp spawn_phrase([name]), do: "a `#{name}`"

  @doc """
  Increments the write-tool delegation hint counter for each child path.
  """
  @spec update_delegation_hints(hints(), [String.t()]) :: hints()
  def update_delegation_hints(hints, child_paths) do
    update_hints(hints, child_paths, :count)
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

  @doc """
  Appends a delegation nudge to `output` when a child directory's write-tool
  call count crosses `threshold` for the first time. Returns the updated output
  and hints map.
  """
  @spec maybe_append_delegation_hint(String.t(), hints(), [String.t()], pos_integer()) ::
          {String.t(), hints()}
  def maybe_append_delegation_hint(output, hints, child_paths, threshold) do
    maybe_append_hint(output, hints, child_paths, threshold, :count, &write_hint_message/3)
  end

  # --- Read-Tool Delegation Hinting ---
  # Tracks how many read-tool calls (internal dispatch keys `read_file`, `rg`,
  # `glob`, `list_dir` — the model-facing names `read`/`grep`/… are matched
  # after alias normalisation) target child directories of the agent's assigned
  # node. When the count exceeds a threshold, a friendly nudge is appended to
  # the tool output suggesting the agent delegate investigation to a subagent
  # instead of reading files directly. Only fires for high-level agents.

  def read_delegation_hint_threshold do
    EvoGit.Config.resolve([:scheduler, :read_delegation_hint_threshold])
  end

  @doc false
  def extract_read_child_paths(tool_name, args, node_path, repo_path) do
    # Normalise the RAW model-facing tool-call name to the internal dispatch
    # vocabulary first (see `extract_child_paths/4`), otherwise the model-facing
    # `read` never matches the `read_file` clause below.
    normalized = ToolNames.normalize(tool_name)

    if normalized in @read_tools_for_delegation do
      do_extract_read_child_paths(normalized, args, node_path, repo_path)
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

  @doc """
  Increments the read-tool delegation hint counter for each child path.
  """
  @spec update_read_delegation_hints(hints(), [String.t()]) :: hints()
  def update_read_delegation_hints(read_hints, child_paths) do
    update_hints(read_hints, child_paths, :count)
  end

  @doc """
  Appends an investigation delegation nudge to `output` when a child
  directory's read-tool call count crosses `threshold` for the first time.
  Only fires for high-level agents (`delegation_level == :high`). Returns the
  updated output and read-hints map.

  `agent_module` is the RECEIVING role: the nudge names only the subagent tools
  that role can actually spawn, resolved from its `subagent_modules/0` via each
  module's `subagent_tool_name/0` (see `investigator_hint_names/1`) — a role
  whose only subagent is the investigator is never pointed at
  `subagent_manager`. `nil` (unknown role: direct/unit-test callers) keeps the
  historical wording naming both. A role with neither tool gets NO hint, and
  the function is total — it never raises, whatever the role's subagent list
  looks like.
  """
  @spec maybe_append_read_delegation_hint(
          String.t(),
          hints(),
          [String.t()],
          pos_integer(),
          atom(),
          module() | nil
        ) ::
          {String.t(), hints()}
  def maybe_append_read_delegation_hint(
        output,
        read_hints,
        child_paths,
        threshold,
        delegation_level,
        agent_module \\ nil
      ) do
    names = investigator_hint_names(agent_module)

    if delegation_level == :high and names != [] do
      builder = fn child_path, count, thr -> read_hint_message(child_path, count, thr, names) end
      maybe_append_hint(output, read_hints, child_paths, threshold, :count, builder)
    else
      {output, read_hints}
    end
  end

  # The subagent tool names the nudge may suggest for `agent_module`, restricted
  # to what that role actually offers. Order is the suggestable order
  # (investigator first), so the multi-name wording stays stable.
  #
  # `nil` means "role unknown" (direct/unit-test callers) — keep the widest
  # historical wording. Any other non-module value degrades the same way.
  defp investigator_hint_names(nil), do: @suggestable_subagent_tools

  defp investigator_hint_names(agent_module) when is_atom(agent_module) do
    available = subagent_tool_names(agent_module)
    Enum.filter(@suggestable_subagent_tools, &(&1 in available))
  end

  defp investigator_hint_names(_agent_module), do: @suggestable_subagent_tools

  # Every model-facing subagent tool name the role exposes: its
  # `subagent_modules/0` mapped through each module's `subagent_tool_name/0`,
  # `nil` names dropped. Total by construction — a role without
  # `subagent_modules/0` and a listed module without `subagent_tool_name/0`
  # (or returning nil) both simply contribute nothing.
  defp subagent_tool_names(agent_module) do
    if Code.ensure_loaded?(agent_module) and
         function_exported?(agent_module, :subagent_modules, 0) do
      agent_module.subagent_modules()
      |> List.wrap()
      |> Enum.flat_map(&subagent_tool_name/1)
    else
      []
    end
  end

  defp subagent_tool_name(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :subagent_tool_name, 0) do
      List.wrap(module.subagent_tool_name())
    else
      []
    end
  end

  defp subagent_tool_name(_module), do: []

  @spec entry_count(hints(), String.t()) :: non_neg_integer()
  def entry_count(hints, child_path) do
    case Map.get(hints, child_path) do
      %{count: count} -> count
      _ -> 0
    end
  end
end
