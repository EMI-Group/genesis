defmodule EvoGit.Agent.CoderTest2 do
  use ExUnit.Case
  alias EvoGit.Agent

  @moduletag :tmp_dir

  defmodule DummyAgent do
    use Agent

    def test_build_dynamic_context(repo_path, node_path) do
      build_dynamic_context(%{repo_path: repo_path, node_path: node_path})
    end
  end

  test "build_dynamic_context with node_path at repo root", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root context")

    context = DummyAgent.test_build_dynamic_context(tmp_dir, ".")

    assert context =~ "Root context"
    assert String.length(context) < 1000
  end
end
