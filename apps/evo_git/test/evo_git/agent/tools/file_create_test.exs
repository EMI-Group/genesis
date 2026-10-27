defmodule EvoGit.Agent.Tools.FileCreateTest do
  @moduledoc """
  `async: true` — each test operates on its own per-test tmp dir (a unique
  `System.tmp_dir!()` path); no BEAM-global state or shared ETS.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.FileCreate

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "file_create_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "schema/0" do
    test "returns a valid tool schema" do
      schema = FileCreate.schema()

      assert schema.name == "create_files"
      assert is_binary(schema.description)
      assert schema.description =~ "empty files"
      assert schema.description =~ "Only the listed paths are staged and committed"
    end
  end

  describe "execute/3 - basic file creation" do
    test "creates a single empty file", %{tmp_dir: tmp_dir} do
      result = FileCreate.execute(%{"paths" => ["lib/a.ex"], "commit" => false}, tmp_dir, nil)

      assert result == "Successfully created 1 file: lib/a.ex"
      assert File.read!(Path.join(tmp_dir, "lib/a.ex")) == ""
    end

    test "lists a failing path in the Errors block", %{tmp_dir: tmp_dir} do
      result =
        FileCreate.execute(
          %{"paths" => ["missing/nested/a.ex"], "parents" => false, "commit" => false},
          tmp_dir,
          nil
        )

      assert result =~ "Errors:"
      assert result =~ "  - missing/nested/a.ex: "
    end
  end

  describe "format_failure/1 - total reason rendering" do
    test "renders a binary reason byte-identically in the listing shape" do
      assert FileCreate.format_failure({:error, "lib/a.ex", "no such file or directory"}) ==
               "  - lib/a.ex: no such file or directory"
    end

    test "renders a map reason instead of raising" do
      assert FileCreate.format_failure({:error, "lib/a.ex", %{code: :eacces}}) ==
               "  - lib/a.ex: %{code: :eacces}"
    end

    test "renders a tuple reason instead of raising" do
      assert FileCreate.format_failure({:error, "lib/a.ex", {:enoent, "lib/a.ex"}}) ==
               "  - lib/a.ex: {:enoent, \"lib/a.ex\"}"
    end

    test "renders an atom reason instead of raising" do
      assert FileCreate.format_failure({:error, "lib/a.ex", :enoent}) ==
               "  - lib/a.ex: :enoent"
    end

    test "renders an exception struct via Exception.message/1 instead of raising" do
      assert FileCreate.format_failure({:error, "lib/a.ex", %RuntimeError{message: "boom"}}) ==
               "  - lib/a.ex: boom"
    end
  end

  describe "format_commit_failure/1 - total reason rendering" do
    test "renders a binary reason byte-identically as the commit notice" do
      assert FileCreate.format_commit_failure("disk full") == "\n\nFailed to commit: disk full"
    end

    test "renders a map reason instead of raising" do
      assert FileCreate.format_commit_failure(%{code: :eacces}) ==
               "\n\nFailed to commit: %{code: :eacces}"
    end

    test "renders a tuple reason instead of raising" do
      assert FileCreate.format_commit_failure({:error, :boom}) ==
               "\n\nFailed to commit: {:error, :boom}"
    end

    test "renders an atom reason instead of raising" do
      assert FileCreate.format_commit_failure(:enoent) == "\n\nFailed to commit: :enoent"
    end

    test "renders an exception struct via Exception.message/1 instead of raising" do
      assert FileCreate.format_commit_failure(%RuntimeError{message: "boom"}) ==
               "\n\nFailed to commit: boom"
    end
  end
end
