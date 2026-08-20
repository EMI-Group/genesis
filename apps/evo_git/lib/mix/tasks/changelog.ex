defmodule Mix.Tasks.Changelog do
  @moduledoc """
  Generate an AI-powered Keep-a-Changelog section for a new version.

  Collects the pull requests / merges in the commit history since the last git
  tag (or a custom range) by walking the first-parent line, summarizes each
  change with an LLM into a single user-facing line (map stage), then
  aggregates those lines into categorized changelog entries (reduce stage),
  and maintains `CHANGELOG.md` in Keep a Changelog format. A missing file is
  created with a `# Changelog` title, an intro line, and an empty
  `## [Unreleased]` section. An existing file gets the new `## [<version>]`
  section inserted right after the header — or replaced in place when a
  section for the same version already exists (re-runs are idempotent and
  never duplicate a section).

  ## Usage

      mix changelog <version> [--from <ref>] [--to <ref>] [--model <id>] [--file <path>]

  Options:

    * `--from <ref>` — range start. Defaults to the last tag via
      `git describe --tags --abbrev=0`; when no tag exists the full history
      is used.
    * `--to <ref>` — range end. Defaults to `HEAD`.
    * `--model <id>` — LLM model profile used for the summary. Defaults to
      `deepseek:deepseek-v4-flash`.
    * `--file <path>` — changelog file path. Defaults to `CHANGELOG.md` in
      the current directory.

  Collection is **PR/merge-aware**: the first-parent line of the range is
  walked (`git log --first-parent <from>..<to>`), and each merge commit (≥ 2
  parents) becomes one change whose commits are the branch commits it brought
  in (`git log --no-merges <merge>^1..<merge>` — `--no-merges` skips nested
  agent merges; GitHub-style single-commit merges yield exactly one commit).
  Non-merge commits on the first-parent line become single-commit changes.
  The merge message itself is never used as the signal. Version-bump commits
  (subjects matching `^Bump version to`) and obvious mechanical noise
  (`^Update mix hash`, `^Update CONTEXT.md`) are filtered from every change's
  commit list; a change left with no commits is dropped entirely.

  Summarization is **two-stage (map-reduce)**: stage 1 produces one concise
  user-facing summary line per change (one LLM call per change, taking that
  change's commits); stage 2 aggregates the per-change summaries into the
  final Keep-a-Changelog entries in a single LLM call. After writing the file
  the task interactively asks whether to commit it; if confirmed only the
  changelog file is staged and committed (never `git add -A`).

  ## Examples

      # Summarize everything since the last tag
      mix changelog 0.2.0

      # Explicit range
      mix changelog 0.2.0 --from v0.1.0 --to v0.2.0

  ## Test seam

  The pipeline is routed through three `Application.get_env(:evo_git, ...)`
  seams (repo-wide pattern, cf. `:peak_hours_now_fun`,
  `:remote_rpc_timeout`); each defaults to the real `ReqLLM` implementation
  and tests substitute deterministic stubs via `Application.put_env`:

    * `:changelog_summarizer` — the whole pipeline
      `(model, version, prs) -> {:ok, entries} | {:error, reason}` where
      `prs` is the PR list. Defaults to `__MODULE__.summarize_pipeline/3`.
    * `:changelog_pr_summarizer` — stage 1 (map), one call per PR
      `(model, version, pr) -> {:ok, summary :: String.t()} | {:error, reason}`
      where `pr = %{head_sha: String.t(), commits: [%{hash, subject, body}]}`.
      Defaults to `__MODULE__.summarize_pr_with_llm/3`.
    * `:changelog_aggregator` — stage 2 (reduce)
      `(model, version, summaries :: [String.t()]) -> {:ok, entries} | {:error, reason}`.
      Defaults to `__MODULE__.aggregate_with_llm/3`.

  `entries` is a list of `%{category, text}` maps (string- or atom-keyed);
  the aggregation schema/output stays exactly compatible with
  `normalize_entries/1` and `build_section/2`.
  """

  use Mix.Task

  @shortdoc "Generate an AI-powered changelog section from git history"

  @requirements ["app.config"]

  @model "deepseek:deepseek-v4-flash"
  @default_file "CHANGELOG.md"
  @record_sep "\x1e"
  @field_sep "\x1f"
  @version_bump_re ~r/^Bump version to/
  @mechanical_noise_re ~r/^(Update mix hash|Update CONTEXT\.md)/
  @categories ~w(Added Changed Fixed Removed Security Deprecated)

  @impl Mix.Task
  def run(args) do
    {opts, remaining, _invalid} =
      OptionParser.parse(args,
        switches: [from: :string, to: :string, model: :string, file: :string]
      )

    case remaining do
      [version | _] ->
        Application.ensure_all_started(:req_llm)
        execute(version, opts)

      [] ->
        Mix.shell().error(
          "Usage: mix changelog <version> [--from <ref>] [--to <ref>] [--model <id>] [--file <path>]"
        )
    end
  end

  # --- Main flow -----------------------------------------------------------

  defp execute(version, opts) do
    file = opts[:file] || @default_file
    model = opts[:model] || @model

    case collect_prs(opts[:from], opts[:to]) do
      {:ok, []} ->
        Mix.shell().info("No commits found in the given range — nothing to summarize.")

      {:ok, prs} ->
        total_commits = Enum.sum(Enum.map(prs, &length(&1.commits)))

        Mix.shell().info(
          "Found #{total_commits} commit(s) in #{length(prs)} change(s) — generating changelog for v#{version}..."
        )

        case summarize(model, version, prs) do
          {:ok, entries} ->
            section = build_section(version, entries)
            content = upsert_changelog(file, version, section)
            File.write!(file, content)
            Mix.shell().info("✓ Changelog updated in #{file}")
            print_summary(version, entries)
            maybe_commit_changelog(file, version)

          {:error, reason} ->
            Mix.shell().error("Changelog generation failed — #{file} was NOT modified.")
            Mix.shell().error("LLM error: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to read git history: #{inspect(reason)}")
    end
  end

  # --- PR collection -------------------------------------------------------

  # Walks the first-parent line of the range (git log --first-parent
  # <from>..<to>; full history when there is no tag) and groups it into
  # PR-shaped changes. Returns {:ok, prs} where prs is a list of
  # %{head_sha: String.t(), commits: [%{hash, subject, body}]} in
  # newest-first order, or {:error, {:git_log_failed, code, output}}.
  defp collect_prs(from, to) do
    to_ref = to || "HEAD"

    from_ref =
      case from do
        nil -> last_tag()
        ref -> ref
      end

    range =
      case from_ref do
        nil -> to_ref
        ref -> "#{ref}..#{to_ref}"
      end

    case git_log_first_parent(range) do
      {:ok, entries} -> build_prs(entries)
      {:error, code, output} -> {:error, {:git_log_failed, code, output}}
    end
  end

  defp last_tag do
    case git(["describe", "--tags", "--abbrev=0"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          tag -> tag
        end

      {:error, _code, _output} ->
        nil
    end
  end

  # git log --first-parent over the range, including merge commits so the
  # mainline walk is PR-shaped. Each record carries hash, parents (space-
  # separated full SHAs), subject, and body. Records are trimmed per edge:
  # git joins each record with a newline (`rec1\x1e\nrec2\x1e\n`), so
  # `trim: true` on the split alone leaves a leading `\n` on every record
  # after the first — which would corrupt hashes and break `<sha>^1..<sha>`
  # ranges built from them.
  defp git_log_first_parent(range) do
    format = "%H%x1f%P%x1f%s%x1f%b%x1e"

    case git(["log", "--first-parent", "--pretty=format:#{format}", range]) do
      {:ok, output} ->
        entries =
          output
          |> String.split(@record_sep)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_first_parent_record/1)

        {:ok, entries}

      {:error, code, output} ->
        {:error, code, output}
    end
  end

  # The branch commits a merge brought in: git log --no-merges <merge>^1..<merge>.
  # --no-merges skips nested agent merges; a GitHub-style single-commit merge
  # yields exactly one commit. Records are trimmed per edge for the same
  # inter-record-newline reason as git_log_first_parent/1 (a leading `\n` on a
  # hash would make the `<hash>^1..<hash>` range passed in here ambiguous).
  defp git_log_no_merges(range) do
    format = "%H%x1f%s%x1f%b%x1e"

    case git(["log", "--no-merges", "--pretty=format:#{format}", range]) do
      {:ok, output} ->
        commits =
          output
          |> String.split(@record_sep)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_record/1)

        {:ok, commits}

      {:error, code, output} ->
        {:error, code, output}
    end
  end

  defp build_prs(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case pr_for_entry(entry) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, pr} -> {:cont, {:ok, [pr | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prs} -> {:ok, Enum.reverse(prs)}
      other -> other
    end
  end

  # A merge commit (≥ 2 parents) is one PR whose commits are exactly the
  # branch commits it brought in — the merge's own subject/body are noise and
  # never feed the signal.
  defp pr_for_entry(%{parents: parents, hash: hash}) when length(parents) >= 2 do
    case git_log_no_merges("#{hash}^1..#{hash}") do
      {:ok, commits} -> pr_or_nil(hash, commits)
      {:error, code, output} -> {:error, {:git_log_failed, code, output}}
    end
  end

  # A non-merge (or root) commit on the first-parent line is a single-commit PR.
  defp pr_for_entry(entry) do
    pr_or_nil(entry.hash, [%{hash: entry.hash, subject: entry.subject, body: entry.body}])
  end

  defp pr_or_nil(head_sha, commits) do
    commits = Enum.reject(commits, &noise_commit?/1)

    if commits == [] do
      {:ok, nil}
    else
      {:ok, %{head_sha: head_sha, commits: commits}}
    end
  end

  defp noise_commit?(commit) do
    Regex.match?(@version_bump_re, commit.subject) or
      Regex.match?(@mechanical_noise_re, commit.subject)
  end

  # Splits one first-parent git-log record (%H%x1f%P%x1f%s%x1f%b%x1e) into
  # {hash, parents, subject, body}. Bodies may contain newlines; fields
  # beyond the first three \x1f separators belong to the body.
  defp parse_first_parent_record(record) do
    case String.split(record, @field_sep, parts: 4) do
      [hash, parents, subject, body] ->
        [%{hash: hash, parents: parse_parents(parents), subject: subject, body: body}]

      [hash, parents, subject] ->
        [%{hash: hash, parents: parse_parents(parents), subject: subject, body: ""}]

      _ ->
        []
    end
  end

  defp parse_parents(""), do: []
  defp parse_parents(parents), do: String.split(parents, " ")

  # Splits one git-log record (already split on the \x1e record separator)
  # into {hash, subject, body} fields. Bodies may contain newlines; fields
  # beyond the first two \x1f separators belong to the body.
  defp parse_record(record) do
    case String.split(record, @field_sep, parts: 3) do
      [hash, subject, body] -> [%{hash: hash, subject: subject, body: body}]
      [hash, subject] -> [%{hash: hash, subject: subject, body: ""}]
      _ -> []
    end
  end

  # --- LLM summarization (two-stage map-reduce) ----------------------------

  # Whole-pipeline seam. Routes through the :changelog_summarizer
  # application-env seam so tests (and Mix.Tasks.Bump.Version's changelog
  # integration) can substitute a deterministic stub (repo-wide pattern, cf.
  # :peak_hours_now_fun, :remote_rpc_timeout). Contract:
  # (model, version, prs) -> {:ok, entries} | {:error, reason}.
  defp summarize(model, version, prs) do
    summarizer =
      Application.get_env(:evo_git, :changelog_summarizer, &__MODULE__.summarize_pipeline/3)

    summarizer.(model, version, prs)
  end

  @doc false
  # The real pipeline: stage 1 maps each PR to one summary line, stage 2
  # reduces the summaries into the final categorized entries.
  def summarize_pipeline(model, version, prs) do
    with {:ok, summaries} <- summarize_prs(model, version, prs) do
      aggregate(model, version, summaries)
    end
  end

  # Stage 1 (map) seam: one call per PR, returning a single concise
  # user-facing summary line for that PR.
  defp summarize_prs(model, version, prs) do
    summarizer =
      Application.get_env(
        :evo_git,
        :changelog_pr_summarizer,
        &__MODULE__.summarize_pr_with_llm/3
      )

    Enum.reduce_while(prs, {:ok, []}, fn pr, {:ok, acc} ->
      case summarizer.(model, version, pr) do
        {:ok, summary} when is_binary(summary) ->
          {:cont, {:ok, acc ++ [String.trim(summary)]}}

        {:ok, _other} ->
          {:halt, {:error, {:invalid_pr_summary, pr.head_sha}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  # Real stage-1 implementation: one LLM call per PR, taking that PR's
  # commits and returning a single summary line.
  def summarize_pr_with_llm(model, version, pr) do
    prompt = build_pr_prompt(version, pr)

    schema = [
      summary: [type: :string, required: true]
    ]

    opts = [
      max_tokens: 10_000,
      provider_options: [thinking: %{type: "disabled"}]
    ]

    case ReqLLM.stream_object(model, prompt, schema, opts) do
      {:ok, stream_resp} ->
        case ReqLLM.StreamResponse.process_stream(stream_resp) do
          {:ok, response} ->
            parsed = ReqLLM.Response.object(response)

            case parsed["summary"] do
              summary when is_binary(summary) -> {:ok, String.trim(summary)}
              _ -> {:error, {:missing_summary, parsed}}
            end

          {:error, reason} ->
            {:error, {:stream_error, reason}}
        end

      {:error, error} ->
        {:error, {:llm_error, error}}
    end
  end

  # Stage 2 (reduce) seam: one LLM call over the per-PR summaries, producing
  # the final entries in the existing {category, text} shape.
  defp aggregate(model, version, summaries) do
    aggregator =
      Application.get_env(:evo_git, :changelog_aggregator, &__MODULE__.aggregate_with_llm/3)

    aggregator.(model, version, summaries)
  end

  @doc false
  # Real stage-2 implementation: reduces the per-PR summary lines into the
  # final categorized entries (same schema + normalize_entries/1 path as the
  # old flat prompt).
  def aggregate_with_llm(model, version, summaries) do
    prompt = build_aggregate_prompt(version, summaries)

    schema = [
      entries: [
        type:
          {:list,
           {:map,
            [
              category: [type: :string, required: true],
              text: [type: :string, required: true]
            ]}},
        required: true
      ]
    ]

    opts = [
      max_tokens: 10_000,
      provider_options: [thinking: %{type: "disabled"}]
    ]

    case ReqLLM.stream_object(model, prompt, schema, opts) do
      {:ok, stream_resp} ->
        case ReqLLM.StreamResponse.process_stream(stream_resp) do
          {:ok, response} ->
            parsed = ReqLLM.Response.object(response)
            entries = parsed["entries"] || []
            {:ok, normalize_entries(entries)}

          {:error, reason} ->
            {:error, {:stream_error, reason}}
        end

      {:error, error} ->
        {:error, {:llm_error, error}}
    end
  end

  # Stage-1 prompt: one PR's commits -> one concise user-facing summary line.
  # Nested per-commit grouping happens inside this call (a PR that "fixes the
  # same bug twice" collapses to one summary).
  defp build_pr_prompt(version, pr) do
    commit_lines = format_commit_lines(pr.commits)

    """
    You are writing release notes for version #{version} of this software project.

    Below are the commits belonging to ONE pull request / merge included in
    this release (hash, subject, and optional body). Write a SINGLE concise,
    user-facing summary line describing what this change does, as it would
    appear in a changelog entry.

    Rules:
    - The summary is ONE short user-facing sentence fragment (no commit
      hashes, author names, or file paths).
    - Merge related commits into a single summary — a change that fixes the
      same bug twice collapses to one summary line.

    Commits in this change:
    #{commit_lines}
    """
  end

  # Stage-2 prompt: per-PR summaries -> categorized Keep-a-Changelog entries.
  defp build_aggregate_prompt(version, summaries) do
    summary_lines = Enum.map_join(summaries, "\n", &"- #{&1}")

    """
    You are writing release notes for version #{version} of this software project.

    Below are the per-change summaries of the pull requests / merges included
    in this release (each line is one change). Write a concise, user-facing
    changelog in Keep a Changelog style, grouped into the categories below.
    Include ONLY categories that have entries.

    Categories (use exactly these names):
    Added, Changed, Fixed, Removed, Security, Deprecated

    Rules:
    - Each entry is a short user-facing sentence fragment (no commit hashes,
      author names, or file paths).
    - Merge related changes into single entries.
    - Ignore mechanical/trivial changes (chore, formatting, dependency churn,
      pure refactors with no user impact) unless they are meaningful.

    Changes:
    #{summary_lines}
    """
  end

  defp format_commit_lines(commits) do
    Enum.map_join(commits, "\n", fn c ->
      base = "  #{c.hash} #{c.subject}"

      if c.body == "" do
        base
      else
        base <> "\n    " <> String.replace(c.body, "\n", "\n    ")
      end
    end)
  end

  # Normalizes the LLM's raw entries (string-keyed maps, free-form category
  # names) into canonical %{category, text} maps with a known category name.
  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry ->
      %{category: entry_category(entry), text: entry_text(entry)}
    end)
    |> Enum.filter(&(&1.category != nil and &1.text != ""))
  end

  defp normalize_entries(_), do: []

  defp entry_category(entry) do
    case Map.get(entry, "category") || Map.get(entry, :category) do
      nil -> nil
      cat when is_binary(cat) -> normalize_category(cat)
      _ -> nil
    end
  end

  defp entry_text(entry) do
    case Map.get(entry, "text") || Map.get(entry, :text) do
      text when is_binary(text) -> String.trim(text)
      _ -> ""
    end
  end

  defp normalize_category(cat) do
    case String.downcase(String.trim(cat)) do
      "added" -> "Added"
      "changed" -> "Changed"
      "fixed" -> "Fixed"
      "removed" -> "Removed"
      "security" -> "Security"
      "deprecated" -> "Deprecated"
      _ -> nil
    end
  end

  # --- CHANGELOG.md maintenance --------------------------------------------

  defp upsert_changelog(file, version, section) do
    if File.exists?(file) do
      file
      |> File.read!()
      |> upsert_section(version, section)
    else
      create_new_file(section)
    end
  end

  defp create_new_file(section) do
    """
    # Changelog

    All notable changes to this project will be documented in this file.

    ## [Unreleased]

    #{section}
    """
  end

  # Inserts the new section, or replaces the existing same-version section in
  # place so re-runs never duplicate it.
  defp upsert_section(content, version, section) do
    lines = String.split(content, "\n")
    section_lines = String.split(section, "\n")

    case find_section_range(lines, version) do
      :not_found ->
        insert_before_first_heading(lines, section_lines)

      {start_idx, end_idx} ->
        prefix = Enum.take(lines, start_idx)
        suffix = Enum.drop(lines, end_idx)
        join_with_blank_seams(prefix, section_lines, suffix)
    end
  end

  # Returns {start_line, end_line} (end exclusive) for the `## [<version>]`
  # section, or :not_found. The section runs from its header up to (not
  # including) the next `## ` heading, or to the end of the file.
  defp find_section_range(lines, version) do
    header_re = ~r/^## \[#{Regex.escape(version)}\]/

    case Enum.find_index(lines, &Regex.match?(header_re, &1)) do
      nil ->
        :not_found

      start_idx ->
        end_idx =
          lines
          |> Enum.drop(start_idx + 1)
          |> Enum.find_index(&String.starts_with?(&1, "## "))

        {start_idx, if(end_idx, do: start_idx + 1 + end_idx, else: length(lines))}
    end
  end

  # New sections go right after the header (after the `# Changelog` title and
  # any intro paragraph), before the first existing `## ` section.
  defp insert_before_first_heading(lines, section_lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, "## ")) do
      nil ->
        join_with_blank_seams(lines, section_lines, [])

      idx ->
        prefix = Enum.take(lines, idx)
        suffix = Enum.drop(lines, idx)
        join_with_blank_seams(prefix, section_lines, suffix)
    end
  end

  # Joins three line lists, guaranteeing a single blank line between a
  # non-empty prefix and the section, and between the section and a following
  # `## ` heading.
  defp join_with_blank_seams(prefix, section_lines, suffix) do
    prefix =
      if prefix != [] and List.last(prefix) != "" and List.first(section_lines) != "" do
        prefix ++ [""]
      else
        prefix
      end

    suffix =
      cond do
        suffix == [] -> suffix
        List.last(section_lines) == "" -> suffix
        not String.starts_with?(List.first(suffix), "## ") -> suffix
        true -> ["" | suffix]
      end

    Enum.join(prefix ++ section_lines ++ suffix, "\n")
  end

  defp build_section(version, entries) do
    date = Date.utc_today() |> to_string()
    grouped = group_by_category(entries)

    category_blocks =
      @categories
      |> Enum.map(fn cat ->
        case Map.get(grouped, cat) do
          nil -> nil
          texts -> "### #{cat}\n\n" <> Enum.map_join(texts, "\n", &"- #{&1}")
        end
      end)
      |> Enum.reject(&is_nil/1)

    case category_blocks do
      [] -> "## [#{version}] - #{date}"
      blocks -> "## [#{version}] - #{date}\n\n" <> Enum.join(blocks, "\n\n")
    end
  end

  # Groups entries by canonical category, tolerating both atom-keyed and
  # string-keyed maps (the LLM path normalizes; test stubs may pass either).
  defp group_by_category(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      category = entry_category(entry)
      text = entry_text(entry)

      if category != nil and text != "" do
        Map.update(acc, category, [text], &(&1 ++ [text]))
      else
        acc
      end
    end)
  end

  defp print_summary(version, entries) do
    grouped = group_by_category(entries)

    Mix.shell().info("Generated changelog section for v#{version}:")

    @categories
    |> Enum.each(fn cat ->
      case Map.get(grouped, cat) do
        nil -> :ok
        texts -> Mix.shell().info("  #{cat}: #{length(texts)}")
      end
    end)
  end

  # --- Interactive commit --------------------------------------------------

  defp maybe_commit_changelog(file, version) do
    if Mix.shell().yes?("Commit the changelog file now? [Yn]") do
      do_commit(file, version)
    else
      Mix.shell().info("""
      Changelog written to #{file} but not committed. Commit it manually:
        git add #{file} && git commit -m "Add changelog for v#{version}"
      """)
    end
  end

  defp do_commit(file, version) do
    case git(["add", "--", file]) do
      {:ok, _output} ->
        case git(["commit", "-m", "Add changelog for v#{version}"]) do
          {:ok, output} ->
            Mix.shell().info(String.trim(output))

          {:error, _code, output} ->
            warn_git_failure("git commit", output, file, version)
        end

      {:error, _code, output} ->
        warn_git_failure("git add", output, file, version)
    end
  end

  defp warn_git_failure(step, output, file, version) do
    Mix.shell().error("⚠ #{step} failed (the changelog file itself was written):")
    Mix.shell().error(String.trim(output))

    Mix.shell().info("""
    Commit the changelog manually:
      git add #{file} && git commit -m "Add changelog for v#{version}"
    """)
  end

  # Runs git in the current directory, capturing stderr into the output so
  # failures can be reported verbatim. Returns {:ok, output} or
  # {:error, code, output}.
  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, code, output}
    end
  end
end
