defmodule EvoGit.Agent.Tools.FileEditTest do
  @moduledoc """
  `async: true` — schema assertions plus real file I/O confined to each test's
  `@moduletag :tmp_dir` (no BEAM-global state).

  The load-bearing regressions here are:

    * the MODEL-FACING schema name is `edit` (the internal dispatch key stays
      `edit_file` — see `EvoGit.Agent.ToolNames`), and
    * `new_string` lands in the file BYTE-EXACTLY — trailing spaces, tabs and a
      trailing newline are never trimmed away.
  """

  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.FileEdit
  alias EvoGit.Agent.Tools.Shared

  @moduletag :tmp_dir

  describe "schema/0" do
    test "uses the model-facing schema name `edit`" do
      assert FileEdit.schema().name == "edit"
    end

    test "description states the exact-match/uniqueness contract and the real success strings" do
      description = FileEdit.schema().description

      # (a) what the tool does
      assert description =~ "exact string replacement in an existing file"
      # (b) byte-exact + UNIQUE, with the two remedies
      assert description =~ "byte-exactly"
      assert description =~ "UNIQUE"
      assert description =~ "more surrounding context"
      assert description =~ "replace_all: true"
      # (d) the read tool's NUMBER<TAB> line-number prefix is called out
      assert description =~ "NUMBER<TAB>"
      # (c) the success strings, quoted verbatim from
      # `Shared.perform_string_replace/5`
      assert description =~ "The file <file_path> has been updated successfully."
      assert description =~ "All occurrences were successfully replaced."
    end

    test "keeps the parameter contract unchanged" do
      parameter_schema = FileEdit.schema().parameter_schema
      properties = parameter_schema["properties"]

      # The implementation reads exactly these names.
      assert Enum.sort(Map.keys(properties)) ==
               ["file_path", "new_string", "old_string", "replace_all"]

      assert properties["replace_all"]["default"] == false
      assert parameter_schema["required"] == ["file_path", "old_string", "new_string"]

      for {_name, property} <- properties do
        assert is_binary(property["description"]) and property["description"] != ""
      end
    end
  end

  describe "apply_string_edit/4 — verbatim replacement bytes" do
    test "does not trim trailing spaces, tabs or newlines off new_string" do
      assert Shared.apply_string_edit("x = 1\n", "x = 1", "y = 2   ", false) == "y = 2   \n"
      assert Shared.apply_string_edit("x = 1\n", "x = 1", "y = 2\t", false) == "y = 2\t\n"
      assert Shared.apply_string_edit("x = 1\n", "x = 1", "y = 2\n\n", false) == "y = 2\n\n\n"
      # Trailing whitespace-only lines survive too.
      assert Shared.apply_string_edit("a\n", "a", "b  \n\t \n", false) == "b  \n\t \n\n"
    end

    test "replace_all also inserts the verbatim replacement for every occurrence" do
      assert Shared.apply_string_edit("a\na\n", "a", "b  ", true) == "b  \nb  \n"
    end

    test "the replacement value never participates in matching (no cascading replace)" do
      # `new_string` contains `old_string`: a naive re-scan would keep replacing.
      # `String.replace/4` never re-processes a replacement.
      assert Shared.apply_string_edit("a a\n", "a", "aa", true) == "aa aa\n"
    end

    test "a non-final occurrence keeps the following bytes untouched" do
      assert Shared.apply_string_edit("one one\n", "one", "1  ", false) == "1   one\n"
    end
  end

  describe "execute/4 — whitespace fidelity" do
    test "inserts new_string byte-exactly (trailing spaces, a tab line, a trailing newline)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "code.ex")
      File.write!(path, "def a do\n  :ok\nend\n")

      # Trailing spaces after `:ok`, then a tab-only line, then a newline that
      # is the caller's own trailing newline.
      new_string = "  :ok   \n\t\n"

      assert edit(tmp_dir, "code.ex", "  :ok\n", new_string) ==
               "The file code.ex has been updated successfully."

      assert File.read!(path) == "def a do\n  :ok   \n\t\nend\n"
    end

    test "a replacement ending in a newline does not lose it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "list.txt")
      File.write!(path, "- a\n")

      assert edit(tmp_dir, "list.txt", "- a", "- a\n- b") ==
               "The file list.txt has been updated successfully."

      assert File.read!(path) == "- a\n- b\n"
    end

    test "a replacement with no trailing newline stays exactly as sent", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trail.txt")
      File.write!(path, "keep\ndrop\n")

      assert edit(tmp_dir, "trail.txt", "\ndrop\n", "\n") ==
               "The file trail.txt has been updated successfully."

      assert File.read!(path) == "keep\n"
    end

    test "replace_all inserts the verbatim replacement at every occurrence",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rows.txt")
      File.write!(path, "row\nrow\n")

      assert edit(tmp_dir, "rows.txt", "row", "row  \t", %{"replace_all" => true}) ==
               "The file rows.txt has been updated. All occurrences were successfully replaced."

      assert File.read!(path) == "row  \t\nrow  \t\n"
    end
  end

  describe "execute/4 — matching contract" do
    test "requires a UNIQUE old_string unless replace_all is true", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dup.txt")
      File.write!(path, "x\nx\n")

      assert edit(tmp_dir, "dup.txt", "x", "y") ==
               "Error: Found 2 matches of old_string in file. Set replace_all=true or provide more context."

      # Nothing was written.
      assert File.read!(path) == "x\nx\n"
    end

    test "replace_all replaces every occurrence", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dup.txt")
      File.write!(path, "x\nx\n")

      assert edit(tmp_dir, "dup.txt", "x", "y", %{"replace_all" => true}) ==
               "The file dup.txt has been updated. All occurrences were successfully replaced."

      assert File.read!(path) == "y\ny\n"
    end

    test "matches BYTE-exactly — a trailing-newline difference is not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "exact.txt")
      File.write!(path, "alpha\nbeta\n")

      # One extra newline in `old_string` is enough to miss.
      assert edit(tmp_dir, "exact.txt", "alpha\nbeta\n\n", "gamma") ==
               "Error: old_string not found in file exact.txt"

      assert File.read!(path) == "alpha\nbeta\n"
    end

    test "reports a not-found old_string without touching the file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "plain.txt")
      File.write!(path, "hello\n")

      assert edit(tmp_dir, "plain.txt", "nope", "x") ==
               "Error: old_string not found in file plain.txt"

      assert File.read!(path) == "hello\n"
    end

    test "every failure starts with the literal `Error: ` (read failure path)",
         %{tmp_dir: tmp_dir} do
      # A directory cannot be read as a file → the `Failure.error/1`-routed
      # read-failure branch.
      File.mkdir_p!(Path.join(tmp_dir, "adir"))

      result = edit(tmp_dir, "adir", "anything", "x")

      assert String.starts_with?(result, "Error: ")
      assert result =~ "failed to read adir"
    end
  end

  describe "model-facing name dispatch" do
    test "`edit` (the schema name) resolves to the edit_file dispatch key", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "spine.txt")
      File.write!(path, "hello\n")

      args = %{"file_path" => "spine.txt", "old_string" => "hello", "new_string" => "bye  "}

      assert EvoGit.Agent.Tools.execute("edit", args, tmp_dir) ==
               "The file spine.txt has been updated successfully."

      assert File.read!(path) == "bye  \n"
    end
  end

  # Calls the tool the way the dispatcher does: `(args, repo_path, repo_root,
  # node_path)` with `node_path` nil (unrestricted scope).
  defp edit(repo_path, file_path, old_string, new_string, extra \\ %{}) do
    FileEdit.execute(
      Map.merge(
        %{"file_path" => file_path, "old_string" => old_string, "new_string" => new_string},
        extra
      ),
      repo_path,
      repo_path,
      nil
    )
  end
end
