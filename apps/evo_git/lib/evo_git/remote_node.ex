defmodule EvoGit.RemoteNode.Defnode do
  @moduledoc false

  # Module-level macro generating the mechanical node-dispatch wrapper body
  # shared by the identity-unwrap RPC functions in `EvoGit.RemoteNode`:
  # a direct local call when `node == node()` (no error catching — local
  # bugs surface truthfully), otherwise the `call_remote/4` erpc route with
  # the plain `{:ok, r} -> r; {:error, e} -> {:error, e}` identity unwrap.
  #
  # Only functions whose remote branch is EXACTLY that identity-unwrap
  # pattern are migrated through this macro; per-function RPC failure
  # fallbacks (`[]`/`%{}`/`nil`/`false`/bool-guards/`{:error, :rpc_failed}`)
  # stay hand-written. The macro invocation mirrors the underlying local
  # call — e.g. `defnode EvoGit.AgentScheduler.RemoteAPI.cancel_task(task_id)`
  # — so the generated wrapper's name/args are always in lockstep with the
  # delegated module function. Default args (`arg \\ value`) are kept in the
  # generated head and stripped from the call sites.
  defmacro defnode(local_call) do
    {{:., _, [mod, fun]}, _, args} = local_call
    node = Macro.var(:node, __MODULE__)

    clean_args =
      Enum.map(args, fn
        {:\\, _, [lhs, _default]} -> lhs
        other -> other
      end)

    quote do
      def unquote(fun)(unquote(node), unquote_splicing(args)) do
        if unquote(node) == node() do
          unquote(mod).unquote(fun)(unquote_splicing(clean_args))
        else
          case call_remote(
                 unquote(node),
                 unquote(mod),
                 unquote(fun),
                 [unquote_splicing(clean_args)]
               ) do
            {:ok, result} -> result
            {:error, reason} -> {:error, reason}
          end
        end
      end
    end
  end
end

