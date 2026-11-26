Code.require_file("review_test_helper.exs", __DIR__)

defmodule EvoDashWeb.ReviewNavigationTest do
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EvoDashWeb.ReviewLiveTest.Helpers

  alias EvoDashWeb.ReviewLive.LoadData
  alias EvoDashWeb.WorkbenchComponent
  alias EvoGit.Adapters.Git

  setup do
    EvoDash.Test.IsolatedTaskStore.assert_production!()
    :ok
  end

  describe "canonical workbench navigation" do
    test "History waits for the Review lookup, then reads only the resolved project", %{
      conn: conn
    } do
      {project, sha, base} = navigation_repo!("Agent change commit")
      task_id = seed_review_task!(project, sha, base)
      sibling_id = seed_review_task!(project, sha, base)
      other_id = seed_review_task!(review_tmp_path("review-other-project-"), sha, base)
      block_review_lookup(task_id)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      local = node()
      assert_receive {:review_lookup_waiting, worker, ref, ^local, ^task_id}, async_wait_budget()

      assert has_element?(view, ~s(#app-layout[data-workbench-history-scope-pending="true"]))
      assert has_element?(view, "#workbench-history-toggle")
      assert has_element?(view, "#workbench-history-content [role=status]", "Resolving project…")
      refute has_element?(view, "#workbench-git-toggle")
      refute_history_data(view)

      # These fields are set before the component starts either History read.
      # Unlike absent rows or async pids, they also detect a fetch that already finished.
      assert %{
               scope_pending?: true,
               project: nil,
               request: nil,
               history_sig: nil,
               project_options_scope: nil
             } = history_assigns(view)

      send(worker, {:release_review_lookup, ref})
      flush_review_load(view)
      html = render_async(view, async_wait_budget())

      assert_review_shell(view, task_id, project)
      refute has_element?(view, "#workbench-history-content [role=status]", "Resolving project…")

      assert has_element?(
               view,
               ~s(#workbench-history-project-filter option[selected][value="#{project}"])
             )

      row_ids =
        html
        |> Floki.parse_document!()
        |> Floki.find("#workbench-history-rows [data-workbench-item=task]")
        |> Floki.attribute("data-item-id")

      refute other_id in row_ids
      assert Enum.sort(row_ids) == Enum.sort([task_id, sibling_id])
    end

    test "review, foreign commit detail and its back link keep one task and primary project", %{
      conn: conn
    } do
      {primary, primary_sha, base} = navigation_repo!("Agent change commit")
      {foreign, foreign_sha, foreign_base} = navigation_repo!("Foreign navigation commit")

      # The commit page must not be able to read the foreign commit from primary.
      assert {:error, _} = Git.run(["cat-file", "-e", foreign_sha <> "^{commit}"], primary)

      task_id =
        seed_multi_repo_task!(
          primary,
          primary_sha,
          [
            %{
              "id" => "original",
              "root" => foreign,
              "writable" => true,
              "base_sha" => foreign_base
            }
          ],
          %{
            "primary" => %{"commit_sha" => primary_sha, "branch_name" => "task-branch"},
            "original" => %{"commit_sha" => foreign_sha, "branch_name" => "task-branch"}
          },
          base
        )

      review = ~p"/review/#{task_id}"
      {:ok, view, _html} = live(conn, review)
      flush_review_load(view)
      assert_review_shell(view, task_id, primary)

      generation = assigns(view).load_generation
      commits = ~p"/review/#{task_id}?#{%{tab: "commits"}}"
      render_patch(view, commits)
      assert_patch(view, commits, async_wait_budget())
      assert assigns(view).load_generation == generation
      assert repo_select_state(render(view)).selected == ["primary"]

      view
      |> element("#commits-repo-switch-form")
      |> render_change(%{"repo_id" => "original"})

      assert repo_select_state(render(view)).selected == ["original"]
      assert assigns(view).repo_path == foreign
      assert_review_shell(view, task_id, primary)

      commit = ~p"/review/#{task_id}/commit/#{foreign_sha}?#{%{repo: "original"}}"
      view |> element(~s(#review-commits a[href="#{commit}"])) |> render_click()
      assert_patch(view, commit, async_wait_budget())
      flush_review_load(view)

      assert has_element?(view, "#main-content h1", "Foreign navigation commit")
      refute has_element?(view, "#review-commit-error")
      refute has_element?(view, "#review-tabs")
      assert_review_shell(view, task_id, primary)

      back = ~p"/review/#{task_id}?#{%{repo: "original", tab: "commits"}}"
      view |> element(~s(#main-content a[href="#{back}"]), "Back to review") |> render_click()
      assert_patch(view, back, async_wait_budget())
      flush_review_load(view)

      assert has_element?(view, "#review-tabs [phx-value-tab=commits][aria-pressed=true]")
      assert repo_select_state(render(view)).selected == ["original"]
      assert_review_shell(view, task_id, primary)
    end

    test "node switch and reconnect keep the exact commit URL without leaking local scope", %{
      conn: conn
    } do
      EvoDash.Test.ConfigDir.isolate!("evogit_review_navigation")
      target = "review-navigation-#{System.unique_integer([:positive])}"
      name = "Review navigation target"

      assert {:ok, _} =
               EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: target, name: name})

      manager =
        start_supervised!(
          {EvoDashWeb.ReviewLiveTest.ConnectionManager,
           {target, %{phase: :connecting, node: nil, last_error: nil}}}
        )

      {primary, sha, base} = navigation_repo!("Agent change commit")
      task_id = seed_review_task!(primary, sha, base)
      # Node navigation splices the node pair into the URL, not a decoded map.
      # Deliberately use a noncanonical encoding for the repo id.
      commit = ~p"/review/#{task_id}/commit/#{sha}" <> "?repo=prim%61ry&tab=commits"
      {:ok, view, _html} = live(conn, commit)
      flush_review_load(view)
      assert_review_shell(view, task_id, primary)
      local_generation = assigns(view).load_generation

      send(view.pid, {:node_selected, target})
      remote_commit = commit <> "&node=" <> target
      assert_patch(view, remote_commit, async_wait_budget())
      assert has_element?(view, "#main-content p", "Connecting to #{name}…")
      assert_unscoped_review(view, target, task_id)

      assert %{task_id: ^task_id, current_node: local_node, load_generation: generation} =
               assigns(view)

      assert local_node == node()
      assert generation == local_generation + 1

      # A pending target still shares the local BEAM identity. An outstanding
      # reply for the same task and BEAM must not settle this new generation.
      send(
        view.pid,
        {:review_data_loaded, task_id, node(), local_generation, {:ok, %{summary_raw: true}}}
      )

      refute assigns(view).summary_raw
      refute assigns(view).page_ready?
      assert_unscoped_review(view, target, task_id)

      connected = %{phase: :connected, node: "#{target}@127.0.0.1", last_error: nil}
      set_review_connection(view, manager, target, connected)
      assert_patch(view, remote_commit, async_wait_budget())
      flush_review_load(view)
      assert has_element?(view, "#review-load-error", "Task not found")
      assert_unscoped_review(view, target, task_id)

      disconnected = %{phase: :error, node: nil, last_error: "Test connection lost"}
      set_review_connection(view, manager, target, disconnected)
      assert_patch(view, remote_commit, async_wait_budget())
      assert has_element?(view, "#main-content p", "Cannot connect to #{name}")
      assert_unscoped_review(view, target, task_id)

      view |> element(~s(#main-content button[phx-click="switch_to_local"])) |> render_click()
      assert_patch(view, commit, async_wait_budget())
      flush_review_load(view)
      assert has_element?(view, "#main-content h1", "Agent change commit")
      refute has_element?(view, "#review-commit-error")
      assert_review_shell(view, task_id, primary)
    end

    test "an unknown node does not publish a local task identity for a remote review URL", %{
      conn: conn
    } do
      EvoDash.Test.ConfigDir.isolate!("evogit_review_unknown_node")
      task_id = seed_orphaned_review_task!()
      review = ~p"/review/#{task_id}"
      {:ok, view, _html} = live(conn, review)
      flush_review_load(view)
      assert_review_shell(view, task_id, "/nonexistent/repo/path")

      render_patch(view, ~p"/review/#{task_id}?node=unknown-review-target")
      assert has_element?(view, "#review-load-error", "the requested node is unavailable")
      assert_unscoped_review(view, "", nil)
    end

    defp block_review_lookup(task_id) do
      owner = self()

      EvoDash.Test.Seam.put(:review_load_runner, fn
        node, ^task_id, opts ->
          ref = Process.monitor(owner)
          send(owner, {:review_lookup_waiting, self(), ref, node, task_id})

          receive do
            {:release_review_lookup, ^ref} ->
              Process.demonitor(ref, [:flush])
              LoadData.load(node, task_id, opts)

            {:DOWN, ^ref, :process, ^owner, _reason} ->
              {:error, "Test ended before releasing the Review lookup"}
          end

        node, other_task_id, opts ->
          LoadData.load(node, other_task_id, opts)
      end)
    end

    defp history_assigns(view) do
      # Read the mounted component's own assigns from the LiveView channel.
      %{components: {instances, ids, _next_cid}} = :sys.get_state(view.pid, async_wait_budget())
      id = "workbench-history-content"
      cid = ids |> Map.fetch!(WorkbenchComponent) |> Map.fetch!(id)
      {WorkbenchComponent, ^id, assigns, _private, _prints} = Map.fetch!(instances, cid)
      assigns
    end

    defp refute_history_data(view) do
      refute has_element?(view, "#workbench-history-filters")
      refute has_element?(view, "#workbench-history-rows")
    end

    # Review reads the persisted SHAs even after a task branch is gone. Keep
    # the commits on main so navigation needs neither a merge check nor its stub.
    defp navigation_repo!(subject) do
      repo = review_tmp_path("review-navigation-")

      on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(repo) end)
      File.mkdir_p!(repo)
      git!(repo, ~w(init --template= --initial-branch=main))

      command = [
        "-c",
        "user.name=Test User",
        "-c",
        "user.email=test@example.com",
        "-c",
        "core.hooksPath=.git/hooks",
        "commit",
        "--no-gpg-sign"
      ]

      git!(repo, command ++ ~w(--allow-empty -m Base))
      File.write!(Path.join(repo, "feature.txt"), subject <> "\n")
      git!(repo, ~w(add --force -- feature.txt))
      git!(repo, command ++ ["-m", subject])

      assert {:ok, base} = Git.rev_parse(repo, "HEAD^")
      assert {:ok, sha} = Git.rev_parse(repo)
      {repo, sha, base}
    end

    defp assert_review_shell(view, task_id, project) do
      assert review_shell(view) == %{
               "data-workbench-page" => "review",
               "data-workbench-node" => "",
               "data-workbench-task" => task_id,
               "data-workbench-project" => project,
               "data-workbench-title" => "Test objective"
             }

      refute has_element?(view, "#app-layout[data-workbench-history-scope-pending]")
      assert has_element?(view, "#workbench-tabs[phx-update=ignore]")
      refute has_element?(view, "#workbench-tabs > *")
      assert has_element?(view, "#workbench-history-toggle")
      assert has_element?(view, ~s(#workbench-git h2[title="#{project}"]))
    end

    defp assert_unscoped_review(view, node_id, task_id) do
      expected = %{
        "data-workbench-page" => "review",
        "data-workbench-node" => node_id,
        "data-workbench-project" => ""
      }

      expected = if task_id, do: Map.put(expected, "data-workbench-task", task_id), else: expected
      assert review_shell(view) == expected
      refute has_element?(view, "#app-layout[data-workbench-history-scope-pending]")
      refute has_element?(view, "#workbench-history-content [role=status]", "Resolving project…")
      refute_history_data(view)
      refute has_element?(view, "#workbench-history-toggle")
      refute has_element?(view, "#workbench-git-toggle")
      refute has_element?(view, "#main-content h1", "Agent change commit")
      refute has_element?(view, "#main-content h1", "Test objective")
    end

    defp review_shell(view) do
      [{_, attrs, _}] = view |> render() |> Floki.parse_document!() |> Floki.find("#app-layout")

      Map.take(Map.new(attrs), ~w(data-workbench-page data-workbench-node data-workbench-task
        data-workbench-project data-workbench-title))
    end

    defp set_review_connection(view, manager, target, status) do
      :ok = GenServer.call(manager, {:set_status, status}, async_wait_budget())
      send(view.pid, {:remote_connection_status, target, status})
    end
  end
end
