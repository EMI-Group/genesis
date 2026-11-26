defmodule EvoGit.Agent.Tools.ContextScopeTest do
  @moduledoc """
  Pins the TWO-SCOPE (`Shared` / `Local`) behaviour of the CONTEXT.md tools,
  `EvoGit.Agent.Tools.Context.execute_read/3` / `execute_edit/4` /
  `execute_write/4` over the divider primitive `EvoGit.Core.ContextScope`.

  The divider is the literal `<!-- genesis:local -->` on a line of its own:
  text BEFORE it is Shared (the node and all of its descendants), text AFTER it
  is Local (only agents assigned to that exact directory), and the divider line
  itself belongs to neither scope.

  What this module OWNS (nothing here duplicates the sibling suites):

    * `read_context` scope selection — `all` (default) is the RAW file with the
      divider line INCLUDED, `shared` / `local` return just their region, a
      divider-less file makes `local` an error with the remedy, an invalid value
      names all three accepted scopes, and reading stays UNRESTRICTED (no node
      path is consulted);
    * `edit_context` scope selection — the DEFAULT is `shared`, matching /
      occurrence counting / `replace_all` all run inside the selected region
      only, and `ContextScope.splice/3` puts the result back so the divider line
      and the untouched region survive byte-for-byte;
    * `write_context` round-trips a full file that carries the divider verbatim.

  Commit/amend behaviour is NOT covered here: `context_amend_test.exs` owns that
  contract, so every call below passes `commit: false` and therefore needs no
  git repository (and touches no global config).

  `async: true` — every test works in its own `:tmp_dir` with process-local
  state only: no BEAM-global env var, no app-global singleton, no shared ETS
  table, and no git subprocess.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.Context

  @moduletag :tmp_dir

  @marker "<!-- genesis:local -->"

  # One canonical two-scope fixture, split at the divider line:
  # the divider sits on its own line and its line ending separates the scopes.
  @shared_part "# Node\n\nShared line.\n\n"
  @local_part "\nLocal line only.\n"
  @raw @shared_part <> @marker <> "\n" <> @local_part

  # A fixture with the SAME text in both regions, for the "which occurrence
  # does the default scope touch?" case.
  @same_text_raw "# Top\n\nMARKER\n\n" <> @marker <> "\n\nMARKER\n"

  # Shared holds ONE "TAG"; Local holds TWO.
  @tag_raw "# Top\n\nTAG\n\n" <> @marker <> "\n\nTAG one\nTAG two\n"

  # No divider at all: the whole file is Shared and the Local scope is empty.
  @divider_less "# Alpha\n\nBody text.\n"

  # ---------------------------------------------------------------------------
  # read_context — scope selection
  # ---------------------------------------------------------------------------

  describe "read_context scope selection" do
    test "an absent scope and scope: \"all\" both return the RAW file, divider line included", %{
      tmp_dir: repo
    } do
      write_ctx!(repo, "lib", @raw)

      assert Context.execute_read(%{"dir_path" => "lib"}, repo, nil) == @raw
      assert Context.execute_read(%{"dir_path" => "lib", "scope" => "all"}, repo, nil) == @raw
      # The divider line really is part of that whole-file read.
      assert Context.execute_read(%{"dir_path" => "lib"}, repo, nil) =~ @marker
    end

    test "scope: \"shared\" returns only the text before the divider line", %{tmp_dir: repo} do
      write_ctx!(repo, "lib", @raw)

      assert Context.execute_read(%{"dir_path" => "lib", "scope" => "shared"}, repo, nil) ==
               @shared_part
    end

    test "scope: \"local\" returns only the text after the divider line", %{tmp_dir: repo} do
      write_ctx!(repo, "lib", @raw)

      assert Context.execute_read(%{"dir_path" => "lib", "scope" => "local"}, repo, nil) ==
               @local_part
    end

    test "a divider-less file is entirely Shared, so scope: \"local\" errors and touches nothing",
         %{tmp_dir: repo} do
      path = write_ctx!(repo, "lib", @divider_less)

      assert Context.execute_read(%{"dir_path" => "lib", "scope" => "shared"}, repo, nil) ==
               @divider_less

      error = Context.execute_read(%{"dir_path" => "lib", "scope" => "local"}, repo, nil)
      assert String.starts_with?(error, "Error: ")
      assert error =~ "no Local section"
      # The remedy names the literal divider so the model can add it.
      assert error =~ @marker

      assert File.read!(path) == @divider_less
    end

    test "reading is UNRESTRICTED: another directory's Local text reads fine", %{tmp_dir: repo} do
      # `execute_read/3` takes no node path, so a node's Local text is readable
      # even when the caller is assigned somewhere else entirely.
      write_ctx!(repo, "other", @raw)

      assert Context.execute_read(%{"dir_path" => "other", "scope" => "local"}, repo, nil) ==
               @local_part
    end

    test "an invalid scope value is rejected on BOTH tools, naming the three accepted scopes", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @raw)

      read_error = Context.execute_read(%{"dir_path" => "lib", "scope" => "both"}, repo, nil)
      assert String.starts_with?(read_error, "Error: ")

      edit_error =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Shared line.",
            "new_string" => "changed",
            "scope" => "both",
            "commit" => false
          },
          repo,
          nil
        )

      assert String.starts_with?(edit_error, "Error: ")

      for error <- [read_error, edit_error] do
        assert error =~ "shared"
        assert error =~ "local"
        assert error =~ "all"
      end

      assert File.read!(path) == @raw
    end
  end

  # ---------------------------------------------------------------------------
  # edit_context — scope selection
  # ---------------------------------------------------------------------------

  describe "edit_context scope selection" do
    test "the default scope is Shared: an identical Local occurrence stays byte-identical", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @same_text_raw)

      # "MARKER" appears once per region, so a whole-file match would be
      # ambiguous; region-scoped counting makes the default edit unambiguous.
      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "MARKER",
            "new_string" => "SHARED-ONLY",
            "commit" => false
          },
          repo,
          nil
        )

      assert result =~ "updated successfully"
      assert File.read!(path) == "# Top\n\nSHARED-ONLY\n\n" <> @marker <> "\n\nMARKER\n"
    end

    test "scope: \"local\" edits the Local region and preserves Shared + divider byte-for-byte",
         %{
           tmp_dir: repo
         } do
      path = write_ctx!(repo, "lib", @raw)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Local line only.",
            "new_string" => "Local line edited.",
            "scope" => "local",
            "commit" => false
          },
          repo,
          nil
        )

      assert result == "The file lib/CONTEXT.md has been updated successfully."
      assert File.read!(path) == @shared_part <> @marker <> "\n\nLocal line edited.\n"
    end

    test "scope: \"shared\" edits the Shared region and preserves Local + divider byte-for-byte",
         %{
           tmp_dir: repo
         } do
      path = write_ctx!(repo, "lib", @raw)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Shared line.",
            "new_string" => "Shared line edited.",
            "scope" => "shared",
            "commit" => false
          },
          repo,
          nil
        )

      assert result =~ "updated successfully"

      assert File.read!(path) ==
               "# Node\n\nShared line edited.\n\n" <> @marker <> "\n" <> @local_part
    end

    test "scope: \"all\" edits the RAW file, so the divider line and the Local text survive", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @raw)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Shared line.",
            "new_string" => "Shared line edited.",
            "scope" => "all",
            "commit" => false
          },
          repo,
          nil
        )

      refute result =~ "Error:"

      # `all` must match against the raw file (divider line INCLUDED), not
      # against `shared <> local`: the divider is not content that an ordinary
      # edit may drop.
      assert File.read!(path) ==
               "# Node\n\nShared line edited.\n\n" <> @marker <> "\n" <> @local_part,
             "scope: \"all\" must edit the RAW file: the divider line and the Local text survive"
    end

    test "replace_all applies WITHIN the selected region only", %{tmp_dir: repo} do
      path = write_ctx!(repo, "lib", @tag_raw)

      # Two Local occurrences are both replaced while the Shared one is untouched.
      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "TAG",
            "new_string" => "NEW",
            "scope" => "local",
            "replace_all" => true,
            "commit" => false
          },
          repo,
          nil
        )

      assert result =~ "All occurrences were successfully replaced"
      assert File.read!(path) == "# Top\n\nTAG\n\n" <> @marker <> "\n\nNEW one\nNEW two\n"
    end

    test "occurrence counting is region-scoped: one Shared match wins over two Local ones", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @tag_raw)

      # Three occurrences exist in the FILE, but only ONE in the selected
      # region, so a non-`replace_all` edit must succeed instead of reporting
      # an ambiguity it never had inside the scope.
      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "TAG",
            "new_string" => "NEW",
            "scope" => "shared",
            "commit" => false
          },
          repo,
          nil
        )

      assert result =~ "updated successfully"
      refute result =~ "matches of old_string"
      assert File.read!(path) == "# Top\n\nNEW\n\n" <> @marker <> "\n\nTAG one\nTAG two\n"
    end

    test "an old_string present only in the OTHER region is not found and changes nothing", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @raw)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Local line only.",
            "new_string" => "changed",
            "scope" => "shared",
            "commit" => false
          },
          repo,
          nil
        )

      assert result == "Error: old_string not found in file lib/CONTEXT.md"
      assert File.read!(path) == @raw
    end

    test "scope: \"local\" on a divider-less file errors and leaves the file unchanged", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @divider_less)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Body text.",
            "new_string" => "changed",
            "scope" => "local",
            "commit" => false
          },
          repo,
          nil
        )

      assert String.starts_with?(result, "Error: ")
      assert result =~ "no Local section"
      assert result =~ @marker
      assert File.read!(path) == @divider_less
    end

    test "an out-of-node target is refused BEFORE any read, existence check or write", %{
      tmp_dir: repo
    } do
      path = write_ctx!(repo, "lib", @raw)

      result =
        Context.execute_edit(
          %{
            "dir_path" => "lib",
            "old_string" => "Shared line.",
            "new_string" => "changed",
            "commit" => false
          },
          repo,
          nil,
          "./other"
        )

      assert String.starts_with?(result, "Error: ")
      assert result =~ "Cannot modify CONTEXT.md at 'lib'"
      assert result =~ "outside your scope"
      assert File.read!(path) == @raw
    end

    test "the node scope check runs before the existence check and creates nothing", %{
      tmp_dir: repo
    } do
      result =
        Context.execute_edit(
          %{
            "dir_path" => "elsewhere",
            "old_string" => "anything",
            "new_string" => "changed",
            "commit" => false
          },
          repo,
          nil,
          "./other"
        )

      # The out-of-node refusal wins over "directory does not exist", so the
      # agent learns the real remedy instead of guessing at paths.
      assert result =~ "outside your scope"
      refute result =~ "does not exist"
      refute File.exists?(Path.join(repo, "elsewhere"))
    end
  end

  # ---------------------------------------------------------------------------
  # write_context — the divider rides along verbatim
  # ---------------------------------------------------------------------------

  describe "write_context" do
    test "round-trips a full file whose content includes the divider verbatim", %{tmp_dir: repo} do
      result =
        Context.execute_write(
          %{"dir_path" => "lib", "content" => @raw, "commit" => false},
          repo,
          nil
        )

      assert result == "Successfully updated CONTEXT.md for directory 'lib'"
      assert File.read!(Path.join([repo, "lib", "CONTEXT.md"])) == @raw
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Writes `<repo>/<dir>/CONTEXT.md` and returns the absolute path. `commit:
  # false` everywhere in this module means no git repository is ever needed.
  defp write_ctx!(repo, dir, content) do
    File.mkdir_p!(Path.join(repo, dir))
    path = Path.join([repo, dir, "CONTEXT.md"])
    File.write!(path, content)
    path
  end
end
