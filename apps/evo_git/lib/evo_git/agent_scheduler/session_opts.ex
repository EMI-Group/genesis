defmodule EvoGit.AgentScheduler.SessionOpts do
  @moduledoc """
  Pure `keyword() -> {:ok, %EvoGit.AgentSpec{}} | {:error, term()}` builder for
  `EvoGit.AgentScheduler.start_session/1`.

  The scheduler's `start_session/1` accepts EITHER a ready `%AgentSpec{}` or a
  plain keyword list; this module owns the second form so the interactive
  entry point does not need the full runtime phase plumbing (a deliberate
  subset of `EvoGit.Runtime.SelfReflective.build_spec/2`, which is the model
  for the model-selection handling here).

  ## Accepted keys

  Required:

  - `:agent_module` — the module implementing `use EvoGit.Agent`
  - `:objective` — the initial user message (binary)

  Optional:

  - `:path` — absolute path of a git repo to run in. It is loaded as a
    `%EvoGit.Core.ContextNode{}` at `:node_path` and anchored on a
    `%EvoGit.Core.PhyloGraphNode{}` at the repo's current HEAD. `nil`/`""`/
    absent means REPO-LESS: the node keeps a `"[system]"` repo placeholder,
    `phylo_node` is `nil` and the spec opts carry `repo_less: true`.
  - `:repo_less` — no worktree; with `:path` the context tree is loaded from
    that directory, without it the node keeps the `[system]` placeholder. A
    truthy value wins over `:path` being set, so "repo-less but context-tree
    backed" (the `EvoGit.Runtime.SelfReflective.build_spec/2` shape) is
    expressible: no `%PhyloGraphNode{}`, no worktree, `repo_less: true` in the
    spec opts.
  - `:node_path` — in-repo relative path inside the context tree (default `"./"`)
  - `:task_id`, `:model_id`, `:model_spec`, `:archive`, `:attachments`,
    `:quality_level`, `:foreign_repos`, `:repo_notes`, `:notify`,
    `:session_mode` — forwarded into the spec opts verbatim (model selection is
    normalized through `EvoGit.Runtime.Helpers.normalize_model_selection_opts/1`,
    exactly like the self-reflective builder, so an explicit `:model_spec` wins
    over a legacy `:model_id` and locks the selection)

  `:depth` / `:parent_id` are accepted ONLY as `0` / `nil`: interactive
  sessions are root-only in v1 (a subagent that lives across exchanges never
  satisfies the parent's exact-count subagent barrier).

  Every rejected input answers `{:error, {:invalid_session_opts, detail}}` (or
  `{:error, {:interactive_root_only, message}}` / `{:error,
  {:unsupported_session_mode, value}}`) — this module never raises on caller
  input.
  """

  require Logger

  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Runtime.Helpers

  # Keys consumed here (never forwarded into the spec opts).
  @consumed_keys [:agent_module, :objective, :path, :node_path, :depth, :parent_id]

  # The sched-meta table the scheduler's `@sched_table` names; `idle_sessions/0`
  # guards on `:ets.whereis/1` because that read is a cheap PUBLIC ETS read.
  @sched_table :evogit_sched_meta

  @session_modes %{
    "interactive" => :interactive,
    "oneshot" => :oneshot,
    interactive: :interactive,
    oneshot: :oneshot
  }

  @doc """
  Builds the `%EvoGit.AgentSpec{}` for an interactive (or explicitly one-shot)
  session from a keyword list. Returns `{:ok, spec}` or a descriptive error.
  """
  @spec build(keyword()) :: {:ok, AgentSpec.t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with {:ok, agent_module} <- fetch_agent_module(opts),
         {:ok, objective} <- fetch_objective(opts),
         {:ok, node_path} <- fetch_node_path(opts),
         :ok <- validate_root_only(opts),
         {:ok, mode} <- fetch_session_mode(opts) do
      {:ok, build_spec(agent_module, objective, node_path, mode, opts)}
    end
  end

  def build(other), do: {:error, {:invalid_session_opts, {:not_a_keyword_list, other}}}

  @doc """
  Reads and normalizes an explicit `:session_mode` value. `nil` (absent) means
  "not specified" and is returned as `nil`.
  """
  @spec fetch_session_mode(keyword()) :: {:ok, :oneshot | :interactive | nil} | {:error, term()}
  def fetch_session_mode(opts) when is_list(opts) do
    case Keyword.get(opts, :session_mode) do
      nil -> {:ok, nil}
      mode -> normalize_mode(mode)
    end
  end

  @doc """
  Normalizes one explicit session-mode value (atom or string form). Unknown
  values answer `{:error, {:unsupported_session_mode, value}}`.
  """
  @spec normalize_mode(term()) :: {:ok, :oneshot | :interactive} | {:error, term()}
  def normalize_mode(mode) when is_atom(mode) or is_binary(mode) do
    case Map.fetch(@session_modes, mode) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:unsupported_session_mode, mode}}
    end
  end

  def normalize_mode(mode), do: {:error, {:unsupported_session_mode, mode}}

  # --- required/validated keys ---

  defp fetch_agent_module(opts) do
    case Keyword.get(opts, :agent_module) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      other -> {:error, {:invalid_session_opts, {:invalid_agent_module, other}}}
    end
  end

  defp fetch_objective(opts) do
    case Keyword.get(opts, :objective) do
      objective when is_binary(objective) -> {:ok, objective}
      other -> {:error, {:invalid_session_opts, {:invalid_objective, other}}}
    end
  end

  defp fetch_node_path(opts) do
    case Keyword.get(opts, :node_path, "./") do
      node_path when is_binary(node_path) ->
        # `ContextNode.load/2` (via `normalize_relpath/1`) RAISES on an absolute
        # path, so a caller error is answered here instead of raised deep in
        # the loader.
        if EvoGit.Platform.absolute_path?(node_path) do
          {:error, {:invalid_session_opts, {:absolute_node_path, node_path}}}
        else
          {:ok, node_path}
        end

      other ->
        {:error, {:invalid_session_opts, {:invalid_node_path, other}}}
    end
  end

  # Interactive sessions are root-only in v1: the subagent barrier is an exact
  # count, which a child that lives across exchanges would never satisfy.
  defp validate_root_only(opts) do
    depth = Keyword.get(opts, :depth)
    parent_id = Keyword.get(opts, :parent_id)

    cond do
      depth not in [nil, 0] ->
        {:error,
         {:interactive_root_only,
          "interactive sessions are root-only (depth must be 0 or absent, got: #{inspect(depth)})"}}

      not is_nil(parent_id) ->
        {:error,
         {:interactive_root_only,
          "interactive sessions are root-only (parent_id must be absent, got: #{inspect(parent_id)})"}}

      true ->
        :ok
    end
  end

  # --- spec assembly ---

  defp build_spec(agent_module, objective, node_path, mode, opts) do
    path = repo_path(opts)

    cond do
      # `:repo_less` wins over a set `:path`: no worktree and no phylo node,
      # while the context tree is still loaded from that directory.
      Keyword.get(opts, :repo_less) ->
        build_repo_less_spec(agent_module, objective, node_path, mode, opts, path)

      is_binary(path) ->
        build_repo_spec(agent_module, objective, node_path, mode, opts, path)

      true ->
        # Repo-less (Assistant) shape — no phylo node, no worktree.
        build_repo_less_spec(agent_module, objective, node_path, mode, opts, nil)
    end
  end

  # The blank/absent `:path` keeps the `"[system]"` repo placeholder; with a
  # path the context tree loads from that directory (repo-less, still backed by
  # a real context tree).
  defp build_repo_less_spec(agent_module, objective, node_path, mode, opts, path) do
    context_node = ContextNode.load(node_path, path || "[system]")

    spec_opts =
      opts
      |> spec_opts(mode)
      |> Keyword.delete(:repo_less)
      |> Keyword.put(:repo_less, true)

    AgentSpec.new(context_node, nil, agent_module, objective, spec_opts)
  end

  defp repo_path(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> path
      _blank -> nil
    end
  end

  defp build_repo_spec(agent_module, objective, node_path, mode, opts, path) do
    case PhyloGraphNode.current_head(path) do
      {:ok, head_sha} ->
        AgentSpec.new(
          ContextNode.load(node_path, path),
          PhyloGraphNode.new(path, head_sha),
          agent_module,
          objective,
          spec_opts(opts, mode)
        )

      {:error, reason} ->
        {:error, {:invalid_session_opts, {:not_a_git_repo, path, reason}}}
    end
  end

  # Forwarded spec opts: the caller's keys minus the ones consumed here, with
  # model selection normalized through the SAME helper the runtime phases use
  # (an explicit :model_spec wins over a legacy :model_id and forces the lock).
  defp spec_opts(opts, mode) do
    opts
    |> Keyword.drop(@consumed_keys)
    |> Keyword.delete(:session_mode)
    |> Helpers.normalize_model_selection_opts()
    |> maybe_put_mode(mode)
  end

  defp maybe_put_mode(opts, nil), do: opts
  defp maybe_put_mode(opts, mode), do: Keyword.put(opts, :session_mode, mode)

  # --- scheduler-side session bookkeeping ---
  #
  # Called from `EvoGit.AgentScheduler`'s client functions / `handle_call`s and
  # kept here so the hub module stays a hub. They are NOT pure (they read and
  # write the scheduler's ETS mirror, broadcast the roster and cast to the task
  # registry), but each one is TOTAL: a missing table, registry or row degrades
  # to its documented default instead of raising.

  @doc """
  Forces `session_mode: :interactive` into a ready spec's opts.

  `EvoGit.AgentScheduler.start_session/1` is the interactive entry point, so the
  mode always wins over whatever the caller put there. Returns `{:ok, spec}`.
  """
  @spec force_interactive(AgentSpec.t()) :: {:ok, AgentSpec.t()}
  def force_interactive(%AgentSpec{} = spec) do
    {:ok, %{spec | opts: Keyword.put(spec.opts || [], :session_mode, :interactive)}}
  end

  @doc """
  Every `:awaiting_input` agent as `%{agent_id, task_id, session_pid,
  task_number, mode}` (see `EvoGit.AgentScheduler.list_awaiting_input/0`).

  A cheap public ETS read — no scheduler call — answering `[]` when nothing is
  idle or the sched-meta table is absent.
  """
  @spec idle_sessions() :: [
          %{
            agent_id: pos_integer(),
            task_id: String.t() | nil,
            session_pid: pid() | nil,
            task_number: pos_integer() | nil,
            mode: EvoGit.AgentScheduler.SchedMeta.mode()
          }
        ]
  def idle_sessions do
    case :ets.whereis(@sched_table) do
      :undefined ->
        []

      _tid ->
        for {agent_id, %SchedMeta{status: :awaiting_input} = meta} <- Store.list_sched_meta() do
          %{
            agent_id: agent_id,
            task_id: meta.task_id,
            session_pid: meta.session_pid,
            task_number: meta.task_number,
            mode: meta.mode
          }
        end
    end
  end

  @doc """
  The ONE staleness admission for session signals (`:agent_session_yield` /
  `:agent_session_resumed`), mirroring the session-RESULT rule: a signal is
  admitted when the agent still has no recorded session pid (already recycled,
  or being retried) or when the sender IS its current session.
  """
  @spec admit_signal(pos_integer(), pid()) ::
          {:ok, SchedMeta.t()} | {:stale, pid() | nil} | :unknown
  def admit_signal(agent_id, session_pid) do
    case Store.get_sched_meta(agent_id) do
      {:ok, %SchedMeta{session_pid: nil} = meta} -> {:ok, meta}
      {:ok, %SchedMeta{session_pid: ^session_pid} = meta} -> {:ok, meta}
      {:ok, %SchedMeta{session_pid: other}} -> {:stale, other}
      :error -> :unknown
    end
  end

  @doc """
  Best-effort task-row status flip for an idle/resumed session.

  It is a CAST to `EvoGit.TaskRegistry`, so a missing or restarting registry is
  a silent no-op — no rescue is needed or wanted, and the scheduler never blocks
  on it. A session without a task id skips it.
  """
  @spec update_task_status(String.t() | nil, atom()) :: :ok
  def update_task_status(task_id, status) when is_binary(task_id) do
    EvoGit.TaskRegistry.update_task_status(task_id, status)
  end

  def update_task_status(_task_id, _status), do: :ok

  @doc """
  Mirrors the session MODE onto the freshly registered `SchedMeta` row, which
  defaults to `:oneshot`. The mode is derived from the spec opts
  `start_session/1` already forced, and is what `idle_sessions/0` reports.
  """
  @spec mark_mode(EvoGit.AgentScheduler.State.t(), pos_integer(), AgentSpec.t()) ::
          EvoGit.AgentScheduler.State.t()
  def mark_mode(state, agent_id, %AgentSpec{opts: opts}) do
    mode =
      case fetch_session_mode(opts || []) do
        {:ok, :interactive} -> :interactive
        _other -> :oneshot
      end

    case Store.get_sched_meta(agent_id) do
      {:ok, %SchedMeta{mode: ^mode}} ->
        state

      {:ok, %SchedMeta{} = meta} ->
        Store.put_sched_meta(agent_id, %{meta | mode: mode})
        state

      :error ->
        state
    end
  end

  @doc false
  def log_stale_signal(status, agent_id, session_pid, other) do
    Logger.debug(
      "AgentScheduler: ignoring session signal #{inspect(status)} from stale session " <>
        "#{inspect(session_pid)} for agent #{agent_id} (current: #{inspect(other)})"
    )
  end

  @doc false
  def log_unknown_signal(status, agent_id, session_pid) do
    Logger.debug(
      "AgentScheduler: ignoring session signal #{inspect(status)} for unknown agent " <>
        "#{inspect(agent_id)} from #{inspect(session_pid)}"
    )
  end
end
