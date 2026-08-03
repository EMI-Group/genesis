defmodule EvoDash.AshTreesTest do
  use ExUnit.Case, async: false

  alias EvoDash.AshTrees

  setup do
    # Point the store at a temp file via app env — no global XDG/APPDATA
    # redirection, so concurrently running tests are unaffected.
    store =
      Path.join(
        System.tmp_dir!(),
        "ash_trees_#{System.unique_integer([:positive])}.etf"
      )

    Application.put_env(:evo_dash, :ash_trees_path, store)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :ash_trees_path)
      File.rm(store)
    end)

    {:ok, store: store}
  end

  test "list/0 is empty when no store file exists" do
    assert AshTrees.list() == []
  end

  test "dismiss/1 removes only the matching ash tree", %{store: store} do
    entries = [
      %{task_id: "t1", task_number: 1, label: "任务一", size: 3, agents: []},
      %{task_id: "t2", task_number: 2, label: "任务二", size: 5, agents: []}
    ]

    File.write!(store, :erlang.term_to_binary(entries))

    assert length(AshTrees.list()) == 2

    assert :ok = AshTrees.dismiss("t1")
    assert [%{task_id: "t2"}] = AshTrees.list()
  end

  test "a corrupt store file reads as an empty list", %{store: store} do
    File.write!(store, "not-etf")

    assert AshTrees.list() == []
  end
end
