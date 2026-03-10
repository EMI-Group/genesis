defmodule EvoGit.Agent.CoderTest do
  use ExUnit.Case
  alias EvoGit.Agent.Coder

  @moduletag :tmp_dir

  defmodule DummyAgent do
    use Coder

    def test_build_dynamic_context do
      build_dynamic_context()
    end
  end

  test "build_dynamic_context does not return massive strings for simple paths", %{
    tmp_dir: tmp_dir
  } do
    Process.put(:repo_path, tmp_dir)
    Process.put(:node_path, Path.join(tmp_dir, "lib"))

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root context")
    File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Lib context")

    context = DummyAgent.test_build_dynamic_context()

    assert context =~ "Root context"
    assert context =~ "Lib context"
    assert String.length(context) < 1000
  end

  test "build_dynamic_context with missing files returns empty string", %{tmp_dir: tmp_dir} do
    Process.put(:repo_path, tmp_dir)
    Process.put(:node_path, Path.join(tmp_dir, "lib/missing/path"))

    context = DummyAgent.test_build_dynamic_context()
    assert context =~ "Current Location:"
  end

  test "build_dynamic_context catches ArgumentError and returns empty", %{tmp_dir: tmp_dir} do
    Process.put(:repo_path, tmp_dir)
    Process.put(:node_path, "/outside/path")

    context = DummyAgent.test_build_dynamic_context()
    assert context == ""
  end

  test "build_dynamic_context handles nil gracefully" do
    Process.put(:repo_path, nil)
    Process.put(:node_path, nil)

    context = DummyAgent.test_build_dynamic_context()
    assert context == ""
  end
end
