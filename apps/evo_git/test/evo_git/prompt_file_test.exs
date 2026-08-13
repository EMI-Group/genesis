defmodule EvoGit.PromptFileTest do
  use ExUnit.Case, async: true

  alias EvoGit.PromptFile

  describe "read/1 — plain text" do
    test ".txt file returns trimmed content" do
      path = write_tmp!("prompt.txt", "  Implement the feature.\n\n  ")
      assert {:ok, "Implement the feature."} = PromptFile.read(path)
    end

    test ".md file returns content verbatim" do
      path = write_tmp!("prompt.md", "# Objective\n\nMake it faster")
      assert {:ok, "# Objective\n\nMake it faster"} = PromptFile.read(path)
    end

    test "multiline and unicode content is preserved" do
      path = write_tmp!("prompt.txt", "Line 1\nLine 2 — ünïcödé 🚀\n")
      assert {:ok, "Line 1\nLine 2 — ünïcödé 🚀"} = PromptFile.read(path)
    end

    test "missing file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.txt"
        )

      assert {:error, :enoent} = PromptFile.read(path)
    end
  end

  describe "read/1 — binary guard" do
    test "invalid UTF-8 (binary/PDF/DOCX) content returns {:error, {:not_text, ext}}" do
      path = write_tmp!("prompt.pdf", <<0xFF, 0xFE, 0x00>>)
      assert {:error, {:not_text, ".pdf"}} = PromptFile.read(path)

      path = write_tmp!("prompt.docx", <<0xFF, 0xFE, 0x00>>)
      assert {:error, {:not_text, ".docx"}} = PromptFile.read(path)
    end

    test "invalid UTF-8 without extension returns {:not_text, \"\"}" do
      path = write_tmp!("prompt", <<0xFF, 0xFE, 0x00>>)
      assert {:error, {:not_text, ""}} = PromptFile.read(path)
    end
  end

  describe "describe_error/2" do
    test "enoent" do
      assert PromptFile.describe_error(:enoent, "obj.txt") == "File not found: obj.txt"
    end

    test "other POSIX atoms" do
      assert PromptFile.describe_error(:eacces, "obj.txt") ==
               "Failed to read file: obj.txt (:eacces)"
    end

    test "not_text with extension" do
      msg = PromptFile.describe_error({:not_text, ".pdf"}, "obj.pdf")
      assert msg =~ "File is not plain text (.pdf)"
      assert msg =~ "plain text only"
      assert msg =~ "attach it via the dashboard"
    end

    test "not_text without extension" do
      msg = PromptFile.describe_error({:not_text, ""}, "obj")
      assert msg =~ "File is not plain text (binary/PDF/DOCX)"
      assert msg =~ "convert the file to text first"
    end
  end

  ## Helpers

  defp write_tmp!(name, binary) do
    path =
      Path.join(
        System.tmp_dir!(),
        "prompt_file_test_#{System.unique_integer([:positive])}_#{name}"
      )

    File.write!(path, binary)
    path
  end
end
