defmodule EvoGit.AgentScheduler.WorktreeRetention do
  @moduledoc """
  Keeps unfinished worktrees and their only commit references recoverable.
  Recovery descriptors live beside the workers directory, so they survive a
  runtime restart without changing Git's worktree registration or user files.
  """
  alias EvoGit.Adapters.Git

  def disposition(path, repo, branch) do
    cond do
      not File.exists?(path) ->
        branch_disposition(repo, branch)

      not File.regular?(Path.join(path, ".git")) ->
        {:retain, "unrecognized_worktree"}

      true ->
        case Git.status(path) do
          {:ok, ""} -> branch_disposition(repo, branch)
          {:ok, _} -> {:retain, "uncommitted_changes"}
          _ -> {:retain, "git_status_unavailable"}
        end
    end
  end

  def record(repo, path, branch, meta) do
    entry =
      Map.merge(
        %{"path" => path, "branch" => branch, "repo_root" => repo},
        Map.new(meta, fn {k, v} -> {to_string(k), v} end)
      )

    file = descriptor(repo, path)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file <> ".tmp", Jason.encode!(entry)),
         :ok <- File.rename(file <> ".tmp", file),
         do: :ok
  end

  def retain(repo, path, branch, reason) do
    meta =
      case File.read(descriptor(repo, path)) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    head =
      case Git.rev_parse(path) do
        {:ok, value} -> value
        _ -> nil
      end

    record(
      repo,
      path,
      branch,
      Map.merge(meta, %{"reason" => reason, "head" => head, "retained" => true})
    )
  end

  def forget(repo, path), do: File.rm(descriptor(repo, path))

  @doc "Records actual task repository roots before foreign work starts."
  def track_task_repositories(_repo, nil, _roots), do: :ok

  def track_task_repositories(repo, task_id, roots) when is_binary(task_id) do
    # One immutable entry per root avoids read/merge/write races between phases.
    # Keep earlier roots even if project configuration changes during the task.
    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Path.expand(repo)))
    |> Enum.reduce_while(:ok, fn root, :ok ->
      file = Path.join([repo, ".genesis/recovery/tasks", key(task_id), key(root) <> ".json"])
      entry = Jason.encode!(%{"repo_root" => root, "task_id" => task_id})

      case write_index_entry(file, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def list(repo, task_id \\ nil) do
    entries = local_entries(repo, task_id)

    (entries ++
       Enum.flat_map(tracked_repositories(repo, task_id), fn {root, id} ->
         local_entries(root, id)
       end))
    |> Enum.uniq_by(&{&1["repo_root"], &1["path"]})
    |> Enum.take(100)
  end

  defp write_index_entry(file, entry) do
    tmp = file <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, entry),
         :ok <- File.rename(tmp, file),
         do: :ok
  end

  defp tracked_repositories(repo, task_id) do
    task_key = if is_nil(task_id), do: "*", else: key(task_id)

    repo
    |> Path.join(".genesis/recovery/tasks/#{task_key}/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      with {:ok, body} <- File.read(file),
           {:ok, %{"repo_root" => root, "task_id" => id}} when is_binary(root) and is_binary(id) <-
             Jason.decode(body),
           true <- is_nil(task_id) or task_id == id do
        [{root, id}]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp key(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp local_entries(repo, task_id) do
    discover(repo)

    repo
    |> Path.join(".genesis/recovery/*.json")
    |> Path.wildcard()
    |> Stream.flat_map(fn file ->
      with {:ok, body} <- File.read(file),
           {:ok, entry} when is_map(entry) <- Jason.decode(body),
           true <- is_nil(task_id) or entry["task_id"] == task_id,
           path when is_binary(path) <- entry["path"],
           true <- File.dir?(path) do
        [entry]
      else
        _ -> []
      end
    end)
    |> Enum.take(100)
  end

  @doc "Discovers pre-descriptor Genesis workers once per repository and VM."
  def discover(repo) do
    table = :evogit_worktree_repos
    key = {:recovery_discovered, Path.expand(repo)}
    known = :ets.whereis(table) != :undefined and :ets.member(table, key)

    unless known do
      with {:ok, output} <- Git.run(["worktree", "list", "--porcelain", "-z"], repo) do
        output
        |> String.split("\0\0", trim: true)
        |> Enum.each(fn record ->
          fields =
            record
            |> String.split("\0", trim: true)
            |> Map.new(fn field ->
              case String.split(field, " ", parts: 2) do
                [key, value] -> {key, value}
                [key] -> {key, true}
              end
            end)

          path = fields["worktree"]
          branch = fields["branch"]

          if is_binary(path) and is_binary(branch) and
               String.starts_with?(branch, "refs/heads/evogit-agent-") and
               worker_path?(repo, path) and not File.exists?(descriptor(repo, path)) do
            branch = String.replace_prefix(branch, "refs/heads/", "")

            case disposition(path, repo, branch) do
              {:retain, reason} -> retain(repo, path, branch, reason)
              :discard -> :ok
            end
          end
        end)

        if :ets.whereis(table) != :undefined, do: :ets.insert(table, {key, true})
      end
    end

    :ok
  end

  defp worker_path?(repo, path) do
    root = Path.expand(Path.join(repo, ".genesis/workers")) <> "/"
    path = Path.expand(path)

    if EvoGit.Platform.os() == :windows,
      do: String.starts_with?(String.downcase(path), String.downcase(root)),
      else: String.starts_with?(path, root)
  end

  defp branch_disposition(repo, branch) do
    case Git.run(["for-each-ref", "--format=%(objectname)", "refs/heads/" <> branch], repo) do
      {:error, _} ->
        {:retain, "git_refs_unavailable"}

      {:ok, ""} ->
        :discard

      {:ok, heads} ->
        head = heads |> String.split("\n", trim: true) |> hd()

        case Git.run(
               [
                 "for-each-ref",
                 "--contains",
                 head,
                 "--format=%(refname)",
                 "refs/heads",
                 "refs/genesis/archive"
               ],
               repo
             ) do
          {:ok, refs} ->
            durable =
              refs
              |> String.split("\n", trim: true)
              |> Enum.any?(fn ref ->
                not String.starts_with?(ref, "refs/heads/evogit-agent-")
              end)

            if durable, do: :discard, else: {:retain, "unpublished_commits"}

          _ ->
            {:retain, "git_refs_unavailable"}
        end
    end
  end

  defp descriptor(repo, path) do
    path = Path.expand(path)
    path = if EvoGit.Platform.windows?(), do: String.downcase(path), else: path
    key = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    Path.join([repo, ".genesis/recovery", key <> ".json"])
  end
end
