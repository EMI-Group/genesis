# Settings → in-browser "Sign in with ChatGPT" SURFACES suite.
#
# The add-account wizard's auth step already owns its own coverage
# (`provider_wizard_test.exs`, `#settings-chatgpt-*`). This module pins the
# GENERALIZED surfaces the state machine added: an expanded `openai_codex`
# account's detail form (`#provider-detail-<slug>-chatgpt-*`) and its auth-status
# row (`#provider-status-<slug>-chatgpt-*`), all driven by ONE page-level
# `EvoDashWeb.SettingsLive.ChatGPTSignInState`.
#
# ASYNC: the config directory is the per-process `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1`, installed by `test_helper.exs`) and the
# flow module is the per-test `EvoDash.Test.ChatGPTLoginStub` injected through
# the sign-in boundary's CALL-TIME `$callers` seam — no loopback listener, no
# network, nothing BEAM-global.
# A fake remote-connection status provider (the same seam `provider_wizard_test`
# uses): registering this process under a target id in the shared
# `EvoGit.RemoteConnection.Registry` makes `NodeAware` resolve `?node=<id>` to a
# CONNECTED remote BEAM. Defined ABOVE the async case module — an `async: true`
# module is handed to the runner while the rest of the file loads, so a
# `start_supervised!` target defined below it can still be `:non_existing`.
defmodule EvoDashWeb.SettingsLive.ChatGPTSignInSurfacesTest.ConnectionManager do
  use GenServer

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end

