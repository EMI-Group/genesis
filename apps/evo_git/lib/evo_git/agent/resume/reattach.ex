defmodule EvoGit.Agent.Resume.Reattach do
  @moduledoc """
  Batch-level SUBAGENT re-attach for a crash-resumed parent agent.

  A parent agent blocks inside `EvoGit.AgentScheduler.spawn_sub_agents/2` while
  its children run, so the batch it was waiting on OUTLIVES the crashed exchange
  worker: the scheduler keeps the batch on the parent's `%SchedMeta{}` row and
  `EvoGit.AgentScheduler.reattach_sub_agents/3` hands it to the retried parent
  exactly once.

  This module is the ONE caller of that API on the resume path. It issues ONE
  call for the WHOLE interrupted batch (`expected_count` = how many `:subagent`
  tool calls the crashed turn had), maps the answered batch onto those calls BY
  POSITION (sub-agent index ↔ subagent-call order), merges every same-repo
  child's commit into the parent worktree, and hands back

    * `:texts` — the real, UNCHANGED
      `EvoGit.Agent.SubagentProcessing.format_subagent_result/1` text of each
      subagent call, keyed by that call's MODEL CALL INDEX (its position in the
      assistant message's `tool_calls`). A call with NO entry gets
      `EvoGit.Agent.Resume.ToolBatch`'s honest fallback text, because its real
      answer cannot be used: the slot answered `{:error, :subagent_result_lost}`,
      the scheduler refused the batch, the reply was malformed, the formatting
      raised, or its same-repo work could not be merged;
    * `:merge_note` — the ordinary
      `EvoGit.Agent.SubagentProcessing.build_merge_message/4` note for a merge
      that changed HEAD, or `nil`.

  ## Why the merge is not optional

  The resumed parent's worktree is based on the SALVAGED commit while a child's
  commits live on the child's own branch. Formatting the child's result without
  merging would report work that is not actually present in the parent's tree —
  the child's changes would be silently absent from every later diff, review and
  final commit. So every real same-repo result is merged here through the same
  ownership-aware `perform_merge/3` (`EvoGit.Agent.ContextMerge`) the spawn path
  uses, and branches whose work landed are deleted the same way.

  Cross-repo children (`result.repo_id` a DIFFERENT non-nil id) are never
  merged — the spawn path does not merge those either.

  ## Totality

  A `%EvoGit.Agent.Result{}` carries `result`, `commit_sha`, `branch` and
  `repo_id` only, so the child's `node_path`, `agent_module` and `objective` are
  re-derived BEST-EFFORT from the interrupted call and the parent state; an
  absent `node_path` never breaks the merge (`EvoGit.Agent.ContextMerge`
  normalizes an absent node to the root, the most permissive ownership), it only
  logs a `:warning`.

  Every step that can raise — the scheduler call, the formatting, the node-path
  derivation and the merge — is guarded and logs at `:warning`:

    * the scheduler call / formatting fail per BATCH or per SLOT, degrading those
      calls to the fallback text;
    * a merge that cannot RUN (a raise, or no parent worktree path) degrades the
      affected calls to the fallback text and appends no note — reporting a
      completion whose work is absent would be a lie;
    * a merge that RUNS keeps the real text and reports the ordinary note, even
      when that report is a conflict/error (`build_merge_message/4`), exactly
      like the spawn path.

  The deliberate, bounded blocking wait inside `reattach_sub_agents/3` is the
  ONLY non-total step and it is guarded here.
  """

  require Logger

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.Agent.SubagentProcessing

  @typedoc """
  `:texts` maps a MODEL CALL INDEX to that call's real formatted result.
  """
  @type t :: %{texts: %{non_neg_integer() => String.t()}, merge_note: String.t() | nil}

  @default_reattach_fun &EvoGit.AgentScheduler.reattach_sub_agents/2

  @doc """
  The DEFAULT re-attach injection: the real scheduler API, arity 2.
  """
  @spec default_reattach_fun() :: (term(), non_neg_integer() -> term())
  def default_reattach_fun, do: @default_reattach_fun

  @doc """
  Answers the interrupted subagent batch of `state`.

  `slots` is the interrupted turn's `:subagent` calls in MODEL CALL ORDER, each
  `{model_call_index, call}` — so slot position `i` corresponds to the
  scheduler's sub-agent index `i`.

  Options:

    * `:reattach_fun` — `fn agent_id, expected_count -> reply`, defaulting to
      `&EvoGit.AgentScheduler.reattach_sub_agents/2`.

  Total: an empty slot list returns no texts and no note without calling
  anything.
  """
  @spec resolve(State.t(), [{non_neg_integer(), term()}], keyword()) :: t()
  def resolve(state, slots, opts \\ [])

  def resolve(%State{}, [], _opts), do: empty()

  def resolve(%State{} = state, slots, opts) when is_list(slots) do
    try do
      do_resolve(state, slots, opts)
    rescue
      error ->
        degrade(state, length(slots), Exception.format(:error, error, __STACKTRACE__))
    catch
      kind, reason ->
        degrade(state, length(slots), Exception.format(kind, reason, __STACKTRACE__))
    end
  end

  def resolve(_state, _slots, _opts), do: empty()

  @doc """
  The empty answer: no real texts (every call gets the fallback text) and no
  merge note.
  """
  @spec empty() :: t()
  def empty, do: %{texts: %{}, merge_note: nil}

  ## Batch

  defp do_resolve(%State{} = state, slots, opts) do
    expected = length(slots)

    case reattach(state, expected, opts) do
      {:ok, results} when is_list(results) ->
        adopt(state, slots, results)

      {:error, reason} ->
        Logger.warning(
          "Resume: no subagent batch to re-attach for agent #{inspect(state.agent_id)} " <>
            "(#{inspect(reason)}); answering #{expected} interrupted subagent call(s) with " <>
            "the fallback text"
        )

        empty()

      other ->
        Logger.warning(
          "Resume: unexpected subagent re-attach reply for agent #{inspect(state.agent_id)}: " <>
            "#{inspect(other)}; answering #{expected} interrupted subagent call(s) with " <>
            "the fallback text"
        )

        empty()
    end
  end

  defp reattach(%State{agent_id: agent_id}, expected, opts) do
    case Keyword.get(opts, :reattach_fun) || @default_reattach_fun do
      fun when is_function(fun, 2) -> fun.(agent_id, expected)
      other -> {:error, {:invalid_reattach_fun, other}}
    end
  end

  defp adopt(%State{} = state, slots, results) do
    {texts, children} =
      slots
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{index, call}, position}, {texts, children} ->
        case Enum.at(results, position) do
          {:ok, %Result{} = result} ->
            case result_text(state, result) do
              nil ->
                {texts, children}

              text ->
                children =
                  case merge_child(state, index, call, result) do
                    nil -> children
                    {index, child} -> [{index, child} | children]
                  end

                {Map.put(texts, index, text), children}
            end

          _lost_or_malformed ->
            {texts, children}
        end
      end)

    children = Enum.reverse(children)

    # A merge that could not even RUN leaves the children's work out of the
    # parent worktree, so the affected calls degrade to the fallback text rather
    # than reporting a completion whose work is silently absent. A merge that
    # ran and reported conflicts/errors keeps the real text plus the ordinary
    # note (exactly what the spawn path does).
    case safe_merge(state, Enum.map(children, &elem(&1, 1))) do
      {:ok, note} -> %{texts: texts, merge_note: note}
      :degraded -> %{texts: drop(texts, Enum.map(children, &elem(&1, 0))), merge_note: nil}
    end
  end

  defp drop(texts, indices) do
    Enum.reduce(indices, texts, &Map.delete(&2, &1))
  end

  ## One slot

  defp result_text(%State{} = state, %Result{} = result) do
    try do
      case SubagentProcessing.format_subagent_result({:ok, result}) do
        text when is_binary(text) and text != "" ->
          text

        other ->
          Logger.warning(
            "Resume: formatting a re-attached subagent result for agent " <>
              "#{inspect(state.agent_id)} produced #{inspect(other)}; using the fallback text"
          )

          nil
      end
    rescue
      error ->
        Logger.warning(
          "Resume: formatting a re-attached subagent result for agent " <>
            "#{inspect(state.agent_id)} failed (#{Exception.message(error)}); " <>
            "using the fallback text"
        )

        nil
    catch
      kind, reason ->
        Logger.warning(
          "Resume: formatting a re-attached subagent result for agent " <>
            "#{inspect(state.agent_id)} failed (#{inspect({kind, reason})}); " <>
            "using the fallback text"
        )

        nil
    end
  end

  # A child is mergeable when its result belongs to the PARENT's repo: `nil`
  # (legacy results carry no repo id) or exactly `state.repo_id`. A different
  # non-nil id is a foreign-repo child — the spawn path never merges those.
  defp merge_child(%State{} = state, index, call, %Result{} = result) do
    if same_repo?(state, result) and is_binary(result.commit_sha) do
      {index,
       SubagentProcessing.merge_child(
         index,
         result,
         node_path(state, call),
         state.agent_module,
         call_arg(call, :objective)
       )}
    end
  end

  defp same_repo?(%State{}, %Result{repo_id: nil}), do: true
  defp same_repo?(%State{repo_id: repo_id}, %Result{repo_id: repo_id}), do: true
  defp same_repo?(_state, _result), do: false

  ## Best-effort derivation of the child's node path

  # `%Result{}` does not carry the node path, so it is re-derived from the
  # interrupted call's `path` argument exactly the way a spawn resolves it. Any
  # failure logs and answers `nil`, which `ContextMerge` treats as root ownership
  # — it can only under-drop conflicts, never lose a commit.
  defp node_path(%State{} = state, call) do
    try do
      do_node_path(state, call)
    rescue
      error ->
        warn_node_path(state, call, Exception.message(error))
        nil
    catch
      kind, reason ->
        warn_node_path(state, call, inspect({kind, reason}))
        nil
    end
  end

  defp do_node_path(%State{} = state, call) do
    raw = call_arg(call, :path)
    repo_path = state.repo_path || Process.get(:repo_path)
    repo_id = state.repo_id

    cond do
      not is_binary(repo_path) ->
        warn_node_path(state, call, "the agent has no repo path")
        nil

      not is_binary(raw) or raw == "" ->
        warn_node_path(state, call, "the interrupted call carries no path")
        nil

      true ->
        case SubagentProcessing.resolve_subagent_path(
               raw,
               repo_path,
               state.foreign_repos || [],
               repo_id
             ) do
          {:ok, ^repo_id, _root, relative} when is_binary(relative) ->
            relative

          {:ok, other_repo, _root, _relative} ->
            warn_node_path(
              state,
              call,
              "path #{inspect(raw)} resolves to repo #{inspect(other_repo)}"
            )

            nil

          {:error, message} ->
            warn_node_path(state, call, "path #{inspect(raw)} does not resolve: #{message}")
            nil
        end
    end
  end

  defp warn_node_path(%State{} = state, call, reason) do
    Logger.warning(
      "Resume: could not derive the node path of a re-attached subagent of agent " <>
        "#{inspect(state.agent_id)} (#{reason}); merging it as root-owned " <>
        "(call #{inspect(call_id(call))})"
    )

    :ok
  end

  ## Merge

  @spec safe_merge(State.t(), [term()]) :: {:ok, String.t() | nil} | :degraded
  defp safe_merge(_state, []), do: {:ok, nil}

  defp safe_merge(%State{} = state, children) do
    try do
      merge(state, children)
    rescue
      error ->
        warn_merge(state, children, Exception.message(error))
        :degraded
    catch
      kind, reason ->
        warn_merge(state, children, inspect({kind, reason}))
        :degraded
    end
  end

  defp merge(%State{} = state, children) do
    repo_path = state.repo_path || Process.get(:repo_path)

    if is_binary(repo_path) do
      report = SubagentProcessing.perform_merge(repo_path, children, state.node_path || "./")
      SubagentProcessing.delete_merged_branches(report, repo_path)
      {:ok, SubagentProcessing.build_merge_message(report, children, "", [])}
    else
      # No worktree path means the merge cannot run at all: the caller degrades
      # the affected calls (their work is NOT in the tree).
      Logger.warning(
        "Resume: cannot merge #{length(children)} re-attached subagent commit(s) for agent " <>
          "#{inspect(state.agent_id)}: the agent has no repo path; degrading their results " <>
          "to the fallback text"
      )

      :degraded
    end
  end

  defp warn_merge(%State{} = state, children, reason) do
    Logger.warning(
      "Resume: merging #{length(children)} re-attached subagent commit(s) for agent " <>
        "#{inspect(state.agent_id)} FAILED (#{reason}); degrading their results to the " <>
        "fallback text because their work is NOT in the parent worktree"
    )

    :ok
  end

  ## Degrade

  defp degrade(%State{} = state, count, detail) do
    Logger.warning(
      "Resume: subagent re-attach for agent #{inspect(state.agent_id)} degraded to the " <>
        "fallback text for #{count} interrupted subagent call(s): #{detail}"
    )

    empty()
  end

  ## Call accessors (total: a restored transcript may carry plain maps)

  defp call_arg(call, key) when is_atom(key) do
    case args(call) do
      %{} = args -> Map.get(args, key) || Map.get(args, Atom.to_string(key))
      _none -> nil
    end
  end

  defp args(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.args_map(call)
  defp args(call) when is_map(call), do: Map.get(call, :arguments) || Map.get(call, "arguments")
  defp args(_call), do: nil

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(call) when is_map(call), do: Map.get(call, :id) || Map.get(call, "id")
  defp call_id(_call), do: nil
end
