defmodule EvoGit.Agent.Tools.FileEditTest do
  @moduledoc """
  Regression tests for the same-path parallel file-mutation race ("lost update").

  `EvoGit.Agent.ToolDispatch.batch_execute_tools/4` runs every standard tool call
  of ONE assistant message CONCURRENTLY via `Task.async_stream` — each call gets
  its own process. File mutators used to do a non-atomic read-modify-write, so
  two parallel calls on the SAME path both read the original bytes and the later
  write silently discarded the earlier edit (e.g. 16 concurrent `edit_file` calls
  on one file dropped all but 2 edits, while EVERY call still reported success).

  The fix wraps the whole read-modify-write in `EvoGit.Agent.Tools.Shared.with_file_lock/2`
  (`:global.trans` keyed by the canonical absolute path) from `Shared.perform_string_replace/5`
  and `FileWrite.perform_write/3`. These tests lock that serialization in — they
  fail against the pre-fix code even though every call returns a success string.

  `async: true` — each test builds its own unique `System.tmp_dir!()` directory
  and drives only process-local state plus per-path file locks, so no BEAM-global
  state, shared ETS, or app-env key is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.FileEdit
  alias EvoGit.Agent.Tools.FileWrite

  @concurrent_edits 16
  # Bounded generous timeout: the calls serialize on the file lock, so an
  # under-provisioned timeout would look like a race failure.
  @batch_timeout 30_000

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "file_edit_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  test "N concurrent edit_file calls on the SAME file all land (no lost update)", %{
    tmp_dir: tmp_dir
  } do
    # Distinct, non-overlapping tokens: each edit targets text no other edit
    # touches, so every edit is individually valid and the ONLY thing that can
    # make an edit vanish is a lost update.
    tokens =
      Enum.map(0..(@concurrent_edits - 1), fn i ->
        "TOKEN_#{i}_ORIGINAL"
      end)

    File.write!(Path.join(tmp_dir, "race.txt"), Enum.join(tokens, "\n") <> "\n")

    # WHY this is a genuine race-catcher: without serialization each of the 16
    # processes reads the ORIGINAL bytes, applies its own replacement, and writes
    # the whole file back. Every writer but the last therefore discards its
    # predecessor's edit — the final file holds a single `TOKEN_i_EDITED` (the
    # last writer's) and 15 stale `TOKEN_i_ORIGINAL` lines, even though all 16
    # calls returned "has been updated successfully". With the file lock each
    # read-modify-write runs to completion before the next starts, so all 16
    # markers are present.
    results =
      0..(@concurrent_edits - 1)
      |> Task.async_stream(
        fn i ->
          FileEdit.execute(
            %{
              "file_path" => "./race.txt",
              "old_string" => "TOKEN_#{i}_ORIGINAL",
              "new_string" => "TOKEN_#{i}_EDITED"
            },
            tmp_dir,
            tmp_dir,
            nil
          )
        end,
        max_concurrency: @concurrent_edits,
        timeout: @batch_timeout,
        ordered: false
      )
      |> Enum.to_list()

    # (a) every call reports success — this was ALREADY true pre-fix, which is
    # exactly why the silent data loss went unnoticed.
    assert Enum.all?(results, fn
             {:ok, msg} -> msg == "The file ./race.txt has been updated successfully."
             _other -> false
           end),
           "every concurrent edit_file must report success, got: #{inspect(results)}"

    content = File.read!(Path.join(tmp_dir, "race.txt"))

    # (b) all edits survived, none of the originals remain.
    for i <- 0..(@concurrent_edits - 1) do
      assert content =~ "TOKEN_#{i}_EDITED",
             "edit #{i} was lost — a parallel write overwrote it (lost update)"

      refute content =~ "TOKEN_#{i}_ORIGINAL", "original token #{i} should have been replaced"
    end
  end

  test "write_file + edit_file on the SAME path in one concurrent batch never tears", %{
    tmp_dir: tmp_dir
  } do
    initial = "ANCHOR\n"
    # B's content deliberately still contains the anchor, so A can succeed whether
    # it runs before or after B.
    write_content = "ANCHOR\nSECOND_LINE\n"
    path = Path.join(tmp_dir, "interleave.txt")

    apply_edit = fn content -> String.replace(content, "ANCHOR", "ANCHOR_EDITED") end
    apply_write = fn _content -> write_content end

    # The two valid SERIAL results, computed here by applying both operations in
    # each order to the initial content.
    expected_a_then_b = apply_write.(apply_edit.(initial))
    expected_b_then_a = apply_edit.(apply_write.(initial))
    valid_results = [expected_a_then_b, expected_b_then_a]

    # The outcome is race-order-dependent (whichever call wins the lock), which is
    # fine — the assertion is order-INDEPENDENT: the final bytes must match one of
    # the two serializations. Any interleaved/torn/stale-read result (e.g. A's
    # stale write landing last and reverting B's write) matches neither. A few
    # rounds make overlap — and therefore race detection — more likely.
    for round <- 1..10 do
      File.write!(path, initial)

      results =
        [:edit, :write]
        |> Task.async_stream(
          fn
            :edit ->
              FileEdit.execute(
                %{
                  "file_path" => "./interleave.txt",
                  "old_string" => "ANCHOR",
                  "new_string" => "ANCHOR_EDITED"
                },
                tmp_dir,
                tmp_dir,
                nil
              )

            :write ->
              FileWrite.execute(
                %{"file_path" => "./interleave.txt", "content" => write_content},
                tmp_dir,
                tmp_dir,
                nil
              )
          end,
          max_concurrency: 2,
          timeout: @batch_timeout,
          ordered: false
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "round #{round}: both operations must succeed, got: #{inspect(results)}"

      content = File.read!(path)

      assert content in valid_results,
             "round #{round}: #{inspect(content)} matches neither serial order — " <>
               "torn/stale read-modify-write (expected one of #{inspect(valid_results)})"

      # Op B's write must NEVER be lost: pre-fix, A's stale write can land last and
      # revert the file to "ANCHOR_EDITED\n", dropping SECOND_LINE entirely.
      assert content =~ "SECOND_LINE",
             "round #{round}: write_file's content was silently overwritten by the stale edit"
    end
  end
end
