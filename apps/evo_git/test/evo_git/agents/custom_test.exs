defmodule EvoGit.Agents.CustomTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # `EvoGit.Agents.Custom` resolves its definition at runtime from
  # `EvoGit.CustomAgents`. Until that module lands (parallel implementation), the
  # whole suite is skipped instead of erroring on UndefinedFunctionError.
  unless Code.ensure_loaded?(EvoGit.CustomAgents) do
    @moduletag :skip
  end

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

  describe "definition resolution" do
    test "raises when no :custom_agent_id is in the process dictionary" do
      assert_raise RuntimeError, ~r/custom_agent_id/, fn ->
        EvoGit.Agents.Custom.system_prompt()
      end
    end

    test "raises when the id does not resolve to a definition" do
      id = save_definition!(%{prompt: "doomed"})
      EvoGit.CustomAgents.delete(id)

      put_custom_agent!(id)

      assert_raise RuntimeError, ~r/#{Regex.escape(id)}/, fn ->
        EvoGit.Agents.Custom.system_prompt()
      end
    end
  end

  describe "system_prompt/0" do
    test "returns the definition's prompt" do
      id = save_definition!(%{prompt: "Be the best custom agent."})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.system_prompt() == "Be the best custom agent."
    end
  end

  describe "agent_type/0 and delegation_level/0" do
    test "come from the definition (read + low)" do
      id = save_definition!(%{agent_type: :read, delegation_level: :low})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.agent_type() == :read
      assert EvoGit.Agents.Custom.delegation_level() == :low
    end

    test "come from the definition (read_write + high)" do
      id = save_definition!(%{agent_type: :read_write, delegation_level: :high})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.agent_type() == :read_write
      assert EvoGit.Agents.Custom.delegation_level() == :high
    end

    test "fall back to the inherited EvoGit.Agent defaults when the fields are absent" do
      id = save_definition!(%{prompt: "minimal"})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.agent_type() == :read_write
      assert EvoGit.Agents.Custom.delegation_level() == :high
      assert EvoGit.Agents.Custom.system_prompt() == "minimal"
    end
  end

  describe "subagent_tool_name/0" do
    test "is nil — custom agents are root agents only, not spawnable as subagents" do
      id = save_definition!(%{})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.subagent_tool_name() == nil
    end
  end

  describe "subagent_modules/0" do
    test "maps built-in type names to modules" do
      id =
        save_definition!(%{
          subagents: ["executor", "investigator", "manager", "architect", "task_scheduler"]
        })

      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.subagent_modules() == [
               EvoGit.Agents.Executor,
               EvoGit.Agents.Investigator,
               EvoGit.Agents.Manager,
               EvoGit.Agents.Architect,
               EvoGit.Agents.TaskScheduler
             ]
    end

    test "accepts atom entries" do
      id = save_definition!(%{subagents: [:executor]})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.subagent_modules() == [EvoGit.Agents.Executor]
    end

    test "skips unknown names with a warning instead of raising" do
      id = save_definition!(%{subagents: ["executor", "not_a_real_agent"]})
      put_custom_agent!(id)

      log =
        capture_log(fn ->
          assert EvoGit.Agents.Custom.subagent_modules() == [EvoGit.Agents.Executor]
        end)

      assert log =~ "not_a_real_agent"
    end

    test "returns [] when no subagents are configured" do
      id = save_definition!(%{})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.subagent_modules() == []
    end

    test "returns [] when subagents is nil" do
      id = save_definition!(%{subagents: nil})
      put_custom_agent!(id)

      assert EvoGit.Agents.Custom.subagent_modules() == []
    end
  end

  describe "available_tools/0" do
    test "without a whitelist includes standard tools, subagent tools, and complete_task" do
      id = save_definition!(%{subagents: ["executor"]})
      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert "complete_task" in names
      assert "read_file" in names
      assert "run_bash" in names
      # The subagent tool schema for the executor subagent is included too.
      assert EvoGit.Agents.Executor.subagent_tool_name() in names
    end

    test "filters to exactly the whitelist when tools is a list" do
      id =
        save_definition!(%{
          subagents: ["executor"],
          tools: ["read_file", "write_file", "complete_task"]
        })

      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert Enum.sort(names) == ["complete_task", "read_file", "write_file"]
      refute "run_bash" in names
      refute EvoGit.Agents.Executor.subagent_tool_name() in names
    end

    test "allows filtering complete_task out" do
      id = save_definition!(%{tools: ["read_file"]})
      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert names == ["read_file"]
      refute "complete_task" in names
    end
  end

  # --- Helpers ---

  # Saves a definition (merged over a minimal base) and extracts the id from the
  # save return, tolerating the common `{:ok, map}` / `{:ok, id}` shapes.
  defp save_definition!(overrides) do
    definition =
      Map.merge(%{name: "Test Custom Agent", prompt: "You are a custom test agent."}, overrides)

    case EvoGit.CustomAgents.save(definition) do
      {:ok, %{id: id}} when is_binary(id) ->
        id

      {:ok, id} when is_binary(id) ->
        id

      {:ok, map} when is_map(map) ->
        case Map.get(map, :id) || Map.get(map, "id") do
          id when is_binary(id) -> id
          other -> flunk("saved custom agent definition has no usable id: #{inspect(other)}")
        end

      other ->
        flunk("unexpected EvoGit.CustomAgents.save/1 return: #{inspect(other)}")
    end
  end

  # Puts the definition id into the test process's dictionary (the same process
  # calls the callbacks — exactly how the real Runner works).
  defp put_custom_agent!(id) do
    Process.put(:custom_agent_id, id)
    on_exit(fn -> Process.delete(:custom_agent_id) end)

    id
  end
end
