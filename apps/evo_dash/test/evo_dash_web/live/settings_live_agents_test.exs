# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.SettingsLiveTest.ConnectionManager). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.SettingsLiveAgentsTest.ConnectionManager do
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

defmodule EvoDashWeb.SettingsLiveAgentsTest do
  # async: true — this module's only shared-state concern, the config dir, is
  # PER-PROCESS (`EvoDash.Test.ConfigDir.isolate!/1`, resolved through
  # `$callers` so the mounted LiveView and its supervised load tasks see THIS
  # test's dir). It
  # touches no app-env seam (`:nix_available_override` / `:platform_os_override`
  # belong to settings_live_test.exs' sync module), no AgentScheduler state and
  # no ETS hub; `EvoDash.ActiveTasks` is per-test data that ConnCase resets
  # too, so nothing here can race an async peer.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  # Isolate all tests in this file from the host's real user config: the
  # custom-agents store (agents.toml) lives in EvoGit.Config.config_dir/0.
  # `isolate!/1` gives this test its own temp dir and activates it for this
  # process (and, through the `$callers` chain, for the mounted view and its
  # supervised load tasks), so a clean agents.toml per test is guaranteed
  # WITHOUT touching any BEAM-global env var — the same per-process idiom as
  # settings_live_test.exs.
  setup do
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_agents_test_config")
    on_exit(fn -> File.rm_rf!(dir) end)

    # ActiveTasks is a global GenServer under EvoDash.Application — reset it so
    # one test's sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    :ok
  end

  # Bounded-poll cadence: the mount funnel below returns the instant this
  # mount's async tasks are gone, so a finer cadence only removes overshoot
  # (same idiom as `tasks_live_test.exs`'s `@wait_poll_ms`).
  @wait_poll_ms 2

  # Generous best-effort deadline for that funnel: past it the wait simply stops
  # and the test's own synchronous call drains whatever is still queued.
  @settle_timeout_ms 5_000

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Mounts the Settings page and waits for the async node-data load that mount
  # kicks off (`EvoDashWeb.SettingsLive.NodeData`, a supervised
  # `EvoDash.TaskSupervisor` child) to have been SENT before returning. Its
  # result handler re-assigns the MOUNT-TIME snapshot of `:custom_agents` /
  # `:model_selection_script` / `:script_status` and resets `:editing_agent_id`
  # / `:script_save_error` / `:script_test_results`, so a result landing after a
  # test's own hook would clobber what that hook just set (the source of a rare
  # full-suite flake: `script_test_results` reads back as `[]`).
  #
  # OWNER-AWARE: only the `EvoDash.TaskSupervisor` children THIS mount spawned
  # are awaited. A supervised task records the process that started it in its
  # `$callers` process-dictionary entry, so matching that against the view pid
  # targets exactly this mount's tasks (`settings_live_test.exs`'s
  # `mount_async_task_pids/1` and `tasks_live_test.exs`'s `drain_async_loads/2`
  # use the same idiom). A blanket `Task.Supervisor.children/1` scan is NOT
  # safe: `EvoDash.TaskSupervisor` never kills children per test, so a
  # long-lived child another test left behind (e.g. a runner stub parked on
  # `receive`) made every mount here pay the whole deadline.
  #
  # A task leaves the supervisor only AFTER its `send(parent, ...)` ran, so once
  # this mount's tasks are gone the result message is already queued in the
  # LiveView's mailbox — and the trailing `render/1` is a synchronous round-trip
  # that drains it, so every request the test sends afterwards is processed
  # AFTER it and the assertion stays race-free without a fixed sleep.
  defp mount_settings(conn, url \\ "/settings?category=agents") do
    {:ok, view, html} = live(conn, url)
    await_view_async_loads(view)
    {:ok, view, html}
  end

  # Bounded poll on "this view owns no live supervised task" (returns
  # immediately when the mount's load already finished), then a synchronous
  # `render/1` round-trip to flush the queued result messages into the view.
  defp await_view_async_loads(view) do
    wait_until(fn -> view_async_loads_idle?(view.pid) end, @settle_timeout_ms)
    render(view)
    :ok
  end

  defp view_async_loads_idle?(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.all?(fn
      {_, pid, _, _} when is_pid(pid) -> not waitable_view_child?(pid, view_pid)
      _ -> true
    end)
  end

  # A live child is one this funnel still has to wait for when `view` started it.
  # An unset `$callers` is NOT proof that it is foreign — a freshly spawned child
  # may not have run its first instruction yet — so it counts as waitable and the
  # poll continues. That converges: every `Task.Supervised` child puts `$callers`
  # in its process dictionary before running the function it was given.
  defp waitable_view_child?(pid, view_pid) do
    case task_callers(pid) do
      :unset -> true
      callers -> view_pid in callers
    end
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.fetch(dict, :"$callers") do
          {:ok, callers} -> callers
          :error -> :unset
        end

      _ ->
        # The child exited between the enumeration and this read: nothing left
        # to wait for.
        []
    end
  end

  # Best-effort bounded poll on an observable end state: returns as soon as
  # `fun` holds, and otherwise stops at the deadline (the caller then proceeds
  # with whatever the test's own synchronous call can still drain).
  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(@wait_poll_ms)
        do_wait_until(fun, deadline)
    end
  end

  defp save_agent(view, attrs) do
    params =
      Map.merge(
        %{
          "agent_id" => "",
          "name" => "Code Reviewer",
          "description" => "",
          "prompt" => "You are a reviewer.",
          "agent_type" => "read_write",
          "delegation_level" => "low",
          "model_id" => "",
          "max_turns" => ""
        },
        attrs
      )

    render_hook(view, "save_custom_agent", params)
  end

  # The `value`s of the agent editor's `tools[]` checkboxes that render CHECKED
  # (alias-aware: a chip whose label is the model-facing name still submits the
  # agent's own saved spelling as its value).
  defp checked_tool_values(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(input[name="tools[]"]))
    |> Enum.filter(fn el -> Floki.attribute(el, "checked") != [] end)
    |> Enum.map(fn el -> List.first(Floki.attribute(el, "value")) end)
    |> MapSet.new()
  end

  # Builds a `%{ok: [...], errors: []}` custom-tools status carrying a single ok
  # entry (the shape `EvoGit.CustomTools.status/0` yields and the panel
  # consumes).
  defp ok_tool_status(name, opts \\ []) do
    %{
      ok: [
        %{
          name: name,
          module: Keyword.get(opts, :module, "M"),
          file: Keyword.get(opts, :file, "/cfg/tools/#{name}.ex"),
          read_only?: Keyword.get(opts, :read_only?, true)
        }
      ],
      errors: []
    }
  end

  # Extracts the Custom Tools panel's Refresh <button> opening tag so an
  # assertion can pin THAT button's disabled state (a bare `"disabled"`
  # substring would also match unrelated disabled controls on the page).
  defp refresh_button_tag(html) do
    case Regex.run(~r/<button[^>]*phx-click="reload_custom_tools"[^>]*>/, html) do
      [tag] -> tag
      _ -> flunk("Custom Tools Refresh button not found in:\n#{html}")
    end
  end

  describe "agents category rendering" do
    test "renders the custom agents and script editors", %{conn: conn} do
      {:ok, _view, html} = mount_settings(conn)

      # Add Agent button, empty state, script editor controls.
      assert html =~ "Add Agent"
      assert html =~ "No custom agents defined"
      assert html =~ ~s(name="script")
      assert html =~ "Test script"
      assert html =~ "Custom Agents"
      assert html =~ "Model Selection Script"
      # Pseudo-categories render as sidebar buttons with phx-value-category
      # (same shape as :remote_connections — no id="category-..." wrapper).
      assert html =~ ~s(phx-value-category="agents")
    end
  end

  describe "custom agent CRUD" do
    # One mount for the whole lifecycle: draft form -> save -> edit pre-fill ->
    # update -> delete (each event still asserts its own contract).
    test "add / edit / delete round-trip", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      html = render_hook(view, "add_custom_agent", %{})
      assert html =~ "New Agent"
      assert html =~ "Save Agent"

      html = save_agent(view, %{})
      assert html =~ "Custom agent saved."
      assert html =~ "Code Reviewer"

      assert Enum.any?(EvoGit.CustomAgents.list(), &(&1.id == "code_reviewer"))
      assert Enum.any?(assigns(view).custom_agents, &(&1.id == "code_reviewer"))
      # Editing state closed after save.
      assert assigns(view).editing_agent_id == nil

      html = render_hook(view, "edit_custom_agent", %{"id" => "code_reviewer"})
      assert html =~ "Edit Agent"
      assert html =~ ~s(value="Code Reviewer")

      html =
        save_agent(view, %{
          "agent_id" => "code_reviewer",
          "name" => "Renamed Reviewer",
          "agent_type" => "read",
          "delegation_level" => "high"
        })

      assert html =~ "Custom agent saved."
      assert html =~ "Renamed Reviewer"

      [agent] = EvoGit.CustomAgents.list()
      assert agent.id == "code_reviewer"
      assert agent.name == "Renamed Reviewer"
      assert agent.agent_type == :read
      assert agent.delegation_level == :high

      html = render_hook(view, "delete_custom_agent", %{"id" => "code_reviewer"})

      assert html =~ "Custom agent deleted."
      refute html =~ "Renamed Reviewer"
      assert EvoGit.CustomAgents.list() == []
    end

    test "rejects an empty name (core :missing_name) and a duplicate id", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "  "})

      assert html =~ "Name cannot be empty."
      assert EvoGit.CustomAgents.list() == []

      save_agent(view, %{"name" => "Dup Agent"})

      # A second agent with the same name slugifies to the same id.
      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "Dup Agent"})

      assert html =~ "already exists"
      assert length(EvoGit.CustomAgents.list()) == 1
    end
  end

  describe "model selection script" do
    test "a saved script persists across page reloads (valid and broken)", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      script = ~s(if agent.depth == 0, do: "default", else: "fast")
      html = render_hook(view, "save_model_selection_script", %{"script" => script})

      assert html =~ "Model selection script saved."
      # Valid script — no compile error box.
      refute html =~ "Script error"
      assert EvoGit.CustomAgents.model_selection_script() == script

      # Bust the ModelSelector cache (same-second/same-size writes could
      # otherwise serve a stale compile) and remount to verify persistence.
      EvoGit.CustomAgents.reload()

      {:ok, view2, html2} = mount_settings(conn)
      assert html2 =~ "agent.depth == 0"
      refute html2 =~ "Script error"

      # Broken scripts save as :ok — the compile status only surfaces via
      # ModelSelector.status/0 after the reload.
      html =
        render_hook(view2, "save_model_selection_script", %{"script" => "this is ( not elixir"})

      assert html =~ "Model selection script saved."
      assert html =~ "Script error"
      assert match?({:error, {:compile_error, _}}, assigns(view2).script_status)

      EvoGit.CustomAgents.reload()

      {:ok, _view3, html3} = mount_settings(conn)
      assert html3 =~ "Script error"
    end

    test "test script button returns the 3 sample results for valid and broken scripts", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn)

      # The script body is wrapped as `fn agent -> ... end` by the core, so a
      # constant script must be the quoted string literal `"fast"` (the bare
      # word `fast` is an undefined variable → compile error).
      render_hook(view, "save_model_selection_script", %{"script" => ~s("fast")})
      html = render_hook(view, "test_model_selection_script", %{})

      assert html =~ "Test Results"
      results = assigns(view).script_test_results
      assert length(results) == 3
      assert Enum.all?(results, fn r -> r.result == {:ok, "fast"} end)

      labels = Enum.map(results, & &1.label)
      assert Enum.any?(labels, &(&1 =~ "architect"))
      assert Enum.any?(labels, &(&1 =~ "executor"))
      assert Enum.any?(labels, &(&1 =~ ~r/custom/i))

      render_hook(view, "save_model_selection_script", %{"script" => "this is ( not elixir"})
      html = render_hook(view, "test_model_selection_script", %{})

      results = assigns(view).script_test_results
      assert length(results) == 3
      assert Enum.all?(results, fn r -> match?({:error, {:compile_error, _}}, r.result) end)
      assert html =~ "Test Results"
    end
  end

  describe "custom tools panel" do
    # The async custom-tools refresh result. `requested_node` is captured at
    # spawn time and stale-guarded against `socket.assigns.current_node` (a
    # local mount resolves `current_node` to `node()`), so injecting with
    # `node()` lands on the currently-viewed node.
    # One mount, one status per shape: the panel's per-shape markup is pinned by
    # `test/evo_dash_web/components/custom_tools_panel_test.exs`; this test pins
    # only that the LiveView handler applies every `{:custom_tools_loaded, ...}`
    # shape (and that the banner and the empty state stay mutually exclusive).
    test "applies every custom-tools status shape for the current node", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      send(
        view.pid,
        {:custom_tools_loaded, node(),
         ok_tool_status("my_tool", module: "MyTool", file: "/cfg/tools/my_tool.ex")}
      )

      html = render(view)

      assert html =~ "my_tool"
      assert html =~ "MyTool"
      assert html =~ "/cfg/tools/my_tool.ex"
      # Pin the badge content itself (`>Read-only<`) — a bare "Read-only"
      # substring could be satisfied by surrounding chrome instead of the badge.
      assert html =~ ">Read-only<"
      refute html =~ "No custom tools loaded"

      send(
        view.pid,
        {:custom_tools_loaded, node(),
         ok_tool_status("writer_tool", module: "WriterTool", read_only?: false)}
      )

      html = render(view)

      assert html =~ "writer_tool"
      # Pin the badge content itself. The fixture's module name ("WriterTool")
      # contains "Write", so a bare "Write" substring would pass even if the
      # badge rendered nothing — `>Write<` can only come from the badge span.
      assert html =~ ">Write<"
      refute html =~ "Read-only"

      send(
        view.pid,
        {:custom_tools_loaded, node(),
         %{
           ok: [],
           errors: [%{file: "/cfg/tools/broken.ex", reason: "compile error: unexpected token"}]
         }}
      )

      html = render(view)

      assert html =~ "/cfg/tools/broken.ex"
      assert html =~ "compile error: unexpected token"
      refute html =~ "No custom tools loaded"

      send(view.pid, {:custom_tools_loaded, node(), {:error, :boom}})
      html = render(view)

      assert html =~ "Custom Tools Unavailable"
      assert html =~ ":boom"
      # Banner and empty state are mutually exclusive.
      refute html =~ "No custom tools loaded"

      send(view.pid, {:custom_tools_loaded, node(), %{ok: [], errors: []}})
      html = render(view)

      assert html =~ "No custom tools loaded"
      refute html =~ "Custom Tools Unavailable"
    end

    test "refresh click spins the button then applies a later result", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      # The click sets `custom_tools_loading` synchronously and spawns a
      # supervised fetch. The HTML returned reflects the post-event state, so
      # the Refresh button is disabled here.
      html = render_click(view, "reload_custom_tools", %{})
      assert refresh_button_tag(html) =~ "disabled"

      # The click's own task delivers an (empty) status that could arrive
      # before or after our injected one. Wait for THIS view's task to leave the
      # supervisor (its `send` has run by then) and drain it, so the sentinel
      # below is the last status applied. Owner-scoped like the mount funnel:
      # any unrelated child still parked on the supervisor is none of our
      # business (and must not cost this test its deadline).
      await_view_async_loads(view)

      send(view.pid, {:custom_tools_loaded, node(), ok_tool_status("sentinel_tool")})

      html = render(view)
      assert html =~ "sentinel_tool"
      assert assigns(view).custom_tools_loading == false
      refute refresh_button_tag(html) =~ "disabled"
    end

    test "drops a result for a foreign node", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      send(view.pid, {:custom_tools_loaded, node(), ok_tool_status("kept_tool")})
      assert render(view) =~ "kept_tool"

      send(
        view.pid,
        {:custom_tools_loaded, :some_other_node@host, ok_tool_status("sentinel_tool")}
      )

      html = render(view)

      refute html =~ "sentinel_tool"
      assert html =~ "kept_tool"
      # The stale result still clears the loading flag (never sticks).
      assert assigns(view).custom_tools_loading == false
    end

    test "applies a node-data result that omits the custom-tools key", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)
      current = assigns(view)

      # Older-shaped node-data loads carry no `:custom_tools_status` — the
      # handler must fall back to the empty status instead of crashing.
      results = %{
        platform_os: current[:platform_os],
        filtered_schemas_by_category: current[:schemas_by_category],
        file_config: current[:file_config],
        config_status: current[:config_status],
        remote_config_error: nil,
        custom_agents: %{agents: [], model_selection_script: "", script_status: :ok}
      }

      send(view.pid, {:settings_node_data_loaded, node(), "agents", results})

      html = render(view)

      assert assigns(view).active_category == :agents
      assert html =~ "No custom tools loaded"
      assert html =~ "No custom agents defined"
    end

    test "offers loaded custom tools as chips in the agent editor", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      send(view.pid, {:custom_tools_loaded, node(), ok_tool_status("my_custom_tool")})
      render(view)

      html = render_hook(view, "add_custom_agent", %{})

      assert html =~ ~s(value="my_custom_tool")
      assert html =~ ~s(name="tools[]")
      assert html =~ "Custom tools"
    end

    test "warns only about genuinely unknown tool names", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      save_agent(view, %{"name" => "Tooly", "tools" => ["bogus_tool"]})

      html = render_hook(view, "edit_custom_agent", %{"id" => "tooly"})

      assert html =~
               "Unknown tool names: bogus_tool. They are neither built-in tools nor loaded custom tools."

      # The core renamed the MODEL-FACING schema names (`read`, `write`, `bash`, …)
      # while `agents.toml` may carry any accepted spelling. The editor must
      # resolve both spellings onto the same tool concept: no bogus warning, the
      # new-name chip CHECKED, and the agent's own saved spelling preserved in the
      # submitted value (never rewrite user config).
      #
      # `read_file`/`run_bash` are the legacy spellings of the `read`/`bash`
      # concept chips. (`web_search` is deliberately not exercised here: its
      # schema is env-gated — without a web-search backend it is absent from
      # `Tools.schemas()`, so it is not a built-in tool name in this env.)
      save_agent(view, %{"name" => "Legacy", "tools" => ["read_file", "run_bash"]})

      html = render_hook(view, "edit_custom_agent", %{"id" => "legacy"})

      refute html =~ "Unknown tool names"

      checked = checked_tool_values(html)
      assert MapSet.member?(checked, "read_file")
      assert MapSet.member?(checked, "run_bash")
      # The chips are labelled with the NEW model-facing names, so nothing
      # submits the new spelling when the agent saved the legacy one.
      refute MapSet.member?(checked, "read")
      refute MapSet.member?(checked, "bash")
    end
  end

  describe "remote node degradation" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under the target id with a :connected
    # phase, so NodeAware resolves `?node=` to the remote BEAM node atom
    # "genesis_remote@127.0.0.1" — an unreachable fake node (same seam as
    # settings_live_test.exs). The subsequent :erpc calls fail fast, and
    # NodeContext.list_custom_agents/1 degrades to an empty result, so the
    # agents category renders as "no custom agents" instead of crashing.
    defp save_target! do
      id = "settings-agents-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Settings Agents Test Target"
        })

      on_exit(fn ->
        EvoGit.RemoteConnections.delete(id)
      end)

      id
    end

    test "renders an empty agent list without crashing", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLiveAgentsTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, html} = mount_settings(conn, "/settings?node=" <> id <> "&category=agents")

      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"
      assert assigns(view)[:custom_agents] == []
      assert assigns(view)[:model_selection_script] == ""
      assert assigns(view)[:script_status] == :ok
      assert html =~ "No custom agents defined"
    end
  end
end
