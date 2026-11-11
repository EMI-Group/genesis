defmodule EvoGit.TaskControl.Observation do
  @moduledoc """
  Bounded, read-only observations of a task and its scheduler records.

  Activity contains recorded counters, not an inferred operation or progress
  estimate. The scheduler has no reliable last-activity timestamp. An empty
  agent list does not imply completion; `saved_state.status` remains the saved
  task status. `scheduler_available` means both scheduler ETS tables could be
  read, not that an agent or the scheduler process has answered a health probe.
  `registered_agent_count` counts scheduler entries, including pending agents.
  Up to 20 agents are displayed, with text fields limited to 240 characters.
  Counts include omitted agents. Elapsed seconds use the saved finish time;
  a terminal task without that time has an unknown (`nil`) duration.

  `change_token` identifies the saved task outcome and observed agent content,
  including agents omitted from the displayed list. It excludes the observation
  clock and elapsed duration, so time passing alone does not signal progress.
  No prompts, conversation contents, task logs, tool arguments, or result/error
  bodies are returned.
  """

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.TaskInfo

  @agent_limit 20
  @text_limit 240
  @terminal [:completed, :failed, :cancelled]
  @usage_keys ~w(input_tokens output_tokens total_tokens total_cost)a
  @saved_keys ~w(status started_at finished_at agent_count model_id review_status base_sha commit_sha branch_name usage result error)a

  @spec snapshot(TaskInfo.t()) :: map()
  def snapshot(%TaskInfo{} = task) do
    now = DateTime.utc_now()
    {available, agents} = agents(task.id)

    content = %{
      report: message_states(task.progress, agents, available),
      scheduler_available: available,
      registered_agent_count: length(agents),
      agent_status_counts: Enum.frequencies_by(agents, & &1.status),
      agents: Enum.take(agents, @agent_limit),
      agents_omitted: max(length(agents) - @agent_limit, 0),
      saved_state: %{
        status: text(task.status),
        started_at: timestamp(task.started_at),
        finished_at: timestamp(task.finished_at),
        agent_count: number(task.agent_count),
        model_id: text(task.model_id),
        review_status: text(task.review_status),
        has_result: not is_nil(task.result),
        has_error: not is_nil(task.error),
        usage: usage(task.usage)
      }
    }

    # Saved outcome bodies affect change detection without being exposed. Lease
    # renewals, process refs and logs do not constitute public task progress.
    token = digest({content, agents, Map.take(task, @saved_keys)})

    Map.merge(content, %{
      observed_at: DateTime.to_iso8601(now),
      elapsed_seconds: elapsed(task, now),
      change_token: token
    })
  end

  defp agents(task_id) do
    available = tables_available?()

    agents =
      RemoteAPI.list_agents()
      |> Enum.filter(&(is_binary(task_id) and &1.task_id == task_id))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&agent/1)

    {available and tables_available?(), agents}
  rescue
    # ETS can disappear between check and read, or a scheduler record can be
    # unreadable by RemoteAPI's typed summary builder. Neither changes the
    # independently saved task status.
    _error in [ArgumentError, FunctionClauseError] -> {false, []}
  end

  defp tables_available? do
    :ets.whereis(:evogit_sched_meta) != :undefined and
      :ets.whereis(:evogit_agent_state) != :undefined
  end

  defp message_states(nil, _, _), do: nil

  defp message_states(report, agents, available) do
    ids = MapSet.new(agents, & &1.id)

    if not Map.has_key?(report, "messages"),
      do: report,
      else:
        Map.update!(report, "messages", fn messages ->
          Enum.map(messages, fn receipt ->
            if receipt["state"] == "queued" and
                 (not available or not MapSet.member?(ids, receipt["agent_id"])),
               do: Map.put(receipt, "state", "unknown"),
               else: receipt
          end)
        end)
  end

  defp agent(summary) do
    # This is an ETS read, with context removed by RemoteAPI. No message is sent
    # to the agent process, even when that process is blocked in a long call.
    state = RemoteAPI.get_agent_state(summary.id)

    %{
      id: summary.id,
      task_local_id: number(summary.task_local_id),
      parent_id: number(summary.parent_id),
      status: text(summary.status),
      depth: number(summary.depth),
      model_id: text(summary.model_id),
      objective: text(summary.objective),
      activity: %{
        phase: if(state && state.activity, do: state.activity.phase),
        tools: if(state && state.activity, do: state.activity.tools, else: []),
        updated_at: if(state && state.activity, do: state.activity.updated_at),
        turn: if(state, do: number(state.turn)),
        message_count: number(summary.message_count),
        total_tokens: number(summary.total_tokens),
        tokens_since_compression: number(summary.total_tokens),
        cumulative_usage: usage((state && state.usage) || %{}),
        compression_count: number(summary.compression_count),
        retries: number(summary.retries),
        current_commit: text(summary.current_commit)
      }
    }
  end

  defp elapsed(%{status: status, finished_at: nil}, _) when status in @terminal, do: nil

  defp elapsed(%{started_at: %DateTime{} = started, finished_at: finished}, now) do
    ending = if match?(%DateTime{}, finished), do: finished, else: now
    max(DateTime.diff(ending, started, :second), 0)
  end

  defp elapsed(_, _), do: nil

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_), do: nil

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: value |> Atom.to_string() |> text()
  defp text(value) when is_binary(value), do: String.slice(value, 0, @text_limit)
  defp text(_), do: nil

  defp number(value) when is_number(value), do: value
  defp number(_), do: nil

  defp usage(value) when is_map(value) do
    Map.new(@usage_keys, fn key -> {key, number(Map.get(value, key))} end)
  end

  defp usage(_), do: nil

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
