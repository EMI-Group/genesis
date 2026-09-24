defmodule EvoGit.Agent.ToolDispatchSerialBatchTest do
  @moduledoc """
  Regression coverage for SEQUENTIAL execution of file-mutating tool calls
  inside one LLM tool-call batch.

  `EvoGit.Agent.ToolDispatch.batch_execute_tools/4` partitions a standard batch
  on `EvoGit.Agent.Tools.serial_tool?/1` and runs the file-mutating subset one
  call at a time, in the parent agent process, BEFORE the remaining calls run
  concurrently. Every file-mutating tool performs a non-atomic read-modify-write
  (read the original bytes, transform, write the whole file back), so two such
  calls targeting the SAME file that overlap would each read the ORIGINAL bytes
  and the last write would win — silently discarding every other edit while
  still reporting success.

  The guarantee lives in the DISPATCHER, not in the individual tools, so these
  tests drive the dispatcher directly (`batch_execute_tools/4`) and assert the
  resulting file contents + returned results. No concurrency primitive is
  involved anywhere in the fix or in these tests.

  Serialized (`async: false`) on purpose — like the sibling
  `tool_dispatch_test.exs`, the dispatcher registers agent state in the
  app-global `:evogit_agent_state` ETS table and acquires slots from the global
  `EvoGit.AgentScheduler`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch

  # 16 same-file edits in ONE batch — comfortably above the point where a
  # concurrent read-modify-write batch loses all but one edit, and small enough
  # to keep the assertion list readable.
  @batch_size 16

  @tool_timeout 1_800_000

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "tool_dispatch_serial_batch_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo_root)

    agent_id = 9_980_000 + :erlang.unique_integer([:positive])

    agent_state = %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: repo_root},
      llm_model: "test:model",
      max_retries: 1,
      max_depth: 1
    }

    :ok = EvoGit.AgentScheduler.Store.put_agent_state(agent_id, agent_state)

    Process.put(:evogit_agent_id, agent_id)
    Process.put(:repo_path, repo_root)
    Process.put(:genesis_repo_root, repo_root)

    on_exit(fn ->
      EvoGit.AgentScheduler.Store.delete_agent_state(agent_id)
      File.rm_rf!(repo_root)
    end)

    %{repo_root: repo_root}
  end

  describe "batch_execute_tools/4 same-file serialization" do
    test "every same-file edit_file call in one batch survives", %{repo_root: repo_root} do
      file = Path.join(repo_root, "notes.txt")

      # 16 distinct, mutually non-overlapping markers (zero-padded so no marker
      # is a substring of another, keeping each `old_string` unique).
      initial = Enum.map_join(0..(@batch_size - 1), "\n", &slot_marker/1) <> "\n"
      File.write!(file, initial)

      # 16 edit_file calls, ALL targeting the same file, each replacing one
      # distinct marker. On a concurrent batch each call reads the original
      # bytes and the last write wins, so at most one DONE marker would survive.
      calls =
        for i <- 0..(@batch_size - 1) do
          call =
            tool_call("edit_file", %{
              "file_path" => "./notes.txt",
              "old_string" => slot_marker(i),
              "new_string" => done_marker(i)
            })

          {call, i}
        end

      results = ToolDispatch.batch_execute_tools(calls, @tool_timeout, repo_root, :high)

      # Results come back in request order...
      assert Enum.map(results, &elem(&1, 0)) == Enum.to_list(0..(@batch_size - 1))

      # ...every call reports success...
      for {_index, _id, name, output} <- results do
        assert name == "edit_file"
        assert output =~ "has been updated successfully"
      end

      content = File.read!(file)

      # ...and EVERY edit is present in the final file.
      for i <- 0..(@batch_size - 1) do
        assert content =~ done_marker(i),
               "edit #{i} was lost: #{inspect(done_marker(i))} missing from the file"
      end

      refute content =~ "SLOT_", "no original marker should remain, got:\n#{content}"
    end

    test "interleaved write_file + edit_file calls apply in request order", %{
      repo_root: repo_root
    } do
      # Serial calls execute in REQUEST order, one at a time, so the net effect
      # is exactly "apply these in order" — deterministic. Under a concurrent
      # batch the edits would race the writes and the final bytes would not be
      # reproducible.
      calls = [
        {tool_call("write_file", %{"file_path" => "./mixed.txt", "content" => "a\nb\nc\n"}), 0},
        {tool_call("edit_file", %{
           "file_path" => "./mixed.txt",
           "old_string" => "b",
           "new_string" => "B_EDIT"
         }), 1},
        {tool_call("write_file", %{"file_path" => "./mixed.txt", "content" => "fresh\n"}), 2},
        {tool_call("edit_file", %{
           "file_path" => "./mixed.txt",
           "old_string" => "fresh",
           "new_string" => "FRESH_EDITED"
         }), 3}
      ]

      results = ToolDispatch.batch_execute_tools(calls, @tool_timeout, repo_root, :high)

      assert Enum.map(results, &elem(&1, 0)) == [0, 1, 2, 3]

      assert Enum.map(results, &elem(&1, 2)) == [
               "write_file",
               "edit_file",
               "write_file",
               "edit_file"
             ]

      for {_index, _id, _name, output} <- results do
        assert output =~ "Successfully wrote to ./mixed.txt" or
                 output =~ "has been updated successfully"
      end

      # Net effect of applying the four calls in order: the last write resets the
      # file, then the last edit transforms it.
      assert File.read!(Path.join(repo_root, "mixed.txt")) == "FRESH_EDITED\n"
    end
  end

  describe "batch_execute_tools/4 serial phase runs before the parallel phase" do
    test "a write followed by a read in one batch returns the newly written content", %{
      repo_root: repo_root
    } do
      calls = [
        {tool_call("write_file", %{
           "file_path" => "./ordered.txt",
           "content" => "ORDERED_CONTENT\n"
         }), 0},
        {tool_call("read_file", %{"file_path" => "./ordered.txt"}), 1}
      ]

      results = ToolDispatch.batch_execute_tools(calls, @tool_timeout, repo_root, :high)

      # Results are index-sorted and each result corresponds to its request index.
      assert Enum.map(results, &elem(&1, 0)) == [0, 1]
      [write_result, read_result] = results

      assert elem(write_result, 2) == "write_file"
      assert elem(write_result, 1) == elem(hd(calls), 0).id
      assert elem(write_result, 3) =~ "Successfully wrote to ./ordered.txt"

      assert elem(read_result, 2) == "read_file"
      assert elem(read_result, 1) == elem(Enum.at(calls, 1), 0).id
      assert elem(read_result, 3) =~ "ORDERED_CONTENT"
    end

    test "the serial write runs BEFORE an earlier-indexed read that observes it", %{
      repo_root: repo_root
    } do
      # The read is requested FIRST (index 0) and the write SECOND (index 1), yet
      # the file-mutating write is the one serialized — and the serial phase runs
      # before the concurrent phase — so the read must observe the new bytes.
      calls = [
        {tool_call("read_file", %{"file_path" => "./first_read.txt"}), 0},
        {tool_call("write_file", %{"file_path" => "./first_read.txt", "content" => "LATE_WRITE\n"}),
         1}
      ]

      results = ToolDispatch.batch_execute_tools(calls, @tool_timeout, repo_root, :high)

      assert Enum.map(results, &elem(&1, 0)) == [0, 1]
      [read_result, write_result] = results

      assert elem(read_result, 2) == "read_file"
      assert elem(write_result, 2) == "write_file"
      assert elem(write_result, 3) =~ "Successfully wrote to ./first_read.txt"
      assert elem(read_result, 3) =~ "LATE_WRITE"
    end
  end

  # --- Helpers ---

  # Builds a `%ReqLLM.ToolCall{}` from a name + decoded args map, encoding the
  # args as JSON exactly like a provider response does.
  defp tool_call(name, args) do
    id = "call_#{name}_#{:erlang.unique_integer([:positive])}"
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
  end

  defp slot_marker(i), do: "SLOT_" <> pad(i)
  defp done_marker(i), do: "DONE_" <> pad(i)

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 2, "0")
end
