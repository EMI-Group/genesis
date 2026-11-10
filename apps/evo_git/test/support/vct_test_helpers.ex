defmodule EvoGit.VCTTest.Helpers do
  @moduledoc """
  Shared stack fixture for the VCT suites.

  Every case starts its OWN, fully isolated stack — a uniquely-named
  `EvoGit.Store` on a per-test SQLite file (a byte copy of the schema-complete
  `EvoGit.TestSupport.StoreTemplate`) plus an `EvoGit.VCT` bound to that store
  through `:store` — and points the CALLING test process at the VCT through the
  `:evogit_vct_server` process-dictionary seam. The app-global singletons are
  never touched, so the mount-table suites may run concurrently.
  """

  alias EvoGit.TestSupport.StoreTemplate

  @doc """
  Boots an isolated store + VCT pair under this test's `tmp_dir`.

  Returns `%{store:, vct:, pid:, data_dir:, vct_dir:}`.
  """
  def start_stack(tmp_dir, opts \\ []) do
    unique = System.unique_integer([:positive])
    root = Path.join(tmp_dir, "stack-#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")
    # A byte copy of the schema-complete template: the seven migrations' DDL is
    # paid once per BEAM, not once per test.
    StoreTemplate.new!().(sqlite_path)

    store_name = :"evogit_vct_test_store_#{unique}"
    vct_name = :"evogit_vct_test_vct_#{unique}"
    data_dir = Keyword.get(opts, :data_dir, Path.join(root, "data"))

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec(
        {EvoGit.Store, data_dir: sqlite_path, name: store_name},
        id: store_name
      )
    )

    pid =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {EvoGit.VCT,
           Keyword.merge(
             [name: vct_name, data_dir: data_dir, store: store_name],
             Keyword.drop(opts, [:data_dir])
           )},
          id: vct_name
        )
      )

    Process.put(:evogit_vct_server, vct_name)

    %{
      name: vct_name,
      pid: pid,
      store: store_name,
      data_dir: data_dir,
      vct_dir: Path.join(data_dir, "vct")
    }
  end

  @doc "Creates the directory and returns it."
  def dir!(path) do
    File.mkdir_p!(path)
    path
  end

  @doc "Truncates a mount timestamp to the store's millisecond wire precision."
  def ms(nil), do: nil
  def ms(%DateTime{} = datetime), do: DateTime.truncate(datetime, :millisecond)

  @doc "Returns the mount points of a mount list, in order."
  def points(mounts), do: Enum.map(mounts, & &1.point)
end
