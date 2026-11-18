defmodule EvoGit.Agent.Resume.Notice do
  @moduledoc """
  The ONE resume notice a resumed agent receives.

  Two texts, selected by the resume KIND (`state.resume_info[:resume_kind]`):

    * `text/2` — the `[RESUME]` notice of an INTERRUPTED run: a crash retry
      (`:resume_kind` absent) and a `:dirty_pause` resume (the task was brought
      back by a restart, so the last tool batch may be partially executed). It
      accompanies the tool-result repair.
    * `pause_text/1` — the NEUTRAL notice of a `:clean_pause` resume: the user
      paused the task at a turn boundary and resumed it, nothing was
      interrupted, the worktree holds the pause checkpoint and NO repair runs.
      It is deliberately not framed `[RESUME]` and never says a file may be
      inconsistent.

  Both are appended ONCE at the top of the resumed exchange (see
  `EvoGit.Agent.Resume`), as a NEUTRAL `:user` message — harness text, never
  `EvoGit.Agent.MessageMarker`-marked as user-authored — so a display layer can
  tell them from a real user turn.

  ## Every claim degrades on a missing fact

  The dispatch context keys this notice reports (`:retries`, `:retry_reason`,
  `:worktree_resume_from`) are supplied by the scheduler retry/resume path and
  may be absent; each absent value DROPS its sentence instead of asserting a
  guess:

    * `:retries` — the count of retries already attempted for this run, so the
      notice states `attempt = retries + 1`; non-integer → no attempt sentence.
    * `:retry_reason` — free text (or an atom); `nil`/blank → no reason sentence.
    * `:worktree_resume_from` — the commit the worktree is actually based on (a
      pause checkpoint or a salvage commit); when present the notice names it as
      the ONE guaranteed state and says uncommitted worktree changes from the
      killed run are not preserved, when absent it says the worktree was
      recreated from the task base and the interrupted run's changes are NOT
      present.
    * the durable restore outcome — `false` adds one sentence saying the earlier
      turns are not in this transcript.

  A PAUSE resume (`:clean_pause` / `:dirty_pause`) additionally says subagents
  are NOT resumable after a restart: their processes are gone and a child's
  partial work survives only if it was already merged.

  Either text is stamped `metadata[:resume_notice] => true`, which is ALSO the
  exactly-once guard: a second resumed exchange never appends a second notice to
  the same transcript.

  Total and pure apart from reading `state`/`resume_info`; never raises.
  """

  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch

  @doc """
  The full `[RESUME]` notice TEXT for a resumed run of `state`, with `batch` the
  (already normalized) in-flight marker — `nil` when no tool batch was executing
  when the run stopped. A `:dirty_pause` resume adds the pause/restart context
  and the subagent sentence; a crash retry (`:resume_kind` absent) does not.
  """
  @spec text(State.t(), ToolBatch.t() | nil) :: String.t()
  def text(%State{} = state, batch) do
    info = resume_info(state)
    kind = pause_kind(state)

    ["[RESUME] The previous run of this agent was interrupted and is now resuming."]
    |> append(attempt_sentence(info))
    |> append(reason_sentence(info))
    |> append(restore_sentence(info))
    |> append(interrupted_sentence(batch))
    |> append(worktree_sentence(info))
    |> append(pause_sentence(kind))
    |> append(subagent_sentence(kind))
    |> append(guidance_sentence())
    |> Enum.join("\n\n")
  end

  @doc """
  The NEUTRAL notice TEXT of a `:clean_pause` resume: the user paused the task
  and resumed it, nothing was interrupted, and subagents are not resumable.

  The worktree clause states only what the resume can BACK: with a pause
  checkpoint commit on `resume_info` the tree is that commit's tree (the pause
  finalizer committed the whole worktree, untracked files included), and with no
  such fact the worktree was recreated from the task base, so only the restored
  conversation survives of the paused run's file changes. It never uses
  inconsistency wording.

  Total for any state; a restore that did not happen adds the
  restore-degradation sentence.
  """
  @spec pause_text(State.t()) :: String.t()
  def pause_text(%State{} = state) do
    info = resume_info(state)

    [
      "The user paused this task and has now resumed it. No tool call was interrupted#{worktree_clause(info)}."
    ]
    |> append(pause_base_sentence(info))
    |> append(restore_sentence(info))
    |> append(subagent_sentence(pause_kind(state)))
    |> Enum.join("\n\n")
  end

  @doc """
  The facts this notice is built from, for tests and callers that want to assert
  on them rather than on prose. Total: an absent `resume_info` yields nils.
  """
  @spec facts(State.t(), ToolBatch.t() | nil) :: map()
  def facts(%State{} = state, batch) do
    info = resume_info(state)

    %{
      retries: Map.get(info, :retries),
      attempt: attempt_number(info),
      retry_reason: Map.get(info, :retry_reason),
      worktree_resume_from: Map.get(info, :worktree_resume_from),
      restored: Map.get(info, :restored),
      resume_kind: pause_kind(state),
      interrupted_calls: length(ToolBatch.calls(batch)),
      class_counts: ToolBatch.class_counts(batch)
    }
  end

  ## Sentences

  defp attempt_sentence(info) do
    case attempt_number(info) do
      attempt when is_integer(attempt) -> "Resume attempt #{attempt} of this agent run."
      _none -> nil
    end
  end

  defp reason_sentence(info) do
    case reason_text(Map.get(info, :retry_reason)) do
      nil -> nil
      text -> "Interruption reason: #{text}."
    end
  end

  defp restore_sentence(info) do
    if Map.get(info, :restored) == false do
      "The previous conversation could NOT be restored from durable state, so earlier turns of " <>
        "this run are not present in this transcript."
    end
  end

  defp interrupted_sentence(batch) do
    case ToolBatch.calls(batch) do
      [] ->
        "No tool call was in flight when the run stopped."

      calls ->
        "Interrupted tool calls: #{length(calls)} (#{counts_text(ToolBatch.class_counts(batch))}). " <>
          "Their results are unavailable; each unanswered call now carries a synthetic tool " <>
          "result describing what may have happened."
    end
  end

  # A killed run's uncommitted worktree changes are NOT preserved: the resume
  # only has the commits the durable checkpoints anchored, so the sentence names
  # that commit as the ONE guaranteed state and tells the agent to verify the
  # files instead of assuming a half-written edit survived.
  defp worktree_sentence(info) do
    case Map.get(info, :worktree_resume_from) do
      sha when is_binary(sha) and sha != "" ->
        "Worktree: restored from commit #{sha}, the last checkpointed commit. Only that commit " <>
          "is guaranteed — uncommitted worktree changes from the interrupted run are NOT " <>
          "preserved, so inspect `git status` and the files themselves before assuming anything " <>
          "about them."

      _none ->
        "Worktree: recreated from the task's base commit, so the interrupted run's changes are " <>
          "NOT present — only what the durable checkpoints recorded survives."
    end
  end

  # The worktree half of the clean-pause sentence: the pause finalizer commits the
  # WHOLE worktree (`git add --all`) and anchors it, so a recorded checkpoint
  # makes "exactly as it was left" a fact this notice can back. Without one the
  # resume fell back to the task base and the clause is omitted, because there it
  # would be false.
  defp worktree_clause(info) do
    case Map.get(info, :worktree_resume_from) do
      sha when is_binary(sha) and sha != "" ->
        " and the worktree is exactly as it was left: it was recreated from the pause " <>
          "checkpoint commit #{sha}, which captured the work as it stood when the task was paused"

      _none ->
        ""
    end
  end

  defp pause_base_sentence(info) do
    case Map.get(info, :worktree_resume_from) do
      sha when is_binary(sha) and sha != "" ->
        nil

      _none ->
        "No pause checkpoint commit was recorded, so the worktree was recreated from the task's " <>
          "base commit: only the restored conversation remains of the paused run's file changes."
    end
  end

  # Only a `:dirty_pause` resume is a POST-RESTART pause; a plain crash retry
  # keeps today's wording exactly.
  defp pause_sentence(:dirty_pause) do
    "The task was PAUSED when the host restarted, so the run stopped mid-flight and the last " <>
      "tool batch may be partially executed."
  end

  defp pause_sentence(_kind), do: nil

  # A pause resume cannot restore subagent processes. Stated for BOTH pause kinds.
  defp subagent_sentence(kind) when kind in [:clean_pause, :dirty_pause] do
    "Subagents are NOT resumable after a restart: their processes are gone, and a child's " <>
      "partial work survives only if it was already merged into this worktree."
  end

  defp subagent_sentence(_kind), do: nil

  defp guidance_sentence do
    "Inspect the current state first: run `git status`, re-read the files you were modifying and " <>
      "call `job_list` for background jobs you started. Do not blindly re-run destructive " <>
      "commands — a shell command, write or edit may already have happened."
  end

  ## Facts

  defp resume_info(%State{resume_info: info}) when is_map(info), do: info
  defp resume_info(_state), do: %{}

  # `:clean_pause | :dirty_pause` for a task-level pause resume, `nil` otherwise
  # (the crash-retry path never sets the key).
  defp pause_kind(%State{} = state) do
    case Map.get(resume_info(state), :resume_kind) do
      kind when kind in [:clean_pause, :dirty_pause] -> kind
      _other -> nil
    end
  end

  # `:retries` is the count of retries already attempted, so the human-facing
  # attempt number is `retries + 1`.
  defp attempt_number(info) do
    case Map.get(info, :retries) do
      retries when is_integer(retries) and retries >= 0 -> retries + 1
      _none -> nil
    end
  end

  defp reason_text(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp reason_text(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp reason_text(nil), do: nil

  # Justified use of `inspect/1`: any other term (a tuple from the scheduler) is
  # still worth reporting verbatim, and `inspect/1` never raises.
  defp reason_text(reason), do: inspect(reason)

  defp counts_text([{class, count}]), do: "#{class} × #{count}"

  defp counts_text(counts),
    do: Enum.map_join(counts, ", ", fn {class, n} -> "#{class} × #{n}" end)

  defp append(sentences, nil), do: sentences
  defp append(sentences, sentence) when is_binary(sentence), do: sentences ++ [sentence]
end
