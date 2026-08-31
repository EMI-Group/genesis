defmodule EvoDash.ChatHistory do
  @moduledoc """
  In-memory chat-history store for the dashboard's Home chat page
  (`EvoDashWeb.HomeLive`).

  The Home page's chat transcript lives only in the LiveView process, so it is
  lost on every LiveView remount (re-navigation, reconnection, mount crash).
  This store keeps per-chat state in memory so `HomeLive` can rehydrate its
  transcript on remount and conversations survive page navigation — the domain
  half of the chat-survival fix.

  ## Concurrency & design decision

  All operations go through synchronous `GenServer` calls. The GenServer owns
  a named public ETS table (`:evo_dash_chat_history`) created in `init/1`; the
  table lives exactly as long as the GenServer (no heir, no disk), so chats
  are volatile by design: they survive LiveView remounts, not BEAM restarts or
  a store crash.

  Routing every operation through the GenServer was chosen over letting
  callers hit the public ETS table directly because several operations are
  COMPOUND (`new_chat/0` inserts the chat AND makes it current,
  `delete_chat/1` removes the chat AND may clear the current pointer,
  `prune/1` scans and deletes, `reset/0` clears everything) — serializing them
  through one process makes them atomic without locks. Single-key operations
  (`put_state/2`, `get_state/1`) would also be safe directly on ETS (ETS
  writes are atomic per call), but they go through the GenServer too, for one
  single trivially-reasoned concurrency model; chat operations are
  low-frequency (per user interaction, not per render), so the serialization
  cost is negligible. The table is `:public` with `read_concurrency: true` so
  external readers (debugging, observers) may inspect it safely — individual
  reads are atomic — but mutations MUST go through this API.

  ## Data model

  The store is shape-agnostic about message content: per-chat state is an
  opaque `term()`; the LiveView owns the shape of transcripts/messages.

  Table entries:

    * `{:current}` → `chat_id | :none` — the current-chat pointer
    * `{:chat, chat_id}` → `{seq, state}` — a strictly increasing creation
      sequence (drives `list_chats/0`'s newest-first ordering — NOT the chat
      id, which is unique but not guaranteed ordered) and the opaque per-chat
      state (`nil` until the first `put_state/2`)

  Memory is bounded only by explicit `prune/1` calls — pruning is NEVER
  automatic; the caller decides when to cap retained chats.

  ## Totality

  Every callback is total — no raising on bad input. Unknown chat ids are
  no-ops (`delete_chat/1`) or read as `nil` (`get_state/1`);
  `set_current_chat/1` does not validate existence (a dangling current id
  simply renders as an empty chat); `prune/1` ignores non-integer/negative
  bounds. `get_state/1` returns `nil` for both an unknown chat and a chat
  whose state was never set (or explicitly stored as `nil`).
  """

  use GenServer

  @table :evo_dash_chat_history

  @typedoc "A chat id: a positive integer from `System.unique_integer([:positive])`."
  @type chat_id :: pos_integer()

  # --- Client API ---

  @doc """
  Starts the store, registered as `EvoDash.ChatHistory`.

  The GenServer creates and owns the named public ETS table
  (`:evo_dash_chat_history`) — the table is destroyed together with the
  GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new chat, makes it the current chat, and returns its id.
  """
  @spec new_chat() :: chat_id()
  def new_chat do
    GenServer.call(__MODULE__, :new_chat)
  end

  @doc "Returns the current chat id, or `nil` when none is set."
  @spec current_chat_id() :: chat_id() | nil
  def current_chat_id do
    GenServer.call(__MODULE__, :current_chat_id)
  end

  @doc """
  Makes `chat_id` the current chat.

  Always returns `:ok`; the id is NOT validated against existing chats — a
  dangling current id is harmless (`get_state/1` reads as `nil`). Callers
  should pass ids obtained from `new_chat/0` or `list_chats/0`.
  """
  @spec set_current_chat(chat_id()) :: :ok
  def set_current_chat(chat_id) do
    GenServer.call(__MODULE__, {:set_current_chat, chat_id})
  end

  @doc "Lists all chat ids, newest first."
  @spec list_chats() :: [chat_id()]
  def list_chats do
    GenServer.call(__MODULE__, :list_chats)
  end

  @doc """
  Deletes the chat (a no-op for unknown ids).

  If the deleted chat was the current chat, the current pointer is cleared
  (`current_chat_id/0` returns `nil` afterwards).
  """
  @spec delete_chat(chat_id()) :: :ok
  def delete_chat(chat_id) do
    GenServer.call(__MODULE__, {:delete_chat, chat_id})
  end

  @doc """
  Keeps only the newest `max_chats` chats, deleting the rest.

  Used to cap memory; it is NEVER called automatically — the caller decides
  when to prune. If the current chat is pruned away, the current pointer is
  cleared. Non-integer or negative bounds are ignored (no-op); `0` clears all
  chats.
  """
  @spec prune(pos_integer()) :: :ok
  def prune(max_chats) do
    GenServer.call(__MODULE__, {:prune, max_chats})
  end

  @doc """
  Upserts the opaque per-chat state.

  An unknown `chat_id` registers it as a new (newest) chat carrying this
  state. The store never inspects the state — its shape is owned by the
  caller (the LiveView).
  """
  @spec put_state(chat_id(), term()) :: :ok
  def put_state(chat_id, chat_state) do
    GenServer.call(__MODULE__, {:put_state, chat_id, chat_state})
  end

  @doc """
  Returns the opaque per-chat state, or `nil` for an unknown chat.

  `nil` is also returned for a chat whose state was never set (or was
  explicitly stored as `nil`).
  """
  @spec get_state(chat_id()) :: term() | nil
  def get_state(chat_id) do
    GenServer.call(__MODULE__, {:get_state, chat_id})
  end

  @doc """
  Clears ALL chats and the current pointer (test helper / hard reset).
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    # The GenServer OWNS the table: it is created here and destroyed together
    # with the GenServer (no heir). A name clash can therefore only mean a
    # genuine bug (a second live owner) — let :ets.new raise loudly instead
    # of silently reusing a foreign table.
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true}
      ])

    # Materialize the current pointer at creation so reads never special-case
    # a missing key.
    :ets.insert(table, {{:current}, :none})

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:new_chat, _from, %{table: table} = state) do
    chat_id = System.unique_integer([:positive])
    seq = System.unique_integer([:monotonic, :positive])

    :ets.insert(table, [
      {{:chat, chat_id}, {seq, nil}},
      {{:current}, chat_id}
    ])

    {:reply, chat_id, state}
  end

  @impl true
  def handle_call(:current_chat_id, _from, %{table: table} = state) do
    {:reply, fetch_current(table), state}
  end

  @impl true
  def handle_call({:set_current_chat, chat_id}, _from, %{table: table} = state) do
    # No existence validation (see the @doc): pointing the current pointer at
    # an unknown id is harmless, and silently ignoring it would hide caller
    # bugs.
    :ets.insert(table, {{:current}, chat_id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_chats, _from, %{table: table} = state) do
    {:reply, newest_first(table), state}
  end

  @impl true
  def handle_call({:delete_chat, chat_id}, _from, %{table: table} = state) do
    :ets.delete(table, {:chat, chat_id})

    case :ets.lookup(table, {:current}) do
      [{{:current}, ^chat_id}] -> :ets.insert(table, {{:current}, :none})
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:prune, max_chats}, _from, %{table: table} = state)
      when is_integer(max_chats) and max_chats >= 0 do
    {_kept, dropped} = Enum.split(newest_first(table), max_chats)

    for chat_id <- dropped do
      :ets.delete(table, {:chat, chat_id})
    end

    clear_current_if_dropped(table, dropped)

    {:reply, :ok, state}
  end

  def handle_call({:prune, _max_chats}, _from, state) do
    # Non-integer / negative bounds: ignore (total API, never raise).
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put_state, chat_id, chat_state}, _from, %{table: table} = state) do
    seq =
      case :ets.lookup(table, {:chat, chat_id}) do
        [{{:chat, ^chat_id}, {existing_seq, _existing_state}}] ->
          existing_seq

        [] ->
          # Upsert: an unknown chat id registers a new (newest) chat.
          System.unique_integer([:monotonic, :positive])
      end

    :ets.insert(table, {{:chat, chat_id}, {seq, chat_state}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_state, chat_id}, _from, %{table: table} = state) do
    chat_state =
      case :ets.lookup(table, {:chat, chat_id}) do
        [{{:chat, ^chat_id}, {_seq, value}}] -> value
        [] -> nil
      end

    {:reply, chat_state, state}
  end

  @impl true
  def handle_call(:reset, _from, %{table: table} = state) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {{:current}, :none})
    {:reply, :ok, state}
  end

  # --- Private helpers ---

  # All chat ids newest-first, ordered by the internal monotonic creation
  # sequence (chat ids themselves are unique but not guaranteed ordered).
  #
  # Uses :ets.match_object with a plain match pattern (not :ets.select match
  # specs): match-spec match HEADS on this OTP cannot contain nested tuples,
  # so they cannot match tuple keys at all.
  defp newest_first(table) do
    table
    |> :ets.match_object({{:chat, :_}, :_})
    |> Enum.sort_by(fn {{:chat, _chat_id}, {seq, _state}} -> seq end, :desc)
    |> Enum.map(fn {{:chat, chat_id}, _value} -> chat_id end)
  end

  defp fetch_current(table) do
    case :ets.lookup(table, {:current}) do
      [{{:current}, :none}] -> nil
      [{{:current}, chat_id}] -> chat_id
      [] -> nil
    end
  end

  defp clear_current_if_dropped(table, dropped) do
    case :ets.lookup(table, {:current}) do
      [{{:current}, chat_id}] when chat_id != :none ->
        if chat_id in dropped do
          :ets.insert(table, {{:current}, :none})
        end

      _ ->
        :ok
    end
  end
end
