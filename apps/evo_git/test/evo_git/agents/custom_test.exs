defmodule EvoGit.Agents.CustomTest do
  @moduledoc """
  `async: true` — every test works on its own per-process config directory
  (`EvoGit.TestSupport.ConfigDir`) so `EvoGit.CustomAgents` never touches the
  real `~/.config/genesis/` directory, and every definition lookup runs in the
  calling test process.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("evogit-agents-custom")
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

    test "fall back to the store-normalized defaults when the fields are absent" do
      id = save_definition!(%{prompt: "minimal"})
      put_custom_agent!(id)

      # EvoGit.CustomAgents normalizes absent fields on save to the agents.toml
      # schema defaults: :read_write for agent_type, :low for delegation_level.
      assert EvoGit.Agents.Custom.agent_type() == :read_write
      assert EvoGit.Agents.Custom.delegation_level() == :low
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

    test "maps string entries from agents.toml (save/1 rejects atom entries)" do
      # The agents.toml contract stores subagents as STRINGS; saving atom
      # entries is rejected by EvoGit.CustomAgents.save/1 with
      # :invalid_subagents (the store, not the runtime agent, owns validation).
      assert {:error, :invalid_subagents} =
               EvoGit.CustomAgents.save(%{
                 name: "Atom Subagents",
                 prompt: "doomed",
                 subagents: [:executor]
               })

      id = save_definition!(%{subagents: ["executor"]})
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
      assert "read" in names
      assert "bash" in names
      # The subagent tool schema for the executor subagent is included too.
      assert EvoGit.Agents.Executor.subagent_tool_name() in names
    end

    test "filters to exactly the whitelist when tools is a list (legacy spellings)" do
      # The whitelist is intentionally written with the PRE-RENAME spellings
      # (`read_file`/`write_file`): alias-aware matching must still resolve them
      # to the shipped `read`/`write` schemas — a literal comparison would
      # resolve this whitelist to no tools at all (the P0 regression).
      id =
        save_definition!(%{
          subagents: ["executor"],
          tools: ["read_file", "write_file", "complete_task"]
        })

      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert Enum.sort(names) == ["complete_task", "read", "write"]
      refute "bash" in names
      refute EvoGit.Agents.Executor.subagent_tool_name() in names
    end

    test "allows filtering complete_task out" do
      id = save_definition!(%{tools: ["read_file"]})
      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert names == ["read"]
      refute "complete_task" in names
    end

    test "also accepts the shipped model-facing spellings" do
      id = save_definition!(%{tools: ["read", "write", "bash"]})
      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert Enum.sort(names) == ["bash", "read", "write"]
    end

    test "mixes legacy and shipped spellings without duplicating schemas" do
      id = save_definition!(%{tools: ["read_file", "read", "web_search", "search_web"]})
      put_custom_agent!(id)

      names =
        EvoGit.Agents.Custom.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      # `read_file`/`read` are two spellings of ONE concept, as are
      # `web_search`/`search_web` — dedupe-by-schema-name keeps exactly one
      # schema per name and no tool is dropped.
      assert "read" in names
      assert Enum.uniq(names) == names
      assert Enum.all?(names, &(&1 in ["read", "web_search"]))
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
