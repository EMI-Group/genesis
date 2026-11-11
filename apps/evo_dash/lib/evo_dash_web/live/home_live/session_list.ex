defmodule EvoDashWeb.HomeLive.SessionList do
  @moduledoc """
  Conversation-list SECTION BODY for the shared app-layout sidebar
  (`EvoDashWeb.Layouts.app/1`) — the Genesis Assistant's conversation list
  (`EvoDashWeb.HomeLive` at `/assistant`), rendered below "Active Tasks" on
  EVERY dashboard page.

  The section HEADER ("Conversations") belongs to the layout; this module
  renders the section body only (rows, loading/error/empty states) and owns the
  data loading it feeds (`load/1`, `spawn_load/2`, `applied/4`), driven by
  `EvoDashWeb.LiveHooks.NodeAware` on every page.

  The list is the UNION of two sources:

    * LIVE interactive sessions — this node's root self-reflective agents that
      are parked at `:awaiting_input` or currently `:running`, read through
      `EvoDashWeb.HomeLive.SessionActions.list/1` (which resolves the
      call-time `:home_session_list_runner` seam itself); and
    * CACHED local conversations — `EvoDash.ChatHistory.list_chats/0`
      (already newest-first) plus each chat's persisted state for its title,
      so a conversation with no live session (a finished session, a legacy
      one-shot `:reflect` chat) stays reachable.

  A live session always WINS over a cached chat with the same id, because an
  interactive session's agent id IS its chat id.

  ## Row shape

      %{id: pos_integer(), title: String.t(), marker: :awaiting_input | :running | :ended}

  Ordering: `:awaiting_input` rows first (newest id first), then `:running`
  (newest id first), then `:ended` rows in the cached order
  (`ChatHistory.list_chats/0` is already newest-first).

  ## Async load contract

  `spawn_load/2` runs the (possibly remote) load on `EvoDash.TaskSupervisor`
  through `EvoDash.SafeCall.start/4` and ALWAYS reports
  `{{:session_list_loaded, seq, node}, result}` — the tag is NESTED inside the
  message's first element, so the consumer's clause must match
  `{{:session_list_loaded, seq, node}, result}`. `applied/4` applies only a
  result whose seq and node still match the socket.

  The OWNER of that load is `EvoDashWeb.LiveHooks.NodeAware` (it intercepts the
  result in its attached `:handle_info` hook); the Assistant page only asks for
  a page-local refresh after it adopts or closes a session.

  Everything in this module is TOTAL and defensive (no dot access on optional
  maps, no atom conversion from untrusted input, no `try/rescue`); a raising
  seam is deliberately left to propagate into the caller's `EvoDash.SafeCall`
  boundary.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.HomeLive.SessionActions

  # Title cap: enough to identify a conversation in a narrow rail.
  @title_chars 80

  # Agent statuses that mean "this session is live" (atom or string form).
  @live_statuses [:awaiting_input, :running]
  @live_status_strings Enum.map(@live_statuses, &Atom.to_string/1)

  # Where a row title may come from on a core agent summary / persisted state.
  @objective_keys [
    :objective,
    "objective",
    :objective_preview,
    "objective_preview",
    :title,
    "title",
    :first_message,
    "first_message",
    :message,
    "message"
  ]

  @type marker :: :awaiting_input | :running | :ended
  @type row :: %{id: pos_integer(), title: String.t(), marker: marker()}

  @doc """
  Loads the conversation rows for `node`.

  Returns `{:ok, rows}` or `{:error, reason}` (the seam's own error value).
  A seam answer that is not the documented `{agent_summaries, awaiting_entries}`
  pair degrades to the cached conversations instead of raising.

  Callers wrap this in `EvoDash.SafeCall` (a cross-node read can EXIT its
  caller, which no `rescue` catches), so no error handling is duplicated here.
  """
  @spec load(node()) :: {:ok, [row()]} | {:error, term()}
  def load(node) do
    case SessionActions.list(node) do
      {:error, reason} ->
        {:error, reason}

      {agent_summaries, awaiting_entries} ->
        {:ok, build_rows(agent_summaries, awaiting_entries, cached_chats())}

      # Not the documented pair: still show the local cache rather than an
      # empty rail (and never raise on a broken seam answer).
      _other ->
        {:ok, build_rows([], [], cached_chats())}
    end
  end

  @doc """
  Builds the sorted row list from the raw inputs — PURE and TOTAL.

  `agent_summaries` are `EvoGit.AgentScheduler` summary maps (atom- or
  string-keyed), `awaiting_entries` the `list_awaiting_input/1` answer
  (`%{agent_id, ...}` maps), and `cached_chats` the cached local conversations
  as bare ids, `{id, state}` tuples or state maps.
  """
  @spec build_rows(term(), term(), term()) :: [row()]
  def build_rows(agent_summaries, awaiting_entries, cached_chats) do
    awaiting_ids = awaiting_ids(awaiting_entries)

    live_rows =
      agent_summaries
      |> summary_list()
      |> Enum.filter(&live_summary?(&1, awaiting_ids))
      |> Enum.map(&live_row(&1, awaiting_ids))

    live_ids = MapSet.new(live_rows, & &1.id)

    ended_rows =
      cached_chats
      |> cached_entries()
      |> Enum.reject(fn {id, _state} -> MapSet.member?(live_ids, id) end)
      |> Enum.map(fn {id, state} -> %{id: id, title: row_title(state, id), marker: :ended} end)

    awaiting_rows = live_rows |> Enum.filter(&(&1.marker == :awaiting_input)) |> newest_first()
    running_rows = live_rows |> Enum.filter(&(&1.marker == :running)) |> newest_first()

    awaiting_rows ++ running_rows ++ ended_rows
  end

  @doc """
  The row title for a row source: the first `:user` transcript entry's text,
  else a core row objective/first-message field, else
  `gettext("Session %{id}", id: fallback_id)`.

  Truncated to 80 graphemes. Total — an unusable source always falls through
  to the id-based label.
  """
  @spec row_title(term(), term()) :: String.t()
  def row_title(source, fallback_id) do
    source
    |> candidate_title()
    |> case do
      title when is_binary(title) -> String.slice(title, 0, @title_chars)
      _other -> gettext("Session %{id}", id: id_label(fallback_id))
    end
  end

  @doc """
  Starts ONE supervised, guarded list load for `target_node`.

  Increments `:session_list_seq` (from `assigns[:session_list_seq] || 0`), sets
  `:session_list_loading`, clears `:session_list_error`, and reports
  `{{:session_list_loaded, seq, node}, result}` to the calling LiveView — the
  tag is NESTED. Never blocks and never raises: a supervisor that cannot start
  the child clears the loading flag immediately (nothing would be sent).
  """
  @spec spawn_load(Phoenix.LiveView.Socket.t(), node()) :: Phoenix.LiveView.Socket.t()
  def spawn_load(socket, target_node) do
    seq = (socket.assigns[:session_list_seq] || 0) + 1
    node = socket.assigns[:current_node]

    socket =
      assign(socket,
        session_list_seq: seq,
        session_list_loading: true,
        session_list_error: nil
      )

    case EvoDash.SafeCall.start(self(), {:session_list_loaded, seq, node}, fn ->
           load(target_node)
         end) do
      {:ok, _pid} ->
        socket

      {:error, reason} ->
        assign(socket, session_list_loading: false, session_list_error: reason)
    end
  end

  @doc """
  Applies a `:session_list_loaded` result — only when `seq` still matches
  `assigns[:session_list_seq]` AND `node` matches `assigns[:current_node]`
  (older in-flight results and results from a previously viewed node are
  dropped silently).

  A success replaces `:session_list`; an error keeps the rows already shown and
  records `:session_list_error`. A matching result ALWAYS clears the loading
  flag, so the panel can never wedge.
  """
  @spec applied(Phoenix.LiveView.Socket.t(), term(), term(), term()) ::
          Phoenix.LiveView.Socket.t()
  def applied(socket, seq, node, result) do
    if seq == socket.assigns[:session_list_seq] and node == socket.assigns[:current_node] do
      case normalize_result(result) do
        {:ok, rows} ->
          assign(socket,
            session_list: rows,
            session_list_loading: false,
            session_list_error: nil
          )

        {:error, reason} ->
          assign(socket, session_list_loading: false, session_list_error: reason)
      end
    else
      socket
    end
  end

  # `EvoDash.SafeCall.run/1` wraps `load/1`'s own tagged answer, so a success
  # arrives as `{:ok, {:ok, rows}}`. Every other shape is accepted defensively.
  defp normalize_result({:ok, {:ok, rows}}) when is_list(rows), do: {:ok, rows}
  defp normalize_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_result({:ok, rows}) when is_list(rows), do: {:ok, rows}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, {:unexpected_session_list_result, other}}

  ## Live sessions

  defp summary_list(summaries) when is_list(summaries), do: Enum.filter(summaries, &is_map/1)
  defp summary_list(_summaries), do: []

  defp awaiting_ids(entries) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, :agent_id, Map.get(&1, "agent_id")))
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> MapSet.new()
  end

  defp awaiting_ids(_entries), do: MapSet.new()

  # A live row is a ROOT self-reflective session summary that is either parked
  # at `:awaiting_input` / `:running`, or whose id the awaiting list reports
  # (the awaiting list is authoritative for "alive but idle").
  defp live_summary?(summary, awaiting_ids) do
    SessionActions.session_agent?(summary) and
      (MapSet.member?(awaiting_ids, agent_id(summary)) or live_status?(status_of(summary)))
  end

  defp live_row(summary, awaiting_ids) do
    id = agent_id(summary)

    marker =
      if MapSet.member?(awaiting_ids, id), do: :awaiting_input, else: :running

    %{id: id, title: row_title(summary, id), marker: marker}
  end

  defp live_status?(status) when status in @live_statuses, do: true
  defp live_status?(status) when status in @live_status_strings, do: true
  defp live_status?(_status), do: false

  defp status_of(summary), do: Map.get(summary, :status, Map.get(summary, "status"))

  defp agent_id(summary), do: Map.get(summary, :id, Map.get(summary, "id"))

  defp newest_first(rows), do: Enum.sort_by(rows, & &1.id, :desc)

  ## Cached conversations

  defp cached_chats do
    EvoDash.ChatHistory.list_chats()
    |> Enum.map(&cached_chat/1)
  end

  defp cached_chat(id) when is_integer(id) and id > 0, do: {id, EvoDash.ChatHistory.get_state(id)}
  defp cached_chat(other), do: other

  defp cached_entries(chats) when is_list(chats) do
    chats
    |> Enum.map(&cached_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn {id, _state} -> id end)
  end

  defp cached_entries(_chats), do: []

  defp cached_entry({id, state}) when is_integer(id) and id > 0 do
    {id, if(is_map(state), do: state, else: nil)}
  end

  defp cached_entry(%{} = state) do
    id =
      Map.get(state, :session_id) || Map.get(state, "session_id") ||
        Map.get(state, :id) || Map.get(state, "id")

    if is_integer(id) and id > 0, do: {id, state}
  end

  defp cached_entry(id) when is_integer(id) and id > 0, do: {id, nil}
  defp cached_entry(_other), do: nil

  ## Titles

  defp candidate_title(source) do
    case transcript_title(source) do
      nil -> objective_title(source)
      title -> title
    end
  end

  defp transcript_title(%{} = source) do
    source
    |> Map.get(:transcript, Map.get(source, "transcript"))
    |> transcript_title()
  end

  defp transcript_title(entries) when is_list(entries) do
    Enum.find_value(entries, fn
      %{} = entry ->
        role = Map.get(entry, :role, Map.get(entry, "role"))
        text = Map.get(entry, :text, Map.get(entry, "text"))

        if user_role?(role) and is_binary(text), do: present_text(text)

      _entry ->
        nil
    end)
  end

  defp transcript_title(_source), do: nil

  defp user_role?(role) when role in [:user, "user"], do: true
  defp user_role?(_role), do: false

  defp objective_title(%{} = source) do
    Enum.find_value(@objective_keys, fn key ->
      case Map.get(source, key) do
        value when is_binary(value) -> present_text(value)
        _value -> nil
      end
    end)
  end

  defp objective_title(_source), do: nil

  defp present_text(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp id_label(id) when is_binary(id), do: id
  defp id_label(id) when is_integer(id), do: Integer.to_string(id)
  defp id_label(id), do: inspect(id)

  ## Panel

  @doc """
  The conversation-list SECTION BODY (rendered inside the layout sidebar, under
  the layout-owned "Conversations" header).

  Declares NO attributes and reads every value defensively from `assigns`, so a
  fixture missing the session assigns still renders (empty, no error). It is a
  plain column of rows — no card chrome, no background, no heading of its own —
  styled like the neighbouring Active Tasks rows.

  ## Page-dependent link destination

  On the Assistant page itself (`assigns[:current_page] == :assistant`) a row
  PATCHES to `EvoDashWeb.HomeLive.SessionActions.url/2`: the LiveView, its
  transcript and its stream stay mounted while only `?session=` changes. On
  EVERY other page a row NAVIGATES instead, because patching to a DIFFERENT
  LiveView is illegal in Phoenix LiveView. `destination/2` returns exactly one
  of `{navigate_url, patch_url}` — the unused attribute is `nil`, so the
  rendered link carries one destination.

  Assigns read: `:session_list`, `:session_list_loading`, `:session_list_error`,
  `:current_node_id`, `:current_session_id` and `:current_page`.
  """
  def session_list(assigns) do
    rows = row_list(assigns[:session_list])
    loading? = assigns[:session_list_loading] == true
    error = assigns[:session_list_error]

    assigns =
      assign(assigns,
        session_rows: rows,
        session_list_loading?: loading?,
        session_list_error?: not is_nil(error),
        session_list_empty?: rows == [] and not loading? and is_nil(error)
      )

    ~H"""
    <div id="chat-session-list" class="space-y-1">
      <p :if={@session_list_loading?} class="px-3 py-1 text-xs text-base-content/50">
        <%!-- zh_CN: 加载中… --%>{gettext("Loading…")}
      </p>

      <p
        :if={@session_list_error?}
        role="alert"
        class="mx-3 rounded-md border border-warning/30 bg-warning/10 px-2 py-1 text-xs text-base-content/80"
      >
        {gettext("Could not load conversations.")}
      </p>

      <p :if={@session_list_empty?} class="px-3 py-2 text-xs text-base-content/50">
        {gettext("No conversations yet.")}
      </p>

      <%= for row <- @session_rows do %>
        <% {nav, patch} = destination(assigns, row.id) %>
        <.link
          id={"chat-session-#{row.id}"}
          navigate={nav}
          patch={patch}
          aria-current={if row.id == assigns[:current_session_id], do: "page", else: nil}
          title={row.title}
          class={[
            "flex items-center gap-2 px-3 py-2.5 rounded-lg text-sm transition-colors group",
            if(row.id == assigns[:current_session_id],
              do: "bg-primary/10 text-primary-standalone",
              else: "text-base-content/80 hover:bg-base-300/70 hover:text-base-content"
            )
          ]}
        >
          <span
            class={["w-2.5 h-2.5 rounded-full shrink-0", marker_dot_class(row.marker)]}
            aria-hidden="true"
          ></span>
          <span class="min-w-0 flex-1 truncate group-hover:text-base-content transition-colors">
            {row.title}
          </span>
          <span class="shrink-0 text-xs text-base-content/60">{marker_label(row.marker)}</span>
        </.link>
      <% end %>
    </div>
    """
  end

  # The row's destination attribute pair `{navigate, patch}`: a PATCH on the
  # Assistant page (same LiveView, only the query state changes) and a NAVIGATE
  # anywhere else (a patch to a different LiveView is illegal). Exactly one of
  # the two is a URL; the other is nil, so exactly one destination renders.
  defp destination(assigns, id) do
    url = SessionActions.url(assigns[:current_node_id], id)

    if assigns[:current_page] == :assistant do
      {nil, url}
    else
      {url, nil}
    end
  end

  defp row_list(rows) when is_list(rows) do
    Enum.filter(rows, fn
      %{id: id, title: title, marker: marker} ->
        is_integer(id) and id > 0 and is_binary(title) and
          marker in [:awaiting_input, :running, :ended]

      _row ->
        false
    end)
  end

  defp row_list(_rows), do: []

  defp marker_dot_class(:awaiting_input), do: "bg-[oklch(0.68_0.17_290)]"
  defp marker_dot_class(:running), do: "bg-warning animate-pulse"
  defp marker_dot_class(_marker), do: "bg-base-content/30"

  defp marker_label(:awaiting_input), do: gettext("Waiting for you")
  defp marker_label(:running), do: gettext("Running")
  defp marker_label(_marker), do: gettext("Ended")
end
