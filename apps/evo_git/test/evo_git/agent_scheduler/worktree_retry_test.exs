defmodule EvoGit.AgentScheduler.WorktreeRetryTest do
  @moduledoc """
  Unit tests for `EvoGit.AgentScheduler.WorktreeRetry` — the shared retry
  helpers for the worktree lifecycle (WorktreeManager, Worktrees).

  The module is pure (no GenServer/ETS state) → `async: true`. Hermetic:
  every retry-capable call passes `delays: [0, 0, 0]` (4 attempts) or
  `delays: []` (1 attempt) so no test ever sleeps. Attempt counts are pinned
  with an Erlang `:counters` counter bumped inside the wrapped fun.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.WorktreeRetry

  @moduletag :tmp_dir

  @retryable_reasons [:eacces, :eperm, :eexist, :enotempty, :ebusy, :again, :eintr]
  @non_retryable_reasons [:enoent, :enospc, :eisdir, :erofs, :enotdir]

  # --- attempt-counting helpers ---

  defp new_counter, do: :counters.new(1, [:atomics])
  defp bump(counter), do: :counters.add(counter, 1, 1)
  defp count(counter), do: :counters.get(counter, 1)

  # ==========================================================================
  # retry_on_transient/2
  # ==========================================================================
  describe "retry_on_transient/2" do
    test "retries a transient 3-tuple failure then succeeds (4 attempts)", %{tmp_dir: tmp_dir} do
      counter = new_counter()
      path = Path.join(tmp_dir, "locked")

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) < 4, do: {:error, :eacces, path}, else: :ok
          end,
          delays: [0, 0, 0]
        )

      assert result == :ok
      assert count(counter) == 4
    end

    test "retries a transient 2-tuple failure (mkdir_p shape) then succeeds" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) < 3, do: {:error, :ebusy}, else: :ok
          end,
          delays: [0, 0, 0]
        )

      assert result == :ok
      assert count(counter) == 3
    end

    test "stops at the first success result without extra attempts" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) == 1, do: {:error, :eacces, "/x"}, else: {:ok, :done}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:ok, :done}
      assert count(counter) == 2
    end

    test "retry exhaustion returns the final error tuple without raising (4 attempts)" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            {:error, :eacces, "/locked"}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:error, :eacces, "/locked"}
      assert count(counter) == 4
    end

    test "non-transient reasons fail fast with exactly 1 attempt" do
      for reason <- [:enospc, :eisdir, :erofs] do
        counter = new_counter()

        result =
          WorktreeRetry.retry_on_transient(
            fn ->
              bump(counter)
              {:error, reason, "/x"}
            end,
            delays: [0, 0, 0]
          )

        assert result == {:error, reason, "/x"}
        assert count(counter) == 1, "reason #{inspect(reason)} was retried"
      end
    end

    test ":enoent is NOT retried — goal already met, 1 attempt" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            {:error, :enoent, "/gone"}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:error, :enoent, "/gone"}
      assert count(counter) == 1
    end

    test "retries git error tuples {:error, {tag, output}} then succeeds (3 attempts)" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) < 3, do: {:error, {:fatal, "could not lock config file"}}, else: :ok
          end,
          delays: [0, 0, 0]
        )

      assert result == :ok
      assert count(counter) == 3
    end

    test "retries git tuples with a non-binary output" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) < 2, do: {:error, {:fatal, :other}}, else: {:ok, "done"}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:ok, "done"}
      assert count(counter) == 2
    end

    test "repo-gone git tuples fail fast with 1 attempt" do
      for output <- [
            "fatal: not a git repository (or any of the parent directories): .git",
            "Repository path does not exist: /tmp/gone"
          ] do
        counter = new_counter()

        result =
          WorktreeRetry.retry_on_transient(
            fn ->
              bump(counter)
              {:error, {:fatal, output}}
            end,
            delays: [0, 0, 0]
          )

        assert result == {:error, {:fatal, output}}
        assert count(counter) == 1, "output #{inspect(output)} was retried"
      end
    end

    test ":enoent git tag fails fast regardless of output (1 attempt)" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            {:error, {:enoent, "some random output"}}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:error, {:enoent, "some random output"}}
      assert count(counter) == 1
    end

    test "retries binary error tuples {:error, output} then succeeds (2 attempts)" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            if count(counter) < 2, do: {:error, "transient lock contention"}, else: :ok
          end,
          delays: [0, 0, 0]
        )

      assert result == :ok
      assert count(counter) == 2
    end

    test "empty binary error output fails fast with 1 attempt" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            {:error, ""}
          end,
          delays: [0, 0, 0]
        )

      assert result == {:error, ""}
      assert count(counter) == 1
    end

    test "delays: [] runs exactly one attempt (no retries)" do
      counter = new_counter()

      result =
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            {:error, :eacces, "/x"}
          end,
          delays: []
        )

      assert result == {:error, :eacces, "/x"}
      assert count(counter) == 1
    end

    test "exceptions from the wrapped fun propagate immediately (1 attempt)" do
      counter = new_counter()

      assert_raise RuntimeError, "boom", fn ->
        WorktreeRetry.retry_on_transient(
          fn ->
            bump(counter)
            raise "boom"
          end,
          delays: [0, 0, 0]
        )
      end

      assert count(counter) == 1
    end
  end

  # ==========================================================================
  # rm_rf_retry/2
  # ==========================================================================
  describe "rm_rf_retry/2" do
    test "normalizes a nonexistent path to {:ok, []}", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ghost")
      refute File.exists?(path)

      assert WorktreeRetry.rm_rf_retry(path, delays: [0, 0, 0]) == {:ok, []}
      refute File.exists?(path)
    end

    test "removes a real temp directory tree", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "tree")
      File.mkdir_p!(Path.join(path, "sub"))
      File.write!(Path.join(path, "file.txt"), "x")
      assert File.dir?(path)

      assert {:ok, files} = WorktreeRetry.rm_rf_retry(path, delays: [0, 0, 0])
      assert path in files
      refute File.exists?(path)
    end
  end

  # ==========================================================================
  # mkdir_p_retry/2
  # ==========================================================================
  describe "mkdir_p_retry/2" do
    test "creates nested directories", %{tmp_dir: tmp_dir} do
      nested = Path.join([tmp_dir, "a", "b", "c"])

      assert WorktreeRetry.mkdir_p_retry(nested, delays: [0, 0, 0]) == :ok
      assert File.dir?(nested)
    end

    test "is idempotent when the directory already exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "exists")
      File.mkdir_p!(path)

      assert WorktreeRetry.mkdir_p_retry(path, delays: [0, 0, 0]) == :ok
      assert File.dir?(path)
    end

    test "fails fast with {:error, :enotdir} when a file is the parent", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "afile")
      File.write!(file, "x")

      assert {:error, :enotdir} =
               WorktreeRetry.mkdir_p_retry(Path.join(file, "child"), delays: [0, 0, 0])
    end
  end

  # ==========================================================================
  # retryable_reason?/1
  # ==========================================================================
  describe "retryable_reason?/1" do
    test "pins the exact transient set" do
      for reason <- @retryable_reasons do
        assert WorktreeRetry.retryable_reason?(reason), "#{inspect(reason)} should be retryable"
      end

      for reason <- @non_retryable_reasons do
        refute WorktreeRetry.retryable_reason?(reason),
               "#{inspect(reason)} should NOT be retryable"
      end
    end
  end

  # ==========================================================================
  # repo_gone_output?/1
  # ==========================================================================
  describe "repo_gone_output?/1" do
    test "detects repo-gone messages" do
      assert WorktreeRetry.repo_gone_output?(
               "fatal: not a git repository (or any of the parent directories): .git"
             )

      assert WorktreeRetry.repo_gone_output?("Repository path does not exist: /tmp/gone")
    end

    test "refutes non-repo-gone outputs" do
      refute WorktreeRetry.repo_gone_output?("could not lock config file")
      refute WorktreeRetry.repo_gone_output?("")
    end
  end
end
