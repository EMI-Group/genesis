defmodule EvoGit.Agent.Resume.Notice do
  @moduledoc """
  The ONE `[RESUME]` notice a crash-resumed agent receives.

  Appended once at the top of the resumed exchange (see
  `EvoGit.Agent.Resume`), as a NEUTRAL `:user` message — harness text, never
  `EvoGit.Agent.MessageMarker`-marked as user-authored — so a display layer can
  tell it from a real user turn.

  ## Every claim degrades on a missing fact

  The dispatch context keys this notice reports (`:retries`, `:retry_reason`,
  `:worktree_resume_from`) are supplied by the scheduler crash-retry path and may
  be absent; each absent value DROPS its sentence instead of asserting a guess:

    * `:retries` — the count of retries already attempted for this run, so the
      notice states `attempt = retries + 1`; non-integer → no attempt sentence.
    * `:retry_reason` — free text (or an atom); `nil`/blank → no reason sentence.
    * `:worktree_resume_from` — the commit the worktree was restored from; when
      present the notice says partial work may remain, when absent it says the
      worktree was recreated from the task base and the interrupted run's
      changes are NOT present.
    * the durable restore outcome — `false` adds one sentence saying the earlier
      turns are not in this transcript.

  The notice is framed `[RESUME]` and stamped `metadata[:resume_notice] => true`,
  which is ALSO the exactly-once guard: a second resumed exchange never appends a
  second notice to the same transcript.

  Total and pure apart from reading `state`/`resume_info`; never raises.
  """

  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch

  @doc """
  The full notice TEXT for a resumed run of `state`, with `batch` the (already
  normalized) in-flight marker — `nil` when no tool batch was executing when the
  run stopped.
  """
  @spec text(State.t(), ToolBatch.t() | nil) :: String.t()
  def text(%State{} = state, batch) do
    info = resume_info(state)

    ["[RESUME] The previous run of this agent was interrupted and is now resuming."]
    |> append(attempt_sentence(info))
    |> append(reason_sentence(info))
    |> append(restore_sentence(info))
    |> append(interrupted_sentence(batch))
    |> append(worktree_sentence(info))
    |> append(guidance_sentence())
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

  defp worktree_sentence(info) do
    case Map.get(info, :worktree_resume_from) do
      sha when is_binary(sha) and sha != "" ->
        "Worktree: restored from commit #{sha} and it may still hold partial or uncommitted " <>
          "work from the interrupted run."

      _none ->
        "Worktree: recreated from the task's base commit, so the interrupted run's changes are " <>
          "NOT present — anything not committed before the interruption is lost."
    end
  end

  defp guidance_sentence do
    "Inspect the current state first: run `git status`, re-read the files you were modifying and " <>
      "call `job_list` for background jobs you started. Do not blindly re-run destructive " <>
      "commands — a shell command, write or edit may already have happened."
  end

  ## Facts

  defp resume_info(%State{resume_info: info}) when is_map(info), do: info
  defp resume_info(_state), do: %{}

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
