# Settings page (`/settings`) suite.
#
# Split across modules for the suite's async policy (see `test/CONTEXT.md`):
# `EvoDashWeb.SettingsLiveTest` is the ASYNC module — every test there touches
# only per-process state, so config isolation comes from the `:config_dir_fun`
# seam (`EvoDash.Test.ConfigDir.isolate!/1`, installed by `test_helper.exs`)
# instead of a BEAM-global `XDG_CONFIG_HOME` write — and
# `EvoDashWeb.SettingsLiveGlobalStateTest` is the SYNC module holding the few
# tests that mutate a genuinely process-wide value: the
# `:nix_available_override` / `:platform_os_override` app-env seams (shared with
# the `async: true` `EvoDashWeb.PlatformInfoTest`) and the boot-time
# `EvoGit.AgentScheduler` (pause/resume). ExUnit drains every async module
# before any sync one starts, so those mutations can never overlap.
#
# Layout follows the established precedent in `review_live_test.exs`: async
# modules first, sync module(s) last, and the helpers shared by both modules in
# one `EvoDashWeb.SettingsLiveTest.Helpers` module exported from this file.
# Every test body is unchanged by the split.
#
# LOAD-ORDER CONSTRAINT: the fake connection managers
# (`EvoDashWeb.SettingsLiveTest.ConnectionManager` / `.BootstrapManager` /
# `.ConnectManager`) are declared ABOVE the async module, next to the helpers.
# An `async: true` module is handed to ExUnit's runner as soon as its
# `defmodule` is evaluated — while the rest of the file is still being loaded —
# so a test in it that starts a module defined FURTHER DOWN the file can race
# the loader (`start_supervised!` → "module … does not exist"). Modules used by
# an async test must therefore precede it; only the sync module may sit last.

defmodule EvoDashWeb.SettingsLiveTest.Helpers do
  @moduledoc false
  # Helpers shared by the two settings-page suites, imported as
  # `EvoDashWeb.SettingsLiveTest.Helpers`. Public instead of private because the
  # suite is split across modules; bodies are unchanged apart from that.
  use EvoDashWeb, :verified_routes
  # `Phoenix.LiveViewTest.live/2` is a MACRO that expands to
  # `__live__(get(conn, path), ...)`, so the caller needs `get/2` — in a
  # ConnCase module it arrives via `use EvoDashWeb.ConnCase`, here explicitly.
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import ExUnit.Callbacks

  # Load-tolerant budgets for waits on ASYNC settings work (mount load chain,
  # owned config-save receipt, provider-request round trips). That work runs in
  # supervised tasks on a shared host whose scheduling swings 10-30x
  # (test/CONTEXT.md), so the previous 1-5 s budgets intermittently expired.
  # The waits stay bounded and still fail loudly — only the deadlines moved.
  @async_wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be starved for
  # seconds on a loaded host, where the 5 s default exits the test.
  @assigns_timeout_ms 30_000

  # The same load-tolerant budget for `assert_receive` / poll deadlines in the
  # test modules below (module attributes are not importable across modules).
  def async_wait_budget, do: @async_wait_budget_ms

  # ───────────────────────────────────────────────────────────────────────────
  # Mount helper — deterministic settle of the page's ASYNC loads
  # ───────────────────────────────────────────────────────────────────────────
  #
  # Every Settings page mount kicks off an async load on EvoDash.TaskSupervisor:
  # `SettingsLive.NodeData.start/3` (from handle_params/3) reads config.toml and
  # reports back `{:settings_node_data_loaded, node, category, results}`, whose
  # handler REPLACES the `:file_config` assign with the snapshot it read; the
  # NodeAware hook additionally spawns its sidebar fetch. The node-data task
  # reads the config at its START but only sends the message after its remaining
  # work, so under scheduler load the apply routinely lands AFTER the first event
  # a test drives — reverting the state the test just mutated (that is what
  # intermittently broke the editor/save/list-editing assertions in full-suite
  # runs: `current_models/1` came back empty, and the editor render lost the
  # profile being edited).
  #
  # `mount_settings/2` funnels every mount in this file through a deterministic
  # settle: wait for THIS mount's async tasks to exit, then drain their result
  # messages (render/1 performs a synchronous round-trip, so everything queued
  # before it — including the node-data apply — is processed first). Only then is
  # the view handed to the test, so no stale apply can arrive mid-test.
  #
  # The ORIGINAL mount HTML is returned unchanged: the "shell seeding (async
  # platform gating)" describe asserts on the seed-shell render that live/3
  # always returns.
  def mount_settings(conn, path) do
    {:ok, view, html} = Phoenix.LiveViewTest.live(conn, path)
    await_mount_async_loads(view)
    {:ok, view, html}
  end

  # Waits until every EvoDash.TaskSupervisor child started by THIS LiveView
  # process has exited, then flushes their result messages into the view.
  # Task.Supervisor records the spawning process in the child's `$callers`
  # process-dictionary entry, so matching it against the view pid targets exactly
  # this mount's tasks — a leftover task from another test is never waited on
  # (and cannot block the mount).
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
        @async_wait_budget_ms -> :ok
      end
    end)

    # No render here: the test's next synchronous call (render_hook /
    # :sys.get_state / render) drains the queued result messages first, because
    # the LiveView processes its mailbox in order.
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

  # Mutations acknowledge dispatch before the off-process write/read completes.
  # Always assert the authoritative completion, not the dispatch render.
  def settings_hook(view, event, params) do
    Phoenix.LiveViewTest.render_hook(view, event, params)
    await_config_save(view)
  end

  def await_config_save(view) do
    wait_settings(view, &(not &1[:config_saving]))
    render(view)
  end

  def wait_settings(view, predicate, deadline \\ nil) do
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

  # In LiveView 1.x the test View struct has no `.assigns` field, so we read
  # them from the underlying LiveView process socket.
  def assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # Builds a deterministic NodeData results map for the currently viewed node
  # by applying the pure PlatformInfo filters to the UNFILTERED schemas
  # snapshot (`:all_schemas_by_category`). The platform computation
  # short-circuits on the `:platform_os_override` / `:nix_available_override`
  # app-env seams (checked FIRST by PlatformInfo), so the result is
  # deterministic on ANY host. `overrides` win per-key for tests that want a
  # different value than the current env computes.
  def default_node_results(view, overrides) do
    overrides = Map.new(overrides)
    assigns = assigns(view)
    node = assigns[:current_node]
    all_schemas = assigns[:all_schemas_by_category]
    platform_os = Map.get(overrides, :platform_os, EvoDashWeb.PlatformInfo.os_for_node(node))

    filtered =
      Map.get(
        overrides,
        :filtered_schemas_by_category,
        EvoDashWeb.PlatformInfo.filter_nix_category(
          EvoDashWeb.PlatformInfo.filter_schemas_by_category(all_schemas, platform_os),
          node
        )
      )

    Map.merge(
      %{
        platform_os: platform_os,
        filtered_schemas_by_category: filtered,
        file_config: assigns[:file_config] || %{},
        config_status: assigns[:config_status] || %{},
        remote_config_error: nil,
        custom_agents: %{
          agents: assigns[:custom_agents] || [],
          model_selection_script: assigns[:model_selection_script] || "",
          script_status: assigns[:script_status] || :ok
        }
      },
      overrides
    )
  end

  # Deterministically delivers a NodeData result (the async task's message)
  # to the view and drains the mailbox via render — the established direct-
  # send pattern for tests asserting async-loaded content. Tagged with the
  # CURRENT node so it passes the stale-guard. The real task (same node, same
  # deterministic values under the override seams) sends its message before
  # ours, so ours is processed last — assertions are race-free.
  def deliver_node_data(view, category_param \\ nil, overrides \\ %{}) do
    state = assigns(view)

    send(
      view.pid,
      {{:settings_node_data_loaded, state.settings_load_seq,
        {state.current_node_id, state.current_node}}, state.current_node, category_param,
       {:ok, default_node_results(view, overrides)}}
    )

    render(view)
  end

  def write_paths(view) do
    get_in(assigns(view).file_config, [:sandbox, :write_paths])
  end

  # Seeds config.toml before mounting the LiveView. Every test's `setup`
  # activates its own per-process config dir (the `:config_dir_fun` seam), so
  # EvoGit.Config.config_path() is unique to this test and resolve() picks the
  # file up via its path-keyed, mtime+size-validated cache. The explicit
  # on_exit rm is belt-and-braces (the setup already rm_rf!'s the whole temp
  # dir).
  def seed_write_paths(paths) do
    path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[sandbox]\nwrite_paths = #{inspect(paths)}\n")

    on_exit(fn ->
      # Teardown cleanup must not mask test failures.
      File.rm(path)
    end)
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.ProjectsLiveTest.ConnectionManager). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.SettingsLiveTest.ConnectionManager do
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

# A fake manager for bootstrap flows. Registered in
# `EvoGit.RemoteConnection.Registry` under the target id, it answers the
# GenServer `:bootstrap` / `{:bootstrap, opts}` call that
# `EvoGit.RemoteConnection.bootstrap/1,2` routes to it, records every call in
# `calls` (read back via `GenServer.call(manager, :calls)`), and serves
# `:status` — used by `EvoDash.NodeContext.connection_status/0` inside the
# `{:bootstrap_complete, ...}` handler's `reload_remote_statuses/1`.
# `delay_ms` optionally holds the `:bootstrap` reply back so a test can keep a
# bootstrap "in flight" (e.g. the double-click guard).
defmodule EvoDashWeb.SettingsLiveTest.BootstrapManager do
  use GenServer

  def start_link({target_id, result, delay_ms}) do
    GenServer.start_link(__MODULE__, {target_id, result, delay_ms})
  end

  @impl true
  def init({target_id, result, delay_ms}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, %{target_id: target_id, result: result, delay_ms: delay_ms, released: false, calls: []}}
  end

  @impl true
  def handle_call(:bootstrap, _from, state), do: reply_bootstrap(state, :bootstrap)

  @impl true
  def handle_call({:bootstrap, opts}, _from, state),
    do: reply_bootstrap(state, {:bootstrap, opts})

  @impl true
  def handle_call(:status, _from, state) do
    # A disconnected status keeps `reload_remote_statuses/1` from crashing on a
    # nil/non-map value while a bootstrap result is being handled.
    {:reply,
     %{phase: :disconnected, node: nil, last_error: nil, target: nil, bootstrap_stage: nil},
     state}
  end

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

  @impl true
  def handle_call(_other, _from, state), do: {:reply, {:error, :unexpected_call}, state}

  # `:release` may land BEFORE the gated call (the spawned task has not reached
  # the manager yet) — remember it so hold_reply/2 does not block.
  @impl true
  def handle_info(:release, state), do: {:noreply, %{state | released: true}}

  defp reply_bootstrap(state, call) do
    hold_reply(state.delay_ms, state.released)
    {:reply, state.result, %{state | calls: state.calls ++ [call]}}
  end

  # Parks the reply until the test sends `:release` (`delay_ms: :gate`) — a
  # deterministic in-flight window with no wall-clock sleep, so the test can
  # assert the "still running" state without racing the completion. Integer
  # delays are still honoured for callers that want a timed hold.
  defp hold_reply(:gate, false) do
    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  defp hold_reply(ms, _released?) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp hold_reply(_delay, _released?), do: :ok
end

# A fake manager for the async remote-connection connect flow. Registered in
# `EvoGit.RemoteConnection.Registry` under the target id, it answers the
# GenServer `:connect` call that `EvoGit.RemoteConnection.connect/1` routes to
# it with `connect_result` (default `{:ok, :connecting}`) after `delay_ms`,
# records every call in `calls` (read back via `GenServer.call(manager,
# :calls)`), and serves `:status` — used by `NodeContext.connection_status/0`
# when the page recomputes `@remote_statuses` after a broadcast. Tests drive
# the row's phase with `{:set_status, status}` (mirroring the real core:
# manager state changes first, THEN the broadcast fires).
defmodule EvoDashWeb.SettingsLiveTest.ConnectManager do
  use GenServer

  def start_link({target_id, status, connect_result, delay_ms}) do
    GenServer.start_link(__MODULE__, {target_id, status, connect_result, delay_ms})
  end

  @impl true
  def init({target_id, status, connect_result, delay_ms}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)

    {:ok,
     %{
       status: status,
       connect_result: connect_result,
       delay_ms: delay_ms,
       released: false,
       calls: []
     }}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    hold_reply(state.delay_ms, state.released)
    {:reply, state.connect_result, %{state | calls: state.calls ++ [:connect]}}
  end

  @impl true
  def handle_call({:set_status, status}, _from, state) do
    {:reply, :ok, %{state | status: status}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:calls, _from, state) do
    {:reply, state.calls, state}
  end

  @impl true
  def handle_call(_other, _from, state), do: {:reply, {:error, :unexpected_call}, state}

  # See BootstrapManager: a `:release` that arrives before the gated call is
  # remembered, so hold_reply/2 does not block.
  @impl true
  def handle_info(:release, state), do: {:noreply, %{state | released: true}}

  # See BootstrapManager.hold_reply/2 — `delay_ms: :gate` parks the reply until
  # the test sends `:release` (deterministic in-flight window, no sleep).
  defp hold_reply(:gate, false) do
    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  defp hold_reply(ms, _released?) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp hold_reply(_delay, _released?), do: :ok
