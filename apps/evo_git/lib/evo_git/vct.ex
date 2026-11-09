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

    * the mount table (rules in `EvoGit.VCT.Table`), persisted as one JSON file
      in the VCT directory (`<data_dir>/vct/virtual-tree.json`) through
      `EvoGit.VCT.Persistence`;
    * the GLOBAL context file (`<data_dir>/vct/CONTEXT.md`) and its local git
      history, so a global context edit is a committed, auditable change; a
      NON-BLANK file that already exists at boot is synced then, too;
    * a ONE-TIME import of the legacy "recent projects" table (the SQLite
      `projects` rows), recorded by the `legacy_projects_imported` marker.

  ## Client reads are TOTAL

  `EvoGit.Core.ContextNode` and other callers may ask the VCT for data from any
  process, including during boot or after a crash, so every read resolves a
  missing/dead server to its documented empty value (`[]`, `nil`, `""`,
  `{:error, :not_found}`) instead of raising; mutations resolve to
  `{:error, :vct_unavailable}`.

  ## Instance seam

  `server/0` is read at CALL time from the `:evogit_vct_server` process
  dictionary key (set by `init/1` for self-calls, exactly like
  `EvoGit.TaskRegistry.server/0`), falling back to the registered singleton
  `__MODULE__`. Tests start isolated instances with a unique `:name`,
  `:data_dir` and `:path`.

  ## Broadcasts

  Every successful mount mutation publishes BOTH the node-less legacy
  `"recent_projects"` notification (`{:recent_projects_updated}`) and the
  node-aware `"vct"` notification (`{:vct_updated, node()}`).
  """

  use GenServer

  require Logger

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Persistence
  alias EvoGit.VCT.Table

  @server_key :evogit_vct_server
  @context_file "CONTEXT.md"
  @table_file "virtual-tree.json"
  @global_context_commit_message "Update global context"

  # The machine-local mount table and any atomic-write temporaries must never
  # enter the global context's git history.
  @gitignore_entries [
    "# Machine-local Virtual Context Tree state, never committed.",
    @table_file,
    "*.tmp",
    "*.tmp.*"
  ]

  @call_timeout 30_000

  @type state :: %{
          name: term(),
          data_dir: String.t(),
          vct_dir: String.t(),
          path: String.t(),
          mounts: [Mount.t()],
          legacy_projects_imported: boolean()
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
    * `:path` — the JSON mount-table file (default `<data_dir>/vct/virtual-tree.json`)
    * `:legacy_projects` — rows to import instead of reading the task store
    * `:legacy_projects_fun` — `fun/0` returning those rows (wins over
      `:legacy_projects`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns every mount in raw persisted order.
  """
  @spec mounts() :: [Mount.t()]
  def mounts, do: call(:mounts, [])

  @doc """
  Returns the mounts sorted by `last_opened_at` DESC with `nil` LAST.

  ## Options

    * `:limit` — positive integer cap on the returned list (the VCT itself
      always retains every mount)
  """
  @spec list_projects(keyword()) :: [Mount.t()]
  def list_projects(opts \\ []) when is_list(opts), do: call({:list_projects, opts}, [])

  @doc """
  Registers an OS path as a mount.

  `path` must be an absolute OS path (`{:error, :relative_path}` otherwise);
  it is normalized (trimmed, trailing separators dropped) and is NEVER required
  to exist. `name_or_opts` is a binary name, `nil`, or a keyword list with
  `:name`.

  Registering the same OS path twice is idempotent and keeps its point; a new
  path that matches the name/basename of a mount whose recorded OS path is gone
  RE-POINTS that mount (same point, new path) instead of accumulating a second
  one.

  Returns `{:ok, mount}` or `{:error, reason}` (`:relative_path`,
  `:invalid_path`, `:invalid_name`, a persistence error, or
  `:vct_unavailable`).
  """
  @spec register_project(String.t(), String.t() | nil | keyword()) ::
          {:ok, Mount.t()} | {:error, term()}
  def register_project(path, name_or_opts \\ nil),
    do: call({:register_project, path, name_or_opts}, {:error, :vct_unavailable})

  @doc """
  Removes a mount by VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`) or
  by OS path (any other binary).

  Returns `:ok`, `{:error, :not_found}` (callers may map it to `:ok`),
  `{:error, :invalid_point}` for an unparseable point, or `{:error, reason}`.
  """
  @spec remove_project(String.t() | VctPath.t()) ::
          :ok | {:error, :not_found} | {:error, term()}
  def remove_project(point_or_path),
    do: call({:remove_project, point_or_path}, {:error, :vct_unavailable})

  @doc """
  Resolves a VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`) — or an
  exact OS path — to its mount.
  """
  @spec resolve(String.t() | VctPath.t()) ::
          {:ok, Mount.t()} | {:error, :not_found} | {:error, term()}
  def resolve(point_or_path),
    do: call({:resolve, point_or_path}, {:error, :not_found})

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
  directory as a git repository, keeps the machine-local mount table out of
  history via a `.gitignore`, and commits the context files. A blank content
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
    path = Keyword.get(opts, :path) || Path.join(vct_dir, @table_file)

    # The VCT directory only — never a mount point.
    File.mkdir_p!(vct_dir)

    loaded = Persistence.load(path)
    {mounts, imported?} = boot_import(loaded, path, opts)

    state = %{
      name: name,
      data_dir: data_dir,
      vct_dir: vct_dir,
      path: path,
      mounts: mounts,
      legacy_projects_imported: imported?
    }

    # A global context restored from a state backup is already on disk but its
    # lazy git repository may not be: sync it now instead of waiting for the
    # first `put_global_context/1`. Best effort — a git failure never fails boot.
    sync_boot_global_context(vct_dir)

    {:ok, state}
  end

  @impl true
  def handle_call(:mounts, _from, state), do: {:reply, state.mounts, state}

  def handle_call({:list_projects, opts}, _from, state) do
    mounts =
      state.mounts
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  def handle_call({:register_project, path, name_or_opts}, _from, state) do
    with {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(name_or_opts) do
      {:ok, mounts, mount} = Table.register(state.mounts, os_path, name, DateTime.utc_now())

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

  def handle_call({:remove_project, key}, _from, state) do
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
        safe_broadcast("vct", {:vct_updated, node()})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_global_context, _content}, _from, state),
    do: {:reply, {:error, :invalid_content}, state}

  ## Boot: one-time legacy import

  defp boot_import(%{legacy_projects_imported: true} = loaded, _path, _opts),
    do: {loaded.mounts, true}

  defp boot_import(%{mounts: mounts}, path, opts) do
    result = Table.import_legacy(mounts, legacy_rows(opts))

    Enum.each(result.skipped, fn skipped ->
      Logger.warning("VCT: skipping legacy project with a non-absolute path: #{inspect(skipped)}")
    end)

    case Persistence.save(path, result.mounts, true) do
      :ok ->
        log_import(result)
        {result.mounts, true}

      {:error, reason} ->
        # Keep the imported mounts in memory but leave the marker false so the
        # NEXT boot retries; the import is idempotent per OS path.
        Logger.warning("VCT: could not persist the legacy project import: #{inspect(reason)}")
        {result.mounts, false}
    end
  end

  defp log_import(%{imported: imported}) when imported != [] do
    Logger.info("VCT: imported #{length(imported)} legacy recent project(s)")
  end

  defp log_import(_result), do: :ok

  defp legacy_rows(opts) do
    fun = Keyword.get(opts, :legacy_projects_fun)

    cond do
      is_function(fun, 0) -> normalize_rows(fun.())
      is_list(Keyword.get(opts, :legacy_projects)) -> Keyword.get(opts, :legacy_projects)
      true -> normalize_rows(default_legacy_rows())
    end
  end

  defp normalize_rows(rows) when is_list(rows), do: rows
  defp normalize_rows(_rows), do: []

  defp default_legacy_rows do
    EvoGit.Store.safe_select_all_projects(EvoGit.Store)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  ## Persistence + broadcasts

  defp persist(state, mounts),
    do: Persistence.save(state.path, mounts, state.legacy_projects_imported)

  defp broadcast_mount_change do
    safe_broadcast("recent_projects", {:recent_projects_updated})
    safe_broadcast("vct", {:vct_updated, node()})
  end

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

  defp extract_name(name) when is_binary(name), do: {:ok, Table.normalize_name(name)}
  defp extract_name(nil), do: {:ok, nil}

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
