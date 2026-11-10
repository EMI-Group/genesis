defmodule EvoGit.Agent.Session do
  @moduledoc """
  ONE supervised process per agent: the owner of the authoritative `%EvoGit.Agent.State{}`.

  The session never runs the agent loop itself.
  Every exchange runs in a SEPARATE `Task` (`EvoGit.Agent.Session.Worker`), which is exactly what
  makes inspection, history, input and cancellation answerable WHILE an exchange is running: the
  owner process only receives messages and replies, it never blocks on an LLM call, a tool or a
  subagent batch.

  ## One-shot subset only (`:starting | :running | :cancelling | :finalizing | :done`)

  This is the process FOUNDATION of the agent-runtime refactor (`docs/agent-runtime-refactor.md`
  P1), so the phase set is deliberately the ONE-SHOT subset.
  There is no `:awaiting_input` phase, no `{:yield}` outcome and no `:close` command, because
  `EvoGit.Agent.Exchange.run/2` has no yield/finish split yet: an exchange always runs to a
  terminal outcome.
  There is likewise no delta streaming and no watcher contract — inspection is SNAPSHOT-ONLY:
  `inspect/2` returns the last checkpointed state, `history/2` its messages, and that is the whole
  read surface.
  Durability is absent too: the state lives in this process (plus the `:evogit_agent_summary`
  row), never on disk.

  ## Terminal delivery contract

  Exactly ONE message leaves the session when it ends normally:
  `{:agent_session_result, agent_id, session_pid, result}` sent to the `:scheduler` pid carried
  in the dispatch context (falling back to the registered `EvoGit.AgentScheduler`), where `result`
  is `{:ok, %EvoGit.Agent.Result{}}` for a finished exchange and the `{:error, reason}` term
  VERBATIM for a failed one.
  The message is sent BEFORE the process stops, which is safe because Erlang guarantees signal
  ordering between two processes: the result always arrives before the monitor `:DOWN`.
  The session NEVER replies to the caller that started it — the scheduler owns that `from` reply,
  because it also injects `agent_count`, rolls up `foreign_repo_commits` and routes subagent
  results.
  A force cancel delivers NO result at all.

  ## `dispatch_ctx[:exchange_opts]` — a default-inert seam

  The scheduler's `dispatch_ctx` keyword list may carry an `:exchange_opts` list, forwarded
  verbatim to every exchange worker as engine seam options.
  Production passes NONE — the key never appears in a shipped configuration — and with the key
  absent the worker gets today's production engine path byte-identically.
  It exists so tests can drive an exchange without an LLM.

  ## Wiring status

  The session IS the one lifecycle for every agent.
  `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` starts it under
  `EvoGit.Agent.Session.Supervisor`, monitors it (`ref_to_agent` keys on the
  session monitor ref) and admits its ONE `{:agent_session_result, ...}` in
  `EvoGit.AgentScheduler.handle_info/2` — no agent runs as a bare
  `Task.Supervisor.async_nolink` run any more.
  `EvoGit.AgentScheduler.SchedMeta` carries `session_pid`, `mode` and `phase` as a
  BEST-EFFORT scheduler-side mirror (`:starting` on start, `:cancelling` on a
  graceful cancel, `:done` on recycle); the AUTHORITATIVE live phase is
  `EvoGit.Agent.Session.inspect/2`, never that field.
  A graceful cancel reaches the session through `cancel/2` (`:graceful`) and a
  force kill through `cancel/2` (`:force`), and `WorktreeManager` re-monitors the
  session pid after its own restart.
  `EvoGit.Agent.Session.Registry` (a unique-name `Registry`) and
  `EvoGit.Agent.Session.Supervisor` (a `DynamicSupervisor`) are started before
  `EvoGit.AgentScheduler`, so a session always has a registry entry and an owner
  supervisor.
  This remains the ONE-SHOT subset: no `:awaiting_input` phase, no yield/close and
  no delta streaming yet.
  """

  @behaviour :gen_statem

  import Kernel, except: [inspect: 2]

  require Logger

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session.Registry, as: SessionRegistry
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.Session.Summary
  alias EvoGit.Agent.Session.Worker
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.Store

  @type phase :: :starting | :running | :cancelling | :finalizing | :done

  # Every public call is answerable in microseconds (the owner never runs the exchange), so one
  # short deadline covers them all; a timeout degrades to the documented fallback.
  @call_timeout 5_000

  # --- public API ---

  @doc """
  Starts the session for a scheduler `dispatch_ctx`.

  Registered as `{:via, Registry, {EvoGit.Agent.Session.Registry, agent_id}}`, so the ONE
  per-agent id → pid lookup needs no other bookkeeping.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(dispatch_ctx) when is_list(dispatch_ctx) do
    agent_id = Keyword.fetch!(dispatch_ctx, :agent_id)

    :gen_statem.start_link(
      {:via, Registry, {SessionRegistry, agent_id}},
      __MODULE__,
      dispatch_ctx,
      []
    )
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(dispatch_ctx) when is_list(dispatch_ctx) do
    %{
      id: {__MODULE__, Keyword.fetch!(dispatch_ctx, :agent_id)},
      start: {__MODULE__, :start_link, [dispatch_ctx]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Snapshot of the session: its last checkpointed state plus the phase it is in.

  `:error` when the session is gone, never started, or does not answer within `timeout`.
  """
  @spec inspect(pid() | term(), timeout()) :: {:ok, %{state: State.t(), phase: phase()}} | :error
  def inspect(target, timeout \\ @call_timeout) do
    case call(target, :inspect, timeout) do
      {:ok, %{state: %State{}} = snapshot} -> {:ok, snapshot}
      _other -> :error
    end
  end

  @doc """
  The conversation messages of the last checkpointed state (`[]` when the session is gone).
  """
  @spec history(pid() | term(), timeout()) :: [ReqLLM.Message.t()]
  def history(target, timeout \\ @call_timeout) do
    case call(target, :history, timeout) do
      {:ok, messages} when is_list(messages) -> messages
      _other -> []
    end
  end

  @doc """
  Cancels the running exchange.

  `:graceful` keeps the worker alive so the engine's 3-turn save-work grace runs (`:cancelling`);
  `:force` kills the worker unconditionally and the session stops without delivering a result.
  """
  @spec cancel(pid() | term(), :graceful | :force) :: :ok | {:error, :not_found}
  def cancel(target, mode) when mode in [:graceful, :force] do
    case call(target, {:cancel, mode}, @call_timeout) do
      :ok -> :ok
      _other -> {:error, :not_found}
    end
  end

  # Total by construction: an unsupported mode is not a session that can serve the request.
  def cancel(_target, _mode), do: {:error, :not_found}

  @doc """
  Injects a user message into the running exchange (a binary or the canonical multimodal map).

  This is the settled P2 transport: it appends to the agent's pending-message queue, which the
  engine drains at the next turn boundary.
  """
  @spec input(pid() | term(), String.t() | map()) :: :ok | {:error, :not_found | :finished}
  def input(target, message) do
    case call(target, {:input, message}, @call_timeout) do
      :ok -> :ok
      {:error, :finished} -> {:error, :finished}
      _other -> {:error, :not_found}
    end
  end

  # --- gen_statem callbacks ---

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(dispatch_ctx) do
    data = %{
      state: nil,
      worker: nil,
      dispatch_ctx: dispatch_ctx,
      tmpdir: nil,
      result: nil,
      phase: :starting,
      last_published_turn: nil
    }

    # `init/1` must return FAST: the worktree, the scheduler row and the first worker all
    # happen in the `:internal, :start` event, so a supervisor start never sits in the
    # worktree-creation queue.
    {:ok, :starting, data, [{:next_event, :internal, :start}]}
  end

  @impl :gen_statem
  def handle_event(:internal, :start, :starting, data) do
    ctx = data.dispatch_ctx

    # The SESSION is the worktree owner: it outlives every exchange worker (D7), and the
    # repo-less branch is skipped internally.
    Setup.bind_worktree(ctx, self())
    data = %{data | tmpdir: Setup.ensure_tmpdir(ctx)}

    with {:ok, row} <- scheduler_row(ctx),
         {:ok, state} <- build_state(ctx, row) do
      Summary.publish(agent_id(data), state, status: :running)

      data = %{
        data
        | state: state,
          worker: start_worker(state, data),
          phase: :running,
          last_published_turn: state.turn
      }

      {:next_state, :running, data}
    else
      {:error, reason} -> finalize(%{data | phase: :finalizing, result: {:error, reason}})
    end
  end

  def handle_event(:info, {:checkpoint, %State{} = state}, phase, data)
      when phase in [:running, :cancelling] do
    {:keep_state, publish_checkpoint(data, state)}
  end

  def handle_event(:info, {:exchange_finished, pid, outcome}, phase, data)
      when phase in [:running, :cancelling] do
    if current_worker?(data, pid) do
      finalize(apply_outcome(data, outcome))
    else
      # A stale worker (a pid that is no longer the current one) can never end this exchange.
      log_ignored(phase, data, {:stale_exchange_finished, pid})
      {:keep_state, data}
    end
  end

  def handle_event(:info, {:DOWN, _ref, :process, pid, reason}, phase, data) do
    cond do
      phase == :finalizing ->
        {:keep_state, data}

      current_worker?(data, pid) and reason in [:normal, :shutdown] ->
        # The worker ended WITHOUT reporting an outcome: nothing to finalize, so this run simply
        # ends. (An abnormal exit below is what the scheduler's crash/retry path must see.)
        {:stop, :normal, data}

      current_worker?(data, pid) ->
        {:stop, reason, data}

      true ->
        log_ignored(phase, data, {:stale_down, pid, reason})
        {:keep_state, data}
    end
  end

  def handle_event(:info, msg, phase, data) do
    # Anything outside this session's contract (a stray cast/plain send) lands
    # here: logged at debug and ignored, so it can never be mistaken for a real
    # event.
    log_ignored(phase, data, msg)
    {:keep_state, data}
  end

  def handle_event({:call, from}, :inspect, phase, data) do
    {:keep_state, data, [{:reply, from, {:ok, %{state: data.state, phase: phase}}}]}
  end

  def handle_event({:call, from}, :history, _phase, data) do
    {:keep_state, data, [{:reply, from, {:ok, messages(data.state)}}]}
  end

  def handle_event({:call, from}, {:input, message}, phase, data)
      when phase in [:running, :cancelling] and (is_binary(message) or is_map(message)) do
    if phase == :cancelling do
      # A cancelling run accepts ONLY the engine's own grace turns: the cancel message already
      # arrived through the pending-message drain, so injecting new work here would contradict
      # the save-work contract (the agent must commit and report, not start something new).
      {:keep_state, data, [{:reply, from, {:error, :finished}}]}
    else
      {:keep_state, data, [{:reply, from, append_input(data, message)}]}
    end
  end

  def handle_event({:call, from}, {:cancel, :graceful}, :running, data) do
    agent_id = agent_id(data)

    Store.set_cancel_requested(agent_id)
    Summary.publish(agent_id, data.state, status: :cancelling)

    # The worker STAYS ALIVE: the engine's 3-turn save-work grace must run on this run.
    {:next_state, :cancelling, %{data | phase: :cancelling}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:cancel, :graceful}, :cancelling, data) do
    # Idempotent: an already-cancelling run has satisfied a second graceful cancel.
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:cancel, :force}, phase, data)
      when phase in [:running, :cancelling] do
    shutdown_worker(data)

    # No result delivery: a force-killed run has no outcome to report.
    {:stop_and_reply, :shutdown, [{:reply, from, :ok}], data}
  end

  def handle_event({:call, from}, _request, phase, data) do
    # An unsupported call (or one arriving in a phase that cannot serve it, e.g. a late `input`)
    # is still ANSWERED, so no caller can hang on a session that cannot serve it.
    log_ignored(phase, data, {:unsupported_call, from})
    {:keep_state, data, [{:reply, from, {:error, :not_found}}]}
  end

  def handle_event(event_type, event, phase, data) do
    # Other gen_statem event types (a stray cast/timeout) must never crash the session.
    log_ignored(phase, data, {event_type, event})
    {:keep_state, data}
  end

  # --- start up ---

  # REGISTRATION SEEDING ONLY: the scheduler row is read ONCE at session start to
  # build the owned `%EvoGit.Agent.State{}`; the loop never reads it for a
  # conversation/loop value.
  defp scheduler_row(ctx) do
    agent_id = Keyword.fetch!(ctx, :agent_id)

    case Store.get_agent_state(agent_id) do
      {:ok, row} ->
        {:ok, row}

      :error ->
        Logger.error("AgentSession #{agent_id}: no scheduler row; cannot start the exchange")
        {:error, :not_registered}
    end
  end

  defp build_state(ctx, row) do
    spec = Keyword.fetch!(ctx, :spec)
    repo_less = Keyword.get(ctx, :repo_less) == true
    meta = Keyword.fetch!(ctx, :meta)

    # Every key `Setup.build_initial_state/3` fetches, plus the ctx-derived ones. The identity
    # and model fields come from the SAME scheduler row the old ETS reads supplied; only
    # `prompt_cache_key` is not on the row struct yet, hence `Map.get/2`.
    state_ctx = [
      agent_id: Keyword.fetch!(ctx, :agent_id),
      depth: Keyword.fetch!(ctx, :depth),
      context_node: row.context_node,
      repo_path: agent_repo_path(ctx, repo_less),
      repo_root: Keyword.fetch!(ctx, :repo_root),
      repo_id: Keyword.fetch!(ctx, :repo_id),
      repo_less: repo_less,
      task_id: Map.get(meta, :task_id),
      parent_id: row.parent_id,
      archive: row.archive,
      foreign_repos: row.foreign_repos,
      repo_notes: row.repo_notes,
      max_turns: row.max_turns,
      max_depth: row.max_depth,
      max_retries: row.max_retries,
      compression_count: row.compression_count,
      llm_context_window: row.llm_context_window,
      llm_model: row.llm_model,
      llm_generation_params: row.llm_generation_params,
      model_spec: row.model_spec,
      provider_profile_id: row.provider_profile_id,
      model_id: row.model_id,
      model_id_locked: row.model_id_locked,
      prompt_cache_key: Map.get(row, :prompt_cache_key),
      quality_level: Keyword.get(spec.opts, :quality_level),
      custom_agent_id: Keyword.get(spec.opts, :custom_agent_id),
      attachments: Keyword.get(spec.opts, :attachments)
    ]

    Setup.build_initial_state(spec.agent_module, spec.objective, state_ctx)
  end

  defp agent_repo_path(ctx, repo_less) do
    cond do
      repo_less -> Keyword.get(ctx, :repo_less_repo_path) || Keyword.fetch!(ctx, :repo_root)
      true -> Keyword.fetch!(ctx, :worktree_path)
    end
  end

  defp start_worker(state, data) do
    ctx = data.dispatch_ctx
    opts = [tmpdir: data.tmpdir] ++ Keyword.get(ctx, :exchange_opts, [])

    Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, Worker, :run, [state, self(), opts])
  end

  # --- running ---

  defp publish_checkpoint(data, %State{} = state) do
    data = %{data | state: state}

    # Coalesced: at most ONE summary write per turn, never one per chunk, and `context` is
    # preserved by `Summary`'s merge-onto-the-existing-row behaviour.
    if data.last_published_turn == state.turn do
      data
    else
      Summary.publish(agent_id(data), state)
      %{data | last_published_turn: state.turn}
    end
  end

  defp append_input(data, message) do
    # `append_pending_user_message/2` is the settled P2 transport: it stores the message on the
    # agent's row and answers `:ok | {:error, :not_found}`. Anything else is reported as the same
    # documented not-found outcome, so a caller never sees an undocumented shape.
    case Store.append_pending_user_message(agent_id(data), message) do
      :ok -> :ok
      _other -> {:error, :not_found}
    end
  end

  defp apply_outcome(data, {:finish, %State{} = state, %Result{} = result}) do
    # The worker already refreshed the commit sha against the post-fallback worktree HEAD.
    %{data | state: state, result: {:ok, result}}
  end

  defp apply_outcome(data, {:error, reason}) do
    # Delivered VERBATIM: an error outcome is never converted into a raise or a success.
    %{data | result: {:error, reason}}
  end

  defp apply_outcome(data, other) do
    Logger.warning("AgentSession #{Kernel.inspect(agent_id(data))}: unexpected exchange outcome")
    %{data | result: {:error, {:unexpected_exchange_outcome, other}}}
  end

  # --- finalize ---

  # Terminal delivery, EXACTLY ONCE (one private function, one caller each for the success,
  # failure and start-failure paths).
  defp finalize(data) do
    data = %{data | phase: :finalizing}

    publish_final(data)
    deliver_result(data)

    {:stop, :normal, %{data | phase: :done}}
  end

  defp publish_final(%{state: %State{} = state} = data) do
    Summary.publish(agent_id(data), state, final_extra(data))
  end

  # A start failure can happen before any state exists: there is nothing to merge onto the row.
  defp publish_final(_data), do: :ok

  defp final_extra(%{result: {:ok, %Result{commit_sha: sha}}} = _data) when is_binary(sha) do
    [status: :done, current_commit: sha]
  end

  defp final_extra(%{result: {:error, _reason}}), do: [status: :failed]
  defp final_extra(_data), do: [status: :done]

  defp deliver_result(data) do
    # NON-BLOCKING and best-effort: no reachable scheduler is skipped silently.
    # The target is the `:scheduler` pid the dispatch context carries (set by
    # `Dispatch.do_try_dispatch/4` to the scheduler that started this session, so
    # a named/test scheduler instance is served), falling back to the registered
    # name. Sent BEFORE the stop, so the monitor `:DOWN` can never overtake it.
    case Keyword.get(data.dispatch_ctx, :scheduler) || Process.whereis(EvoGit.AgentScheduler) do
      nil -> :ok
      scheduler -> send(scheduler, {:agent_session_result, agent_id(data), self(), data.result})
    end
  end

  # --- helpers ---

  defp call(target, request, timeout) do
    with {:ok, pid} <- resolve(target) do
      try do
        :gen_statem.call(pid, request, timeout)
      catch
        # `:gen_statem.call/3` EXITS on a dead, stopping or unresponsive session (`:noproc`,
        # `:normal`, `:timeout`): every public function is TOTAL, so the exit becomes the
        # documented fallback instead of leaking out of the API.
        :exit, _reason -> {:error, :not_found}
      end
    else
      _other -> {:error, :not_found}
    end
  end

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(agent_id) do
    # An UNSTARTED registry (a runtime without the application tree) must degrade to the same
    # fallback as a missing key rather than raising.
    if Process.whereis(SessionRegistry) do
      case Registry.lookup(SessionRegistry, agent_id) do
        [{pid, _value}] when is_pid(pid) -> {:ok, pid}
        _other -> :error
      end
    else
      :error
    end
  end

  defp current_worker?(%{worker: %Task{pid: pid}}, pid) when is_pid(pid), do: true
  defp current_worker?(_data, _pid), do: false

  defp shutdown_worker(%{worker: %Task{} = worker}) do
    Task.shutdown(worker, :brutal_kill)
    :ok
  end

  defp shutdown_worker(_data), do: :ok

  defp messages(%State{context: %{messages: messages}}) when is_list(messages), do: messages
  defp messages(_state), do: []

  defp agent_id(%{dispatch_ctx: ctx}), do: Keyword.get(ctx, :agent_id)

  defp log_ignored(phase, data, event) do
    Logger.debug(fn ->
      "AgentSession #{Kernel.inspect(agent_id(data))} (#{Kernel.inspect(phase)}) ignoring " <>
        Kernel.inspect(event)
    end)

    :ok
  end
end