defmodule EvoGit.RemoteNode do
  @moduledoc """
  Core-runtime cross-node RPC helper for remote (SSH) dashboard connections.

  Thin wrappers over `:erpc.call/5` that let a caller read scheduler state
  (agents, config, paused?) from a *remote* node exactly as it reads it
  locally. Local calls go directly to `EvoGit.AgentScheduler.RemoteAPI` /
  `EvoGit.AgentScheduler`; remote calls are routed through `:erpc` with a
  bounded timeout.

  All functions are safe to call from any process.
  """

  # Default RPC timeout (milliseconds) for cross-node :erpc.call/5 — used as
  # the fallback when the `:remote_rpc_timeout` application env key is unset.
  # The env key is read at CALL time (see rpc_timeout/0), so the timeout can
  # be tuned at runtime (e.g. via config or tests) without recompiling.
  @default_rpc_timeout 30_000

  require EvoGit.RemoteNode.Defnode
  import EvoGit.RemoteNode.Defnode

  @doc """
  Evaluates `apply(module, function, args)` on the given node, returning
  `{:ok, result}` on success or `{:error, reason}` on any failure.

  For the **local node** (`node == node()`), the function is called directly
  via `apply/3` and the result wrapped in `{:ok, result}` — no error catching,
  so local bugs surface truthfully.

  For a **remote node**, the call is routed through `:erpc.call/5` with a
  bounded timeout. The timeout is read at call time from the application env
  key `:remote_rpc_timeout` (`Application.get_env(:evo_git,
  :remote_rpc_timeout, #{@default_rpc_timeout})` — default
  `#{@default_rpc_timeout}` ms = 30 s), so it can be tuned at runtime without
  recompiling. `:erpc.call/5` returns the
  bare result on success, but *raises/throws* on every failure mode: an erpc
  failure (node down, timeout) raises `{erpc, reason}`, and a remote-function
  failure re-raises the original exception/exit/throw. All of these are
  normalized into `{:error, reason}` here.
  """
  @spec call_remote(node(), module(), atom(), [term()]) ::
          {:ok, term()} | {:error, term()}
  def call_remote(node, module, function, args) do
    if node == node() do
      # Local node — call directly. Do NOT catch errors; let local bugs
      # surface. The only normalization is wrapping the bare result.
      {:ok, apply(module, function, args)}
    else
      # Remote node — route through :erpc.call/5.
      #
      # Justified try/catch — cross-node RPC boundary. :erpc.call/5 returns
      # the bare result on success but raises/throws on ANY failure (erpc
      # failure such as node-down/timeout, or a remote exception/exit/throw).
      # The API contract is to return {:ok, _} | {:error, _}, so every failure
      # mode is normalized into {:error, reason} here. This is the correct
      # pattern for a boundary with untrusted/remote execution.
      try do
        result = :erpc.call(node, module, function, args, rpc_timeout())
        {:ok, result}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end
  end

  @doc false
  # Resolves the cross-node RPC timeout at CALL time from the application env
  # key `:remote_rpc_timeout`, falling back to `@default_rpc_timeout` (30 s)
  # when unset. Public (`@doc false`) so tests can pin the env override; the
  # local-node path of call_remote/4 never uses this value.
  @spec rpc_timeout() :: pos_integer()
  def rpc_timeout do
    Application.get_env(:evo_git, :remote_rpc_timeout, @default_rpc_timeout)
  end

  @doc """
  Lists agent summaries for the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_agents/0`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `[]` if the remote call fails.
  """
  @spec list_agents(node()) :: [map()]
  def list_agents(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_agents()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_agents, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns recent system samples from the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.get_recent_system_samples/0` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `{:ok, samples}` on success or `{:error, reason}` on failure
  (including RPC failure).
  """
  @spec get_recent_system_samples(node()) :: {:ok, term()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.get_recent_system_samples())

  @doc """
  Returns the conversation history for an agent on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.get_agent_history/1` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. Returns `[]` if
  the remote call fails.
  """
  @spec get_agent_history(node(), pos_integer()) :: [map()]
  def get_agent_history(node, agent_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_agent_history(agent_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_agent_history, [
             agent_id
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a plain-map snapshot of the full agent state on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_agent_state/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `nil` if the remote call fails.
  """
  @spec get_agent_state(node(), pos_integer()) :: map() | nil
  def get_agent_state(node, agent_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_agent_state(agent_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_agent_state, [
             agent_id
           ]) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> nil
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Returns the resolved scheduler configuration on the given node.

  On the local node, calls `EvoGit.AgentScheduler.get_config/0` directly (a
  GenServer call on the local scheduler). On a remote node, routes the call
  through `:erpc` via `call_remote/4`. Returns `%{}` if the remote call fails.
  """
  @spec get_config(node()) :: map()
  def get_config(node) do
    if node == node() do
      EvoGit.AgentScheduler.get_config()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_config, []) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> %{}
        {:error, _reason} -> %{}
      end
    end
  end

  @doc """
  Triggers a config reload on the given node's AgentScheduler.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.reload_config/0`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec reload_config(node()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.reload_config())

  @doc """
  Saves a config map to the given node's config file on disk.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.save_user_config/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec save_user_config(node(), map()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.save_user_config(config))

  @doc """
  Saves a credentials map to the given node's credentials file on disk.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.save_credentials/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec save_credentials(node(), map()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.save_credentials(creds))

  @doc """
  Returns the config health status on the given node.

  On the local node, calls `EvoGit.Config.config_status/0` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns a
  safe degraded status map if the remote call fails.
  """
  @spec get_config_status(node()) :: map()
  def get_config_status(node) do
    if node == node() do
      EvoGit.Config.config_status()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_config_status, []) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> degraded_config_status()
        {:error, _reason} -> degraded_config_status()
      end
    end
  end

  @doc """
  Returns `true` if the scheduler on the given node is paused.

  On the local node, calls `EvoGit.AgentScheduler.paused?/0` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `false` if the remote call fails.
  """
  @spec paused?(node()) :: boolean()
  def paused?(node) do
    if node == node() do
      EvoGit.AgentScheduler.paused?()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :paused?, []) do
        {:ok, bool} when is_boolean(bool) -> bool
        {:ok, _other} -> false
        {:error, _reason} -> false
      end
    end
  end

  @doc """
  Runs an LLM connectivity test on the given node.

  On the local node, calls `EvoGit.SystemCheck.llm_test/2` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns the
  result tuple `{:ok, _} | {:error, _}` directly.
  """
  @spec llm_test(node(), term(), term()) :: {:ok, term()} | {:error, term()}
  defnode(EvoGit.SystemCheck.llm_test(model, gen_opts))

  @doc """
  Sends a user message to a running agent on the given node.

  `message` is either a legacy plain `String.t()` or a `%{text:, attachments:}`
  map carrying images/audio (see `EvoGit.Attachments.message/1`) — it is passed
  through verbatim to the agent's pending-message queue, which the runner's
  drain materializes as a user message (media allowed for an agent at ANY
  depth; there is no root gate on injected messages).

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.send_agent_message/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure (including
  RPC failures such as node down or timeout).
  """
  @spec send_agent_message(node(), pos_integer(), String.t() | map()) ::
          {:ok, term()} | {:error, term()}
  def send_agent_message(node, agent_id, message) do
    if node == node() do
      {:ok, EvoGit.AgentScheduler.RemoteAPI.send_agent_message(agent_id, message)}
    else
      call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :send_agent_message, [agent_id, message])
    end
  end

  # ── Interactive agent sessions ──────────────────────────────────────
  #
  # The interactive-session RPC surface. An interactive session lives inside the
  # scheduler's own VM (in-memory state, in-memory transcript), so a caller on
  # another node reaches it through these wrappers around the node's
  # `EvoGit.AgentScheduler.RemoteAPI`. Each one is the usual `call_remote/4`
  # identity unwrap: the local node calls `RemoteAPI` directly (no error
  # catching — local bugs surface truthfully) and a remote node routes through
  # `:erpc.call/5` with the call-time `:remote_rpc_timeout`.

  @doc """
  Starts an INTERACTIVE agent session on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.start_session/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `{:ok, agent_id}` — the handle for `send_session_message/4`,
  `await_close/3` and `list_awaiting_input/1` — the node's own
  `{:error, {:start_session_failed, reason}}`, or the RPC failure reason
  (`{:error, {kind, reason}}`) when the transport fails.
  """
  @spec start_session(node(), EvoGit.AgentSpec.t() | keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.start_session(spec_or_opts))

  @doc """
  Sends a user message to an interactive session on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.send_session_message/3` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. `policy` is
  `:queue` (default) or `:interrupt`.

  Returns `:ok`, the session's own `{:error, {:session, reason}}` term, or the
  RPC failure reason (`{:error, {kind, reason}}`).
  """
  @spec send_session_message(
          node(),
          pos_integer() | pid(),
          String.t() | EvoGit.Attachments.message(),
          :queue | :interrupt
        ) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.send_session_message(target, message, policy \\ :queue))

  @doc """
  Closes an interactive session on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.close_session/2`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. `reason` defaults to `:normal`.

  Returns `:ok`, the session's own `{:error, {:session, reason}}` term, or the
  RPC failure reason (`{:error, {kind, reason}}`).
  """
  @spec close_session(node(), pos_integer() | pid(), term()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.close_session(target, reason \\ :normal))

  @doc """
  Blocks until the interactive session for `agent_id` reaches its terminal
  outcome on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.await_close/2`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns the terminal outcome verbatim
  (`{:ok, %EvoGit.Agent.Result{}}` or the session's own `{:error, reason}` term).

  `timeout` (milliseconds, default 30 000) bounds the WAIT only: an expired
  budget answers `{:error, :timeout}` and the session keeps running. Across
  nodes the erpc transport ALSO imposes the call-time `:remote_rpc_timeout`
  (30 s by default) on the whole call, so the effective wait is bounded by the
  node RPC timeout: awaiting a HUMAN-driven session for minutes is only
  supported through the LOCAL API (`EvoGit.AgentScheduler` /
  `EvoGit.AgentScheduler.RemoteAPI`), while the cross-node form is for short
  waits and observation.
  """
  @spec await_close(node(), pos_integer(), timeout()) ::
          {:ok, EvoGit.Agent.Result.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.await_close(agent_id, timeout \\ 30_000))

  @doc """
  Lists the agents on the given node currently parked at `:awaiting_input`.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_awaiting_input/0`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `[]` when the remote call fails or answers something
  other than a list, mirroring the other list wrappers here.
  """
  @spec list_awaiting_input(node()) :: [map()]
  def list_awaiting_input(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_awaiting_input()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_awaiting_input, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Watches a live agent on the given node: subscribes the CALLING process to the
  agent's delta topic, registers it as a watcher on the OWNING node and returns
  the current snapshot plus its `seq`.

  This is the push-only attach. Once it answers, `{:agent_delta, agent_id, seq,
  batch}` messages are PUSHED to the calling process until `unwatch_agent/2` or
  until it dies (the session `Process.monitor/1`s the caller, across nodes too) —
  there is no poll loop and no replay buffer.

  ## The CALLER subscribes, never the RPC target

  `:erpc.call/5` runs its target in a NEW remote worker process, so a subscription
  made inside `EvoGit.AgentScheduler.RemoteAPI` would attach that throwaway worker
  and the caller would never receive a delta. The subscription is therefore made
  HERE, on the caller's OWN node, with `EvoGit.Agent.Stream.subscribe/1` — BEFORE
  the watcher registration, so no delta can fall between the two.
  `EvoGit.PubSub` is a cluster-aware PG2 bus, so a broadcast published on the
  owning node reaches a subscriber anywhere in the cluster; the cluster must be
  CONNECTED (and PubSub running on both nodes) for deltas to arrive.

  ## Reconciliation

  Every delta carries a monotonic `seq`. A delta whose `seq` is `<=` the returned
  snapshot's `seq` is stale and must be DROPPED (`EvoGit.Agent.Stream.stale?/2`).
  The snapshot is the ONLY resync: after a gap, a reconnect or a lost delta call
  `watch_snapshot/2` again and continue from the returned `seq` — nothing is ever
  replayed.

  Returns the FLAT `{:ok, %EvoGit.Agent.Stream.Snapshot{}, seq}` (the snapshot
  carries the session's FULL transcript, so this is a heavy read like
  `get_agent_history/1`) or `{:error, {kind, reason}}` — `{:not_found, _}` /
  `{:bad_state, _}` from the owning node, the subscribe refusal, or the RPC
  failure. Any failure undoes the local subscription, so a refused watch leaves no
  residue.
  """
  @spec watch_agent(node(), pos_integer() | String.t()) ::
          {:ok, EvoGit.Agent.Stream.Snapshot.t(), non_neg_integer()}
          | {:error, {atom(), term()}}
  def watch_agent(node, agent_id) do
    case EvoGit.Agent.Stream.subscribe(agent_id) do
      :ok ->
        case register_watcher_on(node, agent_id) do
          {:ok, _snapshot, _seq} = ok ->
            ok

          {:error, _reason} = error ->
            EvoGit.Agent.Stream.unsubscribe(agent_id)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Stops watching an agent on the given node: unregisters the calling process on
  the OWNING node and unsubscribes it from the delta topic HERE.

  Idempotent on a live session (a duplicate unwatch is `:ok`, because unregistering a missing
  watcher is not an error), and the local subscription is ALWAYS undone — even when the owning
  session is already gone (a local subscription dies with its process anyway).

  Returns `:ok`, or `{:error, {kind, reason}}` when the owning node refuses the unregistration
  (an unknown/gone session or an RPC failure); that error is informational, since the caller has
  already stopped receiving deltas.
  """
  @spec unwatch_agent(node(), pos_integer() | String.t()) :: :ok | {:error, {atom(), term()}}
  def unwatch_agent(node, agent_id) do
    result = unregister_watcher_on(node, agent_id)
    EvoGit.Agent.Stream.unsubscribe(agent_id)
    result
  end

  @doc """
  Reads one bounded snapshot of an agent on the given node, registering and
  subscribing NOTHING.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.watch_snapshot/1` directly; on a remote node,
  routes the call through `:erpc` via `call_remote/4`. This is the ONLY resync path
  of the push contract — a consumer that fell behind or reconnected asks once here
  and drops `seq <= snapshot.seq` deltas afterwards.

  Returns the FLAT `{:ok, %EvoGit.Agent.Stream.Snapshot{}, seq}` (a heavy read: the
  snapshot carries the FULL transcript) or `{:error, {kind, reason}}`.
  """
  @spec watch_snapshot(node(), pos_integer() | String.t()) ::
          {:ok, EvoGit.Agent.Stream.Snapshot.t(), non_neg_integer()}
          | {:error, {atom(), term()}}
  def watch_snapshot(node, agent_id) do
    reply =
      if node == node() do
        EvoGit.AgentScheduler.RemoteAPI.watch_snapshot(agent_id)
      else
        case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :watch_snapshot, [agent_id]) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end

    normalize_watch_reply(reply)
  end

  # --- watch verbs: internals ---

  # Registers the CALLING process on the OWNING node. `self()` is deliberately the
  # caller's pid: across nodes that is an EXTERNAL pid, which the session accepts and
  # monitors like a local one (a remote monitor is a cross-node signal).
  defp register_watcher_on(node, agent_id) do
    reply =
      if node == node() do
        EvoGit.AgentScheduler.RemoteAPI.register_watcher(agent_id, self())
      else
        case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :register_watcher, [
               agent_id,
               self()
             ]) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end

    normalize_watch_reply(reply)
  end

  defp unregister_watcher_on(node, agent_id) do
    reply =
      if node == node() do
        EvoGit.AgentScheduler.RemoteAPI.unregister_watcher(agent_id, self())
      else
        case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :unregister_watcher, [
               agent_id,
               self()
             ]) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end

    case reply do
      :ok -> :ok
      # An unregistration is idempotent: any non-error reply means there is no watcher left.
      {:error, {kind, reason}} when is_atom(kind) -> {:error, {kind, reason}}
      _other -> :ok
    end
  end

  # The flat watch shape. A nested `{:ok, {:ok, snapshot, seq}}` (an RPC unwrap accident)
  # and any shape this phase does not answer yet are refusals, never successes.
  defp normalize_watch_reply({:ok, %EvoGit.Agent.Stream.Snapshot{} = snapshot, seq})
       when is_integer(seq),
       do: {:ok, snapshot, seq}

  defp normalize_watch_reply({:error, {kind, reason}}) when is_atom(kind),
    do: {:error, {kind, reason}}

  defp normalize_watch_reply({:error, reason}), do: {:error, {:not_found, reason}}
  defp normalize_watch_reply(_other), do: {:error, {:not_found, :watch_not_supported}}

  @doc """
  Approves or denies a pending command-approval request on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.respond_approval/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. `decision` is
  `:approve` or `:deny`.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure
  (including RPC failures such as node down or timeout).
  """
  @spec respond_approval(node(), String.t(), :approve | :deny) ::
          {:ok, term()} | {:error, term()}
  def respond_approval(node, request_id, decision) do
    if node == node() do
      {:ok, EvoGit.AgentScheduler.RemoteAPI.respond_approval(request_id, decision)}
    else
      call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :respond_approval, [request_id, decision])
    end
  end

  @doc """
  Lists all tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks/0` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `[]` if the remote call fails.
  """
  @spec list_tasks(node()) :: [EvoGit.TaskInfo.t()]
  def list_tasks(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a paginated slice of tasks on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_tasks_paginated/1` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. Returns `{[], 0}`
  if the remote call fails.
  """
  @spec list_tasks_paginated(node(), keyword()) ::
          {[EvoGit.TaskInfo.t()], non_neg_integer()}
  def list_tasks_paginated(node, opts \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_paginated(opts)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_paginated, [
             opts
           ]) do
        {:ok, {list, count}} when is_list(list) -> {list, count}
        {:ok, _other} -> {[], 0}
        {:error, _reason} -> {[], 0}
      end
    end
  end

  @doc """
  Returns one LIGHTWEIGHT page of task summaries plus the filtered total on the
  given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.select_tasks_page/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. The heavy JSON blobs (`result`, `logs`, `usage`) are never
  transferred — each row is the 16-key summary projection — and the per-agent
  archive lives in its own table (see `list_task_archives/3`).

  Returns `%{rows: [map()], total: non_neg_integer}`; `%{rows: [], total: 0}`
  when the remote call fails.
  """
  @spec list_tasks_page(node(), keyword()) :: %{rows: [map()], total: non_neg_integer()}
  def list_tasks_page(node, opts \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.select_tasks_page(opts)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :select_tasks_page, [opts]) do
        {:ok, %{rows: rows, total: total} = page} when is_list(rows) and is_integer(total) -> page
        {:ok, _other} -> %{rows: [], total: 0}
        {:error, _reason} -> %{rows: [], total: 0}
      end
    end
  end

  @doc """
  Returns the set of unique project paths with tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_unique_paths/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.
  """
  @spec get_unique_paths(node()) :: [String.t()]
  def get_unique_paths(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_unique_paths()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_unique_paths, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `[]` if the remote call fails.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses.
  """
  @spec list_tasks_summary(node(), [atom()]) :: [map()]
  def list_tasks_summary(node, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary(statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_summary, [statuses]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a minimal id/status/updated_at projection for tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_task_ids/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. The
  returned maps have `id`, `status` (atom), and `updated_at` (raw ISO string).
  """
  @spec list_task_ids(node(), [atom()]) :: [map()]
  def list_task_ids(node, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_task_ids(statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_task_ids, [statuses]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries filtered to a specific project_path on the given node.
  """
  @spec list_tasks_summary_by_path(node(), String.t(), [atom()]) :: [map()]
  def list_tasks_summary_by_path(node, path, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary_by_path(path, statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_summary_by_path, [
             path,
             statuses
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries updated since an ISO-8601 timestamp on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks_changed_since/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.

  `since_iso` is a fixed-precision ISO-8601 string; the returned summary-shaped
  maps include an `updated_at` key.
  """
  @spec list_tasks_changed_since(node(), String.t()) :: [map()]
  def list_tasks_changed_since(node, since_iso) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_changed_since(since_iso)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_changed_since, [
             since_iso
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Gracefully cancels a task on the given node.

  The task enters a `:cancelling` grace period: agents are notified to save
  their work and finish cleanly; the task is finally persisted `:cancelled`
  when the wrapper completes. On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.cancel_task/1` directly. On a remote node,
  routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec cancel_task(node(), String.t()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.cancel_task(task_id))

  @doc """
  Force-kills a task on the given node — the BRUTAL cancellation path (no
  grace period): agents are killed, the wrapper is brutal-killed, and the task
  is immediately persisted `:failed`. Works from `:running` or `:cancelling`.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.force_kill_task/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec force_kill_task(node(), String.t()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.force_kill_task(task_id))

  @doc """
  Deletes a task on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.delete_task/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec delete_task(node(), String.t()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.delete_task(task_id))

  @doc """
  Returns a single task by id on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_task/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `nil` if the remote call fails (or if the task
  does not exist).
  """
  @spec get_task(node(), String.t()) :: EvoGit.TaskInfo.t() | nil
  def get_task(node, task_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_task(task_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_task, [task_id]) do
        {:ok, result} -> result
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Returns a single task by id WITHOUT the heavy payload on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_task_lite/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. The per-agent archive is a separate table — see
  `list_task_archives/3` and `get_agent_archive/3`.

  Returns `%TaskInfo{}` or `nil` (absent task, or a failed remote call).
  """
  @spec get_task_lite(node(), String.t()) :: EvoGit.TaskInfo.t() | nil
  def get_task_lite(node, task_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_task_lite(task_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_task_lite, [task_id]) do
        {:ok, result} -> result
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Returns one page of a task's archived agents plus that task's total archive
  row count on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_task_archives/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. Entries are
  STRING-KEYED maps ordered `depth ASC, agent_id ASC`; `opts` accepts `:limit`,
  `:offset` and `:include_results` (default `false` — the heavy `result` column
  is then not selected and the `"result"` key is ABSENT).

  Returns `%{entries: [map()], total: non_neg_integer}`; degraded to
  `%{entries: [], total: 0}` when the remote call fails.
  """
  @spec list_task_archives(node(), String.t(), keyword()) ::
          %{entries: [map()], total: non_neg_integer() | nil}
  def list_task_archives(node, task_id, opts \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_task_archives(task_id, opts)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_task_archives, [
             task_id,
             opts
           ]) do
        {:ok, %{entries: entries, total: total} = page}
        when is_list(entries) and is_integer(total) ->
          page

        {:ok, _other} ->
          %{entries: [], total: 0}

        {:error, _reason} ->
          %{entries: [], total: 0}
      end
    end
  end

  @doc """
  Returns ONE archived agent's full entry (including `"result"`) on the given
  node, or `nil`.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.get_agent_archive/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`.

  Returns a STRING-KEYED `map()`, or `nil` (no such archived agent, or a failed
  remote call).
  """
  @spec get_agent_archive(node(), String.t(), integer()) :: map() | nil
  def get_agent_archive(node, task_id, agent_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_agent_archive(task_id, agent_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_agent_archive, [
             task_id,
             agent_id
           ]) do
        {:ok, entry} when is_map(entry) -> entry
        {:ok, _other} -> nil
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Sets the review status for a task on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.set_review_status/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec set_review_status(node(), String.t(), atom()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.set_review_status(task_id, status))

  @doc """
  Sets the review metadata (base and commit SHAs) for a task on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.set_review_metadata/3` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec set_review_metadata(node(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.set_review_metadata(task_id, base_sha, commit_sha))

  @doc """
  Clears all finished tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.clear_finished_tasks/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec clear_finished_tasks(node()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.clear_finished_tasks())

  @doc """
  Fetches the full content of a file at a specific commit on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.get_file_content/3` directly (which
  delegates to `EvoGit.Review.get_file_content/3`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  Returns `{:ok, content}` if the file exists at that commit, or
  `{:error, {tag, output}}` if not. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec get_file_content(node(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.get_file_content(repo_path, commit_sha, file_path))

  @doc """
  Lists commits between the merge-base and a branch tip on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_commits/2`
  directly (which delegates to `EvoGit.Review.list_commits/2`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns `{:ok, [%EvoGit.Review.CommitInfo{}]}` or `{:error, reason}`. On
  RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec list_commits(node(), String.t(), String.t()) ::
          {:ok, [EvoGit.Review.CommitInfo.t()]} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_commits(repo_path, branch_name))

  @doc """
  Returns the commit-graph data for a set of git ranges on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_commit_graph/3` directly (which
  delegates to `EvoGit.CommitGraph.for_ranges/3`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the git log runs inside the
  remote VM against the remote filesystem.

  `ranges` is a list of `{base_ref, tip_ref}` 2-tuples and `opts` a keyword
  list (`:limit`). Returns `{:ok, %{commits: [commit], refs: %{sha => [ref]}}}`
  or `{:error, {kind, reason}}` on RPC failure.
  """
  @spec list_commit_graph(node(), String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_commit_graph(repo_path, ranges, opts))

  @doc """
  Returns the TASK-SCOPED commit-graph data for a task on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_task_commit_graph/4` directly (which
  delegates to `EvoGit.TaskCommitGraph.for_task/4`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the task-row lookup and the
  git log run inside the remote VM against the remote filesystem.

  `task_id` identifies the persisted task whose durable refs
  (`commit_sha`/`branch_name` + result `"repos"` entries) seed the graph,
  `repo_path` is the absolute repository path, `live_tips` a list of live agent
  tip SHA/ref strings (nils allowed) and `opts` a keyword list (`:limit`,
  optional `:base_sha`/`:foreign_repos`). Returns
  `{:ok, %{commits: [commit], refs: %{sha => [ref]}, truncated: boolean}}`
  (`truncated: true` when any tip range was cut at `opts[:limit]`, carried
  verbatim through the local and `:erpc` paths) or
  `{:error, {kind, reason}}` on RPC failure.
  """
  @spec list_task_commit_graph(node(), String.t(), String.t(), [String.t() | nil], keyword()) ::
          {:ok, map()} | {:error, term()}
  defnode(
    EvoGit.AgentScheduler.RemoteAPI.list_task_commit_graph(task_id, repo_path, live_tips, opts)
  )

  @doc """
  Loads all review data (diff stat, full diff, parsed files) for a branch on
  the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_review_data/2` directly (which
  delegates to `EvoGit.Review.load_review_data/2`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  Returns `{:ok, review_data_map}` or an error tuple. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_data(node(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.load_review_data(repo_path, branch_name))

  @doc """
  Loads review metadata only (file list with counts, no diffs) for a branch
  on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_review_metadata/2` directly (which
  delegates to `EvoGit.Review.load_review_metadata/2`). On a remote node,
  routes the call through `:erpc` via `call_remote/4` so the review operation
  runs inside the remote VM against the remote filesystem.

  Returns `{:ok, review_data_map}` or an error tuple. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_metadata(node(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.load_review_metadata(repo_path, branch_name))

  @doc """
  Loads the diff of a single file between two commits on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_file_diff/4` directly (which
  delegates to `EvoGit.Review.load_file_diff/4`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  Returns the diff result from `EvoGit.Review` verbatim. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec load_file_diff(node(), String.t(), String.t(), String.t(), String.t()) :: term()
  defnode(
    EvoGit.AgentScheduler.RemoteAPI.load_file_diff(repo_path, base_sha, commit_sha, file_path)
  )

  @doc """
  Loads the diff of a single file between two commits on the given node,
  with options.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_file_diff/5` directly (which
  delegates to `EvoGit.Review.load_file_diff/5`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  `opts` is a keyword list of options (e.g. context lines). Returns the diff
  result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_file_diff(node(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          term()
  defnode(
    EvoGit.AgentScheduler.RemoteAPI.load_file_diff(
      repo_path,
      base_sha,
      commit_sha,
      file_path,
      opts
    )
  )

  @doc """
  Loads review metadata from explicit base/commit SHAs on the given node (no
  branch resolution).

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_review_metadata_from_shas/3` directly
  (which delegates to `EvoGit.Review.load_review_metadata_from_shas/3`). On a
  remote node, routes the call through `:erpc` via `call_remote/4` so the
  review operation runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_metadata_from_shas(node(), String.t(), String.t(), String.t()) :: term()
  defnode(
    EvoGit.AgentScheduler.RemoteAPI.load_review_metadata_from_shas(
      repo_path,
      base_sha,
      commit_sha
    )
  )

  @doc """
  Lists commits between explicit base/commit SHAs on the given node (no
  branch resolution).

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_commits_from_shas/3` directly (which
  delegates to `EvoGit.Review.list_commits_from_shas/3`). On a remote node,
  routes the call through `:erpc` via `call_remote/4` so the review operation
  runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec list_commits_from_shas(node(), String.t(), String.t(), String.t()) :: term()
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_commits_from_shas(repo_path, base_sha, commit_sha))

  @doc """
  Lists the files changed in a single commit on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_commit_files/2` directly (which
  delegates to `EvoGit.Review.load_commit_files/2`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_commit_files(node(), String.t(), String.t()) :: term()
  defnode(EvoGit.AgentScheduler.RemoteAPI.load_commit_files(repo_path, commit_sha))

  @doc """
  Loads the diff of a single file within a single commit on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.load_commit_file_diff/3` directly (which
  delegates to `EvoGit.Review.load_commit_file_diff/3`). On a remote node,
  routes the call through `:erpc` via `call_remote/4` so the review operation
  runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_commit_file_diff(node(), String.t(), String.t(), String.t()) :: term()
  defnode(EvoGit.AgentScheduler.RemoteAPI.load_commit_file_diff(repo_path, commit_sha, file_path))

  @doc """
  Merges an agent branch into the repository's default merge target on the
  given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.merge_branch/2`
  directly (which delegates to `EvoGit.Review.merge_branch/2`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns `{:ok, sha}` on success, `{:conflict, details}` on a merge conflict,
  or `{:error, reason}` on failure. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec merge_branch(node(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.merge_branch(repo_path, branch_name))

  @doc """
  Merges an agent branch into an explicit target branch on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.merge_branch/3`
  directly (which delegates to `EvoGit.Review.merge_branch/3`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns `{:ok, sha}` on success, `{:conflict, details}` on a merge conflict,
  or `{:error, reason}` on failure. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec merge_branch(node(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.merge_branch(repo_path, branch_name, target_branch))

  @doc """
  Checks whether a branch or commit SHA can be merged into an explicit target
  branch on the given node without conflicts.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.check_merge/3`
  directly (which delegates to `EvoGit.Review.check_merge/3`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns `{:ok, :clean}` on a conflict-free merge,
  `{:ok, {:conflict, files}}` when the merge would conflict, or
  `{:error, reason}` on failure. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec check_merge(node(), String.t(), String.t(), String.t()) ::
          {:ok, :clean} | {:ok, {:conflict, term()}} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.check_merge(repo_path, branch_or_sha, target_branch))

  @doc """
  Resolves the default merge target branch for a repository on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.default_merge_target/1` directly (which
  delegates to `EvoGit.Review.default_merge_target/1`). On a remote node,
  routes the call through `:erpc` via `call_remote/4` so the review operation
  runs inside the remote VM against the remote filesystem.

  Returns `{:ok, branch_name}` (`main` → `master` → `dev` → `prod` → current
  → first local branch) or `{:error, :no_branch_found}`. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec default_merge_target(node(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.default_merge_target(repo_path))

  @doc """
  Lists all local branches in a repository on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_branches/1`
  directly (which delegates to `EvoGit.Review.list_branches/1`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns `{:ok, [String.t()]}` or `{:error, {tag, output}}`. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec list_branches(node(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_branches(repo_path))

  @doc """
  Rejects (deletes) an agent branch in a repository on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.reject_branch/2`
  directly (which delegates to `EvoGit.Review.reject_branch/2`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec reject_branch(node(), String.t(), String.t()) :: term()
  defnode(EvoGit.AgentScheduler.RemoteAPI.reject_branch(repo_path, branch_name))

  @doc """
  Creates a GitHub pull request for an agent branch on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.create_github_pr/4` directly (which
  delegates to `EvoGit.Review.create_github_pr/4`). On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the review operation runs
  inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec create_github_pr(node(), String.t(), String.t(), String.t(), String.t()) :: term()
  defnode(
    EvoGit.AgentScheduler.RemoteAPI.create_github_pr(repo_path, branch_name, objective, result)
  )

  @doc """
  Gets the GitHub upstream information for a repository on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.github_upstream/1`
  directly (which delegates to `EvoGit.Adapters.GitHub.github_upstream/1`). On
  a remote node, routes the call through `:erpc` via `call_remote/4` so the
  git command runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Adapters.GitHub` verbatim. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec github_upstream(node(), String.t()) :: term()
  defnode(EvoGit.AgentScheduler.RemoteAPI.github_upstream(repo_path))

  @doc """
  Lists GitHub issues of a repository's upstream on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_github_issues/2`
  directly (which delegates to `EvoGit.Adapters.GitHub.list_github_issues/2`).
  On a remote node, routes the call through `:erpc` via `call_remote/4` so the
  gh command runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Adapters.GitHub` verbatim. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec list_github_issues(node(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_github_issues(repo_path, opts \\ []))

  @doc """
  Fetches a GitHub issue of a repository's upstream on the given node and
  composes it into a deterministic Markdown string.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.github_issue_markdown/2` directly (which
  delegates to `EvoGit.Adapters.GitHub.github_issue_markdown/2`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the gh command
  runs inside the remote VM against the remote filesystem.

  Returns the result from `EvoGit.Adapters.GitHub` verbatim. On RPC failure,
  returns `{:error, {kind, reason}}`.
  """
  @spec github_issue_markdown(node(), String.t(), integer() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.github_issue_markdown(repo_path, number))

  @doc """
  Checks whether a branch exists in a repository on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.branch_exists?/2`
  directly (which delegates to `EvoGit.Review.branch_exists?/2`). On a remote
  node, routes the call through `:erpc` via `call_remote/4` so the review
  operation runs inside the remote VM against the remote filesystem.

  Returns a boolean. On RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec branch_exists?(node(), String.t(), String.t()) :: boolean() | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.branch_exists?(repo_path, branch_name))

  @doc """
  Lists the Virtual Context Tree project mounts of the given node, newest first.
  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.projects/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[%EvoGit.VCT.Mount{}]`, degrading to `[]` when the remote call fails
  or returns something else.
  """
  @spec projects(node()) :: [EvoGit.VCT.Mount.t()]
  def projects(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.projects()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :projects, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Mounts an OS project path in the Virtual Context Tree of the given node.
  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.mount_project/2`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `{:ok, %EvoGit.VCT.Mount{}}` or `{:error, reason}`; a failed RPC
  returns `{:error, {kind, reason}}` so the caller can report it.
  """
  @spec mount_project(node(), String.t(), String.t() | nil) ::
          {:ok, EvoGit.VCT.Mount.t()} | {:error, term()}
  def mount_project(node, path, name) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.mount_project(path, name)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :mount_project, [path, name]) do
        {:ok, {:ok, mount}} -> {:ok, mount}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Forgets one project mount on the given node by VCT point or OS path.
  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.forget_project/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `:ok`, `{:error, :not_found}`, `{:error, :invalid_point}` or a failed
  RPC's `{:error, {kind, reason}}`.
  """
  @spec forget_project(node(), term()) :: :ok | {:error, term()}
  def forget_project(node, key) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.forget_project(key)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :forget_project, [key]) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Lists custom agents on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_custom_agents/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  The `agents.toml` file lives per-node (next to `config.toml`), so this reads
  the node being viewed — not the local dashboard's file.

  Returns `{:ok, %{agents: [...], model_selection_script: script_or_nil,
  script_status: status}}` on success or `{:error, reason}` on failure
  (including RPC failures such as node down or timeout).
  """
  @spec list_custom_agents(node()) :: {:ok, map()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.list_custom_agents())

  @doc """
  Saves a custom agent definition on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.save_custom_agent/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`,
  so the definition is written to the remote node's own `agents.toml`.

  Returns `{:ok, definition}` on success or `{:error, reason}` on failure
  (validation errors from `EvoGit.CustomAgents.save/1`, or RPC failures such
  as node down or timeout).
  """
  @spec save_custom_agent(node(), map()) :: {:ok, map()} | {:error, atom() | term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.save_custom_agent(def))

  @doc """
  Deletes a custom agent definition on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.delete_custom_agent/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`,
  so the deletion applies to the remote node's own `agents.toml`.

  Returns `:ok` on success or `{:error, reason}` on failure (`:not_found` when
  no agent has that id, or RPC failures such as node down or timeout).
  """
  @spec delete_custom_agent(node(), String.t()) :: :ok | {:error, :not_found | term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.delete_custom_agent(id))

  @doc """
  Saves the model-selection script on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.save_model_selection_script/1` directly. On
  a remote node, routes the call through `:erpc` via `call_remote/4`, so the
  script is written to the remote node's own `agents.toml`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec save_model_selection_script(node(), String.t()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.save_model_selection_script(script))

  @doc """
  Invalidates the model-selector compile cache on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.reload_custom_agents/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`,
  so the remote node's `EvoGit.CustomAgents.ModelSelector` cache is invalidated.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec reload_custom_agents(node()) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.reload_custom_agents())

  @doc """
  Returns the custom-tools loader status on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.custom_tools_status/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  The `<config_dir>/tools/` directory lives per-node (next to `config.toml`), so
  this inspects the node being viewed — not the local dashboard's directory.

  Declared via `defnode` because `EvoGit.CustomTools.status/0` never raises and
  never returns an `{:error, _}` tuple, so the remote branch is exactly the
  identity-unwrap pattern. This matches the closest sibling RPC family (the
  custom-agents group), whose tests assert RPC failures surface as
  `{:error, reason}`. This wrapper therefore intentionally does NOT swallow RPC
  failures into an empty `%{ok: [], errors: []}` map — a silent swallow would
  hide a real RPC/backend problem.

  Returns the status map verbatim on the local node or on remote success, or
  `{:error, {kind, reason}}` on remote RPC failure (node down, timeout, remote
  raise). The status map is `%{ok: [%{name, file, module, read_only?: boolean}],
  errors: [%{file, reason}]}`.
  """
  @spec custom_tools_status(node()) ::
          %{
            ok: [%{name: String.t(), file: String.t(), module: module(), read_only?: boolean()}],
            errors: [%{file: String.t(), reason: String.t()}]
          }
          | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.custom_tools_status())

  @doc """
  Returns filesystem path suggestions for the given node.

  On the local node, calls `EvoGit.PathSuggestions.suggest/1` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4` — the
  remote daemon resolves paths against its own filesystem. Returns `[]` if
  the remote call fails.
  """
  @spec list_path_suggestions(node(), String.t() | nil) :: [String.t()]
  def list_path_suggestions(node, value) do
    if node == node() do
      EvoGit.PathSuggestions.suggest(value)
    else
      case call_remote(node, EvoGit.PathSuggestions, :suggest, [value]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns whether `path` is a directory on the given node.

  On the local node, calls `File.dir?/1` directly. On a remote node, routes
  the call through `:erpc` via `call_remote/4` so the check runs on the
  remote daemon's filesystem. Returns `false` if the remote call fails.
  """
  @spec dir?(node(), String.t()) :: boolean()
  def dir?(node, path) do
    if node == node() do
      File.dir?(path)
    else
      case call_remote(node, File, :dir?, [path]) do
        {:ok, bool} when is_boolean(bool) -> bool
        {:ok, _other} -> false
        {:error, _reason} -> false
      end
    end
  end

  @doc """
  Starts a task on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.start_task/2`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `{:ok, %EvoGit.TaskInfo{}}` on success or `{:error, reason}` on failure
  (including RPC failures such as node down or timeout).
  """
  @spec start_task(node(), atom(), keyword()) :: {:ok, EvoGit.TaskInfo.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.start_task(task_type, opts))

  @doc """
  Checks whether a file exists on the given node's filesystem.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.file_exists?/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `false` if the remote call fails.
  """
  @spec file_exists?(node(), String.t()) :: boolean()
  def file_exists?(node, path) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.file_exists?(path)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :file_exists?, [path]) do
        {:ok, bool} when is_boolean(bool) -> bool
        {:ok, _other} -> false
        {:error, _reason} -> false
      end
    end
  end

  @doc """
  Lists files and directories in a given path on the given node's filesystem.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.ls/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `{:error, :rpc_failed}` if the remote call fails.
  """
  @spec ls(node(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def ls(node, path) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.ls(path)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :ls, [path]) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :rpc_failed}
      end
    end
  end

  @doc """
  Reads and parses the `genesis.toml` project config on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.read_project_config/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `nil` if the remote call fails or the config file does not exist.
  """
  @spec read_project_config(node(), String.t()) :: map() | nil
  def read_project_config(node, path) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.read_project_config(path)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :read_project_config, [path]) do
        {:ok, result} -> result
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Lists the OS executions `EvoGit.ProcessManager` tracks on the given node,
  newest first.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_processes/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Every documented filter is accepted (`:agent_id`,
  `:task_id`, `:kind`, `:status`, `:backend`).

  Returns `[]` when the remote call fails (or answers something other than a
  list), mirroring the other list wrappers here.
  """
  @spec list_processes(node(), keyword()) :: [EvoGit.ProcessManager.Execution.t()]
  def list_processes(node, opts \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_processes(opts)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_processes, [opts]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Fetches ONE tracked execution by id (`"proc-<n>"`) from the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_process/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `{:ok, %EvoGit.ProcessManager.Execution{}}`, `{:error, :not_found}`,
  `{:error, :process_manager_unavailable}` or the RPC failure reason.
  """
  @spec get_process(node(), String.t()) ::
          {:ok, EvoGit.ProcessManager.Execution.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.get_process(id))

  @doc """
  Probes ONE execution's live resource usage on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.process_stats/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `{:ok, stats}`, the manager's own error (`{:error, :not_found}`,
  `{:error, :not_running}`, `{:error, :process_manager_unavailable}`, …) or the
  RPC failure reason.
  """
  @spec process_stats(node(), String.t()) ::
          {:ok, EvoGit.ProcessManager.Stats.t()} | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.process_stats(id))

  @doc """
  Applies one control action (`:pause`, `:resume`, `:kill` or
  `{:signal, signal}`) to a tracked execution on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.process_control/3` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. `reason` is
  recorded on the execution's `control_log`; the actor is `:remote`.

  Returns `:ok`, the manager's own error (`{:error, :not_found}`,
  `{:error, :terminal}`, `{:error, :invalid_signal}`, …),
  `{:error, {:unknown_action, action}}` or the RPC failure reason.
  """
  @spec process_control(
          node(),
          String.t(),
          EvoGit.AgentScheduler.RemoteAPI.process_control_action(),
          term()
        ) :: :ok | {:error, term()}
  defnode(EvoGit.AgentScheduler.RemoteAPI.process_control(id, action, reason))

  # Safe degraded config-status map returned when a remote config-status RPC
  # fails. Matches the shape of EvoGit.Config.config_status/0 so callers see a
  # well-formed (but unhealthy) status rather than a crash.
  defp degraded_config_status do
    %{ok?: false, missing: [], warnings: [], validation_errors: []}
  end
end
