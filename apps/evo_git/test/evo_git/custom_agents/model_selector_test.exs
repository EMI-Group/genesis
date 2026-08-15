defmodule EvoGit.CustomAgents.ModelSelectorTest do
  use ExUnit.Case, async: false

  # Tests mutate the XDG_CONFIG_HOME env var so that CustomAgents never
  # touches the real ~/.config/genesis/ directory.
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # The cache key embeds the agents.toml path (which follows XDG_CONFIG_HOME),
    # so stale entries from other tests could otherwise leak through.
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

  defp agent(attrs \\ %{}) do
    Map.merge(
      %{
        agent_type: :custom,
        custom_agent_id: nil,
        depth: 0,
        parent_id: nil,
        task_id: "task-1",
        objective: "test objective"
      },
      Map.new(attrs)
    )
  end

  defp write_script(script) do
    EvoGit.CustomAgents.save_model_selection_script(script)
    EvoGit.CustomAgents.ModelSelector.invalidate()
  end

  defp write_full_toml(toml) do
    path = EvoGit.CustomAgents.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, toml)
    EvoGit.CustomAgents.ModelSelector.invalidate()
  end

  describe "compile_script/1" do
    test "returns a function with the agent map in scope" do
      assert {:ok, fun} = EvoGit.CustomAgents.ModelSelector.compile_script("agent.depth")

      assert fun.(%{depth: 2}) == 2
      assert fun.(%{depth: 0}) == 0
    end

    test "returns the value of the LAST expression, ignoring let-bindings" do
      assert {:ok, fun} =
               EvoGit.CustomAgents.ModelSelector.compile_script("""
               x = "first"
               y = "second"
               x <> y
               """)

      assert fun.(%{}) == "firstsecond"
    end

    test "returns a compile_error tuple for invalid syntax" do
      assert {:error, {:compile_error, message}} =
               EvoGit.CustomAgents.ModelSelector.compile_script("agent.depth +")

      assert is_binary(message)
      assert message != ""
    end
  end

  describe "select_model/1 without a configured script" do
    test "returns {:ok, nil} when no agents.toml exists" do
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, nil}
      assert EvoGit.CustomAgents.ModelSelector.status() == :ok
      refute EvoGit.CustomAgents.ModelSelector.enabled?()
    end

    test "returns {:ok, nil} when the file has no model_selection section" do
      write_full_toml("[other_section]\nkey = \"value\"\n")
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, nil}
      assert EvoGit.CustomAgents.ModelSelector.status() == :ok
      refute EvoGit.CustomAgents.ModelSelector.enabled?()
    end
  end

  describe "select_model/1 with a configured script" do
    test "evaluates a script matching on agent.custom_agent_id" do
      write_script("""
      case agent.custom_agent_id do
        "researcher" -> "deep-research-model"
        _ -> "default-model"
      end
      """)

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(custom_agent_id: "researcher")) ==
               {:ok, "deep-research-model"}

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(custom_agent_id: "coder")) ==
               {:ok, "default-model"}
    end

    test "evaluates a script matching on agent.agent_type (module atom)" do
      write_script("""
      case agent.agent_type do
        EvoGit.Agents.Manager -> "manager-model"
        _ -> "worker-model"
      end
      """)

      assert EvoGit.CustomAgents.ModelSelector.select_model(
               agent(agent_type: EvoGit.Agents.Manager)
             ) == {:ok, "manager-model"}

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(agent_type: :custom)) ==
               {:ok, "worker-model"}
    end

    test "evaluates a script matching on agent.depth and agent.parent_id" do
      write_script("""
      cond do
        agent.depth == 0 -> "root-model"
        agent.parent_id != nil and agent.depth <= 2 -> "shallow-model"
        true -> "deep-model"
      end
      """)

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, "root-model"}

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(depth: 1, parent_id: 7)) ==
               {:ok, "shallow-model"}

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(depth: 4, parent_id: 7)) ==
               {:ok, "deep-model"}
    end

    test "the moduledoc example script works end to end" do
      write_script(~s(if agent.depth == 0, do: "default", else: "fast"))

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(depth: 0)) == {:ok, "default"}
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent(depth: 1)) == {:ok, "fast"}
    end

    test "returns {:ok, nil} when the script yields nil" do
      write_script("nil")
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, nil}
    end

    test "returns {:ok, nil} when the script yields an empty string" do
      write_script(~s(""))
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, nil}
    end

    test "returns {:ok, nil} when the script yields false" do
      write_script("false")
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, nil}
    end

    test "returns script_raised without raising when the script raises" do
      write_script(~s(raise "boom"))

      assert {:error, {:script_raised, message}} =
               EvoGit.CustomAgents.ModelSelector.select_model(agent())

      assert message =~ "boom"
    end

    test "returns script_raised when the script hits a bad map access" do
      write_script("agent.depth")

      assert {:error, {:script_raised, message}} =
               EvoGit.CustomAgents.ModelSelector.select_model(Map.delete(agent(), :depth))

      assert message =~ "depth"
    end

    test "returns invalid_result when the script yields a non-string" do
      write_script("42")

      assert {:error, {:invalid_result, "42"}} =
               EvoGit.CustomAgents.ModelSelector.select_model(agent())

      write_script(":fast")

      assert {:error, {:invalid_result, ":fast"}} =
               EvoGit.CustomAgents.ModelSelector.select_model(agent())
    end
  end

  describe "broken scripts" do
    test "select_model/1 returns compile_error and status/0 reports it" do
      write_script("agent.depth +")

      assert {:error, {:compile_error, message}} =
               EvoGit.CustomAgents.ModelSelector.select_model(agent())

      assert is_binary(message)
      assert {:error, {:compile_error, ^message}} = EvoGit.CustomAgents.ModelSelector.status()
    end

    test "enabled?/0 is true for a broken script" do
      write_script("agent.depth +")
      assert EvoGit.CustomAgents.ModelSelector.enabled?()
    end
  end

  describe "caching" do
    test "picks up a new script after invalidate/0" do
      write_script(~s("first-model"))
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, "first-model"}

      # Overwrite agents.toml with a different script and invalidate the cache.
      path = EvoGit.CustomAgents.path()
      File.write!(path, ~s([model_selection]\nscript = """\n"second-model"\n"""))

      EvoGit.CustomAgents.ModelSelector.invalidate()

      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, "second-model"}
    end

    test "invalidate/0 also clears a broken-script cache entry" do
      write_script("agent.depth +")

      assert {:error, {:compile_error, _}} =
               EvoGit.CustomAgents.ModelSelector.select_model(agent())

      write_script(~s("fixed-model"))
      assert EvoGit.CustomAgents.ModelSelector.select_model(agent()) == {:ok, "fixed-model"}
    end
  end

  describe "describe_contract/0" do
    test "documents the agent map fields and the return contract" do
      contract = EvoGit.CustomAgents.ModelSelector.describe_contract()

      for field <- ~w(agent_type custom_agent_id depth parent_id task_id objective) do
        assert contract =~ field
      end

      assert contract =~ "LAST expression"
      assert contract =~ "default"
    end
  end
end
