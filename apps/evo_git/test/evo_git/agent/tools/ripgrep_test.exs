defmodule EvoGit.Agent.Tools.RipgrepTest do
  use ExUnit.Case
  alias EvoGit.Agent.Tools

  @moduletag :tmp_dir

  describe "schemas/0 - rg" do
    test "rg schema is included in tool schemas" do
      schemas = Tools.schemas()
      names = Enum.map(schemas, & &1.name)
      assert "rg" in names
    end

    test "description documents common mistakes (rg is NOT grep)" do
      [rg_schema] = Enum.filter(Tools.schemas(), &(&1.name == "rg"))
      description = rg_schema.description

      assert description =~ "COMMON MISTAKES"
      assert description =~ "rg is NOT grep"
      assert description =~ "`-r`"
      assert description =~ "`--exclude-dir`"
      # Bare numeric flag guidance
      assert description =~ "-C <n>"
      # exclude-dir alternative
      assert description =~ "-g '!dirname'"
    end
  end

  describe "execute/4 - error hint detection" do
    test "bare numeric flag (-9) yields context-line hint", %{tmp_dir: tmp_dir} do
      result = Tools.execute("rg", %{"args" => ["-9", "foo", "."]}, tmp_dir, tmp_dir)

      # The command failed, so a corrective hint should be appended
      assert result =~ "Tip:"
      assert result =~ "-C <n>"
      assert result =~ "--context <n>"
      assert result =~ "-A <n>"
      assert result =~ "-B <n>"
    end

    test "-r flag yields --replace hint", %{tmp_dir: tmp_dir} do
      # Provide a pattern AND a path so rg doesn't try to read from stdin.
      # rg -r foo treats "foo" as the replacement text; without a pattern+path
      # rg would block on stdin. "nonexistent_xyz" is the pattern, "." the path.
      result =
        Tools.execute("rg", %{"args" => ["-r", "foo", "nonexistent_xyz", "."]}, tmp_dir, tmp_dir)

      assert result =~ "Tip:"
      assert result =~ "'--replace'"
    end

    test "--exclude-dir yields -g '!dirname' hint", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "rg",
          %{"args" => ["--exclude-dir", "node_modules", "foo", "."]},
          tmp_dir,
          tmp_dir
        )

      assert result =~ "Tip:"
      assert result =~ "-g '!dirname'"
    end
  end

  describe "execute/4 - normal operation" do
    test "normal search still works without hint text", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.ex"), "defmodule Foo do\n  def bar, do: :ok\nend\n")

      result = Tools.execute("rg", %{"args" => ["defmodule", "."]}, tmp_dir, tmp_dir)

      assert result =~ "Command executed successfully"
      assert result =~ "defmodule Foo"
      refute result =~ "Tip:"
    end

    test "no hint is appended on successful search", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "notes.md"), "remember to refactor\n")

      result = Tools.execute("rg", %{"args" => ["refactor", "."]}, tmp_dir, tmp_dir)

      assert result =~ "Command executed successfully"
      refute result =~ "Tip:"
    end
  end
end
