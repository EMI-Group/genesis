# Required explicitly before either review suite defines any ExUnit cases.
# This is not a *_test.exs file; Code.require_file/2 loads it once and waits
# for compilation if the other suite is requiring it concurrently.
defmodule EvoDashWeb.ReviewLiveTest.Helpers do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias EvoGit.TaskInfo

  # Load-tolerant budgets: this host is shared, so async loads and the
  # `:sys.get_state/1` socket read can stall far past the historical
  # 2-5 s (or 5 s default) windows. Waiting longer only weakens the test when
  # the message never arrives — the assertion itself is unchanged.
  @async_wait_budget_ms 30_000
  @assigns_timeout_ms 30_000

  @blocking_merge_check_key {__MODULE__, :blocking_merge_check_repos}

  # Every review suite installs the same merge-check stub in setup_all and
  # leaves it in place so concurrent mounts never run a real merge-tree check.
  # Only the merge-check suite registers its fixture paths with a test owner;
  # concurrent setup_all callbacks can reinstall the stub without clobbering it.
  def canonical_merge_check_runner(node, repo, branch, target) do
    case Map.fetch(blocking_merge_check_repos(), repo) do
      {:ok, owner} ->
        ref = Process.monitor(owner)
        send(owner, {:merge_check_started, self(), ref, node, repo, branch, target})

        receive do
          {:merge_check_reply, ^ref, result} -> result
          {:DOWN, ^ref, :process, ^owner, _reason} -> :test_finished
        end

      :error ->
        {:ok, :clean}
    end
  end

  def install_canonical_merge_check_runner do
    Application.put_env(
      :evo_dash,
      :merge_check_runner,
      &__MODULE__.canonical_merge_check_runner/4
    )
  end

  # Park checks for these unique paths until the owning test replies or exits.
  # Checks from other suites still return :clean immediately.
  def block_merge_check_for!(repos) do
    owner = self()
    blocked = Map.new(repos, &{&1, owner})

    on_exit(fn ->
      :persistent_term.put(
        @blocking_merge_check_key,
        Map.drop(blocking_merge_check_repos(), repos)
      )
    end)

    :persistent_term.put(
      @blocking_merge_check_key,
      Map.merge(blocking_merge_check_repos(), blocked)
    )
  end

  defp blocking_merge_check_repos do
    :persistent_term.get(@blocking_merge_check_key, %{})
  end

  def setup_review_templates!(shapes) do
    install_canonical_merge_check_runner()
    {:ok, review_templates: build_templates!(shapes)}
  end

  def setup_async_review(%{review_templates: templates}) do
    # The template hand-off is per test process. Use the production store and
    # clear only the local sidebar snapshot, both before and after the test.
    Process.put(:review_templates, templates)
    EvoDash.Test.IsolatedTaskStore.assert_production!()
    EvoDash.ActiveTasks.invalidate(nil, node())
    on_exit(fn -> EvoDash.ActiveTasks.invalidate(nil, node()) end)
    :ok
  end

  # Builds ONE quiescent template repo per requested `{primary, secondary}`
  # branch shape for a suite module's `setup_all/1`. Each test then gets an
  # independent `File.cp_r/2` COPY (a plain recursive byte copy — deliberately
  # NOT a hard link and NOT a `git clone --shared` into the template's object
  # store), so a test may freely mutate its copy (real merges, branch deletes,
  # …) without the template or any sibling test ever seeing it.
  # `build_repo_with_task_branch!/3` ends on a `git checkout`, so a template is
  # quiescent (no index.lock, no in-flight writer) when copied.
  # The map is handed to the module's tests through the PROCESS DICTIONARY
  # (`review_template!/2`) because the helpers are shared across modules and
  # must not key anything on `__MODULE__`.
  def build_templates!(shapes) do
    for {primary, secondary} <- shapes, into: %{} do
      dir = review_tmp_path("evogit_review_template_")
      on_exit(fn -> File.rm_rf!(dir) end)

      {change_sha, _primary, base_sha} = build_repo_with_task_branch!(dir, primary, secondary)
      {{primary, secondary}, %{dir: dir, change_sha: change_sha, base_sha: base_sha}}
    end
  end

  # Extracts the repo selector's state from a rendered page: %{values: [...]}
  # (the option values in DOM order) + %{selected: [...]} (the preselected
  # option value(s)) — or %{values: [], selected: []} when no repo selector
  # renders. Every repo <select> shares name="repo_id" + the "selected" boolean
  # attr across the merge box, Files-changed toolbar, and Commits tab, and only
  # the ACTIVE tab's content is in the DOM at any time, so an unscoped find is
  # unambiguous.
  def repo_select_state(html) do
    case Floki.find(Floki.parse_document!(html), "select[name='repo_id']") do
      [] ->
        %{values: [], selected: []}

      [select | _] ->
        options = Floki.find(select, "option")

        values =
          Enum.map(options, fn option ->
            option |> Floki.attribute("value") |> List.first()
          end)

        selected =
          options
          |> Enum.filter(&(Floki.attribute(&1, "selected") != []))
          |> Enum.map(fn option ->
            option |> Floki.attribute("value") |> List.first()
          end)

        %{values: values, selected: selected}
    end
  end

  # Seeds and per-test fixtures remove their OWN row through the STORE, never
  # through `EvoGit.TaskRegistry.delete_task/1`: the registry variant broadcasts
  # `{:task_deleted, id, node()}` on the global "tasks" topic, so an `async:
  # true` module's cleanup would arm the node-aware reload debounce of every
  # page a CONCURRENT module has mounted — `agents_live_test`'s negative
  # `:tasks_reload_pending` poll asserts exactly that this never happens.
  # Deleting through the Store removes the same row, without the broadcast.
  # (`AS` the row was seeded through `EvoGit.Store.put_task/2`, the registry
  # holds no state for it, so nothing else needs clearing.)
  def delete_seeded_task!(task_id), do: EvoGit.Store.delete_task(EvoGit.Store, task_id)
  # Reads the LiveView's socket assigns (same pattern as projects_live_test).
  # The explicit timeout matters: the 5 s `:sys.get_state/1` default exits on a
  # loaded shared host, and this is a round-trip, not a responsiveness pin.
  def assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # A single budget for review helpers and suite assertions.
  def async_wait_budget, do: @async_wait_budget_ms

  # Allocates a name only. The OS pid separates concurrent VMs, and the
  # random suffix also protects against stale paths after a pid is reused.
  def review_tmp_path(prefix) do
    random = Integer.to_string(:rand.uniform(4_294_967_296) - 1, 16)

    Path.join(
      System.tmp_dir!(),
      "#{prefix}#{System.pid()}-#{System.unique_integer([:positive])}-#{random}"
    )
  end

  # Returns command output, including stderr diagnostics when Git fails.
  def git!(repo, args) do
    {output, status} =
      System.cmd(EvoGit.Executable.resolve("git"), args, cd: repo, stderr_to_stdout: true)

    assert status == 0,
           "git #{inspect(args)} in #{inspect(repo)} failed with exit status #{status}:\n#{output}"

    output
  end

  # Hands out a FRESH, independent copy of the pre-built template for the given
  # (primary, secondary) branch shape. Returns {copy_dir, change_sha, base_sha};
  # the SHAs are the template's (the copy is byte-identical). The copy is never
  # hard-linked, so it is always safe to mutate. Register cleanup before copying
  # so a partial copy is removed even when File.cp_r!/2 raises.
  def copy_review_template!(prefix, primary, secondary) do
    %{dir: template_dir, change_sha: change_sha, base_sha: base_sha} =
      review_template!(primary, secondary)

    copy_dir = review_tmp_path(prefix)
    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(copy_dir) end)

    File.cp_r!(template_dir, copy_dir)
    {copy_dir, change_sha, base_sha}
  end

  # Fails loudly (never silently falls back to a from-scratch build) when a new
  # call site asks for a branch shape the module's `setup_all` did not
  # pre-build. Reads the per-TEST hand-off (`setup %{review_templates: …}` puts
  # it in the process dictionary).
  def review_template!(primary, secondary) do
    templates = Process.get(:review_templates) || %{}

    case Map.fetch(templates, {primary, secondary}) do
      {:ok, template} ->
        template

      :error ->
        raise "no pre-built review repo template for #{inspect({primary, secondary})}; " <>
                "available shapes: #{inspect(Map.keys(templates))}"
    end
  end

  # Creates a temp git repo with the given primary branch (plus an optional
  # secondary branch pointing at the base commit), an agent `task-branch` with
  # a change commit on top of the primary branch, and a completed review task
  # pointing at it. Returns {repo_path, task_id, change_sha} and registers
  # on_exit cleanup.
  def create_review_task_with_repo!(primary, secondary) do
    {tmp_dir, change_sha, base_sha} =
      copy_review_template!("evogit_review_merge_test_", primary, secondary)

    task_id = seed_review_task!(tmp_dir, change_sha, base_sha)
    {tmp_dir, task_id, change_sha}
  end

  # Builds a temp git repo at `tmp_dir` with the given primary branch (plus an
  # optional secondary branch at the base commit), an agent `task-branch` with
  # a change commit on top of the primary branch, checked back out to the
  # primary branch. Returns {change_sha, primary_branch, base_sha}.
  def build_repo_with_task_branch!(tmp_dir, primary, secondary) do
    File.mkdir_p!(tmp_dir)
    # Skip sample hooks and auxiliary files so the template is cheap to copy.
    git!(tmp_dir, ["init", "--template=", "-b", primary])

    # Keep these settings in the copied repo for later commits too, without
    # spawning a separate `git config` process for each fixed key.
    File.write!(
      Path.join(tmp_dir, ".git/config"),
      """

      [user]
        name = Test User
        email = test@example.com
      [commit]
        gpgSign = false
      [core]
        hooksPath = .git/hooks
      """,
      [:append]
    )

    File.write!(Path.join(tmp_dir, "base.txt"), "base\n")
    git!(tmp_dir, ["add", "base.txt"])
    git!(tmp_dir, ["commit", "-m", "Initial commit"])

    if secondary do
      git!(tmp_dir, ["branch", secondary])
    end

    # Agent task branch with a change commit, then back to the primary branch.
    git!(tmp_dir, ["checkout", "-b", "task-branch"])
    File.write!(Path.join(tmp_dir, "feature.txt"), "feature change\n")
    git!(tmp_dir, ["add", "feature.txt"])
    git!(tmp_dir, ["commit", "-m", "Agent change commit"])

    [change_sha, base_sha] =
      tmp_dir
      |> git!(["rev-parse", "HEAD", "refs/heads/#{primary}"])
      |> String.split()

    git!(tmp_dir, ["checkout", primary])

    {change_sha, primary, base_sha}
  end

  # Seeds a completed review task with per-repo result data: `foreign_repos`
  # (string-keyed maps — the Store-codec round-trip shape the review page
  # reads) in opts and a top-level `repos` map (string keys) in the result.
  # The `repos` key is NOT in the Store codec's known result fields, so it
  # round-trips as a STRING key — matching what the page actually reads.
  def seed_multi_repo_task!(repo_path, change_sha, foreign_repos, repos_map, base_sha \\ nil) do
    task_id = "review_test_multi_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      base_sha: base_sha,
      opts: [path: repo_path, objective: "Test objective", foreign_repos: foreign_repos],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      review_status: nil,
      result:
        {:ok,
         %{
           commit_sha: change_sha,
           branch_name: "task-branch",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil,
           repos: repos_map
         }}
    }

    on_exit(fn -> delete_seeded_task!(task_id) end)
    EvoGit.Store.put_task(EvoGit.Store, task)

    task_id
  end

  # Seeds a completed review task pointing at `repo_path` with the agent
  # branch `task-branch` (which must exist in the repo). The per-agent archive
  # is its own table (`task_agent_archives`) and never rides the task row, so
  # these tests serve it through the paged archive runner seams instead.
  def seed_review_task!(repo_path, change_sha, base_sha) do
    task_id = "review_test_merge_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      base_sha: base_sha,
      opts: [path: repo_path, objective: "Test objective", archive: true],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      review_status: nil,
      result:
        {:ok,
         %{
           commit_sha: change_sha,
           branch_name: "task-branch",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }}
    }

    on_exit(fn -> delete_seeded_task!(task_id) end)
    EvoGit.Store.put_task(EvoGit.Store, task)

    task_id
  end

  # Seeds a completed task whose result references a branch that does NOT
  # exist in any real repository (repo_path points nowhere) — the same
  # orphaned-branch scenario as the ignore-test fixture, but self-contained
  # for the async-load describe. Returns the task id.
  def seed_orphaned_review_task! do
    task_id = "review_test_async_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      review_status: nil,
      result:
        {:ok,
         %{
           commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
           branch_name: "evogit/test-branch",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }}
    }

    on_exit(fn -> delete_seeded_task!(task_id) end)
    EvoGit.Store.put_task(EvoGit.Store, task)

    task_id
  end

  # Delegates to the shared flush helper (EvoDashWeb.TestHelpers.flush_loading/4).
  def flush_review_load(view, timeout \\ @async_wait_budget_ms) do
    # Settle the mount-time async load BEFORE polling the loading marker: the
    # review page spawns a supervised EvoDash.TaskSupervisor child at mount
    # (ReviewLive.LoadData.load/3) whose result message is applied to the view
    # when it arrives. Draining it first (see await_mount_async_loads/1) keeps
    # the apply from landing mid-test and clobbering assigns a test has just
    # driven past its first event — the same mount-funnel guarantee
    # settings_live_test.exs uses.
    await_mount_async_loads(view)

    EvoDashWeb.TestHelpers.flush_loading(
      view,
      "Loading review data...",
      "timed out waiting for the async review-data load to finish",
      timeout
    )
  end

  # Waits until every EvoDash.TaskSupervisor child started by THIS LiveView
  # process has exited, then flushes their result messages into the view.
  # Task.Supervisor records the spawning process in the child's `$callers`
  # process-dictionary entry, so matching it against the view pid targets exactly
  # this mount's tasks — a leftover task from another test is never waited on
  # (and cannot block the mount). (Copied from settings_live_test.exs, where the
  # same pattern fixed an intermittent full-suite flake.)
  def await_mount_async_loads(view) do
    view.pid
    |> mount_async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      # A task that already exited delivers its :DOWN immediately (reason
      # :noproc); the send/2 that carries its result always happens BEFORE the
      # process exits, so the message is queued by the time the monitor fires.
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        async_wait_budget() -> :ok
      end
    end)

    # No render here: `flush_review_load/2` — the single caller — immediately
    # runs `EvoDashWeb.TestHelpers.flush_loading/4`, whose first iteration is a
    # FORCED render (a synchronous round-trip that applies every queued result
    # message), so a render here would only duplicate it.
    :ok
  end

  def mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  def task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.SettingsLiveTest.ConnectionManager). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.ReviewLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
  def handle_call({:set_status, status}, _from, _previous), do: {:reply, :ok, status}
end
