defmodule EvoGit.CustomToolsDispatchTest do
  @moduledoc """
  Dispatch/gating + custom-agent integration tests for the custom-tools
  subsystem: how `EvoGit.Agent.Tools.execute/5` dispatches and gates custom
  tools, and how `EvoGit.Agents.Custom` advertises them.

  `async: false` — every test repoints the BEAM-global `XDG_CONFIG_HOME` env var
  so custom tools never read the real `~/.config/genesis/` directory.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools
  alias EvoGit.CustomTools

  setup do
    isolate_xdg!()

    tmp_dir = Path.join(System.tmp_dir!(), "evogit-ct-dispatch-#{uniq()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    write_tool = "ct_write_#{uniq()}"
    read_tool = "ct_read_#{uniq()}"
    write_source_tool!(dir(), "#{write_tool}.ex", write_tool, read_only: false)
    write_source_tool!(dir(), "#{read_tool}.ex", read_tool, read_only: true)
    CustomTools.reload()

    {:ok, %{tmp_dir: tmp_dir, write_tool: write_tool, read_tool: read_tool}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp isolate_xdg! do
    original = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg = Path.join(System.tmp_dir!(), "evogit-ct-xdg-#{uniq()}")
    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      EvoGit.CustomTools.Loader.invalidate(Path.join(EvoGit.Config.config_dir(), "tools"))

      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp dir, do: CustomTools.tools_dir()

  defp module_for(suffix), do: Module.concat([:"CustomToolsDispatchFixture#{suffix}"])

  defp tool_source(module, tool_name, opts) do
    {execute_body, uses_args?} =
      cond do
        Keyword.get(opts, :raise) -> {~s|raise "custom tool boom"|, false}
        true -> {~s|"custom-tool-ran:" <> inspect(args)|, true}
      end

    arg_name = if uses_args?, do: "args", else: "_args"

    """
    defmodule #{inspect(module)} do
      @behaviour EvoGit.CustomTools.Tool

      @impl true
      def schema do
        ReqLLM.tool(
          name: #{inspect(tool_name)},
          description: "custom tools test fixture",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, nil} end
        )
      end

      @impl true
      def execute(#{arg_name}, _ctx), do: #{execute_body}

      @impl true
      def read_only?, do: #{Keyword.get(opts, :read_only, false)}
    end
    """
  end

  defp write_raw!(dir, basename, content) do
    File.mkdir_p!(dir)
    path = Path.join(dir, basename)
    File.write!(path, content)
    path
  end

  defp write_source_tool!(dir, basename, tool_name, opts) do
    module = module_for(uniq())
    path = write_raw!(dir, basename, tool_source(module, tool_name, opts))
    {module, path}
  end

  # Agent operating inside a READ-ONLY foreign repo: the process-dict keys that
  # `maybe_block_read_only_foreign_repo/5` reads are set so the id matches the
  # foreign repo entry and the repo_path lives under the foreign root.
  defp with_read_only_foreign_repo(tmp_dir, fun) do
    foreign_root = Path.join(tmp_dir, "foreign")
    repo_path = Path.join([foreign_root, ".genesis", "workers", "worker_T1_A1"])

    Process.put(:foreign_repos, [
      %EvoGit.Core.ForeignRepo{id: "orig", root: foreign_root, writable: false}
    ])

    Process.put(:evogit_repo_id, "orig")
    Process.put(:repo_path, repo_path)

    on_exit(fn ->
      Process.delete(:foreign_repos)
      Process.delete(:evogit_repo_id)
      Process.delete(:repo_path)
    end)

    fun.(repo_path)
  end

  # ---------------------------------------------------------------------------
  # Dispatch / gating through EvoGit.Agent.Tools.execute/5
  # ---------------------------------------------------------------------------

  describe "EvoGit.Agent.Tools.execute/5 — custom-tool dispatch" do
    test "dispatches a registered custom tool name to its module", %{
      tmp_dir: tmp_dir,
      write_tool: tool
    } do
      result = Tools.execute(tool, %{"hello" => "world"}, tmp_dir, tmp_dir)

      assert result =~ "custom-tool-ran"
      assert result =~ "world"
      refute result =~ "Unknown tool"
    end

    test "a custom WRITE tool is blocked for a repo-less agent", %{
      tmp_dir: tmp_dir,
      write_tool: tool
    } do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      result = Tools.execute(tool, %{}, tmp_dir, tmp_dir)

      assert result =~ "read-only access to the system"
      assert result =~ tool
      assert result =~ "tool is disabled"
    end

    test "a custom WRITE tool is blocked inside a read-only foreign repo", %{
      tmp_dir: tmp_dir,
      write_tool: tool
    } do
      with_read_only_foreign_repo(tmp_dir, fn repo_path ->
        result = Tools.execute(tool, %{}, repo_path)

        assert result =~ "read-only foreign repository"
        assert result =~ tool
      end)
    end

    test "a read-only custom tool is NOT blocked for a repo-less agent", %{
      tmp_dir: tmp_dir,
      read_tool: tool
    } do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      result = Tools.execute(tool, %{}, tmp_dir, tmp_dir)

      assert result =~ "custom-tool-ran"
      refute result =~ "read-only access to the system"
    end

    test "a read-only custom tool is NOT blocked inside a read-only foreign repo", %{
      tmp_dir: tmp_dir,
      read_tool: tool
    } do
      with_read_only_foreign_repo(tmp_dir, fn repo_path ->
        result = Tools.execute(tool, %{}, repo_path)

        assert result =~ "custom-tool-ran"
        refute result =~ "read-only foreign repository"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Fall-through to dynamic skills (must remain unbroken)
  # ---------------------------------------------------------------------------

  describe "unknown-tool fall-through" do
    test "an unknown tool name still returns the unknown-tool error", %{tmp_dir: tmp_dir} do
      result = Tools.execute("ct_missing_#{uniq()}", %{}, tmp_dir, tmp_dir)

      assert result =~ "Unknown tool"
      refute result =~ "custom-tool-ran"
    end

    test "a name matching a dynamic skill still reaches the skill executor", %{
      tmp_dir: tmp_dir
    } do
      skill = "ct-skill-#{uniq()}"
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)

      File.write!(Path.join(skills_dir, "#{skill}.md"), """
      ---
      name: #{skill}
      description: A demo skill with no bash block
      ---

      # Demo skill

      Just instructions.
      """)

      result = Tools.execute(skill, %{}, tmp_dir, tmp_dir)

      refute result =~ "Unknown tool"
      assert result =~ "instructions"
    end
  end

  # ---------------------------------------------------------------------------
  # EvoGit.Agents.Custom integration
  # ---------------------------------------------------------------------------

  describe "EvoGit.Agents.Custom integration" do
    test "an explicit tools whitelist includes a custom tool" do
      tool = "ct_agent_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, read_only: true)
      CustomTools.reload()

      put_custom_agent!(save_agent!(tools: [tool]))

      assert available_tool_names() == [tool]
    end

    test "custom tools are NOT added when tools is nil" do
      tool = "ct_agent_nil_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, read_only: true)
      CustomTools.reload()

      put_custom_agent!(save_agent!(tools: nil))

      names = available_tool_names()
      refute tool in names
      assert "read_file" in names
      assert "complete_task" in names
    end

    test "end-to-end: custom tool file + agents.toml definition ⇒ advertised AND executable" do
      tool = "ct_e2e_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, read_only: true)
      CustomTools.reload()

      id = save_agent!(tools: [tool])
      assert %{tools: [^tool]} = EvoGit.CustomAgents.get(id)

      put_custom_agent!(id)

      assert tool in available_tool_names()

      result = Tools.execute(tool, %{"hello" => "world"}, System.tmp_dir!(), System.tmp_dir!())
      assert result =~ "custom-tool-ran"
      assert result =~ "world"
    end
  end

  # ---------------------------------------------------------------------------
  # Custom-agent helpers
  # ---------------------------------------------------------------------------

  defp save_agent!(overrides) do
    definition =
      Map.merge(
        %{name: "CT Dispatch Agent #{uniq()}", prompt: "You are a custom test agent."},
        Map.new(overrides)
      )

    {:ok, %{id: id}} = EvoGit.CustomAgents.save(definition)
    id
  end

  defp put_custom_agent!(id) do
    Process.put(:custom_agent_id, id)
    on_exit(fn -> Process.delete(:custom_agent_id) end)
    id
  end

  defp available_tool_names do
    EvoGit.Agents.Custom.available_tools() |> Enum.map(&EvoGit.Agent.tool_name/1)
  end
end
