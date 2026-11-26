defmodule EvoGit.VCT.Mounts do
  @moduledoc """
  Internal mount-TABLE helpers for `EvoGit.VCT`.

  This module is an internal helper of `EvoGit.VCT` and owns every operation
  that works on the in-memory MOUNT LIST plus the store: boot loading, the
  `:system_mounts` merge, OS-path and name validation, listing/search/limit,
  point and path resolution, removal and the whole-table persist.
  The pure LIST rules stay in `EvoGit.VCT.Table` — nothing here re-implements
  them — and the mount value object stays in `EvoGit.VCT.Mount`.

  `persist/2` replaces the WHOLE table atomically
  (`EvoGit.Store.save_vct_mounts/2`) and `commit/3` is the ONE mutation funnel:
  it persists, then replaces the cached list, then broadcasts exactly one
  `{:vct_updated, node()}` on `"vct"`.
  A failed persist answers `{:error, :store_unavailable}` (or the store's own
  reason) and leaves both memory and the database untouched.
  """

  require Logger

  alias EvoGit.VCT.Call
  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Table
  alias EvoGit.VCT.Workspaces
  alias EvoGit.VCT.Path, as: VctPath

  @default_max_projects 100

  @doc false
  @spec max_projects() :: pos_integer()
  def max_projects do
    case Application.get_env(:evo_git, :vct_max_projects) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_projects
    end
  end

  ## Boot: load the mount table from the task store

  @doc false
  @spec load_mounts(term()) :: [Mount.t()]
  def load_mounts(store) do
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

  # Total: a store that is absent, down or holding an undecodable row never
  # crashes boot.
  @doc false
  @spec store_mounts(term()) :: [map()]
  def store_mounts(store) do
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

  ## Boot: host-declared system mounts

  @doc false
  @spec merge_system_mounts([Mount.t()], term()) :: {[Mount.t()], boolean()}
  def merge_system_mounts(mounts, entries) when is_list(entries) do
    # Folds the `:system_mounts` entries through `Table.ensure_mount/4` IN ORDER,
    # so booting over an already-correct table changes nothing (no write, no
    # broadcast). A malformed entry is skipped with a warning: boot never fails
    # on host-provided metadata.
    Enum.reduce(entries, {mounts, false}, fn entry, {acc, changed?} ->
      case system_mount(entry) do
        {:ok, point, path, name} ->
          fold_system_mount(acc, changed?, entry, point, path, name)

        :error ->
          warn_skipped_system_mount(entry, :invalid_entry)
          {acc, changed?}
      end
    end)
  end

  def merge_system_mounts(mounts, _entries), do: {mounts, false}

  defp fold_system_mount(acc, changed?, entry, point, path, name) do
    case project_path_owner(acc, point, path) do
      nil ->
        case Table.ensure_mount(acc, point, path, name) do
          {:ok, ensured, _mount, entry_changed?} ->
            {ensured, changed? or entry_changed?}

          {:error, reason} ->
            warn_skipped_system_mount(entry, reason)
            {acc, changed?}
        end

      %Mount{point: owner} ->
        # A system mount must never take over an OS path a user registered as a
        # PROJECT: `ensure_mount/4`'s MOVE rule would carry that row onto the
        # reserved point and `projects/1` would silently stop listing the
        # project. The project row stays untouched and the entry's own point
        # keeps whatever it holds today (possibly nothing) — expected host
        # state, so this is informational, never a warning.
        Logger.info(
          "VCT: not taking over the OS path #{path} for system mount #{point}: " <>
            "it belongs to the project mount #{owner}"
        )

        {acc, changed?}
    end
  end

  # A path owned by a PROJECT mount at a DIFFERENT point is that user's mount,
  # not a system mount's to take. A reserved→reserved move stays allowed (a
  # system mount may be re-pointed between reserved points), and the entry's OWN
  # point is always folded through `ensure_mount/4` (an idempotent no-op).
  defp project_path_owner(mounts, point, path) do
    case Table.find_by_os_path(mounts, Table.normalize_os_path(path)) do
      %Mount{point: ^point} -> nil
      %Mount{point: owner} = mount -> if Table.reserved?(owner), do: nil, else: mount
      nil -> nil
    end
  end

  defp warn_skipped_system_mount(entry, reason) do
    Logger.warning("VCT: skipping a malformed system mount: #{inspect({entry, reason})}")
  end

  defp system_mount(entry) when is_list(entry) or is_map(entry) do
    with point when is_binary(point) <- fetch_entry(entry, :point),
         {:ok, canonical} <- VctPath.canonical(point),
         path when is_binary(path) <- fetch_entry(entry, :path),
         {:ok, name} <- system_mount_name(fetch_entry(entry, :name)) do
      {:ok, canonical, path, name}
    else
      _reason -> :error
    end
  end

  defp system_mount(_entry), do: :error

  defp system_mount_name(nil), do: {:ok, nil}
  defp system_mount_name(name) when is_binary(name), do: {:ok, Table.normalize_name(name)}
  defp system_mount_name(_name), do: :error

  defp fetch_entry(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp fetch_entry(entry, key) when is_list(entry), do: Keyword.get(entry, key)

  ## Mutations

  @doc false
  @spec handle_mount(map(), term(), keyword()) :: {:reply, term(), map()}
  def handle_mount(state, path, opts) do
    with {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(opts) do
      {:ok, registered, mount} = Table.register(state.mounts, os_path, name, DateTime.utc_now())
      mounts = Table.enforce_cap(registered, max_projects())

      commit(state, mounts, {:ok, mount})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  @spec handle_ensure_mount(map(), term(), term(), keyword()) :: {:reply, term(), map()}
  def handle_ensure_mount(state, point, path, opts) do
    with {:ok, canonical} <- VctPath.canonical(point),
         {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(opts),
         {:ok, ensured, mount, changed?} <-
           Table.ensure_mount(state.mounts, canonical, os_path, name) do
      mounts = Table.enforce_cap(ensured, max_projects())

      if changed? do
        commit(state, mounts, {:ok, mount})
      else
        # Nothing to write: no persist, no broadcast, no timestamp churn.
        {:reply, {:ok, mount}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  @spec handle_forget(map(), term()) :: {:reply, term(), map()}
  def handle_forget(state, key) do
    case remove_from(state.mounts, key) do
      {:ok, mounts, _removed} -> commit(state, mounts, :ok)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The ONE mutation funnel: persist the WHOLE table, then replace the cache,
  # then broadcast ONCE. `ok_reply` is what the caller gets on success.
  @doc false
  @spec commit(map(), [Mount.t()], term()) :: {:reply, term(), map()}
  def commit(state, mounts, ok_reply) do
    case persist(state.store, mounts) do
      :ok ->
        broadcast_mount_change(state.pubsub)
        {:reply, ok_reply, %{state | mounts: mounts}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The WHOLE table is replaced atomically by the store, so the in-memory list
  # and the database can never disagree; a failed write leaves both untouched.
  @doc false
  @spec persist(term(), [Mount.t()]) :: :ok | {:error, term()}
  def persist(store, mounts) do
    EvoGit.Store.save_vct_mounts(store, Enum.map(mounts, &Mount.to_map/1))
  rescue
    exception ->
      Logger.warning("VCT: could not persist the mount table: #{Exception.message(exception)}")
      {:error, :store_unavailable}
  catch
    :exit, reason ->
      Logger.warning("VCT: could not persist the mount table: #{inspect(reason)}")
      {:error, :store_unavailable}
  end

  # ONE broadcast per successful mutation: the node-aware `"vct"` notification,
  # published on the instance's own PubSub (`:pubsub` init opt).
  @doc false
  @spec broadcast_mount_change(term()) :: :ok
  def broadcast_mount_change(pubsub),
    do: Call.broadcast(pubsub, "vct", {:vct_updated, node()})

  ## Reads

  @doc false
  @spec list([Mount.t()], keyword()) :: [Mount.t()]
  def list(mounts, opts) do
    mounts
    |> listed_mounts(opts)
    |> Table.sort_by_recency()
    |> apply_limit(Keyword.get(opts, :limit))
  end

  @doc false
  @spec search([Mount.t()], term(), keyword()) :: [Mount.t()]
  def search(mounts, query, opts) do
    mounts
    |> listed_mounts(opts)
    |> matching_mounts(query)
    |> Table.sort_by_recency()
    |> apply_limit(Keyword.get(opts, :limit))
  end

  @doc false
  @spec apply_limit([Mount.t()], term()) :: [Mount.t()]
  def apply_limit(mounts, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(mounts, limit)

  def apply_limit(mounts, _limit), do: mounts

  # Project mounts only, or project + workspace mounts when the caller opts in.
  defp listed_mounts(mounts, opts) do
    if include_workspaces?(opts),
      do: Table.project_mounts(mounts) ++ Table.workspace_mounts(mounts),
      else: Table.project_mounts(mounts)
  end

  defp include_workspaces?(opts), do: Keyword.get(opts, :include_workspaces, false) == true

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

  ## Point / path resolution

  @doc false
  @spec resolve([Mount.t()], term()) ::
          {:ok, Mount.t()} | {:error, :not_found | :invalid_point}
  def resolve(mounts, %VctPath{} = point), do: resolve_point(mounts, VctPath.format(point))

  def resolve(mounts, key) when is_binary(key) do
    if point_string?(key) do
      case VctPath.parse(key) do
        {:ok, point} -> resolve_point(mounts, VctPath.format(point))
        {:error, _reason} -> {:error, :invalid_point}
      end
    else
      case Table.find_by_os_path(mounts, key) do
        nil -> {:error, :not_found}
        mount -> {:ok, mount}
      end
    end
  end

  def resolve(_mounts, _other), do: {:error, :not_found}

  defp resolve_point(mounts, point) do
    case Table.find_by_point(mounts, point) do
      nil -> {:error, :not_found}
      mount -> {:ok, mount}
    end
  end

  @doc false
  @spec mount_for_path([Mount.t()], term()) :: Mount.t() | nil
  def mount_for_path(mounts, os_path), do: Table.mount_for_path(mounts, os_path)

  # The ONE VCT-path derivation pass: the containing mount is resolved for
  # `repo_root` ONCE and every relative path is then mapped through the pure
  # `Table.vct_path_for/2`.
  @doc false
  @spec vct_paths([Mount.t()], term(), [String.t()]) :: [String.t() | nil]
  def vct_paths(mounts, repo_root, relative_paths) do
    mount = Table.mount_for_path(mounts, repo_root)
    Enum.map(relative_paths, fn relative_path -> Table.vct_path_for(mount, relative_path) end)
  end

  ## Removal

  # A RESERVED (system) mount can never be forgotten — neither by its point
  # (whether or not a row exists) nor by its OS path.
  @doc false
  @spec remove_from([Mount.t()], term()) :: {:ok, [Mount.t()], Mount.t()} | {:error, term()}
  def remove_from(mounts, %VctPath{} = point),
    do: refuse_reserved_or_remove_by_point(mounts, VctPath.format(point))

  def remove_from(mounts, key) when is_binary(key) do
    if point_string?(key) do
      case VctPath.parse(key) do
        {:ok, point} -> refuse_reserved_or_remove_by_point(mounts, VctPath.format(point))
        {:error, _reason} -> {:error, :invalid_point}
      end
    else
      # An OS path first (a workspace owns none), then a BARE WORKSPACE NAME.
      case refuse_reserved_or_remove_by_path(mounts, key) do
        {:error, :not_found} -> Workspaces.forget_by_name(mounts, key)
        other -> other
      end
    end
  end

  def remove_from(_mounts, _key), do: {:error, :not_found}

  defp refuse_reserved_or_remove_by_point(mounts, point) do
    if Table.reserved?(point),
      do: {:error, :reserved_point},
      else: Table.remove_by_point(mounts, point)
  end

  defp refuse_reserved_or_remove_by_path(mounts, os_path) do
    case Table.find_by_os_path(mounts, os_path) do
      nil ->
        {:error, :not_found}

      mount ->
        if Table.reserved?(mount.point),
          do: {:error, :reserved_point},
          else: Table.remove_by_path(mounts, os_path)
    end
  end

  ## Input handling

  @doc false
  @spec point_string?(term()) :: boolean()
  def point_string?(value) when is_binary(value), do: String.starts_with?(value, "vct:")
  def point_string?(_value), do: false

  @doc false
  @spec validate_os_path(term()) ::
          {:ok, String.t()} | {:error, :invalid_path | :relative_path}
  def validate_os_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> {:error, :invalid_path}
      not EvoGit.Platform.absolute_path?(trimmed) -> {:error, :relative_path}
      true -> {:ok, trimmed}
    end
  end

  def validate_os_path(_path), do: {:error, :invalid_path}

  @doc false
  @spec extract_name(term()) :: {:ok, String.t() | nil} | {:error, {:invalid_name, term()}}
  def extract_name(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:ok, nil}
      name when is_binary(name) -> {:ok, Table.normalize_name(name)}
      other -> {:error, {:invalid_name, other}}
    end
  end

  def extract_name(other), do: {:error, {:invalid_name, other}}
end
