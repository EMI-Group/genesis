defmodule EvoGit.Agent.Tools.SearchContextTest do
  @moduledoc """
  `async: true` — `EvoGit.Agent.Tools.execute/4` "search_context" over a
  per-test fixture directory under `System.tmp_dir!()`; no BEAM-global state.

  The fixture is DELIBERATELY not ExUnit's `:tmp_dir` (see `setup/0`): that
  path is cwd-relative and deterministic (`tmp/<Module>/<test>-<md5>`), and
  ExUnit creates it with `File.rm_rf!` followed by `File.mkdir_p!`. A
  concurrent `mix test` run of this same file in the SAME checkout therefore
  recreates the very directory this tool's `rg` child process chdirs into —
  EMPTY — so a relative `path` argument (`"lib"`) fails with ripgrep's
  `lib: No such file or directory` even though the directory exists again.
  A per-run unique directory cannot be recreated out from under the tool.
  """

  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools

  setup do
    # OS pid + wall-clock ms on top of the per-BEAM counter: the counter alone
    # restarts on a fresh node and would collide with a concurrent run's
    # directory (same stamp shape as `EvoGit.TaskRegistryCase` /
    # `EvoGit.StoreTemplate`). The `tmp_dir` context key keeps every test body
    # unchanged.
    stamp =
      "#{System.unique_integer([:positive])}_#{:os.getpid()}_#{System.system_time(:millisecond)}"

    tmp_dir = Path.join(System.tmp_dir!(), "evogit_search_context_#{stamp}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "schemas/0 - search_context" do
    test "search_context schema is included in tool schemas" do
      schemas = Tools.schemas()
      names = Enum.map(schemas, & &1.name)
      assert "search_context" in names
    end
  end

  describe "execute/4 - search_context" do
    test "finds pattern in CONTEXT.md files", %{tmp_dir: tmp_dir} do
      # Create directories with CONTEXT.md files
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "src"))

      File.write!(
        Path.join(tmp_dir, "lib/CONTEXT.md"),
        "This is the library module.\nIt handles data processing."
      )

      File.write!(
        Path.join(tmp_dir, "src/CONTEXT.md"),
        "This is the source module.\nIt handles UI rendering."
      )

      result = Tools.execute("search_context", %{"pattern" => "data processing"}, tmp_dir)

      assert result =~ "Command executed successfully"
      assert result =~ "data processing"
    end

    test "searches only CONTEXT.md files, not other files", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "Module documentation")
      File.write!(Path.join(tmp_dir, "lib/code.ex"), "unique_pattern_xyz in code")

      result = Tools.execute("search_context", %{"pattern" => "unique_pattern_xyz"}, tmp_dir)

      assert result =~ "No matches found"
    end

    test "searches within specified path", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "library context with special_keyword")
      File.write!(Path.join(tmp_dir, "src/CONTEXT.md"), "source context without the keyword")

      result =
        Tools.execute(
          "search_context",
          %{"pattern" => "special_keyword", "path" => "lib"},
          tmp_dir
        )

      assert result =~ "Command executed successfully"
      assert result =~ "special_keyword"
    end

    test "returns no matches when pattern not found", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/CONTEXT.md"), "some content")

      result = Tools.execute("search_context", %{"pattern" => "nonexistent_pattern_xyz"}, tmp_dir)

      assert result =~ "No matches found"
    end

    test "returns error when pattern is missing" do
      result = Tools.execute("search_context", %{}, "/tmp")
      assert result =~ "Missing required argument"
    end
  end
end
