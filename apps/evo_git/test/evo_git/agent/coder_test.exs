defmodule EvoGit.Agent.CoderTest do
  use ExUnit.Case
  alias EvoGit.Agent

  @moduletag :tmp_dir

  defmodule DummyAgent do
    use Agent

    def test_build_dynamic_context(repo_path, node_path) do
      build_dynamic_context(%{repo_path: repo_path, node_path: node_path})
    end
  end

  test "build_dynamic_context does not return massive strings for simple paths", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root context")
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib context")

    context = DummyAgent.test_build_dynamic_context(tmp_dir, "lib")

    assert context =~ "Root context"
    assert context =~ "Lib context"
    assert String.length(context) < 1000
  end

  test "build_dynamic_context with missing files returns empty string", %{tmp_dir: tmp_dir} do
    context = DummyAgent.test_build_dynamic_context(tmp_dir, "lib/missing/path")
    assert context =~ "Current Repository"
    assert context =~ "Current Assigned Node"
  end

  test "build_dynamic_context catches ArgumentError and returns base context", %{tmp_dir: tmp_dir} do
    context = DummyAgent.test_build_dynamic_context(tmp_dir, "/outside/path")
    assert context =~ "Current Path:"
  end

  test "build_dynamic_context handles nil gracefully" do
    context = DummyAgent.test_build_dynamic_context(nil, nil)
    assert context =~ "Current Path:"
  end
end
