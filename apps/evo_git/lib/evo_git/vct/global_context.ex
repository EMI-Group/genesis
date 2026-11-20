defmodule EvoGit.VCT.GlobalContext do
  @moduledoc """
  Internal global-context file store for `EvoGit.VCT`.

  This module is an internal helper of `EvoGit.VCT`: it owns the OPTIONAL
  `<data_dir>/vct/CONTEXT.md` file and the lazy local git repository beside it,
  so a global-context edit is a committed, auditable change.
  Every function takes the CONTEXT FILE path (or a value) as its argument and
  reads no `GenServer` state, which keeps it unit-testable in isolation.

  `read/1` is TOTAL (`""` when the file is absent or unreadable), `write/2`
  writes verbatim and then — only for NON-BLANK content — lazily `git init`s the
  directory, writes a `.gitignore`, stages and commits. Every git failure is
  logged and NEVER loses the written file, and `sync_boot/1` is the same
  best-effort sync at boot for a context file that already exists and is
  non-blank (an absent or blank file initializes nothing).
  """

  require Logger

  @file_name "CONTEXT.md"
  @commit_message "Update global context"

  # Any atomic-write temporaries must never enter the global context's git
  # history. The mount table itself is task-store state, not a file here.
  @gitignore_entries [
    "# Temporary files, never committed.",
    "*.tmp",
    "*.tmp.*"
  ]

  @doc false
  @spec default_path() :: String.t()
  def default_path do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    path_for(Path.join(data_dir, "vct"))
  end

  @doc false
  @spec path_for(String.t()) :: String.t()
  def path_for(vct_dir), do: Path.join(vct_dir, @file_name)

  @doc false
  @spec read(term()) :: String.t()
  def read(context_path) when is_binary(context_path) do
    case File.read(context_path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  def read(_context_path), do: ""

  @doc false
  @spec write(term(), term()) :: :ok | {:error, term()}
  def write(context_path, content) when is_binary(context_path) and is_binary(content) do
    vct_dir = Path.dirname(context_path)

    with :ok <- File.mkdir_p(vct_dir),
         :ok <- File.write(context_path, content, [:binary]) do
      unless blank?(content), do: sync_repository(vct_dir)
      :ok
    end
  end

  @doc false
  @spec sync_boot(term()) :: :ok
  def sync_boot(context_path) when is_binary(context_path) do
    # Boot-time counterpart of the lazy sync in `write/2`: when a NON-BLANK
    # global context file already exists (e.g. restored from a state backup),
    # commit it into its local git history now. An absent or blank file
    # initializes NOTHING (no empty repository), and the sync stays idempotent —
    # a clean tree stages no change, so HEAD is never moved. Every failure is
    # logged, never raised: git trouble must never crash boot.
    if File.exists?(context_path) and not blank?(read(context_path)) do
      sync_repository(Path.dirname(context_path))
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "VCT: boot-time global context git sync failed: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("VCT: boot-time global context git sync failed: #{inspect({kind, reason})}")
      :ok
  end

  def sync_boot(_context_path), do: :ok

  ## Lazy local git repository

  # Best effort: a git failure is logged and must NEVER lose the written file.
  defp sync_repository(vct_dir) do
    with :ok <- ensure_git_repository(vct_dir),
         :ok <- ensure_gitignore(vct_dir),
         :ok <- stage_context(vct_dir),
         {:ok, status} <- context_status(vct_dir) do
      maybe_commit_context(vct_dir, status)
    else
      {:error, reason} ->
        Logger.warning("VCT: global context git sync skipped: #{inspect(reason)}")
    end

    :ok
  end

  defp ensure_git_repository(vct_dir) do
    if File.exists?(Path.join(vct_dir, ".git")) do
      :ok
    else
      case EvoGit.Adapters.Git.init(vct_dir) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, {:git_init, reason}}
      end
    end
  end

  defp ensure_gitignore(vct_dir) do
    path = Path.join(vct_dir, ".gitignore")

    if File.exists?(path) do
      :ok
    else
      case File.write(path, Enum.join(@gitignore_entries, "\n") <> "\n") do
        :ok -> :ok
        {:error, reason} -> {:error, {:gitignore, reason}}
      end
    end
  end

  defp stage_context(vct_dir) do
    case EvoGit.Adapters.Git.add(vct_dir, ".") do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_add, reason}}
    end
  end

  defp context_status(vct_dir) do
    case EvoGit.Adapters.Git.status(vct_dir) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, {:git_status, reason}}
    end
  end

  # `{:ok, ""}` after staging means the working tree is clean: nothing to
  # commit, so HEAD is left untouched.
  defp maybe_commit_context(_vct_dir, ""), do: :ok

  defp maybe_commit_context(vct_dir, _status) do
    case EvoGit.Adapters.Git.commit(vct_dir, @commit_message) do
      {:ok, _output} -> :ok
      {:error, reason} -> Logger.warning("VCT: global context commit failed: #{inspect(reason)}")
    end
  end

  defp blank?(content), do: String.trim(content) == ""
end
