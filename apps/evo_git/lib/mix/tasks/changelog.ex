defmodule Mix.Tasks.Changelog do
  @moduledoc """
  Generate an AI-powered Keep-a-Changelog section for a new version.

  Collects the commit history since the last git tag (or a custom range),
  summarizes it with an LLM into user-facing changelog categories, and
  maintains `CHANGELOG.md` in Keep a Changelog format. A missing file is
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

  Merge commits and version-bump commits (subjects matching `^Bump version
  to`) are excluded from the summary. After writing the file the task
  interactively asks whether to commit it; if confirmed only the changelog
  file is staged and committed (never `git add -A`).

  ## Examples

      # Summarize everything since the last tag
      mix changelog 0.2.0

      # Explicit range
      mix changelog 0.2.0 --from v0.1.0 --to v0.2.0

  ## Test seam

  The LLM call is routed through the `:changelog_summarizer` application-env
  seam (`Application.get_env(:evo_git, :changelog_summarizer, ...)`); tests
  substitute a deterministic stub via `Application.put_env`.
  """

  use Mix.Task

  @shortdoc "Generate an AI-powered changelog section from git history"

  @requirements ["app.config"]

  @model "deepseek:deepseek-v4-flash"
  @default_file "CHANGELOG.md"
  @record_sep "\x1e"
  @field_sep "\x1f"
  @version_bump_re ~r/^Bump version to/
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

    case collect_commits(opts[:from], opts[:to]) do
      {:ok, []} ->
        Mix.shell().info("No commits found in the given range — nothing to summarize.")

      {:ok, commits} ->
        Mix.shell().info(
          "Found #{length(commits)} commit(s) — generating changelog for v#{version}..."
        )

        case summarize(model, version, commits) do
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

  # --- Commit collection ---------------------------------------------------

  defp collect_commits(from, to) do
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

    git_log(range)
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

  defp git_log(range) do
    format = "%H%x1f%s%x1f%b%x1e"

    case git(["log", "--no-merges", "--pretty=format:#{format}", range]) do
      {:ok, output} ->
        commits =
          output
          |> String.split(@record_sep, trim: true)
          |> Enum.flat_map(&parse_record/1)
          |> Enum.reject(&Regex.match?(@version_bump_re, &1.subject))

        {:ok, commits}

      {:error, code, output} ->
        {:error, {:git_log_failed, code, output}}
    end
  end

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

  # --- LLM summarization ---------------------------------------------------

  # Routes the LLM call through the :changelog_summarizer application-env
  # seam so tests can substitute a deterministic stub (repo-wide pattern,
  # cf. :peak_hours_now_fun, :remote_rpc_timeout).
  defp summarize(model, version, commits) do
    summarizer =
      Application.get_env(:evo_git, :changelog_summarizer, &__MODULE__.summarize_with_llm/3)

    summarizer.(model, version, commits)
  end

  @doc false
  def summarize_with_llm(model, version, commits) do
    prompt = build_prompt(version, commits)

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

  defp build_prompt(version, commits) do
    commit_lines =
      Enum.map_join(commits, "\n", fn c ->
        base = "  #{c.hash} #{c.subject}"

        if c.body == "" do
          base
        else
          base <> "\n    " <> String.replace(c.body, "\n", "\n    ")
        end
      end)

    """
    You are writing release notes for version #{version} of this software project.

    Below are the commits (hash, subject, and optional body) included in this
    release. Write a concise, user-facing changelog in Keep a Changelog style,
    grouped into the categories below. Include ONLY categories that have entries.

    Categories (use exactly these names):
    Added, Changed, Fixed, Removed, Security, Deprecated

    Rules:
    - Each entry is a short user-facing sentence fragment (no commit hashes,
      author names, or file paths).
    - Merge related commits into single entries.
    - Ignore mechanical/trivial commits (chore, formatting, dependency churn,
      pure refactors with no user impact) unless they are meaningful.

    Commits:
    #{commit_lines}
    """
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
