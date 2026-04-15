defmodule EvoGitTest do
  use ExUnit.Case

  test "generates correct sandbox args" do
    cwd = "/my/project"
    args = EvoGit.sandbox_args(cwd, "bash", ["-c", "ls"])
    assert Enum.take(args, 3) == ["--user", "--wait", "--pipe"]
    assert "-p" in args
    assert "PrivatePIDs=yes" in args
    assert "ProtectProc=invisible" in args
    assert List.last(args) == "ls"
  end
end
