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

    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

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

  describe "agents category rendering" do
    test "renders the custom agents and script editors", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?category=agents")

      # Add Agent button, empty state, script editor controls.
      assert html =~ "Add Agent"
      assert html =~ "No custom agents defined"
      assert html =~ ~s(name="script")
      assert html =~ "Test script"
      assert html =~ "Custom Agents"
      assert html =~ "Model Selection Script"
    end

    test "renders the sidebar entry", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?category=agents")

      # Pseudo-categories render as sidebar buttons with phx-value-category
      # (same shape as :remote_connections — no id="category-..." wrapper).
      assert html =~ ~s(phx-value-category="agents")
      assert html =~ "Agents"
    end
  end

  describe "custom agent CRUD" do
    test "add flow: draft form appears and saving persists the agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")

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
      {:ok, view, _html} = live(conn, "/settings?category=agents")

      save_agent(view, %{"name" => "Dup Agent"})

      # A second agent with the same name slugifies to the same id.
      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "Dup Agent"})

      assert html =~ "already exists"
      assert length(EvoGit.CustomAgents.list()) == 1
    end

    test "empty name is rejected (core :missing_name)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")

      render_hook(view, "add_custom_agent", %{})
      html = save_agent(view, %{"name" => "  "})

      assert html =~ "Name cannot be empty."
      assert EvoGit.CustomAgents.list() == []
    end

    test "edit flow: form pre-fills and saving updates the agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")
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
      {:ok, view, _html} = live(conn, "/settings?category=agents")
      save_agent(view, %{})

      html = render_hook(view, "delete_custom_agent", %{"id" => "code_reviewer"})

      assert html =~ "Custom agent deleted."
      refute html =~ "Code Reviewer"
      assert EvoGit.CustomAgents.list() == []
    end
  end

  describe "model selection script" do
    test "saving a valid script persists it across page reloads", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")

      script = ~s(if agent.depth == 0, do: "default", else: "fast")
      html = render_hook(view, "save_model_selection_script", %{"script" => script})

      assert html =~ "Model selection script saved."
      # Valid script — no compile error box.
      refute html =~ "Script error"
      assert EvoGit.CustomAgents.model_selection_script() == script

      # Bust the ModelSelector cache (same-second/same-size writes could
      # otherwise serve a stale compile) and remount to verify persistence.
      EvoGit.CustomAgents.reload()

      {:ok, _view2, html2} = live(conn, "/settings?category=agents")
      assert html2 =~ "agent.depth == 0"
      refute html2 =~ "Script error"
    end

    test "a broken script saves but surfaces the compile error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")

      # Broken scripts save as :ok — the compile status only surfaces via
      # ModelSelector.status/0 after the reload.
      html =
        render_hook(view, "save_model_selection_script", %{"script" => "this is ( not elixir"})

      assert html =~ "Model selection script saved."
      assert html =~ "Script error"
      assert match?({:error, {:compile_error, _}}, assigns(view).script_status)

      EvoGit.CustomAgents.reload()

      {:ok, _view2, html2} = live(conn, "/settings?category=agents")
      assert html2 =~ "Script error"
    end

    test "test script button returns the 3 sample results for a valid script", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?category=agents")

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
      {:ok, view, _html} = live(conn, "/settings?category=agents")

      render_hook(view, "save_model_selection_script", %{"script" => "this is ( not elixir"})
      html = render_hook(view, "test_model_selection_script", %{})

      results = assigns(view).script_test_results
      assert length(results) == 3
      assert Enum.all?(results, fn r -> match?({:error, {:compile_error, _}}, r.result) end)
      assert html =~ "Test Results"
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

      {:ok, view, html} = live(conn, "/settings?node=" <> id <> "&category=agents")

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
