defmodule EvoGit.TaskRegistry.RuntimeOptsTest do
  @moduledoc """
  Tests for `EvoGit.TaskRegistry.RuntimeOpts` — the pure runtime-opts builder
  used by `TaskExecutor` when executing genesis, evolve, or skill-extraction
  tasks.

  These functions are pure builders (the only side effect is
  `Application.ensure_all_started(:evo_git)` inside `build_common_runtime_opts/3`,
  which is safe in test env), so no DB/Store setup is needed.
  """

  use ExUnit.Case, async: true

  alias EvoGit.TaskRegistry.RuntimeOpts

  describe "build_common_runtime_opts/3" do
    test "returns {nil, runtime_opts} with minimal opts for an evolve task" do
      {first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts([path: "/tmp/repo"], "task-1", :evolve)

      assert first == nil
      assert Keyword.get(runtime_opts, :repo_path) == "/tmp/repo"
      assert Keyword.get(runtime_opts, :mode) == :simple
      assert Keyword.get(runtime_opts, :task_id) == "task-1"

      # Optional keys are absent.
      refute Keyword.has_key?(runtime_opts, :node_path)
      refute Keyword.has_key?(runtime_opts, :starting_commit)
      refute Keyword.has_key?(runtime_opts, :foreign_repos)
      refute Keyword.has_key?(runtime_opts, :archive)
      refute Keyword.has_key?(runtime_opts, :model_id)
      refute Keyword.has_key?(runtime_opts, :build_system)
      refute Keyword.has_key?(runtime_opts, :agent)
      refute Keyword.has_key?(runtime_opts, :model_id_locked)
    end

    test "returns {nil, runtime_opts} with minimal opts for a genesis task" do
      # Genesis tasks require an explicit mode ("new" or "existing"); the
      # default "simple" is invalid for genesis.
      {first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", mode: "new"],
          "task-2",
          :genesis
        )

      assert first == nil
      assert Keyword.get(runtime_opts, :repo_path) == "/tmp/repo"
      assert Keyword.get(runtime_opts, :mode) == :new
      assert Keyword.get(runtime_opts, :task_id) == "task-2"
    end

    test "includes all optional keys when present" do
      opts = [
        path: "/tmp/repo",
        mode: "new",
        node_path: "/tmp/repo/lib",
        starting_commit: "abc123",
        foreign_repos: [id1: "/tmp/foreign1"],
        archive: [:some_archive],
        model_id: "gpt-4o",
        build_system: :mix
      ]

      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(opts, "task-3", :genesis)

      assert Keyword.get(runtime_opts, :node_path) == "/tmp/repo/lib"
      assert Keyword.get(runtime_opts, :starting_commit) == "abc123"
      assert Keyword.get(runtime_opts, :foreign_repos) == [id1: "/tmp/foreign1"]
      assert Keyword.get(runtime_opts, :archive) == [:some_archive]
      assert Keyword.get(runtime_opts, :model_id) == "gpt-4o"
      assert Keyword.get(runtime_opts, :build_system) == :mix
    end

    test "includes :model_id when it is a non-empty string" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", model_id: "claude-sonnet"],
          "task-4",
          :evolve
        )

      assert Keyword.get(runtime_opts, :model_id) == "claude-sonnet"
    end

    test "omits :model_id when it is an empty string" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", model_id: ""],
          "task-5",
          :evolve
        )

      refute Keyword.has_key?(runtime_opts, :model_id)
    end

    test "omits :model_id when it is nil" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", model_id: nil],
          "task-6",
          :evolve
        )

      refute Keyword.has_key?(runtime_opts, :model_id)
    end

    test "threads :agent when it is a non-empty string" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", agent: "code_reviewer"],
          "task-6a",
          :evolve
        )

      assert Keyword.get(runtime_opts, :agent) == "code_reviewer"
    end

    test "omits :agent when it is an empty string" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", agent: ""],
          "task-6b",
          :evolve
        )

      refute Keyword.has_key?(runtime_opts, :agent)
    end

    test "omits :agent when it is absent" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts([path: "/tmp/repo"], "task-6c", :evolve)

      refute Keyword.has_key?(runtime_opts, :agent)
    end

    test "threads :model_id_locked as true when it is truthy" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", model_id_locked: true],
          "task-6d",
          :evolve
        )

      assert Keyword.get(runtime_opts, :model_id_locked) == true
    end

    test "omits :model_id_locked when it is absent" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts([path: "/tmp/repo"], "task-6e", :evolve)

      refute Keyword.has_key?(runtime_opts, :model_id_locked)
    end

    test "omits :model_id_locked when it is false" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", model_id_locked: false],
          "task-6f",
          :evolve
        )

      refute Keyword.has_key?(runtime_opts, :model_id_locked)
    end

    test "genesis mode \"new\" maps to :new" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", mode: "new"],
          "task-7",
          :genesis
        )

      assert Keyword.get(runtime_opts, :mode) == :new
    end

    test "genesis mode \"existing\" maps to :existing" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", mode: "existing"],
          "task-8",
          :genesis
        )

      assert Keyword.get(runtime_opts, :mode) == :existing
    end

    test "evolve mode \"simple\" maps to :simple" do
      {_first, runtime_opts} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/repo", mode: "simple"],
          "task-9",
          :evolve
        )

      assert Keyword.get(runtime_opts, :mode) == :simple
    end

    test "first tuple element is always nil" do
      {first, _runtime_opts} =
        RuntimeOpts.build_common_runtime_opts([path: "/tmp/repo"], "task-10", :evolve)

      assert first == nil
    end

    test "crashes when :path is missing" do
      assert_raise KeyError, fn ->
        RuntimeOpts.build_common_runtime_opts([], "task-11", :evolve)
      end
    end
  end

  describe "evolution_mode_atom/1" do
    test "converts \"simple\" to :simple" do
      assert RuntimeOpts.evolution_mode_atom("simple") == :simple
    end

    test "raises ArgumentError for invalid string values" do
      assert_raise ArgumentError, fn -> RuntimeOpts.evolution_mode_atom("fast") end
    end

    test "raises ArgumentError for non-string values" do
      assert_raise ArgumentError, fn -> RuntimeOpts.evolution_mode_atom(:simple) end
      assert_raise ArgumentError, fn -> RuntimeOpts.evolution_mode_atom(123) end
      assert_raise ArgumentError, fn -> RuntimeOpts.evolution_mode_atom(nil) end
    end
  end

  describe "genesis_mode_atom/1" do
    test "converts \"new\" to :new" do
      assert RuntimeOpts.genesis_mode_atom("new") == :new
    end

    test "converts \"existing\" to :existing" do
      assert RuntimeOpts.genesis_mode_atom("existing") == :existing
    end

    test "raises ArgumentError for invalid string values" do
      assert_raise ArgumentError, fn -> RuntimeOpts.genesis_mode_atom("fast") end
    end

    test "raises ArgumentError for non-string values" do
      assert_raise ArgumentError, fn -> RuntimeOpts.genesis_mode_atom(:new) end
      assert_raise ArgumentError, fn -> RuntimeOpts.genesis_mode_atom(123) end
      assert_raise ArgumentError, fn -> RuntimeOpts.genesis_mode_atom(nil) end
    end
  end

  describe "mode_atom/2" do
    test "dispatches genesis + \"new\" to :new" do
      assert RuntimeOpts.mode_atom(:genesis, "new") == :new
    end

    test "dispatches genesis + \"existing\" to :existing" do
      assert RuntimeOpts.mode_atom(:genesis, "existing") == :existing
    end

    test "dispatches evolve + \"simple\" to :simple" do
      assert RuntimeOpts.mode_atom(:evolve, "simple") == :simple
    end

    test "propagates ArgumentError for invalid genesis modes" do
      assert_raise ArgumentError, fn -> RuntimeOpts.mode_atom(:genesis, "fast") end
    end

    test "propagates ArgumentError for invalid evolve modes" do
      assert_raise ArgumentError, fn -> RuntimeOpts.mode_atom(:evolve, "fast") end
    end
  end
end
