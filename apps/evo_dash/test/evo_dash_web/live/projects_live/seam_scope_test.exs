defmodule EvoDashWeb.ProjectsLive.SeamScopeTest do
  @moduledoc """
  Proves the CHAIN-SCOPED seam contract that lets the Projects LiveView family
  stay `async: true`: `EvoDash.Seam.get/2` resolves a seam on the CALLER's
  spawn chain, so an override installed by `EvoDash.Test.Seam.put/2` reaches
  exactly the pages and load tasks descended from the installing test.
  A consumer outside that chain — another test's concurrently mounted page —
  resolves the production value instead, which is why a runner fixture can no
  longer make a foreign page render this test's bundle or raise a
  `FunctionClauseError` inside an argument-pattern-matched fixture fun.

  Self-contained on purpose: it must be runnable alone (`mix test <this file>`),
  so it owns its config-dir/VCT isolation and its git fixture instead of
  importing the Projects suite's helper module (that module lives inside
  `projects_live_test.exs` and is only loaded when THAT file is compiled).
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDash.Seam
  alias EvoDashWeb.ProjectsLive.Overview

  # A seam key NO production code reads, so these proofs never disturb a
  # concurrently running module (the app-env leg writes only this key).
  @probe :evodash_seam_scope_probe
  @wait_budget_ms 30_000

  setup :setup_isolated_runtime
  setup :setup_project_dir

  describe "EvoDash.Seam.get/2 precedence" do
    test "the process' own dictionary entry wins over app env" do
      put_app_env(@probe, :app_env)

      Process.put(@probe, :own)
      assert Seam.get(@probe, :default) == :own

      Process.delete(@probe)
      assert Seam.get(@probe, :default) == :app_env
    end

    test "a Task child resolves the value from its $callers chain" do
      # No app env on this key at all: the value can only come from the chain.
      assert Application.fetch_env(:evo_dash, @probe) == :error
      Process.put(@probe, :from_test)

      {own, resolved} =
        Task.async(fn -> {Process.get(@probe), Seam.get(@probe, :default)} end)
        |> Task.await()

      assert own == nil, "the child must not carry its own copy of the override"
      assert resolved == :from_test
    end

    test "a proc_lib child resolves the value from its $ancestors chain" do
      assert Application.fetch_env(:evo_dash, @probe) == :error
      Process.put(@probe, :from_test)

      # `Agent.start_link/1` runs its init through `:proc_lib`, so the child
      # inherits `$ancestors` (and no `$callers`) from this process.
      {:ok, agent} = Agent.start_link(fn -> Seam.get(@probe, :default) end)
      assert Agent.get(agent, & &1) == :from_test
    end

    test "an unrelated process falls through app env to the default" do
      assert Seam.get(@probe, :default) == :default

      put_app_env(@probe, :app_env)

      parent = self()

      # A plain `spawn` inherits neither `$callers` nor `$ancestors`, i.e. it is
      # exactly as unrelated to this test as another test's LiveView process.
      spawn(fn ->
        send(
          parent,
          {:unrelated, Process.get(:"$callers"), Process.get(:"$ancestors"),
           Seam.get(@probe, :default)}
        )
      end)

      assert_receive {:unrelated, nil, nil, :app_env}
    end

    test "a dead pid in the chain is skipped instead of crashing the read" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      parent = self()

      spawn(fn ->
        Process.put(:"$callers", [dead, parent])
        send(parent, {:after_dead, Seam.get(@probe, :default)})
      end)

      assert_receive {:after_dead, :default}
    end
  end

  describe "EvoDash.Test.Seam.put/2 scoping" do
    test "reaches the installing process and its descendants, never a sibling" do
      EvoDash.Test.Seam.put(@probe, :fixture)

      # The installing process and everything it spawns resolve the fixture ...
      assert Seam.get(@probe, :production) == :fixture

      assert Task.async(fn -> Seam.get(@probe, :production) end) |> Task.await() == :fixture

      # ... and NOTHING else does: no app-env write exists to leak, so a
      # concurrent page (a process outside this chain) resolves production.
      assert Application.fetch_env(:evo_dash, @probe) == :error

      parent = self()
      spawn(fn -> send(parent, {:sibling, Seam.get(@probe, :production)}) end)
      assert_receive {:sibling, :production}

      # `delete/1` clears the override mid-test.
      EvoDash.Test.Seam.delete(@probe)
      assert Seam.get(@probe, :production) == :production
    end

    test "a mounted page renders the fixture while a sibling resolves the default runner",
         %{conn: conn, project_path: path} do
      # Argument-pattern-matched on purpose: this is the fixture shape that used
      # to raise `FunctionClauseError` inside a FOREIGN page when the seam was
      # BEAM-global app env.
      fixture = fn _node, ^path ->
        %{
          git: %{
            branch: "seam-fixture",
            commit: "0123456789abcdef0123456789abcdef01234567",
            subject: "seam fixture subject"
          },
          tasks: []
        }
      end

      EvoDash.Test.Seam.put(:projects_overview_runner, fixture)

      # The page this test mounts is descended from the test process, so its
      # off-process overview read resolves the fixture.
      {:ok, view, _html} = live(conn, ~p"/projects?project=#{path}")
      wait_until(view, fn assigns -> not is_nil(assigns[:overview_git]) end)
      assert assigns(view)[:overview_git].branch == "seam-fixture"

      # The production key is untouched, so a consumer outside this chain — any
      # other test's page — never receives this fixture: it resolves the
      # un-overridden seam value and therefore the production loader.
      assert Application.fetch_env(:evo_dash, :projects_overview_runner) == :error
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:sibling_runner, Seam.get(:projects_overview_runner),
           Seam.get(:projects_overview_runner, &Overview.load/2)}
        )
      end)

      assert_receive {:sibling_runner, sibling_runner, sibling_default}
      assert sibling_runner != fixture
      assert is_nil(sibling_runner)
      assert sibling_default == (&Overview.load/2)
    end
  end

  # Per-process (spawn-chain) isolation of the config dir and the project
  # registry, plus the onboarding marker that keeps `/projects` from
  # redirecting to `/welcome`.
  defp setup_isolated_runtime(%{conn: conn}) do
    EvoDash.Test.ConfigDir.isolate!("evodash_seam_scope_config")
    EvoDash.Test.IsolatedVCT.isolate!()
    EvoGit.Config.VersionState.complete_onboarding()
    EvoDash.ActiveTasks.invalidate(nil, node())
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  # A real repository, MOUNTED in this test's private registry, so the page
  # selects it as the active project and the overview read actually spawns.
  # Its own template (one empty commit) rather than the Projects suite's shared
  # `:persistent_term` slot, which belongs to whichever module installed last.
  defp setup_project_dir(_context) do
    path = Path.join(System.tmp_dir!(), "evogit_seam_scope_" <> unique())
    File.mkdir_p!(path)
    on_exit(fn -> EvoDash.Test.FsCleanup.rm_rf!(path) end)
    git!(path)

    {:ok, mount} = EvoGit.VCT.ensure_mount("vct:///projects/seam-scope", path, name: "seam-scope")
    assert mount.path == path

    {:ok, project_path: path}
  end

  defp git!(path) do
    {_, 0} = System.cmd("git", ["init", path], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=t@example.com",
          "-c",
          "user.name=t",
          "commit",
          "--allow-empty",
          "-m",
          "init"
        ],
        cd: path,
        stderr_to_stdout: true
      )

    File.rm_rf!(Path.join(path, ".git/hooks"))
    path
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp put_app_env(key, value) do
    Application.put_env(:evo_dash, key, value)
    on_exit(fn -> Application.delete_env(:evo_dash, key) end)
    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid, @wait_budget_ms).socket.assigns

  defp wait_until(view, predicate, timeout_ms \\ @wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      cond do
        predicate.(assigns(view)) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("wait_until timed out. Last assigns: #{inspect(assigns(view))}")

        true ->
          Process.sleep(2)
          poll.(poll)
      end
    end

    poll.(poll)
  end
end
