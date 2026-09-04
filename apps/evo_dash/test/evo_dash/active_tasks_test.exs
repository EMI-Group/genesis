defmodule EvoDash.ActiveTasksTest do
  use ExUnit.Case, async: false

  alias EvoDash.ActiveTasks

  # The hub is a boot-created named public ETS table (:evo_dash_active_tasks,
  # created idempotently at the top of EvoDash.Application.start/2 and owned by
  # the long-lived application process). The module has NO process — tests must
  # not reference a process/start_link. Reset the shared global hub state in
  # setup so tests are independent.
  setup do
    ActiveTasks.reset()
    :ok
  end

  describe "initial state" do
    test "get/2 on any context returns :empty before any write" do
      assert ActiveTasks.get(nil, node()) == :empty
      assert ActiveTasks.get("some-target", :node@remote) == :empty
    end
  end

  describe "put/4 + get/2 round-trip" do
    test "stores and returns exactly what was put for the local context" do
      ActiveTasks.put(nil, node(), [:a, :b], [])
      assert ActiveTasks.get(nil, node()) == {:ok, {[:a, :b], []}}

      ActiveTasks.put(nil, node(), [], [:c])
      assert ActiveTasks.get(nil, node()) == {:ok, {[], [:c]}}
    end

    test "a later put for the same context overwrites the earlier snapshot" do
      ActiveTasks.put(nil, node(), [:a], [:b])
      ActiveTasks.put(nil, node(), [:a, :c], [])
      assert ActiveTasks.get(nil, node()) == {:ok, {[:a, :c], []}}
    end
  end

  describe "per-context isolation" do
    test "a local snapshot does not leak into a remote context (and vice versa)" do
      ActiveTasks.put(nil, node(), [:local], [])
      assert ActiveTasks.get(nil, node()) == {:ok, {[:local], []}}
      assert ActiveTasks.get("some-target", :node@remote) == :empty

      ActiveTasks.put("some-target", :node@remote, [], [:remote])
      assert ActiveTasks.get("some-target", :node@remote) == {:ok, {[], [:remote]}}
      assert ActiveTasks.get(nil, node()) == {:ok, {[:local], []}}
    end

    test "two different remote contexts are isolated from each other" do
      ActiveTasks.put("some-target", :node@remote, [:r1], [])
      ActiveTasks.put("other-target", :node@remote2, [:r2], [])

      assert ActiveTasks.get("some-target", :node@remote) == {:ok, {[:r1], []}}
      assert ActiveTasks.get("other-target", :node@remote2) == {:ok, {[:r2], []}}
    end

    test "the same remote node atom under a different node_id is a distinct context" do
      ActiveTasks.put("some-target", :node@remote, [:a], [])
      assert ActiveTasks.get("other-target", :node@remote) == :empty
    end
  end

  describe "invalidate/2" do
    test "deletes one context's snapshot so get/2 returns :empty for it" do
      ActiveTasks.put(nil, node(), [:running], [:pending])
      assert ActiveTasks.get(nil, node()) == {:ok, {[:running], [:pending]}}

      assert ActiveTasks.invalidate(nil, node()) == :ok
      assert ActiveTasks.get(nil, node()) == :empty
    end

    test "leaves other contexts' snapshots untouched" do
      ActiveTasks.put(nil, node(), [:local], [])
      ActiveTasks.put("some-target", :node@remote, [:r1], [:r2])

      assert ActiveTasks.invalidate("some-target", :node@remote) == :ok

      assert ActiveTasks.get("some-target", :node@remote) == :empty
      assert ActiveTasks.get(nil, node()) == {:ok, {[:local], []}}
    end

    test "is a harmless no-op on a never-written context" do
      assert ActiveTasks.invalidate("never-written", :node@remote) == :ok
      assert ActiveTasks.get("never-written", :node@remote) == :empty
    end
  end

  describe "reset/0" do
    test "clears every previously-written context" do
      ActiveTasks.put(nil, node(), [:local], [])
      ActiveTasks.put("some-target", :node@remote, [:r1], [:r2])
      ActiveTasks.put("other-target", :node@remote2, [], [:r3])

      ActiveTasks.reset()

      assert ActiveTasks.get(nil, node()) == :empty
      assert ActiveTasks.get("some-target", :node@remote) == :empty
      assert ActiveTasks.get("other-target", :node@remote2) == :empty
    end

    test "is idempotent on an already-empty hub" do
      ActiveTasks.reset()
      assert ActiveTasks.get(nil, node()) == :empty
    end
  end

  describe "empty snapshot semantics" do
    test "storing empty lists {[], []} is a valid snapshot, not :empty" do
      # Remote-pending contexts legitimately store empty lists — the hub must
      # distinguish "never written" (:empty) from "written, nothing running".
      ActiveTasks.put("some-target", :node@remote, [], [])
      assert ActiveTasks.get("some-target", :node@remote) == {:ok, {[], []}}

      ActiveTasks.put(nil, node(), [], [])
      assert ActiveTasks.get(nil, node()) == {:ok, {[], []}}
    end
  end
end