end

defmodule EvoDashWeb.SettingsLiveTest.StreamEndpoint do
  @moduledoc false
  # A test-local loopback endpoint captures the FINAL ReqLLM wire request;
  # no vendor endpoint or ambient account is ever contacted.
  def init(owner), do: owner

  def call(conn, owner) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(owner, {:settings_llm_request, conn.req_headers, Jason.decode!(body)})

    chunks = [
      %{type: "response.output_text.delta", delta: "hello", output_index: 0, content_index: 0},
      %{
        type: "response.completed",
        response: %{id: "settings-response", status: "completed", output: []}
      }
    ]

    response = Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, response <> "data: [DONE]\n\n")
  end
end

defmodule EvoDashWeb.SettingsLiveParentAdapterTest do
  # Parent-component/handler contracts plus a loopback-only final-request check;
  # configuration and custom credentials remain per-process isolated.
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  # Load-tolerant budget for the loopback provider-request round trip below
  # (the shared host's scheduling swings 10-30x per test/CONTEXT.md).
  import EvoDashWeb.SettingsLiveTest.Helpers, only: [async_wait_budget: 0]
  alias EvoDashWeb.{SettingsComponents, SettingsLive}

  defp socket(draft, editing \\ "new") do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: nil,
        flash: %{},
        editing_profile_id: editing,
        profile_form_draft: draft,
        profile_advanced_open: nil,
        file_config: %{llm: %{providers: []}}
      }
    }
  end

  test "parent category adapts saved flat generation and nested drafts to editor input names" do
    profile = %{
      "id" => "account",
      "provider" => "openai",
      "default_model" => "example",
      "temperature" => 0.7,
      "provider_options" => %{"store" => false},
      "models" => [%{"model" => "example", "max_tokens" => 2048}]
    }

    html =
      render_component(&SettingsComponents.category_section/1,
        category: :llm,
        schemas: [],
        file_config: %{llm: %{default_provider_profile: "account"}},
        provider_profiles: [profile],
        editing_profile_id: "account"
      )

    doc = Floki.parse_document!(html)
    assert Floki.attribute(doc, ~s(input[name="generation[temperature]"]), "value") == ["0.7"]

    assert Floki.attribute(doc, ~s(input[name="models[0][generation][max_tokens]"]), "value") == [
             "2048"
           ]

    assert Floki.text(Floki.find(doc, ~s(textarea[name="generation[provider_options]"]))) ==
             ~s({&quot;store&quot;:false})

    assert Floki.find(
             doc,
             ~s(form[phx-submit="save_provider_profile"][phx-change="provider_profile_form_change"])
           ) != []

    refute Floki.find(doc, ~s(input[name="temperature"])) != []
    assert Floki.find(doc, ~s(button[phx-click="cancel_edit_provider_profile"])) != []
    draft = %{"generation" => %{"temperature" => ""}, "models" => []}

    html =
      render_component(&SettingsComponents.category_section/1,
        category: :llm,
        schemas: [],
        file_config: %{llm: %{providers: [profile]}},
        provider_profiles: [profile],
        editing_profile_id: "account",
        profile_form_draft: draft
      )

    doc = Floki.parse_document!(html)
    assert Floki.attribute(doc, ~s(input[name="generation[temperature]"]), "value") == [""]
    assert Floki.find(doc, ~s(input[name="models[0][model]"])) == []
  end

  test "parent change and row aliases preserve nested generation and numerically order rows" do
    input = %{
      "generation" => %{"temperature" => "0.7"},
      "off_peak_days" => "weekends",
      "models" => %{
        "10" => %{"model" => "ten"},
        "2" => %{"model" => "two", "generation" => %{"max_tokens" => "42"}}
      },
      "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "12:00", "days" => "mon"}}
    }

    assert {:noreply, changed} =
             SettingsLive.handle_event("provider_profile_form_change", input, socket(%{}))

    assert changed.assigns.profile_form_draft["generation"] == input["generation"]
    assert Enum.map(changed.assigns.profile_form_draft["models"], & &1["model"]) == ["two", "ten"]
    assert changed.assigns.profile_form_draft["off_peak_days"] == ["weekends"]

    assert changed.assigns.profile_form_draft["peak_hours"] == [
             %{start: "09:00", end: "12:00", days: ["mon"]}
           ]

    assert {:noreply, added} = SettingsLive.handle_event("add_provider_model", %{}, changed)

    assert added.assigns.profile_form_draft["models"] ==
             changed.assigns.profile_form_draft["models"] ++ [%{"model" => ""}]

    # Form changes normalize peak rows to atom keys; row actions stringify the
    # detached draft again. Allow only that representation change, not lost fields
    # or unrelated socket changes (including profile_generated_id bookkeeping).
    expected_draft =
      Map.put(changed.assigns.profile_form_draft, "peak_hours", [
        %{"start" => "09:00", "end" => "12:00", "days" => ["mon"]}
      ])

    expected = %{changed | assigns: %{changed.assigns | profile_form_draft: expected_draft}}
    assert Map.fetch!(expected.assigns, :profile_generated_id) == nil

    assert {:noreply, ^expected} =
             SettingsLive.handle_event("remove_provider_model", %{"index" => "2"}, added)

    for index <- ["-1", "99", "invalid"] do
      assert {:noreply, ^expected} =
               SettingsLive.handle_event("remove_provider_model", %{"index" => index}, expected)
    end

    assert {:noreply, peak} =
             SettingsLive.handle_event("add_provider_peak_hours_row", %{}, changed)

    assert length(peak.assigns.profile_form_draft["peak_hours"]) == 2

    assert {:noreply, ^expected} =
             SettingsLive.handle_event("remove_provider_peak_hours_row", %{"index" => "1"}, peak)

    assert {:noreply, cancelled} =
             SettingsLive.handle_event("cancel_edit_provider_profile", %{}, changed)

    assert cancelled.assigns.profile_form_draft == nil
    assert cancelled.assigns.editing_profile_id == nil
    assert cancelled.assigns.file_config == changed.assigns.file_config

    for event <- [
          "add_provider_model",
          "add_provider_peak_hours_row",
          "provider_profile_form_change"
        ] do
      assert {:noreply, ^cancelled} = SettingsLive.handle_event(event, %{}, cancelled)
    end
  end

  @tag :requires_schema_facade
  test "connection selection resolves the persisted model's inherited generation and credential opts" do
    dir = EvoDash.Test.ConfigDir.isolate!("settings-final-request")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(EvoGit.Config.config_dir())
    # This custom name intentionally has no API_KEY suffix: credential loading
    # therefore does not write a process-global ReqLLM provider key.
    File.write!(
      EvoGit.Config.credentials_path(),
      ~s(GENESIS_SETTINGS_FIXTURE = "fixture-not-for-network"\n)
    )

    server =
      start_supervised!(
        {Bandit,
         plug: {EvoDashWeb.SettingsLiveTest.StreamEndpoint, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}/v1"

    profile = %{
      "id" => "account",
      "provider" => "openai",
      "default_model" => "gpt-4.1-mini",
      "api_key_env_var" => "GENESIS_SETTINGS_FIXTURE",
      "base_url" => endpoint,
      "temperature" => 0.7,
      "max_tokens" => 4096,
      "provider_options" => %{"store" => false},
      "models" => [
        %{"model" => "gpt-4.1-mini"},
        %{"model" => "gpt-4.1", "temperature" => 0.0, "max_tokens" => 2048}
      ]
    }

    config = %{llm: %{providers: [profile], default_provider_profile: "account"}}
    alias EvoDashWeb.SettingsLive.ConfigIO

    assert {:ok, inherited} =
             ConfigIO.resolve_model_spec(config, %{
               provider_profile_id: "account",
               model: "gpt-4.1-mini"
             })

    assert inherited.model_spec == %{
             provider: :openai,
             id: "gpt-4.1-mini",
             base_url: endpoint
           }

    assert inherited.generation_params[:temperature] == 0.7
    assert inherited.generation_params[:max_tokens] == 4096
    assert inherited.generation_params[:provider_options][:store] == false

    assert {:ok, overridden} =
             ConfigIO.resolve_model_spec(config, %{
               provider_profile_id: "account",
               model: "gpt-4.1"
             })

    assert overridden.generation_params[:temperature] == 0.0
    assert overridden.generation_params[:max_tokens] == 2048

    for {resolved, model, max_tokens} <- [
          {inherited, "gpt-4.1-mini", 4096},
          {overridden, "gpt-4.1", 2048}
        ] do
      assert {:ok, %{response: "hello"}} =
               EvoGit.SystemCheck.llm_test(resolved.model_spec, resolved.generation_params)

      assert_receive {:settings_llm_request, headers, body}, async_wait_budget()

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Bearer fixture-not-for-network"}

      assert body["model"] == model
      assert body["max_output_tokens"] == max_tokens
      assert body["store"] == false
    end
  end
end

defmodule EvoDashWeb.SettingsLiveTest do
  # ASYNC: everything here touches only per-process state — the config
  # directory comes from the `:config_dir_fun` seam (`setup` below), never from
  # a BEAM-global `XDG_CONFIG_HOME` write, and the mounted LiveView plus every
  # async load task it spawns inherits that override through `$callers`. The
  # tests that mutate a process-wide app-env seam or the boot-time
  # `EvoGit.AgentScheduler` live in `EvoDashWeb.SettingsLiveGlobalStateTest`
  # (`async: false`) at the bottom of this file.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import EvoDashWeb.SettingsLiveTest.Helpers

  setup do
    # Isolate this test's config directory PER PROCESS through the
    # `:config_dir_fun` seam (`EvoDash.Test.ConfigDir`, installed by
    # `test/test_helper.exs`).
    # SettingsLive.mount/1 calls load_file_config() → EvoGit.Config.resolve(),
    # which reads config.toml from EvoGit.Config.config_dir/0, so an EMPTY
    # per-test temp dir guarantees no config.toml exists and schema defaults
    # (e.g. nix.enabled = false) are used — making the tests deterministic
    # regardless of host env.
    # `isolate!/1` writes the per-process override (`<dir>/genesis` is the
    # concrete config dir), so nothing is BEAM-global and no env restore is
    # needed.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_test_config")
    on_exit(fn -> File.rm_rf!(dir) end)

    # ActiveTasks is a process-less public ETS table shared by the whole run.
    # This module is `async: true`, so clear ONLY the local `{nil, node()}`
    # context — a whole-table reset would delete a concurrent module's
    # per-test snapshot between its put and its get.
    EvoDash.ActiveTasks.invalidate(nil, node())

    :ok
  end

  # The page renders TWO banners from the same `@config_status`: the settings
  # card banner (`EvoDashWeb.SettingsLive`, with a call-to-action sentence) and
  # the fixed bottom-right `EvoDashWeb.Layouts` banner (model-neutral
  # "Configure now →"). Both list the SAME detail lines from
  # `EvoDashWeb.ConfigIssues.lines/1`, so these page-wide assertions cover both
  # surfaces; every string asserted is unique to one surface/variant so the two
  # banners cannot mask each other.
  test "the settings window keeps the provider wizard and category navigation in the window", %{
    conn: conn
  } do
    {:ok, view, _html} = mount_settings(conn, ~p"/settings/window")

    assert has_element?(view, "#workbench-window-content #provider-profiles-panel")
    assert has_element?(view, "#workbench-settings-server-form")
    refute has_element?(view, "#sidebar")

    view
    |> element("#workbench-settings-nav button[phx-value-category=appearance]")
    |> render_click()

    assert_patch(view, ~p"/settings/window?category=appearance")
    assert has_element?(view, "#workbench-preferences")
    refute has_element?(view, "#workbench-settings-server-form")

    view
    |> element("#workbench-settings-nav button[phx-value-category=llm]")
    |> render_click()

    assert_patch(view, ~p"/settings/window?category=llm")
    assert has_element?(view, "#provider-profiles-panel")
  end

  describe "config status banner (warnings + validation errors)" do
    @neutral_cta "Fix the settings listed above to resolve these issues."
    @model_cta "Configure your LLM model in the LLM category to resolve these issues."

    test "validation-error-only status shows the formatted error and the neutral call to action",
         %{conn: conn} do
      # The real-world motivating report: `ok?: false` with NOTHING missing and
      # no warnings — a bad provider timezone. The banner used to render a title
      # with zero detail lines and an unfounded model accusation.
      status = %{
        missing: [],
        warnings: [],
        ok?: false,
        validation_errors: [
          %EvoGit.Config.Schema.ValidationError{
            key_path: [:llm, :providers, 0, :timezone],
            message: ~s{invalid timezone: :no_time_zone_database (got "UTC")}
          }
        ]
      }

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view, nil, config_status: status)

      assert html =~ "Missing Configuration"
      assert html =~ "llm.providers.0.timezone"
      assert html =~ "invalid timezone: :no_time_zone_database"
      assert html =~ @neutral_cta
      refute html =~ @model_cta
    end

    test "a missing LLM model keeps the model-specific call to action", %{conn: conn} do
      status = %{
        ok?: false,
        missing: [:llm_model],
        warnings: ["LLM model is not configured. Set [llm] model in config.toml."],
        validation_errors: []
      }

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view, nil, config_status: status)

      assert html =~ "LLM model is not configured. Set [llm] model in config.toml."
      assert html =~ @model_cta
      refute html =~ @neutral_cta
    end

    test "a healthy status with validation errors renders no banner and no error line", %{
      conn: conn
    } do
      # Bare map entry (no `ValidationError` struct): the formatter tolerates
      # plain maps with the same keys. `ok?: true` silences BOTH banners, so
      # neither the title, either call-to-action sentence, nor the formatted
      # line may appear anywhere in the rendered tree.
      status = %{
        ok?: true,
        missing: [],
        warnings: [],
        validation_errors: [
          %{key_path: [:scheduler, :max_turns], message: "must be a positive integer"}
        ]
      }

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view, nil, config_status: status)

      refute html =~ "Missing Configuration"
      refute html =~ @neutral_cta
      refute html =~ @model_cta
      refute html =~ "scheduler.max_turns"
    end
  end

  describe "settings search" do
    test "renders the search input inside a form (required for phx-change)", %{conn: conn} do
      {:ok, _view, html} = mount_settings(conn, ~p"/settings")

      assert html =~ "Filter settings..."
      # The input must sit in a <form> for phx-change to work in LiveView
      # (pushInput throws if inputEl.form is null) and carries name="value"
      # (the key the search handler reads).
      assert html =~ ~s(name="value")
      assert html =~ ~s(phx-change="search")
    end

    test "search handler with 'value' key updates search_text and shows results", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # The search handler expects %{"value" => text} (the input name is "value").
      # A mismatched key (e.g. %{"search" => text}) would silently fail to match.
      html = settings_hook(view, "search", %{"value" => "scheduler"})

      # When search_text is non-empty, the search results panel is shown
      # (the render/1 template branches on @search_text != "").
      assert html =~ "Search Results"
    end

    test "search handler shows 'no settings found' for a non-matching term", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = settings_hook(view, "search", %{"value" => "zzz_nonexistent_xyz"})

      assert html =~ "No settings found matching"
    end

    test "clearing search returns to category view", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # First type a search term
      _html = settings_hook(view, "search", %{"value" => "scheduler"})
      # Then clear it (the clear button sends phx-value-value="")
      html = settings_hook(view, "search", %{"value" => ""})

      # When search_text is empty, the category section is shown instead of
      # the search results panel.
      refute html =~ "Search Results"
    end
  end

  describe "ModelProfileHelpers.move_model_profile/3" do
    alias EvoDashWeb.SettingsLive.ModelProfileHelpers

    defp config_with(profiles) do
      %{
        llm: %{
          providers:
            Enum.map(profiles, fn profile ->
              %{
                "id" => ModelProfileHelpers.profile_id(profile),
                "provider" => "openai",
                "default_model" => "example"
              }
            end),
          default_provider_profile: "a"
        }
      }
    end

    test "moves a profile up in the middle of the list" do
      config = config_with([%{id: "a"}, %{id: "b"}, %{id: "c"}])

      moved = ModelProfileHelpers.move_model_profile(config, "b", "up")

      assert Enum.map(moved.llm.providers, &ModelProfileHelpers.profile_id/1) == ["b", "a", "c"]
    end

    test "moves a profile down in the middle of the list" do
      config = config_with([%{id: "a"}, %{id: "b"}, %{id: "c"}])

      moved = ModelProfileHelpers.move_model_profile(config, "a", "down")

      assert Enum.map(moved.llm.providers, &ModelProfileHelpers.profile_id/1) == ["b", "a", "c"]
    end

    test "unknown id leaves the config unchanged" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "nope", "up") == config
    end

    test "invalid direction leaves the config unchanged" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "a", "sideways") == config
    end

    test "empty model list leaves the config unchanged" do
      config = config_with([])

      assert ModelProfileHelpers.move_model_profile(config, "a", "up") == config
    end

    test "first profile cannot move up and last profile cannot move down" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "a", "up") == config
      assert ModelProfileHelpers.move_model_profile(config, "b", "down") == config
    end

    test "matches string- or atom-keyed profile ids" do
      config = config_with([%{"id" => "a"}, %{id: "b"}])

      config =
        put_in(config, [:llm, :providers, Access.at(1)], %{
          id: "b",
          provider: "openai",
          default_model: "example"
        })

      moved = ModelProfileHelpers.move_model_profile(config, "b", "up")

      assert Enum.map(moved.llm.providers, &ModelProfileHelpers.profile_id/1) == ["b", "a"]
    end
  end

  describe "LLM connection test rendering (map model safety)" do
    # Bug 2: The Connection Test result used to render `{data.model}` directly in
    # HEEx, but `data.model` is a MAP (e.g. %{id: "deepseek-v4-pro",
    # provider: :deepseek}) returned from EvoGit.SystemCheck.llm_test/0.
    # Maps don't implement Phoenix.HTML.Safe, so this crashed the LiveView with
    # Protocol.UndefinedError. The fix renders `model_display(data.model)` instead,
    # which formats maps into readable strings like "deepseek:deepseek-v4-pro".

    test "connection test with a map model renders the formatted string, not the raw map",
         %{conn: conn} do
      server =
        start_supervised!(
          {Bandit,
           plug: {EvoDashWeb.SettingsLiveTest.StreamEndpoint, self()},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      File.mkdir_p!(EvoGit.Config.config_dir())

      File.write!(
        EvoGit.Config.credentials_path(),
        ~s(GENESIS_SETTINGS_FIXTURE = "mounted-fixture"\n)
      )

      File.write!(EvoGit.Config.config_path(), """
      [[llm.providers]]
      id = "account"
      provider = "openai"
      default_model = "gpt-4.1-mini"
      api_key_env_var = "GENESIS_SETTINGS_FIXTURE"
      base_url = "http://127.0.0.1:#{port}/v1"
      models = ["gpt-4.1-mini"]
      """)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "test_llm", %{})
      wait_settings(view, &match?({:ok, _}, &1.llm_test_status))
      assert_receive {:settings_llm_request, headers, body}, async_wait_budget()

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Bearer mounted-fixture"}

      assert body["model"] == "gpt-4.1-mini"

      assert {:ok, %{model: %{id: "gpt-4.1-mini", provider: :openai}}} =
               assigns(view).llm_test_status

      html = render(view)
      assert html =~ "Connected"
      assert html =~ "openai:gpt-4.1-mini"

      # The old unscoped envelope, stale generation and wrong-node envelopes
      # must not replace this authoritative success with a later error.
      state = assigns(view)
      scope = {state.current_node_id, state.current_node, state.test_profile_id}
      send(view.pid, {:llm_test_result, {:error, "unscoped"}})

      send(
        view.pid,
        {{:llm_test_result, state.llm_test_seq - 1, scope}, {:ok, {:error, "stale"}}}
      )

      send(
        view.pid,
        {{:llm_test_result, state.llm_test_seq,
          {nil, :obsolete_settings@host, state.test_profile_id}}, {:ok, {:error, "wrong node"}}}
      )

      render(view)
      assert assigns(view).llm_test_status == state.llm_test_status
    end

    test "model_display/1 formats a map model into a readable provider:id string" do
      # Unit-style test on the helper that the fix delegates to. This is the core
      # guarantee that maps are formatted safely — if the integration approach
      # above ever becomes flaky, this test alone proves maps won't crash HEEx.
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "deepseek-v4-pro",
               provider: :deepseek
             }) == "deepseek:deepseek-v4-pro"
    end

    test "model_display/1 includes base_url when present in a map model" do
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "gpt-4o",
               provider: :openai,
               base_url: "https://x/v1"
             }) =~ "gpt-4o"

      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "gpt-4o",
               provider: :openai,
               base_url: "https://x/v1"
             }) =~ "https://x/v1"
    end

    test "model_display/1 passes through binary (string) models unchanged" do
      # Binary model strings (e.g. "anthropic:claude-sonnet-4") are already safe
      # to render in HEEx and should pass through identically.
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display("anthropic:claude-sonnet-4") ==
               "anthropic:claude-sonnet-4"
    end
  end

  describe "LLM connection test" do
    # Never dispatch a real local provider request. A missing remote BEAM
    # exercises the async handler and its error result without HTTP or ambient
    # credentials; current_node, NOT the remote_config flag, owns the route.
    test "canonical model selection starts off-process for either remote_config flag" do
      alias EvoDashWeb.{SettingsComponents, SettingsLive}
      alias EvoDashWeb.SettingsLive.ConfigIO

      file_config = %{
        llm: %{
          providers: [
            %{
              "id" => "account",
              "provider" => "openai",
              "default_model" => "example",
              "models" => [%{"model" => "example"}, %{"model" => "other"}]
            }
          ]
        }
      }

      selection = Enum.find(ConfigIO.model_selections(file_config), &(&1.model == "other"))
      selected = SettingsComponents.model_selection_value(selection)

      for flag <- [true, false] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: nil,
            flash: %{},
            remote_config: flag,
            llm_test_status: :idle,
            file_config: file_config,
            current_node: :"missing_settings_test@127.0.0.1",
            test_config_scope: {nil, :"missing_settings_test@127.0.0.1"},
            test_profile_id: selected
          }
        }

        assert {:noreply, result} = SettingsLive.handle_event("test_llm", %{}, socket)
        assert result.assigns.llm_test_status == :testing
        scope = {nil, :"missing_settings_test@127.0.0.1", selected}

        assert_receive {{:llm_test_result, 1, ^scope}, {:ok, {:error, _}}},
                       async_wait_budget()
      end
    end

    test "test_llm rejects a removed provider selection without starting work" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          llm_test_status: :idle,
          file_config: %{llm: %{providers: []}},
          test_config_scope: {nil, node()},
          current_node: node()
        }
      }

      assert {:noreply, result} =
               EvoDashWeb.SettingsLive.handle_event(
                 "test_llm",
                 %{"profile_id" => "removed"},
                 socket
               )

      assert result.assigns.llm_test_status == :idle
      assert result.assigns.flash["error"] == "Selected profile has no model configured."
      refute_receive {:llm_test_result, _}, 0
    end
  end

  describe "sandbox write_paths list editor" do
    # The write_paths card (:list_of_strings schema, commit 0ff33d39) renders in
    # the sandbox category (all sub_category == nil schemas) and in search
    # results. The add_list_entry / remove_list_entry events mutate only the
    # in-memory file_config — nothing persists until save_category is submitted.

    test "sandbox category renders the write_paths card without crashing", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = settings_hook(view, "select_category", %{"category" => "sandbox"})

      # Regression: the sandbox category used to hard-filter to [:sandbox, :mode],
      # so any other sub_category == nil schema (write_paths) hit a CaseClauseError
      # in setting_card/1. Rendering without raising proves the :list_of_strings
      # clause works.
      assert html =~ "sandbox.write_paths"
      assert html =~ "Add path"
      # nil (unset) value renders the "Not set" hint instead of inputs
      assert html =~ "platform default writable paths are used"
      assert write_paths(view) == nil
    end

    test "search for write_paths renders the card", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = settings_hook(view, "search", %{"value" => "write_paths"})

      assert html =~ "Search Results"
      assert html =~ "sandbox.write_paths"
      assert html =~ "Add path"
    end

    test "add_list_entry appends a blank entry to the in-memory config", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "select_category", %{"category" => "sandbox"})

      html = settings_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      # The implementation appends a trailing "" entry (the "add row").
      assert write_paths(view) == ["/tmp/a", "/tmp/b", ""]
      # The re-rendered card keeps the existing entries and shows the new blank input
      assert html =~ ~s(value="/tmp/a")
      assert html =~ ~s(value="/tmp/b")
    end

    test "add_list_entry with an unknown key path flashes an error", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = settings_hook(view, "add_list_entry", %{"key_path" => "nope.nope"})

      assert html =~ "Invalid key path."
      assert write_paths(view) == nil
    end

    test "remove_list_entry removes the entry at the given index", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "select_category", %{"category" => "sandbox"})

      html =
        settings_hook(view, "remove_list_entry", %{
          "key_path" => "sandbox.write_paths",
          "index" => "0"
        })

      assert write_paths(view) == ["/tmp/b"]
      refute html =~ ~s(value="/tmp/a")
      assert html =~ ~s(value="/tmp/b")
    end

    test "remove_list_entry with malformed or out-of-range index is a no-op", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      # These events mutate/read `file_config` only — no card in the rendered
      # html is asserted — so the page stays on its default category and the
      # sidebar event is not needed as setup.
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Malformed index → Integer.parse fails → treated as -1 → no-op
      settings_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "abc"
      })

      assert write_paths(view) == ["/tmp/a", "/tmp/b"]

      # Out-of-range index → no-op
      settings_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "5"
      })

      assert write_paths(view) == ["/tmp/a", "/tmp/b"]
    end

    test "save_category persists the edited list to the config file", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Add a blank entry, then remove the first entry → ["/tmp/b", ""]
      settings_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      settings_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "0"
      })

      html =
        settings_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto",
          # Form submission includes the hidden sentinel "" plus the text inputs;
          # blank entries are filtered by list_of_strings_value/1.
          "sandbox.write_paths" => ["", "/tmp/b", ""]
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == ["/tmp/b"]
      assert File.read!(EvoGit.Config.config_path()) =~ ~s(write_paths = ["/tmp/b"])
    end

    test "blank-only list saves as an explicit empty list", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # The UI flow: add one blank entry, then save. The form submits the hidden
      # sentinel "" plus the blank input → parsed to [] (a set-but-empty list
      # that REPLACES the platform defaults, distinct from unset/nil).
      settings_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      html =
        settings_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto",
          "sandbox.write_paths" => ["", ""]
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == []
      assert File.read!(EvoGit.Config.config_path()) =~ "write_paths = []"
    end

    test "absent write_paths on save keeps nil (no key introduced)", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        settings_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto"
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == nil
      refute File.read!(EvoGit.Config.config_path()) =~ "write_paths"
    end
  end

  describe "remote node config loading (config fetch failure)" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under the target id with a :connected
    # phase, so NodeAware resolves `?node=` to the remote BEAM node atom
    # "genesis_remote@127.0.0.1" — an unreachable fake node (same seam as
    # projects_live_test). The subsequent `:erpc` calls fail fast with
    # :nodedown, exercising load_node_config's error branch: the error banner
    # renders and the "No LLM Model Configured" box does NOT (the exact bug
    # being fixed — a spurious unconfigured-model warning on top of a real
    # fetch failure). There is no seam to inject a successful
    # get_resolved_config result for a fake node, so the happy path (remote
    # model profiles rendering) is not covered here.
    defp save_target! do
      id = "settings-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Settings Test Target"
        })

      on_exit(fn ->
        EvoGit.RemoteConnections.delete(id)
      end)

      id
    end

    test "remote config fetch failure renders the error banner, not the LLM warning", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = mount_settings(conn, "/settings?node=" <> id)

      # The node context resolved to the (unreachable) remote node.
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      # The config load now runs in an async supervised task (NodeData) outside
      # the LiveView process, so its result arrives as a message. Deliver it
      # deterministically (direct-send + render, the same pattern as the LLM
      # connection test) instead of racing the task's message. The real task
      # delivers the same values (erpc fails fast with :nodedown), so a
      # duplicate delivery is an idempotent no-op.
      node = :"genesis_remote@127.0.0.1"

      html =
        deliver_node_data(view, nil,
          file_config: %{},
          config_status: EvoDash.NodeContext.get_remote_config_status(node),
          remote_config_error: :nodedown
        )

      assert is_binary(assigns(view)[:remote_config_error])
      # No config was loaded — an empty map, not a misleading subset.
      assert assigns(view)[:file_config] == %{}

      # The error banner explains the real problem...
      assert html =~ "Remote Configuration Unavailable"
      assert html =~ "Could not load configuration from the remote node"

      # ...and the bogus "No LLM Model Configured" box must NOT fire on top of it.
      refute html =~ "No LLM Model Configured"
    end

    test "stale async result for a different node is dropped", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = mount_settings(conn, "/settings?node=" <> id)
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      # Deliver a result tagged with a DIFFERENT node than the one currently
      # viewed — simulates a load that was requested for a node the user has
      # since left. The stale-guard in handle_info must drop it: none of the
      # sentinel values may appear in the assigns, regardless of whether the
      # real in-flight load for the current node has landed yet.
      send(
        view.pid,
        {:settings_node_data_loaded, :some_other_node@host, nil,
         %{
           platform_os: :windows,
           filtered_schemas_by_category: %{sentinel: []},
           file_config: %{"llm" => %{"model" => "stale-sentinel"}},
           config_status: %{ok?: true, warnings: [], validation_errors: []},
           remote_config_error: "stale-error",
           custom_agents: %{
             agents: [%{"id" => "stale-agent"}],
             model_selection_script: "stale-script",
             script_status: :ok
           }
         }}
      )

      render(view)

      refute assigns(view)[:platform_os] == :windows
      refute assigns(view)[:schemas_by_category] == %{sentinel: []}
      refute assigns(view)[:file_config] == %{"llm" => %{"model" => "stale-sentinel"}}
      refute assigns(view)[:remote_config_error] == "stale-error"
      refute assigns(view)[:model_selection_script] == "stale-script"
      refute assigns(view)[:custom_agents] == [%{"id" => "stale-agent"}]
    end

    test "local node keeps remote_config_error nil and shows no error banner", %{conn: conn} do
      {:ok, view, html} = mount_settings(conn, ~p"/settings")

      assert assigns(view)[:remote_config_error] == nil
      refute html =~ "Remote Configuration Unavailable"
    end
  end

  describe "remote-connection bootstrap progress bar (5-step + frozen final states)" do
    # Saves a unique remote target (so the Settings Remote Connections card
    # renders) and registers a fake BootstrapManager in
    # EvoGit.RemoteConnection.Registry answering the bootstrap GenServer calls
    # that EvoGit.RemoteConnection.bootstrap/1,2 route to with `result` (the
    # canned completion). `delay_ms` optionally holds the reply back — used to
    # exercise the double-click guard while a bootstrap is still in flight.
    # Returns {id, manager_pid}.
    defp bootstrap_target!(result, delay_ms \\ 0) do
      id = "settings-bootstrap-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Bootstrap Test Target"
        })

      manager =
        start_supervised!(
          {EvoDashWeb.SettingsLiveTest.BootstrapManager, {id, result, delay_ms}},
          id: {:settings_bootstrap_manager, id}
        )

      on_exit(fn ->
        EvoGit.RemoteConnections.delete(id)
      end)

      {id, manager}
    end

    # Polls render(view) until `fun` is truthy or the deadline passes. The
    # bootstrap handlers spawn their NodeContext call in an async Task whose
    # completion arrives as a message — render/1 flushes it deterministically.
    defp wait_until(view, fun, timeout \\ async_wait_budget()) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait(view, fun, deadline)
    end

    defp do_wait(view, fun, deadline) do
      _html = render(view)

      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) >= deadline ->
          false

        true ->
          Process.sleep(10)
          do_wait(view, fun, deadline)
      end
    end

    defp primary_steps(html) do
      html |> Floki.parse_document!() |> Floki.find("li.step.step-primary") |> length()
    end

    test "the five step labels render for a bootstrapping target", %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :extracting}}
      )

      html = render(view)

      for label <- [
            "Probing / preparing",
            "Downloading",
            "Extracting",
            "Configuring",
            "Starting daemon"
          ] do
        assert html =~ label
      end
    end

    test "maps every core stage atom to its 5-step index", %{conn: conn} do
      mappings = [
        {:probing_platform, 0},
        {:uploading, 0},
        {:detecting_os, 0},
        {:downloading, 1},
        {:downloading_locally, 1},
        {:extracting, 2},
        {:setting_permissions, 3},
        {:copying_config, 3},
        {:generating_cookie, 3},
        {:patching_binaries, 3},
        {:stopping_daemon, 3},
        {:starting_daemon, 4}
      ]

      # ONE mount + ONE target: every broadcast below targets the same card, so
      # the bar is re-rendered in place for each stage (no per-stage remount).
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      html =
        Enum.reduce(mappings, nil, fn {stage, expected_idx}, _acc ->
          send(
            view.pid,
            {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: stage}}
          )

          html = render(view)

          assert assigns(view)[:bootstrap_progress][id] ==
                   %{stage: expected_idx, active: true, status: :active},
                 "stage #{inspect(stage)} should map to step index #{expected_idx}"

          # steps 0..idx are highlighted (step-primary), the rest plain
          assert primary_steps(html) == expected_idx + 1,
                 "stage #{inspect(stage)} should highlight #{expected_idx + 1} steps"

          html
        end)

      # The bar always renders exactly five steps.
      assert length(Floki.find(Floki.parse_document!(html), "li.step")) == 5
    end

    test "unknown stage atom highlights no step", %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id,
         %{phase: :bootstrapping, bootstrap_stage: :some_future_stage}}
      )

      html = render(view)

      assert assigns(view)[:bootstrap_progress][id].stage == -1
      assert primary_steps(html) == 0
    end

    test "a broadcast for a different target preserves the active entry", %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :downloading}}
      )

      render(view)
      assert assigns(view)[:bootstrap_progress][id] == %{stage: 1, active: true, status: :active}

      send(view.pid, {:remote_connection_status, "some-other-target", %{phase: :connecting}})
      render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{stage: 1, active: true, status: :active}
    end

    test "a non-bootstrapping phase while active ends the bootstrap and freezes success", %{
      conn: conn
    } do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :extracting}}
      )

      render(view)

      # The core sets phase: :disconnected with bootstrap_stage: nil right
      # after a successful bootstrap — while the entry is active that ENDS the
      # bootstrap and freezes an all-green bar at step 4.
      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :disconnected, bootstrap_stage: nil}}
      )

      html = render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 4,
               active: false,
               status: :success
             }

      assert primary_steps(html) == 5
    end

    test "bootstrap completion freezes an all-green bar with Install/Connect buttons", %{
      conn: conn
    } do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :extracting}}
      )

      render(view)

      send(view.pid, {:bootstrap_complete, id, {:ok, :daemon_started}})
      html = render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 4,
               active: false,
               status: :success
             }

      assert primary_steps(html) == 5
      # Install + Connect stay visible on the frozen success bar
      assert html =~ ~s(phx-click="bootstrap_remote_target")
      assert html =~ ~s(phx-click="connect_remote_target")

      labels = button_labels(html)
      assert "Install" in labels
      assert "Connect" in labels

      # Frozen — an unrelated broadcast must NOT reset the bar to buttons
      send(view.pid, {:remote_connection_status, id, %{phase: :disconnected}})
      render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 4,
               active: false,
               status: :success
             }
    end

    test "bootstrap failure freezes a partial bar with error text and a retry button", %{
      conn: conn
    } do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :extracting}}
      )

      render(view)

      send(view.pid, {:bootstrap_complete, id, {:error, "download failed"}})
      html = render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 2,
               active: false,
               status: :error,
               error: "download failed"
             }

      doc = Floki.parse_document!(html)
      # steps 0..1 primary, the failing step (2) error-marked, steps 3..4 plain
      assert length(Floki.find(doc, "li.step.step-primary")) == 2
      assert length(Floki.find(doc, "li.step.step-error")) == 1
      assert html =~ "download failed"
      # the error final state has a retry Bootstrap button, not Connect
      assert html =~ ~s(phx-click="bootstrap_remote_target")
      refute html =~ ~s(phx-click="connect_remote_target")

      # Frozen — unrelated broadcasts must NOT reset the error bar
      send(view.pid, {:remote_connection_status, id, %{phase: :disconnected}})
      render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 2,
               active: false,
               status: :error,
               error: "download failed"
             }
    end

    test "bootstrap failure before any stage broadcast renders error text with an unhighlighted bar",
         %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(view.pid, {:bootstrap_complete, id, {:error, "early failure"}})
      html = render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: nil,
               active: false,
               status: :error,
               error: "early failure"
             }

      assert primary_steps(html) == 0
      assert html =~ "early failure"
      assert html =~ ~s(phx-click="bootstrap_remote_target")
    end

    test "a tail-bearing bootstrap failure reason renders readable text, not a raw tuple",
         %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(
        view.pid,
        {:bootstrap_complete, id,
         {:error, {:staging_failed, 255, "bash: line 1: mkdir: Permission denied"}}}
      )

      html = render(view)
      entry = assigns(view)[:bootstrap_progress][id]

      assert %{stage: nil, active: false, status: :error, error: error} = entry
      assert error =~ "extracting/setting permissions failed (ssh exit 255)"
      assert error =~ "Permission denied"

      assert html =~ "extracting/setting permissions failed (ssh exit 255)"
      assert html =~ "Permission denied"
      # The raw tuple shape must never leak into the UI.
      refute html =~ "{:staging_failed"
    end

    test "bootstrap_remote_target shows the bar immediately and completes through the manager", %{
      conn: conn
    } do
      # Gate the fake's reply so it stays in flight until this test releases it
      # — the immediate assertion below can never race the async
      # {:bootstrap_complete, ...} (no wall-clock window).
      {id, manager} = bootstrap_target!({:ok, :daemon_started}, :gate)
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      html = render_click(view, "bootstrap_remote_target", %{"id" => id})

      # Immediate feedback: active entry with a nil (not yet known) stage
      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: nil,
               active: true,
               status: :active
             }

      assert html =~ "Probing / preparing"

      # Release the parked reply, then round trip through the fake manager: it
      # answers the GenServer {:bootstrap, opts} call → the spawned task
      # delivered {:bootstrap_complete, ...} → frozen all-green bar.
      send(manager, :release)

      assert wait_until(view, fn ->
               assigns(view)[:bootstrap_progress][id] == %{
                 stage: 4,
                 active: false,
                 status: :success
               }
             end)

      assert GenServer.call(manager, :calls) == [{:bootstrap, []}]
    end

    test "double-click bootstrap_remote_target while in flight does not spawn a second bootstrap",
         %{conn: conn} do
      # Gate the fake's reply so the first bootstrap is still in flight when
      # the second click lands — the active-entry guard must block it
      {id, manager} = bootstrap_target!({:ok, :daemon_started}, :gate)
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "bootstrap_remote_target", %{"id" => id})
      render_click(view, "bootstrap_remote_target", %{"id" => id})

      # the second click was blocked: the entry is still the FIRST click's
      # active entry (the guard never resets it)
      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: nil,
               active: true,
               status: :active
             }

      # Only the FIRST click reaches the fake manager — the guard prevents a
      # second bootstrap call.
      send(manager, :release)

      assert wait_until(view, fn -> GenServer.call(manager, :calls) == [{:bootstrap, []}] end)
      assert GenServer.call(manager, :calls) == [{:bootstrap, []}]
    end
  end

  describe "daemon-already-running permission dialog" do
    test "daemon_running refusal opens the dialog with details, no error flash, entry removed", %{
      conn: conn
    } do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      # an active bootstrap entry is showing...
      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :bootstrapping, bootstrap_stage: :downloading}}
      )

      render(view)
      assert assigns(view)[:bootstrap_progress][id].status == :active

      details = "Daemon pid 1234 is running (systemd user unit genesis_remote.service)"

      # ...then the bootstrap task reports the daemon_running refusal
      send(view.pid, {:bootstrap_complete, id, {:error, {:daemon_running, details}}})
      html = render(view)

      # the dialog IS the feedback — no generic "Bootstrap failed" flash
      refute html =~ "Bootstrap failed"

      assert assigns(view)[:bootstrap_restart_confirm] == %{id: id, details: details}
      assert html =~ "Remote node already connected"
      assert html =~ details
      assert html =~ ~s(phx-click="confirm_bootstrap_restart")
      assert html =~ ~s(phx-click="cancel_bootstrap_restart")

      # the transient active entry is DELETED — the card returns to buttons
      refute Map.has_key?(assigns(view)[:bootstrap_progress], id)
      assert html =~ ~s(phx-click="bootstrap_remote_target")
    end

    test "confirm_bootstrap_restart closes the dialog and re-bootstraps with on_running: :restart",
         %{conn: conn} do
      # Gate the fake's reply so the confirm handler's re-bootstrap stays in
      # flight until this test releases it — the immediate "progress
      # re-activated" assertion below can never race the async
      # {:bootstrap_complete, ...}.
      {id, manager} = bootstrap_target!({:ok, :daemon_started}, :gate)
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(view.pid, {:bootstrap_complete, id, {:error, {:daemon_running, "daemon is running"}}})
      render(view)
      assert assigns(view)[:bootstrap_restart_confirm] == %{id: id, details: "daemon is running"}

      html = render_click(view, "confirm_bootstrap_restart", %{"target_id" => id})

      # dialog closed + progress re-activated
      assert assigns(view)[:bootstrap_restart_confirm] == nil

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: nil,
               active: true,
               status: :active
             }

      refute html =~ "Remote node already connected"

      # The confirm handler re-bootstraps through the fake manager — pins the
      # on_running: :restart threading.
      send(manager, :release)

      assert wait_until(view, fn ->
               GenServer.call(manager, :calls) == [{:bootstrap, [on_running: :restart]}]
             end),
             "expected confirm_bootstrap_restart to call bootstrap with on_running: :restart"

      # the existing {:bootstrap_complete, ...} path shows progress again
      send(view.pid, {:bootstrap_complete, id, {:ok, :daemon_started}})
      html = render(view)

      assert assigns(view)[:bootstrap_progress][id] == %{
               stage: 4,
               active: false,
               status: :success
             }

      assert html =~ ~s(phx-click="connect_remote_target")
    end

    test "cancel_bootstrap_restart dismisses the dialog without bootstrapping", %{conn: conn} do
      {id, manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(view.pid, {:bootstrap_complete, id, {:error, {:daemon_running, "daemon is running"}}})
      render(view)
      assert assigns(view)[:bootstrap_restart_confirm] != nil

      html = render_click(view, "cancel_bootstrap_restart", %{"target_id" => id})

      assert assigns(view)[:bootstrap_restart_confirm] == nil
      refute html =~ "Remote node already connected"
      # progress is NOT re-activated — the card stays on the plain buttons
      refute Map.has_key?(assigns(view)[:bootstrap_progress], id)
      # and no bootstrap call was made
      assert GenServer.call(manager, :calls) == []
    end
  end

  describe "remote-connection Install wording, banner, and Name auto-fill" do
    # Full form-field param map for the add/edit remote-connection form
    # (mirrors a submitted DOM — the advanced inputs stay in the page inside a
    # CSS-hidden container and keep submitting). `overrides` win per-key.
    defp remote_form_params(overrides) do
      Map.merge(
        %{
          "_id" => "",
          "name" => "",
          "ssh_target" => "",
          "local_binary_path" => "",
          "platform" => "",
          "dist_port" => "9000",
          "remote_path" => "/tmp/genesis_server"
        },
        Map.new(overrides)
      )
    end

    # Visible label of every <button> on the page — asserts action-button
    # wording exactly without tripping over the banner/info-box prose (e.g.
    # "Connection data is stored..." contains the substring "Connect").
    defp button_labels(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("button")
      |> Enum.map(fn btn -> btn |> Floki.text() |> String.trim() end)
    end

    test "Remote Connections category renders the two-step Install/Connect explainer", %{
      conn: conn
    } do
      {:ok, _view, html} = mount_settings(conn, "/settings?category=remote_connections")

      assert html =~ "Remote Connections"
      assert html =~ "first install the remote daemon on the server, then connect to it"
      assert html =~ "keep running even when you close this app"
    end

    test "disconnected target card action buttons read Install and Connect", %{conn: conn} do
      save_target!()

      {:ok, _view, html} = mount_settings(conn, "/settings?category=remote_connections")

      labels = button_labels(html)
      assert "Install" in labels
      assert "Connect" in labels
      refute "Bootstrap" in labels
    end

    test "bootstrap completion flashes Install succeeded", %{conn: conn} do
      {id, _manager} = bootstrap_target!({:ok, :daemon_started})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      send(view.pid, {:bootstrap_complete, id, {:ok, :daemon_started}})
      html = render(view)

      assert html =~ "Install succeeded."
      refute html =~ "Bootstrap succeeded."
    end

    test "Add form auto-fills Name from the SSH Target while Name is untouched", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      html = render_click(view, "add_remote_target", %{})
      assert html =~ "Add Connection"
      assert assigns(view)[:remote_form_target][:auto_name] == true
      assert (assigns(view)[:remote_form_target][:name] || "") == ""

      ssh_target = "gpu-server"

      typed =
        Enum.reduce(String.graphemes(ssh_target), "", fn char, acc ->
          acc = acc <> char

          render_change(
            view,
            "remote_connections_form_change",
            remote_form_params(%{
              # The untouched Name field still holds the previous render's value
              # (what a browser would submit) — the handler keeps tracking.
              "name" => assigns(view)[:remote_form_target][:name] || "",
              "ssh_target" => acc
            })
          )

          assert assigns(view)[:remote_form_target][:name] == acc,
                 "Name must track the full SSH Target as it is typed"

          assert assigns(view)[:remote_form_target][:auto_name] == true
          acc
        end)

      assert typed == ssh_target
      assert assigns(view)[:remote_form_target][:name] == ssh_target

      on_exit(fn -> EvoGit.RemoteConnections.delete("gpu-server") end)

      submit_html =
        render_submit(
          view,
          "save_remote_target",
          remote_form_params(%{"name" => ssh_target, "ssh_target" => ssh_target})
        )

      assert submit_html =~ "Connection saved."
      {:ok, saved} = EvoGit.RemoteConnections.get("gpu-server")
      assert saved.name == "gpu-server"
      assert saved.ssh_target == "gpu-server"
    end

    test "direct submit with a blank Name persists Name == SSH Target", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")
      render_click(view, "add_remote_target", %{})

      html =
        render_submit(
          view,
          "save_remote_target",
          remote_form_params(%{"ssh_target" => "user@build-host"})
        )

      assert html =~ "Connection saved."

      on_exit(fn -> EvoGit.RemoteConnections.delete("user-build-host") end)

      {:ok, saved} = EvoGit.RemoteConnections.get("user-build-host")
      assert saved.name == "user@build-host"
      assert saved.ssh_target == "user@build-host"
    end

    test "custom Name is kept verbatim once typed, never clobbered by SSH Target edits", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")
      render_click(view, "add_remote_target", %{})

      # Type into SSH Target while Name is untouched → Name auto-tracks.
      render_change(
        view,
        "remote_connections_form_change",
        remote_form_params(%{"name" => "", "ssh_target" => "gpu-server"})
      )

      assert assigns(view)[:remote_form_target][:name] == "gpu-server"
      assert assigns(view)[:remote_form_target][:auto_name] == true

      # The user types a custom Name → taken over verbatim, auto-tracking stops.
      render_change(
        view,
        "remote_connections_form_change",
        remote_form_params(%{"name" => "My GPU Box", "ssh_target" => "gpu-server"})
      )

      assert assigns(view)[:remote_form_target][:name] == "My GPU Box"
      assert assigns(view)[:remote_form_target][:auto_name] == false

      # Later SSH Target edits never clobber the custom name.
      render_change(
        view,
        "remote_connections_form_change",
        remote_form_params(%{"name" => "My GPU Box", "ssh_target" => "gpu-server-2"})
      )

      assert assigns(view)[:remote_form_target][:name] == "My GPU Box"
      assert assigns(view)[:remote_form_target][:auto_name] == false

      on_exit(fn -> EvoGit.RemoteConnections.delete("my-gpu-box") end)

      render_submit(
        view,
        "save_remote_target",
        remote_form_params(%{"name" => "My GPU Box", "ssh_target" => "gpu-server-2"})
      )

      {:ok, saved} = EvoGit.RemoteConnections.get("my-gpu-box")
      assert saved.name == "My GPU Box"
      assert saved.ssh_target == "gpu-server-2"
    end

    test "editing an existing target preserves the saved Name when only the SSH Target changes",
         %{
           conn: conn
         } do
      id = "settings-edit-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          id: id,
          name: "My Server",
          ssh_target: "user@host-a"
        })

      on_exit(fn -> EvoGit.RemoteConnections.delete(id) end)

      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "edit_remote_target", %{"id" => id})
      assert assigns(view)[:remote_form_target][:name] == "My Server"
      assert assigns(view)[:remote_form_target][:auto_name] == false

      # Only the SSH Target changes; the prefilled Name is untouched.
      render_change(
        view,
        "remote_connections_form_change",
        remote_form_params(%{
          "_id" => id,
          "name" => assigns(view)[:remote_form_target][:name],
          "ssh_target" => "user@host-b"
        })
      )

      assert assigns(view)[:remote_form_target][:name] == "My Server"
      assert assigns(view)[:remote_form_target][:auto_name] == false

      render_submit(
        view,
        "save_remote_target",
        remote_form_params(%{
          "_id" => id,
          "name" => assigns(view)[:remote_form_target][:name],
          "ssh_target" => "user@host-b"
        })
      )

      {:ok, saved} = EvoGit.RemoteConnections.get(id)
      assert saved.name == "My Server"
      assert saved.ssh_target == "user@host-b"
    end
  end

  describe "remote-connection async connect flow (event-driven flash)" do
    # Saves a unique remote target and registers a fake ConnectManager in
    # EvoGit.RemoteConnection.Registry answering the GenServer :connect call
    # that EvoGit.RemoteConnection.connect/1 routes to it. `connect_result`
    # (default {:ok, :connecting}) is the canned reply; `delay_ms` optionally
    # holds the reply back so a test can keep the connect "in flight" (the
    # double-click guard). The manager starts at `status` (default
    # disconnected) and records every :connect call in `calls` (read back via
    # GenServer.call(manager, :calls)). Returns {id, manager}.
    defp connect_target!(opts \\ []) do
      id = "settings-connect-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Connect Test Target"
        })

      status =
        Keyword.get(
          opts,
          :status,
          %{phase: :disconnected, node: nil, last_error: nil, target: nil, bootstrap_stage: nil}
        )

      manager =
        start_supervised!(
          {EvoDashWeb.SettingsLiveTest.ConnectManager,
           {id, status, Keyword.get(opts, :connect_result, {:ok, :connecting}),
            Keyword.get(opts, :delay_ms, 0)}},
          id: {:settings_connect_manager, id}
        )

      on_exit(fn ->
        EvoGit.RemoteConnections.delete(id)
      end)

      {id, manager}
    end

    # The terminal :connected status map. Realistic ordering in these tests:
    # the fake manager's state is mutated FIRST ({:set_status, ...}), then the
    # same map is broadcast — mirroring the real core (manager state changes,
    # then it broadcasts). The target ROW's phase (dot/badge/label) is
    # recomputed from the manager via NodeContext.connection_status/0, NOT from
    # the broadcast payload.
    defp connect_status_connected do
      %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}
    end

    defp connect_status_error(last_error) do
      %{phase: :error, node: nil, last_error: last_error}
    end

    defp connect_status_connecting do
      %{phase: :connecting, node: nil, last_error: nil}
    end

    # Number of literal occurrences of `text` in `html` — the flash message
    # renders exactly once per put_flash (a re-put on the same kind would
    # overwrite the map entry, so a repeated terminal broadcast must leave the
    # count unchanged).
    defp html_occurrences(html, text) do
      html |> String.split(text) |> length() |> Kernel.-(1)
    end

    test "no premature flash on Connect click; info flash exactly once on the :connected broadcast",
         %{conn: conn} do
      {id, manager} = connect_target!()
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      html = render_click(view, "connect_remote_target", %{"id" => id})

      # Async contract: the click only sets the per-target pending marker and
      # spawns the supervised connect task — NO synchronous flash.
      refute html =~ "Connect succeeded."
      assert assigns(view)[:remote_connect_pending][id] == true

      # Terminal outcomes arrive ONLY via the broadcast. Realistic ordering:
      # manager state changes first, then the broadcast fires.
      GenServer.call(manager, {:set_status, connect_status_connected()})
      send(view.pid, {:remote_connection_status, id, connect_status_connected()})
      html = render(view)

      assert html_occurrences(html, "Connect succeeded.") == 1
      assert assigns(view)[:flash] == %{"info" => "Connect succeeded."}
      # the marker was consumed — the flash is one-shot per initiation
      assert assigns(view)[:remote_connect_pending] == %{}
    end

    test "duplicate :connected broadcast does not flash a second time (marker consumed)",
         %{conn: conn} do
      {id, manager} = connect_target!()
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "connect_remote_target", %{"id" => id})

      GenServer.call(manager, {:set_status, connect_status_connected()})
      send(view.pid, {:remote_connection_status, id, connect_status_connected()})
      html = render(view)

      assert html_occurrences(html, "Connect succeeded.") == 1
      assert assigns(view)[:remote_connect_pending] == %{}

      # Same terminal broadcast again — the marker is gone, so consume must NOT
      # re-add the flash: the rendered page still carries exactly one alert and
      # the flash assign is unchanged.
      send(view.pid, {:remote_connection_status, id, connect_status_connected()})
      html = render(view)

      assert html_occurrences(html, "Connect succeeded.") == 1
      assert assigns(view)[:flash] == %{"info" => "Connect succeeded."}
      assert assigns(view)[:remote_connect_pending] == %{}
    end

    test ":connecting broadcast neither flashes nor consumes the marker; the later terminal still flashes",
         %{conn: conn} do
      {id, manager} = connect_target!()
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "connect_remote_target", %{"id" => id})

      # Intermediate :connecting broadcast (manager state then broadcast) — the
      # non-terminal phase must not flash AND must leave the marker in place so
      # the eventual terminal outcome is still surfaced.
      GenServer.call(manager, {:set_status, connect_status_connecting()})
      send(view.pid, {:remote_connection_status, id, connect_status_connecting()})
      html = render(view)

      refute html =~ "Connect succeeded."
      refute html =~ "Connect failed:"
      assert assigns(view)[:remote_connect_pending][id] == true

      # The later terminal broadcast still flashes — the marker survived the
      # :connecting broadcast.
      GenServer.call(manager, {:set_status, connect_status_connected()})
      send(view.pid, {:remote_connection_status, id, connect_status_connected()})
      html = render(view)

      assert html_occurrences(html, "Connect succeeded.") == 1
      assert assigns(view)[:remote_connect_pending] == %{}
    end

    test "error broadcast flashes the last_error once; a duplicate error broadcast is silent",
         %{conn: conn} do
      {id, manager} = connect_target!()
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "connect_remote_target", %{"id" => id})

      GenServer.call(manager, {:set_status, connect_status_error("ssh refused")})
      send(view.pid, {:remote_connection_status, id, connect_status_error("ssh refused")})
      html = render(view)

      assert html_occurrences(html, "Connect failed: ssh refused") == 1
      assert assigns(view)[:flash] == %{"error" => "Connect failed: ssh refused"}
      assert assigns(view)[:remote_connect_pending] == %{}

      # Marker consumed — a duplicate terminal broadcast adds no second flash.
      send(view.pid, {:remote_connection_status, id, connect_status_error("ssh refused")})
      html = render(view)

      assert html_occurrences(html, "Connect failed: ssh refused") == 1
      assert assigns(view)[:flash] == %{"error" => "Connect failed: ssh refused"}
    end

    test "a second Connect click while the first connect is in flight is a no-op", %{conn: conn} do
      # The gated reply keeps the first connect in flight while the second
      # click lands — the per-target pending marker must block the duplicate.
      {id, manager} = connect_target!(delay_ms: :gate)
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "connect_remote_target", %{"id" => id})
      render_click(view, "connect_remote_target", %{"id" => id})

      # Only the FIRST click reaches the fake manager.
      send(manager, :release)

      assert wait_until(view, fn -> GenServer.call(manager, :calls) == [:connect] end)
      assert GenServer.call(manager, :calls) == [:connect]
    end

    test "sync connect error (never broadcast) clears the marker and flashes via the self-message",
         %{conn: conn} do
      {id, _manager} = connect_target!(connect_result: {:error, :subsystem_down})
      {:ok, view, _html} = mount_settings(conn, "/settings?category=remote_connections")

      render_click(view, "connect_remote_target", %{"id" => id})

      # The async task's connect call returned {:error, :subsystem_down} — an
      # arm that never broadcasts — so initiate_remote_connect self-messages
      # {:remote_connect_result, ...}; the narrow handler clears the marker and
      # flashes the inspected reason.
      assert wait_until(view, fn ->
               assigns(view)[:remote_connect_pending] == %{} and
                 assigns(view)[:flash]["error"] == "Connect failed: :subsystem_down"
             end)

      html = render(view)
      assert html =~ "Connect failed: :subsystem_down"

      # The marker is gone: a later terminal broadcast for this target is
      # silent (no second flash carrying the new last_error).
      send(view.pid, {:remote_connection_status, id, connect_status_error("late error")})
      html = render(view)

      refute html =~ "Connect failed: late error"
      assert assigns(view)[:flash]["error"] == "Connect failed: :subsystem_down"
    end
  end

  describe "copy-to-clipboard" do
    test "config-path copy button renders with the ClipboardCopy hook", %{conn: conn} do
      {:ok, _view, html} = mount_settings(conn, ~p"/settings")

      assert html =~ ~s(id="settings-config-path-copy")
      assert html =~ ~s(phx-hook="ClipboardCopy")
      assert html =~ ~s(data-content=)
    end

    test "copied event flashes the confirmation message", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = settings_hook(view, "copied", %{})

      assert html =~ "Copied to clipboard"
    end
  end

  describe "appearance category / accent color" do
    # The :appearance category holds a single [:appearance, :accent_color]
    # schema (type :string, default "blue", validation in: the ten
    # GNOME/libadwaita palette names — schema definitions.ex). SettingCard
    # renders it as a swatch row + a hidden `appearance.accent_color` input
    # (setting_card.ex); the generic save_category flow persists the hidden
    # input. SettingsLive.select_appearance_accent whitelist-validates the
    # phx-value-accent payload via SettingCard.accent_name?/1 and stores ONLY
    # the pending :appearance_accent_draft assign (threaded into the card by
    # category_section → card_value/3) — the swatches are type="button" and
    # never submit the enclosing save_category form.
    #
    # The category is never platform-gated (only :sandbox / :nix are), so the
    # shell (unfiltered) and async-filtered schema maps agree — selecting the
    # category immediately after live/3 is deterministic, the same pattern as
    # the "boolean field rendering (nix.enabled)" tests. No config file exists
    # in the per-test isolated config dir, so accent_color is unset and
    # the schema default "blue" is the active value.

    test "selecting the appearance category renders 10 swatches and the hidden accent input", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = settings_hook(view, "select_category", %{"category" => "appearance"})

      assert assigns(view).active_category == :appearance
      # The active category's content section is rendered.
      assert html =~ ~s(id="category-appearance")

      # The hidden input carries the ACTIVE value (schema default "blue" when
      # the config does not set the key) so the generic save_category flow
      # persists it.
      assert html =~ ~s(type="hidden" name="appearance.accent_color" value="blue")

      doc = Floki.parse_document!(html)
      swatches = Floki.find(doc, ~s(button[phx-click="select_appearance_accent"]))
      assert length(swatches) == 10

      # Every palette name is present as a phx-value-accent on its swatch
      # (accent_palette/0 returns a plain list of name strings).
      for name <- EvoDashWeb.SettingsComponents.SettingCard.accent_palette() do
        assert html =~ ~s(phx-value-accent="#{name}")
      end
    end

    test "saving the appearance category persists the selected accent color", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "select_category", %{"category" => "appearance"})

      # The real form submits the hidden input's name/value pair inside the
      # save_category params (mirroring the sandbox write_paths save tests —
      # save_category → params_to_category_config passes the :string value
      # through raw → deep_put [:appearance, :accent_color] => "teal").
      html =
        settings_hook(view, "save_category", %{
          "category" => "appearance",
          "appearance.accent_color" => "teal"
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:appearance, :accent_color]) == "teal"
      assert File.read!(EvoGit.Config.config_path()) =~ ~s(accent_color = "teal")
    end

    test "swatch click marks the accent active and updates the hidden input (draft)", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "select_category", %{"category" => "appearance"})

      html = settings_hook(view, "select_appearance_accent", %{"accent" => "teal"})

      # The pending draft re-renders the card: the hidden input now carries
      # teal (the draft threads via card_value/3 — no form submit involved)
      # and the previously active blue value is gone.
      assert html =~ ~s(type="hidden" name="appearance.accent_color" value="teal")
      refute html =~ ~s(type="hidden" name="appearance.accent_color" value="blue")

      # Exactly one swatch is active (ring-base-content/70 + scale-110 marker;
      # every swatch carries `focus-visible:ring-2` in its base classes, so the
      # active marker classes are the discriminator) and it is teal; blue no
      # longer carries the active marker.
      doc = Floki.parse_document!(html)

      active_swatches =
        doc
        |> Floki.find(~s(button[phx-click="select_appearance_accent"]))
        |> Enum.filter(fn btn ->
          btn |> Floki.attribute("class") |> Enum.join(" ") =~ "ring-base-content/70"
        end)

      assert length(active_swatches) == 1

      [teal_swatch] = Floki.find(doc, ~s(button[phx-value-accent="teal"]))
      teal_classes = teal_swatch |> Floki.attribute("class") |> Enum.join(" ")
      assert teal_classes =~ "ring-base-content/70"
      assert teal_classes =~ "scale-110"

      [blue_swatch] = Floki.find(doc, ~s(button[phx-value-accent="blue"]))
      blue_classes = blue_swatch |> Floki.attribute("class") |> Enum.join(" ")
      refute blue_classes =~ "ring-base-content/70"
    end

    test "unknown accent values are rejected (whitelist via SettingCard.accent_name?/1)", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      settings_hook(view, "select_category", %{"category" => "appearance"})

      html = settings_hook(view, "select_appearance_accent", %{"accent" => "chartreuse"})

      # Unknown value → error flash and no draft set — the card keeps the
      # current (blue) value.
      assert html =~ "Unknown accent color."
      assert html =~ ~s(type="hidden" name="appearance.accent_color" value="blue")
    end
  end

  describe "md+ independent scroll layout contract" do
    # The two-column row (`flex flex-col md:flex-row md:flex-1 md:min-h-0` in
    # settings_live.ex) is sized by the flex algorithm and has NO definite
    # `height` property. Two rules keep the section-nav sidebar and the
    # content pane scrolling INDEPENDENTLY on md+:
    #
    # 1. A content-column ROOT must NEVER carry `h-full`: a percentage height
    #    resolves to auto (the row has no definite height), the column grows
    #    to its content, the whole page inflates past the viewport, the BODY
    #    scrolls, and the panes scroll LINKED (the reported
    #    "Scheduler/Sandbox/Tools scrolling linked" bug). Content columns are
    #    sized by `flex-1` alone (+ `overflow-y-auto` on the column or its
    #    inner scroll div). The `md:h-full` on the outer wrapper
    #    (settings_live.ex) and the sidebar are correct and must stay.
    # 2. Every main-axis (column-direction) NON-scroll flex item between the
    #    bounded column and the inner scroll container MUST carry `min-h-0`.
    #    Without it, the flexbox content-based automatic minimum
    #    (`min-height: auto`) keeps the item from shrinking below its content
    #    (~3000px), the inner `flex-1 overflow-y-auto` body never engages,
    #    content spills to `#main-scroll`, and the panes scroll LINKED. The
    #    generic categories' `save_category` `<.form>` sits between the
    #    `category_section` root and its scroll body, so it is THE element
    #    needing `min-h-0`. The `:llm` category works because its scroll body
    #    is a DIRECT child of the column root (scroll containers get automatic
    #    min-size 0); search/`:remote_connections`/`:agents` work because the
    #    column/form ITSELF is the scroll container. Only the generic `:else`
    #    path buries the scroll body behind the non-`min-h-0` form.
    test "content columns size by flex-1, never h-full", %{conn: conn} do
      {:ok, view, html} = mount_settings(conn, ~p"/settings")

      # Default load renders the :llm category section, already on the
      # flex-1-only pattern.
      assert html =~ ~s(id="settings-form-llm")
      assert html =~ "flex-1 flex flex-col min-w-0"
      refute html =~ "h-full bg-base-100/50"

      for cat <- ["scheduler", "sandbox", "tools"] do
        html = settings_hook(view, "select_category", %{"category" => cat})
        doc = Floki.parse_document!(html)

        # The category root div IS the content column — a direct flex child of
        # the two-column row. It must be sized by flex-1 alone, never h-full.
        [root] = Floki.find(doc, ~s(div[id="category-#{cat}"]))
        root_classes = root |> Floki.attribute("class") |> Enum.join(" ")
        assert root_classes =~ "flex-1 flex flex-col min-w-0"
        refute root_classes =~ "h-full", "category root must not carry h-full"

        assert root_classes =~ "min-h-0",
               "category root must carry min-h-0 (main-axis non-scroll flex intermediate chain)"

        # The save_category form fills the column and its inner scroll body
        # (flex-1 overflow-y-auto) owns the scrolling.
        [form] = Floki.find(doc, ~s(form[id="settings-form-#{cat}"]))
        form_classes = form |> Floki.attribute("class") |> Enum.join(" ")
        assert form_classes =~ "flex-1 flex flex-col min-w-0"
        refute form_classes =~ "h-full"

        assert form_classes =~ "min-h-0",
               "save_category form must carry min-h-0 so the inner overflow-y-auto body engages"

        assert Floki.find(doc, ~s(div[id="category-#{cat}"] .overflow-y-auto)) != [],
               "category section must keep an inner overflow-y-auto scroll body"
      end
    end

    test "search results column carries overflow-y-auto on the form", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = settings_hook(view, "search", %{"value" => "scheduler"})
      doc = Floki.parse_document!(html)

      # The search form is the content column — explicitly scrollable so
      # every content column is structurally identical.
      [form] = Floki.find(doc, ~s(form[id="settings-form-search"]))
      form_classes = form |> Floki.attribute("class") |> Enum.join(" ")
      assert form_classes == "flex-1 flex flex-col min-w-0 overflow-y-auto relative"
    end
  end
