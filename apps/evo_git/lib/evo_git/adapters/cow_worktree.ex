defmodule EvoGit.Adapters.CowWorktree do
  @moduledoc """
  CoW (copy-on-write) optimized worktree creation.

  Instead of extracting every file from the git database, this module copies
  unchanged files from a source working tree using `cp` (leveraging filesystem
  reflink/clonefile when available). Only the files that actually differ between
  the source and target commits are left for git to restore via a checkout.

  The module is designed as an **optimization with graceful fallback**: any
  failure disables the feature (via `:persistent_term`) and returns
  `{:fallback, reason}` so the caller can fall back to the standard worktree
  creation method.
  """

  require Logger

  alias EvoGit.Adapters.Git, as: Git

  @flag_key :evogit_cow_worktree_enabled

  @batch_size 1000

  # ---------------------------------------------------------------------------
  # Persistent-term runtime flag
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current CoW worktree flag state.

  Possible values: `:not_set`, `:enabled`, `:disabled`.
  `:persistent_term.get/2` never raises — returns the default if unset.
  """
  def flag, do: :persistent_term.get(@flag_key, :not_set)

  @doc "Enables CoW worktree creation by setting the persistent-term flag."
  def enable, do: :persistent_term.put(@flag_key, :enabled)

  @doc "Disables CoW worktree creation by setting the persistent-term flag."
  def disable, do: :persistent_term.put(@flag_key, :disabled)

  # ---------------------------------------------------------------------------
  # Feature gate
  # ---------------------------------------------------------------------------

  @doc """
  Determines whether CoW worktree creation should be used for the next worktree.

  Reads the `[:git, :cow_worktree_creation]` config setting (`:auto`, `:enabled`,
  or `:disabled`). In `:auto` mode, the feature is auto-detected once (requires
  a non-Windows platform with `cp` available) and cached via the persistent-term
  flag.
  """
  def enabled? do
    case EvoGit.Config.resolve([:git, :cow_worktree_creation]) do
      :disabled ->
        false

      :enabled ->
        flag() != :disabled

      :auto ->
        case flag() do
          :enabled -> true
          :disabled -> false
          :not_set ->
            can_cow? = not EvoGit.Platform.windows?() and System.find_executable("cp") != nil
            if can_cow?, do: enable(), else: disable()
            can_cow?
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Main entry point
  # ---------------------------------------------------------------------------

  @doc """
  Creates a git worktree using CoW-optimized file population.

  Copy unchanged files from `source_path` (the source working tree) into the new
  worktree at `worktree_path`, then let git restore only the differing files.

  ## Parameters
    * `repo_root`     — the git repository root (main working tree)
    * `worktree_path` — destination directory for the new worktree
    * `target_commit` — the commit to base the worktree on
    * `branch_name`   — the branch name for the new worktree
    * `source_path`   — the source working tree to copy unchanged files from

  ## Returns
    * `:ok`               — worktree created successfully
    * `{:fallback, reason}` — creation failed; caller should use the standard method
  """
  def create_worktree(repo_root, worktree_path, target_commit, branch_name, source_path) do
    with {:source_head, {:ok, source_sha}} <-
           {:source_head, Git.rev_parse(source_path)},
         {:dirty, {:ok, porcelain}} <-
           {:dirty, Git.status(source_path)},
         {:changed, {:ok, changed_files}} <-
           {:changed, Git.diff_name_only(repo_root, source_sha, target_commit)},
         {:target, {:ok, target_files}} <-
           {:target, Git.ls_tree_names(repo_root, target_commit)} do
      dirty_files = parse_dirty_files(porcelain)
      changed_set = MapSet.new(changed_files)
      dirty_set = dirty_files
      target_set = MapSet.new(target_files)

      # Shared files = in target tree, but NOT changed between commits AND NOT dirty in source
      shared_files =
        target_set
        |> MapSet.difference(changed_set)
        |> MapSet.difference(dirty_set)

      shared_list = MapSet.to_list(shared_files)

      # Step 6: create empty worktree with no checkout
      case create_empty_worktree(repo_root, worktree_path, target_commit, branch_name) do
        :ok ->
          # Step 7 + 8: copy shared files then checkout remaining
          case populate_worktree(repo_root, worktree_path, source_path, target_commit, shared_list) do
            :ok ->
              Logger.info(
                "[CowWorktree] Created worktree with #{length(shared_list)} CoW-copied shared file(s)"
              )

              :ok

            {:fallback, reason} = fallback ->
              cleanup_partial_worktree(repo_root, worktree_path, branch_name)
              disable()
              Logger.warning("[CowWorktree] Falling back: #{inspect(reason)}")
              fallback
          end

        {:fallback, reason} = fallback ->
          disable()
          Logger.warning("[CowWorktree] Falling back: #{inspect(reason)}")
          fallback
      end
    else
      {:source_head, _} ->
        disable()
        Logger.warning("[CowWorktree] Falling back: :no_source_head")
        {:fallback, :no_source_head}

      {:dirty, error} ->
        disable()
        Logger.warning("[CowWorktree] Falling back: failed to read source status (#{inspect(error)})")
        {:fallback, :no_source_status}

      {:changed, error} ->
        disable()
        Logger.warning("[CowWorktree] Falling back: failed to compute diff (#{inspect(error)})")
        {:fallback, :no_changed_files}

      {:target, error} ->
        disable()
        Logger.warning("[CowWorktree] Falling back: failed to list target tree (#{inspect(error)})")
        {:fallback, :no_target_tree}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 6: create empty worktree (no checkout)
  # ---------------------------------------------------------------------------

  defp create_empty_worktree(repo_root, worktree_path, target_commit, branch_name) do
    # Delete existing branch if present (ignore result)
    if Git.branch_exists?(repo_root, branch_name) do
      Git.run(["branch", "-D", branch_name], repo_root)
    end

    case Git.run(
           ["worktree", "add", "--no-checkout", "-b", branch_name, worktree_path, target_commit],
           repo_root
         ) do
      {:ok, _output} ->
        :ok

      error ->
        Logger.warning("[CowWorktree] worktree add failed: #{inspect(error)}")
        {:fallback, :worktree_add_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Steps 7 + 8: copy shared files then checkout remaining
  # ---------------------------------------------------------------------------

  defp populate_worktree(_repo_root, worktree_path, _source_path, target_commit, []) do
    # No shared files to copy — just checkout everything
    Logger.debug("[CowWorktree] No shared files; checkout all from target commit")

    case Git.run(["checkout", target_commit, "--", "."], worktree_path) do
      {:ok, _} -> :ok
      error -> Logger.warning("[CowWorktree] checkout failed: #{inspect(error)}"); {:fallback, :checkout_failed}
    end
  end

  defp populate_worktree(_repo_root, worktree_path, source_path, target_commit, shared_files) do
    # Step 7: copy shared files from source to worktree
    case copy_shared_files(source_path, worktree_path, shared_files) do
      :ok ->
        :ok

      {:error, code, output} ->
        Logger.warning("[CowWorktree] cp failed (code #{code}): #{output}")
        {:fallback, :cp_failed}
    end
    |> case do
      :ok ->
        # Step 8: checkout remaining files (git stat+hash-skips already-present files)
        case Git.run(["checkout", target_commit, "--", "."], worktree_path) do
          {:ok, _} -> :ok
          error ->
            Logger.warning("[CowWorktree] checkout failed: #{inspect(error)}")
            {:fallback, :checkout_failed}
        end

      fallback ->
        fallback
    end
  end

  # ---------------------------------------------------------------------------
  # Step 7: platform-specific file copying
  # ---------------------------------------------------------------------------

  defp copy_shared_files(source_path, worktree_path, files) do
    cond do
      EvoGit.Platform.os() == :linux ->
        Logger.debug("[CowWorktree] Copying #{length(files)} files via Linux cp --reflink=auto")
        copy_files_linux(source_path, worktree_path, files)

      EvoGit.Platform.os() == :macos ->
        Logger.debug("[CowWorktree] Copying #{length(files)} files via macOS cp -c (clonefile)")
        copy_files_macos(source_path, worktree_path, files)

      true ->
        # Other platforms (e.g. Windows) — not CoW-optimizable
        {:error, -1, "unsupported platform for CoW copy"}
    end
  end

  defp copy_files_linux(source_path, worktree_path, files) do
    files
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn batch, _acc ->
      args = ["--reflink=auto", "--parents" | batch] ++ [worktree_path <> "/"]

      case System.cmd("cp", args, cd: source_path, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("[CowWorktree] Copied batch of #{length(batch)} files (Linux)")
          {:cont, :ok}

        {output, code} ->
          {:halt, {:error, code, output}}
      end
    end)
  end

  defp copy_files_macos(source_path, worktree_path, files) do
    files
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn batch, _acc ->
      # Pre-create parent directories (non-bang — handle errors gracefully)
      dirs = batch |> Enum.map(&Path.dirname/1) |> Enum.uniq()

      case create_dirs(worktree_path, dirs) do
        :ok ->
          # Copy files in this batch — one `cp` invocation per distinct parent
          # directory. BSD `cp` accepts multiple sources with an existing
          # directory target (the dirs are pre-created above), and `-c`
          # (clonefile) CoW semantics apply per file. This reduces process
          # spawns from N files to D distinct directories.
          result =
            batch
            |> Enum.group_by(&Path.dirname/1)
            |> Enum.reduce_while(:ok, fn {dir, dir_files}, _acc ->
              dest = if dir == ".", do: worktree_path, else: Path.join(worktree_path, dir)

              case System.cmd(
                     "cp",
                     ["-c" | dir_files] ++ [dest],
                     cd: source_path,
                     stderr_to_stdout: true
                   ) do
                {_output, 0} -> {:cont, :ok}
                {output, code} -> {:halt, {:error, code, output}}
              end
            end)

          case result do
            :ok ->
              Logger.debug("[CowWorktree] Copied batch of #{length(batch)} files (macOS)")
              {:cont, :ok}

            error ->
              {:halt, error}
          end

        {:error, reason} ->
          {:halt, {:error, -1, "mkdir_p failed: #{inspect(reason)}"}}
      end
    end)
  end

  defp create_dirs(worktree_path, dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, _acc ->
      case File.mkdir_p(Path.join(worktree_path, dir)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Cleanup helper
  # ---------------------------------------------------------------------------

  defp cleanup_partial_worktree(repo_root, worktree_path, branch_name) do
    Logger.debug("[CowWorktree] Cleaning up partial worktree: #{worktree_path}")

    # Remove the worktree (ignore errors — best effort)
    Git.run(["worktree", "remove", "--force", worktree_path], repo_root)

    # Delete the branch (ignore errors — best effort)
    Git.run(["branch", "-D", branch_name], repo_root)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Porcelain status parsing
  # ---------------------------------------------------------------------------

  defp parse_dirty_files(porcelain_output) do
    porcelain_output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      # Format: "XY filename" — filename starts at position 3 (0-indexed)
      # Handle renamed files: "R  old -> new" — take the new path
      path = String.slice(line, 3..-1//1) |> String.trim()

      case String.split(path, " -> ") do
        [_, new_path] -> new_path
        [single] -> single
      end
    end)
    |> MapSet.new()
  end
end
