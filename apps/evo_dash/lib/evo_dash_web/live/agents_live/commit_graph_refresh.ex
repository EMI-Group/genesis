defmodule EvoDashWeb.AgentsLive.CommitGraphRefresh do
  @moduledoc """
  Pure fetch-result folding + commit-relevance fingerprinting for the Agents
  page's TEMPORAL (commit-history) view.

  Two concerns the LiveView previously owned inline, extracted so they are
  testable without a socket:

    * **Partial-success group folding** (`fetch_result/3`) — one git RPC runs
      per `{repo_key, task_id}` group; a failing group drops only ITS data
      while the successful groups still render. `{:error, _}` is produced only
      when EVERY group fails (a single-group failure is exactly that case).
    * **Commit-relevance fingerprint** (`fingerprint/1`) — an order-insensitive
      digest of the temporal view's agent set covering exactly the fields the
      view model + the fetch grouping read. When it is unchanged, the page
      skips both the view-model rebuild and the git-RPC refetch, so
      status/token/usage-only agent updates cost nothing.

  Like the sibling support modules (`PendingEvents`, `HistoryGate`,
  `OptimisticMessages`) this module is deliberately PURE — no I/O, no socket,
  no processes, no `try/rescue`. It is invoked from INSIDE the
  `EvoDash.TaskSupervisor` fetch child (whose node-boundary rescue lives in
  `agents_live.ex`).
  """

  # Max commits fetched per repo range (the per-group `limit:` RPC opt). The
  # single source of the limit — `agents_live.ex` has no copy.
  @limit 100

  @typep refs :: %{optional(term()) => [term()]}

  # `truncated` is always present on the values this module PRODUCES (the
  # merge writes an explicit boolean); an accumulated entry may still lack it
  # (older payloads / the arity-4 merge), which reads as `false`.
  @typep raw_by_repo :: %{
           optional(term()) => %{commits: [map()], refs: refs(), truncated: boolean()}
         }

  @typep group :: %{repo_key: term(), task_id: term(), live_tips: [term()]}
  @typep failure :: {:commit_graph_repo_failed, {term(), term()}, term()}

  @doc """
  The per-group commit limit passed to the runner (`limit: 100`).
  """
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Folds the per-group runner calls into ONE fetch result.

  Calls `runner.(node, task_id, repo_key, live_tips, limit: 100)` ONCE per
  group, in the given (already sorted) group order. **Partial success**: a
  group whose reply is anything other than `{:ok, %{commits: list}}` only
  drops THAT group's data (recorded as a
  `{:commit_graph_repo_failed, {repo_key, task_id}, other}` failure) — the
  remaining groups still fold into the result, so a page with several
  repos/tasks renders the successful ones when a single git RPC fails.

  The runner's per-group reply carries the core's `truncated` flag (true when
  a tip range was cut at the limit); `merge_repo_graph/5` OR-unions it across
  the groups sharing a repo_key.

  Returns `{:ok, merged_raw_by_repo}` when AT LEAST ONE group succeeded
  (groups sharing a `repo_key` are unioned via `merge_repo_graph/5`), and
  `{:error, failure}` only when EVERY group failed — the failure of the LAST
  failing group (the reduce PREPENDS failures, so the most recently processed
  group's failure is the head), which for a single-group page is exactly the
  former halt-with-error semantics. The reason is display-only (either
  failure renders the same error strip), so which one surfaces is immaterial.
  """
  @spec fetch_result([group()], function(), term()) ::
          {:ok, raw_by_repo()} | {:error, failure() | :commit_graph_no_groups}
  def fetch_result(groups, runner, node) do
    groups
    |> Enum.reduce({false, %{}, []}, fn group, {any_ok?, acc, failures} ->
      case fetch_group(group, runner, node) do
        {:ok, repo_key, commits, refs, truncated} ->
          {true, merge_repo_graph(acc, repo_key, commits, refs, truncated), failures}

        {:error, failure} ->
          {any_ok?, acc, [failure | failures]}
      end
    end)
    |> finalize()
  end

  @doc """
  Unions one group's successful reply into `acc` under its `repo_key`: commits
  de-duped by `:sha` (a sha shared by two tasks in the same repo appears once;
  non-map entries dropped) and ref name lists unioned per sha. Total — a
  malformed refs payload degrades to an empty map and non-map commit entries
  are dropped.

  Backward-compatible arity: the caller has no `truncated` flag to contribute,
  so the merged entry carries the accumulated flag alone — `false` for a
  repo_key absent from `acc` (the flag key is always WRITTEN, never inferred).
  """
  @spec merge_repo_graph(raw_by_repo(), term(), [map()], refs()) :: raw_by_repo()
  def merge_repo_graph(acc, repo_key, commits, refs),
    do: merge_repo_graph(acc, repo_key, commits, refs, false)

  @doc """
  `merge_repo_graph/4` plus the incoming reply's `truncated` flag: groups
  sharing a `repo_key` OR-union their flags (one cut range is enough to mark
  the merged repo truncated). An absent accumulated flag reads as `false`, and
  a non-boolean incoming value (garbage payload) folds to `false` — the key is
  always an explicit boolean.
  """
  @spec merge_repo_graph(raw_by_repo(), term(), [map()], refs(), boolean()) :: raw_by_repo()
  def merge_repo_graph(acc, repo_key, commits, refs, truncated) when is_map(acc) do
    existing = Map.get(acc, repo_key, %{commits: [], refs: %{}})

    merged = %{
      commits: dedupe_commits(List.wrap(existing.commits) ++ List.wrap(commits)),
      refs: merge_refs(Map.get(existing, :refs), refs),
      truncated: truncated?(Map.get(existing, :truncated)) or truncated?(truncated)
    }

    Map.put(acc, repo_key, merged)
  end

  def merge_repo_graph(_acc, repo_key, commits, refs, truncated),
    do: merge_repo_graph(%{}, repo_key, commits, refs, truncated)

  @doc """
  An order-insensitive commit-relevance fingerprint of the temporal view's
  agent set: a MapSet of per-agent tuples covering EXACTLY the fields the
  view model (`CommitGraph.build/2`) and the fetch grouping read —

      {id, repo_root || repo_id, task_id, task_local_id, depth, parent_id,
       base_commit, current_commit, ended}

  The grouping key and the shas feed the lanes, START/END annotations, the
  ownership walk and the synthesized bases; `id`/`task_id` cover set
  membership; `task_local_id`/`depth`/`parent_id` fix the lane ORDER and the
  agent-level `:spawn`/`:merge_back` edges (a removed parent orphans its
  children to `parent_id: nil`); and `ended` drives the retained-agent dim
  rendering. A change in ANY element means the view may have moved, so the
  caller rebuilds + refetches; an unchanged set means the update touched only
  fields the temporal view never reads — `status` (deliberately excluded: the
  commit structure is unchanged; the tip status dot catches up on the next
  commit-relevant change or force), tokens/usage, message counts, objective —
  and both the rebuild and the git-RPC refetch can be skipped.
  """
  @spec fingerprint([map()] | nil) :: MapSet.t()
  def fingerprint(agents) do
    agents
    |> List.wrap()
    |> MapSet.new(&agent_entry/1)
  end

  # ONE runner call for ONE group, normalizing the reply. Anything other than
  # {:ok, %{commits: list}} (an {:error, _}, a malformed ok-shape, or garbage)
  # is a per-group failure carrying the raw reply. A success carries the
  # payload's `truncated` flag (absent → false) alongside commits + refs.
  defp fetch_group(group, runner, node) do
    %{repo_key: repo_key, task_id: task_id, live_tips: live_tips} = group

    case runner.(node, task_id, repo_key, live_tips, limit: @limit) do
      {:ok, %{commits: commits} = payload} when is_list(commits) ->
        {:ok, repo_key, commits, Map.get(payload, :refs, %{}),
         truncated?(Map.get(payload, :truncated))}

      other ->
        {:error, {:commit_graph_repo_failed, {repo_key, task_id}, other}}
    end
  end

  # Total boolean fold: only an explicit `true` is truncated; absent / nil /
  # garbage all read as false.
  defp truncated?(true), do: true
  defp truncated?(_), do: false

  # ≥1 success wins (the failures were only dropped groups); an all-groups
  # failure surfaces the LAST failing group's failure — the reduce PREPENDS
  # each failure, so `failure_reason/1`'s head is the most recently processed
  # group — preserving the single-group halt semantics. Which failure surfaces
  # is display-only (both render the same error strip).
  defp finalize({true, acc, _failures}), do: {:ok, acc}

  defp finalize({false, _acc, failures}) do
    {:error, failure_reason(failures)}
  end

  defp failure_reason([last | _]), do: last
  # Unreachable in practice (any_ok? stays false only when ≥1 group failed);
  # kept so the function is total.
  defp failure_reason([]), do: :commit_graph_no_groups

  defp dedupe_commits(commits) do
    commits |> Enum.filter(&is_map/1) |> Enum.uniq_by(&Map.get(&1, :sha))
  end

  defp merge_refs(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _sha, names_a, names_b ->
      (List.wrap(names_a) ++ List.wrap(names_b)) |> Enum.uniq()
    end)
  end

  defp merge_refs(left, _right) when is_map(left), do: left
  defp merge_refs(_left, right) when is_map(right), do: right
  defp merge_refs(_left, _right), do: %{}

  defp agent_entry(agent) when is_map(agent) do
    {
      Map.get(agent, :id),
      Map.get(agent, :repo_root) || Map.get(agent, :repo_id),
      Map.get(agent, :task_id),
      Map.get(agent, :task_local_id),
      Map.get(agent, :depth),
      Map.get(agent, :parent_id),
      Map.get(agent, :base_commit),
      Map.get(agent, :current_commit),
      Map.get(agent, :ended) == true
    }
  end

  defp agent_entry(_agent), do: nil
end
