defmodule EvoDash.TaskStore do
  @moduledoc """
  CubDB-backed persistent store for EvoDash tasks and recent projects.

  A single CubDB instance (started under supervision before `EvoDash.TaskRegistry`)
  holds both data sets under namespaced keys:

    * `{:task, task_id}`  → `%EvoDash.TaskRegistry.TaskInfo{}`
    * `{:project, path}`  → `%{path:, name:, last_opened_at:}`

  CubDB is started with `auto_file_sync: true` for durable writes.
  """

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
end
