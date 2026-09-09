defmodule EvoGit.Agent.Tools.SpawnInvestigatorProbe do
  # Directories skipped everywhere by the bounded walk.
  @ignore_names ~w(.git .genesis _build deps node_modules .elixir_ls coverage)
  # CONTEXT.md files reported (cap).
  @max_context_files 30
  # Files scanned by the keyword scan (cap).
  @max_scan_files 300
  # Matching files reported (cap).
  @max_match_files 15
  # Bytes read per file during scans (prefix cap).
  @max_bytes_per_file 65_536
  # First N bytes used for the binary (NUL) sniff.
  @binary_probe_size 8192
  # Non-empty lines excerpted per CONTEXT.md file (cap).
  @max_context_lines 15
  # Excerpt character cap per line.
  @max_excerpt_chars 160
  # Top-level entries listed in the inventory (cap; counts are totals).
  @inventory_list_limit 40
  # Objective tokens dropped before keyword scanning.
  @stopwords ~w(a an the and or of in on for to with is are this that it its as at by from be was were do does not but can you your i we they he she me my us our them their will would should could have has had)

  @moduledoc """
  Deterministic, bounded, strictly read-only codebase investigation probe.

  `investigate/2` walks an arbitrary repository path with pure-Elixir
  filesystem reads only — no `git` subprocess, no writes (no `.genesis`
  creation, no worktree, no branch), no config mutation, no network — and
  returns a Markdown-ish report string covering:

  1. **Repository facts** — the absolute path, confirmation it is a git repo
     (a `.git` directory or a `gitdir:` pointer file), and the checked-out ref
     parsed from `.git/HEAD` (`ref: refs/heads/<branch>`; a detached HEAD shows
     the SHA).
  2. **CONTEXT.md chain** — the root `CONTEXT.md` plus descendant
     `CONTEXT.md` files found by a bounded walk, each with a short excerpt.
  3. **Top-level inventory** — dirs/files at the repo root (ignoring obvious
     noise dirs) with total counts.
  4. **Objective keyword scan** — meaningful terms extracted from the
     objective, matched case-insensitively against a bounded scan of repo
     files, reporting up to `#{@max_match_files}` matching files with the
     matched line excerpt + line number.

  Self-bound so a single call completes in well under a second on a normal
  repo: CONTEXT.md files capped at `#{@max_context_files}`, keyword scan capped
  at `#{@max_scan_files}` files / `#{@max_match_files}` matching files / first
  `#{@max_bytes_per_file}` bytes per file. The walk skips
  `#{Enum.join(@ignore_names, ", ")}`, and treats files whose first chunk
  contains a NUL byte as binary. Never raises — every step is guarded and an
  unexpected internal error is reported inline rather than crashing the
  caller.

  Used by the `SpawnInvestigator.spawn_investigator` command handler
  (`EvoGit.Agent.Tools.SpawnInvestigator`). Because the probe is strictly
  read-only — zero side effects on the target repo — the command can stay
  security level 1 (executes immediately, no user-approval gate).

  ## No LLM / no agent run

  The probe is deterministic pure Elixir: it does NOT spawn an
  `EvoGit.Agents.Investigator` subagent and makes no LLM calls. A full
  read-only Investigator agent run remains the documented future path (see the
  handler's moduledoc for the blocking constraints).
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Investigates `path` and returns the report as a String. Never raises: every
  step is guarded and unexpected internal errors are reported inline.
  """
  def investigate(path, objective) do
    if is_binary(path) and is_binary(objective) do
      do_investigate(Path.expand(path), objective)
    else
      "# Investigation report (bounded read-only probe)\n\n" <>
        "Investigation skipped: path and objective must both be strings " <>
        "(got path=#{inspect(path)}, objective=#{inspect(objective)})."
    end
  end

  # --- Top-level orchestration -------------------------------------------------

  defp do_investigate(expanded, objective) do
    parts =
      [
        attempt(fn -> repo_section(expanded) end),
        attempt(fn -> context_chain_section(expanded) end),
        attempt(fn -> inventory_section(expanded) end),
        attempt(fn -> keyword_section(expanded, objective) end)
      ]
      |> Enum.map(&render_attempt/1)

    Enum.join(parts, "\n\n") <> "\n\n" <> notes_section()
  rescue
    e ->
      "# Investigation report (bounded read-only probe)\n\n" <>
        "⚠ The probe failed unexpectedly: #{Exception.message(e)}"
  catch
    kind, reason ->
      "# Investigation report (bounded read-only probe)\n\n" <>
        "⚠ The probe failed unexpectedly: #{kind}: #{inspect(reason)}"
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, "internal error while building this section: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "internal error while building this section: #{kind}: #{inspect(reason)}"}
  end

  defp render_attempt({:ok, text}), do: text
  defp render_attempt({:error, note}), do: "⚠ #{note}"

  # --- 1. Repository facts -----------------------------------------------------

  defp repo_section(expanded) do
    {git?, head_content} = git_head_content(expanded)

    [
      "## Repository",
      "- Path: #{expanded}",
      "- Git repository: #{if git?, do: "yes", else: "no"}",
      "- Checked-out ref: #{format_head(head_content)}"
    ]
    |> Enum.join("\n")
  end

  # Returns {git_repo?, head_content}. Resolves a `.git` directory or a
  # `.git` gitdir-pointer file (git worktree). Pure filesystem reads.
  defp git_head_content(expanded) do
    git_path = Path.join(expanded, ".git")

    cond do
      File.dir?(git_path) ->
        {true, read_small_file(Path.join(git_path, "HEAD"))}

      File.regular?(git_path) ->
        case read_small_file(git_path) do
          {:ok, content} ->
            case resolve_gitdir(content, expanded) do
              {:ok, git_dir} ->
                {true, read_small_file(Path.join(git_dir, "HEAD"))}

              :error ->
                {true, {:error, :unreadable}}
            end

          :error ->
            {true, {:error, :unreadable}}
        end

      true ->
        {false, :none}
    end
  end

  # Parses the `gitdir: <path>` line of a `.git` pointer file (worktrees).
  # Relative gitdir paths are resolved against the repo root.
  defp resolve_gitdir(content, expanded) do
    case Regex.run(~r/^gitdir:\s*(.+)$/m, content, capture: :all_but_first) do
      [git_dir] ->
        resolved =
          if Path.type(git_dir) == :absolute do
            Path.expand(git_dir)
          else
            Path.expand(git_dir, expanded)
          end

        if File.dir?(resolved), do: {:ok, resolved}, else: :error

      _ ->
        :error
    end
  end

  defp format_head(:none), do: "n/a (not a git repository)"
  defp format_head({:error, :unreadable}), do: "unknown (could not read HEAD)"

  defp format_head({:ok, content}) do
    case String.trim(content) do
      "ref: " <> ref ->
        case String.split(ref, "/", parts: 3) do
          ["refs", "heads", branch] -> "#{branch} (#{ref})"
          _ -> ref
        end

      sha when byte_size(sha) >= 7 ->
        "detached HEAD at #{sha}"

      other ->
        Shared.truncate(other, @max_excerpt_chars)
    end
  end

  defp read_small_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> :error
    end
  end

  # --- 2. CONTEXT.md chain -----------------------------------------------------

  defp context_chain_section(expanded) do
    files =
      expanded
      |> collect_files(500, 300)
      |> Enum.filter(&(Path.basename(&1) == "CONTEXT.md"))
      |> Enum.sort()
      |> Enum.take(@max_context_files)

    lines =
      case files do
        [] ->
          ["No CONTEXT.md files found within the bounded walk (up to #{@max_context_files})."]

        _ ->
          Enum.map(files, fn rel ->
            excerpt =
              case read_prefix(Path.join(expanded, rel)) do
                {:ok, content} -> context_excerpt(content)
                :error -> "(could not read)"
              end

            "- #{rel}\n#{indent(excerpt, 4)}"
          end)
      end

    heading = "## CONTEXT.md chain (#{length(files)} found, capped at #{@max_context_files})"
    Enum.join([heading | lines], "\n")
  end

  # First `@max_context_lines` non-empty lines, each capped in length; notes
  # how many further non-empty lines were skipped.
  defp context_excerpt(content) do
    non_empty =
      content |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    shown =
      non_empty
      |> Enum.take(@max_context_lines)
      |> Enum.map(&Shared.truncate(&1, @max_excerpt_chars))

    case non_empty do
      lines when length(lines) > @max_context_lines ->
        Enum.join(shown, "\n") <>
          "\n… (#{length(lines) - @max_context_lines} more non-empty lines)"

      _ ->
        Enum.join(shown, "\n")
    end
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)
    text |> String.split("\n") |> Enum.map_join("\n", &(pad <> &1))
  end

  # --- 3. Top-level inventory --------------------------------------------------

  defp inventory_section(expanded) do
    case File.ls(expanded) do
      {:ok, entries} ->
        entries =
          entries
          |> Enum.reject(&(&1 in @ignore_names))
          |> Enum.sort()

        dirs = Enum.count(entries, &File.dir?(Path.join(expanded, &1)))
        files = length(entries) - dirs

        listed =
          entries
          |> Enum.take(@inventory_list_limit)
          |> Enum.map(fn entry ->
            full = Path.join(expanded, entry)
            kind = if File.dir?(full), do: "dir ", else: "file"
            "  - #{kind} #{entry}"
          end)

        heading =
          "## Top-level inventory (#{length(entries)} entries: #{dirs} directories, #{files} " <>
            "files, excluding #{Enum.join(@ignore_names, ", ")})"

        more =
          if length(entries) > @inventory_list_limit do
            ["  … and #{length(entries) - @inventory_list_limit} more entries"]
          else
            []
          end

        Enum.join([heading | listed] ++ more, "\n")

      {:error, reason} ->
        "## Top-level inventory\n\nCould not list directory: #{:file.format_error(reason)}"
    end
  end

  # --- 4. Objective keyword scan ------------------------------------------------

  defp keyword_section(expanded, objective) do
    keywords = extract_keywords(objective, expanded)
    objective_line = "Objective: #{inspect(String.trim(objective))}"

    if keywords == [] do
      Enum.join(
        [
          "## Objective keyword scan",
          objective_line,
          "Keywords: (none)",
          "No meaningful keywords could be extracted from the objective (stopwords and " <>
            "tokens shorter than 3 characters are dropped)."
        ],
        "\n"
      )
    else
      files =
        expanded
        |> collect_files(@max_scan_files, 300)
        |> Enum.sort()

      matches = scan_files(Path.expand(expanded), files, keywords)

      match_lines =
        case matches do
          [] ->
            ["No files matched the objective keywords."]

          _ ->
            ["Matches found in #{length(matches)} file(s):"] ++
              Enum.map(matches, fn {rel, line_no, excerpt, terms} ->
                "  - #{rel}:#{line_no} [#{Enum.join(terms, ", ")}] — #{excerpt}"
              end)
        end

      Enum.join(
        [
          "## Objective keyword scan",
          objective_line,
          "Keywords: #{Enum.join(keywords, ", ")}",
          "Files scanned: #{length(files)} (capped at #{@max_scan_files}, first " <>
            "#{@max_bytes_per_file} bytes per file, matching files capped at #{@max_match_files})"
        ] ++ match_lines,
        "\n"
      )
    end
  end

  # Extracts case-insensitive search terms from the objective: drops the
  # literal path (so "investigate /tmp/repo" does not scan for "/tmp/repo"
  # fragments), downcases, splits on non-alphanumerics, drops stopwords and
  # tokens shorter than 3 characters.
  defp extract_keywords(objective, expanded) do
    objective
    |> String.downcase()
    |> then(fn obj ->
      obj
      |> String.replace(String.downcase(expanded), " ")
      |> String.replace(String.downcase(Path.basename(expanded)), " ")
    end)
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.uniq()
  end

  # Scans files in sorted order, stopping after @max_match_files matches.
  # Returns [{relative_path, line_number, excerpt, matched_terms}].
  defp scan_files(root, files, keywords) do
    files
    |> Enum.reduce_while([], fn rel, acc ->
      if length(acc) >= @max_match_files do
        {:halt, acc}
      else
        case scan_file(root, rel, keywords) do
          nil -> {:cont, acc}
          match -> {:cont, [match | acc]}
        end
      end
    end)
    |> Enum.reverse()
  end

  defp scan_file(root, rel, keywords) do
    case read_prefix(Path.join(root, rel)) do
      {:ok, content} ->
        if binary_content?(content) do
          nil
        else
          case first_matching_line(content, keywords) do
            nil ->
              nil

            {line_no, line, terms} ->
              {rel, line_no, Shared.truncate(String.trim(line), @max_excerpt_chars), terms}
          end
        end

      :error ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp first_matching_line(content, keywords) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, idx} ->
      line_lower = String.downcase(line)

      case Enum.filter(keywords, &String.contains?(line_lower, &1)) do
        [] -> nil
        terms -> {idx, line, terms}
      end
    end)
  end

  # Reads up to @max_bytes_per_file from a file, :raw so invalid UTF-8 cannot
  # raise. Returns {:ok, binary} | :error.
  defp read_prefix(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.read(io, @max_bytes_per_file) do
            {:ok, data} -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, _} -> :error
          end
        after
          :file.close(io)
        end

      {:error, _} ->
        :error
    end
  end

  # A NUL byte within the first probe bytes marks the file as binary.
  defp binary_content?(content) do
    probe = binary_part(content, 0, min(byte_size(content), @binary_probe_size))
    :binary.match(probe, <<0>>) != :nomatch
  end

  # --- Bounded recursive walk ---------------------------------------------------

  # Collects regular-file relative paths under root, depth-first, skipping
  # @ignore_names entries and symlinked directories (cycle safety), stopping
  # after `file_cap` files or `dir_cap` visited directories.
  defp collect_files(root, file_cap, dir_cap) do
    {files, _dirs} = do_collect(root, "", file_cap, dir_cap, {[], 0})
    files
  end

  # Halts the walk once the file budget is exhausted.
  defp do_collect(_root, _rel, file_cap, _dir_cap, {acc, _dirs} = state)
       when length(acc) >= file_cap,
       do: state

  # Halts the walk once the directory budget is exhausted.
  defp do_collect(_root, _rel, _file_cap, dir_cap, {_acc, dirs} = state) when dirs >= dir_cap,
    do: state

  defp do_collect(root, rel, file_cap, dir_cap, state) do
    case File.ls(Path.join(root, rel)) do
      {:ok, entries} ->
        entries = Enum.sort(entries)

        Enum.reduce_while(entries, state, fn entry, {acc, dirs} = state ->
          cond do
            entry in @ignore_names ->
              {:cont, state}

            length(acc) >= file_cap ->
              {:halt, state}

            true ->
              entry_rel = if rel == "", do: entry, else: Path.join(rel, entry)
              full = Path.join(root, entry_rel)
              {type, symlink?} = entry_type(full)

              cond do
                type == :directory and not symlink? ->
                  {acc2, dirs2} =
                    do_collect(root, entry_rel, file_cap, dir_cap, {acc, dirs + 1})

                  {:cont, {acc2, dirs2}}

                type == :regular ->
                  {:cont, {[entry_rel | acc], dirs}}

                true ->
                  {:cont, state}
              end
          end
        end)

      {:error, _} ->
        state
    end
  end

  defp entry_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> {type, type == :symlink}
      {:error, _} -> {:error, false}
    end
  end

  # --- 5. Notes -----------------------------------------------------------------

  defp notes_section do
    """
    ## Notes

    - This report was produced by a deterministic, bounded, strictly READ-ONLY probe — no LLM, no subagent run, no writes to the target repository.
    - Limits applied: CONTEXT.md files capped at #{@max_context_files}; keyword scan capped at #{@max_scan_files} files, #{@max_match_files} matching files, first #{@max_bytes_per_file} bytes per file; top-level inventory lists at most #{@inventory_list_limit} entries.
    - Walk excludes: #{Enum.join(@ignore_names, ", ")}. Files whose first chunk contains a NUL byte are treated as binary and skipped.
    - Not covered: git history/remotes, submodule contents, network, uncommitted-diff analysis, and any content beyond the scanned prefix.
    """
    |> String.trim_trailing()
  end
end
