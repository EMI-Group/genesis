defmodule EvoGit.AgentScheduler.WorktreeManager do
  @moduledoc """
  Dedicated GenServer for worktree filesystem operations.

  The AgentScheduler GenServer delegates all blocking worktree I/O to this
  process so that filesystem operations (rm_rf, prune_worktrees, delete_branch,
  mkdir_p) do not block the scheduler's message loop.

  Initialization and teardown use `GenServer.call` (the caller needs to know
  when the operation is complete). Deletion uses `GenServer.cast` (fire and
  forget — the worktree directory and branch will be cleaned up eventually).

  The GenServer is registered as `EvoGit.AgentScheduler.WorktreeManager` and
  holds no meaningful state — all operations are independent and self-contained.
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git

  # --- Client API ---

  @doc """
  Starts the WorktreeManager GenServer.
  Registers under the module name so callers can use the module as the server name.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initializes worktrees for the given repo root (synchronous).

  Performs:
  - `File.rm_rf` on the workers directory (non-bang, logs warnings on error)
  - `Git.prune_worktrees`
  - Clean orphaned `evogit-agent-*` branches
  - `File.mkdir_p!` on the workers directory

  Returns `:ok`. Idempotent — safe to call multiple times for the same repo.
  """
  @spec init_worktrees(String.t()) :: :ok
  def init_worktrees(repo_root) when is_binary(repo_root) do
    GenServer.call(__MODULE__, {:init_worktrees, repo_root})
  end

  @doc """
  Deletes a worktree directory and its associated git branch (asynchronous).

  Derives the branch name from the directory basename by replacing the
  `worker_` prefix with `evogit-agent-` and underscores with hyphens
  (e.g., `worker_T1_A42` → `evogit-agent-T1-A42`).

  Fires and forgets — returns `:ok` immediately.
  """
  @spec delete_worktree(String.t(), String.t()) :: :ok
  def delete_worktree(path, repo_root) when is_binary(path) and is_binary(repo_root) do
    GenServer.cast(__MODULE__, {:delete_worktree, path, repo_root})
  end

  @doc """
  Tears down all worktrees for the given repo root (synchronous).

  Performs:
  - `File.rm_rf` on the workers directory (non-bang, logs warnings on error)
  - `Git.prune_worktrees`

  Returns `:ok`.
  """
  @spec teardown_worktrees(String.t()) :: :ok
  def teardown_worktrees(repo_root) when is_binary(repo_root) do
    GenServer.call(__MODULE__, {:teardown_worktrees, repo_root})
  end

  @doc """
  Returns the path to the workers directory for a given repo root.
  """
  @spec workers_dir(String.t()) :: String.t()
  def workers_dir(repo_root), do: Path.join(repo_root, ".genesis/workers")

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:init_worktrees, repo_root}, _from, state) do
    worker_base = workers_dir(repo_root)

    Logger.info("WorktreeManager: Initializing worktree directory at #{worker_base}")

    # Use non-bang variant — when the scheduler crashes and restarts while
    # agents from the previous instance are still running, the workers
    # directory may be in use and rm_rf can fail with :eexist (or other
    # errors). Log a warning and continue — mkdir_p on the next line is a
    # no-op since the directory already exists.
    case File.rm_rf(worker_base) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "WorktreeManager: Could not remove worker directory #{worker_base}: " <>
            "#{inspect(reason)} at #{path} — continuing with existing directory"
        )
    end

    Git.prune_worktrees(repo_root)

    # Clean up orphaned evogit-agent branches from previous runs
    clean_orphaned_branches(repo_root)

    File.mkdir_p!(worker_base)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:delete_worktree, path, repo_root}, state) do
    Logger.info("WorktreeManager: Deleting worktree #{path}")

    # Derive branch name from directory name
    # (e.g., worker_T1_A42 → evogit-agent-T1-A42)
    branch_name =
      path
      |> Path.basename()
      |> then(
        &Regex.replace(~r/^worker_(.+)$/, &1, fn _, rest ->
          "evogit-agent-" <> String.replace(rest, "_", "-")
        end)
      )

    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, failed_path} ->
        Logger.warning(
          "WorktreeManager: Failed to remove worktree #{path}: " <>
            "#{inspect(reason)} at #{failed_path}"
        )
    end

    Git.prune_worktrees(repo_root)
    Git.delete_branch(repo_root, branch_name)

    {:noreply, state}
  end

  @impl true
  def handle_call({:teardown_worktrees, repo_root}, _from, state) do
    worker_base = workers_dir(repo_root)

    case File.rm_rf(worker_base) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "WorktreeManager: Could not remove worker directory during teardown: " <>
            "#{inspect(reason)} at #{path}"
        )
    end

    Git.prune_worktrees(repo_root)

    {:reply, :ok, state}
  end

  # --- Private Helpers ---

  @doc """
  Cleans up orphaned `evogit-agent-*` branches from previous runs.

  Matches all branches with the `evogit-agent-` prefix and deletes each one.
  Called during initialization to prevent stale branches from accumulating.
  """
  defp clean_orphaned_branches(repo_root) do
    Git.list_branches(repo_root, "evogit-agent-*")
    |> Enum.each(fn branch ->
      Logger.info("WorktreeManager: Cleaning up orphaned branch #{branch}")
      Git.delete_branch(repo_root, branch)
    end)

    :ok
  end
end
