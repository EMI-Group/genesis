defmodule EvoGit.Agent.CancelGraceTest do
  # Graceful-cancellation grace-period behavior for the agent Runner loop.
  #
  # Covers the runner-side contract of graceful cancellation (spec D2 + D3):
  #   - the ETS `cancel_requested` flag is drained at the top of `loop/1` and
  #     the agent enters cancel-grace (budget 3, no extra recovery message —
  #     the cancel message arrives via the pending_user_messages drain);
  #   - the `grace_turns_remaining` budget semantics: 3 for cancel, 1 for
  #     turn-limit (which keeps its exact pre-budget behavior);
  #   - the budget-aware grace hard-stop checks;
  #   - `maybe_recovery_auto_commit` fires on cancel-grace entry (shared with
  #     turn-limit recovery);
  #   - `complete_task` during cancel-grace succeeds with a dirty workspace
  #     (the grace dirty-check skip).
  #
  # `async: false` because the ETS-based tests manipulate the global named
  # `:evogit_agent_state` / `:evogit_sched_meta` tables (same convention as
  # `agent_scheduler/store_test.exs`).
  use ExUnit.Case, async: false

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

  # Minimal LoopState builder (mirrors turn_limit_test.exs).
  defp state, do: state([])

  defp state(overrides) do
    %LoopState{
      agent_id: 1,
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

  defp agent_state(overrides \\ []) do
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

  defp clear_ets do
    [:evogit_agent_state, :evogit_sched_meta, :evogit_archive_records]
    |> Enum.each(fn name ->
      if :ets.whereis(name) != :undefined, do: :ets.delete_all_objects(name)
    end)
  end

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_archive_records)
    clear_ets()
    on_exit(fn -> clear_ets() end)
    :ok
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
  # `{:continue, _}` (no complete_task). The continue call site checks
  # `grace_period_continue_failed?/1` and, when allowed, decrements
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

    test "budget 1: continue fails recovery (hard-stop, turn-limit parity)" do
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
      # ends with {:continue, _} (no complete_task) decrements; the 3rd
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

    test "turn-limit budget 1: exactly 1 grace turn then {:error, :recovery_failed}" do
      # Turn-limit recovery keeps its exact pre-budget behavior: enter grace,
      # one continue attempt → hard-stop.
      assert {:recovery_failed, 1} ==
               continue_until_fail(
                 state(in_grace_period: true, grace_turns_remaining: 1),
                 0
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Cancel flag → cancel-grace entry (ETS integration)
  # ---------------------------------------------------------------------------

  describe "cancel_requested flag → cancel-grace entry" do
    test "flag set + cancel message pending → cancel-grace with budget 3, flag cleared, no extra message" do
      agent_id = 1

      cancel_message =
        "The task is being cancelled. Please wrap up and call complete_task with your best answer."

      Store.put_agent_state(
        agent_id,
        agent_state(
          objective: "Original objective",
          pending_user_messages: [cancel_message],
          cancel_requested: true
        )
      )

      # loop/1 drains pending user messages BEFORE the cancel check; replicate
      # that step so the cancel message is already in the context.
      drained = inject_user_messages(state(), Store.drain_pending_user_messages(agent_id))

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
      Store.put_agent_state(agent_id = 1, agent_state())

      assert :no_cancel == Runner.maybe_enter_cancel_grace(state())
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
  # Turn-limit recovery — byte-for-byte parity
  # ---------------------------------------------------------------------------

  describe "turn-limit recovery parity" do
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

    test "enter_grace default (turn-limit): appends the exact standard message, budget 1" do
      # No ETS agent state → objective is nil → the no-objective message variant.
      grace_state = Runner.enter_grace(state(), "max turns (128) exceeded")

      assert grace_state.in_grace_period == true
      assert grace_state.grace_turns_remaining == 1

      [text] = message_texts(grace_state.context)
      assert text =~ "You have exceeded the execution limit (max turns (128) exceeded)."
      assert text =~ "Your priority is to call `complete_task` NOW with your best answer"
      assert text =~ "Your already-committed work is safe."
      refute text =~ "Your original objective was:"
    end

    test "turn-limit message includes the objective when present (byte-for-byte parity)" do
      Store.put_agent_state(1, agent_state(objective: "Refactor the parser"))

      grace_state = Runner.enter_grace(state(), "max turns (128) exceeded")

      [text] = message_texts(grace_state.context)
      assert text =~ "Your original objective was:\nRefactor the parser"
      assert text =~ "Your report MUST summarize the status of this ENTIRE objective"
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

      Store.put_agent_state(1, agent_state(cancel_requested: true))

      assert {:cancel_grace, grace_state} = Runner.maybe_enter_cancel_grace(state())
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

      Store.put_agent_state(1, agent_state(cancel_requested: true))

      assert {:cancel_grace, _grace_state} = Runner.maybe_enter_cancel_grace(state())

      assert {:ok, ""} = EvoGit.Adapters.Git.status(tmp_dir)

      {:ok, log} = EvoGit.Adapters.Git.log(tmp_dir, ["--oneline", "-5"])
      refute log =~ "auto-commit"
    end
  end

  # ---------------------------------------------------------------------------
  # complete_task during cancel-grace (grace dirty-check skip)
  # ---------------------------------------------------------------------------

  describe "complete_task during cancel-grace" do
    test "succeeds with a dirty workspace (grace dirty-check skip)", %{tmp_dir: tmp_dir} do
      base_sha = init_repo(tmp_dir)
      # Dirty the workspace — normally complete_task would refuse and return
      # {:continue, ...} with a dirty-warning tool result.
      File.write!(Path.join(tmp_dir, "uncommitted.txt"), "dirty")

      Process.put(:repo_path, tmp_dir)
      on_exit(fn -> Process.delete(:repo_path) end)

      Store.put_agent_state(
        1,
        agent_state(
          phylo_node: %PhyloGraphNode{
            repo: tmp_dir,
            base_commit: base_sha,
            current_commit: base_sha
          },
          objective: "Wrap up",
          task_local_id: 1
        )
      )

      complete_call =
        ReqLLM.ToolCall.new("call_complete", "complete_task", ~s({"result":"wrapping up"}))

      grace_state = state(in_grace_period: true, grace_turns_remaining: 3)

      assert {:complete, %EvoGit.Agent.Result{result: "wrapping up"}} =
               ToolDispatch.handle_complete_call(complete_call, grace_state, [complete_call])
    end

    test "without grace, a dirty workspace returns {:continue, _} with the dirty warning", %{
      tmp_dir: tmp_dir
    } do
      base_sha = init_repo(tmp_dir)
      File.write!(Path.join(tmp_dir, "uncommitted.txt"), "dirty")

      Process.put(:repo_path, tmp_dir)
      on_exit(fn -> Process.delete(:repo_path) end)

      Store.put_agent_state(
        1,
        agent_state(
          phylo_node: %PhyloGraphNode{
            repo: tmp_dir,
            base_commit: base_sha,
            current_commit: base_sha
          }
        )
      )

      complete_call =
        ReqLLM.ToolCall.new("call_complete", "complete_task", ~s({"result":"wrapping up"}))

      non_grace_state = state(in_grace_period: false)

      assert {:continue, tool_responses, nil} =
               ToolDispatch.handle_complete_call(complete_call, non_grace_state, [complete_call])

      combined = Enum.map_join(tool_responses, " ", &message_text/1)
      assert combined =~ "uncommitted changes"
    end
  end
end
