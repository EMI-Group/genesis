defmodule EvoGit.Course.Server do
  @moduledoc """
  Serves course files from either git repos (:git mode) or built artifacts (:build mode).

  ## Modes

  - `:git` — Local development mode. Reads files directly from git repositories
    using `git show`. Suitable for rapid iteration.
  - `:build` — Production mode. Reads files from pre-built course directories.
    Content is assumed to be immutable between builds.

  ## Configuration

  The following `Application` env keys are required:

  - `:evo_git, :courses_dir` — local directory where built courses live (build mode, default: `"/var/evogit/courses"`)
  - `:evo_git, :courses` — list of course maps: `[%{name: "course1", repo_path: "/path/to/repo"}, ...]`
  - `:evo_git, :builder_node` — the builder node atom (for pulling)
  - `:evo_git, :course_builds_dir` — remote dir on builder where tar.zst files live (default: `"/tmp/evogit_builds"`)
  - `:evo_git, :course_mode` — default mode (`:git` or `:build`, defaults to `:build`)
  """

  require Logger

  @doc """
  Get a course file's content and metadata.

  ## Parameters

  - `course_name` — name of the course
  - `path` — relative path within the course (e.g., `"index.html"`, `"css/style.css"`)
  - `mode` — `:git` or `:build` (defaults to `EvoGit.Course.mode()`)

  ## Returns

  - `{:ok, content, metadata}` where `metadata` is `%{etag: String.t(), content_type: String.t(), cache_control: String.t()}`
  - `{:error, :not_found}`
  - `{:error, reason}`
  """
  @spec get_file(String.t(), String.t(), atom() | nil) ::
          {:ok, String.t(), map()} | {:error, term()}
  def get_file(course_name, path, mode \\ nil) do
    mode = mode || default_mode()

    case mode do
      :git -> get_file_git(course_name, path)
      :build -> get_file_build(course_name, path)
      other -> {:error, {:invalid_mode, other}}
    end
  end

  @doc """
  Check if the server has a given course available.
  """
  @spec has_course?(String.t(), atom() | nil) :: boolean()
  def has_course?(course_name, mode \\ nil) do
    mode = mode || default_mode()

    case mode do
      :git -> has_course_git?(course_name)
      :build -> has_course_build?(course_name)
      _ -> false
    end
  end

  @doc """
  List all available courses.
  """
  @spec list_courses(atom() | nil) :: [map()]
  def list_courses(mode \\ nil) do
    mode = mode || default_mode()

    case mode do
      :git -> list_courses_git()
      :build -> list_courses_build()
      _ -> []
    end
  end

  @doc """
  Get the ETag for a file (useful for conditional requests).

  Returns a simple etag based on file mtime + size (build mode),
  or the git commit hash (git mode).
  """
  @spec etag(String.t(), String.t(), atom() | nil) :: {:ok, String.t()} | {:error, term()}
  def etag(course_name, path, mode \\ nil) do
    mode = mode || default_mode()

    case mode do
      :git -> etag_git(course_name, path)
      :build -> etag_build(course_name, path)
      other -> {:error, {:invalid_mode, other}}
    end
  end

  @doc """
  Pull the latest course build from the builder node.

  Called on startup and when notified of updates.
  Only meaningful in `:build` mode.
  """
  @spec pull_course(String.t(), keyword()) :: :ok | {:error, term()}
  def pull_course(course_name, opts \\ []) do
    if mode_is_build?() do
      EvoGit.Course.FilePuller.pull(course_name, courses_dir(), opts)
    else
      Logger.warning("pull_course is only supported in :build mode, skipping")
      :ok
    end
  end

  @doc """
  Pull all courses from the builder node.
  """
  @spec pull_all_courses(keyword()) :: :ok | {:error, term()}
  def pull_all_courses(opts \\ []) do
    if mode_is_build?() do
      courses = list_courses_build()

      results =
        Enum.map(courses, fn %{name: name} ->
          pull_course(name, opts)
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        :ok
      else
        {:error, {:partial_failures, errors}}
      end
    else
      Logger.warning("pull_all_courses is only supported in :build mode, skipping")
      :ok
    end
  end

  # ===========================================================================
  # :git mode
  # ===========================================================================

  defp get_file_git(course_name, path) do
    with {:ok, %{repo_path: repo_path}} <- find_course_config(course_name),
         {:ok, branch} <- default_branch(repo_path),
         {:ok, content} <- git_show(repo_path, branch, path) do
      etag = git_head_etag(repo_path, path)
      content_type = content_type_for(path)
      cache_control = "no-cache"

      metadata = %{
        etag: etag,
        content_type: content_type,
        cache_control: cache_control
      }

      {:ok, content, metadata}
    end
  end

  defp has_course_git?(course_name) do
    case find_course_config(course_name) do
      {:ok, %{repo_path: repo_path}} ->
        File.dir?(repo_path) and is_git_repo?(repo_path)

      {:error, _} ->
        false
    end
  end

  defp list_courses_git do
    Application.get_env(:evo_git, :courses, [])
  end

  defp etag_git(course_name, path) do
    with {:ok, %{repo_path: repo_path}} <- find_course_config(course_name) do
      {:ok, git_head_etag(repo_path, path)}
    end
  end

  # ===========================================================================
  # :build mode
  # ===========================================================================

  defp get_file_build(course_name, path) do
    courses_dir = courses_dir()
    file_path = Path.join([courses_dir, course_name, path])

    with {:ok, content} <- read_file(file_path),
         {:ok, etag} <- file_etag(file_path) do
      metadata = %{
        etag: etag,
        content_type: content_type_for(path),
        cache_control: "public, max-age=86400"
      }

      {:ok, content, metadata}
    end
  end

  defp has_course_build?(course_name) do
    course_dir = Path.join(courses_dir(), course_name)
    File.dir?(course_dir)
  end

  defp list_courses_build do
    courses_dir = courses_dir()

    if File.dir?(courses_dir) do
      case File.ls(courses_dir) do
        {:ok, entries} ->
          Enum.map(entries, fn name ->
            %{name: name}
          end)

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  defp etag_build(course_name, path) do
    file_path = Path.join([courses_dir(), course_name, path])
    file_etag(file_path)
  end

  # ===========================================================================
  # Content type detection
  # ===========================================================================

  @doc false
  def content_type_for(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".html" -> "text/html"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".svg" -> "image/svg+xml"
      ".json" -> "application/json"
      _ -> "application/octet-stream"
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp default_mode do
    EvoGit.Course.mode()
  end

  defp mode_is_build? do
    default_mode() == :build
  end

  defp courses_dir do
    EvoGit.Course.courses_dir()
  end

  defp find_course_config(course_name) do
    courses = Application.get_env(:evo_git, :courses, [])

    case Enum.find(courses, &(&1[:name] == course_name || &1.name == course_name)) do
      nil -> {:error, :unknown_course}
      course -> {:ok, course}
    end
  end

  defp is_git_repo?(repo_path) do
    File.dir?(Path.join(repo_path, ".git"))
  end

  defp default_branch(repo_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _exit_code} -> {:ok, "main"}
    end
  end

  defp git_show(repo_path, branch, path) do
    ref = "#{branch}:#{path}"

    case System.cmd("git", ["show", ref], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error_output, _exit_code} ->
        if String.contains?(error_output, "does not exist") or
           String.contains?(error_output, "bad revision") or
           String.contains?(error_output, "fatal: path") do
          {:error, :not_found}
        else
          {:error, {:git_error, String.trim(error_output)}}
        end
    end
  end

  defp git_head_etag(repo_path, path) do
    case System.cmd("git", ["log", "-1", "--format=%H", "--", path],
                    cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        hash = String.trim(output)

        if hash == "" do
          # Fallback: use HEAD commit hash
          case System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
            {head_output, 0} -> String.trim(head_output)
            {_, _} -> ""
          end
        else
          hash
        end

      {_output, _exit_code} ->
        ""
    end
  end

  defp read_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_etag(file_path) do
    case File.stat(file_path) do
      {:ok, %{mtime: mtime, size: size}} ->
        etag_value = "#{inspect(mtime)}_#{size}"
        {:ok, etag_value}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
