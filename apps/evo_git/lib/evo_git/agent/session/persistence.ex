defmodule EvoGit.Agent.Session.Persistence do
  @moduledoc """
  The ONE module that knows BOTH `%EvoGit.Agent.State{}` and `EvoGit.AgentState`.

  This is the durable-state hot path of an agent run: it translates the
  session-owned struct into the SMALL checkpoint entry
  `EvoGit.AgentState` documents (`%{kind:, base_seq:, messages:, fields:,
  owner:}`) and back, and it is called from the SESSION process only (the
  `:checkpoint` boundary in `EvoGit.Agent.Session.publish_checkpoint/2`, the
  `{:agent_state_resync, …}` handler and the terminal path).

  ## Never crashes a run

  Every function here is TOTAL by construction (guards plus `case`, no
  `try/rescue`): a malformed state, a missing identity, a corrupt/absent row or
  an unavailable store degrades to `:ok` / `{:error, reason}` and never takes
  the agent down with it. Durable state is an optimisation for recovery, never
  a prerequisite for running.

  ## The session process does NO serialization

  `checkpoint/2` only compares two message lists (the previously adopted state
  and the worker's new one) and then issues ONE `GenServer.cast` through
  `EvoGit.AgentState.checkpoint/4`; encoding (`term_to_binary` of the message
  payload, Jason encoding of the JSON columns) happens in the agent-state
  server's own writer process, so the session's mailbox is never blocked by a
  database write.

  ## Append vs rewrite

  The baseline is the message COUNT believed to be persisted for this run,
  kept in the SESSION's process dictionary (the session is `:temporary`, so the
  dictionary's lifetime IS the run's lifetime):

      {:evogit_agent_state_baseline, task_id, agent_id}

  An absent baseline means "nothing of this run has been persisted yet", so the
  first checkpoint of a run is always a `:rewrite` of the full list. From then
  on a checkpoint is an `:append` (new tail only) exactly when the previously
  adopted message list is a PREFIX of the new one AND `compression_count` did
  not change; every other case (a compression, a rewritten transcript, a
  shorter/different list) is a `:rewrite` of the full list.

  ## The restored transcript is authoritative

  `restore/3` merges ONLY conversation state onto a freshly built `%State{}`:
  the persisted message list REPLACES the fresh `[system, user]` pair, because
  the conversation — not the prompt that would be rebuilt from disk — is what
  the run was working on. Identity, worktree, paths, model selection and phase
  stay FRESH: they are re-resolved from the scheduler row and the (re-created)
  worktree of THIS run, and the provider cache identity minted at
  re-registration rides `llm_generation_params` untouched.
  """

  require Logger

  alias EvoGit.Agent.State
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record

  @baseline_key :evogit_agent_state_baseline

  # The scalar fields persisted per checkpoint: a SMALL projection of the state,
  # never the whole struct. These are exactly the columns
  # `EvoGit.AgentState.Record` knows how to write.
  @field_keys [
    :agent_module,
    :depth,
    :parent_id,
    :node_path,
    :repo_id,
    :repo_less,
    :repo_root,
    :custom_agent_id,
    :mode,
    :archive,
    :objective,
    :model_spec,
    :provider_profile_id,
    :model_id,
    :model_id_locked,
    :prompt_cache_key,
    :llm_model,
    :llm_context_window,
    :turn,
    :usage,
    :total_tokens,
    :compression_count,
    :current_commit,
    :pending_inputs,
    :phase
  ]

  # The conversation fields `restore/3` may take from the stored record, with the
  # shape each one must have. Anything else keeps the freshly built value.
  @restore_fields [
    {:turn, :integer},
    {:usage, :usage},
    {:total_tokens, :integer},
    {:compression_count, :integer},
    {:prompt_cache_key, :binary},
    {:objective, :binary},
    {:pending_inputs, :list},
    {:current_commit, :binary}
  ]

  @doc """
  Persists ONE turn boundary: classifies the change between the previously
  adopted `old_state` and the worker's `new_state`, then issues at most ONE
  checkpoint cast.

  Fully INERT (no cast, no encoding, no database touch, no process-dictionary
  write) unless `new_state.persistent_state == true`, so the struct default
  (`false`) keeps every hand-built/unit-test state from writing.
  """
  @spec checkpoint(State.t(), State.t()) :: :ok
  def checkpoint(%State{} = old_state, %State{} = new_state) do
    if new_state.persistent_state != true do
      :ok
    else
      case identity(new_state) do
        {:ok, task_id, agent_id} ->
          persist(old_state, new_state, task_id, agent_id)

        :skip ->
          :ok
      end
    end
  end

  def checkpoint(_old_state, _new_state), do: :ok

  @doc """
  Restores a crashed run's conversation onto the freshly built `fresh_state`.

  Returns the merged `%EvoGit.Agent.State{}`, or `{:error, reason}` when the
  run has no identity (`:no_identity`), no stored row (`:not_found`), a corrupt
  payload (`:corrupt_state`), an unavailable store (`:store_unavailable`) or a
  stored run with no messages (`:empty_state`). The caller keeps its fresh
  state in every error case.
  """
  @spec restore(State.t(), String.t() | nil, integer() | nil) ::
          State.t() | {:error, atom()}
  def restore(%State{} = fresh_state, task_id, agent_id) do
    if valid_identity?(task_id, agent_id) do
      case AgentState.load(task_id, agent_id) do
        {:ok, %Record{messages: messages, fields: fields}}
        when is_list(messages) and messages != [] ->
          merge_restored(fresh_state, messages, fields)

        {:ok, %Record{}} ->
          {:error, :empty_state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_identity}
    end
  end

  @doc """
  Answers a reported continuity gap with ONE FULL `:rewrite` of the state's
  conversation, resetting the process-dictionary baseline to the full list.

  ALWAYS a rewrite, never an append: the store reported that what it holds does
  not line up with what this run believed, so the only safe recovery is to
  replace its copy wholesale. Inert unless `persistent_state == true`.
  """
  @spec resync(State.t()) :: :ok
  def resync(%State{} = state) do
    if state.persistent_state != true do
      :ok
    else
      case identity(state) do
        {:ok, task_id, agent_id} ->
          Logger.debug(fn ->
            "Agent #{agent_id}: durable state resync requested; rewriting the full transcript " <>
              "(#{length(messages(state))} messages)"
          end)

          messages = messages(state)
          cast(task_id, agent_id, :rewrite, nil, messages, state)
          put_baseline(task_id, agent_id, length(messages))
          :ok

        :skip ->
          :ok
      end
    end
  end

  def resync(_state), do: :ok

  @doc """
  Marks the run completed in the durable store (the row is KEPT for later
  recovery). Best-effort and total; inert unless `persistent_state == true`.

  Called ONLY from the one-shot terminal delivery — an interactive session
  parked in `:awaiting_input` is not completed, and neither is a force-killed
  one.
  """
  @spec complete(State.t()) :: :ok
  def complete(%State{} = state) do
    if state.persistent_state != true do
      :ok
    else
      case identity(state) do
        {:ok, task_id, agent_id} -> AgentState.mark_completed(task_id, agent_id)
        :skip -> :ok
      end
    end
  end

  def complete(_state), do: :ok

  ## Classification + cast

  defp persist(%State{} = old_state, %State{} = new_state, task_id, agent_id) do
    old_messages = messages(old_state)
    new_messages = messages(new_state)

    case classify(old_state, new_state, old_messages, new_messages, task_id, agent_id) do
      :skip ->
        :ok

      {:append, base_seq, tail} ->
        cast(task_id, agent_id, :append, base_seq, tail, new_state)
        put_baseline(task_id, agent_id, base_seq + length(tail))
        :ok

      {:rewrite, _nil, full} ->
        cast(task_id, agent_id, :rewrite, nil, full, new_state)
        put_baseline(task_id, agent_id, length(full))
        :ok
    end
  end

  # append when a baseline exists, compression has not fired and the previously
  # adopted list is a PREFIX of the new one; rewrite in every other case.
  defp classify(old_state, new_state, old_messages, new_messages, task_id, agent_id) do
    cond do
      is_nil(get_baseline(task_id, agent_id)) ->
        {:rewrite, nil, new_messages}

      new_state.compression_count != old_state.compression_count ->
        {:rewrite, nil, new_messages}

      not prefix?(old_messages, new_messages) ->
        {:rewrite, nil, new_messages}

      true ->
        tail = Enum.drop(new_messages, length(old_messages))
        if tail == [], do: :skip, else: {:append, length(old_messages), tail}
    end
  end

  defp prefix?(old_messages, new_messages) when is_list(old_messages) and is_list(new_messages) do
    length(new_messages) >= length(old_messages) and
      Enum.take(new_messages, length(old_messages)) == old_messages
  end

  defp prefix?(_old_messages, _new_messages), do: false

  defp cast(task_id, agent_id, kind, base_seq, messages, %State{} = state) do
    AgentState.checkpoint(task_id, agent_id, %{
      kind: kind,
      base_seq: base_seq,
      messages: messages,
      fields: fields(state),
      owner: self()
    })
  end

  ## Baseline (process dictionary: the session's lifetime IS the run's lifetime)

  defp get_baseline(task_id, agent_id), do: Process.get({@baseline_key, task_id, agent_id})

  defp put_baseline(task_id, agent_id, count) do
    Process.put({@baseline_key, task_id, agent_id}, count)
    :ok
  end

  ## Messages

  defp messages(%State{context: %ReqLLM.Context{messages: messages}}) when is_list(messages),
    do: messages

  defp messages(_state), do: []

  ## Fields

  defp fields(%State{} = state) do
    Map.new(@field_keys, fn key -> {key, field_value(key, state)} end)
  end

  # `%Usage{}` has no Jason encoder and the store JSON-encodes this column, so
  # only the plain map ever leaves this module.
  defp field_value(:usage, %State{usage: usage}), do: usage_map(usage)

  # A custom-endpoint `llm_model` is a map; the column is text, so it is stored
  # as absent rather than inspected into an unusable string.
  defp field_value(:llm_model, %State{llm_model: model}) when is_binary(model), do: model
  defp field_value(:llm_model, _state), do: nil

  defp field_value(key, %State{} = state), do: Map.get(state, key)

  defp usage_map(%Usage{} = usage), do: Map.from_struct(usage)
  defp usage_map(usage) when is_map(usage), do: usage
  defp usage_map(_usage), do: nil

  ## Restore

  defp merge_restored(%State{} = fresh_state, messages, fields) do
    fields = if is_map(fields), do: fields, else: %{}

    # The restored transcript is AUTHORITATIVE: it replaces the freshly built
    # `[system, user]` pair, while the fresh context's `tools` stay as built.
    base = %{fresh_state | context: %{fresh_state.context | messages: messages}}

    Enum.reduce(@restore_fields, base, fn {key, kind}, state ->
      case restore_value(kind, Map.get(fields, key)) do
        :keep -> state
        value -> Map.put(state, key, value)
      end
    end)
  end

  defp restore_value(:integer, value) when is_integer(value), do: value
  defp restore_value(:usage, value) when is_map(value), do: Usage.from_archive_map(value)
  defp restore_value(:list, value) when is_list(value), do: value
  defp restore_value(:binary, value) when is_binary(value), do: blank_to_keep(value)
  defp restore_value(_kind, _value), do: :keep

  defp blank_to_keep(value), do: if(String.trim(value) == "", do: :keep, else: value)

  ## Identity

  defp identity(%State{task_id: task_id, agent_id: agent_id}) do
    if valid_identity?(task_id, agent_id) do
      {:ok, task_id, agent_id}
    else
      :skip
    end
  end

  defp valid_identity?(task_id, agent_id) do
    is_binary(task_id) and String.trim(task_id) != "" and is_integer(agent_id)
  end
end
