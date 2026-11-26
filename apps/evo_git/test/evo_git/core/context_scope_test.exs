defmodule EvoGit.Core.ContextScopeTest do
  @moduledoc """
  Pure unit suite for `EvoGit.Core.ContextScope` — the two-scope (`Shared` /
  `Local`) `CONTEXT.md` divider.

  No file/system I/O, no config reads and no BEAM-global mutation: every case
  drives the pure functions on in-memory binaries, so `async: true`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Core.ContextScope

  @marker "<!-- genesis:local -->"

  describe "marker/0" do
    test "is the literal divider line" do
      assert ContextScope.marker() == "<!-- genesis:local -->"
      assert ContextScope.marker() == @marker
    end
  end

  describe "split/1 and has_local?/1" do
    test "without a divider the whole file is Shared and Local is empty" do
      content = "# Root\nroot body\n"

      assert ContextScope.split(content) == %{shared: content, local: ""}
      refute ContextScope.has_local?(content)
    end

    test "an empty file has no divider" do
      assert ContextScope.split("") == %{shared: "", local: ""}
      refute ContextScope.has_local?("")
    end

    test "a divider as the FIRST line leaves Shared empty" do
      content = @marker <> "\n# Local\nlocal only\n"

      assert ContextScope.split(content) == %{shared: "", local: "# Local\nlocal only\n"}
      assert ContextScope.has_local?(content)
    end

    test "leading and trailing spaces/tabs are tolerated on the divider line" do
      content = "# Root\nshared body\n \t" <> @marker <> "\t  \n# Local\nlocal only\n"

      assert ContextScope.split(content) == %{
               shared: "# Root\nshared body\n",
               local: "# Local\nlocal only\n"
             }

      assert ContextScope.has_local?(content)
    end

    test "a CRLF file keeps its \\r\\n endings in BOTH scopes" do
      content = "# Shared\r\nbody\r\n" <> @marker <> "\r\n# Local\r\nlocal only\r\n"

      assert ContextScope.split(content) == %{
               shared: "# Shared\r\nbody\r\n",
               local: "# Local\r\nlocal only\r\n"
             }
    end

    test "a divider as the FINAL line with no trailing newline" do
      content = "# Shared\nshared body\n" <> @marker

      assert ContextScope.split(content) == %{shared: "# Shared\nshared body\n", local: ""}
      assert ContextScope.has_local?(content)
    end

    test "the FIRST occurrence wins: a second marker line stays ordinary Local text" do
      content = "# Shared\n" <> @marker <> "\nlocal one\n" <> @marker <> "\nlocal two\n"

      assert ContextScope.split(content) == %{
               shared: "# Shared\n",
               local: "local one\n" <> @marker <> "\nlocal two\n"
             }
    end

    # DELIBERATE: there is NO Markdown fence awareness — a divider line written
    # inside a fenced code block still splits the file. A CONTEXT.md that needs
    # to SHOW the divider must alter the literal itself (indenting does not help,
    # because a whitespace-padded divider line still counts).
    test "a marker line inside a fenced code block still splits" do
      content = "```markdown\n" <> @marker <> "\n```\n"

      assert ContextScope.split(content) == %{shared: "```markdown\n", local: "```\n"}
      assert ContextScope.has_local?(content)
    end
  end

  describe "scope_content/2" do
    test "returns each region without the divider line" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"

      assert ContextScope.scope_content(content, :shared) == "# Shared\nshared body\n"
      assert ContextScope.scope_content(content, :local) == "# Local\nlocal body\n"

      assert ContextScope.scope_content(content, :all) ==
               "# Shared\nshared body\n# Local\nlocal body\n"
    end

    test ":all is shared <> local, i.e. the input with ONLY the divider line dropped" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"
      %{shared: shared, local: local} = ContextScope.split(content)

      assert ContextScope.scope_content(content, :all) == shared <> local

      # Byte-exact: the divider line (and its own newline) is the ONLY removal.
      assert ContextScope.scope_content(content, :all) ==
               "# Shared\nshared body\n# Local\nlocal body\n"
    end

    test "a CRLF :all drops ONLY the divider line, keeping every \\r\\n" do
      content = "# Shared\r\nbody\r\n" <> @marker <> "\r\n# Local\r\nlocal only\r\n"

      assert ContextScope.scope_content(content, :all) ==
               "# Shared\r\nbody\r\n# Local\r\nlocal only\r\n"
    end

    test "without a divider :shared and :all are the content verbatim and :local is empty" do
      content = "# Root\nroot body\n"

      assert ContextScope.scope_content(content, :shared) == content
      assert ContextScope.scope_content(content, :all) == content
      assert ContextScope.scope_content(content, :local) == ""
    end

    test "an empty Shared region stays empty for :shared" do
      content = @marker <> "\nlocal only\n"

      assert ContextScope.scope_content(content, :shared) == ""
      assert ContextScope.scope_content(content, :local) == "local only\n"
      assert ContextScope.scope_content(content, :all) == "local only\n"
    end
  end

  describe "splice/3" do
    test "editing :shared preserves the divider line and the Local scope byte-for-byte" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"

      assert ContextScope.splice(content, :shared, "# New\nnew shared\n") ==
               "# New\nnew shared\n" <> @marker <> "\n# Local\nlocal body\n"
    end

    test "editing :local preserves the Shared scope and the divider line byte-for-byte" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"

      assert ContextScope.splice(content, :local, "# New\nnew local\n") ==
               "# Shared\nshared body\n" <> @marker <> "\n# New\nnew local\n"
    end

    test "a CRLF divider line is re-emitted with its exact ending" do
      content = "# Shared\r\nbody\r\n" <> @marker <> "\r\n# Local\r\nlocal only\r\n"

      assert ContextScope.splice(content, :shared, "NEW\r\n") ==
               "NEW\r\n" <> @marker <> "\r\n# Local\r\nlocal only\r\n"
    end

    test "a final divider line with no ending is re-emitted without one" do
      content = "# Shared\nbody\n" <> @marker

      assert ContextScope.splice(content, :shared, "NEW\n") == "NEW\n" <> @marker
    end

    test ":all replaces the whole body (nothing to preserve)" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"

      assert ContextScope.splice(content, :all, "REPLACED") == "REPLACED"
    end

    test "without a divider :shared and :all replace the file and :local is a no-op" do
      content = "# Root\nroot body\n"

      assert ContextScope.splice(content, :shared, "NEW") == "NEW"
      assert ContextScope.splice(content, :all, "NEW") == "NEW"

      # There is no Local region to replace, so the content is returned UNCHANGED
      # (callers must guard with `has_local?/1` first).
      assert ContextScope.splice(content, :local, "NEW") == content
    end

    test "splicing a split's own region back is the identity" do
      content = "# Shared\nshared body\n" <> @marker <> "\n# Local\nlocal body\n"
      %{shared: shared, local: local} = ContextScope.split(content)

      assert ContextScope.splice(content, :shared, shared) == content
      assert ContextScope.splice(content, :local, local) == content
    end
  end

  describe "parse_scope/1" do
    test "accepts the three string forms" do
      assert ContextScope.parse_scope("shared") == {:ok, :shared}
      assert ContextScope.parse_scope("local") == {:ok, :local}
      assert ContextScope.parse_scope("all") == {:ok, :all}
    end

    test "accepts the matching atoms" do
      assert ContextScope.parse_scope(:shared) == {:ok, :shared}
      assert ContextScope.parse_scope(:local) == {:ok, :local}
      assert ContextScope.parse_scope(:all) == {:ok, :all}
    end

    test "rejects anything else without raising, naming all three values" do
      for bad <- ["Shared", "both", "", nil, 42, :everything, ["shared"]] do
        assert {:error, message} = ContextScope.parse_scope(bad)
        assert is_binary(message)
        assert message =~ ~s("shared")
        assert message =~ ~s("local")
        assert message =~ ~s("all")
      end
    end
  end
end
