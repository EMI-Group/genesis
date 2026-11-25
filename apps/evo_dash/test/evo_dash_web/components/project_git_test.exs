defmodule EvoDashWeb.ProjectGitTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ProjectGit

  @project "/repos/launch plan"
  @views [
    {"changes", "Changes", "workbench-git-changes"},
    {"branches", "Branches", "workbench-git-branches"},
    {"commits", "Commits", "workbench-git-history"}
  ]
  @cid %Phoenix.LiveComponent.CID{cid: 7}

  test "the header, summary, switcher and branch search stay above the selected view" do
    for {section, _label, view_id} <- @views do
      tree = render_git(section: section, query: "main")
      assert [panel] = Floki.find(tree, "#workbench-git-content[phx-hook=WorkbenchSection]")

      assert [heading] =
               Floki.find(panel, "#workbench-git-content > header.workbench-git-heading")

      assert text(heading, ".workbench-git-eyebrow") == "Source control"
      assert text(heading, "h2") == "launch plan"
      assert attr(heading, "h2", "title") == [@project]

      assert attr(
               heading,
               ".workbench-git-chip[phx-click=git_section][phx-target='7']",
               "phx-value-section"
             ) == ["branches"]

      assert text(heading, ".workbench-git-chip .truncate") == "main"
      assert text(heading, "[title='Ahead of upstream']") == "↑2"
      assert text(heading, "[title='Behind upstream']") == "↓1"
      assert [_] = Floki.find(heading, "[data-workbench-close-git][aria-label='Close Git panel']")

      assert [summary] =
               Floki.find(panel, "#workbench-git-content > .workbench-git-summary.flex-none")

      assert text(summary, "code") == "abcdef123"
      assert attr(summary, "[title='Publish launch plan']", "title") == ["Publish launch plan"]
      assert text(summary, "[title='origin/main']") == "origin/main"
      assert Floki.find(summary, ".workbench-git-delta") == []

      assert [switcher] =
               Floki.find(
                 panel,
                 "#workbench-git-content > .workbench-segmented.workbench-git-views.flex-none[role=group][aria-label='Git views']"
               )

      buttons = Floki.find(switcher, "button[type=button][phx-click=git_section][phx-target='7']")

      assert Enum.map(buttons, fn button ->
               {Floki.attribute(button, "phx-value-section"), String.trim(Floki.text(button)),
                Floki.attribute(button, "aria-pressed")}
             end) ==
               Enum.map(@views, fn {key, label, _id} ->
                 {[key], label, [to_string(key == section)]}
               end)

      preceding_controls =
        "#workbench-git-content > header.workbench-git-heading ~ .workbench-git-summary ~ .workbench-git-views"

      preceding_controls =
        if section == "branches",
          do: preceding_controls <> " ~ #workbench-git-search",
          else: preceding_controls

      assert attr(panel, preceding_controls <> " ~ .workbench-git-body > div", "id") == [view_id]

      if section == "branches" do
        assert [search] =
                 Floki.find(
                   panel,
                   "#workbench-git-content > form#workbench-git-search.flex-none[phx-change=git_search][phx-target='7']"
                 )

        assert attr(
                 search,
                 "#workbench-git-query[type=search][name=query][aria-controls=workbench-git-branches]",
                 "value"
               ) == ["main"]
      else
        assert Floki.find(panel, "#workbench-git-search") == []
      end
    end
  end

  test "changes show total and per-group counts, with original diff indexes and group-local paging" do
    changes = [
      file(:untracked, "new <> file", "?"),
      file(:unstaged, "notes.txt", "M"),
      file(:staged, "notes.txt", "A"),
      file(:conflicted, "conflict.txt", "U"),
      file(:staged, "removed.txt", "D")
    ]

    tree = render_git(snapshot: snapshot(changes: changes), shown_files: %{staged: 1})

    assert ["Working tree", "Conflicts", "Staged", "Unstaged", "Untracked"] ==
             tree
             |> Floki.find("#workbench-git-changes h3 > span:first-child")
             |> Enum.map(&Floki.text/1)

    assert ["5 changes", "1", "2", "1", "1"] ==
             tree
             |> Floki.find("#workbench-git-changes h3 .workbench-git-count")
             |> Enum.map(&Floki.text/1)

    files = "#workbench-git-changes button[data-workbench-git-file][data-workbench-git-preview]"

    assert attr(tree, files <> "[phx-click=git_file][phx-target='7']", "phx-value-index") ==
             ~w(3 2 1 0)

    assert attr(tree, files, "title") == ["conflict.txt", "notes.txt", "notes.txt", "new <> file"]

    for {index, code, tint} <- [
          {3, "U", "text-error"},
          {2, "A", "text-success"},
          {1, "M", "text-warning"},
          {0, "?", "text-base-content/70"}
        ] do
      assert [chip] = Floki.find(tree, "#{files}[phx-value-index='#{index}'] .workbench-git-code")
      assert String.trim(Floki.text(chip)) == code
      assert tint in String.split(hd(Floki.attribute(chip, "class")))
    end

    pager =
      "#workbench-git-changes button.workbench-git-more[phx-click=git_more_files][phx-target='7']"

    assert attr(tree, pager, "phx-value-kind") == ["staged"]
    assert text(tree, pager) == "Show more files"

    expanded = render_git(snapshot: snapshot(changes: changes), shown_files: %{staged: 2})
    assert attr(expanded, files, "phx-value-index") == ~w(3 2 4 1 0)
    assert Floki.find(expanded, pager) == []
  end

  test "a clean tree on detached HEAD omits empty groups, summary and zero tracking deltas" do
    tree =
      render_git(
        head: nil,
        snapshot: snapshot(branch: nil, commit: nil, upstream: nil, ahead: "0", behind: "0")
      )

    assert text(tree, ".workbench-git-chip") == "Detached HEAD"
    assert text(tree, "#workbench-git-changes") == "Working tree is clean."

    assert Floki.find(tree, ".workbench-git-group, .workbench-git-summary, .workbench-git-delta") ==
             []
  end

  test "branch search counts matches before capping and renders current and remote actions differently" do
    current = branch(:local, "main")
    remote = branch(:remote, "origin/main")

    branches =
      [current, remote, branch(:local, "release")] ++
        for(i <- 1..59, do: branch(:local, "feature/main-#{i}"))

    opts = [section: "branches", snapshot: snapshot(branches: branches)]
    tree = render_git(opts ++ [query: " MAIN ", branch: remote])

    assert text(tree, "#workbench-git-branches h3 .workbench-git-count") == "60 of 61 branches"
    assert length(Floki.find(tree, "#workbench-git-branches [phx-click=git_branch]")) == 60

    assert text(tree, "#workbench-git-branches .workbench-hint") ==
             "Search to narrow the branch list."

    assert Floki.find(
             tree,
             "[phx-value-ref='refs/heads/release'], [phx-value-ref='refs/heads/feature/main-59']"
           ) == []

    local_row = "button[phx-click=git_branch][phx-value-ref='refs/heads/main']"
    remote_row = "button[phx-click=git_branch][phx-value-ref='refs/remotes/origin/main']"
    assert text(tree, local_row <> " .workbench-git-entry-meta") == "Current branch"
    assert [_] = Floki.find(tree, local_row <> " .workbench-git-current-mark")
    assert text(tree, remote_row <> " .workbench-git-entry-meta") == "Remote branch"
    assert attr(tree, remote_row, "aria-pressed") == ["true"]
    assert attr(tree, local_row, "aria-pressed") == ["false"]

    switch = ".workbench-git-branch-actions button[phx-click=git_switch][phx-target='7']"
    start = ".workbench-git-branch-actions button[phx-click=git_start_task][phx-target='7']"
    assert text(tree, switch) == "Check out tracking branch"
    assert attr(tree, switch, "phx-value-ref") == [remote.ref]
    assert text(tree, start) == "Start task from branch"
    assert attr(tree, start, "phx-value-ref") == [remote.ref]

    selected_current = render_git(opts ++ [branch: current])
    assert Floki.find(selected_current, switch) == []
    assert attr(selected_current, start, "phx-value-ref") == [current.ref]

    selected_release =
      render_git(opts ++ [query: "release", branch: branch(:local, "release"), busy: :switch])

    assert text(selected_release, "#workbench-git-branches h3 .workbench-git-count") == "1 branch"
    assert text(selected_release, switch) == "Switch project branch"
    assert attr(selected_release, switch, "disabled") == ["disabled"]
    assert attr(selected_release, start, "disabled") == ["disabled"]

    no_match = render_git(opts ++ [query: "nothing-matches"])
    assert text(no_match, "#workbench-git-branches") == "No matching branches."
    assert Floki.find(no_match, "#workbench-git-branches h3, [phx-click=git_branch]") == []
  end

  test "commit paging keeps loaded rows and their count visible while the next page loads" do
    rows = [commit("abcdef123", "Launch <plan>"), commit("012345678", "Earlier change")]
    opts = [section: "commits"]
    tree = render_git(opts ++ [history: %{rows: rows, more?: true}])

    row =
      "#workbench-git-history button[data-workbench-git-preview][phx-click=git_commit][phx-target='7']"

    pager =
      "#workbench-git-history button.workbench-git-more[phx-click=git_more_commits][phx-target='7']"

    assert attr(tree, row, "phx-value-sha") == Enum.map(rows, & &1.sha)
    assert attr(tree, row, "title") == ["Launch <plan>", "Earlier change"]

    assert text(tree, "#{row}:first-of-type .workbench-git-entry-meta") ==
             "abcdef123 · Pat · 2026-11-25"

    assert text(tree, "#workbench-git-history h3 .workbench-git-count") == "2 commits loaded"
    assert text(tree, pager) == "Show more commits"

    loading = render_git(opts ++ [history: %{rows: rows, more?: true, loading?: true}])
    assert text(loading, "#workbench-git-history [role=status]") == "Loading…"
    assert attr(loading, row, "phx-value-sha") == Enum.map(rows, & &1.sha)
    assert text(loading, "#workbench-git-history h3 .workbench-git-count") == "2 commits loaded"
    assert Floki.find(loading, "#workbench-git-history [data-skeleton], #{pager}") == []
  end

  test "commit first load, empty and retry states are distinct" do
    view = "#workbench-git-history"
    first = render_git(section: "commits", history: %{loading?: true})
    assert text(first, "#{view} [role=status]") == "Loading…"
    assert [_] = Floki.find(first, "#{view} [data-skeleton]")
    refute Floki.text(first) =~ "No commits on this branch."

    empty = render_git(section: "commits", history: %{rows: []})
    assert text(empty, view) == "No commits on this branch."

    assert Floki.find(
             empty,
             "#{view} [role=status], #{view} [role=alert], #{view} [data-skeleton]"
           ) == []

    failed = render_git(section: "commits", history: %{rows: [], error: "History unavailable"})
    assert text(failed, "#{view} [role=alert] p") == "History unavailable"

    assert text(
             failed,
             "#{view} [role=alert] button[phx-click=git_retry_history][phx-target='7']"
           ) == "Retry"

    refute Floki.text(failed) =~ "No commits on this branch."
  end

  test "status refresh leaves a cached view visible; only a first load shows a skeleton" do
    refresh = "#workbench-git-refresh[type=button][phx-click=git_refresh][phx-target='7']"
    first = render_git(snapshot: nil, head: nil, busy: :snapshot)
    assert text(first, "[role=status]") == "Loading Git status…"
    assert [_] = Floki.find(first, ".workbench-git-body[aria-busy=true] > [data-skeleton]")
    assert attr(first, refresh, "disabled") == ["disabled"]
    assert Floki.find(first, ".workbench-git-views") == []

    cached =
      render_git(
        busy: :snapshot,
        snapshot: snapshot(changes: [file(:unstaged, "notes.txt", "M")])
      )

    assert text(cached, "[role=status]") == "Refreshing Git status…"
    assert [_] = Floki.find(cached, ".workbench-git-body[aria-busy=true] [phx-click=git_file]")
    assert Floki.find(cached, "[data-skeleton]") == []
    assert attr(cached, refresh, "disabled") == ["disabled"]
    assert [_] = Floki.find(render_git(), refresh <> ":not([disabled])")

    failed =
      render_git(snapshot: nil, head: nil, error: "This project does not have a Git repository.")

    assert text(failed, "[role=alert]") == "This project does not have a Git repository."
    assert [_] = Floki.find(failed, refresh <> ":not([disabled])")
    assert Floki.find(failed, "[role=status], [data-skeleton], .workbench-git-views") == []

    pending = render_git(target: nil, project: nil, snapshot: nil, head: nil)
    assert text(pending, "h2") == "No project"
    assert text(pending, ".workbench-hint") == "Connect to see the project's Git status."
    assert attr(pending, refresh, "disabled") == ["disabled"]

    assert Floki.find(
             pending,
             ".workbench-git-views, [data-workbench-git-scope], [data-workbench-git-target]"
           ) == []
  end

  test "a file preview points at the shell portal host and preserves its selected row and diff text" do
    file = file(:unstaged, "dir/notes.txt", "M")

    opts = [
      node_id: "remote-test",
      target: :"remote@127.0.0.1",
      snapshot: snapshot(changes: [file]),
      preview: %{
        kind: :file,
        item: file,
        title: "notes.txt",
        heading: "notes.txt",
        subtitle: "Unstaged · dir/notes.txt"
      }
    ]

    tree =
      render_git(
        opts ++ [lines: [%{type: :addition, prefix: "+", content: "<updated>"}], omitted: 1]
      )

    root = "#workbench-git-content"
    assert attr(tree, root, "data-workbench-git-diff") == ["notes.txt"]
    assert attr(tree, root, "data-workbench-git-target") == ["remote@127.0.0.1"]
    [scope] = attr(tree, root, "data-workbench-git-scope")
    assert %URI{path: "/", query: query} = URI.parse(scope)
    assert URI.decode_query(query) == %{"node" => "remote-test", "project" => @project}

    assert [_] =
             Floki.find(tree, "[data-workbench-git-file][phx-value-index='0'][aria-pressed=true]")

    assert [portal] =
             Floki.find(
               tree,
               "template#workbench-git-diff-portal[data-phx-portal='#workbench-git-diff-host']"
             )

    assert [_] =
             Floki.find(portal, "#workbench-git-diff[aria-labelledby=workbench-git-diff-title]")

    assert text(portal, "#workbench-git-diff-title[tabindex='-1']") == "notes.txt"

    assert [_] =
             Floki.find(portal, "button[data-workbench-close-git-diff][aria-label='Close diff']")

    assert text(portal, ".workbench-git-diff-lines[tabindex='0'] code[data-diff-type=addition]") ==
             "+<updated>"

    assert text(portal, ".workbench-hint") == "Diff preview truncated."

    no_preview = render_git(snapshot: snapshot(changes: [file]))
    assert attr(no_preview, root, "data-workbench-git-diff") == []
    assert Floki.find(no_preview, "#workbench-git-diff-portal") == []
    assert [_] = Floki.find(no_preview, "[data-workbench-git-file][aria-pressed=false]")
  end

  test "the parent-supplied GitHub upstream alone enables the Issues footer outside the scroller" do
    tree =
      render_git(
        snapshot: nil,
        head: nil,
        github_status: %{state: :ok, owner: "acme", repo: "launch"}
      )

    assert [footer] =
             Floki.find(
               tree,
               "#workbench-git-content > .workbench-git-body + section.workbench-git-github[aria-label=GitHub]"
             )

    assert text(footer, ".workbench-git-github-slug > span.font-mono") == "acme/launch"
    assert [issues] = Floki.find(footer, "button[type=button][phx-click=open_github_issues]")
    assert String.trim(Floki.text(issues)) == "Issues"
    assert Floki.attribute(issues, "title") == ["Open GitHub Issues · acme/launch"]
    # The parent page handles the event, not the Git LiveComponent.
    assert Floki.attribute(issues, "phx-target") == []

    for status <- [
          nil,
          %{state: :loading, owner: "acme", repo: "launch"},
          %{state: :ok, owner: "acme", repo: ""}
        ] do
      assert Floki.find(
               render_git(github_status: status),
               ".workbench-git-github, [phx-click=open_github_issues]"
             ) == []
    end
  end

  # Render the real callback with mounted defaults and data in the same shape as
  # the async results. No mount, node RPC, or async git operation is simulated.
  defp render_git(opts \\ []) do
    {:ok, socket} = ProjectGit.mount(%Phoenix.LiveView.Socket{})

    assigns =
      socket.assigns
      |> Map.merge(%{
        id: "workbench-git-content",
        myself: @cid,
        node_id: nil,
        target: node(),
        project: @project,
        github_status: nil,
        snapshot: snapshot(),
        head: "main"
      })
      |> Map.merge(Map.new(opts))

    (&ProjectGit.render/1)
    |> render_component(assigns)
    |> Floki.parse_document!()
  end

  defp snapshot(opts \\ []) do
    Map.merge(
      %{
        root: @project,
        branch: "main",
        commit: "abcdef1230000000000000000000000000000000",
        subject: "Publish launch plan",
        upstream: "origin/main",
        ahead: "2",
        behind: "1",
        changes: [],
        branches: [branch(:local, "main")]
      },
      Map.new(opts)
    )
  end

  defp file(kind, path, code), do: %{kind: kind, path: path, code: code, from: nil}
  defp branch(:local, name), do: %{kind: :local, name: name, ref: "refs/heads/#{name}"}
  defp branch(:remote, name), do: %{kind: :remote, name: name, ref: "refs/remotes/#{name}"}

  defp commit(short, subject) do
    %{
      sha: String.pad_trailing(short, 40, "0"),
      short: short,
      subject: subject,
      author: "Pat",
      date: "2026-11-25T10:11:12Z"
    }
  end

  defp attr(tree, selector, name), do: Floki.attribute(tree, selector, name)
  defp text(tree, selector), do: tree |> Floki.find(selector) |> Floki.text() |> String.trim()
end
