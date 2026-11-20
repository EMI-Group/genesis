defmodule EvoDash.ChatHistory do
  # Declared before @moduledoc so the documentation can interpolate the real
  # bounds instead of restating them.
  @table :evo_dash_chat_history

  # Conversations retained by the creation-time prune (`new_chat/0,1`).
  @max_chats 10

  # Temporary composer drafts retained before the least recently saved is
  # evicted.
  @max_drafts 80

  @moduledoc """
  In-memory chat-history store for the dashboard's Home chat page
  (`EvoDashWeb.HomeLive`) plus the workbench's temporary composer drafts.

  The Home page's chat transcript lives only in the LiveView process, so it is
  lost on every LiveView remount (re-navigation, reconnection, mount crash).
  This store keeps per-chat state in memory so `HomeLive` can rehydrate its
  transcript on remount and conversations survive page navigation — the domain
  half of the chat-survival fix.

  ## Concurrency & design decision

  ONE `GenServer` owns a named public ETS table (`:evo_dash_chat_history`)
  created in `init/1`; the table lives exactly as long as the GenServer (no
  heir, no disk), so chats are volatile by design: they survive LiveView
  remounts, not BEAM restarts or a store crash.

  The GenServer exists for table OWNERSHIP and for the COMPOUND operations
  only — the ones whose correctness comes from being serialized:

    * `new_chat/0,1` — inserts a chat AND its scoped current pointer, then
      caps the conversation index (two-plus writes, one atomic step);
    * `delete_chat/1` — removes a chat AND clears every pointer aimed at it;
    * `prune/1` — scans newest-first, deletes, clears the dropped pointers;
    * `reset/0` — clears the whole table;
    * `discard_workbench_draft/1` — pattern-deletes a family of draft rows.

  Every SINGLE-KEY operation runs DIRECTLY on the public ETS table, with NO
  `GenServer.call`: `get_state/1`, `put_state/2`, `list_chats/0`,
  `conversations/0`, `current_chat_id/0,1`, `set_current_chat/1,2`,
  `get_draft/1`, `put_draft/2` and `delete_draft/1`. An ETS single-key read or
  write is atomic per call and a `:public` table needs no process
  intermediary, so a render path pays no message round-trip and cannot be
  queued behind another viewer's compound write.

  Two consequences are accepted deliberately:

    * `put_state/2` is a read-then-write upsert (read the existing sequence,
      then insert). It is not atomic as a whole and does not need to be: one
      chat id is written by exactly ONE LiveView process (a conversation
      belongs to one browser tab), so two writers for the same id cannot
      interleave. The worst a concurrent `delete_chat/1` can do is resurrect
      the row with a fresh (newest) sequence.
    * `put_draft/2` trims over-cap drafts inline. Concurrent trims are
      harmless: each may delete a different least-recently-saved entry, which
      only prunes slightly earlier than requested.

  The table is `:public` with `read_concurrency: true`, so external observers
  may inspect it safely (individual reads are atomic) — but mutations belong
  to this API, which is where the invariants are kept.

  ## Data model

  The store is shape-agnostic about message content: per-chat state is an
  opaque `term()`; the LiveView owns the shape of transcripts/messages.

  Table entries:

    * `{{:current, {client_id, node}}, chat_id | :none}` — the current-chat
      pointer, SCOPED by browser/tab identity (`client_id`; `nil` is a valid
      unscoped identity) and BEAM node. Several viewers can share one host
      without adopting each other's conversation. A missing key (or `:none`)
      reads as `nil`.
    * `{:chat, chat_id}` → `{seq, state}` — a strictly increasing creation
      sequence (drives `list_chats/0`/`conversations/0`'s newest-first
      ordering — NOT the chat id, which is unique but not guaranteed ordered)
      and the opaque per-chat state (`nil` until the first `put_state/2`).
    * `{:draft, key}` → `{seq, state}` — edited composer state before the
      first send, scoped to its browser or workbench tab. These entries are
      excluded from the conversation index and capped at #{@max_drafts} entries, the
      least recently saved being evicted first.

  ## Scoped current pointer

  The pointer is keyed by `{client_id, node()}`, never by BEAM-global state,
  because several viewers share one host: a second viewer must not adopt the
  first viewer's conversation merely by mounting the page. The caller supplies
  its own browser/tab identity:

    * `current_chat_id/0`, `set_current_chat/1` and `new_chat/0` use
      `default_scope/0` (`{nil, node()}`), so existing callers keep working;
    * `current_chat_id/1`, `set_current_chat/2` and `new_chat/1` take a
      `client_id` and derive `{client_id, node()}`.

  The id is never validated against existing chats: pointing the pointer at an
  unknown id is harmless (`get_state/1` reads `nil`) and silently ignoring it
  would hide caller bugs.

  ## Auto-prune at creation

  Both `new_chat/0` and `new_chat/1` keep only the newest `#{@max_chats}` chats right
  after inserting, using the same newest-first rule and the same every-scope
  pointer clearing as `prune/1`. A long-lived session therefore cannot grow
  the table without bound; the explicit `prune/1` API stays available for
  callers that want their own bound.

  ## Bulk reads

  `conversations/0` answers `[%{id: chat_id, state: state}]` newest-first from
  ONE table scan, so a sidebar can render N conversations without N
  `get_state/1` calls.

  ## Totality

  Every function is total — no raising on bad input, and no raising when the
  table is absent (the app is not started, or the owning process died and
  destroyed the table): single-key reads answer `nil`/`[]` and single-key
  writes answer `:ok`. Unknown chat ids are no-ops (`delete_chat/1`) or read
  as `nil` (`get_state/1`); `prune/1` ignores non-integer/negative bounds;
  `get_state/1` returns `nil` for both an unknown chat and a chat whose state
  was never set (or explicitly stored as `nil`).
  """

  use GenServer

  @typedoc "A chat id: a positive integer from `System.unique_integer([:positive])`."
  @type chat_id :: pos_integer()

  @typedoc """
  A browser/tab identity supplied by the caller to scope its current-chat
  pointer. `nil` is a valid (unscoped) identity.
  """
  @type client_id :: term()

  @typedoc "One conversation as read by `conversations/0`."
  @type conversation :: %{id: chat_id(), state: term()}

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
  Creates a new chat, makes it current for the default scope, prunes the index
  to the newest `#{@max_chats}` chats, and returns the new id.
  """
  @spec new_chat() :: chat_id()
  def new_chat do
    new_chat(nil)
  end

  @doc """
  Creates a new chat, makes it current for `client_id`'s scope, prunes the
  index to the newest `#{@max_chats}` chats, and returns the new id.

  `client_id` is the caller's browser/tab identity (`nil` is valid and equals
  `new_chat/0`'s default scope).
  """
  @spec new_chat(client_id()) :: chat_id()
  def new_chat(client_id) do
    GenServer.call(__MODULE__, {:new_chat, scope(client_id)})
  end

  @doc """
  The scope used by the zero-arity verbs on THIS BEAM node: `{nil, node()}`.

  Exposed so a caller can tell which pointer it is reading without inventing
  its own default, and so the scope shape (`{client_id, node}`) is discoverable.
  """
  @spec default_scope() :: {client_id() | nil, node()}
  def default_scope, do: {nil, node()}

  @doc """
  Returns the default scope's current chat id, or `nil` when none is set.

  Direct ETS read — no `GenServer` round-trip.
  """
  @spec current_chat_id() :: chat_id() | nil
  def current_chat_id do
    read_current(default_scope())
  end

  @doc """
  Returns `client_id`'s current chat id, or `nil` when none is set.

  Direct ETS read — no `GenServer` round-trip. A client id that never set a
  pointer reads `nil`; it does not fall back to another client's pointer.
  """
  @spec current_chat_id(client_id()) :: chat_id() | nil
  def current_chat_id(client_id) do
    read_current(scope(client_id))
  end

  @doc """
  Makes `chat_id` the current chat for the default scope.

  Always returns `:ok`; the id is NOT validated against existing chats — a
  dangling current id is harmless (`get_state/1` reads as `nil`). Callers
  should pass ids obtained from `new_chat/0` or `list_chats/0`.
  """
  @spec set_current_chat(chat_id()) :: :ok
  def set_current_chat(chat_id) do
    write_current(default_scope(), chat_id)
  end

  @doc """
  Makes `chat_id` the current chat for `client_id`'s scope.

  Same contract as `set_current_chat/1`; the scope is `{client_id, node()}`, so
  two viewers on one host keep independent current pointers.
  """
  @spec set_current_chat(client_id(), chat_id()) :: :ok
  def set_current_chat(client_id, chat_id) do
    write_current(scope(client_id), chat_id)
  end

  @doc """
  Lists all chat ids, newest first.

  Direct ETS read (one table scan) — no `GenServer` round-trip. Use
  `conversations/0` when the states are needed too.
  """
  @spec list_chats() :: [chat_id()]
  def list_chats do
    on_table([], &newest_first/1)
  end

  @doc """
  Returns every conversation as `%{id: chat_id, state: state}`, newest first.

  ONE table scan — the sidebar's bulk read, replacing `list_chats/0` plus one
  `get_state/1` call per id.
  """
  @spec conversations() :: [conversation()]
  def conversations do
    on_table([], fn table ->
      table
      |> :ets.match_object({{:chat, :_}, :_})
      |> Enum.sort_by(fn {{:chat, _chat_id}, {seq, _state}} -> seq end, :desc)
      |> Enum.map(fn {{:chat, chat_id}, {_seq, chat_state}} ->
        %{id: chat_id, state: chat_state}
      end)
    end)
  end

  @doc """
  Deletes the chat (a no-op for unknown ids).

  Every scope's current pointer aimed at the deleted chat is cleared, so
  `current_chat_id/0` (and `current_chat_id/1` for any client) returns `nil`
  afterwards for that chat.
  """
  @spec delete_chat(chat_id()) :: :ok
  def delete_chat(chat_id) do
    GenServer.call(__MODULE__, {:delete_chat, chat_id})
  end

  @doc """
  Keeps only the newest `max_chats` chats, deleting the rest.

  Used to cap memory; it is NEVER called automatically (`new_chat/0,1` carry
  their own `#{@max_chats}`-chat cap). If a pruned chat was current for any
  scope, that pointer is cleared. Non-integer or negative bounds are ignored
  (no-op); `0` clears all chats.
  """
  @spec prune(pos_integer()) :: :ok
  def prune(max_chats) do
    GenServer.call(__MODULE__, {:prune, max_chats})
  end

  @doc """
  Upserts the opaque per-chat state.

  An unknown `chat_id` registers it as a new (newest) chat carrying this
  state; a known chat keeps its creation sequence, so upserting never reorders
  the conversation index. The store never inspects the state — its shape is
  owned by the caller (the LiveView).

  Direct ETS read-then-write, which is safe because one chat id has exactly
  one writer (the LiveView process that owns that conversation).
  """
  @spec put_state(chat_id(), term()) :: :ok
  def put_state(chat_id, chat_state) do
    on_table(:ok, fn table ->
      seq =
        case :ets.lookup(table, {:chat, chat_id}) do
          [{{:chat, ^chat_id}, {existing_seq, _existing_state}}] ->
            existing_seq

          [] ->
            # Upsert: an unknown chat id registers a new (newest) chat.
            next_seq()
        end

      :ets.insert(table, {{:chat, chat_id}, {seq, chat_state}})
      :ok
    end)
  end

  @doc """
  Returns the opaque per-chat state, or `nil` for an unknown chat.

  Direct ETS read — no `GenServer` round-trip. `nil` is also returned for a
  chat whose state was never set (or was explicitly stored as `nil`).
  """
  @spec get_state(chat_id()) :: term() | nil
  def get_state(chat_id) do
    on_table(nil, fn table ->
      case :ets.lookup(table, {:chat, chat_id}) do
        [{{:chat, ^chat_id}, {_seq, chat_state}}] -> chat_state
        [] -> nil
      end
    end)
  end

  @doc """
  Reads temporary composer state, separate from the conversation index.

  Direct ETS read — no `GenServer` round-trip.
  """
  @spec get_draft(term()) :: term() | nil
  def get_draft(key) do
    on_table(nil, fn table ->
      case :ets.lookup(table, {:draft, key}) do
        [{{:draft, ^key}, {_sequence, draft}}] -> draft
        [] -> nil
      end
    end)
  end

  @doc """
  Retains edited composer state across view navigation.

  Direct ETS write; the draft store stays capped at `#{@max_drafts}` entries,
  evicting the least recently saved (concurrent trims are harmless).
  """
  @spec put_draft(term(), term()) :: :ok
  def put_draft(key, draft) do
    on_table(:ok, fn table ->
      :ets.insert(table, {{:draft, key}, {next_seq(), draft}})

      drafts = :ets.match_object(table, {{:draft, :_}, :_})

      if length(drafts) > @max_drafts do
        {oldest, _} = Enum.min_by(drafts, fn {_key, {sequence, _}} -> sequence end)
        :ets.delete(table, oldest)
      end

      :ok
    end)
  end

  @doc """
  Discards the temporary state of a composer.

  Direct ETS delete — no `GenServer` round-trip.
  """
  @spec delete_draft(term()) :: :ok
  def delete_draft(key) do
    on_table(:ok, fn table ->
      :ets.delete(table, {:draft, key})
      :ok
    end)
  end

  @doc """
  Discards a workbench tab's temporary state across its node scopes.

  Serialized through the `GenServer` because it is a pattern delete over a
  family of composed draft keys, not a single-key operation.
  """
  @spec discard_workbench_draft(term()) :: :ok
  def discard_workbench_draft(tab_id) do
    GenServer.call(__MODULE__, {:discard_workbench_draft, tab_id})
  end

  @doc """
  Clears ALL chats, drafts and every scope's current pointer (test helper /
  hard reset).
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

    # No pointer rows are seeded: a missing `{:current, scope}` key reads as
    # `nil` (see `read_current/1`), so scopes materialize on first write only.
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:new_chat, scope}, _from, %{table: table} = state) do
    chat_id = System.unique_integer([:positive])

    # Both writes happen in ONE serialized step, so a reader never observes a
    # chat without its pointer (or vice versa).
    :ets.insert(table, [
      {{:chat, chat_id}, {next_seq(), nil}},
      {{:current, scope}, chat_id}
    ])

    # Cap the conversation index AT CREATION, so a long-lived session cannot
    # grow the table without bound and callers need not prune themselves. The
    # just-created chat is the newest, so it is always kept for ITS scope.
    prune_table(table, @max_chats)

    {:reply, chat_id, state}
  end

  @impl true
  def handle_call({:delete_chat, chat_id}, _from, %{table: table} = state) do
    :ets.delete(table, {:chat, chat_id})
    clear_pointers(table, [chat_id])
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:prune, max_chats}, _from, %{table: table} = state) do
    # Non-integer / negative bounds are ignored inside prune_table/2 (total
    # API, never raise).
    prune_table(table, max_chats)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:discard_workbench_draft, tab_id}, _from, %{table: table} = state) do
    :ets.match_delete(table, {{:draft, {:workbench, {:_, :_, :_, tab_id}}}, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, %{table: table} = state) do
    :ets.delete_all_objects(table)
    {:reply, :ok, state}
  end

  # --- Private helpers ---

  # A client's pointer scope: browser/tab identity plus the publishing node.
  defp scope(client_id), do: {client_id, node()}

  defp next_seq, do: System.unique_integer([:monotonic, :positive])

  # Runs `fun` against the public table, answering `fallback` when the table is
  # absent (the store is not started) or destroyed mid-call. This is what makes
  # the direct-ETS operations total.
  defp on_table(fallback, fun) do
    case :ets.whereis(@table) do
      :undefined -> fallback
      _table -> fun.(@table)
    end
  rescue
    ArgumentError -> fallback
  end

  defp read_current(scope) do
    on_table(nil, fn table ->
      case :ets.lookup(table, {:current, scope}) do
        [{{:current, ^scope}, :none}] -> nil
        [{{:current, ^scope}, chat_id}] -> chat_id
        [] -> nil
      end
    end)
  end

  defp write_current(scope, chat_id) do
    on_table(:ok, fn table ->
      # No existence validation (see set_current_chat/1): pointing the current
      # pointer at an unknown id is harmless, and silently ignoring it would
      # hide caller bugs.
      :ets.insert(table, {{:current, scope}, chat_id})
      :ok
    end)
  end

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

  # Keeps only the newest `max_chats` chats. Non-integer / negative bounds are
  # a no-op; `0` clears all chats.
  defp prune_table(_table, max_chats) when not (is_integer(max_chats) and max_chats >= 0),
    do: :ok

  defp prune_table(table, max_chats) do
    {_kept, dropped} = Enum.split(newest_first(table), max_chats)

    for chat_id <- dropped do
      :ets.delete(table, {:chat, chat_id})
    end

    clear_pointers(table, dropped)
  end

  # Resets EVERY scope's current pointer that aims at one of the removed chat
  # ids (any client, any node) to `:none`, so no viewer is left pointing at a
  # deleted conversation.
  defp clear_pointers(_table, []), do: :ok

  defp clear_pointers(table, dropped) do
    dropped = MapSet.new(dropped)

    table
    |> :ets.match_object({{:current, :_}, :_})
    |> Enum.each(fn
      {{:current, _scope} = key, chat_id} ->
        if MapSet.member?(dropped, chat_id) do
          :ets.insert(table, {key, :none})
        end

      _other ->
        :ok
    end)
  end
end
