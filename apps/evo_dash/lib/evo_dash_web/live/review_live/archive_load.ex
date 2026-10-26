defmodule EvoDashWeb.ReviewLive.ArchiveLoad do
  @moduledoc """
  Paged, lazy archive loading and the Archive-tab panel for `EvoDashWeb.ReviewLive`.

  The review page loads the task row through the LITE read (`get_task_lite/2`), which carries no archive data, so the archive is a SEPARATE on-demand fetch.
  A task's archive is read in bounded pages (`EvoDash.NodeContext.list_task_archives/3` — 100 entries, `include_results: false`).
  Pages ACCUMULATE in `archive_records` behind a RETENTION WINDOW: `EvoDashWeb.ArchiveHelpers.max_retained/0` (500 = 5 × the 100-entry page size) keeps only the most RECENT entries, which bounds a multi-thousand-agent task while a normal (≤500-agent) archive stays fully scrollable without eviction.
  Evicted entries are counted in `archive_dropped`, so the rendered span (`retained_page_bounds/3`) and the pager predicate (`more_pages?/3`) stay correct after eviction.
  The NEXT REQUEST OFFSET always comes from `archive_fetched` — the cumulative count of RAW server rows received — never from `length(archive_records)`, which shrinks once the window evicts.
  A page returning FEWER rows than the page limit (an empty page included) EXHAUSTS the archive; the effective total is then clamped to `dropped + retained` (the distinct loaded rows), because the server may stop sending a per-page COUNT.
  No paged entry carries its heavy `"result"`, so one agent's result is fetched on demand (`EvoDash.NodeContext.get_agent_archive/3`) and folded into the already loaded page by `EvoDashWeb.ArchiveHelpers.merge_entry/2`.
  Both caches live for the lifetime of the load context (`{task_id, node}`), so tab round-trips and `{:review_data_loaded, ...}` reloads never refetch anything.
  A task broadcast for the reviewed task drops the cached per-agent results (they may be stale) while the loaded pages stay — including the results already folded into them.

  OPT-IN: the state machine and the panel are a NO-OP unless the task opted into archiving (`archive_opt_in?`, owned by `EvoDashWeb.ReviewLive.LoadData` from `EvoDashWeb.ArchiveHelpers.archive_opt?/1`); a non-opt-in task never issues a fetch and renders an explicit disabled state.

  State machine (`socket.assigns`):

    * `archive_opt_in?` — the task opted into archiving; owned by `LoadData`, never touched here. False ⇒ every entry point returns the socket untouched.
    * `archive_state` — `:idle | :loading | :loaded | :error`; only a FIRST page moves it to `:loading`, later appends keep `:loaded`.
    * `archive_records` — the RETAINED entries of every loaded page (bounded by the retention window).
    * `archive_dropped` — entries evicted by the retention window (their rows exist on the server but are no longer loaded).
    * `archive_fetched` — cumulative RAW server rows received; the ONLY source of the next request offset.
    * `archive_exhausted?` — a page returned fewer rows than `@page_limit` (an empty page included), so no further page exists.
    * `archive_server_total` — the raw server count (`nil` when a page reported none); used for the LABEL only.
    * `archive_total` — the EFFECTIVE total used for paging (clamped when exhausted).
    * `archive_loading_more?` / `archive_more_error` — an append fetch in flight / its failure (the loaded page stays rendered).
    * `archive_error` — a first-page failure (the panel renders the retry-able error state).
    * `archive_key` — the `{task_id, node}` of the cached or in-flight fetch.
    * `archive_seq` — the context generation; a fresh first page, `retry/1` and a context reset bump it, so results from before are dropped.
    * `archive_agent_results` — `%{agent_id => %{state: :loading | :ok | :error, entry: map() | nil, error: term() | nil}}`.
    * `archive_agent_seq` — the generation of the lazy result cache; `invalidate_agent_results/1` and a context reset bump it, so in-flight per-agent results from before are dropped.

  Same async pattern as `LoadData` / `MergeCheck`: every fetch runs in an `EvoDash.TaskSupervisor` child behind `EvoDash.SafeCall.run/1` and ALWAYS reports its result, so no shape can wedge the panel on a spinner.
  A page reports `{:review_archive_loaded, task_id, node, seq, offset, result}`; one agent's result reports `{:review_archive_agent_loaded, task_id, node, agent_id, seq, result}`.

  Seams, resolved AT CALL TIME inside the spawned child (so a runner injected after mount is honoured):

    * `:review_archive_runner` — `fn node, task_id, opts -> ... end`, default `&EvoDash.NodeContext.list_task_archives/3`.
    * `:review_archive_agent_runner` — `fn node, task_id, agent_id -> ... end`, default `&EvoDash.NodeContext.get_agent_archive/3`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  use Phoenix.Component

  import EvoDashWeb.CoreComponents, only: [icon: 1]

  alias EvoDashWeb.ArchiveHelpers

  @page_limit 100

  @doc """
  Starts the FIRST page fetch when the panel needs one, and only then.

  A NO-OP for a task that did not opt into archiving (`archive_opt_in?` false):
  no fetch is ever issued. Otherwise `:loading` (in flight), `:loaded` (cached
  for this task/node) and `:error` (needs the explicit `retry/1`) are all
  no-ops too; only `:idle` spawns.
  """
  def ensure_loaded(socket) do
    if Map.get(socket.assigns, :archive_opt_in?, false) do
      case Map.get(socket.assigns, :archive_state, :idle) do
        :idle -> start_fetch(socket)
        _other -> socket
      end
    else
      socket
    end
  end

  @doc """
  Appends the next page, when there is one and none is already in flight.

  The request offset is `archive_fetched` — the cumulative count of raw server
  rows already received — so a retried append is idempotent (duplicate
  `agent_id`s are dropped on arrival) even after the retention window evicted
  older entries. A no-op when the first page is not `:loaded`, an append is in
  flight, the archive is exhausted, or `EvoDashWeb.ArchiveHelpers.more_pages?/3`
  says nothing is left.
  """
  def load_more(socket) do
    loaded = loaded_count(socket.assigns)
    total = total_count(socket.assigns)
    dropped = dropped_count(socket.assigns)

    if Map.get(socket.assigns, :archive_state) == :loaded and
         not Map.get(socket.assigns, :archive_loading_more?, false) and
         not Map.get(socket.assigns, :archive_exhausted?, false) and
         ArchiveHelpers.more_pages?(loaded, dropped, total) do
      socket
      |> assign(archive_loading_more?: true, archive_more_error: nil)
      |> request_page(fetched_count(socket.assigns))
    else
      socket
    end
  end

  @doc """
  Fetches ONE agent's full archive entry (including its `"result"`), on demand.

  A no-op when the agent is unknown to the loaded page or its result is already
  `:loading`/`:ok`; an `:error` entry is retry-able through the same call.
  """
  def load_agent_result(socket, agent_id) when is_binary(agent_id) and agent_id != "" do
    results = Map.get(socket.assigns, :archive_agent_results, %{})
    cached = if is_map(results), do: Map.get(results, agent_id), else: nil
    cached_state = if is_map(cached), do: Map.get(cached, :state), else: nil

    if cached_state in [:loading, :ok] or not loaded_agent?(socket.assigns, agent_id) do
      socket
    else
      seq = Map.get(socket.assigns, :archive_agent_seq, 0)

      socket
      |> assign(
        :archive_agent_results,
        Map.put(results, agent_id, %{state: :loading, entry: nil, error: nil})
      )
      |> request_agent(agent_id, seq)
    end
  end

  def load_agent_result(socket, _agent_id), do: socket

  @doc """
  Applies an `{:review_archive_loaded, ...}` message to the socket.

  Drops results from a different task/node or from before the current context
  generation. `offset == 0` REPLACES the records (a first page or a retry);
  a larger offset APPENDS, deduped by `agent_id`. Every shape is terminal:
  a first-page failure becomes `:error`, an append failure keeps the loaded
  page and only sets `archive_more_error`.
  """
  def handle_result(socket, task_id, node, seq, offset, result) do
    if stale?(socket, task_id, node, seq, :archive_seq) do
      socket
    else
      apply_page(socket, offset, result)
    end
  end

  @doc """
  Applies a `{:review_archive_agent_loaded, ...}` message to the socket.

  Stale results (another task/node, or a cache generation that has since been
  invalidated) are dropped. A map payload is cached AND folded into the loaded
  page; every other shape becomes a retry-able `:error` entry.
  """
  def handle_agent_result(socket, task_id, node, agent_id, seq, result) do
    if stale?(socket, task_id, node, seq, :archive_agent_seq) do
      socket
    else
      apply_agent_result(socket, agent_id, result)
    end
  end

  @doc """
  Retry handler for the panel's Retry button: re-arms the state machine and
  starts a fresh first page.

  A NO-OP for a task that did not opt into archiving — a non-opt-in task can
  never start a fetch, no matter which control is clicked.
  """
  def retry(socket) do
    if Map.get(socket.assigns, :archive_opt_in?, false) do
      socket
      |> assign(
        archive_state: :idle,
        archive_error: nil,
        archive_key: nil,
        archive_records: [],
        archive_total: 0,
        archive_dropped: 0,
        archive_fetched: 0,
        archive_exhausted?: false,
        archive_server_total: nil,
        archive_loading_more?: false,
        archive_more_error: nil,
        archive_agent_results: %{},
        archive_seq: next_seq(socket, :archive_seq),
        archive_agent_seq: next_seq(socket, :archive_agent_seq)
      )
      |> ensure_loaded()
    else
      socket
    end
  end

  @doc """
  Drops every cached per-agent result while keeping the loaded pages.

  The lazily fetched `"result"` is stripped from the accumulated entries too,
  so each of those agents becomes fetchable again (the "Show result" button
  returns). Bumps the cache generation, so a per-agent fetch still in flight
  when this runs is discarded instead of repopulating the cache.
  """
  def invalidate_agent_results(socket) do
    results = Map.get(socket.assigns, :archive_agent_results, %{})

    if is_map(results) and map_size(results) == 0 do
      socket
    else
      assign(socket,
        archive_agent_results: %{},
        archive_agent_seq: next_seq(socket, :archive_agent_seq),
        archive_records: Enum.map(records(socket.assigns), &drop_result/1)
      )
    end
  end

  @doc """
  Reconciles the archive cache with the current load context.

  Called at the top of `ReviewLive.start_async_load/2`, i.e. exactly when a
  load is (re)started. A nil or matching `archive_key` leaves the cache alone
  (a same task/node reload must not discard a loaded archive); a task/node
  change resets pages, total, pager state, the retention/offset counters AND
  the per-agent results, bumps both generations so in-flight fetches are
  dropped, and re-fetches only when the Archive tab is on screen AND the new
  task opted into archiving.
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
            archive_total: 0,
            archive_dropped: 0,
            archive_fetched: 0,
            archive_exhausted?: false,
            archive_server_total: nil,
            archive_error: nil,
            archive_loading_more?: false,
            archive_more_error: nil,
            archive_agent_results: %{},
            archive_key: nil,
            archive_seq: next_seq(socket, :archive_seq),
            archive_agent_seq: next_seq(socket, :archive_agent_seq)
          )

        if Map.get(socket.assigns, :review_tab) == :archive and
             Map.get(socket.assigns, :archive_opt_in?, false) do
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
  # The EFFECTIVE total (paging decisions); `server_total` is the label size.
  attr :total, :any, default: nil
  attr :opt_in?, :boolean, default: false
  attr :dropped, :integer, default: 0
  attr :exhausted?, :boolean, default: false
  attr :server_total, :integer, default: nil
  attr :loading_more?, :boolean, default: false
  attr :more_error, :any, default: nil
  attr :agent_results, :map, default: %{}
  attr :error, :any, default: nil
  attr :task_id, :any, default: nil
  # Remote node target id (`?node=` value); nil on the local node, so the
  # export href stays the bare task export path.
  attr :node_id, :string, default: nil

  def panel(assigns) do
    message = error_message()
    records = if is_list(assigns.records), do: assigns.records, else: []
    # The error assigns is already the standard message for a failed fetch;
    # surface a distinct binary reason (a transport/RPC detail) beneath it.
    detail = if is_binary(assigns.error) and assigns.error != message, do: assigns.error

    assigns = assign(assigns, records: records, message: message, detail: detail)

    ~H"""
    <%= cond do %>
      <% not @opt_in? -> %>
        <div class="p-8 text-center">
          <.icon name="hero-archive-box-x-mark" class="size-10 text-base-content/40 mx-auto mb-3" />
          <%!-- zh_CN: archive → 归档 --%>
          <p class="text-sm text-base-content/60">
            {gettext("Archive data was not collected for this task.")}
          </p>
          <%!-- zh_CN: archive → 归档 --%>
          <p class="mt-1 text-xs text-base-content/50">
            {gettext("Tasks started without archiving enabled keep no per-agent archive.")}
          </p>
        </div>
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
          total={@total}
          dropped={@dropped}
          exhausted?={@exhausted?}
          server_total={@server_total}
          loading_more?={@loading_more?}
          more_error={@more_error}
          agent_results={@agent_results}
          task_id={@task_id}
          export_url={EvoDashWeb.Helpers.with_node_param("/tasks/#{@task_id}/export", @node_id)}
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

  @doc """
  The count the archive is LABELLED with (tab badge + section header).

  `max(server_total, effective_total)` when the server reported a usable count,
  else the effective total (`0` for a missing/garbage total). Kept separate from
  the EFFECTIVE total because the label shows the archive's true size even once
  paging was clamped by exhaustion/eviction. TOTAL — never raises.
  """
  def label_total(assigns) do
    case Map.get(assigns, :archive_server_total) do
      total when is_integer(total) and total >= 0 -> max(total, total_count(assigns))
      _other -> total_count(assigns)
    end
  end

  # Single source of the failure message (a gettext literal so extraction sees
  # it); the fetch paths and the panel share it.
  defp error_message, do: gettext("Failed to load archive data.")

  # --- State machine ---

  defp start_fetch(socket) do
    seq = next_seq(socket, :archive_seq)

    socket
    |> assign(
      archive_seq: seq,
      archive_state: :loading,
      archive_error: nil,
      archive_records: [],
      archive_total: 0,
      archive_dropped: 0,
      archive_fetched: 0,
      archive_exhausted?: false,
      archive_server_total: nil,
      archive_loading_more?: false,
      archive_more_error: nil,
      archive_agent_results: %{},
      archive_agent_seq: next_seq(socket, :archive_agent_seq),
      archive_key: {socket.assigns.task_id, socket.assigns.current_node}
    )
    |> request_page(0)
  end

  defp apply_page(socket, 0, result) do
    case result do
      {:ok, %{entries: entries, total: total}} ->
        apply_page_success(socket, 0, entries, total, entries)

      {:error, reason} ->
        assign(socket,
          archive_state: :error,
          archive_error: reason,
          archive_records: [],
          archive_total: 0,
          archive_dropped: 0,
          archive_fetched: 0,
          archive_exhausted?: false,
          archive_server_total: nil,
          archive_loading_more?: false,
          archive_more_error: nil
        )

      _unexpected ->
        assign(socket,
          archive_state: :error,
          archive_error: error_message(),
          archive_records: [],
          archive_total: 0,
          archive_dropped: 0,
          archive_fetched: 0,
          archive_exhausted?: false,
          archive_server_total: nil,
          archive_loading_more?: false,
          archive_more_error: nil
        )
    end
  end

  defp apply_page(socket, offset, result) do
    case result do
      {:ok, %{entries: entries, total: total}} ->
        accumulated = append_entries(records(socket.assigns), entries)
        apply_page_success(socket, offset, entries, total, accumulated)

      {:error, reason} ->
        # The loaded page stays exactly as it was — only the append failed.
        assign(socket,
          archive_loading_more?: false,
          archive_more_error: reason,
          archive_state: :loaded
        )

      _unexpected ->
        assign(socket,
          archive_loading_more?: false,
          archive_more_error: error_message(),
          archive_state: :loaded
        )
    end
  end

  # Folds ONE successful page into the accumulated records + pager state.
  #
  # `offset` is the RAW request offset, so `fetched = offset + page size` counts
  # every server row received even after the retention window evicted older
  # ones — it is the only source of the next offset. A page shorter than
  # `@page_limit` (an empty page included) means the archive ends here, and the
  # effective total is then clamped to the distinct loaded rows
  # (`dropped + retained`), because the core may not send a per-page COUNT.
  defp apply_page_success(socket, offset, page_entries, total, accumulated) do
    previous_dropped = if offset == 0, do: 0, else: dropped_count(socket.assigns)
    {retained, dropped} = ArchiveHelpers.retain_window(accumulated, previous_dropped)
    fetched = offset + length(page_entries)
    exhausted? = length(page_entries) < @page_limit
    server_total = if is_integer(total) and total >= 0, do: total

    effective_total =
      if exhausted? do
        dropped + length(retained)
      else
        max(fetched, server_total || 0)
      end

    assign(socket,
      archive_state: :loaded,
      archive_records: retained,
      archive_total: effective_total,
      archive_dropped: dropped,
      archive_fetched: fetched,
      archive_exhausted?: exhausted?,
      archive_server_total: server_total,
      archive_loading_more?: false,
      archive_more_error: nil,
      archive_error: nil
    )
  end

  defp apply_agent_result(socket, agent_id, result) do
    results = Map.get(socket.assigns, :archive_agent_results, %{})
    results = if is_map(results), do: results, else: %{}

    case result do
      {:ok, entry} when is_map(entry) ->
        assign(socket,
          archive_agent_results:
            Map.put(results, agent_id, %{state: :ok, entry: entry, error: nil}),
          archive_records: ArchiveHelpers.merge_entry(records(socket.assigns), entry)
        )

      {:error, reason} ->
        assign(
          socket,
          :archive_agent_results,
          Map.put(results, agent_id, %{state: :error, entry: nil, error: reason})
        )

      other ->
        # Anything else (a nil payload included) is terminal, so the UI can
        # offer Retry instead of spinning forever.
        assign(
          socket,
          :archive_agent_results,
          Map.put(results, agent_id, %{state: :error, entry: nil, error: other})
        )
    end
  end

  # A result is stale when it belongs to another task/node, or when it was
  # requested before the current generation of its own cache (a reset / retry /
  # invalidation happened in the meantime). Pages and per-agent results carry
  # SEPARATE generations, so invalidating the result cache never drops a page
  # append in flight (and vice versa).
  defp stale?(socket, task_id, node, seq, generation_key) do
    task_id != socket.assigns.task_id or node != socket.assigns.current_node or
      not is_integer(seq) or seq < Map.get(socket.assigns, generation_key, 0)
  end

  defp next_seq(socket, key), do: Map.get(socket.assigns, key, 0) + 1

  defp records(assigns) do
    case Map.get(assigns, :archive_records) do
      records when is_list(records) -> records
      _other -> []
    end
  end

  defp loaded_count(assigns), do: length(records(assigns))

  defp total_count(assigns) do
    case Map.get(assigns, :archive_total) do
      total when is_integer(total) and total >= 0 -> total
      _other -> 0
    end
  end

  # Cumulative RAW server rows received — the ONLY source of the next request
  # offset (the retained record count shrinks once the window evicts).
  defp fetched_count(assigns) do
    case Map.get(assigns, :archive_fetched) do
      fetched when is_integer(fetched) and fetched >= 0 -> fetched
      _other -> 0
    end
  end

  defp dropped_count(assigns) do
    case Map.get(assigns, :archive_dropped) do
      dropped when is_integer(dropped) and dropped >= 0 -> dropped
      _other -> 0
    end
  end

  defp loaded_agent?(assigns, agent_id) do
    Enum.any?(records(assigns), &(ArchiveHelpers.agent_key(&1, :agent_id) == agent_id))
  end

  # --- Fetching ---

  # Spawns ONE page fetch for the current task/node. Parent/task_id/node/seq
  # are snapshotted into locals; the fetch runs behind EvoDash.SafeCall.run/1
  # and the result message is ALWAYS sent — a dead child would otherwise wedge
  # the panel on :loading. The runner is resolved inside the child (call time),
  # so an injected test seam is honoured.
  defp request_page(socket, offset) do
    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id
    seq = Map.get(socket.assigns, :archive_seq, 0)
    opts = [limit: @page_limit, offset: offset, include_results: false]

    spawn_result =
      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        runner =
          Application.get_env(:evo_dash, :review_archive_runner) ||
            (&EvoDash.NodeContext.list_task_archives/3)

        result =
          case EvoDash.SafeCall.run(fn -> runner.(node, task_id, opts) end) do
            {:ok, %{entries: entries, total: total}}
            when is_list(entries) and is_integer(total) and total >= 0 ->
              {:ok, %{entries: entries, total: total}}

            {:ok, %{entries: entries}} when is_list(entries) ->
              # A page without a usable total is still renderable; treat it as
              # fully loaded rather than inventing a longer archive.
              {:ok, %{entries: entries, total: length(entries) + offset}}

            _ ->
              {:error, error_message()}
          end

        send(parent, {:review_archive_loaded, task_id, node, seq, offset, result})
      end)

    case spawn_result do
      {:ok, _pid} -> socket
      # A dead supervisor must not leave a wedge behind: apply the failure as
      # if the fetch had reported it.
      {:error, reason} -> apply_page(socket, offset, {:error, reason})
    end
  end

  defp request_agent(socket, agent_id, seq) do
    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id

    spawn_result =
      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        runner =
          Application.get_env(:evo_dash, :review_archive_agent_runner) ||
            (&EvoDash.NodeContext.get_agent_archive/3)

        result =
          case EvoDash.SafeCall.run(fn -> runner.(node, task_id, agent_id) end) do
            {:ok, entry} when is_map(entry) -> {:ok, entry}
            # A nil/non-map payload is a terminal failure (Retry), never a
            # spinner.
            _ -> {:error, error_message()}
          end

        send(parent, {:review_archive_agent_loaded, task_id, node, agent_id, seq, result})
      end)

    case spawn_result do
      {:ok, _pid} -> socket
      {:error, reason} -> apply_agent_result(socket, agent_id, {:error, reason})
    end
  end

  # --- Entry list helpers ---

  defp append_entries(existing, incoming) when is_list(existing) and is_list(incoming) do
    {new_entries, _seen} =
      Enum.reduce(incoming, {[], MapSet.new(existing, &agent_id_of/1)}, fn entry, {acc, seen} ->
        id = agent_id_of(entry)

        cond do
          id in [nil, ""] -> {[entry | acc], seen}
          MapSet.member?(seen, id) -> {acc, seen}
          true -> {[entry | acc], MapSet.put(seen, id)}
        end
      end)

    existing ++ Enum.reverse(new_entries)
  end

  defp append_entries(existing, _incoming), do: existing

  defp agent_id_of(entry) when is_map(entry), do: ArchiveHelpers.agent_key(entry, :agent_id)
  defp agent_id_of(_entry), do: nil

  defp drop_result(entry) when is_map(entry) do
    entry |> Map.delete(:result) |> Map.delete("result")
  end

  defp drop_result(entry), do: entry
end
