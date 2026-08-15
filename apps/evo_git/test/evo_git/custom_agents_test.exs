defmodule EvoGit.CustomAgentsTest do
  use ExUnit.Case, async: false

  # Tests mutate the XDG_CONFIG_HOME env var so that CustomAgents never
  # touches the real ~/.config/genesis/ directory.
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  describe "path/0" do
    test "points into the platform config dir" do
      assert EvoGit.CustomAgents.path() ==
               Path.join(EvoGit.Config.config_dir(), "agents.toml")
    end
  end

  describe "list/0" do
    test "returns [] when no file exists" do
      assert EvoGit.CustomAgents.list() == []
    end
  end

  describe "save/1" do
    test "succeeds with just name+prompt, auto-generating a slugified id and applying defaults" do
      assert {:ok, agent} =
               EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "You are..."})

      assert agent.id == "code_reviewer"
      assert agent.name == "Code Reviewer"
      assert agent.prompt == "You are..."
      assert agent.agent_type == :read_write
      assert agent.delegation_level == :low
      assert agent.subagents == []
      assert is_nil(agent.description)
      assert is_nil(agent.model_id)
      assert is_nil(agent.max_turns)
      assert is_nil(agent.tools)
    end

    test "accepts atom agent_type and delegation_level values" do
      assert {:ok, agent} =
               EvoGit.CustomAgents.save(%{
                 name: "Atom Types",
                 prompt: "p",
                 agent_type: :read,
                 delegation_level: :high
               })

      assert agent.agent_type == :read
      assert agent.delegation_level == :high
    end

    test "full fields round-trip via list/get (string agent_type normalized to atom)" do
      assert {:ok, saved} =
               EvoGit.CustomAgents.save(%{
                 name: "Full Agent",
                 description: "Full featured",
                 prompt: "You are a full agent",
                 agent_type: "read",
                 delegation_level: "high",
                 model_id: "gpt-5",
                 max_turns: 40,
                 tools: ["read_file", "run_bash"],
                 subagents: ["executor", "investigator"]
               })

      assert saved.agent_type == :read
      assert saved.delegation_level == :high

      fetched = EvoGit.CustomAgents.get(saved.id)
      assert fetched == saved

      list = EvoGit.CustomAgents.list()
      assert length(list) == 1
      assert hd(list) == saved
    end

    test "returns {:error, :missing_name} when name is absent or empty" do
      assert {:error, :missing_name} = EvoGit.CustomAgents.save(%{prompt: "p"})
      assert {:error, :missing_name} = EvoGit.CustomAgents.save(%{name: "", prompt: "p"})
      assert {:error, :missing_name} = EvoGit.CustomAgents.save(%{name: nil, prompt: "p"})
    end

    test "returns {:error, :missing_prompt} when prompt is absent or empty" do
      assert {:error, :missing_prompt} = EvoGit.CustomAgents.save(%{name: "n"})
      assert {:error, :missing_prompt} = EvoGit.CustomAgents.save(%{name: "n", prompt: ""})
      assert {:error, :missing_prompt} = EvoGit.CustomAgents.save(%{name: "n", prompt: nil})
    end

    test "returns {:error, :invalid_agent_type} for an unknown agent_type" do
      assert {:error, :invalid_agent_type} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", agent_type: "flying"})
    end

    test "returns {:error, :invalid_delegation_level} for an unknown delegation_level" do
      assert {:error, :invalid_delegation_level} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", delegation_level: "medium"})
    end

    test "returns {:error, :invalid_max_turns} for non-positive or non-integer values" do
      assert {:error, :invalid_max_turns} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", max_turns: 0})

      assert {:error, :invalid_max_turns} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", max_turns: -3})

      assert {:error, :invalid_max_turns} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", max_turns: "forty"})
    end

    test "returns {:error, :invalid_tools} when tools is not a list of strings" do
      assert {:error, :invalid_tools} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", tools: "read_file"})

      assert {:error, :invalid_tools} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", tools: ["read_file", 42]})
    end

    test "returns {:error, :invalid_subagents} when subagents is not a list of strings" do
      assert {:error, :invalid_subagents} =
               EvoGit.CustomAgents.save(%{name: "n", prompt: "p", subagents: "executor"})
    end

    test "returns {:error, :duplicate_id} when a second auto-generated id collides" do
      assert {:ok, _first} = EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "p1"})

      assert {:error, :duplicate_id} =
               EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "p2"})

      assert length(EvoGit.CustomAgents.list()) == 1
    end

    test "updates an existing agent when the same explicit id is saved again" do
      assert {:ok, first} = EvoGit.CustomAgents.save(%{name: "Tweaker", prompt: "v1"})

      assert {:ok, updated} =
               EvoGit.CustomAgents.save(%{id: first.id, name: "Tweaker", prompt: "v2"})

      assert updated.prompt == "v2"

      list = EvoGit.CustomAgents.list()
      assert length(list) == 1
      assert hd(list).prompt == "v2"
    end

    test "ignores unknown keys" do
      assert {:ok, agent} =
               EvoGit.CustomAgents.save(%{name: "Known", prompt: "p", unknown_key: "dropped"})

      refute Map.has_key?(agent, :unknown_key)
      assert EvoGit.CustomAgents.get(agent.id) == agent
    end
  end

  describe "get/1" do
    test "returns the definition when found" do
      assert {:ok, saved} = EvoGit.CustomAgents.save(%{name: "Fetcher", prompt: "p"})
      assert %{name: "Fetcher"} = EvoGit.CustomAgents.get(saved.id)
    end

    test "returns nil for an unknown id" do
      assert EvoGit.CustomAgents.get("does-not-exist") == nil
    end
  end

  describe "delete/1" do
    test "removes the agent and returns :ok, then {:error, :not_found}" do
      assert {:ok, saved} = EvoGit.CustomAgents.save(%{name: "Deletable", prompt: "p"})
      assert :ok = EvoGit.CustomAgents.delete(saved.id)
      assert EvoGit.CustomAgents.list() == []
      assert {:error, :not_found} = EvoGit.CustomAgents.delete(saved.id)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.CustomAgents.delete("nope")
    end
  end

  describe "model_selection_script/0 and save_model_selection_script/1" do
    test "returns nil initially" do
      assert EvoGit.CustomAgents.model_selection_script() == nil
    end

    test "round-trips a script through the file" do
      script = "defmodule MySelector do\n  def pick(_), do: :ok\nend"

      assert :ok = EvoGit.CustomAgents.save_model_selection_script(script)
      assert EvoGit.CustomAgents.model_selection_script() == script
    end

    test "saving and deleting agents preserves the model_selection script" do
      script = "x = 1"
      assert :ok = EvoGit.CustomAgents.save_model_selection_script(script)

      assert {:ok, agent} = EvoGit.CustomAgents.save(%{name: "Preserver", prompt: "p"})
      assert EvoGit.CustomAgents.model_selection_script() == script

      assert :ok = EvoGit.CustomAgents.delete(agent.id)
      assert EvoGit.CustomAgents.model_selection_script() == script
      assert EvoGit.CustomAgents.list() == []
    end

    test "saving the script preserves existing agents" do
      assert {:ok, _agent} = EvoGit.CustomAgents.save(%{name: "Keeper", prompt: "p"})
      assert :ok = EvoGit.CustomAgents.save_model_selection_script("s = 1")

      list = EvoGit.CustomAgents.list()
      assert length(list) == 1
      assert hd(list).name == "Keeper"
    end

    test "an empty script removes the key" do
      assert :ok = EvoGit.CustomAgents.save_model_selection_script("s = 1")
      assert :ok = EvoGit.CustomAgents.save_model_selection_script("")
      assert EvoGit.CustomAgents.model_selection_script() == nil
    end
  end

  describe "reload/0" do
    test "returns :ok (guarded invalidate call)" do
      assert :ok = EvoGit.CustomAgents.reload()
    end
  end

  describe "persistence round-trip" do
    test "writes [[agents]] TOML on disk" do
      assert {:ok, _agent} = EvoGit.CustomAgents.save(%{name: "On Disk", prompt: "p"})

      toml_path = EvoGit.CustomAgents.path()
      assert File.exists?(toml_path)
      assert File.read!(toml_path) =~ "[[agents]]"
    end

    test "reads a manually written TOML file incl. model_selection" do
      File.mkdir_p!(EvoGit.Config.config_dir())

      toml = """
      [model_selection]
      script = \"\"\"
      defmodule MySelector do
        def pick(_), do: :default
      end
      \"\"\"

      [[agents]]
      id = "manual_agent"
      name = "Manual Agent"
      description = "Written by hand"
      prompt = "You are manually defined"
      agent_type = "read"
      delegation_level = "high"
      model_id = "gpt-5"
      max_turns = 12
      tools = ["read_file", "write_file"]
      subagents = ["executor"]
      """

      File.write!(EvoGit.CustomAgents.path(), toml)

      assert EvoGit.CustomAgents.model_selection_script() =~ "MySelector"

      list = EvoGit.CustomAgents.list()
      assert length(list) == 1

      agent = hd(list)
      assert agent.id == "manual_agent"
      assert agent.name == "Manual Agent"
      assert agent.description == "Written by hand"
      assert agent.prompt == "You are manually defined"
      assert agent.agent_type == :read
      assert agent.delegation_level == :high
      assert agent.model_id == "gpt-5"
      assert agent.max_turns == 12
      assert agent.tools == ["read_file", "write_file"]
      assert agent.subagents == ["executor"]

      assert %{name: "Manual Agent"} = EvoGit.CustomAgents.get("manual_agent")
    end

    test "list/0 does not raise on an unknown agent_type string" do
      File.mkdir_p!(EvoGit.Config.config_dir())

      File.write!(
        EvoGit.CustomAgents.path(),
        """
        [[agents]]
        id = "odd"
        name = "Odd"
        prompt = "p"
        agent_type = "flying"
        """
      )

      list = EvoGit.CustomAgents.list()
      assert length(list) == 1
      assert hd(list).agent_type == "flying"
      assert hd(list).delegation_level == :low
      assert hd(list).subagents == []
      assert hd(list).tools == nil
    end
  end
end
