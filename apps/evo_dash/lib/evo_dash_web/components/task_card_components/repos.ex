defmodule EvoDashWeb.TaskCardComponents.Repos do
  @moduledoc """
  Multi-repo support for the task card: `result_repos/1` (normalizes the
  result `repos` key), `task_repos/2` (the collapsed card's per-repo
  indicator) and the shared `result_repos_badges/1` badge row.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.TaskCardComponents.ResultRender

  # ---------------------------------------------------------------------------
  # Public helpers — result_repos/1 (multi-repo "repos" result key)
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes the `repos` result key into a deterministic list of per-repo
  entries `%{id:, commit_sha:, branch_name:}` — the `"primary"` repo first,
  then writable foreign repos sorted by id. Returns `nil` when the result
  carries no usable `repos` map (legacy results, error/crash results, summary
  maps) so callers can guard with `if repos = result_repos(...) do` and render
  nothing — legacy behavior stays byte-identical.

  Shape notes (see `EvoGit.Runtime.Helpers.report_map/5` + the Store Codec):
  the `repos` value is `%{repo_id => %{"commit_sha" => sha, "branch_name" =>
  branch | nil}}` with STRING keys — after the `EvoGit.Store.Codec` round trip
  the top-level `"repos"` key is NOT in `@result_data_fields`, so it stays a
  string key with string-keyed inner maps (unknown keys are never atomized).
  Both atom and string keys are read defensively so in-memory (pre-encode)
  results work identically. Non-map entries are dropped; `branch_name` nil
  means "no changes" for the primary repo (or a failed branch creation for a
  foreign repo).
  """
  def result_repos({:ok, data}) when is_map(data), do: result_repos(data)

  def result_repos(data) when is_map(data) do
    case Map.get(data, :repos) || Map.get(data, "repos") do
      repos when is_map(repos) and map_size(repos) > 0 ->
        entries =
          Enum.flat_map(repos, fn
            {id, entry} when is_map(entry) ->
              [
                %{
                  id: to_string(id),
                  commit_sha: Map.get(entry, :commit_sha) || Map.get(entry, "commit_sha"),
                  branch_name: Map.get(entry, :branch_name) || Map.get(entry, "branch_name")
                }
              ]

            _ ->
              []
          end)

        case entries do
          [] -> nil
          entries -> primary_first(entries)
        end

      _ ->
        nil
    end
  end

  def result_repos(_), do: nil

  # `"primary"` first (contract: always present), then foreign repos sorted by
  # id for deterministic rendering.
  defp primary_first(entries) do
    {primary, foreign} = Enum.split_with(entries, &(&1.id == "primary"))
    primary ++ Enum.sort_by(foreign, & &1.id)
  end

  # ---------------------------------------------------------------------------
  # Public helpers — task_repos/2 (COLLAPSED card multi-repo indicator)
  # ---------------------------------------------------------------------------

  @doc """
  Derives the collapsed card's per-repo indicator from the task SUMMARY map,
  enriched by the lazily-fetched `detail` once it has landed.

  Sources, in order:

    1. the primary repo, straight from the summary —
       `%{id: "primary", commit_sha: task.commit_sha, branch_name: task.branch_name}`;
    2. one entry per foreign repo in `opts[:foreign_repos]` (structs or maps) —
       `%{id:, path:, description:, writable:, commit_sha: nil, branch_name: nil}`.
       Entries without a usable string id, and any entry whose id is
       `"primary"`, are skipped;
    3. enrichment from `detail.task`'s result `repos` map (see
       `result_repos/1`): a NON-nil detail `commit_sha`/`branch_name` overrides
       the summary value, and detail-only repo ids absent from
       `opts[:foreign_repos]` are added as badge-only entries.

  Returns `nil` — so the caller renders NOTHING (legacy behaviour) — unless the
  task is genuinely multi-repo: at least one foreign repo is configured, or the
  detail result carries more than the primary repo. Otherwise the entries are
  ordered primary-first, foreign repos sorted by id.

  TOTAL: `task` may be odd, `opts` nil or not a keyword list, entries may be
  non-maps, `detail` may be nil or `:loading`/`:error` — none of it raises.
  """
  def task_repos(task, detail) do
    task = if is_map(task), do: task, else: %{}

    summary_primary = %{
      id: "primary",
      commit_sha: Map.get(task, :commit_sha),
      branch_name: Map.get(task, :branch_name),
      path: nil,
      description: nil,
      writable: false
    }

    foreign = foreign_repo_entries(Map.get(task, :opts))
    detail_repos = detail_result_repos(detail)

    if foreign == [] and not more_than_primary?(detail_repos) do
      nil
    else
      [summary_primary | foreign]
      |> merge_detail_repos(detail_repos)
      |> primary_first()
    end
  end

  # `detail.task`'s result `repos` entries — nil while the detail is missing,
  # still loading, or errored out (all treated identically: no enrichment).
  defp detail_result_repos(%{state: :ok, task: lite}) when is_map(lite),
    do: result_repos(Map.get(lite, :result))

  defp detail_result_repos(_detail), do: nil

  defp more_than_primary?(repos) when is_list(repos), do: length(repos) > 1
  defp more_than_primary?(_repos), do: false

  # Merge the detail result's per-repo entries into the summary-derived ones:
  # a non-nil detail value wins, a nil detail value keeps the summary value,
  # and detail-only ids are appended (badge-only entries, no path/description).
  defp merge_detail_repos(entries, detail_repos) when is_list(detail_repos) do
    Enum.reduce(detail_repos, entries, fn %{id: id} = detail_entry, acc ->
      case Enum.find_index(acc, &(&1.id == id)) do
        nil ->
          [
            %{
              id: id,
              commit_sha: detail_entry.commit_sha,
              branch_name: detail_entry.branch_name,
              path: nil,
              description: nil,
              writable: false
            }
            | acc
          ]

        index ->
          List.update_at(acc, index, fn entry ->
            %{
              entry
              | commit_sha: detail_entry.commit_sha || entry.commit_sha,
                branch_name: detail_entry.branch_name || entry.branch_name
            }
          end)
      end
    end)
  end

  defp merge_detail_repos(entries, _detail_repos), do: entries

  # `opts[:foreign_repos]` → normalized badge entries. Tolerant of a nil /
  # non-keyword `opts` and of non-list / non-map entries.
  defp foreign_repo_entries(opts) when is_list(opts) do
    opts
    |> foreign_repos_list()
    |> Enum.flat_map(fn entry ->
      case foreign_repo_entry(entry) do
        nil -> []
        entry -> [entry]
      end
    end)
  end

  defp foreign_repo_entries(_opts), do: []

  defp foreign_repos_list(opts) do
    Enum.find_value(opts, [], fn
      {:foreign_repos, repos} when is_list(repos) -> repos
      _ -> nil
    end)
  end

  # `%EvoGit.Core.ForeignRepo{}` structs AND plain atom/string-keyed maps are
  # accepted (settings round-trips hand either shape).
  defp foreign_repo_entry(entry) when is_map(entry) do
    case Map.get(entry, :id) || Map.get(entry, "id") do
      id when is_binary(id) and id != "" and id != "primary" ->
        %{
          id: id,
          commit_sha: nil,
          branch_name: nil,
          path:
            Map.get(entry, :root) || Map.get(entry, "root") || Map.get(entry, :path) ||
              Map.get(entry, "path"),
          description: Map.get(entry, :description) || Map.get(entry, "description"),
          writable: (Map.get(entry, :writable) || Map.get(entry, "writable")) == true
        }

      _ ->
        nil
    end
  end

  defp foreign_repo_entry(_entry), do: nil

  attr(:repos, :list, required: true)
  attr(:size_class, :string, default: "text-xs")

  @doc """
  Renders the per-repo commit/branch badges for a task result carrying the
  `repos` key (see `result_repos/1`): one compact row per repo —
  `id: <short_sha> (<branch>)` — primary first, foreign repos sorted by id.
  A nil branch renders just the short sha, plus a muted "no changes" hint for
  the primary repo (its nil branch means the primary produced no commits).
  """
  def result_repos_badges(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-x-3 gap-y-1.5", @size_class]}>
      <%= for repo <- @repos do %>
        <span class="inline-flex items-center gap-1.5 min-w-0">
          <span class="badge badge-ghost font-mono font-medium">
            {repo.id}:
          </span>
          <%= if repo.commit_sha do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-code-bracket" class="size-3 mr-1 opacity-60" />
              {String.slice(repo.commit_sha, 0..6)}
            </span>
          <% end %>
          <%= if repo.branch_name do %>
            <span class={ResultRender.branch_badge_class()}>
              <.icon name="hero-code-bracket-square" class="size-3 mr-1 shrink-0" />
              <span class="truncate min-w-0">{repo.branch_name}</span>
            </span>
          <% else %>
            <%= if repo.id == "primary" do %>
              <span class="badge badge-ghost font-mono opacity-60">
                <%!-- zh_CN: 主仓库本次无改动 --%>{gettext("no changes")}
              </span>
            <% end %>
          <% end %>
        </span>
      <% end %>
    </div>
    """
  end
end
