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

  An UNCHANGED transcript with an advanced scalar (a tool-only turn's `turn`/`usage`/
  `current_commit`) writes NO transcript at all: it goes to
  `EvoGit.AgentState.update_volatile/4`, the store's constant-shape `UPDATE` of the
  mutable per-turn columns (unchanged `message_count` and `chunk_count`, no chunk
  row). The ONE exception is a boundary that also ANCHORED a new commit:
  `anchor_ref` is not a volatile column, so it rides one `checkpoint/4` with an
  EMPTY tail instead (still no chunk row).
  A boundary that changed NOTHING AT ALL — same transcript, same volatile scalars, a
  matching baseline — writes nothing and runs no anchor task, so a duplicate
  checkpoint cannot cost a full state projection.

  ## One full-field write per run, volatile-only after it

  The identity and run facts (`depth`, `parent_id`, `objective`, `branch`,
  `base_commit`, `redispatch`, …) never change after a run starts, so they are
  written ONCE by `initial_snapshot/1` and the resync repair; a per-turn write
  supplies the VOLATILE projection only, built from the store's own
  `EvoGit.AgentState.Record.volatile_field_specs/0`, so the two lists cannot
  drift. `pause_commit` and `result` are never supplied here: they belong to
  `EvoGit.AgentState.put_pause_commit/4` and `mark_done/5`.

  ## The restored transcript is authoritative

  `restore/3` merges ONLY conversation state onto a freshly built `%State{}`:
  the persisted message list REPLACES the fresh `[system, user]` pair, because
  the conversation — not the prompt that would be rebuilt from disk — is what
  the run was working on. Identity, worktree, paths, model selection and phase
  stay FRESH: they are re-resolved from the scheduler row and the (re-created)
  worktree of THIS run, and the provider cache identity minted at
  re-registration rides `llm_generation_params` untouched.

  The DURABLE RUN FACTS are the one exception on the facts side: `spawn_turn`,
  `spawn_index`, `branch`, `base_commit` and `redispatch` are recovered from the
  row when the freshly built value is `nil`, because a resume cannot re-derive
  them (the spawn position belongs to a parent turn that already happened, and
  the branch/base/anchor belong to the work the predecessor produced). A
  restored value is used only when it has the right shape, and a fresh non-`nil`
  value always wins.

  ## Identity verification

  A restore is keyed `(task_id, agent_id)`, and an id is only unique if the
  scheduler seeded its counter from the store. `restore/3` therefore also
  verifies the row's `parent_id` and `depth` against the state it is about to
  merge into and answers `{:error, :identity_mismatch}` on a disagreement — an
  id collision must never splice one agent's transcript into another run.

  ## The row lifecycle of ONE run

  `initial_snapshot/1` writes the row the moment the run starts (one `:rewrite`
  of the whole transcript plus EVERY scalar, `status: "running"`), so "one
  durable row per RUNNING agent" is true from the first instant and a resumed
  run RE-OPENS a previously `done` row. `checkpoint/2` keeps it current,
  `resync/1` re-writes it wholesale after a store-reported gap, and
  `complete/2` owns the terminal decision: `mark_done/5` with the finished
  run's result, then a ROOT deletes its own row (nothing consumes a root's
  result) while a CHILD keeps its `done` row until the parent's batch-clearing
  checkpoint deletes it (`EvoGit.AgentState.delete_done_children/4`).
  """

  require Logger

  alias EvoGit.Agent.Session.Durable
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Anchor
  alias EvoGit.AgentState.Record

  @baseline_key :evogit_agent_state_baseline

  # The scalar fields a FULL-field write supplies: the store's whole
  # `{field_key, column, type}` spec list MINUS the two columns that have their
  # own writers — `pause_commit` (`EvoGit.AgentState.put_pause_commit/4`) and
  # `result` (`EvoGit.AgentState.mark_done/5`). Deriving them from the store keeps
  # this projection from drifting from the column list, and the exclusion is
  # load-bearing: `Record.encode_fields/1` writes every key it is GIVEN (`nil`
  # included), so supplying either here would CLOBBER the other writer's value.
  #
  # Only `initial_snapshot/1` (which establishes the run's identity and run
  # facts) and `resync/1` (which may have to RE-CREATE a lost row) supply this
  # list; a per-turn write supplies `volatile_fields/1`.
  @field_keys Record.field_specs()
              |> Enum.map(fn {key, _column, _type} -> key end)
              |> Enum.reject(&(&1 in [:pause_commit, :result]))

  # The conversation fields `restore/3` may take from the stored record, with the
  # shape each one must have. These rows are ALWAYS overwritten: they are the
  # progress of the stored run, and the fresh build either has no answer at all
  # (`turn`/`usage`/`total_tokens`/`compression_count`/`pending_inputs`/
  # `pending_tool_batch`) or a rebuilt-from-disk one that must NOT win
  # (`objective`, `prompt_cache_key`).
  #
  # `current_commit` belongs HERE, not in `@run_fact_fields`: the dispatch ctx
  # carries no `current_commit` for a resume (the worktree base travels as
  # `worktree_resume_from`/`base_commit` instead), so the stored value is the ONLY
  # record of the newest commit this run produced — the commit the restored
  # transcript continues from and the one `Result.commit_sha` must reflect.
  @restore_fields [
    {:turn, :integer},
    {:usage, :usage},
    {:total_tokens, :integer},
    {:compression_count, :integer},
    {:prompt_cache_key, :binary},
    {:objective, :binary},
    {:pending_inputs, :list},
    {:current_commit, :binary},
    {:pending_tool_batch, :json}
  ]

  # The DURABLE RUN FACTS `restore/3` recovers from the row (only when the
  # freshly built value is `nil` and the stored one has the right shape — a
  # resume cannot re-derive them, but a fresh value is always authoritative).
  # `branch` and `base_commit` therefore keep a NON-NIL fresh value: this run's
  # worktree was re-created from the resume plan, so its branch/base describe the
  # checkout the run actually has, while the stored pair describes the dead
  # predecessor's checkout.
  @run_fact_fields [
    {:spawn_turn, :integer},
    {:spawn_index, :integer},
    {:branch, :binary},
    {:base_commit, :binary},
    {:redispatch, :json}
  ]

  @doc """
  Persists ONE turn boundary: classifies the change between the previously
  adopted `old_state` and the worker's `new_state`, then issues ONE checkpoint
  cast (a scalar-only append when the transcript did not change).

  It also anchors a commit this boundary ADVANCED (see "Git anchoring") and,
  when the boundary CLEARS the in-flight tool batch, deletes the `done` children
  that batch produced (`EvoGit.AgentState.delete_done_children/4`, one cast).

  Fully INERT (no cast, no encoding, no database touch, no process-dictionary
  write, no git write) unless `new_state.persistent_state == true`, so the
  struct default (`false`) keeps every hand-built/unit-test state from writing.
  """
  @spec checkpoint(State.t(), State.t()) :: :ok
  def checkpoint(%State{} = old_state, %State{} = new_state) do
    if new_state.persistent_state != true do
      :ok
    else
      case identity(new_state) do
        {:ok, task_id, agent_id} ->
          persist(old_state, new_state, task_id, agent_id)
          clear_done_children(old_state, new_state, task_id, agent_id)

        :skip ->
          :ok
      end
    end
  end

  def checkpoint(_old_state, _new_state), do: :ok

  @doc """
  Writes the run's FIRST durable row: ONE `:rewrite` carrying the WHOLE message
  list and EVERY scalar field, issued ONCE from the session start path AFTER
  `EvoGit.Agent.Session.Setup.build_initial_state/3` succeeded (the fresh and
  the restored case alike).

  This is what makes "one durable row per RUNNING agent from the moment it
  starts" true: the row exists before the first turn, so a run that dies inside
  its first LLM call still has its identity, run facts and `redispatch` blob on
  disk. Its fields carry `status: "running"`, so a resumed run RE-OPENS a
  previously `done` row.

  It sets the process-dictionary baseline to the full message count, so every
  later append chains exactly as `checkpoint/2` expects, and it anchors an
  already-known `current_commit` (a resumed run starts on the commit it
  restored — see "Git anchoring").

  Fully INERT unless `state.persistent_state == true`; total, and a state
  without a valid `(task_id, agent_id)` is a no-op `:ok`.
  """
  @spec initial_snapshot(State.t()) :: :ok
  def initial_snapshot(%State{} = state) do
    if state.persistent_state != true do
      :ok
    else
      case identity(state) do
        {:ok, task_id, agent_id} ->
          messages = Durable.messages(state)

          Logger.debug(fn ->
            "Agent #{agent_id}: writing the initial durable snapshot " <>
              "(#{length(messages)} messages)"
          end)

          # The ONE full-field write of the run: identity, run facts and the
          # whole transcript, plus an already-known `anchor_ref`.
          put_checkpoint(
            task_id,
            agent_id,
            :rewrite,
            nil,
            messages,
            fields(state, anchor_fields(state, nil, task_id, agent_id))
          )

          # The baseline is what makes the NEXT checkpoint an append of the tail
          # instead of another full rewrite.
          put_baseline(task_id, agent_id, length(messages))
          :ok

        :skip ->
          :ok
      end
    end
  end

  def initial_snapshot(_state), do: :ok

  @doc """
  Restores a crashed run's conversation onto the freshly built `fresh_state`.

  Returns the merged `%EvoGit.Agent.State{}`, or `{:error, reason}` when the
  run has no identity (`:no_identity`), no stored row (`:not_found`), a corrupt
  payload (`:corrupt_state`), an unavailable store (`:store_unavailable`), a
  stored run with no messages (`:empty_state`) or a row that belongs to a
  DIFFERENT slot (`:identity_mismatch` — the row's `parent_id`/`depth` disagree
  with the state's, so an id collision can never splice another run's
  transcript into this one). The caller keeps its fresh state in every error
  case.
  """
  @spec restore(State.t(), String.t() | nil, integer() | nil) ::
          State.t() | {:error, atom()}
  def restore(%State{} = fresh_state, task_id, agent_id) do
    if Durable.valid_identity?(task_id, agent_id) do
      case AgentState.load(task_id, agent_id) do
        {:ok, %Record{} = record} -> restore_record(fresh_state, record)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_identity}
    end
  end

  def restore(_fresh_state, _task_id, _agent_id), do: {:error, :no_identity}

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
          messages = Durable.messages(state)

          Logger.debug(fn ->
            "Agent #{agent_id}: durable state resync requested; rewriting the full transcript " <>
              "(#{length(messages)} messages)"
          end)

          # The FULL field projection, exceptionally, rather than the volatile
          # one a per-turn boundary writes: a resync is ALSO what the store
          # reports when it finds NO row (a checkpoint dropped by the backlog or
          # payload cap can be the run's very FIRST one), and `checkpoint/4`
          # UPSERTs. A volatile-only upsert would then re-create an
          # IDENTITY-LESS row that every later resume must refuse with
          # `:identity_mismatch`, i.e. the repair would silently destroy the
          # run's resumability. The extra encode happens on the expensive
          # repair path only, never on the turn path.
          put_checkpoint(task_id, agent_id, :rewrite, nil, messages, fields(state, %{}))
          put_baseline(task_id, agent_id, length(messages))
          :ok

        :skip ->
          :ok
      end
    end
  end

  def resync(_state), do: :ok

  @doc """
  Marks the run finished and OWNS the row's fate.

  `complete/1` is the legacy shape (no result text); `complete/2` carries the
  finished run's report, so the row records `status = "done"`, the JSON `result`
  (`text`, `commit`, repo id) and `current_commit` through
  `EvoGit.AgentState.mark_done/5`.

  Then the row depends on the run's ROLE: a ROOT's row is DELETED
  (`EvoGit.AgentState.delete/3`) because nothing consumes a root's result, while
  a CHILD keeps its `done` row until the parent's batch-clearing checkpoint
  deletes it. Both are casts, never a synchronous barrier — the terminal result
  has already been delivered when this runs.

  Best-effort and total; inert unless `persistent_state == true`.

  Called ONLY from the one-shot terminal delivery — an interactive session
  parked in `:awaiting_input` is not completed, a PAUSED run must stay
  resumable, and a force-killed session never reaches here.
  """
  @spec complete(State.t()) :: :ok
  def complete(%State{} = state), do: complete(state, nil)

  def complete(_state), do: :ok

  @spec complete(State.t(), String.t() | nil) :: :ok
  def complete(%State{} = state, result_text) do
    if state.persistent_state != true do
      :ok
    else
      case identity(state) do
        {:ok, task_id, agent_id} ->
          AgentState.mark_done(
            task_id,
            agent_id,
            done_result(state, result_text),
            state.current_commit
          )

          drop_root_row(state, task_id, agent_id)
          :ok

        :skip ->
          :ok
      end
    end
  end

  def complete(_state, _result_text), do: :ok

  ## Completion

  # The finished run's small JSON result. `nil`/non-binary text is recorded as
  # `null` rather than inspected into a value no consumer can use.
  defp done_result(%State{} = state, result_text) do
    %{
      "text" => if(is_binary(result_text), do: result_text, else: nil),
      "commit" => state.current_commit,
      "repo_id" => state.repo_id
    }
  end

  # A ROOT's result is consumed by nobody, so its row is dropped as soon as the
  # terminal facts are recorded. A CHILD's row is the parent's (and the resume
  # path's) evidence that it finished, so it stays until the parent's
  # batch-clearing checkpoint deletes it.
  defp drop_root_row(%State{parent_id: nil}, task_id, agent_id) do
    AgentState.delete(task_id, agent_id)
    :ok
  end

  defp drop_root_row(%State{}, _task_id, _agent_id), do: :ok

  ## Classification + cast

  defp persist(%State{} = old_state, %State{} = new_state, task_id, agent_id) do
    old_messages = Durable.messages(old_state)
    new_messages = Durable.messages(new_state)
    # The counts are the classification's whole input and EVERY branch needs the new
    # one, so they are computed ONCE per boundary (the old code called `length/1`
    # up to four times, each call a full walk of a transcript that grows every turn).
    old_count = length(old_messages)
    new_count = length(new_messages)

    # A boundary that learned NOTHING does no store work at all: no encoding, no
    # cast, no anchor task. Answering a no-op here keeps a duplicate checkpoint from
    # costing a full JSON projection of the state.
    if unchanged?(old_state, new_state, old_messages, new_messages, old_count, task_id, agent_id) do
      :ok
    else
      anchor = anchor_fields(new_state, old_state.current_commit, task_id, agent_id)

      case classify(
             old_state,
             new_state,
             old_messages,
             new_messages,
             old_count,
             task_id,
             agent_id
           ) do
        # The transcript did NOT move (an equal list with a matching baseline and
        # compression count): only the volatile scalars did.
        {:append, base_seq, []} ->
          write_volatile_boundary(task_id, agent_id, base_seq, new_count, new_state, anchor)

        {:append, base_seq, tail} ->
          write_checkpoint(task_id, agent_id, :append, base_seq, tail, new_state, anchor)
          put_baseline(task_id, agent_id, new_count)
          :ok

        {:rewrite, _nil, full} ->
          write_checkpoint(task_id, agent_id, :rewrite, nil, full, new_state, anchor)
          put_baseline(task_id, agent_id, new_count)
          :ok
      end
    end
  end

  # The scalar-only boundary: the conversation the store already holds is
  # unchanged, so nothing has to be re-sent. `EvoGit.AgentState.update_volatile/4`
  # is ONE constant-shape `UPDATE` of the mutable per-turn columns — no chunk
  # write, no full-field upsert, and nothing for the store to re-encode.
  #
  # The ONE reason to prefer a checkpoint here is a NEW `anchor_ref`: it is a
  # durable RUN FACT written by the git side, NOT a volatile column, so
  # `update_volatile/4` cannot carry it (and `checkpoint/4`'s `fields` write only
  # touches supplied keys, so an omitted `anchor_ref` would leave the stored ref
  # alone — but the ref would then be LOST for a row that has none yet). An
  # empty-tail `:append` persists the scalar set AND the ref with no chunk row.
  defp write_volatile_boundary(task_id, agent_id, base_seq, count, %State{} = state, anchor) do
    if anchor == %{} do
      AgentState.update_volatile(task_id, agent_id, volatile_fields(state))
    else
      put_checkpoint(
        task_id,
        agent_id,
        :append,
        base_seq,
        [],
        Map.merge(volatile_fields(state), anchor)
      )
    end

    put_baseline(task_id, agent_id, count)
    :ok
  end

  # A per-turn write of the VOLATILE projection plus whatever the git side just
  # established. Identity and run facts are NOT re-supplied: `initial_snapshot/1`
  # wrote them once and they cannot change after a run starts.
  defp write_checkpoint(task_id, agent_id, kind, base_seq, messages, %State{} = state, anchor) do
    put_checkpoint(
      task_id,
      agent_id,
      kind,
      base_seq,
      messages,
      Map.merge(volatile_fields(state), anchor)
    )
  end

  # The no-op boundary: the SAME transcript list (`==` short-circuits on a shared
  # term, so an unchanged turn costs one pointer compare) and no scalar this
  # checkpoint persists has moved. The baseline must MATCH too — "nothing changed"
  # may never hide a transcript the store does not hold.
  defp unchanged?(old_state, new_state, old_messages, new_messages, count, task_id, agent_id) do
    get_baseline(task_id, agent_id) == count and
      old_messages == new_messages and
      volatile_fields(old_state) == volatile_fields(new_state)
  end

  ## Git anchoring

  # Keeps a commit this boundary ADVANCED reachable past worktree reclamation
  # (`docs/agent-run-durability.md` § Git anchoring): a branch inside
  # `.genesis/workers/` dies with the worktree, so the session anchors the sha at
  # `refs/genesis/agent-state/<task_id>/<agent_id>` and records that ref on the
  # row.
  #
  # Fire-and-forget by contract: `Anchor.anchor/4` hands ONE `git update-ref` to
  # an unlinked task and is total, so this can never block or fail the turn. A
  # REPO-LESS run has no repository, and an unchanged/absent sha is not a new
  # fact, so both answer `%{}` and write no ref.
  defp anchor_fields(%State{} = state, previous_sha, task_id, agent_id) do
    sha = state.current_commit

    if is_binary(sha) and sha != "" and sha != previous_sha and state.repo_less != true and
         is_binary(state.repo_path) do
      Anchor.anchor(state.repo_path, task_id, agent_id, sha)
      %{anchor_ref: Anchor.ref(task_id, agent_id)}
    else
      %{}
    end
  end

  ## Done children

  # The transition `pending_tool_batch != nil → nil` IS the batch boundary: the
  # parent has just consumed the results of the children it spawned in that
  # turn, so their `done` rows are no longer needed (`mark_done/5` kept them
  # exactly for this read). ONE cast per batch; a marker without an integer turn
  # deletes nothing (the store enforces that too).
  defp clear_done_children(%State{} = old_state, %State{} = new_state, task_id, agent_id) do
    if is_nil(new_state.pending_tool_batch) do
      case ToolBatch.normalize(old_state.pending_tool_batch) do
        %{turn: turn} when is_integer(turn) ->
          AgentState.delete_done_children(task_id, agent_id, turn)
          :ok

        _none ->
          :ok
      end
    else
      :ok
    end
  end

  defp clear_done_children(_old_state, _new_state, _task_id, _agent_id), do: :ok

  # append when a baseline exists, compression has not fired and the previously
  # adopted list is a PREFIX of the new one (an EMPTY tail included: that is the
  # scalar-only append); rewrite in every other case.
  #
  # The counts arrive pre-computed from `persist/4`, and both successful branches set
  # the baseline to the NEW count (`base_seq + length(tail)` is exactly that for an
  # append of a shared tail), so the caller writes one baseline for both.
  defp classify(old_state, new_state, old_messages, new_messages, old_count, task_id, agent_id) do
    cond do
      # An absent baseline (`nil`) and a count disagreement are the same decision: the
      # store does not hold this transcript, so replace it wholesale.
      get_baseline(task_id, agent_id) != old_count ->
        {:rewrite, nil, new_messages}

      new_state.compression_count != old_state.compression_count ->
        {:rewrite, nil, new_messages}

      not prefix?(old_messages, new_messages) ->
        {:rewrite, nil, new_messages}

      true ->
        # `Enum.drop/2` returns a SHARED tail of `new_messages`: no allocation.
        {:append, old_count, Enum.drop(new_messages, old_count)}
    end
  end

  # A NON-ALLOCATING prefix walk. The old form (`Enum.take(new, length(old)) == old`)
  # copied the whole old prefix into a fresh list on EVERY boundary — the largest
  # allocation of a served checkpoint, and it grew with the transcript. Walking both
  # lists together is one comparison per message and allocates nothing.
  defp prefix?([], new_messages) when is_list(new_messages), do: true
  defp prefix?([_old_head | _old_tail], []), do: false
  defp prefix?([head | old_tail], [head | new_tail]), do: prefix?(old_tail, new_tail)

  defp prefix?(old_messages, new_messages) when is_list(old_messages) and is_list(new_messages),
    do: false

  defp prefix?(_old_messages, _new_messages), do: false

  # ONE cast: `fields` is already the exact map the store should write (the
  # caller decides whether that is the volatile projection, the full one, or the
  # volatile one plus a fresh `anchor_ref`).
  defp put_checkpoint(task_id, agent_id, kind, base_seq, messages, fields) do
    AgentState.checkpoint(task_id, agent_id, %{
      kind: kind,
      base_seq: base_seq,
      messages: messages,
      fields: fields,
      owner: self()
    })
  end

  ## Baseline (process dictionary: the session's lifetime IS the run's lifetime)

  defp get_baseline(task_id, agent_id), do: Process.get({@baseline_key, task_id, agent_id})

  defp put_baseline(task_id, agent_id, count) do
    Process.put({@baseline_key, task_id, agent_id}, count)
    :ok
  end

  ## Fields

  # The VOLATILE projection: exactly the scalar columns a turn boundary can
  # advance, built from the STORE's own list (`EvoGit.AgentState.Record`) so the
  # producer can never drift from the column set `update_volatile/4` writes.
  #
  # It answers two questions at once: compared with `==` it is "did this boundary
  # learn anything new?" (without building the 34-key map a full write needs), and
  # supplied whole it IS the `update_volatile/4` payload — which has REPLACE
  # semantics, so EVERY key must be present, never a subset.
  defp volatile_fields(%State{} = state) do
    Map.new(Record.volatile_field_specs(), fn {key, _column, _type} ->
      {key, field_value(key, state)}
    end)
  end

  # The FULL projection, for the two writes that create/re-open a row
  # (`initial_snapshot/1`, `resync/1`): every stable identity/run fact plus the
  # volatile half. `pause_commit` and `result` are deliberately NOT in
  # `@field_keys` — they have their own writes (`put_pause_commit/4`,
  # `mark_done/5`) and re-encoding them here would clobber a later value.
  #
  # `extra_fields` are the facts THIS checkpoint establishes beyond the state
  # projection (currently only `anchor_ref`, which the session has just written
  # to git); they are merged over the projection, so an absent key can never
  # erase a stored value (`Record.encode_fields/1` keeps only supplied keys).
  defp fields(%State{} = state, extra_fields) when is_map(extra_fields) do
    @field_keys
    |> Map.new(fn key -> {key, field_value(key, state)} end)
    |> Map.merge(extra_fields)
  end

  # A checkpoint is written by a RUNNING agent by definition: every checkpoint
  # path re-opens a row a previous run left as `done`. The terminal value belongs
  # to `EvoGit.AgentState.mark_done/5` (reached through `complete/2`).
  defp field_value(:status, %State{}), do: "running"

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

  # The row must belong to the SLOT being restored before a single message is
  # merged: `agent_id` is only unique when the scheduler seeded its counter from
  # the store, so a collision would otherwise splice one run's transcript into
  # another. `parent_id` and `depth` are the cheap, durable proof of the slot.
  defp restore_record(%State{} = fresh_state, %Record{} = record) do
    with :ok <- verify_identity(fresh_state, record) do
      restore_messages(fresh_state, record)
    end
  end

  defp restore_messages(%State{} = fresh_state, %Record{messages: messages, fields: fields})
       when is_list(messages) and messages != [] do
    merge_restored(fresh_state, messages, fields)
  end

  defp restore_messages(%State{}, %Record{}), do: {:error, :empty_state}

  defp verify_identity(%State{} = fresh_state, %Record{fields: fields}) when is_map(fields) do
    if Map.get(fields, :parent_id) == fresh_state.parent_id and
         Map.get(fields, :depth) == fresh_state.depth do
      :ok
    else
      {:error, :identity_mismatch}
    end
  end

  # A record without decodable fields cannot prove which slot it belongs to, so
  # it is treated as a mismatch instead of being merged on trust.
  defp verify_identity(_fresh_state, _record), do: {:error, :identity_mismatch}

  defp merge_restored(%State{} = fresh_state, messages, fields) do
    fields = if is_map(fields), do: fields, else: %{}

    # The restored transcript is AUTHORITATIVE: it replaces the freshly built
    # `[system, user]` pair, while the fresh context's `tools` stay as built.
    base = %{fresh_state | context: %{fresh_state.context | messages: messages}}

    base
    |> merge_stored(@restore_fields, fields, :always)
    |> merge_stored(@run_fact_fields, fields, :only_nil)
  end

  # `:always` overwrites (the conversation belongs to the stored run), while
  # `:only_nil` fills in a durable RUN FACT the fresh build could not derive
  # (a fresh non-nil value is authoritative — identity, worktree and model
  # selection belong to THIS run).
  defp merge_stored(%State{} = state, specs, fields, mode) do
    Enum.reduce(specs, state, fn {key, kind}, acc ->
      if mode == :only_nil and Map.get(acc, key) != nil do
        acc
      else
        case restore_value(kind, Map.get(fields, key)) do
          :keep -> acc
          value -> Map.put(acc, key, value)
        end
      end
    end)
  end

  defp restore_value(:integer, value) when is_integer(value), do: value
  defp restore_value(:usage, value) when is_map(value), do: Usage.from_archive_map(value)
  defp restore_value(:list, value) when is_list(value), do: value
  # A marker column round-trips through JSON, so it comes back STRING-keyed with a
  # STRING class. It is passed through RAW: `EvoGit.Agent.ToolBatch.normalize/1`
  # is the ONE place that rebuilds the atom-keyed shape, and it is the consumer's
  # job (never this module's) to do so.
  defp restore_value(:json, value) when is_map(value), do: value
  defp restore_value(:binary, value) when is_binary(value), do: blank_to_keep(value)
  defp restore_value(_kind, _value), do: :keep

  defp blank_to_keep(value), do: if(String.trim(value) == "", do: :keep, else: value)

  ## Identity

  defp identity(%State{task_id: task_id, agent_id: agent_id}) do
    if Durable.valid_identity?(task_id, agent_id) do
      {:ok, task_id, agent_id}
    else
      :skip
    end
  end
end
