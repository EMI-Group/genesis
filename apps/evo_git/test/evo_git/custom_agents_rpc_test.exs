defmodule EvoGit.CustomAgentsRPCTest do
  @moduledoc """
  Tests for the custom-agents RPC surface:

    * `EvoGit.AgentScheduler.RemoteAPI` — the direct per-node functions
      (`list_custom_agents/0`, `save_custom_agent/1`, `delete_custom_agent/1`,
      `save_model_selection_script/1`, `reload_custom_agents/0`).
    * `EvoGit.RemoteNode` — the node-first wrappers (local path delegates to
      RemoteAPI; the remote branch is exercised through the unreachable-node
      `call_remote/4` failure path, same pattern as remote_node_test.exs).

  Uses `async: false` and mutates `XDG_CONFIG_HOME` so `agents.toml` is
  written to a temp dir and never touches the real `~/.config/genesis/`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.CustomAgents
  alias EvoGit.RemoteNode

  # A node name that definitely does not exist on this machine (same pattern
  # as remote_node_test.exs). On a non-distributed local node, :erpc.call to
  # a foreign node fails immediately with {:erpc, :noconnection} — no TCP
  # timeout wait.
  @fake_remote :"nonexistent@127.0.0.1"

  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # The ModelSelector compile cache is keyed on the agents.toml path (which
    # follows XDG_CONFIG_HOME) plus file mtime/size — invalidate before and
    # after for determinism (same pattern as model_selector_test.exs).
    EvoGit.CustomAgents.ModelSelector.invalidate()

    on_exit(fn ->
      EvoGit.CustomAgents.ModelSelector.invalidate()

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  defp valid_agent(overrides \\ %{}) do
    Map.merge(%{name: "RPC Agent", prompt: "You are an RPC agent"}, overrides)
  end

  # ── RemoteAPI direct functions ─────────────────────────────────────

  describe "RemoteAPI.list_custom_agents/0" do
    test "returns the empty shape when no agents.toml exists" do
      assert {:ok,
              %{
                agents: [],
                model_selection_script: nil,
                script_status: :ok
              }} = RemoteAPI.list_custom_agents()
    end

    test "shows a saved agent" do
      assert {:ok, agent} = RemoteAPI.save_custom_agent(valid_agent())
      assert agent.id == "rpc_agent"

      assert {:ok, %{agents: [listed]}} = RemoteAPI.list_custom_agents()
      assert listed == agent
    end

    test "surfaces a broken model-selection script as script_status compile_error" do
      assert :ok = RemoteAPI.save_model_selection_script("agent.depth +")
      assert :ok = RemoteAPI.reload_custom_agents()

      assert {:ok, %{script_status: {:error, {:compile_error, msg}}}} =
               RemoteAPI.list_custom_agents()

      assert is_binary(msg)
      assert msg != ""
    end
  end

  describe "RemoteAPI.save_custom_agent/1" do
    test "rejects a definition without a prompt" do
      assert {:error, :missing_prompt} = RemoteAPI.save_custom_agent(%{name: "No Prompt"})
    end

    test "rejects a definition without a name" do
      assert {:error, :missing_name} = RemoteAPI.save_custom_agent(%{prompt: "p"})
    end
  end

  describe "RemoteAPI.delete_custom_agent/1" do
    test "deletes an existing agent and reports missing ids" do
      assert {:ok, agent} = RemoteAPI.save_custom_agent(valid_agent())

      assert :ok = RemoteAPI.delete_custom_agent(agent.id)
      assert {:ok, %{agents: []}} = RemoteAPI.list_custom_agents()

      assert {:error, :not_found} = RemoteAPI.delete_custom_agent(agent.id)
    end
  end

  describe "RemoteAPI.save_model_selection_script/1" do
    test "round-trips the script through list_custom_agents/0" do
      assert :ok = RemoteAPI.save_model_selection_script(~s("fast"))

      assert {:ok, %{model_selection_script: script, script_status: :ok}} =
               RemoteAPI.list_custom_agents()

      assert script == ~s("fast")
    end
  end

  describe "RemoteAPI.reload_custom_agents/0" do
    test "returns :ok and picks up direct file writes" do
      assert :ok = RemoteAPI.reload_custom_agents()

      path = CustomAgents.path()
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        """
        [[agents]]
        name = "Written Directly"
        prompt = "You are direct"
        """
      )

      assert :ok = RemoteAPI.reload_custom_agents()

      assert {:ok, %{agents: [agent]}} = RemoteAPI.list_custom_agents()
      assert agent.name == "Written Directly"
      assert agent.prompt == "You are direct"
    end
  end

  # ── RemoteNode wrappers (local node) ───────────────────────────────

  describe "RemoteNode custom-agents wrappers on the local node" do
    test "list_custom_agents/1 delegates to RemoteAPI" do
      assert RemoteNode.list_custom_agents(node()) == RemoteAPI.list_custom_agents()
    end

    test "save/delete/script/reload wrappers delegate to RemoteAPI" do
      assert {:ok, agent} = RemoteNode.save_custom_agent(node(), valid_agent())
      assert {:ok, %{agents: [^agent]}} = RemoteNode.list_custom_agents(node())

      assert :ok = RemoteNode.save_model_selection_script(node(), ~s("fast"))

      assert {:ok, %{model_selection_script: ~s("fast")}} =
               RemoteNode.list_custom_agents(node())

      assert :ok = RemoteNode.delete_custom_agent(node(), agent.id)
      assert {:ok, %{agents: []}} = RemoteNode.list_custom_agents(node())

      assert {:error, :not_found} = RemoteNode.delete_custom_agent(node(), agent.id)

      assert :ok = RemoteNode.reload_custom_agents(node())
    end
  end

  # ── RemoteNode wrappers (unreachable remote node) ──────────────────
  #
  # Unlike the fire-and-forget recent-projects wrappers, these are
  # user-action RPCs — the remote failure is surfaced as {:error, reason}.

  describe "RemoteNode custom-agents wrappers on an unreachable remote node" do
    test "list_custom_agents/1 surfaces the RPC failure" do
      assert {:error, _reason} = RemoteNode.list_custom_agents(@fake_remote)
    end

    test "save_custom_agent/2 surfaces the RPC failure" do
      assert {:error, _reason} =
               RemoteNode.save_custom_agent(@fake_remote, valid_agent())
    end

    test "delete_custom_agent/2 surfaces the RPC failure" do
      assert {:error, _reason} = RemoteNode.delete_custom_agent(@fake_remote, "some_id")
    end

    test "save_model_selection_script/2 surfaces the RPC failure" do
      assert {:error, _reason} =
               RemoteNode.save_model_selection_script(@fake_remote, ~s("fast"))
    end

    test "reload_custom_agents/1 surfaces the RPC failure" do
      assert {:error, _reason} = RemoteNode.reload_custom_agents(@fake_remote)
    end
  end
end
