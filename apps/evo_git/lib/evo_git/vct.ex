defmodule EvoGit.VCT do
  @moduledoc """
  The Virtual Context Tree (VCT) mount store.

  The VCT is a **pure in-memory namespace** layered over the local filesystem:
  a mount binds a canonical VCT point (`vct:///projects/foo`, see
  `EvoGit.VCT.Path`) to an absolute OS path (see `EvoGit.VCT.Mount`). It is NOT
  a filesystem — this module never creates a directory for a point, never
  requires a mount's OS path to exist, and never creates a symlink, bind mount,
  junction or FUSE mount. No on-disk layout changes on the agent side.

  This GenServer owns:

    * the mount table (rules in `EvoGit.VCT.Table`), persisted in the SQLite
      task store's `vct_mounts` table (`EvoGit.Store.list_vct_mounts/1` /
      `EvoGit.Store.save_vct_mounts/2`). The in-memory list is a READ CACHE of
      that table; every mutation writes the WHOLE table back before the state
      changes;
    * the GLOBAL context file (`<data_dir>/vct/CONTEXT.md`) and its local git
      history, so a global context edit is a committed, auditable change; a
      NON-BLANK file that already exists at boot is synced then, too.

  ## Capacity

  `max_projects/0` (100 by default, overridable through the app env
  `:vct_max_projects`) caps the mount table. Registering a path beyond the cap
  EVICTS the oldest mounts, so the table never grows unbounded while staying
  newest-first.

  ## Client reads are TOTAL

  `EvoGit.Core.ContextNode` and other callers may ask the VCT for data from any
  process, including during boot or after a crash, so every read resolves a
  missing/dead server to its documented empty value (`[]`, `nil`, `""`,
  `{:error, :not_found}`) instead of raising; mutations resolve to
  `{:error, :vct_unavailable}`. A store that is down or unavailable never
  crashes the init or a caller: the mount list loads as `[]` and a mutation
  returns an error.

  ## Instance seam

  `server/0` is read at CALL time from the `:evogit_vct_server` process
  dictionary key (set by `init/1` for self-calls, exactly like
  `EvoGit.TaskRegistry.server/0`), falling back to the registered singleton
  `__MODULE__`. Tests start isolated instances with a unique `:name`,
  `:data_dir` and `:store`.

  ## Broadcasts

  Every successful mount mutation publishes `{:vct_updated, node()}` on
  `"vct"` — exactly one broadcast per mutation.
  """

  use GenServer

  require Logger

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table

  @server_key :evogit_vct_server
  @context_file "CONTEXT.md"
  @global_context_commit_message "Update global context"

  # Any atomic-write temporaries must never enter the global context's git
  # history. The mount table itself is task-store state, not a file here.
  @gitignore_entries [
    "# Temporary files, never committed.",
    "*.tmp",
    "*.tmp.*"
  ]

  @call_timeout 30_000
  @default_max_projects 100

  @type state :: %{
          name: term(),
          data_dir: String.t(),
          vct_dir: String.t(),
          store: term(),
          mounts: [Mount.t()]
        }

  ## Client API

  @doc """
  Resolves the VCT server name for the CURRENT process.

  Reads the `:evogit_vct_server` process dictionary key at CALL time (an
  isolated instance started with a custom `:name`), falling back to the
  registered singleton `__MODULE__`.
  """
  @spec server() :: term()
  def server, do: Process.get(@server_key) || __MODULE__

  @doc """
  Starts the mount store.

  ## Options

    * `:name` — registered name (default `__MODULE__`)
    * `:data_dir` — data directory holding the `vct/` folder (default
      `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`)
    * `:store` — the task store owning the `vct_mounts` table (default
      `EvoGit.Store`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the maximum number of mounts the table may hold.

  `100` by default, overridable through the app env `:vct_max_projects` (a
  non-positive or non-integer value falls back to the default).
  """
  @spec max_projects() :: pos_integer()
  def max_projects do
    case Application.get_env(:evo_git, :vct_max_projects) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_projects
    end
  end

  @doc """
  Mounts an absolute OS path, returning the created or refreshed mount.

  `path` must be an absolute OS path (`{:error, :relative_path}` otherwise) and
  is normalized (trimmed, trailing separators dropped). It is NEVER required to
  exist on disk, and no directory is created.

  ## Options

    * `:name` — display name (a blank or absent name keeps the derived basename)

  Registering an already-mounted OS path is idempotent: it refreshes
  `last_opened_at` (and a non-blank `:name`) and KEEPS its point. A new path
  that matches the name and point basename of a mount whose recorded OS path is
  gone RE-POINTS that mount (same point, new path) instead of accumulating a
  second one — the portability rule for a mount table carried across machines.

  Returns `{:ok, mount}` or `{:error, reason}` (`:relative_path`,
  `:invalid_path`, `{:invalid_name, term}`, a store error, or
  `:vct_unavailable`).
  """
  @spec mount(String.t(), keyword()) :: {:ok, Mount.t()} | {:error, term()}
  def mount(path, opts \\ []) when is_list(opts),
    do: call({:mount, path, opts}, {:error, :vct_unavailable})

  @doc """
  Returns every mount, newest first (`last_opened_at` descending, `nil` LAST).

  ## Options

    * `:limit` — positive integer cap on the returned list (the table itself
      keeps up to `max_projects/0` entries)
  """
  @spec projects(keyword()) :: [Mount.t()]
  def projects(opts \\ []) when is_list(opts), do: call({:projects, opts}, [])

  @doc """
  Returns the mounts matching `query`, newest first.

  The match is a CASE-INSENSITIVE SUBSTRING search over the display name, the
  OS path and the VCT point — the autocomplete interface. A blank query matches
  every mount; a non-binary query matches none.

  ## Options

    * `:limit` — positive integer cap on the returned list
  """
  @spec search(term(), keyword()) :: [Mount.t()]
  def search(query, opts \\ []) when is_list(opts), do: call({:search, query, opts}, [])

  @doc """
  Forgets a mount by VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`) or
  by OS path (any other binary).

  Returns `:ok`, `{:error, :not_found}`, `{:error, :invalid_point}` for an
  unparseable point, or another `{:error, reason}`.
  """
  @spec forget(String.t() | VctPath.t()) :: :ok | {:error, term()}
  def forget(key), do: call({:forget, key}, {:error, :vct_unavailable})

  @doc """
  Resolves a VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`) — or an
  exact OS path — to its mount.
  """
  @spec resolve(String.t() | VctPath.t()) ::
          {:ok, Mount.t()} | {:error, :not_found} | {:error, term()}
  def resolve(point_or_path), do: call({:resolve, point_or_path}, {:error, :not_found})

  @doc """
  Returns the mount containing `os_path` (longest OS-path prefix, path-boundary
  aware), or `nil`.
  """
  @spec mount_for_path(String.t()) :: Mount.t() | nil
  def mount_for_path(os_path), do: call({:mount_for_path, os_path}, nil)

  @doc """
  Returns the canonical VCT URL for `relative_path` inside `repo_root`'s mount,
  or `nil` when no mount contains `repo_root` (or the relative path is invalid).
  """
  @spec vct_path_for(String.t(), String.t()) :: String.t() | nil
  def vct_path_for(repo_root, relative_path),
    do: call({:vct_path_for, repo_root, relative_path}, nil)

  @doc """
  Returns the global context file path (`<vct_dir>/CONTEXT.md`).

  Total: with no reachable server it returns the default path computed from the
  configured data directory.
  """
  @spec global_context_path() :: String.t()
  def global_context_path, do: call(:global_context_path, default_global_context_path())

  @doc """
  Returns the global context contents (`""` when absent or unreadable).
  """
  @spec global_context() :: String.t()
  def global_context do
    case global_context_path() do
      path when is_binary(path) -> read_file(path)
      _other -> ""
    end
  end

  @doc """
  Writes the global context verbatim.

  After a successful write with NON-BLANK content it lazily initializes the VCT
  directory as a git repository and commits the context files. A blank content
  never initializes a repository. Git failures are logged and never lose the
  written file.

  Broadcasts `{:vct_updated, node()}` on `"vct"` after a successful write.
  """
  @spec put_global_context(term()) :: :ok | {:error, term()}
  def put_global_context(content),
    do: call({:put_global_context, content}, {:error, :vct_unavailable})

  ## Server callbacks

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Process.put(@server_key, name)

    data_dir =
      Keyword.get(opts, :data_dir) ||
        Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())

    vct_dir = Path.join(data_dir, "vct")

    # The VCT directory only — never a mount point.
    File.mkdir_p!(vct_dir)

    store = Keyword.get(opts, :store, EvoGit.Store)

    state = %{
      name: name,
      data_dir: data_dir,
      vct_dir: vct_dir,
      store: store,
      mounts: load_mounts(store)
    }

    # A global context restored from a state backup is already on disk but its
    # lazy git repository may not be: sync it now instead of waiting for the
    # first `put_global_context/1`. Best effort — a git failure never fails boot.
    sync_boot_global_context(vct_dir)

    {:ok, state}
  end

  @impl true
  def handle_call({:mount, path, opts}, _from, state) do
    with {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(opts) do
      {:ok, registered, mount} = Table.register(state.mounts, os_path, name, DateTime.utc_now())
      mounts = Table.enforce_cap(registered, max_projects())

      case persist(state, mounts) do
        :ok ->
          broadcast_mount_change()
          {:reply, {:ok, mount}, %{state | mounts: mounts}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:projects, opts}, _from, state) do
    mounts =
      state.mounts
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  def handle_call({:search, query, opts}, _from, state) do
    mounts =
      state.mounts
      |> matching_mounts(query)
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  def handle_call({:forget, key}, _from, state) do
    case remove_from(state.mounts, key) do
      {:ok, mounts, _removed} ->
        case persist(state, mounts) do
          :ok ->
            broadcast_mount_change()
            {:reply, :ok, %{state | mounts: mounts}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, %VctPath{} = point}, _from, state) do
    {:reply, resolve_point(state.mounts, VctPath.format(point)), state}
  end

  def handle_call({:resolve, key}, _from, state) when is_binary(key) do
    reply =
      if point_string?(key) do
        case VctPath.parse(key) do
          {:ok, point} -> resolve_point(state.mounts, VctPath.format(point))
          {:error, _reason} -> {:error, :invalid_point}
        end
      else
        case Table.find_by_os_path(state.mounts, key) do
          nil -> {:error, :not_found}
          mount -> {:ok, mount}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:resolve, _other}, _from, state),
    do: {:reply, {:error, :not_found}, state}

  def handle_call({:mount_for_path, os_path}, _from, state),
    do: {:reply, Table.mount_for_path(state.mounts, os_path), state}

  def handle_call({:vct_path_for, repo_root, relative_path}, _from, state) do
    reply =
      case Table.mount_for_path(state.mounts, repo_root) do
        nil -> nil
        mount -> Table.vct_path_for(mount, relative_path)
      end

    {:reply, reply, state}
  end

  def handle_call(:global_context_path, _from, state),
    do: {:reply, Path.join(state.vct_dir, @context_file), state}

  def handle_call({:put_global_context, content}, _from, state) when is_binary(content) do
    case write_global_context(state, content) do
      :ok ->
        broadcast_mount_change()
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_global_context, _content}, _from, state),
    do: {:reply, {:error, :invalid_content}, state}

  ## Boot: load the mount table from the task store

  # Total: a store that is absent, down or holding an undecodable row never
  # crashes boot. Invalid rows are dropped with a warning.
  defp load_mounts(store) do
    store
    |> store_mounts()
    |> Enum.flat_map(fn map ->
      case Mount.from_map(map) do
        {:ok, mount} ->
          [mount]

        {:error, reason} ->
          Logger.warning("VCT: dropping an invalid mount row: #{inspect({map, reason})}")
          []
      end
    end)
  end

  defp store_mounts(store) do
    EvoGit.Store.list_vct_mounts(store)
  rescue
    exception ->
      Logger.warning("VCT: could not load the mount table: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("VCT: could not load the mount table: #{inspect(reason)}")
      []
  end

  ## Persistence + broadcasts

  # The WHOLE table is replaced atomically by the store, so the in-memory list
  # and the database can never disagree; a failed write leaves both untouched.
  defp persist(state, mounts) do
    EvoGit.Store.save_vct_mounts(state.store, Enum.map(mounts, &Mount.to_map/1))
  rescue
    exception ->
      Logger.warning("VCT: could not persist the mount table: #{Exception.message(exception)}")
      {:error, :store_unavailable}
  catch
    :exit, reason ->
      Logger.warning("VCT: could not persist the mount table: #{inspect(reason)}")
      {:error, :store_unavailable}
  end

  # ONE broadcast per successful mutation: the node-aware `"vct"` notification.
  defp broadcast_mount_change, do: safe_broadcast("vct", {:vct_updated, node()})

  defp safe_broadcast(topic, message) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, topic, message)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  ## Input handling

  defp validate_os_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> {:error, :invalid_path}
      not EvoGit.Platform.absolute_path?(trimmed) -> {:error, :relative_path}
      true -> {:ok, trimmed}
    end
  end

  defp validate_os_path(_path), do: {:error, :invalid_path}

  defp extract_name(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:ok, nil}
      name when is_binary(name) -> {:ok, Table.normalize_name(name)}
      other -> {:error, {:invalid_name, other}}
    end
  end

  defp extract_name(other), do: {:error, {:invalid_name, other}}

  defp apply_limit(mounts, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(mounts, limit)

  defp apply_limit(mounts, _limit), do: mounts

  # Case-insensitive substring match over name, OS path and VCT point.
  defp matching_mounts(mounts, query) when is_binary(query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      mounts
    else
      Enum.filter(mounts, fn mount ->
        Enum.any?([mount.name, mount.path, mount.point], &contains?(&1, needle))
      end)
    end
  end

  defp matching_mounts(_mounts, _query), do: []

  defp contains?(value, needle) when is_binary(value),
    do: String.contains?(String.downcase(value), needle)

  defp contains?(_value, _needle), do: false

  defp remove_from(mounts, %VctPath{} = point),
    do: Table.remove_by_point(mounts, VctPath.format(point))

  defp remove_from(mounts, key) when is_binary(key) do
    if point_string?(key) do
      case VctPath.parse(key) do
        {:ok, point} -> Table.remove_by_point(mounts, VctPath.format(point))
        {:error, _reason} -> {:error, :invalid_point}
      end
    else
      Table.remove_by_path(mounts, key)
    end
  end

  defp remove_from(_mounts, _key), do: {:error, :not_found}

  defp resolve_point(mounts, point) do
    case Table.find_by_point(mounts, point) do
      nil -> {:error, :not_found}
      mount -> {:ok, mount}
    end
  end

  defp point_string?(value), do: String.starts_with?(value, "vct:")

  ## Global context

  # Boot-time counterpart of the lazy sync in `write_global_context/2`: when a
  # NON-BLANK global context file already exists (e.g. restored from a state
  # backup), commit it into its local git history now. An absent or blank file
  # initializes NOTHING (no empty repository), and the sync stays idempotent —
  # a clean tree stages no change, so HEAD is never moved. Every failure is
  # logged, never raised: git trouble must never crash boot.
  defp sync_boot_global_context(vct_dir) do
    context_path = Path.join(vct_dir, @context_file)

    if File.exists?(context_path) and not blank?(read_file(context_path)) do
      sync_context_repository(vct_dir)
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "VCT: boot-time global context git sync failed: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("VCT: boot-time global context git sync failed: #{inspect({kind, reason})}")
      :ok
  end

  defp write_global_context(state, content) do
    context_path = Path.join(state.vct_dir, @context_file)

    with :ok <- File.mkdir_p(state.vct_dir),
         :ok <- File.write(context_path, content, [:binary]) do
      unless blank?(content), do: sync_context_repository(state.vct_dir)
      :ok
    end
  end

  # Best effort: a git failure is logged and must NEVER lose the written file.
  defp sync_context_repository(vct_dir) do
    with :ok <- ensure_git_repository(vct_dir),
         :ok <- ensure_gitignore(vct_dir),
         :ok <- stage_context(vct_dir),
         {:ok, status} <- context_status(vct_dir) do
      maybe_commit_context(vct_dir, status)
    else
      {:error, reason} ->
        Logger.warning("VCT: global context git sync skipped: #{inspect(reason)}")
    end

    :ok
  end

  defp ensure_git_repository(vct_dir) do
    if File.exists?(Path.join(vct_dir, ".git")) do
      :ok
    else
      case EvoGit.Adapters.Git.init(vct_dir) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, {:git_init, reason}}
      end
    end
  end

  defp ensure_gitignore(vct_dir) do
    path = Path.join(vct_dir, ".gitignore")

    if File.exists?(path) do
      :ok
    else
      case File.write(path, Enum.join(@gitignore_entries, "\n") <> "\n") do
        :ok -> :ok
        {:error, reason} -> {:error, {:gitignore, reason}}
      end
    end
  end

  defp stage_context(vct_dir) do
    case EvoGit.Adapters.Git.add(vct_dir, ".") do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_add, reason}}
    end
  end

  defp context_status(vct_dir) do
    case EvoGit.Adapters.Git.status(vct_dir) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, {:git_status, reason}}
    end
  end

  # `{:ok, ""}` after staging means the working tree is clean: nothing to
  # commit, so HEAD is left untouched.
  defp maybe_commit_context(_vct_dir, ""), do: :ok

  defp maybe_commit_context(vct_dir, _status) do
    case EvoGit.Adapters.Git.commit(vct_dir, @global_context_commit_message) do
      {:ok, _output} -> :ok
      {:error, reason} -> Logger.warning("VCT: global context commit failed: #{inspect(reason)}")
    end
  end

  defp blank?(content), do: String.trim(content) == ""

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  defp default_global_context_path do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    Path.join([data_dir, "vct", @context_file])
  end

  ## Total client calls

  # Every client function routes through here so a missing/dead server (a read
  # from `EvoGit.Core.ContextNode`, a boot race, a crash) resolves to the
  # caller's documented empty value instead of an exit.
  defp call(request, default) do
    GenServer.call(server(), request, @call_timeout)
  catch
    :exit, _reason -> default
  end
end