end

defmodule EvoDashWeb.SettingsLiveGlobalStateTest do
  # SYNC (`async: false`): these tests mutate BEAM-GLOBAL app-env seams that an
  # `async: true` peer also reads — `:nix_available_override` and
  # `:platform_os_override` are exercised by `EvoDashWeb.PlatformInfoTest`
  # (async) and `system_live_test` — and two of them pause/resume the boot-time
  # `EvoGit.AgentScheduler`. The suite's rule is that a flip is unsafe only when
  # a mutable global is shared with another ASYNC module, which is exactly the
  # case here; ExUnit runs `async: false` modules only after every async module
  # has finished, so these mutations can never overlap another test.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import EvoDashWeb.SettingsLiveTest.Helpers

  test "in-flight save owns its token across rejected reset and stale completions", %{conn: conn} do
    # This test belongs to the sync module because it suspends the process-global
    # AgentScheduler, making the real writer's reload acknowledgement deterministic.
    seed_write_paths(["/custom"])
    # A SAVED account is the only way into the expanded editor: the deleted
    # `add_model_profile` → `editing_profile_id: :new` shortcut no longer
    # exists (creation goes through the wizard). The sandbox write_paths are
    # kept in the same file, so the reload the save performs must preserve them.
    File.write!(EvoGit.Config.config_path(), """
    [sandbox]
    write_paths = ["/custom"]

    [[llm.providers]]
    id = "default"
    provider = "openai"
    default_model = "first"
    concurrency = 3

    [[llm.providers.models]]
    model = "first"
    """)

    {:ok, view, _} = mount_settings(conn, ~p"/settings")
    settings_hook(view, "edit_provider_profile", %{"profile_id" => "default"})
    before = assigns(view).file_config
    :ok = :sys.suspend(EvoGit.AgentScheduler)

    on_exit(fn ->
      # Teardown must resume the global singleton even if an assertion failed.
      try do
        :sys.resume(EvoGit.AgentScheduler)
      catch
        :exit, _ -> :ok
      end
    end)

    input = %{
      "profile_id" => "default",
      "profile_id_new" => "owned",
      "provider" => "openai",
      "default_model" => "first",
      "models" => %{"0" => %{"model" => "first"}, "1" => %{"model" => "second"}}
    }

    render_hook(view, "save_provider_profile", input)
    request = assigns(view).config_save_request
    assert request != nil
    assert assigns(view).config_saving
    assert assigns(view).file_config == before

    render_hook(view, "reset_key", %{"key_path" => "sandbox.write_paths"})
    assert assigns(view).config_save_request == request
    assert assigns(view).file_config == before
    assert assigns(view).flash["error"] == "Failed to save configuration: :save_in_progress"

    for {token, scope} <- [
          {make_ref(), request.scope},
          {request.token, {"obsolete-target", node()}}
        ] do
      send(
        view.pid,
        {{:settings_config_saved, token, scope}, {:ok, {:saved, %{llm: %{providers: []}}, []}}}
      )
    end

    render(view)
    assert assigns(view).config_save_request == request
    assert assigns(view).config_saving
    assert assigns(view).file_config == before
    assert assigns(view).editing_profile_id == "default"

    :ok = :sys.resume(EvoGit.AgentScheduler)
    html = await_config_save(view)
    assert html =~ "Provider profile saved."
    assert assigns(view).editing_profile_id == nil
    saved = assigns(view).file_config
    assert Enum.map(saved.llm.providers, & &1["id"]) == ["owned"]
    assert get_in(saved, [:sandbox, :write_paths]) == ["/custom"]
    assert EvoGit.Config.user_config()["llm"]["providers"] == saved.llm.providers

    html = settings_hook(view, "reset_key", %{"key_path" => "sandbox.write_paths"})
    assert html =~ "Reset sandbox.write_paths to default."
    reset_config = assigns(view).file_config
    assert get_in(reset_config, [:sandbox, :write_paths]) == nil
    # A duplicate receipt from the real, completed write cannot undo the reset.
    send(
      view.pid,
      {{:settings_config_saved, request.token, request.scope}, {:ok, {:saved, saved, []}}}
    )

    render(view)
    assert assigns(view).file_config == reset_config
    assert assigns(view).config_saving == false
    assert assigns(view).config_save_request == nil
    assert get_in(EvoGit.Config.user_config(), ["sandbox", "write_paths"]) != ["/custom"]
  end

  setup do
    # Same per-process config isolation as the async module: the
    # `:config_dir_fun` seam, never an `XDG_CONFIG_HOME` write.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_test_config")
    on_exit(fn -> File.rm_rf!(dir) end)

    # Force the nix category visible by default so ALL tests here are
    # deterministic regardless of whether the host has the `nix` binary (the
    # boolean field rendering and category-conversion tests select the nix
    # category). Gating tests below override this to false and clean up via
    # their own on_exit; the next test's setup re-establishes the default.
    Application.put_env(:evo_dash, :nix_available_override, true)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :nix_available_override)
    end)

    # ActiveTasks is a global ETS hub that ConnCase already resets around every
    # test; reset it here too so one test's sidebar snapshot never leaks into
    # the next.
    EvoDash.ActiveTasks.reset()

    :ok
  end

  describe "scheduler_config broadcast (node-filtered)" do
    # Push-refactor contract: the emitter broadcasts
    # `{:scheduler_config_updated, node}` on the "scheduler_config" topic,
    # where node is the BEAM node atom of the publisher. The handler
    # (settings_live.ex:822) node-filters via
    # NodeAware.event_from_current_node?/2 — matching-node events re-read the
    # scheduler config (LOCAL — pre-existing gap, see settings_live/CONTEXT.md);
    # foreign-node events are ignored (socket unchanged).

    test "broadcast from the current node refreshes the :scheduler_config assign", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Mount seeds the assign from the scheduler — flip the paused flag so the
      # refreshed config observably differs from the mount-time snapshot.
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
        {:scheduler_config_updated, node()}
      )

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      render(view)

      assert assigns(view)[:scheduler_config][:paused] == true
    end

    test "broadcast from a foreign node is ignored (assign unchanged)", %{conn: conn} do
      # Pause BEFORE mounting: pause() itself broadcasts a matching-node
      # {:scheduler_config_updated, node()} via
      # AgentScheduler.PubSub.broadcast_config_updated/0 (config change, pause,
      # or resume). With no subscribers yet the broadcast is dropped, so the
      # mount-time snapshot is the paused state and the foreign broadcast below
      # is the ONLY event the view can react to. This also makes the test
      # immune to cross-test scheduler-state leakage (if a prior test left the
      # scheduler paused, pause() is a no-op and the test still behaves
      # identically).
      EvoGit.AgentScheduler.pause()

      on_exit(fn ->
        # Resume in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.AgentScheduler.resume()
        rescue
          _ -> :ok
        end
      end)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Mount snapshot was paused — the final assertion below means "unchanged
      # from the snapshot" (the foreign event was dropped).
      assert assigns(view)[:scheduler_config][:paused] == true

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, :genesis_remote@somewhere}
      )

      render(view)

      # Foreign-node event dropped — the mount-time snapshot (paused) stays.
      assert assigns(view)[:scheduler_config][:paused] == true
    end
  end

  describe "boolean field rendering (nix.enabled)" do
    test "renders a DaisyUI toggle with hidden field for false value submission", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = settings_hook(view, "select_category", %{"category" => "nix"})

      # The hidden field (value="false") must appear BEFORE the checkbox so that
      # unchecked submits "false" and checked submits "true" (checkbox overrides).
      hidden_html = ~s(type="hidden" name="nix.enabled" value="false")
      checkbox_html = ~s(type="checkbox" name="nix.enabled" value="true")

      hidden_pos = :binary.match(html, hidden_html)
      checkbox_pos = :binary.match(html, checkbox_html)

      # Both must be present
      assert hidden_pos != :nomatch, "hidden boolean field not rendered"
      assert checkbox_pos != :nomatch, "checkbox boolean field not rendered"

      # Hidden must come before checkbox in the HTML
      {hidden_start, _} = hidden_pos
      {checkbox_start, _} = checkbox_pos
      assert hidden_start < checkbox_start, "hidden field must precede the checkbox"

      # The checkbox is the DaisyUI toggle and is UNCHECKED for the false/nil
      # default (nix.enabled defaults to false).
      assert html =~ ~s(class="toggle toggle-primary toggle-sm")

      refute html =~
               ~s(name="nix.enabled" value="true" class="toggle toggle-primary toggle-sm" checked)
    end
  end

  describe "platform gating" do
    # SettingsLive filters the :sandbox category per-node-OS via
    # EvoDashWeb.PlatformInfo.filter_schemas_by_category/2 — in mount AND
    # again in handle_params (before category resolution). The testable
    # injection seam is the :platform_os_override app env, which
    # PlatformInfo.os_for_node/1 checks BEFORE any OS detection — so these
    # tests are deterministic on ANY host OS. This module is async: false (the
    # seam is a BEAM-global app-env value shared with the async
    # EvoDashWeb.PlatformInfoTest), so env mutation is safe, but each test still
    # cleans up its own override.

    defp with_os_override(os) do
      Application.put_env(:evo_dash, :platform_os_override, os)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)
    end

    test "Windows override hides the Sandbox sidebar entry", %{conn: conn} do
      with_os_override(:windows)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # The platform-filtered schemas arrive with the async NodeData result —
      # deliver it deterministically (the real task computes the same values
      # under the :platform_os_override seam, so a duplicate is idempotent).
      html = deliver_node_data(view)

      # The sidebar renders one button per category, each carrying
      # phx-value-category="<name>" (EvoDashWeb.SettingsComponents.Sidebar).
      # With :sandbox deleted from schemas_by_category, no such button exists.
      refute html =~ ~s(phx-value-category="sandbox")
      # The sandbox content section is not rendered either.
      refute html =~ ~s(id="category-sandbox")
      # The default active category is :llm.
      assert html =~ ~s(id="category-llm")
    end

    test "Windows override: ?category=sandbox falls back to :llm without crashing", %{conn: conn} do
      with_os_override(:windows)

      # The result handler re-resolves the category param against the
      # platform-FILTERED schemas — deliver the async result first. On Windows
      # "sandbox" is not a known category → falls back to the active category
      # (:llm). No crash.
      {:ok, view, _html} = mount_settings(conn, ~p"/settings?category=sandbox")
      html = deliver_node_data(view, "sandbox")

      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-sandbox")
    end

    test "macOS override keeps sandbox mode + write_paths but drops Linux sub-sections", %{
      conn: conn
    } do
      with_os_override(:macos)
      # Seed write_paths so the :list_of_strings card renders its named inputs
      # (an unset/nil value renders only the "Not set" hint, no name attribute).
      seed_write_paths(["/tmp/a"])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      # Deliver the async platform-filtered schemas before selecting the
      # category (the seed shell shows the UNFILTERED map).
      deliver_node_data(view)
      html = settings_hook(view, "select_category", %{"category" => "sandbox"})

      assert assigns(view).active_category == :sandbox
      # sub_category == nil schemas (mode + write_paths) remain.
      assert html =~ ~s(name="sandbox.mode")
      assert html =~ ~s(name="sandbox.write_paths")
      # The Linux-only sub-sections (:resources/:process/:linux) are filtered
      # out, so their sub-headers never render.
      refute html =~ "Resources"
      refute html =~ "Process Limits"
      refute html =~ "Linux Security"
    end

    test "Linux override keeps the Linux Security sub-section", %{conn: conn} do
      with_os_override(:linux)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      # Deliver the async platform-filtered schemas before selecting the
      # category (the seed shell shows the UNFILTERED map).
      deliver_node_data(view)
      html = settings_hook(view, "select_category", %{"category" => "sandbox"})

      # On Linux the sandbox schemas are unchanged — all sub-sections render.
      assert html =~ "Linux Security"
      assert html =~ "Resources"
      assert html =~ "Process Limits"
    end
  end

  describe "nix category gating" do
    # SettingsLive hides the :nix category via
    # EvoDashWeb.PlatformInfo.filter_nix_category/2 (applied in mount AND in
    # handle_params before category resolution) when the nix binary is missing
    # on the node AND the user has NOT explicitly set `[nix] enabled` in the
    # raw config file. The testable injection seam is the
    # :nix_available_override app env (checked by
    # PlatformInfo.nix_available_for_node/1 BEFORE any detection) — so these
    # tests are deterministic on ANY host. This module's `setup` defaults the
    # override to true; each test here overrides it and cleans up via its own
    # on_exit (LIFO: the test's cleanup runs before setup's re-delete, and the
    # next test's setup re-establishes the true default).

    defp with_nix_available_override(bool) do
      Application.put_env(:evo_dash, :nix_available_override, bool)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :nix_available_override)
      end)
    end

    # Seed an explicit `[nix] enabled` in the RAW user config file (under this
    # module's per-process isolated config dir). Must be called BEFORE
    # mount_settings(conn, ~p"/settings") so mount sees it.
    defp seed_nix_enabled(bool) do
      File.mkdir_p!(Path.dirname(EvoGit.Config.config_path()))
      File.write!(EvoGit.Config.config_path(), "[nix]\nenabled = #{bool}\n")
    end

    test "nix binary available → nix category shown even with no config", %{conn: conn} do
      with_nix_available_override(true)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Deliver the async NodeData result (nix visible under the override) so
      # the platform-filtered schemas are in place before the gated asserts.
      html = deliver_node_data(view)

      # Sidebar entry is present on initial load...
      assert html =~ ~s(phx-value-category="nix")
      # ...and selecting the category renders its content section (only the
      # active category's section is rendered, so select first).
      section_html = settings_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary but explicit [nix] enabled = true → category shown", %{conn: conn} do
      with_nix_available_override(false)
      seed_nix_enabled(true)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view)

      assert html =~ ~s(phx-value-category="nix")
      section_html = settings_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary but explicit [nix] enabled = false → category still shown", %{conn: conn} do
      with_nix_available_override(false)
      seed_nix_enabled(false)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view)

      # An explicit false counts as "configured" — the section must stay
      # editable so the user can turn the feature on.
      assert html =~ ~s(phx-value-category="nix")
      section_html = settings_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary and no config → category hidden everywhere (sidebar, section, search)", %{
      conn: conn
    } do
      with_nix_available_override(false)

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = deliver_node_data(view)

      # Sidebar entry and content section are both gone.
      refute html =~ ~s(phx-value-category="nix")
      refute html =~ ~s(id="category-nix")
      # The default active category is :llm.
      assert html =~ ~s(id="category-llm")

      # Selecting the hidden category is a no-op — it is not a known category
      # in the filtered map, so active_category stays :llm.
      select_html = settings_hook(view, "select_category", %{"category" => "nix"})

      assert assigns(view).active_category == :llm
      refute select_html =~ ~s(id="category-nix")

      # Search: only the nix schemas ([nix] :enabled / :flake_output) contain
      # "nix" in key_path/description, so with the category removed from
      # @schemas_by_category the search finds zero matches.
      search_html = settings_hook(view, "search", %{"value" => "nix"})

      assert search_html =~ "No settings found matching"
    end

    test "no nix binary and no config: ?category=nix falls back to :llm without crashing", %{
      conn: conn
    } do
      with_nix_available_override(false)

      # The result handler re-resolves the category param against the
      # platform-FILTERED schemas — deliver the async result first. With nix
      # hidden, "nix" is not a known category → falls back to the active
      # category (:llm). No crash.
      {:ok, view, _html} = mount_settings(conn, ~p"/settings?category=nix")
      html = deliver_node_data(view, "nix")

      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-nix")
    end
  end

  describe "shell seeding (last-known filtered nav)" do
    # The sidebar `/settings` renders ALWAYS comes from the LAST-KNOWN
    # platform-filtered schemas map (seeded at mount from the page's own local
    # filtering, refreshed by every async NodeData result). An explicit
    # `?category=` therefore resolves against what the viewed node really has:
    # a displayable category opens on the FIRST paint with zero flash, and a
    # platform-gated one neither opens nor is ever advertised in the nav.
    #
    # The html returned by live/3 is ALWAYS the seed-shell render (the async
    # task's message cannot interleave with the mount/handle_params call), so
    # seed-state html assertions are deterministic. `assigns` may already
    # reflect the real task's (fast, local) result — seed asserts below
    # therefore use scenarios where the seed state and the post-result state
    # coincide, and the post-delivery asserts use deliver_node_data (ours is
    # the last message processed).
    test "displayable ?category=agents renders the agents section immediately", %{conn: conn} do
      {:ok, view, html} = mount_settings(conn, ~p"/settings?category=agents")

      # Seeded by Navigation.seed/3 against the filtered map — no async result
      # needed. The real task's resolution lands on :agents too.
      assert assigns(view).active_category == :agents
      assert html =~ ~s(phx-value-category="agents")
      # The custom-agent ROSTER arrives ASYNC (mount only seeds the loading
      # placeholder), so the editor assertion happens after the load result.
      html = render(view)
      assert html =~ "Add Agent"
    end

    test "displayable ?category=sandbox renders its section on the first paint", %{
      conn: conn
    } do
      with_os_override(:linux)

      # Mount's own (cheap, local) filtering keeps :sandbox on Linux, so the
      # seeded nav offers it AND the sandbox section renders immediately.
      {:ok, view, html} = mount_settings(conn, ~p"/settings?category=sandbox")
      assert assigns(view).active_category == :sandbox
      assert html =~ ~s(id="category-sandbox")
      refute html =~ ~s(id="category-llm")
      assert html =~ ~s(phx-value-category="sandbox")

      # The async result (sandbox kept on Linux) cannot undo it.
      html = deliver_node_data(view, "sandbox")
      assert assigns(view).active_category == :sandbox
      assert html =~ ~s(id="category-sandbox")
    end

    test "displayable ?category=nix renders its section on the first paint", %{conn: conn} do
      # nix binary available (this module's setup default) → nix displayable.
      {:ok, view, html} = mount_settings(conn, ~p"/settings?category=nix")
      assert assigns(view).active_category == :nix
      assert html =~ ~s(id="category-nix")

      html = deliver_node_data(view, "nix")
      assert assigns(view).active_category == :nix
      assert html =~ ~s(id="category-nix")
    end

    test "hidden ?category=nix stays :llm and is never advertised", %{conn: conn} do
      with_nix_available_override(false)

      # nix is gated on this host, so the seeded nav never offers it and the
      # active category is the stable default — from the FIRST paint — and the
      # sidebar stays non-empty.
      {:ok, view, html} = mount_settings(conn, ~p"/settings?category=nix")
      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      assert html =~ ~s(phx-value-category="agents")
      refute html =~ ~s(phx-value-category="nix")

      # The async result agrees, and the URL param is not rewritten.
      html = deliver_node_data(view, "nix")
      assert assigns(view).active_category == :llm
      refute html =~ ~s(phx-value-category="nix")
      refute html =~ ~s(id="category-nix")
    end
  end
end
