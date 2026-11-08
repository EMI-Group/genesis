defmodule EvoGit.Agent.CancelGraceTest do
  @moduledoc """
  Graceful-cancellation grace-period behavior for the agent Runner loop.

  Covers the runner-side contract of graceful cancellation (spec D2 + D3):
    - the ETS `cancel_requested` flag is drained at the top of `loop/1` and
      the agent enters cancel-grace (budget 3, no extra recovery message —
      the cancel message arrives via the pending_user_messages drain);
    - the `grace_turns_remaining` budget semantics: 3 for cancel-grace AND 3
      for turn-limit recovery (a real report window: a tool-calling turn does
      not finish the run, so one bounded final commit plus the tool-free report
      turn has to fit inside it);
    - the budget-aware grace hard-stop checks;
    - `maybe_recovery_auto_commit` fires on cancel-grace entry (shared with
      turn-limit recovery);
    - a plain-text reply with NO tool calls during cancel-grace finishes the
      run (committing the pending work into the reported commit), exactly as it
      does outside a grace period.

  `async: true` — the ETS-based tests seed ONE row in the app-global named
  `:evogit_agent_state` table under a per-test unique agent id from this file's
  own id range and delete exactly that row on exit; nothing is asserted about
  the table as a whole, so the writes are concurrent-safe. The end-to-end
  completion test drives `EvoGit.Agent.ToolDispatch.process_llm_response/6`
  against that own row and its own temp git repo; every other test is pure
  (`LoopState` structs / a per-test temp git repo).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Agent
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Runner
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  # An agent id NOTHING ever registers, so the "no ETS agent state" tests keep
  # observing a nil objective regardless of concurrently running modules. It
  # sits just below this file's unique-id range (9_900_000 + unique_integer).
  @absent_agent_id 9_899_999

  # Minimal LoopState builder (mirrors turn_limit_test.exs).
  defp state, do: state([])

  defp state(overrides) do
    %LoopState{
      agent_id: @absent_agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([])
    }
    |> struct(overrides)
  end

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp agent_state(overrides) do
    defaults = [
      context_node: context_node(),
      phylo_node: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    :ok
  end

  # Seeds an agent row under a UNIQUE id (this file's own range) and schedules
  # its deletion, so no concurrently running module can observe or clobber it.
  defp put_agent_state!(overrides \\ []) do
    agent_id = 9_900_000 + :erlang.unique_integer([:positive])
    :ok = Store.put_agent_state(agent_id, agent_state(overrides))
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
    agent_id
  end

  # Replicates `Runner`'s drain_and_inject_user_messages/1 (which is private):
  # drains pending messages via Store and appends them as turn-tagged user
  # messages into the context.
  defp inject_user_messages(%LoopState{} = state, messages) do
    Enum.reduce(messages, state, fn msg, st ->
      tagged = EvoGit.Agent.ContextBuilder.tag_message_turn(ReqLLM.Context.user(msg), st.turn)
      %{st | context: ReqLLM.Context.append(st.context, tagged)}
    end)
  end

  defp message_texts(%ReqLLM.Context{} = context) do
    Enum.map(context.messages, &message_text/1)
  end

  defp message_text(%ReqLLM.Message{} = msg) do
    case msg.content do
      parts when is_list(parts) ->
        Enum.map_join(parts, "", fn
          %ReqLLM.Message.ContentPart{text: t} -> t
          _ -> ""
        end)

      text when is_binary(text) ->
        text

      _ ->
        ""
    end
  end

  # Simulates the grace continue path: a turn ran and ended with
  # `{:continue, _}` (the turn did not finish the run). The continue call site
  # checks `grace_period_continue_failed?/1` and, when allowed, decrements
  # `grace_turns_remaining`. Returns `{:recovery_failed, turns_completed}` —
  # the number of grace turns that ran before the hard-stop.
  defp continue_until_fail(%LoopState{} = state, turns_completed) do
    if Agent.grace_period_continue_failed?(state) do
      {:recovery_failed, turns_completed + 1}
    else
      continue_until_fail(
        %{state | grace_turns_remaining: state.grace_turns_remaining - 1},
        turns_completed + 1
      )
    end
  end

  defp init_repo(dir) do
    System.cmd("git", ["init", "-q"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
    System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "# repo\n")
    {:ok, _} = EvoGit.Adapters.Git.add(dir, ".")
    {:ok, _} = EvoGit.Adapters.Git.commit(dir, "initial")
    {:ok, sha} = EvoGit.Adapters.Git.rev_parse(dir)
    sha
  end

  # An assistant reply carrying TEXT and NO tool calls — the shape a streamed
  # turn produces when the model finishes the run; its context already holds the
  # assistant message, which is what `process_llm_response/6` expects.
  defp text_response(text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)]
    }

    %ReqLLM.Response{
      id: "cancel-grace-response",
      model: "test:model",
      context: ReqLLM.Context.new([message]),
      message: message,
      usage: %{input_tokens: 11, output_tokens: 3}
    }
  end

  # ---------------------------------------------------------------------------
  # grace_period_continue_failed?/1 — budget-aware
  # ---------------------------------------------------------------------------

  describe "grace_period_continue_failed?/1 — budget-aware" do
    test "cancel-grace budget 3: continue is allowed (3 > 1)" do
      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 3)
             )
    end

    test "cancel-grace budget 2: continue is allowed (2 > 1)" do
      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 2)
             )
    end

    test "budget 1: continue fails recovery (the shared hard-stop boundary)" do
      assert Agent.grace_period_continue_failed?(
               state(in_grace_period: true, grace_turns_remaining: 1)
             )
    end

    test "budget 0 in grace (struct default): hard-stop, preserving legacy behavior" do
      # A state constructed with `in_grace_period: true` but no explicit budget
      # (grace_turns_remaining defaults to 0) must hard-stop — identical to the
      # pre-budget `in_grace_period: true → true`.
      assert Agent.grace_period_continue_failed?(state(in_grace_period: true))
    end

    test "not in grace: never fails, regardless of the counter" do
      refute Agent.grace_period_continue_failed?(state(in_grace_period: false))

      refute Agent.grace_period_continue_failed?(
               state(in_grace_period: false, grace_turns_remaining: 3)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Grace-turn budget semantics (exact turn counts)
  # ---------------------------------------------------------------------------

  describe "grace-turn budget semantics" do
    test "cancel-grace budget 3: exactly 3 grace turns then {:error, :recovery_failed}" do
      # Entering cancel-grace sets grace_turns_remaining = 3. Each turn that
      # ends with {:continue, _} (the run did not finish) decrements; the 3rd
      # continue hard-stops:
      #   turn 1 ends with continue (3 > 1) → allowed, decrement to 2
      #   turn 2 ends with continue (2 > 1) → allowed, decrement to 1
      #   turn 3 ends with continue (1 <= 1) → hard-stop
      assert {:recovery_failed, 3} ==
               continue_until_fail(
                 state(in_grace_period: true, grace_turns_remaining: 3),
                 0
               )
    end

    test "turn-limit budget 3: exactly 3 grace turns then {:error, :recovery_failed}" do
      # Turn-limit recovery grants the SAME 3-turn window as cancel-grace, so
      # the agent can still make its one bounded final commit AND deliver the
      # tool-free report (a tool-calling turn does not finish the run):
      #   turn 1 ends with continue (3 > 1) → allowed, decrement to 2
      #   turn 2 ends with continue (2 > 1) → allowed, decrement to 1
      #   turn 3 ends with continue (1 <= 1) → hard-stop
      assert {:recovery_failed, 3} ==
               continue_until_fail(
                 state(in_grace_period: true, grace_turns_remaining: 3),
                 0
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Cancel flag → cancel-grace entry (ETS integration)
  # ---------------------------------------------------------------------------

  describe "cancel_requested flag → cancel-grace entry" do
    test "flag set + cancel message pending → cancel-grace with budget 3, flag cleared, no extra message" do
      # The scheduler's own cancel message (one source of truth: no wording is
      # duplicated here — this test pins the drain/flag plumbing, not the text).
      cancel_message = EvoGit.AgentScheduler.cancel_message()

      agent_id =
        put_agent_state!(
          objective: "Original objective",
          pending_user_messages: [cancel_message],
          cancel_requested: true
        )

      # loop/1 drains pending user messages BEFORE the cancel check; replicate
      # that step so the cancel message is already in the context.
      drained =
        inject_user_messages(
          state(agent_id: agent_id),
          Store.drain_pending_user_messages(agent_id)
        )

      assert Enum.any?(message_texts(drained.context), &(&1 =~ cancel_message))

      {:cancel_grace, grace_state} = Runner.maybe_enter_cancel_grace(drained)

      assert grace_state.in_grace_period == true
      assert grace_state.grace_turns_remaining == 3

      # The ETS flag is cleared (the runner owns it — scheduler may re-set it
      # only for a later cancel request).
      refute Store.cancel_requested?(agent_id)

      # The cancel message is present in the context (from the drain)...
      assert Enum.any?(message_texts(grace_state.context), &(&1 =~ cancel_message))

      # ...and NO extra recovery message was appended by entering grace (the
      # message count is unchanged by enter_grace with message: nil).
      assert length(grace_state.context.messages) == length(drained.context.messages)
    end

    test "flag not set → :no_cancel (loop continues normally)" do
      agent_id = put_agent_state!()

      assert :no_cancel == Runner.maybe_enter_cancel_grace(state(agent_id: agent_id))
      refute Store.cancel_requested?(agent_id)
    end

    test "enter_grace with message: nil sets budget and appends nothing" do
      grace_state =
        Runner.enter_grace(state(context: ReqLLM.Context.new([])), "task cancelled",
          message: nil,
          grace_turns: 3
        )

      assert grace_state.in_grace_period == true
      assert grace_state.grace_turns_remaining == 3
      assert grace_state.context.messages == []
    end
  end

  # ---------------------------------------------------------------------------
  # Turn-limit recovery — 3-turn report window
  # ---------------------------------------------------------------------------

  describe "turn-limit recovery" do
    test "trigger_turn_limit_recovery?/1 unchanged (at limit, not in grace → true)" do
      assert Agent.trigger_turn_limit_recovery?(
               state(turn: 128, max_turns: 128, in_grace_period: false)
             )
    end

    test "trigger_turn_limit_recovery?/1 unchanged (in grace → false, no re-trigger)" do
      refute Agent.trigger_turn_limit_recovery?(
               state(turn: 128, max_turns: 128, in_grace_period: true)
             )
    end

    test "enter_grace default (turn-limit): the new message with budget 3" do
      # No ETS agent state → objective is nil → the no-objective message variant.
      grace_state = Runner.enter_grace(state(), "max turns (128) exceeded")

      assert grace_state.in_grace_period == true
      assert grace_state.grace_turns_remaining == 3

      [text] = message_texts(grace_state.context)
      assert text =~ "You have exceeded your turn budget (max turns (128) exceeded)."
      assert text =~ "You have 3 final turns left before this run stops immediately."

      # The ONE completion rule: a tool-free reply finishes the run; a
      # tool-calling turn does not.
      assert text =~ "a reply with NO tool calls ends the run, and its text IS the report"
      assert text =~ "A turn that ends with a tool call does NOT finish the run"

      # The terminal consequence of burning the window.
      assert text =~ "there will be NO report at all"

      # The one bounded final commit, and the safety of already-committed work.
      assert text =~ "at most ONE final commit"
      assert text =~ "Your already-committed work is safe"

      # The acceptable outcome: an honest partial report, not "one more fix".
      assert text =~
               "what was done (with the commit), what remains, and what a follow-up must pick up"

      assert text =~ "an honest partial report is exactly what is needed here"
      assert text =~ ~s(Never keep working toward "just one more fix".)

      # The false "work will be LOST" claim is gone.
      refute text =~ "LOST"

      refute text =~ "Your original objective was:"
    end

    test "the turn-limit budget is > 1 and strictly bounded" do
      # The production entry point grants a real report window (not a single
      # turn), and continuing without a tool-free reply always terminates:
      # a finite number of grace turns, then {:error, :recovery_failed}.
      grace_state = Runner.enter_grace(state(), "max turns (128) exceeded")

      assert grace_state.grace_turns_remaining > 1

      assert {:recovery_failed, turns_completed} = continue_until_fail(grace_state, 0)
      assert turns_completed == grace_state.grace_turns_remaining
      assert turns_completed <= 10
    end

    test "turn-limit message includes the objective when present" do
      agent_id = put_agent_state!(objective: "Refactor the parser")

      grace_state = Runner.enter_grace(state(agent_id: agent_id), "max turns (128) exceeded")

      [text] = message_texts(grace_state.context)
      assert text =~ "Your original objective was:\nRefactor the parser"
      assert text =~ "Your report MUST summarize the status of this ENTIRE objective"
    end

    test "objective variant: report what remains even if the objective cannot be completed" do
      agent_id = put_agent_state!(objective: "Refactor the parser")

      grace_state = Runner.enter_grace(state(agent_id: agent_id), "max turns (128) exceeded")

      [text] = message_texts(grace_state.context)
      assert grace_state.grace_turns_remaining == 3

      assert text =~ "You have exceeded your turn budget (max turns (128) exceeded)."
      assert text =~ "You have 3 final turns left before this run stops immediately."

      # The ONE completion rule, stated for the objective variant too.
      assert text =~ "a reply with NO tool calls ends the run, and its text IS the report"
      assert text =~ "A turn that ends with a tool call does NOT finish the run"
      assert text =~ "there will be NO report at all"

      # One bounded final commit; already-committed work is safe.
      assert text =~ "First turn: make at most ONE final commit"
      assert text =~ "Your already-committed work is safe"

      # The partial report is the ACCEPTABLE outcome of a bounded budget.
      assert text =~
               "If you cannot complete the entire objective, that is acceptable: stop and report what you did (with the commit), what remains, and what a follow-up must pick up."

      assert text =~ "Your original objective was:\nRefactor the parser"
      assert text =~ "Your report MUST summarize the status of this ENTIRE objective"
      refute text =~ "LOST"
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_recovery_auto_commit fires on cancel-grace entry (real git worktree)
  # ---------------------------------------------------------------------------

  describe "recovery auto-commit on cancel-grace entry" do
    test "dirty worktree is auto-committed when entering cancel-grace", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      File.write!(Path.join(tmp_dir, "uncommitted.txt"), "salvage me")

      Process.put(:repo_path, tmp_dir)
      on_exit(fn -> Process.delete(:repo_path) end)

      agent_id = put_agent_state!(cancel_requested: true)

      assert {:cancel_grace, grace_state} =
               Runner.maybe_enter_cancel_grace(state(agent_id: agent_id))

      assert grace_state.in_grace_period == true
      assert grace_state.grace_turns_remaining == 3

      # The dirty file was committed by the shared recovery auto-commit
      # (the same code path as turn-limit recovery).
      assert {:ok, ""} = EvoGit.Adapters.Git.status(tmp_dir)

      {:ok, log} = EvoGit.Adapters.Git.log(tmp_dir, ["--oneline", "-5"])
      assert log =~ "auto-commit: turn-limit recovery"
    end

    test "clean worktree is a no-op (no commit) on cancel-grace entry", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)

      Process.put(:repo_path, tmp_dir)
      on_exit(fn -> Process.delete(:repo_path) end)

      agent_id = put_agent_state!(cancel_requested: true)

      assert {:cancel_grace, _grace_state} =
               Runner.maybe_enter_cancel_grace(state(agent_id: agent_id))

      assert {:ok, ""} = EvoGit.Adapters.Git.status(tmp_dir)

      {:ok, log} = EvoGit.Adapters.Git.log(tmp_dir, ["--oneline", "-5"])
      refute log =~ "auto-commit"
    end
  end

  # ---------------------------------------------------------------------------
  # Plain-text completion (no tool calls) during cancel-grace
  # ---------------------------------------------------------------------------

  describe "plain-text completion during cancel-grace" do
    test "finishes the run and commits the pending work into the reported sha", %{
      tmp_dir: tmp_dir
    } do
      base_sha = init_repo(tmp_dir)
      # Dirty the workspace: finishing must commit it — a reply with no tool
      # calls IS the completion, so there is no workspace gate to trip.
      File.write!(Path.join(tmp_dir, "uncommitted.txt"), "salvage me")

      Process.put(:repo_path, tmp_dir)
      on_exit(fn -> Process.delete(:repo_path) end)

      agent_id =
        put_agent_state!(
          phylo_node: %PhyloGraphNode{
            repo: tmp_dir,
            base_commit: base_sha,
            current_commit: base_sha
          },
          objective: "Wrap up",
          task_local_id: 1,
          # No catalog-resolvable model: keeps this async test off the one-off
          # LLMDB catalog decode (`Threshold.for_model/2` only needs the
          # configured window).
          llm_model: nil
        )

      grace_state = state(agent_id: agent_id, in_grace_period: true, grace_turns_remaining: 3)

      assert {:ok, %EvoGit.Agent.Result{} = result} =
               ToolDispatch.process_llm_response(
                 text_response("wrapping up"),
                 grace_state,
                 [],
                 fn _state -> flunk("a completion must not re-enter the loop") end,
                 fn _state, _reason -> flunk("a completion must not trigger recovery") end,
                 "wrapping up"
               )

      assert result.result == "wrapping up"

      # The finish committed the pending work and reported THAT commit.
      assert {:ok, head} = EvoGit.Adapters.Git.rev_parse(tmp_dir)
      assert head == result.commit_sha
      refute result.commit_sha == base_sha

      assert {:ok, "salvage me"} =
               EvoGit.Adapters.Git.show(tmp_dir, "#{result.commit_sha}:uncommitted.txt")

      assert {:ok, ""} = EvoGit.Adapters.Git.status(tmp_dir)
    end
  end
end
