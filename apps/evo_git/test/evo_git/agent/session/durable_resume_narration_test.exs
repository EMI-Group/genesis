defmodule EvoGit.Agent.Session.DurableResumeNarrationTest.StubAgent do
  @moduledoc false
  # `EvoGit.Agent.Resume` reads the agent's `subagent_modules/0` to classify an
  # unanswered `task` call; this stub reports no subagent capability, so the
  # narration cases need no real agent module.
  def subagent_modules, do: []
end

defmodule EvoGit.Agent.Session.DurableResumeNarrationTest do
  @moduledoc """
  The NARRATION half of the durable-resume contract, at the `EvoGit.Agent.Resume`
  boundary (pure `%EvoGit.Agent.State{}` values, no store, no repo, no session).

  Pins what a resumed run is TOLD about its own continuity:

    * a CLEAN pause that is genuinely intact resumes QUIETLY — one neutral notice,
      and never the inconsistency / partial-execution / lost-result wording;
    * a clean pause whose durable state provably is NOT intact (a non-empty
      `pending_tool_batch` marker, or a dangling `tool_calls` tail) takes the
      REPAIR path: an honest warning plus exactly one `[RESUME]` notice and, for
      the dangling tail, one synthetic per-class tool result per unanswered call;
    * a DIRTY resume / crash retry states plainly that uncommitted worktree
      changes were NOT preserved and names the checkpoint the worktree came from
      (or the task base when no checkpoint was recorded).

  `async: true`: every value here is a per-test struct and the log capture is the
  ExUnit per-test window — no BEAM-global is read or written.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Agent.Resume
  alias EvoGit.Agent.Session.DurableResumeNarrationTest.StubAgent
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch

  @turn 4
  @objective "the objective"

  describe "clean pause resume narration" do
    test "an intact clean pause resumes quietly and never hints at inconsistency" do
      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        message(:assistant, "the batch finished before the pause")
      ]

      state = state(messages, resume_info: clean_pause_info())

      {resumed, log} = captured(fn -> Resume.apply(state) end)

      # No repair happened: the transcript is the same prefix plus ONE notice.
      assert Enum.take(resumed.context.messages, length(messages)) == messages
      assert length(resumed.context.messages) == length(messages) + 1
      refute Enum.any?(resumed.context.messages, &(&1.role == :tool))

      [notice] = Enum.slice(resumed.context.messages, length(messages)..-1//1)
      assert notice.role == :user
      assert notice.metadata[:resume_notice] == true
      assert notice.metadata[:user_authored] == nil

      text = text_of(notice)
      assert text =~ "The user paused this task and has now resumed it"
      assert text =~ "No tool call was interrupted"
      assert text =~ "worktree is exactly as it was left"
      refute text =~ "[RESUME]"

      # A clean pause is NOT an inconsistency report: nothing may suggest the
      # worktree, the files or the tool results are in doubt.
      refute text =~ "may be inconsistent"
      refute text =~ "may still hold partial"
      refute text =~ "are unavailable"
      refute text =~ "Interrupted tool calls"
      refute resumed.pending_tool_batch

      # And nothing was logged: the quiet path degrades nothing.
      refute log =~ "clean-pause resume found an interrupted tool batch"

      # Exactly-once: a second apply/1 must not append a second notice.
      twice = Resume.apply(resumed)

      assert twice.context.messages == resumed.context.messages
      assert count_notices(twice) == 1
    end

    test "a clean pause with a non-empty batch marker repairs and says results are unavailable" do
      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        message(:assistant, "a batch was running when the pause was recorded")
      ]

      batch = ToolBatch.build([tool_call("c1", "bash")], @turn, [])

      state =
        state(messages,
          batch: batch,
          resume_info: clean_pause_info()
        )

      {resumed, log} = captured(fn -> Resume.apply(state) end)

      # The marker is provably non-empty, so a clean pause CANNOT be assumed
      # intact: the resume says so, once.
      assert log =~
               "clean-pause resume found an interrupted tool batch in the durable state; repairing it as an interruption"

      assert count_notices(resumed) == 1
      assert log |> String.split("found an interrupted tool batch") |> length() == 2

      [notice] = Enum.filter(resumed.context.messages, &notice_marked?/1)
      text = text_of(notice)
      assert text =~ "[RESUME]"
      assert text =~ "Interrupted tool calls: 1"
      assert text =~ "Their results are unavailable"
      refute text =~ "PAUSED when the host restarted"

      # The marker is consumed even though there was no dangling tail to answer.
      refute resumed.pending_tool_batch
    end

    test "a clean pause with a dangling tool_calls tail takes the per-class repair path" do
      calls = [tool_call("c1", "read"), tool_call("c2", "edit")]

      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        dangling_assistant(calls)
      ]

      state = state(messages, resume_info: clean_pause_info())

      {resumed, log} = captured(fn -> Resume.apply(state) end)

      assert log =~ "clean-pause resume found an interrupted tool batch"

      # One honest synthetic result per unanswered call, tagged with the turn
      # the interrupted batch belonged to.
      results = Enum.filter(resumed.context.messages, &(&1.role == :tool))
      assert Enum.map(results, & &1.tool_call_id) == ["c1", "c2"]
      assert Enum.all?(results, &(&1.metadata[:turn] == @turn))

      texts = Map.new(results, &{&1.tool_call_id, text_of(&1)})
      assert texts["c1"] =~ "unavailable"
      assert texts["c1"] =~ "Re-run it if you still need its output"
      assert texts["c2"] =~ "PARTIALLY written (inconsistent content)"
      assert texts["c2"] =~ "Re-read the file before editing it again"

      assert count_notices(resumed) == 1
      [notice] = Enum.filter(resumed.context.messages, &notice_marked?/1)
      assert text_of(notice) =~ "[RESUME]"
      assert text_of(notice) =~ "Interrupted tool calls: 2"
      refute resumed.pending_tool_batch
    end
  end

  describe "dirty resume and crash retry narration" do
    test "a dirty pause names the pause checkpoint and states uncommitted work is NOT preserved" do
      calls = [tool_call("c0", "read"), tool_call("c1", "bash")]

      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        dangling_assistant(calls)
      ]

      state = state(messages, resume_info: dirty_pause_info())

      {resumed, _log} = captured(fn -> Resume.apply(state) end)

      results = Enum.filter(resumed.context.messages, &(&1.role == :tool))
      assert Enum.map(results, & &1.tool_call_id) == ["c0", "c1"]

      texts = Map.new(results, &{&1.tool_call_id, text_of(&1)})
      assert texts["c0"] =~ "unavailable"
      assert texts["c1"] =~ "this shell command's outcome is UNKNOWN"
      assert texts["c1"] =~ "Do not blindly re-run destructive commands"

      assert count_notices(resumed) == 1
      [notice] = Enum.filter(resumed.context.messages, &notice_marked?/1)
      text = text_of(notice)

      assert text =~ "[RESUME]"
      assert text =~ "Interrupted tool calls: 2"
      # Dirty means the host restarted mid-flight: say so, and say the batch may
      # have partially executed.
      assert text =~ "PAUSED when the host restarted"
      assert text =~ "may be partially executed"
      # The honest worktree statement: only the checkpoint is guaranteed.
      assert text =~ "restored from commit pause1234, the last checkpointed commit"
      assert text =~ "uncommitted worktree changes from the interrupted run are NOT preserved"
      refute text =~ "recreated from the task's base commit"
    end

    test "a crash retry with a marker says one [RESUME] and names its salvage commit" do
      calls = [tool_call("c0", "read"), tool_call("c1", "write")]

      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        dangling_assistant(calls)
      ]

      state = state(messages, resume_info: crash_retry_info())

      {resumed, log} = captured(fn -> Resume.apply(state) end)

      # A crash retry is not a pause: no clean-pause wording, no clean-pause repair log.
      refute log =~ "clean-pause resume found an interrupted tool batch"

      results = Enum.filter(resumed.context.messages, &(&1.role == :tool))
      assert Enum.map(results, & &1.tool_call_id) == ["c0", "c1"]

      texts = Map.new(results, &{&1.tool_call_id, text_of(&1)})
      assert texts["c1"] =~ "partially written"
      assert texts["c1"] =~ "Inspect the target before writing it again"

      assert count_notices(resumed) == 1
      [notice] = Enum.filter(resumed.context.messages, &notice_marked?/1)
      text = text_of(notice)

      assert text =~ "[RESUME] The previous run of this agent was interrupted"
      assert text =~ "Resume attempt 3 of this agent run."
      assert text =~ "Interruption reason: crash."
      assert text =~ "Interrupted tool calls: 2"
      assert text =~ "restored from commit abc1234, the last checkpointed commit"
      assert text =~ "uncommitted worktree changes from the interrupted run are NOT preserved"
      # The subagent sentence belongs to a PAUSE resume only: a crash retry never
      # claims subagents were resumable.
      refute text =~ "is re-spawned and resumes from its own durable checkpoint"
      refute text =~ "Subagents:"
      refute text =~ "PAUSED when the host restarted"
    end

    test "a crash retry without a checkpoint falls back to the task base commit" do
      messages = [
        message(:system, "sys prompt"),
        message(:user, @objective),
        dangling_assistant([tool_call("c0", "bash")])
      ]

      state = state(messages, resume_info: crash_retry_info(worktree_resume_from: nil))

      {resumed, _log} = captured(fn -> Resume.apply(state) end)

      [notice] = Enum.filter(resumed.context.messages, &notice_marked?/1)
      text = text_of(notice)

      assert text =~ "recreated from the task's base commit"
      assert text =~ "the interrupted run's changes are NOT present"
      refute text =~ "the last checkpointed commit"

      # The unanswered shell call is still answered honestly.
      assert resumed.context.messages
             |> Enum.filter(&(&1.role == :tool))
             |> Enum.map(&text_of/1)
             |> Enum.any?(&(&1 =~ "this shell command's outcome is UNKNOWN"))
    end
  end

  ## resume_info shapes, exactly as `Setup.build_initial_state/3` builds them

  # A CLEAN pause resume restores, has no retry, and names the pause checkpoint
  # the worktree was based on.
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

  # A DIRTY pause resume: the row was recovered after a host restart, so it
  # repairs like a crash while keeping the pause explanation.
  defp dirty_pause_info(opts \\ []) do
    clean_pause_info()
    |> Map.put(:resume_kind, :dirty_pause)
    |> Map.put(:worktree_resume_from, Keyword.get(opts, :worktree_resume_from, "pause1234"))
  end

  # A crash retry's resume_info: retries and a reason, plus the salvage commit.
  defp crash_retry_info(opts \\ []) do
    %{
      restore_agent_state: true,
      restored: true,
      retries: 2,
      retry_reason: :crash,
      worktree_resume_from: Keyword.get(opts, :worktree_resume_from, "abc1234")
    }
  end

  ## State / conversation builders

  defp state(messages, opts) do
    calls = dangling_calls(messages)
    batch = Keyword.get(opts, :batch, ToolBatch.build(calls, @turn, subagent_modules()))

    struct!(
      State,
      agent_id: 7_880_000 + System.unique_integer([:positive]),
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      repo_id: "primary",
      repo_path: Keyword.get(opts, :repo_path),
      context: ReqLLM.Context.new(messages),
      task_id: "resume-narration-test",
      persistent_state: true,
      turn: @turn,
      pending_tool_batch: batch,
      resume_info: Keyword.get(opts, :resume_info, crash_retry_info())
    )
  end

  defp subagent_modules, do: StubAgent.subagent_modules()

  # The calls of a transcript whose LAST message is an assistant `tool_calls`
  # message — the batch the marker describes in a real run.
  defp dangling_calls(messages) do
    case List.last(messages) do
      %ReqLLM.Message{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
      _other -> []
    end
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

  defp notice_marked?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata),
    do: metadata[:resume_notice] == true

  defp notice_marked?(_message), do: false

  defp count_notices(%State{context: %ReqLLM.Context{messages: messages}}),
    do: Enum.count(messages, &notice_marked?/1)

  # Runs `fun` with its log captured (the repairing resume paths log at
  # `:warning`) and returns `{result, log}`.
  defp captured(fun) do
    log = capture_log(fn -> send(self(), {:logged_result, fun.()}) end)

    result =
      receive do
        {:logged_result, value} -> value
      after
        0 -> flunk("the captured call produced no result")
      end

    {result, log}
  end
end
