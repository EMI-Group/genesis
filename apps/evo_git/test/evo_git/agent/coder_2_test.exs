defmodule EvoGit.Agent.CoderTest2 do
  @moduledoc """
  `async: true` — the single test writes and reads only inside its own
  `:tmp_dir` fixture directory via `EvoGit.Agent.ContextBuilder.build_dynamic_context/1`;
  no shared/global state is touched.
  """

  use ExUnit.Case, async: true
  alias EvoGit.Agent

  @moduletag :tmp_dir

  defmodule DummyAgent do
    use Agent

    def test_build_dynamic_context(repo_path, node_path) do
      EvoGit.Agent.ContextBuilder.build_dynamic_context(%{
        repo_path: repo_path,
        node_path: node_path
      })
    end
  end

  test "build_dynamic_context with node_path at repo root", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "Root context")

    context = DummyAgent.test_build_dynamic_context(tmp_dir, ".")

    assert context =~ "Root context"
    assert String.length(context) < 1000
  end
end
