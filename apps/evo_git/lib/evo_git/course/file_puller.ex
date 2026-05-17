defmodule EvoGit.Course.FilePuller do
  @moduledoc """
  Pulls course build artifacts (`.tar.zst` archives) from a remote builder node
  and extracts them to a local courses directory.

  Requires `EvoGit.Course.builder_node/0` to return a non‑nil node name.
  The remote tar path defaults to `"/tmp/evogit_builds/<course_name>.tar.zst"`
  but can be overridden via Application config (`:evo_git, :builder_remote_dir`).
  """

  require Logger

  @doc """
  Pull a course artifact from the builder node and extract it locally.

  ## Parameters

    - `course_name` — the course name (used for remote path and local subdirectory)
    - `local_courses_dir` — local directory where courses are stored (e.g., `"/var/courses"`)
    - `opts` — keyword options (reserved for future use)

  ## Returns

    - `{:ok, local_course_dir}` on success (the extracted course directory)
    - `{:error, reason}` on failure

  ## Examples

      iex> EvoGit.Course.FilePuller.pull("my_course", "/var/courses")
      {:ok, "/var/courses/my_course"}

  """
  @spec pull(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def pull(course_name, local_courses_dir, _opts \\ []) do
    with {:ok, builder_node} <- resolve_builder_node(),
         remote_tar_path <- remote_tar_path(course_name),
         {:ok, local_tar_path} <- ensure_temp_tar(course_name, local_courses_dir),
         :ok <- pull_artifact(builder_node, remote_tar_path, local_tar_path),
         {:ok, local_course_dir} <- extract(local_tar_path, local_courses_dir, course_name) do
      cleanup_temp_tar(local_tar_path)
      {:ok, local_course_dir}
    else
      {:error, reason} = error ->
        Logger.error("Failed to pull course #{course_name}: #{inspect(reason)}")
        error
    end
  end

  # --- Private helpers ---

  defp resolve_builder_node do
    case EvoGit.Course.builder_node() do
      nil ->
        {:error, :no_builder_configured}

      node ->
        {:ok, node}
    end
  end

  defp remote_tar_path(course_name) do
    remote_dir = Application.get_env(:evo_git, :builder_remote_dir, "/tmp/evogit_builds")
    Path.join(remote_dir, "#{course_name}.tar.zst")
  end

  defp ensure_temp_tar(course_name, local_courses_dir) do
    # Create a temp file path for the downloaded tar.zst
    file_name = "#{course_name}_#{unique_suffix()}.tar.zst"
    path = Path.join(local_courses_dir, file_name)

    with :ok <- File.mkdir_p(local_courses_dir) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, {:mkdir_failed, local_courses_dir, reason}}
    end
  end

  defp unique_suffix do
    System.system_time(:millisecond)
    |> Integer.to_string()
  end

  defp pull_artifact(builder_node, remote_tar_path, local_tar_path) do
    case EvoGit.Cluster.FilePuller.pull(builder_node, remote_tar_path, local_tar_path) do
      :ok ->
        Logger.info("Pulled #{remote_tar_path} from #{builder_node}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to pull #{remote_tar_path} from #{builder_node}: #{inspect(reason)}")
        {:error, {:pull_failed, builder_node, remote_tar_path, reason}}
    end
  end

  defp extract(local_tar_path, local_courses_dir, course_name) do
    local_course_dir = Path.join(local_courses_dir, course_name)

    with :ok <- File.mkdir_p(local_course_dir),
         {_output, 0} <-
           System.cmd("tar", ["--zstd", "-xf", local_tar_path, "-C", local_courses_dir]) do
      Logger.info("Extracted #{local_tar_path} to #{local_courses_dir}")
      {:ok, local_course_dir}
    else
      {:error, reason} ->
        {:error, {:extract_mkdir_failed, local_course_dir, reason}}

      {output, code} ->
        Logger.error("Failed to extract #{local_tar_path}: #{output}")
        {:error, {:tar_extract_failed, code, String.trim(output)}}
    end
  end

  defp cleanup_temp_tar(local_tar_path) do
    case File.rm(local_tar_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove temp file #{local_tar_path}: #{inspect(reason)}")
        :ok
    end
  end
end
