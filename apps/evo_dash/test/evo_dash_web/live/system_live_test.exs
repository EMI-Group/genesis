# System-page suite — SPLIT ACROSS MODULES FOR PARALLELISM.
#
# ExUnit parallelises across MODULES, never within one, so the suite is
# partitioned into ONE `async: true` module plus ONE `async: false` module (and a
# helper module) for the tests that write process-global state. Every test body,
# assertion and comment is carried over unchanged; only module boilerplate and the
# config-dir isolation moved.
#
# A test is SYNC when it writes a mutable PROCESS-GLOBAL that another `async: true`
# module also uses (symmetric: a writer must never run next to a reader):
#
#   * `:platform_os_override` — also written by the ASYNC
#     `evo_dash_web/live/platform_info_test.exs`. Blocks the whole "platform
#     gating" describe and the "system self-check" describe (its
#     `set_windows_platform/0`).
#   * `EvoDash.UpdateStatus` (a global GenServer hub) together with
#     `:update_notify_only_override`, `:desktop_release` and the `:update_*`
#     seams — also written by the ASYNC `evo_dash/update_status_test.exs`. Blocks
#     the whole "software update card" describe.
#   * `EvoGit.AgentScheduler.pause/0` + a broadcast on the global
#     "scheduler_config" topic — the moved "scheduler_config broadcast …" test.
#   * TEST-OWNED ETS call counters inside a process-global
#     `:system_samples_runner` closure that any concurrently mounting /system page
#     also invokes — the two moved "a failed seed retries …" tests.
#   * a BLOCKING `:source_status_runner` closure that signals its own pid for an
#     `assert_receive`, likewise invoked by any concurrently mounting /system page
#     — the moved "status load shows the loading spinner …" test.
#
# Neither `:system_checks_runner` / `:system_samples_runner` / `:source_*_runner`
# nor the `EvoDash.ActiveTasks` hub blocks the flip: no other ASYNC module writes
# those keys (only this file family does), their values are inert for a
# concurrently mounting foreign page, and `EvoDashWeb.ConnCase` already resets
# `ActiveTasks` per test for every suite.
#
#   Module (async?)            Tests  Globals OWNED / why sync
#   ---------------------------------------------------------------------------
#   .Helpers            (none)     –  shared helpers + `@poll_ms`
#   SystemLiveTest      (true)    26  :system_checks_runner,
#                                     :system_samples_runner (this file only)
#   SystemLiveSyncTest  (false)   30  :platform_os_override, EvoDash.UpdateStatus
#                                     + :update_* + :desktop_release, local
#                                     AgentScheduler.pause/0 + "scheduler_config"
#                                     broadcast, ETS counters, blocking runner
#
# CONFIG DIR: every test that WRITES the config dir (remote-connection targets)
# isolates it PER PROCESS through the test-only `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1`, installed by test/test_helper.exs) —
# never a BEAM-global `XDG_CONFIG_HOME` write. `<override>/genesis` is the same
# layout the old env-var redirect produced, so no assertion changed.
#
# DEFINITION ORDER IS LOAD-BEARING: an `async: true` module's tests can run
# while the REST of this file is still being loaded, so a module defined BELOW
# them may not exist yet when one of those tests calls `start_supervised!/1`
# on it ("The module … was given as a child to a supervisor but it does not
# exist"). Every module these tests reference is defined ABOVE the case
# modules, starting with this fake connection manager.

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.ProjectsLiveTest.ConnectionManager). Registers a status so
# `EvoDash.NodeContext.connection_status/1` resolves the `?node=` param to a
# connected remote context without any real SSH/distribution machinery. The
# process dies (and its Registry entry is auto-removed) at test end via
# `start_supervised!`.
defmodule EvoDashWeb.SystemLiveTest.ConnectionManager do
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
end

