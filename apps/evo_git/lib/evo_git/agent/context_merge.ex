defmodule EvoGit.Agent.ContextMerge do
  @moduledoc """
  Ownership-aware merge engine for a parent agent's subagent commits.

  A parent agent merges its subagents' same-repo commits. `CONTEXT.md`
  conflicts are frequent and usually spurious: e.g. the root spawns a manager
  at `./src` and one at `./doc`; the `./doc` manager spawns an investigator at
  `./src` which legitimately edits `./src/CONTEXT.md`. That commit lands in the
  `./doc` branch, so merging both branches conflicts on `./src/CONTEXT.md`
  even though one side (the `./src` owner) is clearly authoritative.

  This module resolves such conflicts deterministically **by node ownership**
  (see `file_node_path/1`, `ownership_strength/2` and `decide/3`):

  * strength `3` — the node path IS the file's directory (the owner);
  * strength `2` — the node path is a strict ancestor of the file's directory;
  * strength `1` — unrelated (including a node BELOW the file's directory).

  Only `CONTEXT.md` conflicts are ever auto-resolved. Any conflict in source
  code aborts and is reported. At the end of **every** path the worktree is
  clean (no merge in progress) — nothing is ever left half-resolved.

  The merge is attempted as one octopus merge first (the fast path) and falls
  back to merging children one at a time (spawn order) when that conflicts.
  """

  alias EvoGit.Adapters.Git
  alias EvoGit.Core.ContextNode

  @context_file "CONTEXT.md"
  @diff_max_chars 2000

  defmodule Report do
    @moduledoc """
    Outcome of `EvoGit.Agent.ContextMerge.merge_children/3`.
    """

    defstruct status: :clean,
              starting_sha: nil,
              head_sha: nil,
              merge_output: "",
              entries: [],
              auto_resolutions: [],
              dropped_edits: [],
              genuine_conflicts: [],
              error: nil

    @type status :: :clean | :no_changes | :conflict | :error

    @type entry :: %{
            index: non_neg_integer() | nil,
            commit_sha: String.t() | nil,
            branch: String.t() | nil,
            node_path: String.t(),
            agent_module: module() | nil,
            agent_type: String.t(),
            status: :merged | :auto_resolved | :conflict | :not_attempted
          }

    @type auto_resolution :: %{
            file: String.t(),
            direction: :theirs | :ours,
            child_node_path: String.t(),
            reason: atom()
          }

    @type dropped_edit :: %{file: String.t(), child_node_path: String.t(), diff: String.t()}

    @type genuine_conflict :: %{
            file: String.t(),
            theirs_node_path: String.t() | nil,
            ours_node_path: String.t() | nil,
            theirs_strength: 1 | 2 | 3,
            ours_strength: 1 | 2 | 3
          }

    @type t :: %__MODULE__{
            status: status(),
            starting_sha: String.t() | nil,
            head_sha: String.t() | nil,
            merge_output: String.t(),
            entries: [entry()],
            auto_resolutions: [auto_resolution()],
            dropped_edits: [dropped_edit()],
            genuine_conflicts: [genuine_conflict()],
            error: String.t() | nil
          }
  end

  @type child :: %{
          required(:index) => non_neg_integer(),
          required(:commit_sha) => String.t(),
          required(:branch) => String.t() | nil,
          required(:node_path) => String.t(),
          required(:agent_module) => module(),
          optional(:objective) => String.t() | nil,
          optional(:agent_type) => String.t()
        }

  # ---------------------------------------------------------------------------
  # Merge
  # ---------------------------------------------------------------------------

  @doc """
  Merges `children` (in spawn order) into `repo_path`'s current HEAD.

  Options:

    * `:parent_node_path` — the owning (parent) agent's node path, used as the
      "ours" side for CONTEXT.md ownership decisions. Defaults to `"./"`.
  """
  @spec merge_children(String.t(), [child()], keyword()) :: Report.t()
  def merge_children(repo_path, children, opts \\ [])

  def merge_children(repo_path, [], _opts) when is_binary(repo_path) do
    %Report{
      status: :no_changes,
      starting_sha: current_sha(repo_path),
      head_sha: short_sha(repo_path)
    }
  end

  def merge_children(repo_path, children, opts)
      when is_binary(repo_path) and is_list(children) and is_list(opts) do
    parent_node_path = normalize_node(Keyword.get(opts, :parent_node_path, "./"))
    starting_sha = current_sha(repo_path)

    # MUST be computed before any merge: HEAD moves as children are merged.
    changes = precompute_changes(repo_path, children)

    case fast_merge(repo_path, children) do
      {:ok, output} ->
        status = if current_sha(repo_path) == starting_sha, do: :no_changes, else: :clean

        %Report{
          status: status,
          starting_sha: starting_sha,
          head_sha: short_sha(repo_path),
          merge_output: output,
          entries: Enum.map(children, &entry(&1, :merged))
        }

      :conflict ->
        abort_merge(repo_path)
        sequential_merge(repo_path, children, changes, parent_node_path, starting_sha)

      {:error, message} ->
        %Report{
          status: :error,
          starting_sha: starting_sha,
          head_sha: short_sha(repo_path),
          entries: Enum.map(children, &entry(&1, :not_attempted)),
          error: message
        }
    end
  end

  # One child → plain merge; several → octopus merge.
  defp fast_merge(repo_path, children) do
    shas = Enum.map(children, &Map.get(&1, :commit_sha))

    if Enum.all?(shas, &is_binary/1) do
      result =
        case shas do
          [sha] -> Git.merge(repo_path, sha)
          _ -> Git.merge_octopus(repo_path, shas)
        end

      case result do
        {:ok, output} -> {:ok, output}
        {:error, {:conflict, _output}} -> :conflict
        {:error, {code, output}} -> {:error, fast_merge_error(code, output)}
      end
    else
      # A missing/invalid sha cannot be merged — let the sequential path report
      # it per child without touching the repository.
      :conflict
    end
  end

  defp fast_merge_error(code, output) do
    "git merge failed with exit code #{code}: #{output}"
  end

  # Precomputes, for every child, the set of files it changed since the merge
  # base with the CURRENT HEAD (the parent's starting commit) plus that base
  # sha (needed for the dropped-edit diff). Failures degrade to "no files".
  defp precompute_changes(repo_path, children) do
    Map.new(children, fn child -> {Map.get(child, :index), change_for(repo_path, child)} end)
  end

  defp change_for(repo_path, %{commit_sha: sha}) when is_binary(sha) do
    base =
      case Git.merge_base(repo_path, "HEAD", sha) do
        {:ok, base} -> base
        _ -> nil
      end

    files =
      case base do
        nil ->
          MapSet.new()

        base ->
          case Git.diff_name_only(repo_path, base, sha) do
            {:ok, files} -> MapSet.new(files)
            _ -> MapSet.new()
          end
      end

    %{base: base, files: files}
  end

  defp change_for(_repo_path, _child), do: %{base: nil, files: MapSet.new()}

  # ---------------------------------------------------------------------------
  # Sequential merge (fallback after the fast path conflicted)
  # ---------------------------------------------------------------------------

  defp sequential_merge(repo_path, children, changes, parent_node_path, starting_sha) do
    initial = %{
      entries: [],
      merge_output: [],
      auto_resolutions: [],
      dropped_edits: [],
      genuine_conflicts: [],
      merged: [],
      terminal: nil
    }

    state =
      Enum.reduce(children, initial, fn child, acc ->
        if acc.terminal do
          %{acc | entries: acc.entries ++ [entry(child, :not_attempted)]}
        else
          merge_one(repo_path, child, acc, changes, parent_node_path)
        end
      end)

    status =
      case state.terminal do
        {:error, _message} -> :error
        :conflict -> :conflict
        nil -> if current_sha(repo_path) == starting_sha, do: :no_changes, else: :clean
      end

    error =
      case state.terminal do
        {:error, message} -> message
        _ -> nil
      end

    %Report{
      status: status,
      starting_sha: starting_sha,
      head_sha: short_sha(repo_path),
      merge_output: Enum.join(state.merge_output, "\n"),
      entries: state.entries,
      auto_resolutions: state.auto_resolutions,
      dropped_edits: state.dropped_edits,
      genuine_conflicts: state.genuine_conflicts,
      error: error
    }
  end

  defp merge_one(repo_path, child, acc, changes, parent_node_path) do
    case Map.get(child, :commit_sha) do
      sha when is_binary(sha) ->
        case Git.merge(repo_path, sha) do
          {:ok, output} ->
            %{
              acc
              | entries: acc.entries ++ [entry(child, :merged)],
                merge_output: acc.merge_output ++ [output],
                merged: acc.merged ++ [child]
            }

          {:error, {:conflict, output}} ->
            handle_conflict(repo_path, child, acc, changes, parent_node_path, output)

          {:error, {code, output}} ->
            abort_merge(repo_path)

            %{
              acc
              | entries: acc.entries ++ [entry(child, :not_attempted)],
                terminal: {:error, child_merge_error(child, code, output)}
            }
        end

      _other ->
        %{
          acc
          | entries: acc.entries ++ [entry(child, :not_attempted)],
            terminal: {:error, "child #{inspect(Map.get(child, :index))} has no valid commit sha"}
        }
    end
  end

  defp child_merge_error(child, code, output) do
    "git merge of child #{inspect(Map.get(child, :index))} " <>
      "(#{text(Map.get(child, :commit_sha))}) failed with exit code #{code}: #{output}"
  end

  defp handle_conflict(repo_path, child, acc, changes, parent_node_path, output) do
    acc = %{acc | merge_output: acc.merge_output ++ [output]}
    {context_files, other_files} = split_conflict_files(conflict_files(repo_path))

    cond do
      other_files != [] ->
        # Genuine source-code conflict — never auto-resolve.
        conflicts =
          Enum.map(other_files, fn file ->
            conflict_record(
              file,
              child.node_path,
              ours_node_paths(file, acc, changes, parent_node_path)
            )
          end)

        abort_merge(repo_path)

        %{
          acc
          | entries: acc.entries ++ [entry(child, :conflict)],
            genuine_conflicts: acc.genuine_conflicts ++ conflicts,
            terminal: :conflict
        }

      context_files == [] ->
        # A conflict git did not report any unmerged file for — never guess.
        abort_merge(repo_path)
        %{acc | entries: acc.entries ++ [entry(child, :conflict)], terminal: :conflict}

      true ->
        resolve_context_files(repo_path, child, acc, changes, parent_node_path, context_files)
    end
  end

  defp split_conflict_files(files) do
    Enum.split_with(files, fn file -> Path.basename(file) == @context_file end)
  end

  defp resolve_context_files(repo_path, child, acc, changes, parent_node_path, context_files) do
    result =
      Enum.reduce_while(context_files, {:ok, [], []}, fn file, {:ok, resolutions, dropped} ->
        ours_paths = ours_node_paths(file, acc, changes, parent_node_path)

        case decide(file, child.node_path, ours_paths) do
          {:keep, direction, reason} ->
            case checkout_side(repo_path, direction, file) do
              :ok ->
                resolution = %{
                  file: file,
                  direction: direction,
                  child_node_path: child.node_path,
                  reason: reason
                }

                dropped =
                  if reason == :out_of_scope do
                    [
                      %{
                        file: file,
                        child_node_path: child.node_path,
                        diff: child_file_diff(repo_path, child, base_sha(changes, child), file)
                      }
                      | dropped
                    ]
                  else
                    dropped
                  end

                {:cont, {:ok, [resolution | resolutions], dropped}}

              {:error, message} ->
                {:halt, {:error, message}}
            end

          {:conflict, _kind, _reason} ->
            {:halt, {:owner_conflict, file, ours_paths}}
        end
      end)

    case result do
      {:ok, resolutions, dropped} ->
        finish_resolution(repo_path, child, acc, Enum.reverse(resolutions), Enum.reverse(dropped))

      {:owner_conflict, file, ours_paths} ->
        abort_merge(repo_path)
        conflict = conflict_record(file, child.node_path, ours_paths)

        %{
          acc
          | entries: acc.entries ++ [entry(child, :conflict)],
            genuine_conflicts: acc.genuine_conflicts ++ [conflict],
            terminal: :conflict
        }

      {:error, message} ->
        abort_merge(repo_path)

        %{
          acc
          | entries: acc.entries ++ [entry(child, :not_attempted)],
            terminal: {:error, message}
        }
    end
  end

  defp finish_resolution(repo_path, child, acc, resolutions, dropped) do
    files = Enum.map(resolutions, &Map.get(&1, :file))

    case stage_and_commit(repo_path, files) do
      :ok ->
        status = if resolutions == [], do: :merged, else: :auto_resolved

        %{
          acc
          | entries: acc.entries ++ [entry(child, status)],
            auto_resolutions: acc.auto_resolutions ++ resolutions,
            dropped_edits: acc.dropped_edits ++ dropped,
            merged: acc.merged ++ [child]
        }

      {:error, message} ->
        abort_merge(repo_path)

        %{
          acc
          | entries: acc.entries ++ [entry(child, :not_attempted)],
            terminal: {:error, message}
        }
    end
  end

  defp stage_and_commit(repo_path, files) do
    with :ok <- stage_files(repo_path, files) do
      commit_merge(repo_path)
    end
  end

  defp stage_files(repo_path, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case Git.add(repo_path, file) do
        {:ok, _output} ->
          {:cont, :ok}

        {:error, {code, output}} ->
          {:halt, {:error, "git add failed for #{file} (exit #{code}): #{output}"}}
      end
    end)
  end

  defp commit_merge(repo_path) do
    case Git.run(["commit", "--no-edit"], repo_path) do
      {:ok, _output} ->
        :ok

      {:error, {code, output}} ->
        {:error,
         "git commit --no-edit failed after resolving conflicts (exit #{code}): #{output}"}
    end
  end

  # The "ours" side: the parent's node + every child already merged into HEAD
  # that touched this file.
  defp ours_node_paths(file, acc, changes, parent_node_path) do
    from_children =
      acc.merged
      |> Enum.filter(fn child -> changed_file?(changes, child, file) end)
      |> Enum.map(&Map.get(&1, :node_path))

    [parent_node_path | from_children]
  end

  defp changed_file?(changes, child, file) do
    case Map.get(changes, Map.get(child, :index)) do
      %{files: %MapSet{} = files} -> MapSet.member?(files, file)
      _ -> false
    end
  end

  defp base_sha(changes, child) do
    case Map.get(changes, Map.get(child, :index)) do
      %{base: base} -> base
      _ -> nil
    end
  end

  defp conflict_record(file, theirs_node_path, ours_paths) do
    {ours_node_path, ours_strength} = best_owner(file, ours_paths)

    %{
      file: file,
      theirs_node_path: normalize_node(theirs_node_path),
      ours_node_path: ours_node_path,
      theirs_strength: ownership_strength(file, theirs_node_path),
      ours_strength: ours_strength
    }
  end

  defp best_owner(_file, []), do: {nil, 1}

  defp best_owner(file, paths) do
    paths
    |> Enum.map(fn path -> {normalize_node(path), ownership_strength(file, path)} end)
    |> Enum.max_by(fn {_node, strength} -> strength end, fn -> {nil, 1} end)
  end

  defp checkout_side(repo_path, :theirs, file), do: do_checkout(repo_path, "--theirs", file)
  defp checkout_side(repo_path, :ours, file), do: do_checkout(repo_path, "--ours", file)

  defp do_checkout(repo_path, flag, file) do
    case Git.run(["checkout", flag, "--", file], repo_path) do
      {:ok, _output} ->
        :ok

      {:error, {code, output}} ->
        {:error, "git checkout #{flag} failed for #{file} (exit #{code}): #{output}"}
    end
  end

  defp conflict_files(repo_path) do
    case Git.conflict_files(repo_path) do
      {:ok, files} -> files
      _ -> []
    end
  end

  # Best-effort: `git merge --abort` exits non-zero when no merge is in
  # progress (e.g. an octopus attempt that already rolled itself back).
  defp abort_merge(repo_path) do
    _ = Git.run(["merge", "--abort"], repo_path)
    :ok
  end

  defp current_sha(repo_path) do
    case Git.rev_parse(repo_path) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp short_sha(repo_path) do
    case Git.rev_parse_short(repo_path) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp child_file_diff(repo_path, child, base, file) do
    sha = Map.get(child, :commit_sha)

    if is_binary(base) and is_binary(sha) do
      case Git.run(["diff", base, sha, "--", file], repo_path) do
        {:ok, diff} -> truncate_diff(diff)
        _ -> ""
      end
    else
      ""
    end
  end

  defp truncate_diff(diff) do
    if String.length(diff) > @diff_max_chars do
      String.slice(diff, 0, @diff_max_chars) <> "\n… (truncated)"
    else
      diff
    end
  end

  defp entry(child, status) do
    %{
      index: Map.get(child, :index),
      commit_sha: Map.get(child, :commit_sha),
      branch: Map.get(child, :branch),
      node_path: normalize_node(Map.get(child, :node_path)),
      agent_module: Map.get(child, :agent_module),
      agent_type: agent_type_label(child),
      status: status
    }
  end

  defp agent_type_label(child) do
    case Map.get(child, :agent_type) || Map.get(child, :agent_module) do
      nil ->
        "unknown"

      label when is_binary(label) ->
        label

      module when is_atom(module) ->
        module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  # ---------------------------------------------------------------------------
  # Pure ownership rules
  # ---------------------------------------------------------------------------

  @doc """
  Maps a repo-relative file path to the node path that owns it (its directory).

  `"CONTEXT.md"` → `"./"`, `"src/CONTEXT.md"` → `"./src"`,
  `"src/a/b/CONTEXT.md"` → `"./src/a/b"`.
  """
  @spec file_node_path(String.t()) :: String.t()
  def file_node_path(file_path) when is_binary(file_path) do
    file_path
    |> EvoGit.Platform.normalize_separators()
    |> Path.dirname()
    |> normalize_node()
  end

  def file_node_path(_other), do: "./"

  @doc """
  Ownership strength of `node_path` over `file_path`.

  `3` = owner (same node dir), `2` = strict ancestor (segment-wise; `"./"`
  owns every non-root file), `1` = unrelated (including a node BELOW the
  file's directory).
  """
  @spec ownership_strength(String.t(), String.t()) :: 1 | 2 | 3
  def ownership_strength(file_path, node_path)
      when is_binary(file_path) and is_binary(node_path) do
    file_segments = segments(file_node_path(file_path))
    node_segments = segments(normalize_node(node_path))

    cond do
      node_segments == file_segments -> 3
      proper_prefix?(node_segments, file_segments) -> 2
      true -> 1
    end
  end

  def ownership_strength(_file_path, _node_path), do: 1

  @doc """
  Decides which side of a `CONTEXT.md` conflict wins.

  Returns `{:keep, :theirs | :ours, reason}` or
  `{:conflict, :unresolved, :same_ownership}` (a 3-tuple — match the first
  element). Total: never raises.
  """
  @spec decide(String.t(), String.t(), [String.t()]) ::
          {:keep, :theirs | :ours, atom()} | {:conflict, :unresolved, :same_ownership}
  def decide(file_path, theirs_node_path, ours_node_paths) do
    theirs = ownership_strength(file_path, theirs_node_path)
    ours = max_strength(file_path, ours_node_paths)

    cond do
      theirs == 1 -> {:keep, :ours, :out_of_scope}
      theirs > ours -> {:keep, :theirs, :deeper_owner}
      theirs < ours -> {:keep, :ours, :ancestor_owner}
      true -> {:conflict, :unresolved, :same_ownership}
    end
  end

  defp max_strength(file_path, ours_node_paths) do
    ours_node_paths
    |> List.wrap()
    |> Enum.map(fn node_path -> ownership_strength(file_path, node_path) end)
    |> Enum.max(fn -> 1 end)
  end

  # `"./"` → [], `"./src/a"` → ["src", "a"].
  defp segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reject(&(&1 in ["", "."]))
  end

  defp proper_prefix?(node_segments, file_segments) do
    length(node_segments) < length(file_segments) and
      Enum.take(file_segments, length(node_segments)) == node_segments
  end

  # `ContextNode.normalize_relpath/1` raises on absolute paths; this module
  # must never crash on a malformed node path, so degrade gracefully instead.
  defp normalize_node(path) when is_binary(path) do
    if EvoGit.Platform.absolute_path?(path) do
      path |> EvoGit.Platform.normalize_separators() |> fallback_normalize()
    else
      ContextNode.normalize_relpath(path)
    end
  end

  defp normalize_node(_other), do: "./"

  defp fallback_normalize(path) do
    normalized = EvoGit.Platform.trim_separators(path)

    cond do
      normalized in ["", "."] -> "./"
      String.starts_with?(normalized, "./") -> normalized
      true -> "./" <> normalized
    end
  end

  # ---------------------------------------------------------------------------
  # Note formatting
  # ---------------------------------------------------------------------------

  @doc """
  Formats the system note handed back to the parent agent's LLM context.

  Returns `nil` when there is nothing to report (`:no_changes`). Never raises,
  even on a partially populated report.
  """
  @spec format_note(Report.t(), String.t()) :: String.t() | nil
  def format_note(%Report{status: :no_changes}, _cross_repo_note), do: nil

  def format_note(%Report{status: :clean} = report, cross_repo_note) do
    base =
      "System Note: Successfully auto-merged changes from subagents." <>
        note_text(cross_repo_note) <>
        "\nMerge output:\n" <> text(report.merge_output)

    [
      base,
      resolution_lines(report.auto_resolutions),
      dropped_blocks(report.dropped_edits),
      branch_handling(report.status, report.entries)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def format_note(%Report{status: :conflict} = report, cross_repo_note) do
    head =
      "System Note: Auto-merging subagent changes hit conflicts. " <>
        "The merge was aborted; your worktree is clean at HEAD #{sha_text(report.head_sha)}." <>
        note_text(cross_repo_note)

    [
      head,
      child_lines(report.entries),
      conflict_lines(report.genuine_conflicts),
      resolution_lines(report.auto_resolutions),
      dropped_blocks(report.dropped_edits),
      next_steps(report.entries),
      branch_handling(report.status, report.entries)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def format_note(%Report{status: :error} = report, cross_repo_note) do
    head =
      "System Note: Failed to auto-merge subagent changes" <>
        error_text(report.error) <>
        note_text(cross_repo_note) <>
        "\nYour worktree is clean at HEAD #{sha_text(report.head_sha)}."

    [head, child_lines(report.entries), branch_handling(report.status, report.entries)]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  # Defensive: an unknown/partial status still yields a usable note.
  def format_note(%Report{} = report, cross_repo_note) do
    format_note(%{report | status: :error}, cross_repo_note)
  end

  def format_note(_other, _cross_repo_note), do: nil

  defp error_text(nil), do: ""
  defp error_text(""), do: ""

  defp error_text(message) do
    ": " <> text(message)
  end

  defp resolution_lines([]), do: nil

  defp resolution_lines(resolutions) do
    lines =
      Enum.map(resolutions, fn resolution ->
        "  - #{text(Map.get(resolution, :file))}: kept " <>
          "#{direction_label(Map.get(resolution, :direction))} " <>
          "(node #{text(Map.get(resolution, :child_node_path))}) — " <>
          reason_label(Map.get(resolution, :reason))
      end)

    "Auto-resolutions applied:\n" <> Enum.join(lines, "\n")
  end

  defp dropped_blocks([]), do: nil

  defp dropped_blocks(dropped_edits) do
    dropped_edits
    |> Enum.map(fn edit ->
      "Dropped out-of-scope edit (the child's version was NOT applied):\n" <>
        "  file: #{text(Map.get(edit, :file))}\n" <>
        "  child node: #{text(Map.get(edit, :child_node_path))}\n" <>
        "  diff:\n" <> text(Map.get(edit, :diff))
    end)
    |> Enum.join("\n")
  end

  defp child_lines([]), do: nil

  defp child_lines(entries) do
    "Subagent merge results:\n" <> Enum.map_join(entries, "\n", &child_line/1)
  end

  defp child_line(entry) do
    "  [#{inspect(Map.get(entry, :index))}] " <>
      "#{text(Map.get(entry, :node_path))} (#{text(Map.get(entry, :agent_type))}) " <>
      "branch #{branch_text(Map.get(entry, :branch))} " <>
      "commit #{text(Map.get(entry, :commit_sha))} — #{status_label(Map.get(entry, :status))}"
  end

  defp conflict_lines([]), do: nil

  defp conflict_lines(conflicts) do
    "Conflicting files:\n" <> Enum.map_join(conflicts, "\n", &conflict_line/1)
  end

  defp conflict_line(conflict) do
    theirs = Map.get(conflict, :theirs_node_path)
    ours = Map.get(conflict, :ours_node_path)
    theirs_strength = Map.get(conflict, :theirs_strength, 1)
    ours_strength = Map.get(conflict, :ours_strength, 1)

    "  - #{text(Map.get(conflict, :file))} — " <>
      "theirs: #{side_label(theirs, theirs_strength)}, " <>
      "ours: #{side_label(ours, ours_strength)} → #{verdict(theirs_strength, ours_strength)}"
  end

  defp side_label(nil, _strength), do: "none"

  defp side_label(node_path, 3), do: "#{text(node_path)} (owner, strength 3)"

  defp side_label(node_path, strength), do: "#{text(node_path)} (strength #{strength})"

  defp verdict(theirs_strength, ours_strength) when theirs_strength == ours_strength do
    "unresolved: both sides own this node"
  end

  defp verdict(theirs_strength, ours_strength) when theirs_strength > ours_strength,
    do: "unresolved: theirs owns it"

  defp verdict(_theirs_strength, _ours_strength), do: "unresolved: ours owns it"

  defp next_steps(entries) do
    pending =
      Enum.filter(entries, fn entry ->
        Map.get(entry, :status) in [:conflict, :not_attempted]
      end)

    merge_hints =
      case pending do
        [] ->
          "    1. No child commits remain to merge."

        _ ->
          "    1. Merge the remaining child commits one at a time, in spawn order:\n" <>
            Enum.map_join(pending, "\n", fn entry ->
              "       git merge #{text(Map.get(entry, :commit_sha))}"
            end) <>
            "\n       Inspect first with `git log --oneline HEAD..<sha>` and `git diff HEAD...<sha>`."
      end

    Enum.join(
      [
        "Next steps (resolve deliberately — nothing was left half-merged):",
        merge_hints,
        "    2. To give up on the remaining children, run `git merge --abort` after a conflicted attempt.",
        "    3. For a CONTEXT.md conflict, keep the owning node's version.",
        "       For a genuine same-node conflict (both sides own it), merge both sides deliberately —",
        "       retain the routing-table entries from both versions instead of dropping either."
      ],
      "\n"
    )
  end

  # The merge did NOT complete (`:conflict` / `:error`): every subagent branch is
  # preserved, whatever its entry status — never claim a branch was deleted here.
  defp branch_handling(status, entries) when status in [:conflict, :error] do
    preserved =
      entries
      |> Enum.filter(fn entry -> is_binary(Map.get(entry, :branch)) end)
      |> Enum.map(fn entry ->
        "#{Map.get(entry, :branch)} " <>
          "(node #{text(Map.get(entry, :node_path))}, " <>
          "#{status_label(Map.get(entry, :status))})"
      end)

    case preserved do
      [] ->
        "Branch handling:\n  Preserved: none."

      _ ->
        "Branch handling:\n" <>
          "  Preserved (NOT deleted — the merge did not complete, " <>
          "so every subagent branch is still available):\n" <>
          Enum.map_join(preserved, "\n", &("    - " <> &1)) <>
          "\n" <>
          "  Delete one yourself with `git branch -D <branch>` once you no longer need it."
    end
  end

  defp branch_handling(_status, entries) do
    preserved =
      entries
      |> Enum.filter(fn entry -> Map.get(entry, :status) in [:conflict, :not_attempted] end)
      |> Enum.filter(fn entry -> is_binary(Map.get(entry, :branch)) end)
      |> Enum.map(fn entry ->
        "#{Map.get(entry, :branch)} (node #{text(Map.get(entry, :node_path))})"
      end)

    merged_count =
      Enum.count(entries, fn entry -> Map.get(entry, :status) in [:merged, :auto_resolved] end)

    preserved_text =
      case preserved do
        [] ->
          "  Preserved: none."

        _ ->
          "  Preserved (NOT deleted — their work is still available):\n" <>
            Enum.map_join(preserved, "\n", &("    - " <> &1))
      end

    deleted_text =
      if merged_count > 0 do
        "  Branches of merged children were deleted (their changes are already in HEAD)."
      else
        "  No merged-child branches were deleted."
      end

    "Branch handling:\n" <> preserved_text <> "\n" <> deleted_text
  end

  defp direction_label(:theirs), do: "theirs"
  defp direction_label(:ours), do: "ours"
  defp direction_label(other), do: text(other)

  defp reason_label(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp reason_label(other), do: text(other)

  defp status_label(:merged), do: "merged"
  defp status_label(:auto_resolved), do: "auto-resolved"
  defp status_label(:conflict), do: "conflict"
  defp status_label(:not_attempted), do: "not attempted"
  defp status_label(other), do: inspect(other)

  defp branch_text(nil), do: "(no branch)"
  defp branch_text(branch), do: text(branch)

  defp sha_text(nil), do: "unknown"
  defp sha_text(sha), do: text(sha)

  defp note_text(note) when is_binary(note) and note != "", do: note
  defp note_text(_note), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)
end