defmodule EvoDashWeb.SettingsLive.ChatGPTSignInSurfacesTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias EvoDash.Test.ChatGPTLoginStub, as: ChatGPTStub
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState

  @profile_id "codex-1"
  @flow_url "https://auth.openai.com/detail"
  @flow_id "flow-1"

  # Load-tolerant budgets: the mount load chain and every owned write run in
  # supervised tasks on a shared host whose scheduling swings 10-30x
  # (test/CONTEXT.md). The waits stay bounded and still fail loudly.
  @async_wait_budget_ms 30_000
  @assigns_timeout_ms 30_000

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_settings_chatgpt_surfaces_test")
    # Process-less public ETS table shared by the whole run — clear ONLY the
    # local context (a whole-table reset would delete a concurrent module's
    # per-test snapshot).
    EvoDash.ActiveTasks.invalidate(nil, node())
    # The stub notifies from INSIDE the boundary's `Task.async` call, so the
    # product's call budget also bounds a stub notification: on a starved host
    # the task can be killed before it runs and the notification is lost
    # forever. Inject the suite's load-tolerant budget so the product can never
    # kill a stub call (production keeps its own 15 s default).
    Process.put(:chatgpt_signin_call_timeout_ms, @async_wait_budget_ms)
    :ok
  end

  # ── mount + async settles ──────────────────────────────────────────────────
  defp mount_settings(conn, path) do
    {:ok, view, html} = live(conn, path)
    settle_mount_loads(view)
    {:ok, view, html}
  end

  defp settle_mount_loads(view) do
    settle_mount_loads(view, System.monotonic_time(:millisecond) + @async_wait_budget_ms)
  end

  defp settle_mount_loads(view, deadline) do
    # Drain applies BEFORE enumerating: an applied node-data result can spawn
    # the OAuth load, which must also finish before a test injects a verdict.
    _ = render(view)
    pids = mount_async_task_pids(view.pid)

    if pids != [] do
      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          remaining -> flunk("Settings async loader did not settle")
        end
      end)

      assert System.monotonic_time(:millisecond) < deadline,
             "Settings async load chain did not settle"

      settle_mount_loads(view, deadline)
    end
  end

  defp mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        callers = task_callers(pid)
        if is_nil(callers) or view_pid in callers, do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers")
      _ -> []
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # ── config fixtures ────────────────────────────────────────────────────────
  # An `openai_codex` account whose managed credential path can neither be read
  # nor created on ANY host (its parent is a regular FILE), so the baseline
  # credential verdict is deterministic (`No subscription login found`) and the
  # status surface renders its sign-in control.
  defp seed_openai_codex_profile(id \\ @profile_id) do
    path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(path))
    blocked = blocked_oauth_file(Path.dirname(path))

    File.write!(path, """
    [llm]
    default_provider_profile = "#{id}"
    [[llm.providers]]
    id = "#{id}"
    provider = "openai_codex"
    default_model = "gpt-5.6-terra"
    oauth_file = "#{blocked}"
    concurrency = 3
    [[llm.providers.models]]
    model = "gpt-5.6-terra"
    """)

    on_exit(fn -> File.rm(path) end)
    id
  end

  defp blocked_oauth_file(dir) do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "not a directory")
    Path.join(blocker, "auth.json")
  end

  # ── panel helpers ──────────────────────────────────────────────────────────
  defp slug(id), do: Row.slug(id)
  defp detail_panel(id), do: "provider-detail-#{slug(id)}-chatgpt"
  defp status_panel(id), do: "provider-status-#{slug(id)}-chatgpt"
  defp row_id(id), do: "#provider-profile-#{slug(id)}"

  defp open_account(view, id) do
    render_hook(view, "edit_provider_profile", %{"profile_id" => id})
    await_config_save(view)
  end

  defp await_config_save(view) do
    wait_settings(view, &(not &1[:config_saving]))
    render(view)
  end

  defp wait_settings(view, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @async_wait_budget_ms
    current = assigns(view)

    if predicate.(current) do
      current
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "Settings did not reach the expected authoritative state"

      receive do
      after
        2 -> wait_settings(view, predicate, deadline)
      end
    end
  end

  defp attr(html, name) do
    html |> Floki.parse_fragment!() |> Floki.attribute(name) |> List.first()
  end

  defp waiting_block_count(view) do
    Regex.scan(~r/id="[^"]*-chatgpt-waiting"/, render(view)) |> length()
  end

  # Selector membership on a CAPTURED render.
  #
  # A captured render is the right instrument only for a state that has already
  # been APPLIED: `has_element?/2` re-reads the page, so it proves the CURRENT
  # state, never what an event returned. No claim below depends on how fast a
  # later read runs: the flow's verdict is gated by the TEST (`status_gate/1`),
  # so the waiting surface is a STABLE phase that every instrument can read —
  # and a success can only arrive once the test opens that gate.
  defp rendered?(html, selector),
    do: html |> Floki.parse_fragment!() |> Floki.find(selector) != []

  # The same claim for the click's OWN render, with a SELF-DIAGNOSING failure.
  #
  # The click's render must already show the waiting surface (the event's
  # handler decided the phase), and when it does not the message has to report
  # WHAT the page really rendered: a bare "expected truthy" cannot tell an
  # `:error` phase from a non-waiting surface or a stale diff. `elapsed_ms` is
  # part of the evidence — the product's flow call is bounded
  # (`EvoDashWeb.LLMSetup.ChatGPTSignIn.call_timeout_ms/0`), so a whole-budget
  # elapsed proves a starved call while a fast non-waiting render proves the
  # phase was decided immediately.
  defp assert_waiting_on_click(click_html, view, panel, surface, elapsed_ms) do
    selector = "#" <> panel <> "-waiting"

    if rendered?(click_html, selector) do
      :ok
    else
      state = Map.get(assigns(view), :chatgpt_sign_in) || %{}

      flunk("""
      expected the click's own render to show #{selector}, but it did not.
      page sign-in state: #{inspect(state)}
      expected surface: #{inspect(surface)}
      page surface:     #{inspect(ChatGPTSignInState.surface(state))}
      rendered error:   #{inspect(floki_text(click_html, "#" <> panel <> "-sign-in-error"))}
      idle button rendered: #{rendered?(click_html, "#" <> panel <> "-sign-in")}
      manual hint rendered: #{rendered?(click_html, "#" <> panel <> "-manual-hint")}
      click took #{elapsed_ms} ms
      """)
    end
  end

  defp floki_text(html, selector) do
    case html |> Floki.parse_fragment!() |> Floki.find(selector) do
      [] -> nil
      nodes -> nodes |> Floki.text() |> String.trim()
    end
  end

  # Clicks a surface's sign-in button and keeps BOTH the render the event
  # returned and how long the click itself took (evidence for the bounded
  # flow-call budget).
  defp click_sign_in(view, panel) do
    started_at = System.monotonic_time(:millisecond)
    html = view |> element("#" <> panel <> "-sign-in") |> render_click()
    {html, System.monotonic_time(:millisecond) - started_at}
  end

  # ── a TEST-CONTROLLED flow verdict ────────────────────────────────────────
  #
  # `ChatGPTLoginStub` pops ONE status answer per poll, so a single `:pending`
  # fun would be consumed by the first poll and every later one would answer
  # `:pending` from the empty queue — which this file cannot use: the poll task
  # (`EvoDashWeb.LLMSetup.ChatGPTSignIn.start_poll/2`) runs under
  # `EvoDash.TaskSupervisor` with the view in its `:"$callers"`, so a flow that
  # never terminates makes `settle_mount_loads/1` sit on its whole budget.
  # The gate therefore answers `:pending` while it is CLOSED and the flow's
  # verdict as soon as the TEST opens it — the waiting phase is a stable state
  # for as long as the test needs, and the page's own poll then delivers the
  # success and finishes, exactly as a real authorization does.
  # `:counters` is process-independent, so the fun can read it from the stub's
  # own agent, and the queue is deep enough to outlive any load stall.
  @status_gate_depth 60_000

  defp status_gate(account) do
    counter = :counters.new(1, [])

    answers =
      List.duplicate(
        fn ->
          if :counters.get(counter, 1) == 0 do
            :pending
          else
            {:ok, %{account: account}}
          end
        end,
        @status_gate_depth
      )

    %{counter: counter, statuses: %{@flow_id => answers}}
  end

  defp open_status_gate(%{counter: counter}), do: :counters.put(counter, 1, 1)

  # ── bounded sign-in waits (event-driven, never a fixed sleep) ─────────────
  defp await_page_sign_in(view, phase, surface) do
    await_page_sign_in(
      view,
      phase,
      surface,
      System.monotonic_time(:millisecond) + @async_wait_budget_ms
    )
  end

  defp await_page_sign_in(view, phase, surface, deadline) do
    state = assigns(view)[:chatgpt_sign_in] || %{}
    current_phase = Map.get(state, :phase)

    if current_phase == phase and surface == ChatGPTSignInState.surface(state) do
      render(view)
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "ChatGPT sign-in never reached #{inspect(phase)} on #{inspect(surface)} " <>
               "(was #{inspect(current_phase)} on #{inspect(ChatGPTSignInState.surface(state))}, " <>
               "state #{inspect(state)})"

      receive do
      after
        2 -> :ok
      end

      await_page_sign_in(view, phase, surface, deadline)
    end
  end

  # A bounded wait for the page's START-FAILURE verdict (`:error` phase on
  # `surface`), answering the applied state so the reason is assertable.
  defp await_start_failure(view, surface) do
    await_start_failure(
      view,
      surface,
      System.monotonic_time(:millisecond) + @async_wait_budget_ms
    )
  end

  defp await_start_failure(view, surface, deadline) do
    state = assigns(view)[:chatgpt_sign_in] || %{}

    if Map.get(state, :phase) == :error and surface == ChatGPTSignInState.surface(state) do
      _ = render(view)
      state
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "ChatGPT sign-in never reported a start failure on #{inspect(surface)} " <>
               "(state #{inspect(state)})"

      receive do
      after
        2 -> :ok
      end

      await_start_failure(view, surface, deadline)
    end
  end

  # ── auth-status injection (the auth_status_test pattern) ──────────────────
  #
  # The sign-in success path fires a REAL `AuthStatus.start/2` reload in a
  # supervised task. That task captures the `:auth_status_seq` the page bumped
  # BEFORE spawning it, so its `{:settings_auth_status_loaded, …}` carries
  # exactly the seq an injector reads — the page's stale guard cannot tell the
  # two apart, and whichever arrives LAST wins. Settling the real load first is
  # therefore necessary but NOT sufficient: a load still in flight (or spawned
  # while applying a queued result) delivers the same seq and overwrites the
  # injected verdict, which is the intermittent failure this helper removes.
  #
  # So the injection is PROVEN to be the last writer instead of assumed:
  #
  #   1. settle every in-flight apply (the real load task's DOWN AND the
  #      mailbox-draining `:sys.get_state` round-trip that can apply a queued
  #      result and spawn the next real load),
  #   2. inject with the page's CURRENT seq — the only value its stale guard
  #      accepts,
  #   3. settle again and re-read: a real result that landed after the injection
  #      either replaced `:auth_statuses` or bumped `:auth_status_seq` (a bump
  #      always precedes its spawn), and either one simply repeats the injection
  #      against the seq the page now holds.
  #
  # Once step 3 sees BOTH an unmoved seq and the injected map, no real load can
  # still be in flight (step 1's settle proved none was running, and any new one
  # must bump the seq first), so the injected verdict is what the assertions
  # render. The loop is bounded and event-driven — never a sleep.
  defp inject_statuses(view, statuses, target_node \\ nil) do
    inject_statuses(
      view,
      statuses,
      target_node,
      System.monotonic_time(:millisecond) + @async_wait_budget_ms
    )
  end

  defp inject_statuses(view, statuses, target_node, deadline) do
    # Drain applies BEFORE enumerating: that round-trip can apply a queued
    # result and spawn the real credential load, which must also finish.
    settle_mount_loads(view)
    _ = assigns(view)
    settle_mount_loads(view)
    state = assigns(view)

    send(
      view.pid,
      {:settings_auth_status_loaded, target_node || state.current_node, state.auth_status_seq,
       statuses}
    )

    _ = render(view)
    # Prove the injected verdict is the page's LAST writer.
    settle_mount_loads(view)
    settled = assigns(view)

    cond do
      settled.auth_statuses == statuses and settled.auth_status_seq == state.auth_status_seq ->
        render(view)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "Settings auth-status injection was overwritten by the real credential load " <>
            "(seq #{state.auth_status_seq} -> #{settled.auth_status_seq}, " <>
            "auth_statuses #{inspect(settled.auth_statuses)})"
        )

      true ->
        inject_statuses(view, statuses, target_node, deadline)
    end
  end

  defp profile_row(html, profile_id) do
    rows =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(row_id(profile_id))

    assert [row] = rows, "expected one canonical provider row for #{profile_id}"
    Floki.raw_html(row)
  end

  # ── wizard helpers (the add-account surface, for cancel-on-close) ─────────
  defp start_wizard(view) do
    view |> element(~s(button[phx-click="add_provider_profile"])) |> render_click()
    assert has_element?(view, "#provider-wizard")
    :ok
  end

  defp pick_provider(view, provider) do
    view
    |> element(~s(#provider-wizard button[phx-value-provider="#{provider}"]))
    |> render_click()
  end

  defp wizard_next(view) do
    view
    |> element(~s(#provider-wizard button[phx-click="provider_wizard_next"]))
    |> render_click()
  end

  defp open_chatgpt_auth_step(view) do
    start_wizard(view)
    pick_provider(view, "openai_codex")
    wizard_next(view)
    assert has_element?(view, "#wizard-step-auth")
  end

  # A bounded wait for the wizard-surface projection (the same event-driven rule
  # as `await_page_sign_in`, reading `provider_wizard.chatgpt_sign_in`).

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. the expanded account's DETAIL surface
  # ═══════════════════════════════════════════════════════════════════════════
  describe "detail surface" do
    test "starts a sign-in and shows the authorization link while it waits", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      button_html = view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render()
      # Inside the account <form>, so it must never submit.
      assert attr(button_html, "type") == "button"
      assert attr(button_html, "phx-value-surface") == "detail"
      assert attr(button_html, "phx-value-profile_id") == @profile_id

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      # The flow call is an async RPC, so await the APPLIED phase before reading
      # its markup (the stub stays `:pending` here).
      await_page_sign_in(view, :waiting, {:detail, @profile_id})

      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      link = view |> element("#" <> detail_panel(@profile_id) <> "-sign-in-url") |> render()
      assert attr(link, "href") == @flow_url
      assert attr(link, "target") == "_blank"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. the account's AUTH-STATUS row surface
  # ═══════════════════════════════════════════════════════════════════════════
  describe "status surface" do
    test "starts a sign-in and shows the authorization link while it waits", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      button_html = view |> element("#" <> status_panel(@profile_id) <> "-sign-in") |> render()
      assert attr(button_html, "type") == "button"
      assert attr(button_html, "phx-value-surface") == "status"
      assert attr(button_html, "phx-value-profile_id") == @profile_id

      view |> element("#" <> status_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:status, @profile_id})

      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      link = view |> element("#" <> status_panel(@profile_id) <> "-sign-in-url") |> render()
      assert attr(link, "href") == @flow_url
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. cancel from each surface leaves the OTHER untouched
  # ═══════════════════════════════════════════════════════════════════════════
  describe "cancel from each surface" do
    test "each surface abandons only its own flow", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      # Detail: wait, cancel, return to its idle button.
      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in-cancel") |> render_click()
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @async_wait_budget_ms
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
      # The OTHER surface never moved.
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-sign-in")
      refute has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")

      # Status: wait, cancel, return to its idle button.
      view |> element("#" <> status_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:status, @profile_id})
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")

      view |> element("#" <> status_panel(@profile_id) <> "-sign-in-cancel") |> render_click()
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @async_wait_budget_ms
      refute has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-sign-in")
      # The detail surface is untouched by the status cancel.
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. a successful sign-in flips the OWNING surface only
  # ═══════════════════════════════════════════════════════════════════════════
  describe "success" do
    test "the detail surface records the account and triggers a credential reload", %{
      conn: conn
    } do
      # The flow's verdict is gated by THIS test: the stub keeps answering
      # `:pending` until the gate opens, so the waiting phase is a STABLE state
      # (a `[{:ok, …}]` queue settles it on the very next 5 ms poll, which made
      # every "while it waits" claim race a transient window — see `rendered?/2`).
      gate = status_gate("work")

      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: gate.statuses
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      seq_before = assigns(view).auth_status_seq

      {click_html, click_ms} = click_sign_in(view, detail_panel(@profile_id))

      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      # The event's own render already shows the waiting surface …
      assert_waiting_on_click(
        click_html,
        view,
        detail_panel(@profile_id),
        {:detail, @profile_id},
        click_ms
      )

      # … and the APPLIED state keeps showing it, because the gate is still
      # closed: nothing but this test can end the wait.
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      link = view |> element("#" <> detail_panel(@profile_id) <> "-sign-in-url") |> render()
      assert attr(link, "href") == @flow_url

      # Open the gate: the page's OWN poll answers the success (the same path a
      # real authorization takes) and the poll task finishes with it.
      open_status_gate(gate)
      await_page_sign_in(view, :ok, {:detail, @profile_id})

      # Settle the success path's supervised credential reload (and any queued
      # config/node-data apply) BEFORE reading the page, so these assertions —
      # and the injection below, which the real load would otherwise overwrite
      # with the same seq — see one quiet page.
      settle_mount_loads(view)

      # The connected registration lands in the expanded account's detached
      # draft (never the wizard's).
      assert assigns(view).profile_form_draft["siwc_account"] == "work"
      # The waiting block clears and the surface offers a fresh sign-in.
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")

      # The page re-requested the OAuth credential status (seq bumped) — inject
      # the reload payload and watch the rendered verdict move off the baseline.
      assert assigns(view).auth_status_seq > seq_before

      inject_statuses(view, %{
        @profile_id => %{
          state: :ok,
          expires: nil,
          account_id: "acct",
          login_instructions: nil,
          oauth_file: "/tmp/genesis/auth.json"
        }
      })

      row = profile_row(render(view), @profile_id)
      assert row =~ "Login detected"
      refute row =~ "No subscription login found"
    end

    test "the status surface records the account and triggers a credential reload", %{
      conn: conn
    } do
      # Gated for the same reason as the detail surface: the waiting phase must
      # be a stable state, never a transient window.
      gate = status_gate("work-status")

      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: gate.statuses
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      seq_before = assigns(view).auth_status_seq

      {click_html, click_ms} = click_sign_in(view, status_panel(@profile_id))

      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms

      assert_waiting_on_click(
        click_html,
        view,
        status_panel(@profile_id),
        {:status, @profile_id},
        click_ms
      )

      await_page_sign_in(view, :waiting, {:status, @profile_id})
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      link = view |> element("#" <> status_panel(@profile_id) <> "-sign-in-url") |> render()
      assert attr(link, "href") == @flow_url

      # The page's own poll delivers the success once the gate opens.
      open_status_gate(gate)
      await_page_sign_in(view, :ok, {:status, @profile_id})

      # This surface reads the REAL credential load (it injects nothing), so the
      # only ordering hazard is rendering/reading while the success path's
      # supervised reload (or a queued config/node-data apply) is still in
      # flight: settle it first so every assertion below sees the quiet page.
      settle_mount_loads(view)

      assert assigns(view).profile_form_draft["siwc_account"] == "work-status"
      refute has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-sign-in")
      assert assigns(view).auth_status_seq > seq_before
      # The detail surface was never rendered with the status flow's phase.
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. friendly errors — never the raw reason atom
  # ═══════════════════════════════════════════════════════════════════════════
  describe "friendly errors" do
    test "a denied authorization renders localized text, never the reason atom", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: [{:error, :authorization_denied}]
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms

      await_page_sign_in(view, :error, {:detail, @profile_id})

      error =
        view |> element("#" <> detail_panel(@profile_id) <> "-sign-in-error") |> render()

      assert attr(error, "role") == "alert"
      assert error =~ "Sign-in was cancelled in the browser."
      refute error =~ "authorization_denied"
      refute render(view) =~ "authorization_denied"
    end

    test "a status-surface failure is just as friendly", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: [{:error, :loopback_listener_unavailable}]
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> status_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms

      await_page_sign_in(view, :error, {:status, @profile_id})

      error =
        view |> element("#" <> status_panel(@profile_id) <> "-sign-in-error") |> render()

      assert attr(error, "role") == "alert"
      assert error =~ "Genesis could not start a local sign-in"
      refute error =~ "loopback_listener_unavailable"
      refute render(view) =~ "loopback_listener_unavailable"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5b. the BOUNDED flow start — a start that cannot complete is an error,
  #     never a waiting surface (and never a hung poll)
  # ═══════════════════════════════════════════════════════════════════════════
  describe "bounded flow start" do
    test "a start the product cannot complete renders the error phase, never a waiting surface",
         %{conn: conn} do
      ChatGPTStub.install!(
        begin: fn ->
          Process.sleep(200)
          {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}}
        end
      )

      # AFTER `install!/1`, which itself pins this seam at the 30 s async budget:
      # shrinking the product's per-call budget below the stub's own answer
      # reproduces — deterministically, with NO host load — the failure shape this
      # suite hit on a starved host. That is why the waiting-surface claims above
      # hold the flow `:pending` and read the APPLIED state instead of depending
      # on the click's own render of a phase the flow can leave in 5 ms.
      Process.put(:chatgpt_signin_call_timeout_ms, 1)

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      {click_html, _click_ms} = click_sign_in(view, detail_panel(@profile_id))

      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms

      state = await_start_failure(view, {:detail, @profile_id})
      assert state.reason == :sign_in_unavailable
      assert state.flow_id == nil

      refute rendered?(click_html, "#" <> detail_panel(@profile_id) <> "-waiting")
      assert rendered?(click_html, "#" <> detail_panel(@profile_id) <> "-sign-in-error")

      # The surface is honest and retry-able: the friendly message (never the
      # reason atom) and a fresh sign-in button.
      assert floki_text(click_html, "#" <> detail_panel(@profile_id) <> "-sign-in-error") =~
               "Genesis could not start a local sign-in"

      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
    end

    test "the waiting surface persists for as long as the flow stays pending", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: %{}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})

      # Nothing settles a pending flow on its own, so repeated independent reads
      # (each one a fresh render) all see the SAME waiting surface: a later read
      # is as sound as the click's own render, which is the instrument rule this
      # suite relies on.
      for _read <- 1..3 do
        assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
        assert waiting_block_count(view) == 1
      end

      assert assigns(view).chatgpt_sign_in.flow_id == @flow_id
      assert assigns(view).profile_form_draft["siwc_account"] in [nil, ""]
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. remote-node gating for the NEW surfaces
  # ═══════════════════════════════════════════════════════════════════════════
  describe "remote-node gating" do
    test "both surfaces show the CLI hint and no sign-in button", %{conn: conn} do
      id = "chatgpt-remote-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Sign-in Remote"})

      on_exit(fn -> EvoGit.RemoteConnections.delete(id) end)

      start_supervised!(
        {EvoDashWeb.SettingsLive.ChatGPTSignInSurfacesTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote_siwc@127.0.0.1", last_error: nil}}}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, "/settings?node=" <> id)
      # The viewed node is a FOREIGN execution node, so the in-browser flow —
      # which binds a loopback listener on THIS BEAM — is never offered.
      assert assigns(view).current_node_id == id
      assert assigns(view).current_node != node()
      assert assigns(view).chatgpt_sign_in_manual == true
      # A remote node's config cannot be read in-process (`get_resolved_config/1`
      # is a real `:erpc` with no injection seam), so the page truthfully renders
      # the remote-unavailable banner and NO account rows — hence there is no
      # detail/status panel to expand. The reachable remote sign-in control is
      # the wizard's auth step: CLI hint, never a button.
      assert render(view) =~ "Remote Configuration Unavailable"
      refute has_element?(view, "#provider-profile-" <> slug(@profile_id))
      open_chatgpt_auth_step(view)
      refute has_element?(view, "#settings-chatgpt-sign-in")
      assert has_element?(view, "#settings-chatgpt-manual-hint")
      hint = view |> element("#settings-chatgpt-manual-hint") |> render()
      assert hint =~ "genesis chatgpt login"
      assert hint =~ "same machine as the execution node"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. surface isolation — at most ONE live flow, never cross-rendered
  # ═══════════════════════════════════════════════════════════════════════════
  describe "surface isolation" do
    test "a result for another surface's flow changes nothing and only one waits", %{
      conn: conn
    } do
      # ONE install, a per-call `begin` queue and flow-keyed answer queues: the
      # superseded detail flow's still-running poll polls the same stub, and a
      # shared queue would let it steal the status flow's success.
      ChatGPTStub.install!(
        begin: [
          {:ok, %{id: "flow-detail", url: @flow_url, port: 48_123}},
          {:ok, %{id: "flow-status", url: @flow_url, port: 48_123}}
        ],
        # Both flows stay `:pending` until the TEST delivers a result for the
        # exact flow id, so no assertion window races a stub answer.
        statuses: %{}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      assert waiting_block_count(view) == 1

      # A result for the wizard surface's flow is stale: nothing changes.
      send(view.pid, {:chatgpt_signin_result, "flow-wizard", {:ok, %{account: "ghost"}}})
      render(view)

      assert assigns(view).chatgpt_sign_in.flow_id == "flow-detail"
      assert assigns(view).chatgpt_sign_in.phase == :waiting
      refute assigns(view).profile_form_draft["siwc_account"] == "ghost"
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      refute has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")

      # Starting the STATUS flow abandons the detail one — two live flows can
      # never race for the page state.
      view |> element("#" <> status_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :cancel, "flow-detail"}, @async_wait_budget_ms
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:status, @profile_id})

      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      assert waiting_block_count(view) == 1

      # A late result for the now-cancelled detail flow is stale.
      send(view.pid, {:chatgpt_signin_result, "flow-detail", {:ok, %{account: "ghost"}}})
      render(view)

      refute assigns(view).profile_form_draft["siwc_account"] == "ghost"
      assert has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")

      # The current flow's success flips ONLY the status surface.
      send(view.pid, {:chatgpt_signin_result, "flow-status", {:ok, %{account: "work"}}})
      await_page_sign_in(view, :ok, {:status, @profile_id})

      assert assigns(view).profile_form_draft["siwc_account"] == "work"
      refute has_element?(view, "#" <> status_panel(@profile_id) <> "-waiting")
      # The detail surface is idle, never showing the status flow's phase.
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in")
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")
      refute has_element?(view, "#" <> detail_panel(@profile_id) <> "-sign-in-error")
    end

    test "a wizard flow ignores a result for another surface's flow", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: "flow-wizard", url: @flow_url, port: 48_123}})
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)

      view |> element("#settings-chatgpt-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, :wizard)
      assert has_element?(view, "#settings-chatgpt-waiting")

      send(view.pid, {:chatgpt_signin_result, "flow-detail", {:ok, %{account: "ghost"}}})
      render(view)

      assert assigns(view).chatgpt_sign_in.surface == :wizard
      assert assigns(view).chatgpt_sign_in.flow_id == "flow-wizard"
      assert has_element?(view, "#settings-chatgpt-waiting")
      refute assigns(view).provider_wizard.draft["siwc_account"] == "ghost"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 8. cancel-on-close — dismissing a surface abandons its flow
  # ═══════════════════════════════════════════════════════════════════════════
  describe "cancel-on-close" do
    test "closing the add-account wizard abandons its waiting flow", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)

      view |> element("#settings-chatgpt-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, :wizard)
      assert has_element?(view, "#settings-chatgpt-waiting")

      render_hook(view, "provider_wizard_cancel", %{})
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @async_wait_budget_ms

      refute has_element?(view, "#provider-wizard")
      refute has_element?(view, "#settings-chatgpt-waiting")

      # A late poll result must not resurface on any surface.
      send(view.pid, {:chatgpt_signin_result, @flow_id, {:ok, %{account: "ghost"}}})
      render(view)

      refute render(view) =~ "-chatgpt-waiting"
      refute render(view) =~ "-chatgpt-sign-in-error"
    end

    test "collapsing the expanded account abandons its detail flow", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")

      # `edit_provider_profile` toggles the open row closed.
      render_hook(view, "edit_provider_profile", %{"profile_id" => @profile_id})
      await_config_save(view)
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @async_wait_budget_ms

      assert assigns(view).editing_profile_id == nil
      refute render(view) =~ "-chatgpt-waiting"

      send(view.pid, {:chatgpt_signin_result, @flow_id, {:ok, %{account: "ghost"}}})
      render(view)

      refute render(view) =~ "-chatgpt-waiting"
      refute render(view) =~ "-chatgpt-sign-in-error"
      assert assigns(view).profile_form_draft in [nil, %{}]
    end

    test "switching nodes abandons the waiting flow", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)

      view |> element("#" <> detail_panel(@profile_id) <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      assert has_element?(view, "#" <> detail_panel(@profile_id) <> "-waiting")

      target = "chatgpt-switch-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: target,
          name: "Switch Remote"
        })

      on_exit(fn -> EvoGit.RemoteConnections.delete(target) end)

      render_patch(view, "/settings?node=" <> target)
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @async_wait_budget_ms

      # The reset page owns no surface, so a late result can land nowhere.
      send(view.pid, {:chatgpt_signin_result, @flow_id, {:ok, %{account: "ghost"}}})
      render(view)

      refute render(view) =~ "-chatgpt-waiting"
      refute render(view) =~ "-chatgpt-sign-in-error"
      refute assigns(view).chatgpt_sign_in.flow_id
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 9. the MANUAL "paste the redirect URL" fallback
  # ═══════════════════════════════════════════════════════════════════════════
  describe "manual paste fallback" do
    test "a pasted redirect URL reaches the same flow and keeps it waiting", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: %{},
        submit: {:ok, %{id: @flow_id}}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)
      panel = detail_panel(@profile_id)
      view |> element("#" <> panel <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      html = render(view)
      # The disclosure is ALWAYS in the waiting DOM (this page may be viewed
      # from a machine that cannot reach the flow's loopback listener) and it
      # names the exact address the flow expects from its own port.
      assert html =~ panel <> "-sign-in-paste-hint"
      assert html =~ panel <> "-sign-in-paste-input"
      assert html =~ panel <> "-sign-in-paste-submit"
      assert html =~ "http://127.0.0.1:48123/auth/callback"
      typed = "http://127.0.0.1:48123/auth/callback?code=abc&state=s1"

      view
      |> element("#" <> panel <> "-sign-in-paste-input")
      |> render_change(%{
        "value" => typed,
        "surface" => "detail",
        "profile_id" => @profile_id
      })

      # `phx-change` records the text verbatim and calls nothing.
      assert assigns(view).chatgpt_sign_in.paste == typed
      assert assigns(view).chatgpt_sign_in.paste_error == nil
      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0
      view |> element("#" <> panel <> "-sign-in-paste-submit") |> render_click()
      assert_receive {:chatgpt_stub, :submit, @flow_id, ^typed}, @async_wait_budget_ms
      state = assigns(view).chatgpt_sign_in
      # The flow ACKED the paste; the terminal result still rides the poll.
      assert state.phase == :waiting
      assert state.paste == ""
      assert state.paste_error == nil
      assert has_element?(view, "#" <> panel <> "-waiting")
      refute has_element?(view, "#" <> panel <> "-sign-in-paste-error")
    end

    # The REAL browser payload for a keystroke in the paste input: an
    # input-level `phx-change` makes LiveView serialize the enclosing form's
    # VALUES (so `"paste"` arrives) while `phx-value-*` is read from the FORM,
    # never the input — so the payload carries no `"surface"`, no
    # `"profile_id"` and no `"value"`. A page that reads `params["value"]`
    # therefore always saw a blank paste and answered "no authorization code".
    test "a keystroke in the paste input lands on the waiting attempt (real payload)", %{
      conn: conn
    } do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: %{},
        submit: {:ok, %{id: @flow_id}}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)
      panel = detail_panel(@profile_id)
      view |> element("#" <> panel <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})
      typed = "http://localhost:1455/auth/callback?code=ac.1.abc&state=s1"
      render_change(view, "chatgpt_sign_in_paste", %{"paste" => typed, "_target" => "paste"})
      # Recorded verbatim, from the input's OWN field name.
      assert assigns(view).chatgpt_sign_in.paste == typed
      assert assigns(view).chatgpt_sign_in.paste_error == nil
      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0
      # The submit button carries its `phx-value-*` (and an empty `.value`), so
      # the recorded paste is what reaches the flow.
      view |> element("#" <> panel <> "-sign-in-paste-submit") |> render_click()
      assert_receive {:chatgpt_stub, :submit, @flow_id, ^typed}, @async_wait_budget_ms
      state = assigns(view).chatgpt_sign_in
      assert state.phase == :waiting
      assert state.paste == ""
      assert state.paste_error == nil
      refute has_element?(view, "#" <> panel <> "-sign-in-paste-error")
    end

    test "a rejected paste keeps the waiting panel with an inline error", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        statuses: %{},
        submit: {:error, :invalid_callback}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)
      panel = detail_panel(@profile_id)
      view |> element("#" <> panel <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})

      view
      |> element("#" <> panel <> "-sign-in-paste-input")
      |> render_change(%{
        "value" => "code=stale",
        "surface" => "detail",
        "profile_id" => @profile_id
      })

      view |> element("#" <> panel <> "-sign-in-paste-submit") |> render_click()
      assert_receive {:chatgpt_stub, :submit, @flow_id, "code=stale"}, @async_wait_budget_ms
      state = assigns(view).chatgpt_sign_in
      # Still WAITING with a retryable inline rejection — never a terminal
      # error phase, and the pasted text is kept for correction.
      assert state.phase == :waiting
      assert state.paste_error == :invalid_callback
      assert state.reason == nil
      assert state.paste == "code=stale"
      assert has_element?(view, "#" <> panel <> "-waiting")
      error = view |> element("#" <> panel <> "-sign-in-paste-error") |> render()
      assert error =~ "does not belong to this sign-in"
      refute error =~ "invalid_callback"
      refute has_element?(view, "#" <> panel <> "-sign-in-error")
    end

    test "a paste for a superseded surface never reaches the flow", %{conn: conn} do
      ChatGPTStub.install!(
        begin: [
          {:ok, %{id: "flow-detail", url: @flow_url, port: 48_123}},
          {:ok, %{id: "flow-status", url: @flow_url, port: 48_123}}
        ],
        statuses: %{}
      )

      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)
      detail = detail_panel(@profile_id)
      status = status_panel(@profile_id)
      view |> element("#" <> detail <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})

      view
      |> element("#" <> detail <> "-sign-in-paste-input")
      |> render_change(%{
        "value" => "code=detail",
        "surface" => "detail",
        "profile_id" => @profile_id
      })

      # A NEW sign-in on another surface abandons the detail attempt.
      view |> element("#" <> status <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :cancel, "flow-detail"}, @async_wait_budget_ms
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:status, @profile_id})
      refute has_element?(view, "#" <> detail <> "-waiting")
      # A paste addressed to the superseded detail surface is dropped before the
      # flow is called, and it never resurrects the detail waiting panel.
      for event <- ["chatgpt_sign_in_paste", "chatgpt_sign_in_submit"] do
        render_click(view, event, %{
          "surface" => "detail",
          "profile_id" => @profile_id,
          "value" => "code=stale"
        })
      end

      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0
      state = assigns(view).chatgpt_sign_in
      assert state.phase == :waiting
      assert state.paste == ""
      assert ChatGPTSignInState.surface(state) == {:status, @profile_id}
      assert has_element?(view, "#" <> status <> "-waiting")
      refute has_element?(view, "#" <> detail <> "-waiting")
      refute has_element?(view, "#" <> detail <> "-sign-in-paste-error")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 10. the paste input never leaks into a provider draft
  # ═══════════════════════════════════════════════════════════════════════════
  # The waiting panel's `name="paste"` input lives INSIDE the provider-detail
  # form, so LiveView serializes the typed redirect with every provider-field
  # change. The draft boundary (`ProviderProfiles.submission/2`) drops it, and
  # these tests pin that end to end: the draft stays clean while the panel keeps
  # the typed text. `provider_wizard_change` gets the same treatment because the
  # same panel can sit inside a wizard-step form.
  describe "the sign-in paste input never enters a provider draft" do
    @paste "http://127.0.0.1:48123/auth/callback?code=abc&state=xyz"

    test "a provider-field change keeps paste out of the expanded account's draft", %{
      conn: conn
    } do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      seed_openai_codex_profile()
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, @profile_id)
      panel = detail_panel(@profile_id)

      view |> element("#" <> panel <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, {:detail, @profile_id})

      view
      |> element("#" <> panel <> "-sign-in-paste-input")
      |> render_change(%{"value" => @paste, "surface" => "detail", "profile_id" => @profile_id})

      assert assigns(view).chatgpt_sign_in.paste == @paste

      # The whole enclosing form is serialized, paste included — exactly what a
      # keystroke in any provider field sends.
      render_change(view, "provider_profile_form_change", %{
        "paste" => @paste,
        "profile_id" => @profile_id,
        "name" => "Renamed account",
        "provider" => "openai_codex",
        "auth_mode" => "oauth"
      })

      draft = assigns(view).profile_form_draft
      refute Map.has_key?(draft, "paste")
      assert draft["name"] == "Renamed account"

      # The sign-in fallback keeps its typed text on the SAME panel.
      assert assigns(view).chatgpt_sign_in.paste == @paste
      input = view |> element("#" <> panel <> "-sign-in-paste-input") |> render()
      assert attr(input, "name") == "paste"
      assert attr(input, "value") == @paste
      assert has_element?(view, "#" <> panel <> "-waiting")
    end

    test "a provider_wizard_change keeps paste out of the wizard draft", %{conn: conn} do
      ChatGPTStub.install!(begin: {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)
      panel = "settings-chatgpt"

      view |> element("#" <> panel <> "-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}, @async_wait_budget_ms
      await_page_sign_in(view, :waiting, :wizard)

      view
      |> element("#" <> panel <> "-sign-in-paste-input")
      |> render_change(%{"value" => @paste, "surface" => "wizard"})

      assert assigns(view).chatgpt_sign_in.paste == @paste

      render_hook(view, "provider_wizard_change", %{
        "paste" => @paste,
        "provider" => "openai_codex",
        "siwc_account" => "default"
      })

      wizard = assigns(view).provider_wizard
      refute Map.has_key?(wizard.draft, "paste")
      assert wizard.draft["provider"] == "openai_codex"
      assert assigns(view).chatgpt_sign_in.paste == @paste
      input = view |> element("#" <> panel <> "-sign-in-paste-input") |> render()
      assert attr(input, "value") == @paste
      assert has_element?(view, "#" <> panel <> "-waiting")
    end
  end
end
