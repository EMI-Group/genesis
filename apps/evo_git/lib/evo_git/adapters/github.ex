defmodule EvoGit.Adapters.GitHub do
  @moduledoc """
  Wrapper for GitHub issue queries via the `gh` CLI.

  All GitHub interaction goes through the `gh` command — no GitHub API HTTP
  calls. `gh_available?/0` is reused from `EvoGit.Adapters.Git`.

  ## Return contract

  Every function takes `repo_path` as its first argument and returns tagged
  tuples; nothing ever raises on CLI failures. The shared check order is
  pinned (and relied upon by tests — do not reorder):

  1. `File.dir?(repo_path)` pre-check → `{:error, {:enoent, repo_path}}`
     (System.cmd never receives a bad `:cd`).
  2. `EvoGit.Adapters.Git.gh_available?/0` → `{:error, :gh_not_available}`
     (`System.cmd("gh", ...)` raises ErlangError when gh is not on PATH, so
     every gh invocation is guarded by this check).
  3. `github_upstream/1` error → propagated as-is.
  4. Run the `gh` command.

  gh failures return `{:error, {:gh, code, trimmed_output}}`; unparseable gh
  JSON returns `{:error, {:invalid_json, reason}}`.

  ## Invocation conventions

  * **gh** (mirrors `Git.create_pull_request/5`): `System.cmd("gh", args,
    cd: repo_path, stderr_to_stdout: true)` — plain `"gh"`, no GitEnv.
  * **git** (mirrors `Git.has_origin_remote?/1`): `System.cmd(
    EvoGit.Executable.resolve("git"), args, cd: repo_path,
    stderr_to_stdout: true, env: EvoGit.GitEnv.git_env(repo_path))`.
  """

  # Own URL regexes covering BOTH https and ssh GitHub origin forms (the
  # `@repo_url_re` in git.ex covers only https). Both accept an optional
  # trailing `.git`, slash, and whitespace; input is trimmed before matching.
  @https_url_re ~r{\Ahttps://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z}
  @ssh_url_re ~r{\Agit@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z}

  @issue_list_fields "number,title,state,labels,url,author,createdAt"
  @issue_view_fields "number,title,state,labels,url,author,body"

  @doc """
  Resolves the GitHub upstream (owner/repo) of a repository from its `origin`
  remote URL via `git remote get-url origin`.

  Parses both URL forms:

  * https: `https://github.com/owner/repo` (optional trailing `.git`/slash)
  * ssh: `git@github.com:owner/repo.git` (optional trailing `.git`/slash)

  Returns `{:ok, %{owner: String.t(), repo: String.t(), url: String.t(),
  gh_available: boolean()}}` on success — `repo` has `.git` stripped, `url`
  is the trimmed origin URL verbatim, `gh_available` comes from
  `EvoGit.Adapters.Git.gh_available?/0`.

  Errors:

  * `{:error, {:enoent, repo_path}}` — repo path does not exist
  * `{:error, :no_github_upstream}` — non-GitHub origin URL, or git reports no origin remote (git exit 128, or exit 2 as real git ≥2.55 emits for "No such remote")
  * `{:error, {:code, code, trimmed_output}}` — any other non-zero git exit
  """
  @spec github_upstream(String.t()) ::
          {:ok, %{owner: String.t(), repo: String.t(), url: String.t(), gh_available: boolean()}}
          | {:error, term()}
  def github_upstream(repo_path) when is_binary(repo_path) do
    if not File.dir?(repo_path) do
      {:error, {:enoent, repo_path}}
    else
      case System.cmd(
             EvoGit.Executable.resolve("git"),
             ["remote", "get-url", "origin"],
             cd: repo_path,
             stderr_to_stdout: true,
             env: EvoGit.GitEnv.git_env(repo_path)
           ) do
        {output, 0} ->
          trimmed = String.trim(output)

          case parse_github_url(trimmed) do
            {:ok, owner, repo} ->
              {:ok,
               %{
                 owner: owner,
                 repo: repo,
                 url: trimmed,
                 gh_available: EvoGit.Adapters.Git.gh_available?()
               }}

            :error ->
              {:error, :no_github_upstream}
          end

        {_output, code} when code in [2, 128] ->
          # No origin remote: the pinned contract expects git exit 128, but
          # real git >= 2.55 emits exit 2 ("error: No such remote 'origin'")
          # for `git remote get-url` — both mean the same thing here.
          {:error, :no_github_upstream}

        {output, code} ->
          {:error, {:code, code, String.trim(output)}}
      end
    end
  end

  @doc """
  Lists GitHub issues of the repository's upstream via
  `gh issue list --repo <owner>/<repo> --state <state> --limit <limit>
  --json number,title,state,labels,url,author,createdAt`.

  Options (defaults shown): `state: "open"`, `limit: 100` (integer,
  stringified for the CLI arg).

  Returns `{:ok, [issue_map]}` where each issue is normalized to
  `%{number: integer, title: String.t(), state: String.t(),
  labels: [String.t()], url: String.t(), author: String.t(),
  created_at: String.t()}`.

  Errors (check order pinned — see the module "## Return contract"):

  * `{:error, {:enoent, repo_path}}`
  * `{:error, :gh_not_available}`
  * upstream errors from `github_upstream/1` propagated as-is
  * `{:error, {:gh, code, trimmed_output}}` — gh exited non-zero
  * `{:error, {:invalid_json, reason}}` — malformed JSON (`reason` is the
    `Jason` error term) or non-array JSON (`reason` is `:not_an_array`)
  """
  @spec list_github_issues(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_github_issues(repo_path, opts \\ []) when is_binary(repo_path) and is_list(opts) do
    state = Keyword.get(opts, :state, "open")
    limit = Keyword.get(opts, :limit, 100)

    with_github_ready(repo_path, fn %{owner: owner, repo: repo} ->
      args = [
        "issue",
        "list",
        "--repo",
        "#{owner}/#{repo}",
        "--state",
        to_string(state),
        "--limit",
        Integer.to_string(limit),
        "--json",
        @issue_list_fields
      ]

      case System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true) do
        {output, 0} ->
          decode_issue_array(output)

        {output, code} ->
          {:error, {:gh, code, String.trim(output)}}
      end
    end)
  end

  @doc """
  Fetches a single GitHub issue via
  `gh issue view <number> --repo <owner>/<repo>
  --json number,title,state,labels,url,author,body` and composes it into a
  deterministic Markdown string:

      # GitHub Issue #<number>: <title>
      URL: <url> | State: <state> | Labels: <l1>, <l2>

      <body>

  When the issue has no labels the labels segment is omitted entirely (the
  second line is `URL: <url> | State: <state>`). Labels are joined with
  `", "`; the body is embedded verbatim after one blank line (no trailing
  whitespace manipulation).

  Returns `{:ok, markdown}` on success. Errors (check order pinned — see the
  module "## Return contract"):

  * `{:error, {:enoent, repo_path}}`
  * `{:error, :gh_not_available}`
  * upstream errors from `github_upstream/1` propagated as-is
  * `{:error, {:gh, code, trimmed_output}}` — gh exited non-zero
  * `{:error, {:invalid_json, reason}}` — malformed JSON (`reason` is the
    `Jason` error term) or non-object JSON (`reason` is `:not_an_object`)
  """
  @spec github_issue_markdown(String.t(), integer() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def github_issue_markdown(repo_path, number)
      when is_binary(repo_path) and (is_integer(number) or is_binary(number)) do
    with_github_ready(repo_path, fn %{owner: owner, repo: repo} ->
      args = [
        "issue",
        "view",
        to_string(number),
        "--repo",
        "#{owner}/#{repo}",
        "--json",
        @issue_view_fields
      ]

      case System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true) do
        {output, 0} ->
          decode_issue_object(output)

        {output, code} ->
          {:error, {:gh, code, String.trim(output)}}
      end
    end)
  end

  # Shared prelude with the pinned check order: dir exists → gh available →
  # upstream resolvable → run the gh command. `fun` receives the upstream map.
  defp with_github_ready(repo_path, fun) when is_function(fun, 1) do
    if File.dir?(repo_path) do
      if EvoGit.Adapters.Git.gh_available?() do
        case github_upstream(repo_path) do
          {:ok, upstream} -> fun.(upstream)
          {:error, _reason} = error -> error
        end
      else
        {:error, :gh_not_available}
      end
    else
      {:error, {:enoent, repo_path}}
    end
  end

  # Parses a trimmed origin URL into {owner, repo}. Handles both https and ssh
  # GitHub forms; the `.git` suffix and trailing slash are consumed by the
  # regexes. Returns :error for anything else (incl. non-GitHub hosts).
  defp parse_github_url(url) do
    case Regex.run(@https_url_re, url) do
      [_, owner, repo] ->
        {:ok, owner, repo}

      nil ->
        case Regex.run(@ssh_url_re, url) do
          [_, owner, repo] -> {:ok, owner, repo}
          nil -> :error
        end
    end
  end

  # Decodes gh `issue list` output (a JSON ARRAY of objects) into normalized
  # issue maps. Never raises.
  defp decode_issue_array(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, issues} when is_list(issues) ->
        {:ok, Enum.map(issues, &normalize_issue/1)}

      {:ok, _other} ->
        {:error, {:invalid_json, :not_an_array}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # Decodes gh `issue view` output (a single JSON object) into the pinned
  # markdown string. Never raises.
  defp decode_issue_object(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, issue} when is_map(issue) ->
        {:ok, compose_markdown(issue)}

      {:ok, _other} ->
        {:error, {:invalid_json, :not_an_object}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # Normalizes one gh issue object to the pinned atom-keyed map
  # (7 keys — the list shape; `body` is not included here).
  defp normalize_issue(issue) do
    Map.put(issue_base_fields(issue), :created_at, string_or_empty(issue["createdAt"]))
  end

  # Shared fields for both the list normalization and the markdown composer.
  defp issue_base_fields(issue) do
    %{
      number: issue["number"],
      title: string_or_empty(issue["title"]),
      state: string_or_empty(issue["state"]),
      labels: label_names(issue["labels"]),
      url: string_or_empty(issue["url"]),
      author: author_login(issue["author"])
    }
  end

  # Extracts the `name` string from each label object; label objects missing
  # `name` are skipped.
  defp label_names(labels) when is_list(labels) do
    for %{"name" => name} when is_binary(name) <- labels, do: name
  end

  defp label_names(_other), do: []

  # Extracts the `login` string from the author map; missing author → "".
  defp author_login(%{"login" => login}) when is_binary(login), do: login
  defp author_login(_other), do: ""

  defp string_or_empty(nil), do: ""
  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(value), do: to_string(value)

  # Composes the pinned markdown format. The labels segment is omitted
  # entirely when there are no labels; the body is embedded verbatim.
  defp compose_markdown(issue) do
    fields = issue_base_fields(issue)
    body = string_or_empty(issue["body"])

    labels_segment =
      case fields.labels do
        [] -> ""
        _ -> " | Labels: #{Enum.join(fields.labels, ", ")}"
      end

    "# GitHub Issue ##{fields.number}: #{fields.title}\n" <>
      "URL: #{fields.url} | State: #{fields.state}#{labels_segment}\n\n" <> body
  end
end
