defmodule EvoGit.Agent.ToolDispatchSameFileTest do
  @moduledoc """
  Batch-level regression test for the same-path parallel file-mutation race
  ("lost update") in `EvoGit.Agent.ToolDispatch.batch_execute_tools/4`.

  `batch_execute_tools/4` runs EVERY non-subagent tool call of one assistant
  message CONCURRENTLY (one `Task.async_stream` process per call), so a batch of
  `edit_file` calls on the SAME file used to race: each call read the original
  bytes and wrote back its own version, so all but the last edit were silently
  dropped while every call still returned its success string. The fix serializes
  the whole read-modify-write per path via
  `EvoGit.Agent.Tools.Shared.with_file_lock/2`.

  This module LOCK-IN asserts the batch-level contract (many same-file edits in
  one batch → every edit survives), which the per-tool lock test cannot: it is
  the only place where the concurrency actually exists.

  Serialized (`async: false`) because the harness works on BEAM-global state:
  the app-global `:evogit_agent_state` ETS table (via
  `EvoGit.AgentScheduler.Store.put_agent_state/2`) and the global
  `EvoGit.AgentScheduler` tool-slot pool (`AgentScheduler.with_tool_slot/2`,
  which every parallel tool call acquires).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch

  # Same-file batch size: large enough that a lost-update race is essentially
  # certain without the per-path lock, small enough to stay fast (each edit is a
  # plain file read/write).
  @edit_count 12

  describe "batch_execute_tools/4 with multiple same-file edit_file calls" do
    setup do
      repo_root =
        Path.join(
          System.tmp_dir!(),
          "tool_dispatch_same_file_#{:erlang.unique_integer([:positive])}"
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
        Process.delete(:evogit_agent_id)
        Process.delete(:repo_path)
        Process.delete(:genesis_repo_root)
        File.rm_rf!(repo_root)
      end)

      %{repo_root: repo_root}
    end

    test "every same-file edit in one batch survives (no lost update)", %{repo_root: repo_root} do
      # One file carrying N distinct, unique old_string tokens — so each edit is
      # independently identifiable AND independently unique in the file (the
      # edit_file uniqueness check would otherwise reject the call).
      original_lines =
        for i <- 1..@edit_count, do: "TOKEN_#{i}_ORIGINAL"

      File.write!(Path.join(repo_root, "race.txt"), Enum.join(original_lines, "\n") <> "\n")

      # One edit_file tool call per token, all targeting the SAME file — exactly
      # the shape pre-fix lost all but ~1 edit. The index mirrors how the real
      # runner indexes the tool calls of one assistant message.
      calls =
        for i <- 1..@edit_count do
          args =
            Jason.encode!(%{
              "file_path" => "./race.txt",
              "old_string" => "TOKEN_#{i}_ORIGINAL",
              "new_string" => "TOKEN_#{i}_EDITED"
            })

          {ReqLLM.ToolCall.new("call_#{i}", "edit_file", args), i - 1}
        end

      results = ToolDispatch.batch_execute_tools(calls, 1_800_000, repo_root, :high)

      # Batch results are index-ordered `{index, tool_call_id, tool_name, output}`.
      assert Enum.map(results, &elem(&1, 0)) == Enum.to_list(0..(@edit_count - 1))

      # EVERY call reports success. Pre-fix this ALSO held — which is precisely
      # why the lost update was invisible: the file content below is the real
      # assertion.
      assert Enum.all?(results, fn {_index, _id, name, _output} -> name == "edit_file" end)

      assert Enum.map(results, &elem(&1, 3)) ==
               List.duplicate("The file ./race.txt has been updated successfully.", @edit_count)

      content = File.read!(Path.join(repo_root, "race.txt"))

      # All N edits are present…
      for i <- 1..@edit_count do
        assert content =~ "TOKEN_#{i}_EDITED",
               "edit #{i} was lost — same-path parallel write race regressed"
      end

      # …and NO original marker remains (a surviving `_ORIGINAL` marker means
      # some call wrote back a stale snapshot of the file).
      refute content =~ "_ORIGINAL"

      assert length(String.split(content, "\n", trim: true)) == @edit_count
    end
  end
end
