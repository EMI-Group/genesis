defmodule EvoDashWeb.ReviewLive.ArchiveLoad do
  @moduledoc """
  Lazy archive load + panel for `EvoDashWeb.ReviewLive`.

  The review page loads the task row through the LITE read
  (`get_task_lite/2`), which carries no archive data. The archive is therefore
  a SEPARATE, on-demand fetch: opening the Archive tab triggers exactly one
  fetch, and the result is cached for the lifetime of the load context (keyed
  by `{task_id, node}`) so tab round-trips and `{:review_data_loaded, ...}`
  reloads never refetch it.

  State machine (`socket.assigns`): `archive_state` (`:idle | :loading |
  :loaded | :error`), `archive_records`, `archive_metadata` (render-facing
  mirror), `archive_error`, `archive_key` (`{task_id, node}` of the cached or
  in-flight fetch) and `archive_seq` (monotonic fetch counter, the stale guard).

  Same async pattern as `LoadData` / `MergeCheck`: the fetch runs in an
  `EvoDash.TaskSupervisor` child behind `EvoDash.SafeCall.run/1` and ALWAYS
  reports `{:review_archive_loaded, task_id, node, seq, result}`, so no result
  shape can wedge the panel on a spinner.

  The runner is the `:review_archive_runner` app-env seam (resolved inside the
  spawned child), defaulting to `EvoDash.NodeContext.get_task_archive/2`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  use Phoenix.Component

  import EvoDashWeb.CoreComponents, only: [icon: 1]

  @doc """
  Starts the archive fetch when the panel needs one, and only then.

  `:loading` (in flight), `:loaded` (cached forever for this task/node) and
  `:error` (needs the explicit `retry/1`) are all no-ops; only `:idle` spawns.
  """
  def ensure_loaded(socket) do
    case Map.get(socket.assigns, :archive_state, :idle) do
      :idle -> start_fetch(socket)
      _other -> socket
    end
  end

  @doc """
  Applies an `{:review_archive_loaded, ...}` message to the socket.

  Drops results from a different task/node or from an older fetch sequence
  (a newer fetch was started since). Every result shape is normalized into the
  `:loaded` / `:error` states — this function never raises.
  """
  def handle_result(socket, task_id, node, seq, result) do
    stale? =
      task_id != socket.assigns.task_id or node != socket.assigns.current_node or
        seq < Map.get(socket.assigns, :archive_seq, 0)

    if stale? do
      socket
    else
      case result do
        {:ok, records} when is_list(records) ->
          assign(socket,
            archive_state: :loaded,
            archive_records: records,
            archive_metadata: records,
            archive_error: nil
          )

        {:error, reason} ->
          assign(socket,
            archive_state: :error,
            archive_error: reason,
            archive_records: [],
            archive_metadata: nil
          )

        _unexpected ->
          assign(socket,
            archive_state: :error,
            archive_error: error_message(),
            archive_records: [],
            archive_metadata: nil
          )
      end
    end
  end

  @doc """
  Retry handler for the panel's Retry button: re-arms the state machine and
  starts a fresh fetch.
  """
  def retry(socket) do
    socket
    |> assign(archive_state: :idle, archive_error: nil, archive_key: nil)
    |> ensure_loaded()
  end

  @doc """
  Reconciles the archive cache with the current load context.

  Called at the top of `ReviewLive.start_async_load/2`, i.e. exactly when a
  load is (re)started. A nil or matching `archive_key` leaves the cache alone
  (a same task/node reload must not discard a loaded archive); a task/node
  change resets it to `:idle` and re-fetches only when the Archive tab is the
  one on screen. `archive_seq` stays monotonic across resets.
  """
  def sync_context(socket) do
    key = {socket.assigns.task_id, socket.assigns.current_node}

    case Map.get(socket.assigns, :archive_key) do
      nil ->
        socket

      ^key ->
        socket

      _changed ->
        socket =
          assign(socket,
            archive_state: :idle,
            archive_records: [],
            archive_metadata: nil,
            archive_error: nil,
            archive_key: nil
          )

        if Map.get(socket.assigns, :review_tab) == :archive do
          ensure_loaded(socket)
        else
          socket
        end
    end
  end

  @doc """
  Whether the Export JSON affordance may render: only a `:loaded`, non-empty
  archive is exportable (the export endpoint 404s without one).
  """
  def export_available?(assigns) do
    Map.get(assigns, :archive_state) == :loaded and Map.get(assigns, :archive_records, []) != []
  end

  @doc """
  Renders the Archive tab body for every archive state.
  """
  attr :state, :atom, required: true
  attr :records, :any, default: []
  attr :error, :any, default: nil
  attr :task_id, :any, default: nil

  def panel(assigns) do
    message = error_message()
    records = if is_list(assigns.records), do: assigns.records, else: []
    # The error assigns is already the standard message for a failed fetch;
    # surface a distinct binary reason (a transport/RPC detail) beneath it.
    detail = if is_binary(assigns.error) and assigns.error != message, do: assigns.error

    assigns = assign(assigns, records: records, message: message, detail: detail)

    ~H"""
    <%= cond do %>
      <% @state == :error -> %>
        <div class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <.icon name="hero-exclamation-triangle" class="size-8 text-error mx-auto mb-3" />
          <p class="text-sm text-error">{@message}</p>
          <p :if={@detail} class="mt-1 text-xs text-base-content/70">{@detail}</p>
          <button type="button" phx-click="retry_archive" class="btn btn-outline btn-sm mt-4 gap-2">
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Retry")}
          </button>
        </div>
      <% @state == :loaded and @records == [] -> %>
        <div class="p-8 text-center">
          <.icon name="hero-archive-box-x-mark" class="size-10 text-base-content/50 mx-auto mb-3" />
          <p class="text-sm text-base-content/70">
            {gettext("No archived agent data available for this task.")}
          </p>
        </div>
      <% @state == :loaded -> %>
        <EvoDashWeb.ReviewComponents.archive_review_section
          archive_metadata={@records}
          task_id={@task_id}
        />
      <% true -> %>
        <div class="flex items-center justify-center py-20">
          <.icon
            name="hero-arrow-path"
            class="size-8 text-primary-standalone motion-safe:animate-spin"
          />
          <span class="ml-3 text-base-content/60">{gettext("Loading archive…")}</span>
        </div>
    <% end %>
    """
  end

  # Single source of the failure message (a gettext literal so extraction sees
  # it); the fetch path and the panel share it.
  defp error_message, do: gettext("Failed to load archive data.")

  # Spawns the single archive fetch for the current task/node. Mirrors
  # ReviewLive's start_async_load/2: parent/task_id/node/seq snapshotted into
  # locals, the fetch behind EvoDash.SafeCall.run/1, and the result message
  # ALWAYS sent — a dead child would otherwise wedge the panel on :loading.
  defp start_fetch(socket) do
    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id
    seq = Map.get(socket.assigns, :archive_seq, 0) + 1

    socket =
      assign(socket,
        archive_seq: seq,
        archive_state: :loading,
        archive_error: nil,
        archive_metadata: nil,
        archive_records: [],
        archive_key: {task_id, node}
      )

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Resolved at CALL time (inside the child) so an injected test seam set
      # after the page mounted is honoured.
      runner =
        Application.get_env(:evo_dash, :review_archive_runner) ||
          (&EvoDash.NodeContext.get_task_archive/2)

      result =
        case EvoDash.SafeCall.run(fn -> runner.(node, task_id) end) do
          {:ok, records} when is_list(records) -> {:ok, records}
          # Exit/exception/throw around the call, or a non-list payload: the
          # panel becomes retry-able instead of hanging.
          _ -> {:error, error_message()}
        end

      send(parent, {:review_archive_loaded, task_id, node, seq, result})
    end)

    socket
  end
end
