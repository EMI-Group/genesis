defmodule EvoGit.Agent.Resume.RosterBatch do
  @moduledoc """
  Worker-side builder of the REBUILD PLAN a whole-tree resume hands to the
  scheduler.

  A parent's subagent batch lives on its `%SchedMeta{}` row, i.e. in ETS: a BEAM
  (or scheduler) restart wipes it, so
  `EvoGit.AgentScheduler.reattach_sub_agents/2,3` refuses with
  `{:error, :no_pending_batch}` and every interrupted slot used to
  degrade to `{:error, :subagent_result_lost}` — even when the children's durable
  rows and anchored commits were sitting in `agent_state.sqlite` all along.

  This module reads those rows and turns them back into a batch:

    * the rows whose `parent_id` is THIS agent and whose `spawn_turn` is the
      dangling turn (the assistant message's `tool_calls` the resume is about to
      answer), ordered by `spawn_index` — the child's position in the parent's
      model call order. The filter itself lives in `EvoGit.AgentState.Snapshot`
      (`children/3`), the ONE durable read model of the tree, so this module
      cannot drift from the pause side;
    * one SLOT per expected subagent call, in that same order:
      - `status == "done"` → its stored `result` JSON becomes the slot result
        (`{:ok, %EvoGit.Agent.Result{}}`), so no child is re-spawned and no cost
        is paid twice;
      - `status == "running"` → a rebuilt `%EvoGit.AgentSpec{}` plus the resume
        opts that re-create the child on its OWN anchored commit and branch with
        its restored conversation;
      - no row (or a row that cannot be rebuilt) → `:missing`, which the
        scheduler answers as `{:error, :subagent_result_lost}` — honest, never
        invented. `EvoGit.Agent.Resume.Reattach` upgrades such a slot to
        `:fresh` on a `:clean_pause` resume (a child the pause froze BEFORE it
        ever registered must be spawned, not reported lost), which is why the
        entry type below carries that status even though this module never
        produces it.

  ## Containment

  This runs in the AGENT WORKER process (the resumed parent's exchange worker),
  never in the scheduler: the durable read is ONE `EvoGit.AgentState.snapshot/2`
  call (bounded and total inside `EvoGit.AgentState`), and the file/context work
  of rebuilding a spec stays off the shared GenServer. `plan/4` answers
  `{:error, reason}` for any RAISE and degrades the caller to the honest
  fallback text; an EXIT or THROW is left alone and reaches the scheduler's
  crash-retry, because it is infrastructure rather than a plan verdict.

  ## Why the resume opts, and which KIND they carry

  A re-spawned child is a resumed run of its OWN: `:resume_agent_id`,
  `:resume_current_commit`, `:resume_branch`, `:resume_anchor_ref` and
  `:restore_agent_state: true` are what `EvoGit.AgentScheduler.ResumePlan` needs
  to base the child's worktree on its own last commit, rebuild its branch from
  the anchor when the workers directory was wiped, and restore its transcript.

  The PARENT's resume kind (`opts[:resume_kind]`) decides two further keys,
  because a child inherits the pause position it was frozen in:

    * `:clean_pause` → `:pause_commit` = the child's OWN `pause_commit` (the
      checkpoint the freeze stored), so its worktree is based on the exact
      position it was frozen at, and `:resume_kind` travels so the child's own
      `EvoGit.Agent.Resume.apply/2` takes the clean/no-repair path;
    * `:dirty_pause` → `:pause_commit` PRESENT and `nil`, which SUPPRESSES
      `ResumePlan`'s durable fallback read: a `pause_commit` column left over
      from an EARLIER pause must never be used after a crash, and the child then
      bases on `:resume_current_commit` exactly as a crash retry does;
    * `nil` (crash retry) → neither key is written, so the child's opts stay
      byte-identical to the pre-redesign shape.
  """

  require Logger

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentState.Redispatch
  alias EvoGit.AgentState.Snapshot
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @typedoc """
  One expected subagent slot of the dangling batch.

    * `:index` — the slot position, i.e. the child's `spawn_index` in the
      parent's model call order;
    * `:status` — `:done` (a finished child whose stored result is used as-is),
      `:running` (a child to re-spawn under its persisted id), `:fresh` (a child
      the pause froze before it ever registered: spawn it under a NEW id — built
      by `EvoGit.Agent.Resume.Reattach`, never here) or `:missing` (no usable
      durable row);
    * `:agent_id` — the persisted id of the child when a row matched (`nil` for
      `:fresh`);
    * `:result` — for `:done`, the `{:ok, %EvoGit.Agent.Result{}}` the ordinary
      spawn path would have produced; `nil` otherwise;
    * `:spec` — for `:running`/`:fresh`, the rebuilt spec; `nil` otherwise.
  """
  @type entry :: %{
          index: non_neg_integer(),
          status: :done | :running | :fresh | :missing,
          agent_id: pos_integer() | nil,
          result: {:ok, Result.t()} | nil,
          spec: AgentSpec.t() | nil
        }

  @typedoc """
  The plan handed to `EvoGit.AgentScheduler.rebuild_subagent_batch/3`.
  """
  @type plan :: %{
          turn: integer(),
          expected_count: pos_integer(),
          entries: [entry()]
        }

  @typedoc """
  Every decline `plan/4` can answer.

  All of them are self-contained facts about the plan request — a state without
  durable identity, a turn/count the caller could not have meant, a durable read
  that refused, or a raise while rebuilding a spec. An EXIT is deliberately not
  in this list: it is infrastructure, never a plan verdict, so it propagates to
  the scheduler's crash-retry instead of being laundered into a "we checked, the
  child is gone" answer.

  An injected `:roster_fun`'s own `{:error, reason}` term is passed through
  UNCHANGED (that `reason` belongs to the reader, not to this module), so an
  unrecognized term means the roster read failed.
  """
  @type error ::
          :invalid_state
          | :persistent_state_disabled
          | :no_expected_slots
          | :unknown_spawn_turn
          | :no_task_id
          | {:invalid_roster, term()}
          | {:invalid_roster_fun, term()}
          | {:plan_failed, String.t()}

  @doc """
  Builds the rebuild plan for the dangling batch of `state`.

  `turn` is the parent TURN whose `tool_calls` are dangling
  (`EvoGit.Agent.Resume.dangling/1`), and `expected` is the number of
  `:subagent` calls that turn issued — one slot each, in model call order.

  Options:

    * `:roster_fun` — `fn task_id -> [%EvoGit.AgentState.Record{}] | {:error, reason}`,
      defaulting to the ONE snapshot read
      (`EvoGit.AgentState.snapshot/2`, whose `agents` roster it projects). The
      ONE injection point (an explicit option, never app env).
    * `:resume_kind` — the PARENT's pause resume kind (`:clean_pause`,
      `:dirty_pause`, `nil` for a crash retry); it decides whether a rebuilt
      child carries its own `:pause_commit` and a `:resume_kind` of its own —
      see the moduledoc.

  Total: `{:error, reason}` for a state without durable identity, an unknown
  turn, an empty batch, a refused/unavailable store or any raise while
  rebuilding a spec. An EXIT or THROW is NOT a failure verdict and is not
  rescued — it belongs to the caller's crash-retry.
  """
  @spec plan(State.t(), term(), non_neg_integer(), keyword()) ::
          {:ok, plan()} | {:error, error()}
  def plan(state, turn, expected, opts \\ [])

  def plan(%State{} = state, turn, expected, opts) when is_list(opts) do
    try do
      do_plan(state, turn, expected, opts)
    rescue
      error ->
        {:error, {:plan_failed, Exception.message(error)}}
    end
  end

  def plan(_state, _turn, _expected, _opts), do: {:error, :invalid_state}

  ## Plan

  defp do_plan(%State{} = state, turn, expected, opts) do
    with :ok <- durable?(state),
         :ok <- valid_expected(expected),
         :ok <- valid_turn(turn),
         {:ok, task_id} <- task_id(state),
         {:ok, records} <- roster(task_id, opts) do
      by_index = children_by_index(records, state.agent_id, turn)

      entries =
        for index <- 0..(expected - 1)//1 do
          entry(index, Map.get(by_index, index), state, opts)
        end

      {:ok, %{turn: turn, expected_count: expected, entries: entries}}
    end
  end

  # `persistent_state: false` is FULLY inert: there are no durable rows at all,
  # so a roster read would be a pointless (and misleading) database touch.
  defp durable?(%State{persistent_state: true}), do: :ok
  defp durable?(_state), do: {:error, :persistent_state_disabled}

  defp valid_expected(expected) when is_integer(expected) and expected > 0, do: :ok
  defp valid_expected(_expected), do: {:error, :no_expected_slots}

  defp valid_turn(turn) when is_integer(turn), do: :ok
  defp valid_turn(_turn), do: {:error, :unknown_spawn_turn}

  defp task_id(%State{task_id: task_id}) when is_binary(task_id) and task_id != "",
    do: {:ok, task_id}

  defp task_id(_state), do: {:error, :no_task_id}

  ## Roster

  # The default durable read is the ONE snapshot read model: `snapshot/2` already
  # splits the root off the roster and answers `{:error, :empty | :no_root |
  # :unavailable}` for anything unusable, and `resume_opts/2` only needs the
  # `agents` roster.
  defp roster(task_id, opts) do
    case Keyword.get(opts, :roster_fun) || (&default_roster/1) do
      fun when is_function(fun, 1) ->
        case fun.(task_id) do
          records when is_list(records) -> {:ok, records}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_roster, other}}
        end

      other ->
        {:error, {:invalid_roster_fun, other}}
    end
  end

  defp default_roster(task_id) do
    case AgentState.snapshot(task_id) do
      {:ok, snapshot} -> snapshot.agents
      {:error, _reason} -> []
    end
  end

  # The children of THIS parent spawned by the DANGLING turn, keyed by their
  # position in the parent's model call order. The filter is
  # `EvoGit.AgentState.Snapshot.children/3` — the SAME one the pause side reads —
  # so this module has no private copy of it. A row without an integer
  # `spawn_index` cannot be placed in a batch, so it is ignored (the slot ends up
  # `:missing`) rather than guessed.
  defp children_by_index(records, parent_id, turn) do
    records
    |> Snapshot.children(parent_id, turn)
    |> Enum.filter(&is_integer(field(&1, :spawn_index)))
    |> Map.new(fn record -> {field(record, :spawn_index), record} end)
  end

  ## One slot

  defp entry(index, nil, _state, _opts), do: missing_entry(index, nil)

  defp entry(index, record, state, opts) do
    case Record.status(record) do
      "done" ->
        %{
          index: index,
          status: :done,
          agent_id: record_agent_id(record),
          result: done_result(record),
          spec: nil
        }

      "running" ->
        running_entry(index, record, state, opts)

      other ->
        Logger.warning(
          "Resume: durable subagent row #{inspect(record_agent_id(record))} has status " <>
            "#{inspect(other)}; reporting the slot as lost"
        )

        missing_entry(index, record_agent_id(record))
    end
  end

  defp missing_entry(index, agent_id) do
    %{index: index, status: :missing, agent_id: agent_id, result: nil, spec: nil}
  end

  defp done_result(record) do
    stored = Record.result(record) || %{}
    fields = fields(record)

    {:ok,
     %Result{
       result: text(get(stored, "text")),
       commit_sha: get(stored, "commit") || Map.get(fields, :current_commit),
       branch: Map.get(fields, :branch),
       repo_id: get(stored, "repo_id") || Map.get(fields, :repo_id)
     }}
  end

  defp running_entry(index, record, state, opts) do
    case build_spec(record, state, opts) do
      {:ok, spec} ->
        %{
          index: index,
          status: :running,
          agent_id: record_agent_id(record),
          result: nil,
          spec: spec
        }

      {:error, reason} ->
        Logger.warning(
          "Resume: cannot rebuild the spec of durable subagent " <>
            "#{inspect(record_agent_id(record))} (#{inspect(reason)}); reporting its slot as lost"
        )

        missing_entry(index, record_agent_id(record))
    end
  end

  ## Spec rebuild

  defp build_spec(record, state, opts) do
    fields = fields(record)

    with module when is_atom(module) and not is_nil(module) <- Map.get(fields, :agent_module),
         objective when is_binary(objective) <- Map.get(fields, :objective),
         agent_id when is_integer(agent_id) and agent_id > 0 <- record_agent_id(record) do
      repo_id = Map.get(fields, :repo_id) || state.repo_id || "primary"
      redispatch_opts = Redispatch.to_spec_opts(Map.get(fields, :redispatch))
      foreign_repos = Keyword.get(redispatch_opts, :foreign_repos) || state.foreign_repos || []
      node_path = Keyword.get(redispatch_opts, :node_path) || Map.get(fields, :node_path) || "./"

      context_node =
        ContextNode.load(node_path, repo_root(repo_id, state, foreign_repos), repo_id)

      phylo_node = phylo_node(record, repo_root(repo_id, state, foreign_repos))

      opts =
        redispatch_opts
        |> Keyword.drop([:parent_id, :depth, :agent_type, :delegation_level])
        |> Keyword.merge(
          repo_id: repo_id,
          foreign_repos: foreign_repos,
          repo_notes: state.repo_notes,
          archive: Map.get(fields, :archive),
          persistent_state: true,
          task_tmpdir: EvoGit.TaskTmpdir.current(),
          model_spec: Map.get(fields, :model_spec) || Keyword.get(redispatch_opts, :model_spec),
          model_id: Map.get(fields, :model_id)
        )
        |> put_model_id_locked(fields)
        |> Keyword.merge(resume_opts(record, opts))

      {:ok, AgentSpec.new(context_node, phylo_node, module, objective, opts)}
    else
      _absent -> {:error, :incomplete_row}
    end
  end

  # The child resumes its OWN run: identity, base, branch and anchor. The anchor
  # ref is what lets `EvoGit.AgentScheduler.Worktrees` rebuild a wiped branch from
  # the commits the dead run had produced.
  #
  # The PARENT's resume kind is inherited as the child's own pause position: a
  # clean freeze based the child on ITS `pause_commit`, a dirty pause SUPPRESSES
  # the stale durable `pause_commit` column with an explicit `nil` (the key's
  # presence is what `ResumePlan` honors), and a crash retry writes neither key.
  defp resume_opts(record, opts) do
    fields = fields(record)
    kind = resume_kind(opts)

    [
      resume_agent_id: record_agent_id(record),
      resume_current_commit: Map.get(fields, :current_commit),
      resume_branch: Map.get(fields, :branch),
      resume_anchor_ref: Map.get(fields, :anchor_ref),
      restore_agent_state: true
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> put_pause_commit(kind, fields)
    |> put_resume_kind(kind)
  end

  # The two task-level pause resume kinds; anything else (including an absent
  # key) is the crash-retry path.
  defp resume_kind(opts) do
    case Keyword.get(opts, :resume_kind) do
      kind when kind in [:clean_pause, :dirty_pause] -> kind
      _other -> nil
    end
  end

  defp put_pause_commit(opts, :clean_pause, fields),
    do: Keyword.put(opts, :pause_commit, Map.get(fields, :pause_commit))

  defp put_pause_commit(opts, :dirty_pause, _fields),
    do: Keyword.put(opts, :pause_commit, nil)

  defp put_pause_commit(opts, nil, _fields), do: opts

  defp put_resume_kind(opts, nil), do: opts
  defp put_resume_kind(opts, kind), do: Keyword.put(opts, :resume_kind, kind)

  # A locked selection stays locked (the whole account/model/effort identity was
  # chosen explicitly); an unlocked one is left ABSENT so dispatch fallbacks keep
  # working exactly as they did for the original run.
  defp put_model_id_locked(opts, fields) do
    if Map.get(fields, :model_id_locked) == true do
      Keyword.put(opts, :model_id_locked, true)
    else
      opts
    end
  end

  # The base/branch the worktree is created from. The child's own last commit is
  # the base (its anchored work IS the starting point); when no row value
  # survives, the dispatch falls back to the parent's checkout, and
  # `EvoGit.AgentScheduler.ResumePlan` still verifies every candidate before use.
  defp phylo_node(record, repo_root) do
    fields = fields(record)
    base = Map.get(fields, :base_commit) || Map.get(fields, :current_commit)

    %PhyloGraphNode{repo: repo_root, base_commit: base, current_commit: base}
  end

  # A same-repo child loads against the PARENT's checkout (exactly like the
  # ordinary spawn path); a cross-repo child loads against its own foreign root.
  defp repo_root(repo_id, state, foreign_repos) do
    if repo_id == (state.repo_id || "primary") do
      state.repo_path || Process.get(:repo_path) || state.repo_root
    else
      foreign_root(repo_id, foreign_repos)
    end
  end

  defp foreign_root(repo_id, foreign_repos) do
    Enum.find_value(foreign_repos, fn repo ->
      if Map.get(repo, :id) == repo_id, do: Map.get(repo, :root)
    end)
  end

  ## Accessors

  defp fields(%Record{fields: fields}) when is_map(fields), do: fields
  defp fields(_record), do: %{}

  defp record_agent_id(%Record{agent_id: agent_id}), do: agent_id
  defp record_agent_id(_record), do: nil

  defp field(%Record{} = record, key), do: Map.get(fields(record), key)
  defp field(_record, _key), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  # A stored JSON result is STRING-keyed; an atom-keyed map (a test fixture, or a
  # value read back through a different path) must still answer, so the atom form
  # is tried without minting a new atom.
  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, existing_atom(key))
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
