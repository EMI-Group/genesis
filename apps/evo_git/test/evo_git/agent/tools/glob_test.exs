defmodule EvoGit.Agent.Tools.GlobTest do
  use ExUnit.Case
  alias EvoGit.Agent.Tools

  @moduletag :tmp_dir

  describe "execute/4 - malformed patterns" do
    test "unmatched '{' returns an error string and does not crash", %{tmp_dir: tmp_dir} do
      result = Tools.execute("glob", %{"pattern" => "{unclosed"}, tmp_dir, tmp_dir)

      assert is_binary(result)
      assert result =~ ~r/invalid|malformed/i
      assert result =~ "{unclosed"
      assert result =~ "balanced"
    end

    test "unmatched '{' with prefix returns an error string", %{tmp_dir: tmp_dir} do
      result = Tools.execute("glob", %{"pattern" => "foo{"}, tmp_dir, tmp_dir)

      assert is_binary(result)
      assert result =~ ~r/invalid|malformed/i
      assert result =~ "foo{"
    end

    test "unmatched '[' returns an error string or no-match (never crashes)", %{tmp_dir: tmp_dir} do
      result = Tools.execute("glob", %{"pattern" => "[unclosed"}, tmp_dir, tmp_dir)

      assert is_binary(result)
      # On this Elixir version, an unmatched '[' yields no match rather than a
      # badpattern error, so accept either an error string or the no-match msg.
      assert result =~ ~r/invalid|malformed|No files found/i
      refute String.starts_with?(result, "** (")
    end
  end

  describe "execute/4 - happy path" do
    test "valid pattern returns matching files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.ex"), "defmodule Sample do\nend\n")

      result = Tools.execute("glob", %{"pattern" => "*.ex"}, tmp_dir, tmp_dir)

      assert result =~ "Found:"
      assert result =~ "sample.ex"
    end

    test "valid pattern with recursive glob returns matching files", %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "lib")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "helper.ex"), ":ok\n")

      result = Tools.execute("glob", %{"pattern" => "**/*.ex"}, tmp_dir, tmp_dir)

      assert result =~ "Found:"
      assert result =~ "helper.ex"
    end
  end

  describe "execute/4 - no matches" do
    test "valid pattern with no matches returns no-files message", %{tmp_dir: tmp_dir} do
      result = Tools.execute("glob", %{"pattern" => "*.nonexistent"}, tmp_dir, tmp_dir)

      assert result =~ "No files found"
    end
  end
end
