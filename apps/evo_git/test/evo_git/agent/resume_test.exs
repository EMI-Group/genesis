defmodule EvoGit.Agent.ResumeTest.StubAgent do
  @moduledoc """
  The role a resume-repair state runs AS when it declares NO subagents.
  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the resume-repair stub agent."

  @doc "The role exposes no tools and no subagents."
  def available_tools, do: []
end

defmodule EvoGit.Agent.ResumeTest.StubSubagent do
  @moduledoc "A stub subagent module, so a `task` call classifies as `:subagent`."

  @doc "The subagent tool name the model calls."
  def subagent_tool_name, do: "task"

  @doc "The subagent tool description."
  def subagent_tool_description, do: "stub subagent"
end

defmodule EvoGit.Agent.ResumeTest.SubagentAgent do
  @moduledoc """
  The role a resume-repair state runs AS when it DID spawn subagents: its
  `subagent_modules/0` is what `EvoGit.Agent.ToolBatch` classifies a `task` call
  by (the marker is the provenance source).
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the resume-repair subagent-spawning stub agent."

  @doc "The role declares ONE subagent module."
  def subagent_modules, do: [EvoGit.Agent.ResumeTest.StubSubagent]

  @doc "No model-facing tools are needed: the repair never dispatches."
  def available_tools, do: []
end

