defmodule EvoGitTest do
  use ExUnit.Case
  doctest EvoGit

  test "greets the world" do
    assert EvoGit.hello() == :world
  end
end