defmodule EvoDashWeb.SystemLiveTest.Helpers do
  @moduledoc false
  # Helpers shared by BOTH system-page suite modules (imported as
  # `EvoDashWeb.SystemLiveTest.Helpers`). Public instead of private because the
  # suite is split across modules; bodies are unchanged.
  #
  # `Phoenix.LiveViewTest.live/2` is a MACRO that expands to `__live__(get(conn,
  # path), …)`, so a helper calling it needs `get/2` — in a ConnCase module that
  # arrives via `use EvoDashWeb.ConnCase`, here explicitly (same idiom as
  # `EvoDashWeb.ReviewLiveTest.Helpers`).
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import ExUnit.Callbacks

  # `get/3` (expanded from `live/2`) dispatches to the test case's `@endpoint`,
  # which `use EvoDashWeb.ConnCase` sets in the TEST module — this helper module
  # needs its own copy because the macro is expanded HERE.
  @endpoint EvoDashWeb.Endpoint

  # Poll interval for every bounded await below (1 ms, not the old 10 ms): the
  # awaits are bounded by generous timeouts, so a fine cadence only removes dead
  # time between an async result and its observation. The bounded-poll SHAPE and
  # every timeout are unchanged.
  @poll_ms 1

  # alpha (used 2 / waiting 1 / capacity 4) + beta (used 0 / waiting 3 /
  # capacity 0). Sorted ids are ["alpha", "beta"], so the deterministic
  # default selection is "alpha" and beta's distinctive legend last-value is
  # "Waiting" = 3.
  def two_model_sample do
    sample_map(llm_slots: llm_slots(%{"beta" => %{used: 0, waiting: 3, capacity: 0}}))
  end

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as projects_live_test.exs / welcome_live_test.exs).
  def assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Waits until the async self-check task spawned on mount has processed its
  # real `{:system_checks_result, _}` (i.e. `system_checks_status` leaves
  # `:checking`). The handler simply assigns, so the LAST such message
  # processed wins — awaiting the real result first guarantees an injected
  # result below is deterministically processed last (FIFO mailbox), no matter
  # how fast/slow the real check completes on the host.
  def await_checks_done(view, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_checks_done(view, deadline)
  end

  def do_await_checks_done(view, deadline) do
    cond do
      assigns(view)[:system_checks_status] == :done ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("system self-check did not complete within the test timeout")

      true ->
        Process.sleep(@poll_ms)
        do_await_checks_done(view, deadline)
    end
  end

  # Waits until the chart ring buffer is non-empty (`chart_samples`). Samples
  # arrive either from a `{:system_sample, ...}` broadcast (applied
  # synchronously by the handler) or from the async seed RPC — poll until the
  # handler has applied one.
  def await_chart_sample(view, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_chart_sample(view, deadline)
  end

  def do_await_chart_sample(view, deadline) do
    cond do
      assigns(view)[:chart_samples] != [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no chart sample appeared within the test timeout")

      true ->
        Process.sleep(@poll_ms)
        do_await_chart_sample(view, deadline)
    end
  end

  # A full 12-key sample map as emitted by the evo_git system sampler (the
  # "system" topic contract). Overrides let tests vary individual keys.
  #
  # Since the LLM-slots rework the sample also carries `llm_slots` (the
  # per-model map the LLM Slots chart plots — model ids are config-profile id
  # STRINGS, inner keys are atoms). The default carries one model profile
  # ("alpha"); tests override/augment via the `llm_slots/1` helper below. A
  # legacy 12-key sample WITHOUT the `:llm_slots` key is produced by
  # `Map.delete(sample_map(), :llm_slots)`.
  def sample_map(overrides) do
    Map.merge(
      %{
        llm_used: 0,
        llm_waiting: 0,
        llm_capacity: 4,
        tool_used: 0,
        tool_waiting: 0,
        tool_capacity: 2,
        agents_total: 0,
        agents_running: 0,
        agents_blocked: 0,
        agents_waiting: 0,
        agents_pending: 0,
        scheduler_alive: true,
        llm_slots: llm_slots()
      },
      Map.new(overrides)
    )
  end

  # Fake per-model LLM slot data (`llm_slots`) for the charts. Default carries
  # one model profile ("alpha": used 2 / waiting 1 / capacity 4); the override
  # map is merged on top so tests augment with more profiles (e.g.
  # `llm_slots(%{"beta" => %{used: 0, waiting: 3, capacity: 0}})` yields
  # alpha + beta) or replace entries wholesale.
  def llm_slots(overrides \\ %{}) do
    Map.merge(%{"alpha" => %{used: 2, waiting: 1, capacity: 4}}, overrides)
  end

  # Extracts (label, last-value) pairs from every chart legend on the page. The
  # legend markup (charts.ex `chart_card/1`) is a `<span
  # class="text-base-content/70">Label</span>` immediately followed by `<span
  # class="font-semibold text-base-content/90">Value</span>` — the only place
  # on the page where those two classes are adjacent, so the regex captures
  # legend entries only (asserting exact last values, e.g. the LLM Slots
  # card's per-model "Waiting" count).
  def legend_last_values(html) do
    ~r/<span class="text-base-content\/70">([^<]*)<\/span>\s*<span class="font-semibold text-base-content\/90">([^<]*)<\/span>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, label, value] -> {label, value} end)
  end

  # Injects a system-checks result directly into the LiveView mailbox and
  # renders. The self-check rows only render once `system_checks_status` leaves
  # `:checking`; the injected result is processed after the real async one, so
  # it is what the assertions see (same send+render pattern as the
  # "LLM Test in Settings link" test, made deterministic by `await_checks_done`).
  def render_with_checks(view, result) do
    await_checks_done(view)
    send(view.pid, {:system_checks_result, result})
    render(view)
  end

  # Builds a full checks result with the given nix check map (all other checks
  # come from the real host, so the nix row assertions are independent of host
  # config).
  def render_with_nix_check(view, nix_check) do
    render_with_checks(view, %{all_ok_checks() | nix: nix_check})
  end

  # Deterministic all-OK checks map for the self-check grid/banner assertions.
  # Every check passes, so the merged health light is green regardless of the
  # host (a real `run_all_checks/0` on CI may legitimately report failing
  # tools/config/sandbox). The sandbox map is a safe `:none` backend — with the
  # :windows platform override the cell is hidden and the map is never read by
  # the template, but supplying it keeps the assign well-formed.
  def all_ok_checks do
    %{
      config: %{ok?: true, missing: [], warnings: [], validation_errors: []},
      tools: %{
        git: %{available: true, path: "/usr/bin/git", version: "git version 2.0.0", error: nil},
        rg: %{available: true, path: "/usr/bin/rg", version: "ripgrep 14.1.0", error: nil}
      },
      sandbox: %{
        backend: :none,
        enabled: false,
        capabilities: %{filesystem_isolation: false, resource_limits: false, backend: :none},
        systemd_available: false,
        sandbox_exec_available: false
      },
      supervisor: %{healthy: true, evo_git: [], evo_dash: []},
      nix: %{
        enabled: false,
        available: false,
        flake_present: false,
        dev_env_built: false,
        error: nil
      }
    }
  end

  # `:platform_os_override` is the injection seam for `os_for_node/1` (checked
  # BEFORE host detection): set to :windows it hides the Sandbox cell, so the
  # merged health banner never depends on the host's sandbox state (on Linux CI
  # the real sandbox check can be :error, which would hard-fail the banner).
  # Safe only in `async: false` files; cleaned up via `on_exit`.
  def set_windows_platform do
    Application.put_env(:evo_dash, :platform_os_override, :windows)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :platform_os_override)
    end)
  end

  # Floki-scopes the self-check term grid so disclosure assertions never see
  # the app layout's sidebar `<details>` theme dropdown (layouts.ex). The grid
  # container is `<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">`
  # (system_live.ex); the charts grid uses the same classes plus `p-4`, so the
  # exact-match attribute selector matches only the check grid.
  def check_grid(html) do
    [grid] =
      Floki.find(
        Floki.parse_document!(html),
        ~s(div[class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3"])
      )

    grid
  end

  # --- Software Update card test helpers ------------------------------------

  # Restores an Application env (handles a stored `false` value correctly —
  # `if value` would wrongly delete it). Mirrors update_status_test.exs.
  def restore_env_value(key, original) do
    if original != nil do
      Application.put_env(:evo_dash, key, original)
    else
      Application.delete_env(:evo_dash, key)
    end
  end

  # The desktop-shell flag for the update card (restored by the setup on_exit).
  def set_desktop do
    Application.put_env(:evo_dash, :desktop_release, true)
  end

  # --- Genesis Source card test helpers -------------------------------------

  # A full Genesis Source status map as emitted by the
  # `EvoGit.SelfReflectiveSource.status/0` backend contract (see SourceCard).
  # Overrides let tests vary individual keys.
  def source_status, do: source_status(%{})

  def source_status(overrides) do
    Map.merge(
      %{
        dir: "/tmp/genesis-source",
        exists: true,
        is_git_repo: true,
        valid: true,
        commit: "deadbeef",
        branch: "feature/source",
        version: "9.9.9",
        remote_url: "https://example.com/genesis.git",
        reference: nil,
        is_reference: false
      },
      Map.new(overrides)
    )
  end

  # The status of a checkout that has never been cloned (no commit/branch/etc.).
  def not_cloned_status do
    source_status(%{exists: false, commit: nil, branch: nil, version: nil, remote_url: nil})
  end

  # Mounts the System page in a connected remote-node context (same pattern as
  # the update card's "card is hidden when viewing a remote node" test and the
  # "LLM Test in Settings link" test): isolates the config dir PER PROCESS so
  # the saved target never touches the developer's real ~/.config/genesis/,
  # registers a fake connection manager so the `?node=` param resolves to a
  # connected remote context, and returns `{view, html}` from `live/3`.
  def mount_remote_system(conn) do
    # Per-process config dir — never the BEAM-global `XDG_CONFIG_HOME`: the
    # override is activated in the TEST process (the caller of this helper) and
    # the mounted page inherits it through OTP's `:"$callers"` chain.
    EvoDash.Test.ConfigDir.isolate!("evogit_system_test_config")

    id = "test-target-#{System.unique_integer([:positive])}"

    {:ok, _target} =
      EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.RemoteConnections.delete(id)
      rescue
        _ -> :ok
      end
    end)

    start_supervised!(
      {EvoDashWeb.SystemLiveTest.ConnectionManager,
       {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
    )

    live(conn, "/system?node=" <> id)
  end

  # Resets the shared hub and synchronizes: the reset is a cast, so the
  # following `phase()` call (same process) is guaranteed to observe it.
  def reset_hub_to_idle do
    EvoDash.UpdateStatus.reset()
    assert await_hub_phase(:idle) == :ok
  end

  # Polls the hub until it reaches the given phase. A cast followed by a call
  # from this process is ordered, so the first poll already reflects the cast.
  def await_hub_phase(phase, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_hub_phase(phase, deadline)
  end

  def do_await_hub_phase(phase, deadline) do
    if EvoDash.UpdateStatus.phase() == phase do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("update hub did not reach phase #{inspect(phase)} within the test timeout")
      else
        Process.sleep(@poll_ms)
        do_await_hub_phase(phase, deadline)
      end
    end
  end

  # Polls the LiveView's `@update_status` assign until its phase matches (the
  # hub broadcast is assigned via the `{:update_status, state}` handle_info).
  def await_update_phase(view, phase, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_update_phase(view, phase, deadline)
  end

  def do_await_update_phase(view, phase, deadline) do
    if assigns(view).update_status.phase == phase do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view).update_status.phase

        flunk(
          "update status did not reach phase #{inspect(phase)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(@poll_ms)
        do_await_update_phase(view, phase, deadline)
      end
    end
  end

  # Polls the LiveView's `@update_status` assign until its error matches. Needed
  # for consecutive same-phase transitions (e.g. :error → :error): the
  # phase-only await above can return on the PREVIOUS state's broadcast, and
  # the following render would show stale HTML. Awaiting the error value
  # discriminates the two states.
  def await_update_error(view, error, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_update_error(view, error, deadline)
  end

  def do_await_update_error(view, error, deadline) do
    if assigns(view).update_status.error == error do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view).update_status.error

        flunk(
          "update status did not reach error #{inspect(error)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(@poll_ms)
        do_await_update_error(view, error, deadline)
      end
    end
  end

  # Polls the LiveView's `@update_status` assign with an arbitrary predicate —
  # needed when consecutive hub transitions share a phase/error (e.g. an empty
  # vs absent changelog body), where the phase-only awaits would return on the
  # PREVIOUS state's broadcast.
  def await_update_status(view, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_update_status(view, predicate, deadline)
  end

  def do_await_update_status(view, predicate, deadline) do
    if predicate.(assigns(view).update_status) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("update status predicate did not match within the test timeout")
      else
        Process.sleep(@poll_ms)
        do_await_update_status(view, predicate, deadline)
      end
    end
  end

  # Polls any socket assign until it equals the expected value (modal flags).
  def await_view_assign(view, key, value, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_view_assign(view, key, value, deadline)
  end

  # Polls an ETS integer counter until it reaches the expected value (used for
  # deterministic proofs where a transient phase window is too short to await).
  def await_ets_count(table, key, expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_ets_count(table, key, expected, deadline)
  end

  def do_await_ets_count(table, key, expected, deadline) do
    if :ets.lookup_element(table, key, 2) >= expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = :ets.lookup_element(table, key, 2)

        flunk(
          "ETS counter #{inspect(key)} did not reach #{expected} within the test timeout (got #{got})"
        )
      else
        Process.sleep(@poll_ms)
        do_await_ets_count(table, key, expected, deadline)
      end
    end
  end

  def do_await_view_assign(view, key, value, deadline) do
    if assigns(view)[key] == value do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view)[key]

        flunk(
          "assign #{inspect(key)} did not reach #{inspect(value)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(@poll_ms)
        do_await_view_assign(view, key, value, deadline)
      end
    end
  end

  # Drives the hub to :available (synchronized) — shared setup for the
  # download/apply tests.
  def drive_hub_to_available do
    EvoDash.UpdateStatus.handle_check_result(%{
      "status" => "available",
      "version" => "1.2.3",
      "body" => "release notes",
      "current_version" => "0.1.0"
    })

    await_hub_phase(:available)
  end

  def drive_hub_to_ready do
    drive_hub_to_available()
    EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
    await_hub_phase(:ready)
  end
end

defmodule EvoDashWeb.SystemLiveTest do
  # `async: true` — see the file header for the per-test-sync exceptions. What
  # this module owns: `:system_checks_runner` + `:system_samples_runner` (grep:
  # no other suite writes them) and the pure/`?node=`-scoped page tests.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EvoDashWeb.SystemLiveTest.Helpers

  setup do
    # Hermetic + fast mounts: every page mount spawns the system self-check and
    # the chart seed. Both seams are injected here (re-resolved AT
    # CALL/SPAWN TIME, so a test may override them for its own mount) — the real
    # self-check shells out to the tool probes (~9 ms) and the default seed reads
    # the VM-wide sampler ring buffer, which makes chart-buffer assertions
    # host-dependent.
    #
    # Both keys are owned by THIS file family alone: no other `async: true`
    # module writes them, and their values are inert for a concurrently mounting
    # foreign page (an all-OK check map / an empty sample list). A test's own
    # override is restored by the `on_exit` below.
    #
    # Deliberately NOT here: `EvoDash.UpdateStatus` and the `:update_*` /
    # `:desktop_release` / `:update_notify_only_override` seams (shared with the
    # async `evo_dash/update_status_test.exs` — they live in the sync module) and
    # `EvoDash.ActiveTasks` (reset per test by `EvoDashWeb.ConnCase`).
    originals =
      Map.new([:system_checks_runner, :system_samples_runner], fn key ->
        {key, Application.get_env(:evo_dash, key)}
      end)

    Application.put_env(:evo_dash, :system_checks_runner, fn -> all_ok_checks() end)
    Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, []} end)

    on_exit(fn ->
      Enum.each(originals, fn {key, original} -> restore_env_value(key, original) end)
    end)

    :ok
  end

  describe "system page" do
    test "LLM Test in Settings link carries &node=<id> when a remote node is active", %{
      conn: conn
    } do
      # The settings link already carries a query string (`?category=llm`), so
      # the node param must be appended with `&node=` — `with_node_param/2`
      # would append with `?` and the browser would silently drop the node
      # param (parsing it as part of the `category` value), landing the remote
      # user on the LOCAL settings page.
      #
      # Same pattern as projects_live_test.exs: isolate the config dir PER
      # PROCESS so the saved target never touches the developer's real
      # ~/.config/genesis/, and register a fake connection manager so the
      # `?node=` param resolves to a connected remote context.
      # Per-process config dir — never the BEAM-global `XDG_CONFIG_HOME`: the
      # override is activated in THIS process, and the mounted page plus its
      # supervised loads inherit it through OTP's `:"$callers"` chain
      # (`<dir>/genesis` is the same layout the old env redirect produced).
      EvoDash.Test.ConfigDir.isolate!("evogit_system_test_config")

      id = "test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.RemoteConnections.delete(id)
        rescue
          _ -> :ok
        end
      end)

      start_supervised!(
        {EvoDashWeb.SystemLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/system?node=" <> id)

      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:remote?] == true

      # The system self-check runs async and gates the LLM Test row on
      # completion; drive it deterministically so the link renders.
      send(view.pid, {:system_checks_result, all_ok_checks()})
      html = render(view)

      # The `~p` sigil percent-encodes the interpolated query suffix:
      # `%26node%3D` decodes to `&node=` in the browser, so the node param is
      # preserved alongside the existing `category=llm` query — unlike the old
      # `?node=` form, which the browser parsed into the `category` value and
      # silently dropped.
      assert html =~ ~s(href="/settings?category=llm%26node%3D#{id}")
      # The old (would-be-dropped) `?node=` form must never be emitted
      refute html =~ ~s(href="/settings?category=llm?node=)
    end
  end

  # NOTE: The LOCAL "confirm_restart"/"confirm_stop" event handlers are
  # intentionally NOT unit-tested. They call System.restart/0 / System.stop/0,
  # which tears down / shuts down the entire BEAM VM and would crash the ExUnit
  # test run (killing all other tests along with it). The REMOTE variants are
  # tested via direct handle_event/3 invocation with a non-local current_node —
  # the erpc call to a non-existent remote node fails gracefully inside
  # restart_remote/stop_remote (which always returns :ok), so it's safe to run.
  # We also test the surrounding modal open/cancel flows, which are safe.

  describe "scheduler and system controls" do
    test "scheduler control renders with the pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ ~s(phx-click="toggle_pause")
    end

    test "System Control section renders its Restart/Stop buttons and both modals open+close",
         %{conn: conn} do
      # ONE mount for the four modal open/close paths (the documented
      # `render_click(view, "request_X")` opens / `cancel_X` closes idiom): the
      # section markup and both danger-confirmation modals are independent
      # renders of the same page, so no per-modal mount is needed.
      {:ok, view, html} = live(conn, ~p"/system")

      assert html =~ "System Control"
      assert html =~ "Restart System"
      assert html =~ ~s(phx-click="request_restart")
      assert html =~ "Stop System"
      assert html =~ ~s(phx-click="request_stop")

      # Both modals are invisible on the initial render.
      refute html =~ "Restart System?"
      refute html =~ "Stop System?"

      # Restart: open, then close.
      assert render_click(view, "request_restart") =~ "Restart System?"
      refute render_click(view, "cancel_restart") =~ "Restart System?"

      # Stop: open, then close.
      assert render_click(view, "request_stop") =~ "Stop System?"
      refute render_click(view, "cancel_stop") =~ "Stop System?"
    end

    test "confirm_restart restarts the remote node via RPC when remote" do
      # ISSUE 2 fix: confirm_restart now operates on the REMOTE node via
      # EvoDash.NodeContext.restart_remote/1 (erpc RPC) instead of refusing.
      #
      # We test by invoking the handle_event/3 callback with a socket that has
      # remote?: true and a non-local current_node. This avoids calling
      # System.restart/0 on the LOCAL test VM (which would tear it down). The
      # erpc call to the non-existent remote node fails gracefully inside
      # restart_remote/1 (it normalizes the node-down error and always returns
      # :ok), so this is safe to run. The handler should close the modal and
      # show an info flash about the remote node restarting.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote?: true,
          current_node: :nonexistent_remote@host,
          show_restart_confirm: true
        }
      }

      assert {:noreply, pending_socket} =
               SystemLive.handle_event("confirm_restart", %{}, socket)

      # The remote action runs in an EvoDash.SafeCall task that reports
      # {{:system_action_result, node, action}, result} to the caller; the
      # modal closes and the flash lands in handle_info, never in the click reply.
      assert pending_socket.assigns.system_action == :restarting

      assert_receive {{:system_action_result, :nonexistent_remote@host, :restarting}, _result},
                     5000

      assert {:noreply, result_socket} =
               SystemLive.handle_info(
                 {{:system_action_result, :nonexistent_remote@host, :restarting}, {:ok, :ok}},
                 pending_socket
               )

      # Modal closed + in-flight marker cleared
      refute result_socket.assigns.show_restart_confirm
      assert result_socket.assigns.system_action == nil
      # Info flash about remote restart (not an error flash)
      assert %{"info" => _} = result_socket.assigns.flash
    end

    test "confirm_stop stops the remote node via RPC when remote" do
      # ISSUE 2 fix: confirm_stop now operates on the REMOTE node via
      # EvoDash.NodeContext.stop_remote/1 (erpc RPC) instead of refusing.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote?: true,
          current_node: :nonexistent_remote@host,
          show_stop_confirm: true
        }
      }

      assert {:noreply, pending_socket} =
               SystemLive.handle_event("confirm_stop", %{}, socket)

      # Same async contract as confirm_restart: the result arrives as a
      # {{:system_action_result, node, action}, result} message.
      assert pending_socket.assigns.system_action == :stopping

      assert_receive {{:system_action_result, :nonexistent_remote@host, :stopping}, _result}, 5000

      assert {:noreply, result_socket} =
               SystemLive.handle_info(
                 {{:system_action_result, :nonexistent_remote@host, :stopping}, {:ok, :ok}},
                 pending_socket
               )

      # Modal closed + in-flight marker cleared
      refute result_socket.assigns.show_stop_confirm
      assert result_socket.assigns.system_action == nil
      # Info flash about remote stop (not an error flash)
      assert %{"info" => _} = result_socket.assigns.flash
    end
  end

  describe "Status sandbox helpers — bwrap" do
    # Pure function calls into EvoDashWeb.SystemLive.Status — no LiveView
    # harness needed (same style as the other helper unit tests).
    alias EvoDashWeb.SystemLive.Status

    test "format_backend/1 maps :bwrap to its display name" do
      assert Status.format_backend(:bwrap) == "bwrap (Linux)"
    end

    test "sandbox_status/1 treats bwrap with filesystem isolation as ok" do
      assert Status.sandbox_status(%{
               backend: :bwrap,
               enabled: true,
               capabilities: %{filesystem_isolation: true}
             }) == :ok
    end

    test "sandbox_status/1 errors when bwrap lacks filesystem isolation" do
      assert Status.sandbox_status(%{
               backend: :bwrap,
               enabled: true,
               capabilities: %{filesystem_isolation: false}
             }) == :error
    end
  end

  describe "scheduler status charts" do
    test "renders the Scheduler Status section with placeholder cards on initial render", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Scheduler Status"
      assert html =~ ~s(<h3 class="font-semibold text-sm">LLM Slots</h3>)
      assert html =~ ~s(<h3 class="font-semibold text-sm">Tool Slots</h3>)
      assert html =~ ~s(<h3 class="font-semibold text-sm">Agents</h3>)
      # The static mount has no samples yet — every card shows the
      # collecting-data placeholder and no SVG chart (the only <svg> elements
      # on the page come from the chart cards' SVG branch).
      assert html =~ "Collecting data…"
      refute html =~ "<svg"
    end

    test "a system sample broadcast appends to the chart buffer and renders", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/system")

      sample = sample_map(llm_used: 1, tool_used: 1, agents_total: 2, agents_running: 1)

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "system", {:system_sample, node(), 1, sample})

      assert await_chart_sample(view) == :ok
      assert List.last(assigns(view)[:chart_samples]) == sample

      html = render(view)

      assert html =~ "<svg"
      refute html =~ "Collecting data…"
    end

    test "a foreign-node system sample broadcast is ignored", %{conn: conn} do
      # Make the test hermetic: the mount's async seed RPC must not fill the
      # chart buffer. The default runner reads the real EvoGit.SystemSampler
      # ring buffer, which is non-empty whenever a sampler tick has occurred in
      # this VM (real user config, capacities 25/8) — stubbing it to fail makes
      # the assertion depend only on the foreign-sample filter. (The file-level
      # setup block restores this env in on_exit.)
      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        {:error, :not_implemented}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The foreign sample carries `llm_slots` with TWO model profiles — if it
      # were (wrongly) applied, the buffer would fill and the selection would
      # default to "alpha". The node filter must drop it wholesale: buffer
      # stays empty and the selection stays nil.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "system",
        {:system_sample, :remote@elsewhere, 1,
         sample_map(
           llm_used: 9,
           llm_slots: llm_slots(%{"beta" => %{used: 0, waiting: 3, capacity: 0}})
         )}
      )

      render(view)

      assert assigns(view)[:chart_samples] == []
      assert assigns(view)[:selected_llm_model] == nil
    end

    test "the seed RPC fills the chart buffer preserving order", %{conn: conn} do
      samples = [sample_map(llm_used: 1), sample_map(llm_used: 2)]

      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, samples} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert await_view_assign(view, :chart_samples, samples, 6_000) == :ok
    end

    test "the seed RPC caps the chart buffer at 60 samples", %{conn: conn} do
      samples = for i <- 1..65, do: sample_map(llm_used: i)

      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, samples} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert await_view_assign(view, :chart_samples, Enum.take(samples, -60), 6_000) == :ok
    end

    test "node switch clears the chart buffer and re-seeds for the new node", %{conn: conn} do
      # Same remote scaffolding as the scheduler_config broadcast test:
      # isolate the config dir PER PROCESS and register a fake connection
      # manager so the `?node=` param resolves to a connected remote context.
      # Per-process config dir — never the BEAM-global `XDG_CONFIG_HOME`: the
      # override is activated in THIS process, and the mounted page plus its
      # supervised loads inherit it through OTP's `:"$callers"` chain
      # (`<dir>/genesis` is the same layout the old env redirect produced).
      EvoDash.Test.ConfigDir.isolate!("evogit_system_test_config")

      id = "test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.RemoteConnections.delete(id)
        rescue
          _ -> :ok
        end
      end)

      start_supervised!(
        {EvoDashWeb.SystemLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      local_sample = sample_map(llm_used: 1)
      remote_sample = sample_map(llm_used: 2)

      Application.put_env(:evo_dash, :system_samples_runner, fn node ->
        if node == node(), do: {:ok, [local_sample]}, else: {:ok, [remote_sample]}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The local node's seed fills the buffer.
      assert await_view_assign(view, :chart_samples, [local_sample], 6_000) == :ok

      # Switch to the remote node: buffer cleared + a fresh seed for the new
      # node (a stale local seed result, if any, is dropped by the node
      # stale-guard).
      render_patch(view, "/system?node=" <> id)

      assert await_view_assign(view, :chart_samples, [remote_sample], 6_000) == :ok
    end

    # ── Per-model LLM Slots chart (llm_slots rework) ──────────────────────────

    # The two-model `llm_slots` payload used by most per-model chart tests:
    test "select_llm_model switches the LLM chart to the selected model's series", %{
      conn: conn
    } do
      # Hermetic: the mount's async seed RPC must not fill the buffer.
      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      sample = two_model_sample()
      send(view.pid, {:system_sample, node(), 1, sample})
      assert await_chart_sample(view) == :ok

      # Two model ids → the dropdown selector renders, and the default
      # selection is the first SORTED id ("alpha"): alpha's legend last-values
      # show (capacity 4 / waiting 1), beta's do not.
      html = render(view)

      assert html =~ ~s(<select name="model" phx-change="select_llm_model")
      assert html =~ ~s(<option value="alpha" selected)
      assert html =~ ~s(<option value="beta">)

      legends = legend_last_values(html)
      assert {"Capacity", "4"} in legends
      assert {"Waiting", "1"} in legends
      refute {"Waiting", "3"} in legends
      assert assigns(view)[:selected_llm_model] == "alpha"

      # Pick beta in the dropdown → the LLM chart plots beta's series only.
      html = render_change(view, "select_llm_model", %{"model" => "beta"})

      assert assigns(view)[:selected_llm_model] == "beta"
      # The beta option is now the preselected one.
      assert html =~ ~s(<option value="beta" selected)
      refute html =~ ~s(<option value="alpha" selected)
      # Beta's waiting (3) renders; alpha's values (capacity 4 / waiting 1)
      # are gone from the LLM card legends.
      legends = legend_last_values(html)
      assert {"Waiting", "3"} in legends
      refute {"Capacity", "4"} in legends
      refute {"Waiting", "1"} in legends
    end

    test "the seed fill defaults the LLM model selection to the first sorted id", %{
      conn: conn
    } do
      sample = two_model_sample()

      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, [sample]} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # Seed fill (async, budgeted like the other seed tests) resolves the
      # selection deterministically to the first sorted id ("alpha").
      assert await_view_assign(view, :selected_llm_model, "alpha", 6_000) == :ok
      assert await_view_assign(view, :chart_samples, [sample], 6_000) == :ok

      # Two ids → the in-card dropdown selector renders both models, with the
      # resolved selection ("alpha") preselected.
      html = render(view)
      assert html =~ ~s(<select name="model" phx-change="select_llm_model")
      assert html =~ ~s(<option value="alpha" selected)
      assert html =~ ~s(<option value="beta">)
    end

    test "a legacy sample without llm_slots leaves the selection nil and never wedges the charts",
         %{conn: conn} do
      # Legacy sampler sample: the 12 aggregate keys, NO `:llm_slots` — via the
      # SEED path on mount, then again via a live push.
      legacy = sample_map(tool_used: 1, agents_total: 2) |> Map.delete(:llm_slots)
      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, [legacy]} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert await_view_assign(view, :chart_samples, [legacy], 6_000) == :ok

      # No model ids are known → no selection and no selector markup (neither
      # the dropdown nor the single-model muted label).
      assert assigns(view)[:selected_llm_model] == nil

      html = render(view)
      refute html =~ "select_llm_model"
      refute html =~ ~s(<select name="model")
      refute html =~ "alpha"
      # The LLM card still renders (its series are all zeros).
      assert html =~ "<svg"
      refute html =~ "Collecting data…"

      # A subsequent two-model sample arriving via live push still works (no
      # wedged state): alpha is now selected and the chart plots per-model data.
      sample = two_model_sample()
      send(view.pid, {:system_sample, node(), 1, sample})
      assert await_view_assign(view, :chart_samples, [legacy, sample]) == :ok
      assert assigns(view)[:selected_llm_model] == "alpha"
    end

    test "node switch clears the chart buffer and resets the LLM model selection", %{
      conn: conn
    } do
      remote_sample = two_model_sample()

      # Remote node seed fills the buffer with the two-model sample; the LOCAL
      # node seed fails (buffer stays empty after the switch — deterministic).
      Application.put_env(:evo_dash, :system_samples_runner, fn node ->
        if node == node(), do: {:error, :not_implemented}, else: {:ok, [remote_sample]}
      end)

      {:ok, view, _html} = mount_remote_system(conn)

      # Remote seed fills the buffer; default selection = first sorted id.
      assert await_view_assign(view, :selected_llm_model, "alpha", 6_000) == :ok
      assert await_view_assign(view, :chart_samples, [remote_sample], 6_000) == :ok

      # Pick beta in the dropdown.
      render_change(view, "select_llm_model", %{"model" => "beta"})

      assert assigns(view)[:selected_llm_model] == "beta"

      # Switch back to the local node: the ring buffer is cleared and the
      # selection resets to nil (charts never mix samples across nodes).
      render_patch(view, "/system")

      assert assigns(view)[:chart_samples] == []
      assert assigns(view)[:selected_llm_model] == nil
    end

    test "the selected model is kept while present and clamps to the first id when dropped", %{
      conn: conn
    } do
      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      both = two_model_sample()
      send(view.pid, {:system_sample, node(), 1, both})
      assert await_chart_sample(view) == :ok
      assert assigns(view)[:selected_llm_model] == "alpha"

      # Select beta in the dropdown.
      render_change(view, "select_llm_model", %{"model" => "beta"})

      assert assigns(view)[:selected_llm_model] == "beta"

      # Further samples still carrying beta keep the selection.
      send(view.pid, {:system_sample, node(), 2, both})
      assert await_view_assign(view, :chart_samples, [both, both]) == :ok
      assert assigns(view)[:selected_llm_model] == "beta"

      # 61 alpha-only samples age the beta sample out of the ring buffer (60
      # sample cap): the model-id union no longer contains beta, so the
      # selection clamps to the first available id ("alpha").
      alpha_only = sample_map(llm_slots: %{"alpha" => %{used: 2, waiting: 1, capacity: 4}})

      for i <- 3..63 do
        send(view.pid, {:system_sample, node(), i, alpha_only})
      end

      render(view)

      assert length(assigns(view)[:chart_samples]) == 60
      assert assigns(view)[:selected_llm_model] == "alpha"

      # The clamped chart now plots alpha's values (waiting 1), not beta's (3).
      legends = legend_last_values(render(view))
      assert {"Waiting", "1"} in legends
      refute {"Waiting", "3"} in legends
    end
  end

  describe "genesis source card" do
    # The card is local-only and load-on-mount: every test that mounts a LOCAL
    # node spawns an async status load via `:source_status_runner` (resolved at
    # spawn time inside the spawned Task — the same send-pattern seam idiom as
    # the update card's `:update_check_runner`). Tests therefore inject it
    # BEFORE `live/3`; the default runner degrades to
    # `{:unavailable, :module_missing}` when the `EvoGit.SelfReflectiveSource`
    # backend module is absent (it is, in this worktree) and must never be hit.
    # Clone/update flows use the same seam pattern (`:source_clone_runner` /
    # `:source_update_runner`). Those operations need NO artificial delay: their
    # busy state (`source_busy`) is assigned SYNCHRONOUSLY by the event handler,
    # so the `render_click/2` return value already carries "Cloning…"/"Updating…"
    # and the disabled button regardless of how fast the runner returns; the
    # completion is then flushed by polling the socket assigns
    # (`await_view_assign/3`). A runner that must stay in flight for a
    # deterministic window (the loading spinner) signals its start and blocks
    # until the test releases it. `render_async/2` does not await TaskSupervisor
    # children, so polling the assigns is required either way.

    test "card is a local-only peer cell of the self-check grid; not-cloned shows Clone", %{
      conn: conn
    } do
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, not_cloned_status())

      html = render(view)

      # Visibility + placement: a real cell INSIDE the self-check check grid (it
      # hides together with the grid while a re-check is running).
      assert assigns(view)[:source_card_visible] == true
      assert html =~ ~s(id="genesis-source-card")
      assert html =~ "Genesis Source"
      assert html =~ "Genesis source checkout used by the self-reflective agent."
      assert Floki.find(check_grid(html), ~s(div[id="genesis-source-card"])) != []

      # Not-cloned state: Clone only, no Update, no busy label.
      assert html =~ "The Genesis source has not been cloned yet."
      assert html =~ ~s(id="clone-source")
      assert html =~ "Clone"
      refute html =~ "Cloning…"
      refute html =~ ~s(id="update-source")
    end

    test "cloned status renders the checkout details and Update button, no reference line", %{
      conn: conn
    } do
      status = source_status()
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> status end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, status)

      html = render(view)
      assert html =~ "deadbeef"
      refute html =~ "feature/source"
      assert html =~ "9.9.9"
      refute html =~ "https://example.com/genesis.git"
      refute html =~ "Remote URL"
      refute html =~ ">Branch</span>"
      # The redundant reference line is gone — the Directory row already shows
      # the checkout path.
      refute html =~ "The self-reflective agent reads"
      assert html =~ ~s(id="update-source")
      assert html =~ "Update"
      refute html =~ ~s(id="clone-source")
      refute html =~ "in use"
      refute html =~ "An explicit override is in effect"
      assert html =~ ~s(id="system-self-check")
      # The source card is a real cell of the self-check grid
      assert Floki.find(check_grid(html), ~s(div[id="genesis-source-card"])) != []
      # The three system controls (Dashboard + Scheduler + System) are grouped
      # into ONE section
      assert html =~ ~s(id="system-controls")
      assert html =~ "System Dashboard"
      assert html =~ ~s(id="runtime-controls")
      assert html =~ "System Control"
    end

    test "an explicit reference override shows the muted note (carrying the path) and the in-use badge",
         %{
           conn: conn
         } do
      status = source_status(%{reference: "/custom/genesis-root", is_reference: true})
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> status end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, status)

      html = render(view)
      assert html =~ "An explicit override is in effect"
      # The override note carries the actual reference path (info preservation —
      # it differs from the Directory row's managed dir)
      assert html =~ "/custom/genesis-root"
      refute html =~ "The self-reflective agent reads"
      assert html =~ "in use"
    end

    test "card shows the unavailable message when the backend module is missing", %{conn: conn} do
      Application.put_env(:evo_dash, :source_status_runner, fn _ ->
        {:unavailable, :module_missing}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, {:unavailable, :module_missing})

      html = render(view)
      assert html =~ "Genesis source is not available in this version"
      refute html =~ ~s(id="clone-source")
      refute html =~ ~s(id="update-source")
    end

    test "clone flow: busy state, an error flash on failure, then a success refreshes the status",
         %{conn: conn} do
      cloned = source_status(%{commit: "cafebabe"})
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      # No artificial delay: the busy state asserted below comes from
      # render_click/1's synchronous render (`source_busy` is assigned by the
      # event handler before the runner task is even spawned), so an instantly
      # returning runner cannot clear it early. The runner is resolved AT SPAWN
      # TIME, so the SAME page exercises the failing and the succeeding clone.
      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        {:error, "clone failed"}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, not_cloned_status())

      # --- failing clone
      html = render_click(view, "clone_source")
      assert html =~ "Cloning…"

      [clone_button] = Floki.find(Floki.parse_document!(html), ~s(button[id="clone-source"]))
      assert Floki.attribute(clone_button, "disabled") != []

      await_view_assign(view, :source_busy, nil)

      html = render(view)
      assert html =~ "Failed to clone the Genesis source."

      # --- succeeding clone (same page, new runner)
      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        {:ok, cloned}
      end)

      html = render_click(view, "clone_source")
      assert html =~ "Cloning…"

      # The mutation result clears the busy flag and assigns the fresh status.
      await_view_assign(view, :source_busy, nil)
      await_view_assign(view, :source_status, cloned)

      html = render(view)
      assert html =~ "Genesis source cloned."
      assert html =~ "cafebabe"
      assert html =~ ~s(id="update-source")
      refute html =~ ~s(id="clone-source")
    end

    test "update flow: busy state, an error flash on failure, then a success refreshes the status",
         %{conn: conn} do
      original = source_status(%{commit: "deadbeef"})
      updated = source_status(%{commit: "cafebabe"})

      Application.put_env(:evo_dash, :source_status_runner, fn _ -> original end)

      # No artificial delay (see the clone test above): the busy state comes
      # from the synchronous render, the fresh status is awaited via the
      # `source_busy`/`source_status` assigns afterwards. The runner is resolved
      # AT SPAWN TIME, so one page exercises the failing AND succeeding update.
      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        {:error, "update failed"}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_checks_done(view)
      await_view_assign(view, :source_status, original)

      # --- failing update
      html = render_click(view, "update_source")
      assert html =~ "Updating…"

      await_view_assign(view, :source_busy, nil)

      html = render(view)
      assert html =~ "Failed to update the Genesis source."

      # --- succeeding update (same page, new runner)
      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        {:ok, updated}
      end)

      html = render_click(view, "update_source")
      assert html =~ "Updating…"

      [update_button] = Floki.find(Floki.parse_document!(html), ~s(button[id="update-source"]))
      assert Floki.attribute(update_button, "disabled") != []

      await_view_assign(view, :source_busy, nil)
      await_view_assign(view, :source_status, updated)

      html = render(view)
      assert html =~ "Genesis source updated."
      assert html =~ "cafebabe"
    end

    test "clone/update events are no-ops when the card is hidden (remote node)", %{conn: conn} do
      test_pid = self()

      # Runners that would loudly fail if invoked — the hidden card must never
      # spawn them.
      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        send(test_pid, :clone_runner_called)
        {:ok, source_status()}
      end)

      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        send(test_pid, :update_runner_called)
        {:ok, source_status()}
      end)

      {:ok, view, _html} = mount_remote_system(conn)

      await_checks_done(view)
      html = render(view)

      # The card is not rendered at all for a remote node, and its events are
      # guarded no-ops — never a spawn, never a busy flag.
      assert assigns(view)[:remote?] == true
      assert assigns(view)[:source_card_visible] == false
      refute html =~ ~s(id="genesis-source-card")
      refute html =~ "Genesis Source"

      render_click(view, "clone_source")
      render_click(view, "update_source")

      # Zero-window sanity check (the runners signal loudly), backed by the
      # DETERMINISTIC proof below: the click handlers are synchronous, so a
      # spawn would leave `source_busy` == :clone/:update (assigned by the
      # handler, cleared only together with a non-nil `source_status` in
      # `apply_source_mutation_result/3`). "source_busy == nil AND
      # source_status == nil" (read through a `:sys.get_state` round-trip that
      # drains the mailbox behind the clicks) therefore cannot both hold once a
      # runner ran — so no wall-clock observation window is needed.
      refute_received :clone_runner_called
      refute_received :update_runner_called

      assert assigns(view)[:source_busy] == nil
      assert assigns(view)[:source_status] == nil
    end
  end
