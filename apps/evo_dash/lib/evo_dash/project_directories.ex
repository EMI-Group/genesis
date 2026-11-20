defmodule EvoDash.ProjectDirectories do
  @moduledoc false

  alias EvoDash.NodeContext
  alias EvoDashWeb.ProjectsLive.Project
  alias EvoGit.RemoteNode

  # The filesystem and path functions run on the selected node, including
  # its Path implementation. Older Genesis releases already export these APIs.
  def browse(target, requested) do
    with {:ok, path} <- directory_path(target, requested),
         {:ok, {:ok, names}} <- RemoteNode.call_remote(target, File, :ls, [path]),
         {:ok, parent} <- RemoteNode.call_remote(target, Path, :dirname, [path]),
         entries = Enum.filter(names, &String.valid?/1),
         {:ok, paths} <-
           RemoteNode.call_remote(target, Enum, :zip_with, [
             List.duplicate(path, length(entries)),
             entries,
             &Path.join/2
           ]),
         {:ok, directories} <-
           RemoteNode.call_remote(target, Enum, :filter, [paths, &File.dir?/1]) do
      directories = MapSet.new(directories)

      entries =
        Enum.zip(entries, paths)
        |> Enum.filter(fn {_name, full} -> MapSet.member?(directories, full) end)
        |> Enum.map(fn {name, full} -> %{name: name, path: full} end)
        |> Enum.sort_by(&{String.downcase(&1.name), &1.name})

      {:ok, %{path: path, parent: if(path == parent, do: nil, else: parent), entries: entries}}
    else
      {:ok, {:error, reason}} when is_atom(reason) -> {:error, reason}
      {:error, :absolute_path_required} -> {:error, :absolute_path_required}
      _ -> {:error, :directory_unavailable}
    end
  end

  def mount(target, node_id, "open", directory, _) do
    register(target, node_id, directory)
  end

  def mount(target, node_id, "create", directory, name) do
    with {:ok, name} <- validate_name(name),
         {:ok, path} <- RemoteNode.call_remote(target, Path, :join, [directory, name]),
         :ok <- make_directory(target, path) do
      register(target, node_id, path)
    end
  end

  defp directory_path(target, :home) do
    case RemoteNode.call_remote(target, System, :user_home, []) do
      {:ok, home} when is_binary(home) -> directory_path(target, home)
      _ -> {:error, :directory_unavailable}
    end
  end

  defp directory_path(target, input) when is_binary(input) do
    input = String.trim(input)

    case RemoteNode.call_remote(target, Path, :type, [input]) do
      {:ok, :absolute} -> RemoteNode.call_remote(target, Path, :expand, [input])
      _ -> {:error, :absolute_path_required}
    end
  end

  defp validate_name(name) do
    with {:ok, name} <- Project.validate_project_name(name),
         false <- name in [".", ".."],
         false <- String.contains?(name, ["\0", ":"]) do
      {:ok, name}
    else
      _ -> {:error, :invalid_name}
    end
  end

  defp make_directory(target, path) do
    case RemoteNode.call_remote(target, File, :mkdir, [path]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :directory_unavailable}
    end
  end

  defp register(target, node_id, path) do
    with {:ok, true} <- RemoteNode.call_remote(target, File, :dir?, [path]),
         {:ok, name} <- RemoteNode.call_remote(target, Path, :basename, [path]),
         {:ok, project} <- NodeContext.mount_project(target, path, name) do
      {:ok, %{node_id: node_id, path: project.path}}
    else
      _ -> {:error, :mount_failed}
    end
  end
end
