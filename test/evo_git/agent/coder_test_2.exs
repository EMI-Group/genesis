defmodule EvoGit.Agent.CoderTest2 do
  use ExUnit.Case
  alias EvoGit.Agent.Coder

  @moduletag :tmp_dir

  defmodule DummyAgent do
    use Coder

    def test_build_dynamic_context do
      build_dynamic_context()
    end
  end

  test "build_dynamic_context with node_path == repo_path", %{tmp_dir: tmp_dir} do
    Process.put(:repo_path, tmp_dir)
    Process.put(:node_path, tmp_dir)

    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root context")

    context = DummyAgent.test_build_dynamic_context()

    assert context =~ "Root context"
    assert String.length(context) < 1000
  end
end
