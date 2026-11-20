defmodule EvoGit.TaskRegistry.StoreRead do
  @moduledoc """
  The ONE three-state read surface for `EvoGit.TaskRegistry`'s narrow store
  reads: `{:ok, value} | :absent | :unavailable`.

  ## Why this exists — an outage must never read as a domain answer

  A `nil`/`[]` degraded read is indistinguishable from "the row does not exist"
  or "there are no rows", and the registry makes IRREVERSIBLE decisions from
  those reads: persisting `:completed`/`:failed` (destroying the result/usage a
  resume needs), dropping a live task's wrapper ref, writing a review column.
  So every such read goes through `EvoGit.TaskRegistry.StoreGuard.fetch/2`,
  which keeps a store fault OUT of the value space, and the callers choose their
  own direction of caution:

  | Call site | `:absent` | `:unavailable` |
  |---|---|---|
  | `pause_settled?/2` (straggler guard) | not settled | SETTLED — a late result never flips a `:pausing`/`:paused` row |
  | `persist_paused/3` | drop the ref (the row is gone) | drop the ref + ONE warning (the pause is NOT persisted; the lease sweep parks a resumable row as a dirty pause) |
  | `handle_update_status/6` | no write (the row is gone) | no write (never persist blind) |
  | `set_review_status/metadata` | no write, no broadcast | no write, no broadcast |
  | `start_task/2` (fresh id, cannot be cancelled) | proceed | proceed |
  | `Pause.pause/2`, `Pause.resume/4` | `{:error, :not_found}` | `{:error, :store_unavailable}` |

  `:absent` therefore always means "the store answered, and the row is not
  there", and `:unavailable` always means "the store could not answer".

  Every function here is TOTAL: it never raises and never exits (the fault is
  contained by `StoreGuard.fetch/2`, which logs it once).
  """

  alias EvoGit.TaskRegistry.StoreGuard

  @typedoc "A persisted task status as the store decodes it (`{:unknown, raw}` = row present, text unreadable)."
  @type status :: atom() | {:unknown, term()}

  @typedoc "The narrow `EvoGit.Store.select_task_update_info/2` projection."
  @type update_info :: %{
          status: atom() | nil,
          opts: keyword() | nil,
          finished_at: DateTime.t() | nil,
          lease_expires_at: integer() | nil,
          project_path: String.t() | nil
        }

  @typedoc "The narrow `EvoGit.Store.select_tasks_restart_info/2` projection."
  @type restart_info :: %{
          id: String.t(),
          status: atom() | nil,
          type: atom() | nil,
          opts: keyword() | nil,
          pause_kind: :clean | :dirty | nil,
          project_path: String.t() | nil
        }

  @doc """
  The task's persisted status (`EvoGit.Store.get_task_status/2`): `{:ok,
  status}` for a present row — including `{:ok, {:unknown, raw}}`, a row that
  EXISTS with unreadable status text — `:absent` when no row has this id, and
  `:unavailable` when the store could not answer.

  Reads only the `status` column.
  """
  @spec status(GenServer.server(), String.t()) :: {:ok, status()} | :absent | :unavailable
  def status(store, task_id) do
    case StoreGuard.fetch("store_read get_task_status", fn ->
           EvoGit.Store.get_task_status(store, task_id)
         end) do
      {:ok, nil} -> :absent
      {:ok, status} -> {:ok, status}
      :unavailable -> :unavailable
    end
  end

  @doc """
  The narrow update projection (`EvoGit.Store.select_task_update_info/2`):
  `{:ok, %{status, opts, finished_at, lease_expires_at, project_path}}` for a
  present row, `:absent` when no row has this id, `:unavailable` on a store
  fault.

  NOTE: this projection decodes the status through the TYPED schema, so an
  unreadable status text arrives as `nil` (never `{:unknown, raw}`) — use
  `status/2` when that distinction matters.
  """
  @spec update_info(GenServer.server(), String.t()) ::
          {:ok, update_info()} | :absent | :unavailable
  def update_info(store, task_id) do
    case StoreGuard.fetch("store_read select_task_update_info", fn ->
           EvoGit.Store.select_task_update_info(store, task_id)
         end) do
      {:ok, nil} -> :absent
      {:ok, row} -> {:ok, row}
      :unavailable -> :unavailable
    end
  end

  @doc """
  The batched restart-classification projection
  (`EvoGit.Store.select_tasks_restart_info/2`): `{:ok, [%{id, status, type,
  opts, pause_kind, project_path}]}` for the PRESENT rows (an absent id
  contributes nothing; an empty id list reads nothing), or `:unavailable` on a
  store fault.
  """
  @spec restart_info(GenServer.server(), [String.t()]) ::
          {:ok, [restart_info()]} | :unavailable
  def restart_info(store, task_ids) when is_list(task_ids) do
    case StoreGuard.fetch("store_read select_tasks_restart_info", fn ->
           EvoGit.Store.select_tasks_restart_info(store, task_ids)
         end) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      :unavailable -> :unavailable
    end
  end
end