end

defmodule EvoDashWeb.SystemLiveSyncTest do
  # `async: false` — every test here writes a PROCESS-GLOBAL that another
  # `async: true` module also uses (see the file header table for the per-describe
  # reason). ExUnit drains ALL async modules before starting a sync one, so this
  # module may freely write `:platform_os_override`, the `EvoDash.UpdateStatus`
  # hub and its `:update_*` seams, the local AgentScheduler's paused state, and
  # process-global runner closures that other modules' /system mounts invoke.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EvoDashWeb.SystemLiveTest.Helpers

  setup do
    # Software Update card tests share the global `EvoDash.UpdateStatus` hub —
    # reset it so tests are independent, and pin the notify-only seam to false
    # so the full download flow is testable regardless of the host platform
    # (Linux CI without APPIMAGE would otherwise be notify-only). Capture the
    # original values of every update-related env key so test-body mutations
    # are restored (same restore_env_value/2 pattern as
    # test/evo_dash/update_status_test.exs, handling a stored `false`
    # correctly).
    keys = [
      :update_notify_only_override,
      :desktop_release,
      :update_check_runner,
      :update_check_timeout,
      :update_active_task_ids,
      :update_winddown_timeout,
      :update_winddown_poll_ms,
      :system_checks_runner,
      :system_samples_runner,
      :system_samples_seed_retry_ms,
      :source_status_runner,
      :source_clone_runner,
      :source_update_runner
    ]

    originals = Map.new(keys, fn key -> {key, Application.get_env(:evo_dash, key)} end)
    Application.put_env(:evo_dash, :update_notify_only_override, false)
    # Hermetic + fast mounts: every page mount spawns the system self-check and
    # the chart seed. Both are injected here (re-resolved AT CALL/SPAWN TIME, so
    # a test may override them for its own mount) — the real self-check shells
    # out to the tool probes (~9 ms) and the default seed reads the VM-wide
    # sampler ring buffer, which makes chart-buffer assertions host-dependent.
    Application.put_env(:evo_dash, :system_checks_runner, fn -> all_ok_checks() end)
    Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, []} end)
    EvoDash.UpdateStatus.reset()

    # ActiveTasks is another shared global hub under EvoDash.Application (the
    # sidebar seed on every LiveView mount) — reset it alongside UpdateStatus
    # so one test's sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    on_exit(fn ->
      Enum.each(originals, fn {key, original} -> restore_env_value(key, original) end)
    end)

    :ok
  end

  describe "platform gating" do
    # These tests use the `:platform_os_override` injection seam in
    # `EvoDashWeb.PlatformInfo.os_for_node/1` (checked BEFORE host detection),
    # which is only safe in `async: false` files. The overrides are cleaned up
    # via `on_exit`. The injected `{:system_checks_result, _}` messages make the
    # nix/sandbox row assertions independent of host config.
    #
    # NOTE on markers: the HEEx template keeps its HTML comments in the rendered
    # output (`<!-- Nix Environment Row ... -->`, `<!-- Sandbox Row ... -->`),
    # so plain "Nix Environment"/"Sandbox" substrings are present even when the
    # rows are hidden. Assertions therefore use row-only markers: the title span
    # (`>Nix Environment</span>` / `>Sandbox</span>`) and row-only detail
    # strings / icons ("flake.nix", "Flake valid", "hero-lock-closed").

    test "Nix Environment row renders only when nix is enabled and the binary is available", %{
      conn: conn
    } do
      # ONE mount: visibility is a pure function of the injected nix check map,
      # so the three gate combinations are injected sequentially into the same
      # page (each injected result is the last one processed — see
      # `render_with_checks/2`).
      {:ok, view, _html} = live(conn, ~p"/system")

      # Enabled in config but the nix binary is missing -> hidden.
      html =
        render_with_nix_check(view, %{
          enabled: true,
          available: false,
          flake_present: false,
          dev_env_built: false,
          error: nil
        })

      refute html =~ ">Nix Environment</span>"
      refute html =~ "flake.nix"
      refute html =~ "Flake valid"

      # Disabled in config (binary available) -> hidden.
      html =
        render_with_nix_check(view, %{
          enabled: false,
          available: true,
          flake_present: false,
          dev_env_built: false,
          error: nil
        })

      refute html =~ ">Nix Environment</span>"
      # Row-only detail strings — never rendered when the row is hidden.
      refute html =~ "flake.nix"
      refute html =~ "Flake valid"

      # Enabled AND available -> shown, with the nix-specific detail strings
      # (the generic "Enabled"/"Disabled" strings also appear in the Sandbox
      # row, so assert on strings unique to the Nix row).
      html =
        render_with_nix_check(view, %{
          enabled: true,
          available: true,
          flake_present: true,
          dev_env_built: true,
          error: nil
        })

      assert html =~ ">Nix Environment</span>"
      assert html =~ "flake.nix"
      assert html =~ "Flake valid"
    end

    test "Sandbox row is hidden when the platform is Windows", %{conn: conn} do
      # `:platform_os_override` is the injection seam for `os_for_node/1`: set
      # to :windows it gates the Sandbox row off regardless of the host OS (on
      # CI the host is Linux, which would normally show the row).
      Application.put_env(:evo_dash, :platform_os_override, :windows)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :windows

      # Checks must complete for any row to render at all — inject the real
      # result so `system_checks_status` leaves `:checking` (same pattern as
      # the "LLM Test in Settings link" test).
      html = render_with_checks(view, all_ok_checks())

      # The check grid renders the "Sandbox" row title only when the row is
      # shown; the `hero-lock-closed` icon is unique to that row.
      refute html =~ ">Sandbox</span>"
      refute html =~ "hero-lock-closed"
    end

    test "Sandbox row is shown when the platform is macOS", %{conn: conn} do
      Application.put_env(:evo_dash, :platform_os_override, :macos)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :macos

      # Core assertion: row visibility. NOTE (behavior-vs-plan discrepancy):
      # the :macos override only gates row VISIBILITY — the backend badge text
      # (`Status.format_backend/1`) comes from the REAL host check result, so
      # on a Linux CI host it shows "systemd-run (Linux)" even under the
      # override. Only a second injected :sandbox_exec check map makes the
      # badge deterministic.
      html = render_with_checks(view, all_ok_checks())

      assert html =~ ">Sandbox</span>"
      assert html =~ "hero-lock-closed"

      # Deterministic badge assertion: inject a macOS-style sandbox check result
      # so the "sandbox-exec (macOS)" badge does not depend on the host OS.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | sandbox: %{
              backend: :sandbox_exec,
              enabled: true,
              capabilities: %{filesystem_isolation: true, resource_limits: false},
              sandbox_exec_available: true,
              systemd_available: false
            }
        })

      assert html =~ ">Sandbox</span>"
      assert html =~ "sandbox-exec (macOS)"
    end

    test "Sandbox row shows a bwrap backend badge when the platform is Linux", %{conn: conn} do
      Application.put_env(:evo_dash, :platform_os_override, :linux)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :linux

      # Inject a bwrap-style sandbox check result (Linux host with bwrap but no
      # systemd) so the badge text is deterministic regardless of the host OS.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | sandbox: %{
              backend: :bwrap,
              enabled: true,
              capabilities: %{filesystem_isolation: true, resource_limits: false},
              systemd_available: false,
              sandbox_exec_available: false
            }
        })

      assert html =~ ">Sandbox</span>"
      assert html =~ "bwrap (Linux)"
    end
  end

  describe "system self-check" do
    # The self-check grid/banner tests inject a deterministic
    # `{:system_checks_result, _}` via `render_with_checks/2` after the real
    # async check completes (see the helper's comment for the send+render
    # determinism pattern). All tests set the :windows platform override via
    # `set_windows_platform/0` so the Sandbox cell is hidden and the banner
    # depends only on the injected checks.

    test "merged health banner turns red for each failure reason, green when all pass", %{
      conn: conn
    } do
      # ONE mount: `render_with_checks/2` injects a full result, and the LAST
      # injected result wins (FIFO mailbox, real check already settled), so
      # every banner branch is exercised on the same page.
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      # Green when every check passes.
      html = render_with_checks(view, all_ok_checks())
      assert html =~ "System running correctly"
      assert html =~ "All self-checks passed."

      # Configuration failure.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | config: %{ok?: false, missing: [:llm_model], warnings: [], validation_errors: []}
        })

      assert html =~ "System needs attention"
      assert html =~ "Required settings are missing or invalid"

      # Missing tool.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | tools: %{
              git: %{available: false, path: nil, version: nil, error: "not found"},
              rg: %{available: true, path: "/usr/bin/rg", version: "ripgrep 14.1.0", error: nil}
            }
        })

      assert html =~ "System needs attention"
      assert html =~ "A required tool (git or ripgrep) is missing"

      # Supervisor failure.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | supervisor: %{
              healthy: false,
              evo_git: [%{id: :evo_git, status: :error, pid: nil}],
              evo_dash: []
            }
        })

      assert html =~ "System needs attention"
      assert html =~ "System processes are not running correctly"
    end

    test "check terms render details inline with no disclosure and fix hints on failure", %{
      conn: conn
    } do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      # Every term's detail content is ALWAYS rendered — the old
      # <details>/<summary> disclosure cards were removed. Scope the assertions
      # to the check grid with Floki: the app layout's sidebar theme dropdown
      # (layouts.ex) legitimately renders its own <details>/<summary>, so a
      # bare refute on the full page would be vacuous.
      html = render_with_checks(view, all_ok_checks())
      grid = check_grid(html)

      assert Floki.find(grid, "details") == []
      assert Floki.find(grid, "summary") == []

      # A check-cell description string is present in the scoped grid — proof
      # the detail content renders unconditionally, with no disclosure to open.
      assert Floki.text(grid) =~ "Checks that the git and ripgrep command-line tools"

      # Failing rg → the Required Tools cell shows the per-tool fix hint
      # ("Install git ..." is NOT shown because git is still available).
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | tools: %{
              git: %{
                available: true,
                path: "/usr/bin/git",
                version: "git version 2.0.0",
                error: nil
              },
              rg: %{available: false, path: nil, version: nil, error: "not found"}
            }
        })

      assert html =~ "Install ripgrep and make sure it is available on your PATH."

      # Failing config → the Configuration cell shows the Settings fix hint
      # with its "Open Settings" link.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | config: %{ok?: false, missing: [:llm_model], warnings: [], validation_errors: []}
        })

      assert html =~ "Fix the missing or invalid settings in Settings."
      assert html =~ "Open Settings"
    end
  end

  # The ONE test of the (otherwise async) "scheduler and system controls"
  # describe that must stay sync: it PAUSES the process-global AgentScheduler and
  # broadcasts on the global "scheduler_config" topic (see the file header).
  describe "scheduler and system controls" do
    test "scheduler_config broadcast reloads the REMOTE paused state, not the local one", %{
      conn: conn
    } do
      # Regression for the async node-aware paused reload: the
      # {:scheduler_config_updated} handler must re-read the node being VIEWED
      # (degrading to false for the fake remote node, which has no scheduler
      # behind it), never the LOCAL scheduler's paused state — the old
      # local-only read showed "Scheduler Paused" on a remote view whenever the
      # local scheduler happened to be paused.
      #
      # Same remote scaffolding as the "LLM Test in Settings link" test:
      # a per-process config dir so the saved target never touches the
      # developer's real ~/.config/genesis/, and a fake connection manager so
      # the `?node=` param resolves to a connected remote context.
      # Per-process config dir — never the BEAM-global `XDG_CONFIG_HOME`: the
      # override is activated in THIS process, and the mounted page plus its
      # supervised loads inherit it through OTP's `:"$callers"` chain
      # (`<dir>/genesis` is the same layout the old env redirect produced).
      EvoDash.Test.ConfigDir.isolate!("evogit_system_test_config")

      id = "test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.RemoteConnections.delete(id)
        rescue
          _ -> :ok
        end
      end)

      start_supervised!(
        {EvoDashWeb.SystemLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/system?node=" <> id)

      # The initial async handle_params paused load settles on `false`: the
      # fake remote node has no scheduler behind it, so NodeContext.paused?/1
      # degrades to false. Await it so the broadcast path is what the final
      # assertion exercises.
      assert await_view_assign(view, :scheduler_paused, false) == :ok

      # Prove the paused-state channel works for the current (remote) node —
      # the node stale-guard accepts it, flipping the banner to paused. This
      # makes the post-broadcast flip back to `false` meaningful: it comes from
      # the broadcast-triggered node-aware reload, not a broken channel.
      remote_node = assigns(view)[:current_node]
      send(view.pid, {:paused_state, remote_node, true})
      render(view)
      assert assigns(view)[:scheduler_paused] == true

      # A FOREIGN node's scheduler broadcast must be ignored: no reload is
      # triggered, so the paused banner stays exactly as injected.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, :remote@elsewhere}
      )

      render(view)
      assert assigns(view)[:scheduler_paused] == true

      # Now pause the LOCAL scheduler and fire the broadcast for the VIEWED
      # node (topic "scheduler_config", message
      # {:scheduler_config_updated, node} — see EvoGit.AgentScheduler.PubSub;
      # `remote_node` is the viewed node's BEAM atom, resolved by NodeAware).
      EvoGit.AgentScheduler.pause()

      on_exit(fn ->
        # Resume in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.AgentScheduler.resume()
        rescue
          _ -> :ok
        end
      end)

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, remote_node}
      )

      # The reload is node-aware: it re-reads the REMOTE node's paused state
      # (degrading to false), NOT the local scheduler's now-paused state, so
      # the remote view flips back to `false`.
      assert await_view_assign(view, :scheduler_paused, false) == :ok
    end
  end

  # The TWO "scheduler status charts" tests that must stay sync: each injected
  # `:system_samples_runner` closure bumps a TEST-OWNED ETS call counter and the
  # test asserts the EXACT count. The runner key is process-global, so a
  # concurrently mounting /system page in another async module would invoke the
  # same closure and inflate the count. The other eleven tests of that describe
  # are async.
  describe "scheduler status charts" do
    test "a failed seed retries once and then gives up", %{conn: conn} do
      table = :ets.new(:seed_calls, [:public, :set])
      :ets.insert(table, {:calls, 0})

      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        :ets.update_counter(table, :calls, 1)
        {:error, :not_implemented}
      end)

      # Shorten the one-shot retry delay (production default 3000 ms) so the
      # test does not sleep 3s waiting for it; the setup on_exit restores the
      # seam. The retry is awaited (never slept on), so a few ms is enough.
      Application.put_env(:evo_dash, :system_samples_seed_retry_ms, 5)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The initial seed failed — the one-shot retry is scheduled.
      assert await_view_assign(view, :chart_seed_retried, true) == :ok

      # The retry fires once (30ms later), fails again, and gives up: the
      # second failure schedules no further call (the failure handler is gated
      # on chart_seed_retried), so no third call can ever be made.
      assert await_ets_count(table, :calls, 2, 6_000) == :ok
      assert :ets.lookup_element(table, :calls, 2) == 2
      assert assigns(view)[:chart_samples] == []
    end

    test "a failed seed retries and succeeds on the second attempt", %{conn: conn} do
      table = :ets.new(:seed_calls, [:public, :set])
      :ets.insert(table, {:calls, 0})
      sample = sample_map(llm_used: 3)

      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        if :ets.update_counter(table, :calls, 1) == 1 do
          {:error, :not_implemented}
        else
          {:ok, [sample]}
        end
      end)

      # Shorten the one-shot retry delay (production default 3000 ms) so the
      # test does not sleep 3s waiting for it; the setup on_exit restores the
      # seam. The retry is awaited (never slept on), so a few ms is enough.
      Application.put_env(:evo_dash, :system_samples_seed_retry_ms, 5)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The initial seed failed — the one-shot retry is scheduled. 6s budget:
      # the seed task queues behind the mount's async system-check loads in
      # the test env, so the failure result (and thus the retry scheduling)
      # can arrive late.
      assert await_view_assign(view, :chart_seed_retried, true, 6_000) == :ok

      # The retry succeeds and fills the buffer (30ms later).
      assert await_view_assign(view, :chart_samples, [sample], 6_000) == :ok
    end
  end

  describe "software update card" do
    # These tests drive the shared `EvoDash.UpdateStatus` hub (a global
    # GenServer), so this file must stay `async: false` (it already is). The
    # setup block resets the hub and captures/restores every update-related env
    # key; each test additionally re-syncs the hub to :idle before mounting.
    #
    # Timing helpers:
    #   * `await_hub_phase/2` — polls the hub directly. Used to synchronize hub
    #     state BEFORE mounting: a cast followed by a call from the same
    #     process is ordered, so once `phase()` reports the target the hub is
    #     there and the mount's `get()` cannot observe a stale phase.
    #   * `await_update_phase/2` — polls the LiveView's `@update_status` assign
    #     (the hub broadcast is assigned via the `{:update_status, state}`
    #     handle_info).
    #   * `await_view_assign/3` — polls any socket assign (modal flags).

    test "every update state renders in the card", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # A no-op runner keeps the mount-triggered check's result from arriving
      # (the states below are driven directly via the hub); the huge timeout
      # makes the parallel never-wedge watchdog a harmless long sleep that
      # never fires during the suite.
      Application.put_env(:evo_dash, :update_check_runner, fn _ -> :ok end)
      Application.put_env(:evo_dash, :update_check_timeout, 2_000_000)

      {:ok, view, html} = live(conn, ~p"/system")

      # :idle — the initial render: the mount-triggered check's broadcast is
      # processed only after the initial render is sent, so the returned html
      # still shows the :idle branch. The current-version line is seeded from
      # the :evo_git app spec and visible in every phase.
      assert html =~ "Software Update"
      assert html =~ "Check now"
      assert html =~ "Current version:"
      assert html =~ "Update information will appear here after the first check."

      # :checking — the mount-triggered check left the hub at :checking
      await_update_phase(view, :checking)
      html = render(view)
      assert html =~ "Checking for updates…"

      # :up_to_date
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_update_phase(view, :up_to_date)
      html = render(view)
      assert html =~ "is up to date"
      assert html =~ "Last checked"

      # :available
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "release notes",
        "current_version" => "0.1.0"
      })

      await_update_phase(view, :available)
      html = render(view)
      assert html =~ "Version 1.2.3 is available"
      assert html =~ ~s(id="update-download")

      # :ready
      EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
      await_update_phase(view, :ready)
      html = render(view)
      assert html =~ "Update ready"
      assert html =~ ~s(id="update-restart")

      # :error (generic failure) — no Retry button (the always-visible
      # Check-now header button is the retry path from every phase)
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "error", "error" => "boom"})
      await_update_phase(view, :error)
      html = render(view)
      assert html =~ "Check failed"
      refute html =~ ~s(id="update-retry")

      # :error with error == "not_configured" → friendly pre-key message
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_configured"})
      await_update_error(view, "not_configured")
      html = render(view)
      assert html =~ "Automatic updates are not configured yet"
      refute html =~ "Check failed"

      # :error with error == "not_available" → friendly info-style message;
      # the latest_version from the earlier "available" check is preserved and
      # shown (the version-less rendering is covered in the dedicated test)
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_available"})
      await_update_error(view, "not_available")
      html = render(view)
      assert html =~ "Latest version 1.2.3 — no auto-update for this platform"
      refute html =~ "Check failed"

      # :applying — the header Check-now button is disabled
      EvoDash.UpdateStatus.applying()
      await_update_phase(view, :applying)
      html = render(view)
      assert html =~ "Applying update…"

      [check_now_button] =
        Floki.find(Floki.parse_document!(html), ~s(button[id="update-check-now"]))

      assert Floki.attribute(check_now_button, "disabled") != []
    end

    test "not_available renders the generic message, then the latest version when known", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_available"})
      await_hub_phase(:error)

      {:ok, view, html} = live(conn, ~p"/system")

      # No version known yet -> the generic platform message.
      assert assigns(view).update_status.error == "not_available"
      assert assigns(view).update_status.latest_version == nil
      assert html =~ "No auto update on this platform"
      refute html =~ "Latest version"
      refute html =~ "Check failed"

      # A later result that DOES carry a version surfaces it (the hub keeps the
      # newest latest_version; the view follows via the `{:update_status, _}`
      # broadcast — awaited on the assign itself, since the phase is unchanged).
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "not_available",
        "version" => "1.2.3",
        "body" => "notes",
        "date" => "2026-08-01T00:00:00Z"
      })

      assert await_update_status(
               view,
               &(&1.error == "not_available" and &1.latest_version == "1.2.3")
             ) ==
               :ok

      html = render(view)
      assert html =~ "Latest version 1.2.3 — no auto-update for this platform"
      refute html =~ "No auto update on this platform"
      refute html =~ "Check failed"
    end

    test "generic check error shows Check failed and the raw error detail", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "error",
        "error" => "Update check failed: network unreachable"
      })

      await_hub_phase(:error)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.error == "Update check failed: network unreachable"
      assert html =~ "Check failed"
      assert html =~ "Update check failed: network unreachable"
      refute html =~ "No auto update on this platform"
    end

    test "notify-only mode shows the package-manager message instead of a Download button", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      Application.put_env(:evo_dash, :update_notify_only_override, true)

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "notes",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:available)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.notify_only == true
      assert html =~ "Version 1.2.3 is available"
      assert html =~ "Update via your package manager"
      refute html =~ ~s(id="update-download")
    end

    test "Check now flow: the click triggers a check that resolves to up-to-date", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # Drive the hub to :up_to_date BEFORE mounting so the mount-triggered
      # check does not fire — its :checking phase would disable the Check-now
      # button. The click below is therefore the only check in this test.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:up_to_date)

      test_pid = self()

      # The runner HOLDS the :checking phase open until the test releases it,
      # instead of sleeping a fixed 300ms window: :checking is then observed
      # directly (see the `await_update_phase(view, :checking)` below) rather
      # than raced against a wall clock. The `after` bound is generous (5s) so a
      # lost handshake can never hang the run.
      Application.put_env(:evo_dash, :update_check_runner, fn pid ->
        send(test_pid, {:update_check_runner_started, self()})

        receive do
          :release_update_check -> :ok
        after
          5_000 -> :ok
        end

        send(
          pid,
          {:update_check_result, %{"status" => "up_to_date", "current_version" => "0.1.0"}}
        )
      end)

      # Timeout watchdog fires after the result landed (phase :up_to_date → no-op).
      Application.put_env(:evo_dash, :update_check_timeout, 400)

      {:ok, view, _html} = live(conn, ~p"/system")

      # TaskSupervisor children already alive before the click (mount-time self
      # check / chart seed), subtracted below so only the click's own tasks are
      # drained.
      pre_click_tasks = Task.Supervisor.children(EvoDash.TaskSupervisor)

      view |> element("#update-check-now") |> render_click()

      # The click spawns exactly two TaskSupervisor children when a runner seam
      # is injected: the runner (now blocked on the release) and the parallel
      # never-wedge timeout watchdog. Both are spawned synchronously by the
      # handler, so asserting them here guarantees the drain below can never
      # silently become a no-op.
      click_tasks = Task.Supervisor.children(EvoDash.TaskSupervisor) -- pre_click_tasks
      assert length(click_tasks) >= 2

      assert_receive {:update_check_runner_started, runner_pid}, 1_000
      await_update_phase(view, :checking)
      send(runner_pid, :release_update_check)

      await_update_phase(view, :up_to_date)

      html = render(view)
      assert html =~ "is up to date"

      # The never-wedge watchdog is still sleeping out `:update_check_timeout`.
      # TERMINATE it instead of waiting it out: the check already resolved to
      # :up_to_date, so all of its remaining work is a guaranteed no-op — and
      # terminating it removes the stray-task hazard deterministically, whereas
      # the previous trailing `Process.sleep(100)` only *probably* covered it
      # (the watchdog fires ~400ms after the click, i.e. right around when that
      # sleep ended).
      for pid <- click_tasks do
        Task.Supervisor.terminate_child(EvoDash.TaskSupervisor, pid)
      end

      # `terminate_child/2` is synchronous — nothing from the click may survive
      # into a later test (a surviving watchdog could mutate the shared hub).
      refute Enum.any?(click_tasks, &Process.alive?/1)
    end

    test "a check that never resolves times out and shows the error state", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # Count runner invocations in a public ETS table so the Check-now re-run
      # is provable without racing the short :checking observation window (the
      # short watchdog timeout is too fast to await on the view assign reliably).
      :ets.new(:update_check_runs, [:named_table, :public, :set])
      :ets.insert(:update_check_runs, {:count, 0})

      Application.put_env(:evo_dash, :update_check_runner, fn _ ->
        :ets.update_counter(:update_check_runs, :count, 1)
        :ok
      end)

      Application.put_env(:evo_dash, :update_check_timeout, 15)

      on_exit(fn ->
        if :ets.info(:update_check_runs) != :undefined do
          :ets.delete(:update_check_runs)
        end
      end)

      # Drive the hub to :up_to_date BEFORE mounting so the mount-triggered
      # check does not fire (its :checking phase would disable the Check-now
      # button). The click below is therefore the only check in this test.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:up_to_date)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-check-now") |> render_click()

      # The runner never reports, so only the timeout watchdog can end
      # :checking — the never-wedge invariant.
      await_update_phase(view, :error)

      html = render(view)
      assert html =~ "Check failed"
      refute html =~ ~s(id="update-retry")

      # The always-visible Check-now header button is the retry path: re-run
      # the check from :error (poll until the runner is invoked a second time —
      # deterministic, the short :checking window is not awaited), then the
      # 15ms watchdog bounds the retry too: the UI can never wedge on a spinner.
      view |> element("#update-check-now") |> render_click()

      await_ets_count(:update_check_runs, :count, 2)
      await_update_phase(view, :error)
    end

    test "mounting the page with an idle hub triggers a check automatically", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      Application.put_env(:evo_dash, :update_check_runner, fn pid ->
        send(
          pid,
          {:update_check_result, %{"status" => "up_to_date", "current_version" => "0.1.0"}}
        )
      end)

      Application.put_env(:evo_dash, :update_check_timeout, 500)

      {:ok, view, _html} = live(conn, ~p"/system")

      await_update_phase(view, :up_to_date)

      html = render(view)
      assert html =~ "is up to date"
    end

    test "Download pushes the download request and a ready result arms the apply button", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_available()

      {:ok, view, html} = live(conn, ~p"/system")
      assert html =~ "Version 1.2.3 is available"

      view |> element("#update-download") |> render_click()

      assert_push_event(view, "update_download_requested", %{}, 1_000)

      EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
      await_update_phase(view, :ready)

      html = render(view)
      # HTML-escaped `&` (HEEx renders `&` as `&amp;`).
      assert html =~ "Restart &amp; Update"
    end

    test "applying with no active tasks proceeds immediately", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, [])

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()

      await_update_phase(view, :applying)
      assert_push_event(view, "update_apply_requested", %{}, 1_000)
    end

    test "applying with active tasks shows the busy modal and Defer keeps the update ready", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, ["task-1", "task-2"])

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()

      assert await_view_assign(view, :update_apply_busy_count, 2) == :ok
      html = render(view)
      assert html =~ "2 task(s) still running"

      render_click(view, "defer_apply_update")

      assert await_view_assign(view, :update_apply_busy_count, nil) == :ok
      assert EvoDash.UpdateStatus.phase() == :ready

      html = render(view)
      refute html =~ "task(s) still running"
    end

    test "applying with active tasks can gracefully stop them and then apply", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      # :gate sees one active task (busy modal); :winddown_poll sees none, so
      # the wind-down completes on its first poll and the update applies. The
      # graceful cancel of the fake id errors harmlessly.
      Application.put_env(:evo_dash, :update_active_task_ids, fn
        :gate -> ["task-1"]
        :winddown_poll -> []
      end)

      Application.put_env(:evo_dash, :update_winddown_poll_ms, 20)
      Application.put_env(:evo_dash, :update_winddown_timeout, 500)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()
      assert await_view_assign(view, :update_apply_busy_count, 1) == :ok

      render_click(view, "confirm_apply_graceful")

      await_update_phase(view, :applying)
    end

    test "a wind-down that times out offers the force-kill fallback", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, fn _ -> ["task-1"] end)
      Application.put_env(:evo_dash, :update_winddown_poll_ms, 5)
      Application.put_env(:evo_dash, :update_winddown_timeout, 20)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()
      assert await_view_assign(view, :update_apply_busy_count, 1) == :ok

      render_click(view, "confirm_apply_graceful")

      assert await_view_assign(view, :update_force_kill_count, 1) == :ok
      html = render(view)
      # HTML-escaped `&` (HEEx renders `&` as `&amp;`).
      assert html =~ "Force Kill &amp; Update?"
      assert html =~ "1 task(s) still running after waiting"
      assert html =~ "In-flight work will be lost"

      render_click(view, "confirm_force_kill_update")

      await_update_phase(view, :applying)
    end

    test "card is hidden when viewing a remote node", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      # Isolate the config dir PER PROCESS so the saved target never
      # touches the developer's real ~/.config/genesis/ (same pattern as the
      # "LLM Test in Settings link" test).
      # Per-process config dir — never the BEAM-global `XDG_CONFIG_HOME`: the
      # override is activated in THIS process, and the mounted page plus its
      # supervised loads inherit it through OTP's `:"$callers"` chain
      # (`<dir>/genesis` is the same layout the old env redirect produced).
      EvoDash.Test.ConfigDir.isolate!("evogit_system_test_config")

      id = "test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.RemoteConnections.delete(id)
        rescue
          _ -> :ok
        end
      end)

      start_supervised!(
        {EvoDashWeb.SystemLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, html} = live(conn, "/system?node=" <> id)

      assert assigns(view)[:remote?] == true
      assert assigns(view)[:update_card_visible] == false
      refute html =~ "Software Update"
    end

    # --- Changelog modal (release notes) ------------------------------------
    # The update feed's release notes (the check-result payload "body" key)
    # surface as a "View changelog" link in the :available/:ready card rows
    # and render in a dedicated modal gated on the `changelog_open` assign —
    # never inline in the card (which stays compact). Both the link and the
    # modal appear only when the hub's `notes` field is a non-empty binary
    # (nil or "" → neither renders).

    test "available with notes renders the changelog link and keeps the notes out of the card",
         %{
           conn: conn
         } do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_available()

      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ ~s(id="view-changelog")
      assert html =~ ~s(phx-click="open_changelog")
      assert html =~ "View changelog"
      # The notes live in the modal (closed on the initial render), so they
      # must not be dumped inline in the card row.
      refute html =~ "release notes"
    end

    test "available with absent or empty notes renders no changelog link", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      # No "body" key -> the hub's `notes` stays nil.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:available)

      {:ok, view, html} = live(conn, ~p"/system")

      refute html =~ ~s(id="view-changelog")
      refute html =~ "View changelog"

      # An EMPTY-STRING body is treated exactly like an absent one.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "",
        "current_version" => "0.1.0"
      })

      assert await_update_status(view, &(&1.notes == "")) == :ok

      html = render(view)
      refute html =~ ~s(id="view-changelog")
      refute html =~ "View changelog"
    end

    test "the open modal closes via its backdrop or the Close button", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_available()

      {:ok, view, _html} = live(conn, ~p"/system")

      # The modal is closed on the initial render.
      refute render(view) =~ "Update changelog"

      html = render_click(view, "open_changelog")

      assert assigns(view)[:changelog_open] == true
      assert html =~ "Update changelog"
      assert html =~ "release notes"

      # While open, exactly two elements carry the close event: the backdrop
      # div (first in DOM order) and the Close button. Pin the backdrop's
      # class + click affordance.
      [backdrop | rest] =
        Floki.find(Floki.parse_document!(html), ~s([phx-click="close_changelog"]))

      assert rest != []

      assert Floki.attribute(backdrop, "class") == [
               "fixed inset-0 bg-black/50 backdrop-blur-sm"
             ]

      # `render_click(view, "close_changelog")` dispatches to the handler —
      # the same path the backdrop click (or the Close button) takes.
      html = render_click(view, "close_changelog")

      assert assigns(view)[:changelog_open] == false
      refute html =~ "Update changelog"
      refute html =~ "release notes"
    end

    test "ready with notes renders the changelog link and opens the modal", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.phase == :ready
      assert html =~ ~s(id="view-changelog")
      assert html =~ "View changelog"
      refute html =~ "release notes"

      html = render_click(view, "open_changelog")

      assert assigns(view)[:changelog_open] == true
      assert html =~ "Update changelog"
      assert html =~ "release notes"
    end

    test "ready without notes renders no changelog link", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:available)
      EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
      await_hub_phase(:ready)

      {:ok, _view, html} = live(conn, ~p"/system")

      refute html =~ ~s(id="view-changelog")
      refute html =~ "View changelog"
    end

    test "changelog notes are HTML-escaped inside the modal", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "<script>alert(1)</script><b>bold</b>",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:available)

      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_click(view, "open_changelog")

      assert assigns(view)[:changelog_open] == true
      # HEEx auto-escapes the `{@update_status.notes}` text node.
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "<script>alert(1)</script>"
    end

    test "card is hidden outside the desktop shell and its events are guarded no-ops", %{
      conn: conn
    } do
      reset_hub_to_idle()
      Application.delete_env(:evo_dash, :desktop_release)

      {:ok, view, html} = live(conn, ~p"/system")

      # Cache the card + all of its events behind ONE visibility gate.
      assert assigns(view)[:update_card_visible] == false
      refute html =~ "Software Update"
      refute html =~ ~s(id="view-changelog")

      # No visible card → the events are guarded no-ops; `changelog_open`
      # stays at its mount default (false) and nothing renders.
      render_click(view, "open_changelog")
      render_click(view, "close_changelog")

      refute assigns(view)[:changelog_open]
    end
  end

  # The ONE "genesis source card" test that must stay sync: its injected
  # `:source_status_runner` BLOCKS until the test releases it and signals its own
  # pid for an `assert_receive` — a concurrently mounting /system page in another
  # async module would run the same process-global closure and win that receive.
  # The other seven tests of that describe are async.
  describe "genesis source card" do
    test "status load shows the loading spinner until the status lands", %{conn: conn} do
      test_pid = self()
      status = source_status()

      # The runner BLOCKS until the test releases it (instead of sleeping a
      # fixed window): the loading spinner is then observable for a genuinely
      # deterministic window, not a wall-clock race against `await_checks_done/1`
      # (which can easily exceed a fixed sleep under load).
      Application.put_env(:evo_dash, :source_status_runner, fn _ ->
        send(test_pid, {:source_status_task_started, self()})

        receive do
          :release_source_status -> status
        after
          5_000 -> status
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The runner signals it started, then blocks — the loading spinner is
      # observable for a deterministic window.
      assert_receive {:source_status_task_started, runner_pid}, 1_000
      await_checks_done(view)
      html = render(view)
      assert html =~ "Loading…"

      send(runner_pid, :release_source_status)
      await_view_assign(view, :source_status, status)
      html = render(view)
      refute html =~ "Loading…"
      refute html =~ "The self-reflective agent reads"
    end
  end
end
