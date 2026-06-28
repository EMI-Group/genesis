defmodule EvoDash.TaskStore do
  @moduledoc """
  CubDB-backed persistent store for EvoDash tasks and recent projects.

  A single CubDB instance (started under supervision before `EvoDash.TaskRegistry`)
  holds both data sets under namespaced keys:

    * `{:task, task_id}`  → `%EvoDash.TaskRegistry.TaskInfo{}`
    * `{:project, path}`  → `%{path:, name:, last_opened_at:}`

  CubDB is started with `auto_file_sync: true` for durable writes.

  This module also provides crash-safe read/recovery helpers that survive corrupt
  (un-deserializable) entries in the underlying CubDB btree.
  """

  require Logger

  @doc """
  Child spec for the supervisor.

  CubDB does not provide its own `child_spec/1`, so this wrapper defines one.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts the CubDB store.

  ## Options

    * `:data_dir` — (required) filesystem path for the CubDB data directory.
    * `:name` — (optional) registration name, defaults to `__MODULE__`.
  """
  def start_link(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    name = Keyword.get(opts, :name, __MODULE__)

    File.mkdir_p!(data_dir)

    CubDB.start_link(data_dir: data_dir, name: name, auto_file_sync: true)
  end

  @doc """
  Safely reads a key, returning nil on error (including corrupt values).

  `CubDB.get/2` deserializes the stored value via `:erlang.binary_to_term/1`.
  If the value bytes are corrupt, the call raises. This helper rescues any error
  and returns `nil` instead so callers never crash.
  """
  def safe_get(store \\ __MODULE__, key) do
    try do
      CubDB.get(store, key)
    rescue
      _ -> nil
    end
  end

  @doc """
  Enumerates all entries, collecting partial results even if some values
  are corrupt. Returns a list of {key, value} tuples.

  CubDB's `select/2` loads each leaf's value nodes eagerly during reduction.
  A single corrupt value raises mid-reduction, losing the entire accumulated
  list. To salvage partial results, we use an `Agent` as a side-effect
  accumulator fed by `Stream.each/2`. When the stream raises, the Agent still
  retains all entries from leaves read *before* the corrupt leaf.
  """
  def safe_select_all(store \\ __MODULE__) do
    try_collect_partial(store, [])
  end

  @doc """
  Returns the store size without deserializing any values.

  CubDB stores the entry count in the btree struct metadata, so `CubDB.size/1`
  works even when individual values are corrupt.
  """
  def safe_size(store \\ __MODULE__) do
    try do
      CubDB.size(store)
    rescue
      _ -> 0
    end
  end

  @doc """
  Checks store integrity and repairs corruption. If unreadable entries are
  detected, salvages all readable entries, clears the store, and rewrites
  salvaged data — healing the database without losing intact data.

  Returns `:ok` if no corruption, or `{:repaired, lost_count}` if entries
  were quarantined.
  """
  def integrity_check(store \\ __MODULE__) do
    declared_size = safe_size(store)
    salvaged = safe_select_all(store)
    salvaged_count = length(salvaged)

    if salvaged_count < declared_size do
      lost = declared_size - salvaged_count

      Logger.warning(
        "CubDB integrity check: #{lost} of #{declared_size} entries are " <>
          "corrupt/unreadable. Salvaging #{salvaged_count} valid entries and rebuilding store."
      )

      try do
        CubDB.clear(store)
        CubDB.put_multi(store, salvaged)
        {:repaired, lost}
      rescue
        error ->
          Logger.error("CubDB rebuild failed during integrity check: #{inspect(error)}")
          {:error, error}
      end
    else
      :ok
    end
  end

  # The key recovery function. Reads entries via `CubDB.select/2` while
  # accumulating them into an Agent side-effect. On corruption-induced
  # exceptions, returns whatever was salvaged before the failure.
  defp try_collect_partial(store, opts) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    try do
      CubDB.select(store, opts)
      |> Stream.each(fn entry ->
        Agent.update(agent, fn acc -> [entry | acc] end)
      end)
      |> Enum.to_list()

      # Full success
      Agent.get(agent, fn acc -> Enum.reverse(acc) end)
    rescue
      error ->
        partial = Agent.get(agent, fn acc -> Enum.reverse(acc) end)

        Logger.warning(
          "CubDB select (opts: #{inspect(opts)}) failed after #{length(partial)} " <>
            "readable entries; salvaged partial results. Error: #{Exception.message(error)}"
        )

        partial
    after
      Agent.stop(agent)
    end
  end
end
