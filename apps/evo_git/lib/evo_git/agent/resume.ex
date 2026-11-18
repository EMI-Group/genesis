defmodule EvoGit.Agent.Resume do
  @moduledoc """
  Resume repair/narration: make a restored transcript provider-valid and tell
  the agent what happened.

  `apply/1,2` runs ONCE at the very top of `EvoGit.Agent.Exchange.run/2`, before
  the loop, and ONLY for a RESTORED RUN — `state.resume_info` says the dispatch
  ctx carried `restore_agent_state: true` (see
  `EvoGit.Agent.Session.Setup.build_initial_state/3`) and durable state is
  enabled. Every other run (a fresh agent, a resume/merge follow-up, an
  interactive session) passes through untouched.

  ## The resume KIND selects the narration (`resume_info[:resume_kind]`)

    * `nil` — a CRASH RETRY (today's semantics, byte-identical): repair + ONE
      `[RESUME]` notice.
    * `:dirty_pause` — a task-level pause resumed after a host restart: the
      SAME repair and ONE `[RESUME]` notice (it additionally states the pause
      happened and what the whole-tree resume does with the subagents).
    * `:clean_pause` — the user paused the task at a turn boundary and resumed
      it: the conversation is restored with **NO repair** (nothing was
      interrupted, so no `tool_calls` tail is dangling — see `dangling/1` and
      `clean_pause_intact?/1`) and ONE neutral pause/resume notice instead of
      `[RESUME]` (`Resume.Notice`). A clean pause whose durable state DOES prove
      an interruption (a non-empty `pending_tool_batch` or a dangling tail) is
      repaired and narrated as an interruption instead — the transcript, never
      the pause label, is the truth.

  ## Two steps, both driven by transcript SHAPE (the repairing kinds)

  The in-flight marker (`state.pending_tool_batch`) supplies PROVENANCE (which
  turn, which calls, which classes); the transcript supplies the TRUTH (is a
  tool call actually unanswered):

  1. **Repair** — when the LAST message is an assistant message carrying
     `tool_calls` and no `:tool` answers followed it, append ONE synthetic
     `:tool` message per unanswered call, in the assistant's call order, built
     with the same `EvoGit.Agent.ToolDispatch.assemble_tool_result/3` and
     turn-tagged exactly like a real result. The content is class-specific and
     honest (`EvoGit.Agent.Resume.ToolBatch`); without it the next provider call
     rejects the unpaired `tool_call_id` (HTTP 400 → `EvoGit.Agent.LlmError`
     fail-fast → a `:failed` task).
     A `:subagent` call is the ONE class whose real answer may still arrive: the
     interrupted batch is re-attached with ONE
     `EvoGit.AgentScheduler.reattach_sub_agents/2` call for the WHOLE batch
     (`EvoGit.Agent.Resume.Reattach`), so a surviving child's real, formatted
     result is used instead of the fallback text and its same-repo commit is
     merged into the parent worktree. When NO in-memory batch survived (a
     scheduler/BEAM restart wipes the ETS batch), the same module rebuilds it
     from the children's DURABLE rows (`EvoGit.Agent.Resume.RosterBatch`):
     finished children contribute their stored results and still-running ones
     are re-spawned under their persisted ids with their own anchored base,
     branch and restored conversation — recursively down the tree.
  2. **Notice** — append ONE `[RESUME]`-framed, NON-user-authored `:user`
     message (`EvoGit.Agent.Resume.Notice`) stating the interruption, the
     interrupted calls and their classes, the worktree situation and how to
     proceed.

  ## Hard invariants

    * NEVER touches the system message or the first user message — the prompt
      cache prefix must stay byte-identical across a resume.
    * TOTAL except for the ONE deliberate, bounded and fully guarded scheduler
      re-attach call: no raises, no LLM call; every failure of the re-attach, the
      formatting or the merge degrades to the honest fallback text with a
      `:warning`, so a repair can never crash the exchange.
    * At most ONE notice per resumed run: the notice carries
      `metadata[:resume_notice]` and an existing one short-circuits the append
      (a transcript restored from a previous resume already contains it).
    * `persistent_state: false` is FULLY inert — no repair, no notice, no
      marker write.
    * The marker is always CLEARED by the time this returns: repair exists to
      close it.
  """

  # `apply/2` is the public option-taking entry point; Kernel's would clash.
  import Kernel, except: [apply: 2]

  require Logger

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Resume.Notice
  alias EvoGit.Agent.Resume.Reattach
  alias EvoGit.Agent.Resume.ToolBatch, as: Impact
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.ToolDispatch

  @notice_key :resume_notice

  @doc """
  Repairs and annotates a resumed state; a no-op for every other state.

  Total: a malformed state/context returns the state unchanged.
  """
  @spec apply(State.t()) :: State.t()
  def apply(%State{} = state), do: apply(state, [])

  def apply(state), do: state

  @doc """
  Repairs and annotates a resumed state, with the resume-path options.

  A `:clean_pause` resume appends ONE neutral pause/resume notice and runs NO
  repair (nothing was interrupted); every other resume kind (`nil` = crash
  retry, `:dirty_pause` = post-restart pause) repairs the dangling tail and
  appends ONE `[RESUME]` notice.

  Options (each an explicit injection point, never app env):

    * `:reattach_fun` — `fn agent_id, expected_count -> reply` used to re-attach
      the interrupted subagent batch; defaults to
      `&EvoGit.AgentScheduler.reattach_sub_agents/2`;
    * `:rebuild_fun` — `fn agent_id, plan, opts -> reply` used to install a batch
      rebuilt from the durable rows when no in-memory batch survived; defaults
      to `&EvoGit.AgentScheduler.rebuild_subagent_batch/3`;
    * `:roster_fun` — the durable roster read the rebuild plan is built from
      (`EvoGit.Agent.Resume.RosterBatch`); defaults to
      `&EvoGit.AgentState.roster/1`;
    * `:spawn_fun` — the scheduler-side spawn seam the rebuild passes through
      (`EvoGit.AgentScheduler.SubagentRebuild`);
    * `:turn` — set by `apply/2` itself from `dangling/1`; the parent turn whose
      `tool_calls` are being answered.

  Total for any option value.
  """
  @spec apply(State.t(), keyword()) :: State.t()
  def apply(%State{} = state, opts) when is_list(opts) do
    cond do
      not crash_retry?(state) ->
        state

      clean_pause?(state) and clean_pause_intact?(state) ->
        state |> annotate_pause() |> clear_marker()

      true ->
        batch = ToolBatch.normalize(state.pending_tool_batch)
        state = %{state | pending_tool_batch: batch}
        state |> repair(batch, opts) |> annotate(batch) |> clear_marker()
    end
  end

  def apply(state, _opts), do: state

  @doc """
  True when this state is a `:clean_pause` resume: the user paused the task at a
  turn boundary, so nothing was interrupted. Total.

  It is only ONE half of the clean-pause decision — `Resume.apply/2` additionally
  requires the transcript to be intact (`EvoGit.Agent.ToolBatch.calls/1` of the
  marker empty AND no dangling `tool_calls` tail): a durable state that proves
  something WAS interrupted is repaired and narrated as an interruption, never
  silently declared clean.
  """
  @spec clean_pause?(State.t()) :: boolean()
  def clean_pause?(%State{} = state), do: resume_kind(state) == :clean_pause

  def clean_pause?(_state), do: false

  @doc """
  The task-level PAUSE resume kind of this state: `:clean_pause` (paused by the
  user at a turn boundary), `:dirty_pause` (paused by a host restart) or `nil`
  (the crash-retry path, which never sets the key). Total.
  """
  @spec resume_kind(State.t()) :: :clean_pause | :dirty_pause | nil
  def resume_kind(%State{resume_info: %{} = info}) do
    case Map.get(info, :resume_kind) do
      kind when kind in [:clean_pause, :dirty_pause] -> kind
      _other -> nil
    end
  end

  def resume_kind(_state), do: nil

  @doc """
  True when this state is a RESTORED RUN: the durable restore was requested by
  the dispatch ctx AND persistent state is enabled for the task.

  Both a crash retry and a task-level pause resume answer `true` — the resume
  KIND (`resume_kind/1`) decides whether anything is repaired or only narrated.
  A `resume_info` map that is absent/malformed, a `restore_agent_state` that is
  not `true`, or `persistent_state: false` all answer `false`.
  """
  @spec crash_retry?(State.t()) :: boolean()
  def crash_retry?(%State{persistent_state: true, resume_info: %{} = info}),
    do: Map.get(info, :restore_agent_state) == true

  def crash_retry?(_state), do: false

  @doc """
  Clears the in-flight marker. `nil` is already clear, so this is a plain (and
  total) field write used by every path that stops executing a batch.
  """
  @spec clear_marker(State.t()) :: State.t()
  def clear_marker(%State{pending_tool_batch: nil} = state), do: state
  def clear_marker(%State{} = state), do: %{state | pending_tool_batch: nil}
  def clear_marker(state), do: state

  @doc """
  The unanswered tool calls of the FINAL assistant message, or `:none`.

  Returns `{:ok, turn, calls}` where `calls` are the `%ReqLLM.ToolCall{}`
  structs with no following `:tool` message, in the assistant's call order, and
  `turn` is the turn to tag the synthetic results with (the assistant message's
  own `metadata[:turn]` when present, else `state.turn`). Only a DANGLING TAIL is
  repairable: if anything follows the assistant message (or the last message is
  not an assistant with tool calls), there is nothing to answer in place.

  Total — a malformed context answers `:none`.
  """
  @spec dangling(State.t()) :: {:ok, integer() | nil, [term()]} | :none
  def dangling(%State{context: %ReqLLM.Context{messages: messages}} = state)
      when is_list(messages) and messages != [] do
    case List.last(messages) do
      %ReqLLM.Message{role: :assistant, tool_calls: calls} = message
      when is_list(calls) and calls != [] ->
        {:ok, message_turn(message, state), calls}

      _other ->
        :none
    end
  end

  def dangling(_state), do: :none

  @doc """
  True when the transcript already carries a `[RESUME]` notice (the
  exactly-once guard). Total.
  """
  @spec notice_present?(term()) :: boolean()
  def notice_present?(%ReqLLM.Context{messages: messages}) when is_list(messages) do
    Enum.any?(messages, &notice_marked?/1)
  end

  def notice_present?(_context), do: false

  ## Repair

  defp repair(%State{} = state, batch, opts) do
    case dangling(state) do
      {:ok, turn, calls} ->
        # ONE re-attach request for the WHOLE interrupted batch: the subagent
        # calls are collected in MODEL CALL ORDER (slot position ↔ sub-agent
        # index) and answered together. The TURN travels with it because the
        # durable rebuild (`EvoGit.Agent.Resume.RosterBatch`, used when no
        # in-memory batch survived) identifies the children by the parent turn
        # that spawned them.
        classified = classify(calls, batch, state)

        reattach =
          Reattach.resolve(state, subagent_slots(classified), Keyword.put(opts, :turn, turn))

        results =
          classified
          |> Enum.map(&synthetic_result(&1, reattach))
          |> Enum.map(&ContextBuilder.tag_message_turn(&1, turn))

        state = %{state | context: ReqLLM.Context.append(state.context, results)}

        append_merge_note(state, turn, reattach)

      :none ->
        state
    end
  end

  # One entry per unanswered call: `{model_call_index, call, class}`.
  defp classify(calls, batch, state) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} -> {index, call, class_for(call, batch, state)} end)
  end

  defp subagent_slots(classified) do
    for {index, call, :subagent} <- classified, do: {index, call}
  end

  defp synthetic_result({index, call, class}, reattach) do
    text = Map.get(reattach.texts, index) || Impact.impact(class, call)
    ToolDispatch.assemble_tool_result(call_id(call), call_name(call), text)
  end

  # The merge outcome is reported the way the spawn path reports it: ONE
  # `:user` note AFTER the tool results. It is harness text, never
  # `MessageMarker`-flagged as user-authored.
  defp append_merge_note(%State{} = state, turn, %{merge_note: note})
       when is_binary(note) and note != "" do
    message = ContextBuilder.build_injected_message(note, turn)
    %{state | context: ReqLLM.Context.append(state.context, message)}
  end

  defp append_merge_note(state, _turn, _reattach), do: state

  # Provenance: prefer the marker entry for the SAME provider id, then the entry
  # at the SAME index; when the marker is absent (a crash outside a batch) the
  # class is re-derived from the call name.
  defp class_for(call, batch, state) do
    case marker_class(call, batch) do
      nil -> ToolBatch.class(call_name(call), agent_subagent_modules(state))
      class -> class
    end
  end

  defp marker_class(call, batch) do
    entries = ToolBatch.calls(batch)
    id = call_id(call)

    by_id =
      if is_binary(id) do
        Enum.find(entries, fn entry -> entry.id == id end)
      end

    case by_id || by_index(call, entries) do
      %{class: class} -> class
      nil -> nil
    end
  end

  defp by_index(call, entries) do
    case call_index(call) do
      nil -> nil
      index -> Enum.find(entries, fn entry -> entry.index == index end)
    end
  end

  defp call_index(%ReqLLM.ToolCall{}), do: nil
  defp call_index(call) when is_map(call), do: Map.get(call, :index)
  defp call_index(_call), do: nil

  defp agent_subagent_modules(%State{agent_module: module}) when is_atom(module) do
    if function_exported?(module, :subagent_modules, 0) do
      module.subagent_modules()
    else
      []
    end
  end

  defp agent_subagent_modules(_state), do: []

  # A clean pause stops at a TURN BOUNDARY, so an intact transcript is the whole
  # contract: no in-flight marker and no unanswered `tool_calls` tail. Anything
  # else means the durable state proves an interruption the pause kind denies, so
  # the caller takes the repair path instead (repairing a dangling tail is also
  # what keeps the next provider call valid).
  defp clean_pause_intact?(%State{} = state) do
    calls_empty? = ToolBatch.calls(state.pending_tool_batch) == []

    if calls_empty? and dangling(state) == :none do
      true
    else
      Logger.warning(
        "Agent #{inspect(state.agent_id)}: clean-pause resume found an interrupted tool batch " <>
          "in the durable state; repairing it as an interruption"
      )

      false
    end
  end

  ## Notice

  # A CLEAN pause resume: the conversation is restored verbatim (no repair) and
  # ONE neutral notice explains the pause. Nothing is asserted about files being
  # inconsistent — nothing was interrupted.
  defp annotate_pause(%State{} = state) do
    if notice_present?(state.context) or not repair_target?(state) do
      state
    else
      message =
        state
        |> Notice.pause_text()
        |> ContextBuilder.build_injected_message(state.turn)
        |> mark_notice()

      %{state | context: ReqLLM.Context.append(state.context, message)}
    end
  end

  defp annotate(%State{} = state, batch) do
    if notice_present?(state.context) or not repair_target?(state) do
      state
    else
      message =
        state
        |> Notice.text(batch)
        |> ContextBuilder.build_injected_message(state.turn)
        |> mark_notice()

      %{state | context: ReqLLM.Context.append(state.context, message)}
    end
  end

  # The notice is part of the crash-resume contract, so it is appended whenever
  # the state is a crash retry with a usable context.
  defp repair_target?(%State{context: %ReqLLM.Context{}}), do: true
  defp repair_target?(_state), do: false

  defp mark_notice(%ReqLLM.Message{} = message) do
    %{message | metadata: Map.put(message.metadata || %{}, @notice_key, true)}
  end

  defp notice_marked?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, @notice_key) == true

  defp notice_marked?(_message), do: false

  ## Call accessors (total: a restored transcript may carry plain maps)

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(call) when is_map(call), do: Map.get(call, :id) || Map.get(call, "id")
  defp call_id(_call), do: nil

  defp call_name(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.name(call)
  defp call_name(call) when is_map(call), do: Map.get(call, :name) || Map.get(call, "name")
  defp call_name(_call), do: nil

  defp message_turn(%ReqLLM.Message{metadata: metadata}, %State{turn: state_turn}) do
    case is_map(metadata) && Map.get(metadata, :turn) do
      turn when is_integer(turn) -> turn
      _none -> state_turn
    end
  end
end
