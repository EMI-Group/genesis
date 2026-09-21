defmodule EvoDashWeb.SettingsLiveAgentsTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Isolate all tests in this file from the host's real user config: the
  # custom-agents store (agents.toml) lives in EvoGit.Config.config_dir/0,
  # which honours XDG_CONFIG_HOME on Linux. Pointing it at a unique temp dir
  # guarantees a clean agents.toml per test (same pattern as
  # settings_live_test.exs and apps/evo_git/test/evo_git/custom_agents_test.exs).
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_settings_agents_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    :ok
  end

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
  # A task leaves the supervisor only AFTER its `send(parent, ...)` ran, so once
  # the tasks observed at mount are gone, the result message is already queued
  # in the LiveView's mailbox — and every request the test sends afterwards is
  # therefore processed AFTER it, making the assertion race-free without a fixed
  # sleep. Only the tasks present at mount are waited for, so an unrelated
  # lingering task can never stall the suite.
  defp mount_settings(conn, url \\ "/settings?category=agents") do
    result = live(conn, url)
    mounted_tasks = Task.Supervisor.children(EvoDash.TaskSupervisor)
    wait_until(fn -> Enum.all?(mounted_tasks, &(not Process.alive?(&1))) end, 2_000)
    result
  end

  # Best-effort bounded poll on an observable end state: returns as soon as
  # `fun` holds (or the deadline passes, leaving the previous behavior).
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
        Process.sleep(5)
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
    end

    test "renders the sidebar entry", %{conn: conn} do
      {:ok, _view, html} = mount_settings(conn)

      # Pseudo-categories render as sidebar buttons with phx-value-category
      # (same shape as :remote_connections — no id="category-..." wrapper).
      assert html =~ ~s(phx-value-category="agents")
      assert html =~ "Agents"
    end
  end

  describe "custom agent CRUD" do
    test "add flow: draft form appears and saving persists the agent", %{conn: conn} do
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
    end

    test "duplicate id is rejected with the duplicate message", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      save_agent(view, %{"name" => "Dup Agent"})

      # A second agent with the same name slugifies to the same id.
      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "Dup Agent"})

      assert html =~ "already exists"
      assert length(EvoGit.CustomAgents.list()) == 1
    end

    test "empty name is rejected (core :missing_name)", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "  "})

      assert html =~ "Name cannot be empty."
      assert EvoGit.CustomAgents.list() == []
    end

    test "edit flow: form pre-fills and saving updates the agent", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)
      save_agent(view, %{})

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
    end

    test "delete flow: removes the agent", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)
      save_agent(view, %{})

      html = render_hook(view, "delete_custom_agent", %{"id" => "code_reviewer"})

      assert html =~ "Custom agent deleted."
      refute html =~ "Code Reviewer"
      assert EvoGit.CustomAgents.list() == []
    end
  end

  describe "model selection script" do
    test "saving a valid script persists it across page reloads", %{conn: conn} do
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

      {:ok, _view2, html2} = mount_settings(conn)
      assert html2 =~ "agent.depth == 0"
      refute html2 =~ "Script error"
    end

    test "a broken script saves but surfaces the compile error", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      # Broken scripts save as :ok — the compile status only surfaces via
      # ModelSelector.status/0 after the reload.
      html =
        render_hook(view, "save_model_selection_script", %{"script" => "this is ( not elixir"})

      assert html =~ "Model selection script saved."
      assert html =~ "Script error"
      assert match?({:error, {:compile_error, _}}, assigns(view).script_status)

      EvoGit.CustomAgents.reload()

      {:ok, _view2, html2} = mount_settings(conn)
      assert html2 =~ "Script error"
    end

    test "test script button returns the 3 sample results for a valid script", %{conn: conn} do
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
    end

    test "test script button shows error tuples for a broken script", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

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
    test "renders a read-only ok entry", %{conn: conn} do
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
      assert html =~ "Read-only"
      refute html =~ "No custom tools loaded"
    end

    test "renders a write ok entry", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      send(
        view.pid,
        {:custom_tools_loaded, node(),
         ok_tool_status("writer_tool", module: "WriterTool", read_only?: false)}
      )

      html = render(view)

      assert html =~ "writer_tool"
      assert html =~ "Write"
      refute html =~ "Read-only"
    end

    test "renders populated errors", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

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
    end

    test "renders the unavailable banner for an error status", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      send(view.pid, {:custom_tools_loaded, node(), {:error, :boom}})

      html = render(view)

      assert html =~ "Custom Tools Unavailable"
      assert html =~ ":boom"
      # Banner and empty state are mutually exclusive.
      refute html =~ "No custom tools loaded"
    end

    test "renders the empty state for an empty ok status", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

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
      # before or after our injected one. Wait for it to leave the supervisor
      # (its `send` has run by then) and drain it, so the sentinel below is the
      # last status applied.
      spawned = Task.Supervisor.children(EvoDash.TaskSupervisor)
      wait_until(fn -> Enum.all?(spawned, &(not Process.alive?(&1))) end, 2_000)
      render(view)

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
      assert html =~ "Custom tools"
    end

    test "warns about unknown tool names in the agent editor", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      save_agent(view, %{"name" => "Tooly", "tools" => ["bogus_tool"]})

      html = render_hook(view, "edit_custom_agent", %{"id" => "tooly"})

      assert html =~
               "Unknown tool names: bogus_tool. They are neither built-in tools nor loaded custom tools."
    end

    test "does not warn for a valid built-in tool", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      save_agent(view, %{"name" => "Reader", "tools" => ["read_file"]})

      html = render_hook(view, "edit_custom_agent", %{"id" => "reader"})

      refute html =~ "Unknown tool names"
      assert html =~ ~s(value="read_file")
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