defmodule EvoGit.Agent.ResumeTest do
  @moduledoc """
  `EvoGit.Agent.Resume.apply/1,2` — the crash-resume repair.

  `async: true`: every state is hand-built (no scheduler row, no ETS write, no
  app-env mutation) and every test that needs a worktree uses its own
  `:tmp_dir` git repo. The scheduler is NEVER contacted: the re-attach is an
  explicit `:reattach_fun` option, which is the seam these tests count and
  steer.

  The suite pins, in order:
    1. the repaired transcript SHAPE — one `:tool` message per unanswered call,
       in call order, with the provider ids and turn tags, and nothing for a
       call that was already answered;
    2. the per-class honest WORDING (and that no class ever fabricates success);
    3. the ONE `[RESUME]` notice — non-user-authored, exactly once, with factual
       sentences that DEGRADE when their fact is absent;
    4. inertness (`persistent_state: false`, no `resume_info`) and idempotence;
    5. the subagent RE-ATTACH — real results adopted from ONE batch call, the
       surviving children's commits actually MERGED into the parent worktree,
       per-slot degradation for a lost child, and total degradation on a refusal
       or a raise.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Resume
  alias EvoGit.Agent.ResumeTest.StubAgent
  alias EvoGit.Agent.ResumeTest.SubagentAgent
  alias EvoGit.Agent.ResumeTest.StubSubagent
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch

  @turn 4
  @objective "the objective"

  describe "the repaired transcript shape" do
    test "answers exactly the unanswered calls, in call order, with ids and turn tags" do
      calls = [tool_call("c0", "read"), tool_call("c3", "bash"), tool_call("c5", "task")]

      repaired = repair!(conversation(calls))

      messages = repaired.context.messages
      assert length(messages) == 7

      # Prefix invariant: system + first user are byte-identical.
      assert Enum.take(messages, 2) == conversation(calls) |> Enum.take(2)

      results = Enum.slice(messages, 3, 3)
      assert Enum.map(results, & &1.role) == [:tool, :tool, :tool]
      assert Enum.map(results, & &1.tool_call_id) == ["c0", "c3", "c5"]
      assert Enum.map(results, & &1.metadata[:turn]) == [@turn, @turn, @turn]

      # Every unanswered call is answered exactly once — nothing orphaned.
      call_ids = MapSet.new(Enum.map(calls, & &1.id))
      tool_ids = messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.tool_call_id)
      assert MapSet.new(tool_ids) == call_ids
      assert length(tool_ids) == 3
    end

    test "adds nothing for a call that was already answered, and no duplicate" do
      earlier = [
        %ReqLLM.Message{
          role: :assistant,
          content: [text_part("earlier turn")],
          tool_calls: [tool_call("c-old", "read")],
          metadata: %{turn: 2}
        },
        %ReqLLM.Message{
          role: :tool,
          tool_call_id: "c-old",
          content: [text_part("old output")],
          metadata: %{turn: 2}
        }
      ]

      messages =
        [
          message(:system, "sys prompt"),
          message(:user, @objective)
        ] ++ earlier ++ [dangling_assistant([tool_call("c2", "bash")])]

      repaired = repair!(messages)
      repaired_messages = repaired.context.messages

      # The earlier pair is untouched, including its single tool answer.
      assert Enum.at(repaired_messages, 3) == Enum.at(messages, 3)

      assert Enum.count(repaired_messages, &(&1.role == :tool and &1.tool_call_id == "c-old")) ==
               1

      # Exactly ONE new answer, for the dangling call only.
      new_tools =
        Enum.filter(repaired_messages, &(&1.role == :tool and &1.tool_call_id != "c-old"))

      assert Enum.map(new_tools, & &1.tool_call_id) == ["c2"]
    end

    test "does nothing but notice when the transcript has no dangling tool_calls" do
      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        message(:assistant, "a plain reply")
      ]

      repaired = repair!(messages)

      assert length(repaired.context.messages) == 4
      assert Enum.map(repaired.context.messages, & &1.role) == [:system, :user, :assistant, :user]
      assert repaired.pending_tool_batch == nil
    end
  end

  describe "per-class wording (honest, never fabricated)" do
    test "read, shell, edit and write each keep their own wording" do
      calls = [
        tool_call("r", "read"),
        tool_call("s", "bash"),
        tool_call("e", "edit"),
        tool_call("w", "write")
      ]

      texts = tool_texts(repair!(conversation(calls)), ["r", "s", "e", "w"])

      assert texts["r"] =~ "unavailable"
      assert texts["r"] =~ "Re-run"
      assert texts["s"] =~ "UNKNOWN"
      assert texts["s"] =~ "Do not blindly re-run destructive commands"
      assert texts["e"] =~ "PARTIALLY written"
      assert texts["e"] =~ "Re-read the file"
      assert texts["w"] =~ "partially written"
      assert texts["w"] =~ "Inspect the target"

      for {_id, text} <- texts do
        refute text =~ "Success"
        refute text =~ "completed successfully"
      end
    end

    test "an unanswerable subagent call gets the honest durable-rebuild fallback" do
      # No in-memory batch survives, so the resume attempts the durable roster
      # rebuild — and no roster row exists for that turn either. Both refusals
      # end in the honest fallback text and exactly ONE warning.
      calls = [tool_call("t", "task", %{"path" => "./src", "objective" => "child work"})]

      {repaired, log} =
        captured(fn ->
          repair!(conversation(calls),
            agent_module: SubagentAgent,
            reattach_fun: fn _agent_id, _count -> {:error, :no_pending_batch} end
          )
        end)

      rebuild_warnings =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "no durable subagent batch to rebuild"))

      # EXACTLY ONE durable-rebuild fallback warning for THIS call, counted by
      # its own distinctive text inside a capture SCOPED to this process's own
      # log events (`captured/1`). The scope is load-bearing: the sibling
      # `agent/resume/reattach_test.exs` and `agent/resume/roster_batch_test.exs`
      # modules emit the very same wording from their own processes, so an
      # unscoped (`ExUnit.CaptureLog` is node-global) count would be
      # load-dependent while an id-scoped one never can be.
      assert [warning] = rebuild_warnings
      assert warning =~ ":no_pending_batch"
      assert warning =~ "answering 1 interrupted subagent call(s)"
      text = tool_texts(repaired, ["t"])["t"]

      assert text =~ "crashed and restarted"
      assert text =~ "may still exist"
      assert text =~ "tool `task`"
      refute text =~ "Success"
    end

    test "class falls back to the call name when the marker is absent" do
      # No in-flight marker at all: the class is re-derived from the call name.
      repaired = repair!(conversation([tool_call("s", "bash")]), batch: nil)
      assert tool_texts(repaired, ["s"])["s"] =~ "UNKNOWN"
    end
  end

  describe "the [RESUME] notice" do
    test "is appended exactly once, framed, and is NOT user-authored" do
      calls = [tool_call("c0", "read"), tool_call("c3", "bash"), tool_call("c5", "task")]

      {repaired, _log} =
        captured(fn ->
          repair!(conversation(calls),
            agent_module: SubagentAgent,
            reattach_fun: fn _agent_id, _count -> {:error, :no_pending_batch} end
          )
        end)

      messages = repaired.context.messages
      notice = List.last(messages)

      assert notice.role == :user
      text = text_of(notice)
      assert text =~ "[RESUME]"
      assert text =~ "attempt 3"
      assert text =~ "Interruption reason: crash."
      assert text =~ "Interrupted tool calls: 3"
      assert text =~ "shell × 1"
      assert text =~ "subagent × 1"
      assert text =~ "abc1234"
      assert text =~ "restored from commit"
      assert notice.metadata[:resume_notice] == true
      assert notice.metadata[:user_authored] == nil
      # Exactly ONE notice in the whole transcript.
      assert Enum.count(messages, &(&1.role == :user and text_of(&1) =~ "[RESUME]")) == 1
    end

    test "degrades every sentence whose fact is absent" do
      calls = [tool_call("c0", "read")]

      info = %{restore_agent_state: true, restored: false}
      repaired = repair!(conversation(calls), resume_info: info)
      text = repaired.context.messages |> List.last() |> text_of()

      refute text =~ "attempt"
      refute text =~ "Interruption reason"
      refute text =~ "restored from commit"
      assert text =~ "recreated from the task's base commit"
      assert text =~ "could NOT be restored from durable state"
    end

    test "a blank retry_reason drops the reason sentence" do
      info = %{
        restore_agent_state: true,
        restored: true,
        retry_reason: "   ",
        worktree_resume_from: "deadbeef"
      }

      repaired = repair!(conversation([tool_call("c0", "read")]), resume_info: info)
      text = repaired.context.messages |> List.last() |> text_of()

      refute text =~ "Interruption reason"
      assert text =~ "deadbeef"
    end
  end

  describe "task-level pause resume narration" do
    test "a CLEAN pause restores the transcript with NO repair and one neutral notice" do
      # A clean pause stops at a TURN BOUNDARY, so nothing is dangling and no
      # batch is in flight — the transcript is exactly what the pause left.
      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        message(:assistant, "working")
      ]

      state = state(messages, batch: nil, resume_info: clean_pause_info())

      # The contract this narration rests on: a clean pause has nothing to
      # repair by construction.
      assert Resume.dangling(state) == :none
      assert ToolBatch.calls(state.pending_tool_batch) == []

      resumed = Resume.apply(state, reattach_fun: deny_reattach(self()))

      # Prefix invariant: system + first user message stay BYTE-IDENTICAL.
      assert Enum.take(resumed.context.messages, 2) == Enum.take(messages, 2)

      # NO synthetic tool result: exactly ONE message was appended.
      assert length(resumed.context.messages) == length(messages) + 1
      refute Enum.any?(resumed.context.messages, &(&1.role == :tool))

      notice = List.last(resumed.context.messages)
      text = text_of(notice)

      # One neutral notice — never `[RESUME]`, never repair/inconsistency wording.
      assert notice.role == :user
      assert notice.metadata[:resume_notice] == true
      assert notice.metadata[:user_authored] == nil
      refute text =~ "[RESUME]"
      refute text =~ "repair"
      refute text =~ "inconsistent"
      refute text =~ "Interrupted tool calls"

      # It states the pause/resume, the untouched worktree and what the
      # whole-tree resume does with the subagents, and claims no interruption.
      assert text =~ "paused this task and has now resumed it"
      assert text =~ "worktree is exactly as it was left"
      assert text =~ "No tool call was interrupted"
      assert text =~ "contributes its stored result"
      # The clean-pause subagent sentence describes a FROZEN tree, not a
      # re-spawn-on-own-checkpoint interruption.
      assert text =~ "part of the pause snapshot"
      assert text =~ "re-spawned under its own durable state and worktree"
      assert text =~ "you now WAIT for it — the batch is not re-issued"

      # Exactly ONE such notice in the whole transcript.
      assert Enum.count(resumed.context.messages, &(&1.role == :user and text_of(&1) =~ "paused")) ==
               1

      # The marker is cleared and the re-attach was never needed.
      assert resumed.pending_tool_batch == nil
      refute_received {:reattach, _agent_id, _count}
    end

    test "a CLEAN pause frozen on a subagent batch REBUILDS it and answers with the real texts",
         %{tmp_dir: tmp_dir} do
      # The other clean-pause position: the pause parked the parent INSIDE
      # `spawn_sub_agents/2`, so the all-subagent marker is still set, NO tool
      # result was appended and no child result was stored. Nothing was
      # interrupted, so the batch must be rebuilt and answered for real.
      %{repo: repo, results: results} = subagent_fixture!(tmp_dir)
      test_pid = self()

      calls = [
        tool_call("c1", "task", %{"path" => "./src", "objective" => "do the src work"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "do the doc work"})
      ]

      state =
        state(conversation(calls),
          agent_module: SubagentAgent,
          repo_path: repo,
          resume_info: clean_pause_info()
        )

      # The contract this path rests on: a pure-subagent marker + a dangling tail.
      assert ToolBatch.calls(state.pending_tool_batch) |> length() == 2
      assert {:ok, @turn, _calls} = Resume.dangling(state)

      resumed =
        Resume.apply(state,
          reattach_fun: fn agent_id, count ->
            send(test_pid, {:reattach, agent_id, count})
            {:ok, ok_results(results)}
          end
        )

      # (a) ONE re-attach/rebuild request for the WHOLE batch.
      assert_received {:reattach, _agent_id, 2}
      refute_received {:reattach, _agent_id, _count}
      # (b) the REAL child texts and the merge note — no invented result.
      texts = tool_texts(resumed, ["c1", "c2"])
      assert texts["c1"] =~ "# Result"
      assert texts["c1"] =~ "child one did the src work"
      assert texts["c2"] =~ "child two did the doc work"

      for {_id, text} <- texts do
        refute text =~ "crashed"
        refute text =~ "interrupted"
        refute text =~ "outcome unknown"
        refute text =~ "may have happened"
      end

      assert File.read!(Path.join(repo, "src/b.ex")) == "defmodule B do\nend\n"

      assert Enum.any?(
               resumed.context.messages,
               &(&1.role == :user and text_of(&1) =~ "Successfully auto-merged")
             )

      # (c) exactly ONE neutral pause notice, and NO repair wording.
      notices =
        Enum.filter(
          resumed.context.messages,
          &(&1.role == :user and text_of(&1) =~ "paused this task and has now resumed it")
        )

      assert length(notices) == 1
      text = text_of(List.last(resumed.context.messages))
      refute text =~ "[RESUME]"
      refute text =~ "crashed"
      refute text =~ "outcome unknown"
      refute text =~ "may have happened"
      refute text =~ "Interrupted tool calls"
      refute text =~ "synthetic tool result"
      assert text =~ "part of the pause snapshot"
      assert text =~ "the batch is not re-issued"

      assert Enum.count(
               resumed.context.messages,
               &(&1.role == :user and text_of(&1) =~ "[RESUME]")
             ) ==
               0

      # (d) the marker is cleared, and the transcript stays provider-valid: one
      # `:tool` answer per unanswered call, in model call order.
      assert resumed.pending_tool_batch == nil

      answered =
        resumed.context.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.map(& &1.tool_call_id)

      assert answered == ["c1", "c2"]
    end

    test "a clean pause with NOTHING appended is still untouched when a notice exists" do
      state =
        state(conversation([]) |> List.delete_at(-1), batch: nil, resume_info: clean_pause_info())

      once = Resume.apply(state)
      twice = Resume.apply(once)

      assert twice == once

      assert Enum.count(twice.context.messages, &(&1.role == :user and text_of(&1) =~ "paused")) ==
               1
    end

    test "a clean pause whose restore failed never claims the conversation is intact" do
      info = %{restore_agent_state: true, restored: false, resume_kind: :clean_pause}
      state = state(conversation([]) |> List.delete_at(-1), batch: nil, resume_info: info)

      text = state |> Resume.apply() |> then(&List.last(&1.context.messages)) |> text_of()

      assert text =~ "could NOT be restored from durable state"
      refute text =~ "repair"
    end

    test "a DIRTY pause keeps the crash repair and exactly ONE [RESUME] notice" do
      calls = [tool_call("c0", "read"), tool_call("c1", "bash")]
      info = Map.put(clean_pause_info(), :resume_kind, :dirty_pause)

      resumed =
        conversation(calls)
        |> repair!(resume_info: info, reattach_fun: deny_reattach(self()))

      messages = resumed.context.messages

      # Prefix invariant.
      assert Enum.take(messages, 2) == Enum.take(conversation(calls), 2)

      # The repair DID run: one synthetic `:tool` message per unanswered call.
      results = Enum.filter(messages, &(&1.role == :tool))
      assert Enum.map(results, & &1.tool_call_id) == ["c0", "c1"]

      notice = List.last(messages)
      text = text_of(notice)

      assert text =~ "[RESUME]"
      assert text =~ "Interrupted tool calls: 2"
      # A post-restart pause says so and still states the subagent fate.
      assert text =~ "PAUSED when the host restarted"
      assert text =~ "contributes its stored result"
      assert text =~ "is re-spawned and resumes from its own durable checkpoint"
      assert Enum.count(messages, &(&1.role == :user and text_of(&1) =~ "[RESUME]")) == 1
    end
  end

  describe "inertness and idempotence" do
    test "a second apply adds nothing and issues no second re-attach" do
      test_pid = self()
      calls = [tool_call("t", "task", %{"path" => "./src", "objective" => "child work"})]

      fun = fn agent_id, count ->
        send(test_pid, {:reattach, agent_id, count})
        {:error, :no_pending_batch}
      end

      {once, _log} =
        captured(fn ->
          repair!(conversation(calls), agent_module: SubagentAgent, reattach_fun: fun)
        end)

      assert_received {:reattach, _agent_id, 1}

      twice = Resume.apply(once, reattach_fun: fun)

      assert twice == once
      refute_received {:reattach, _agent_id, _count}
    end

    test "persistent_state: false is fully inert and never calls the scheduler" do
      test_pid = self()
      calls = [tool_call("t", "task", %{"path" => "./src", "objective" => "child work"})]

      state =
        state(conversation(calls),
          agent_module: SubagentAgent,
          persistent_state: false
        )

      result =
        Resume.apply(state,
          reattach_fun: fn agent_id, count ->
            send(test_pid, {:reattach, agent_id, count})
            {:error, :no_pending_batch}
          end
        )

      assert result == state
      refute_received {:reattach, _agent_id, _count}
    end

    test "no resume_info (or a restore that was not requested) is untouched" do
      test_pid = self()
      calls = [tool_call("t", "task", %{"path" => "./src", "objective" => "child work"})]

      fun = fn agent_id, count ->
        send(test_pid, {:reattach, agent_id, count})
        {:error, :no_pending_batch}
      end

      for info <- [nil, %{restore_agent_state: false}, :garbage, %{"restore_agent_state" => true}] do
        state = state(conversation(calls), resume_info: info)
        assert Resume.apply(state, reattach_fun: fun) == state
      end

      refute_received {:reattach, _agent_id, _count}
    end

    test "the in-flight marker is always cleared" do
      repaired = repair!(conversation([tool_call("c0", "read")]))
      assert repaired.pending_tool_batch == nil
    end
  end

  describe "subagent re-attach" do
    test "adopts the real results and merges the survivor commits into the parent worktree",
         %{tmp_dir: tmp_dir} do
      %{repo: repo, base: base, results: results} = subagent_fixture!(tmp_dir)

      calls = [
        tool_call("c0", "read"),
        tool_call("c1", "task", %{"path" => "./src", "objective" => "do the src work"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "do the doc work"})
      ]

      reattached =
        conversation(calls)
        |> repair!(
          agent_module: SubagentAgent,
          repo_path: repo,
          reattach_fun: fn _agent_id, 2 -> {:ok, ok_results(results)} end
        )

      texts = tool_texts(reattached, ["c0", "c1", "c2"])

      # The real, UNCHANGED formatter output — no fallback anywhere.
      assert texts["c1"] =~ "# Result"
      assert texts["c1"] =~ "# Final Commit"
      assert texts["c1"] =~ "child one did the src work"
      first_sha = results |> Enum.at(0) |> Map.fetch!(:commit_sha)
      second_sha = results |> Enum.at(1) |> Map.fetch!(:commit_sha)
      assert texts["c1"] =~ first_sha
      assert texts["c2"] =~ "child two did the doc work"
      assert texts["c2"] =~ second_sha

      refute Enum.any?(texts, fn {_id, text} -> text =~ "crashed and restarted" end)
      # The non-subagent call keeps its own class wording.
      assert texts["c0"] =~ "unavailable"

      # THIS is the point of the merge: the children's work must be IN the
      # parent worktree, not merely reported.
      assert File.read!(Path.join(repo, "src/b.ex")) == "defmodule B do\nend\n"
      assert File.read!(Path.join(repo, "doc/x.md")) == "# Doc\n"
      assert git!(repo, ["rev-parse", "HEAD"]) != base

      # The merge outcome is reported the way the spawn path reports it.
      assert Enum.any?(
               reattached.context.messages,
               &(&1.role == :user and text_of(&1) =~ "Successfully auto-merged")
             )
    end

    test "keeps the fallback text for exactly the slot the scheduler reports as lost",
         %{tmp_dir: tmp_dir} do
      %{repo: repo, results: [kept_result | _]} = subagent_fixture!(tmp_dir)

      calls = [
        tool_call("c1", "task", %{"path" => "./src", "objective" => "keep me"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "lose me"})
      ]

      results = [{:ok, kept_result}, {:error, :subagent_result_lost}]

      reattached =
        conversation(calls)
        |> repair!(
          agent_module: SubagentAgent,
          repo_path: repo,
          reattach_fun: fn _agent_id, 2 -> {:ok, results} end
        )

      texts = tool_texts(reattached, ["c1", "c2"])

      assert texts["c1"] =~ "# Result"
      assert texts["c1"] =~ "child one did the src work"
      refute texts["c1"] =~ "crashed and restarted"

      assert texts["c2"] =~ "crashed and restarted"
      refute texts["c2"] =~ "# Result"

      # Only the survivor's work landed.
      assert File.exists?(Path.join(repo, "src/b.ex"))
      refute File.exists?(Path.join(repo, "doc/x.md"))
    end

    test "answers EVERY subagent call with the fallback when the batch is refused" do
      calls = [
        tool_call("c1", "task", %{"path" => "./src", "objective" => "one"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "two"})
      ]

      for reply <- [{:error, :no_pending_batch}, {:error, :unavailable}] do
        {reattached, _log} =
          captured(fn ->
            repair!(conversation(calls),
              agent_module: SubagentAgent,
              reattach_fun: fn _agent_id, 2 -> reply end
            )
          end)

        texts = tool_texts(reattached, ["c1", "c2"])
        assert texts["c1"] =~ "crashed and restarted"
        assert texts["c2"] =~ "crashed and restarted"
        refute texts["c1"] =~ "# Result"
        refute texts["c2"] =~ "# Result"
      end
    end

    test "issues ONE re-attach for the whole batch, with the agent id and expected count" do
      test_pid = self()
      agent_id = 7_770_000 + System.unique_integer([:positive])

      calls = [
        tool_call("c0", "read"),
        tool_call("c1", "task", %{"path" => "./src", "objective" => "one"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "two"})
      ]

      conversation(calls)
      |> repair!(
        agent_id: agent_id,
        agent_module: SubagentAgent,
        reattach_fun: fn id, count ->
          send(test_pid, {:reattach, id, count})
          {:ok, [{:error, :subagent_result_lost}, {:error, :subagent_result_lost}]}
        end
      )

      assert_received {:reattach, ^agent_id, 2}
      refute_received {:reattach, _agent_id, _count}
    end

    test "never calls the scheduler when the interrupted batch has no subagent calls" do
      test_pid = self()

      conversation([tool_call("c0", "read"), tool_call("c1", "bash")])
      |> repair!(
        agent_module: SubagentAgent,
        reattach_fun: fn agent_id, count ->
          send(test_pid, {:reattach, agent_id, count})
          {:error, :no_pending_batch}
        end
      )

      refute_received {:reattach, _agent_id, _count}
    end

    test "a raising re-attach degrades to the fallback text instead of raising" do
      calls = [
        tool_call("c1", "task", %{"path" => "./src", "objective" => "one"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "two"})
      ]

      {reattached, log} =
        captured(fn ->
          repair!(conversation(calls),
            agent_module: SubagentAgent,
            reattach_fun: fn _agent_id, _count -> raise "scheduler exploded" end
          )
        end)

      assert log =~ "scheduler exploded"
      texts = tool_texts(reattached, ["c1", "c2"])
      assert texts["c1"] =~ "crashed and restarted"
      assert texts["c2"] =~ "crashed and restarted"
    end

    test "a non-binary/invalid result entry degrades that slot only" do
      calls = [
        tool_call("c1", "task", %{"path" => "./src", "objective" => "one"}),
        tool_call("c2", "task", %{"path" => "./doc", "objective" => "two"})
      ]

      # Cross-repo so no merge is attempted (this test is about the per-slot
      # answer, not about integration).
      results = [
        {:ok, Result.new("real child work", "abc1234", repo_id: "other-repo")},
        :unexpected
      ]

      reattached =
        conversation(calls)
        |> repair!(
          agent_module: SubagentAgent,
          reattach_fun: fn _agent_id, 2 -> {:ok, results} end
        )

      texts = tool_texts(reattached, ["c1", "c2"])
      assert texts["c1"] =~ "# Result"
      assert texts["c1"] =~ "abc1234"
      assert texts["c2"] =~ "crashed and restarted"
    end

    test "a same-repo result whose work CANNOT be merged degrades to the fallback text" do
      # No repo path on the parent: the merge cannot run, so reporting the
      # child's completion would claim work that is not in any worktree.
      calls = [tool_call("c1", "task", %{"path" => "./src", "objective" => "one"})]
      results = [{:ok, Result.new("child work that cannot land", "abc1234")}]

      reattached =
        conversation(calls)
        |> repair!(
          agent_module: SubagentAgent,
          reattach_fun: fn _agent_id, 1 -> {:ok, results} end
        )

      texts = tool_texts(reattached, ["c1"])
      assert texts["c1"] =~ "crashed and restarted"
      refute texts["c1"] =~ "child work that cannot land"
    end

    test "a cross-repo child is formatted but NEVER merged", %{tmp_dir: tmp_dir} do
      %{repo: repo, results: [result | _]} = subagent_fixture!(tmp_dir)
      foreign = %{result | repo_id: "other-repo", commit_sha: "not-in-this-repo"}

      calls = [tool_call("c1", "task", %{"path" => "./src", "objective" => "one"})]

      reattached =
        conversation(calls)
        |> repair!(
          agent_module: SubagentAgent,
          repo_path: repo,
          reattach_fun: fn _agent_id, 1 -> {:ok, [{:ok, foreign}]} end
        )

      assert tool_texts(reattached, ["c1"])["c1"] =~ "# Result"
      assert tool_texts(reattached, ["c1"])["c1"] =~ result.result
      # No merge ran: no files landed and no merge note was appended.
      refute File.exists?(Path.join(repo, "src/b.ex"))

      refute Enum.any?(
               reattached.context.messages,
               &(&1.role == :user and text_of(&1) =~ "auto-merged")
             )
    end
  end

  ## Conversation / state builders

  # The `resume_info` of a CLEAN pause resume as `Setup.build_initial_state/3`
  # builds it from the dispatch ctx: a pause resume restores, has no retry and
  # names the pause checkpoint the worktree was based on.
  defp clean_pause_info do
    %{
      restore_agent_state: true,
      restored: true,
      resume_kind: :clean_pause,
      retries: 0,
      retry_reason: nil,
      worktree_resume_from: "pause1234"
    }
  end

  # A re-attach fun that must NOT be called; it records any call and degrades.
  defp deny_reattach(test_pid) do
    fn agent_id, count ->
      send(test_pid, {:reattach, agent_id, count})
      {:error, :no_pending_batch}
    end
  end

  defp repair!(messages, opts \\ []) do
    state = state(messages, opts)
    Resume.apply(state, Keyword.take(opts, [:reattach_fun]))
  end

  defp state(messages, opts) do
    calls = dangling_calls(messages)
    batch = Keyword.get(opts, :batch, ToolBatch.build(calls, @turn, subagent_modules(opts)))

    struct!(
      State,
      agent_id: Keyword.get(opts, :agent_id, 7_770_000 + System.unique_integer([:positive])),
      agent_module: Keyword.get(opts, :agent_module, StubAgent),
      depth: 0,
      node_path: Keyword.get(opts, :node_path, "./"),
      repo_id: Keyword.get(opts, :repo_id, "primary"),
      repo_path: Keyword.get(opts, :repo_path),
      context: ReqLLM.Context.new(messages),
      task_id: "resume-test",
      persistent_state: Keyword.get(opts, :persistent_state, true),
      turn: @turn,
      pending_tool_batch: batch,
      resume_info:
        Keyword.get(opts, :resume_info, %{
          restore_agent_state: true,
          restored: true,
          retries: 2,
          retry_reason: :crash,
          worktree_resume_from: "abc1234"
        })
    )
  end

  defp subagent_modules(opts) do
    case Keyword.get(opts, :agent_module, StubAgent) do
      SubagentAgent -> [StubSubagent]
      _other -> []
    end
  end

  # The calls of a transcript whose LAST message is an assistant `tool_calls`
  # message — the batch the marker describes in a real run.
  defp dangling_calls(messages) do
    case List.last(messages) do
      %ReqLLM.Message{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
      _other -> []
    end
  end

  defp conversation(calls) do
    [
      message(:system, "sys prompt"),
      message(:user, @objective),
      dangling_assistant(calls)
    ]
  end

  defp dangling_assistant(calls) do
    %ReqLLM.Message{
      role: :assistant,
      content: [text_part("running tools")],
      tool_calls: calls,
      metadata: %{turn: @turn}
    }
  end

  defp message(role, text), do: %ReqLLM.Message{role: role, content: [text_part(text)]}

  defp text_part(text), do: ReqLLM.Message.ContentPart.text(text)

  defp text_of(%ReqLLM.Message{content: content}) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      other -> inspect(other)
    end)
    |> Enum.join()
  end

  defp tool_call(id, name, args \\ %{}) do
    %ReqLLM.ToolCall{
      id: id,
      type: "function",
      function: %{name: name, arguments: Jason.encode!(args)}
    }
  end

  # `id => text` for the tool messages of the given ids.
  defp tool_texts(%State{context: %ReqLLM.Context{messages: messages}}, ids) do
    messages
    |> Enum.filter(&(&1.role == :tool and &1.tool_call_id in ids))
    |> Map.new(&{&1.tool_call_id, text_of(&1)})
  end

  ## Git fixture: a parent repo at a base commit plus two child branches, each
  ## carrying ONE commit in its own node — exactly the shape a survived subagent
  ## batch leaves behind.

  defp subagent_fixture!(tmp_dir) do
    repo = Path.join(tmp_dir, "parent")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"}
        ] do
      git!(repo, ["config", key, value])
    end

    base = commit_file!(repo, "src/a.ex", "defmodule A do\nend\n", "base")
    main = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])

    git!(repo, ["checkout", "-q", "-b", "child-src"])
    src_sha = commit_file!(repo, "src/b.ex", "defmodule B do\nend\n", "child one")
    git!(repo, ["checkout", "-q", main])

    git!(repo, ["checkout", "-q", "-b", "child-doc", base])
    doc_sha = commit_file!(repo, "doc/x.md", "# Doc\n", "child two")
    git!(repo, ["checkout", "-q", main])

    # Confirm the parent is still at the base: the children's work is NOT here.
    assert git!(repo, ["rev-parse", "HEAD"]) == base
    refute File.exists?(Path.join(repo, "src/b.ex"))

    %{
      repo: repo,
      base: base,
      results: [
        Result.new("child one did the src work", src_sha, branch: "child-src"),
        Result.new("child two did the doc work", doc_sha, branch: "child-doc")
      ]
    }
  end

  # Runs `fun` with its log captured (the deliberately degrading resume paths log
  # at `:warning`) and returns `{result, log}`.
  #
  # The window is SCOPED to the events THIS process emits. `ExUnit.CaptureLog`
  # installs ONE node-global handler, so an unfiltered window also collects every
  # concurrently running module's output — `agent/resume/reattach_test.exs` and
  # `agent/resume/roster_batch_test.exs` log the SAME distinctive
  # "no durable subagent batch to rebuild" wording (with their own agent ids), so
  # a whole-blob count would be inflated by a sibling under load. Every degrading
  # resume path logs from the process that runs the repair, which IS this process,
  # so a pid filter keeps each assertion strictly about this call without
  # weakening it.
  defp captured(fun) do
    log =
      capture_log([formatter: {__MODULE__, self()}], fn ->
        send(self(), {:logged_result, fun.()})
      end)

    result =
      receive do
        {:logged_result, value} -> value
      after
        0 -> flunk("the captured call produced no result")
      end

    {result, log}
  end

  @doc false
  # The `:formatter` of `captured/1`'s scoped `capture_log/2` — the capture
  # server calls `formatter.format(event, config)` with the `{module, term}`
  # tuple's second element as `config`. It renders ONLY the events the
  # capturing process emitted itself, one line each.
  # Public because `ExUnit.CaptureServer` runs the formatter in its OWN process,
  # and TOTAL because a non-matching event must render as nothing, never raise.
  def format(event, caller_pid) do
    if Map.get(event.meta, :pid) == caller_pid do
      "[#{event.level}] #{log_message(event.msg)}\n"
    else
      ""
    end
  end

  # Mirrors the parts of the default formatter the assertions rely on: the
  # message itself, with `$metadata` and timestamps elided.
  defp log_message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp log_message({:report, report}), do: inspect(report)
  defp log_message({format, args}), do: IO.chardata_to_string(:io_lib.format(format, args))
  defp log_message(other), do: inspect(other)

  defp ok_results(results), do: Enum.map(results, &{:ok, &1})

  defp commit_file!(repo, path, content, message) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
