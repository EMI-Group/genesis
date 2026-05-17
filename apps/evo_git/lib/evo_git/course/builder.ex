defmodule EvoGit.Course.Builder do
  @moduledoc """
  Course Builder — builds courses from git repos into plain files/folders
  with a transformation pipeline.

  Each git repo is expected to have language-variant branches:
    - `main` — the default/English variant (mapped to "en" output)
    - `lang-<code>` — other language variants (e.g., `lang-zh` → "zh")

  After extracting each branch into a language subdirectory, optional
  transformation modules are applied in order to the output tree.
  Finally the entire output directory is compressed to a `.tar.zst` archive.
  """

  require Logger

  @doc """
  Build a single course from a git repo.

  ## Parameters

    - `repo_path` — path to the git repo
    - `output_dir` — where to put built files
    - `opts` — keyword options:
      - `:transformations` — list of transformation modules (default: `[]`)
      - `:tar_file` — path to output `.tar.zst` file (default: `nil`, auto‑generated in `output_dir` parent)

  ## Returns

    - `{:ok, tar_path}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> EvoGit.Course.Builder.build("/path/to/repo", "/tmp/courses/my_course")
      {:ok, "/tmp/courses/my_course.tar.zst"}

  """
  @spec build(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(repo_path, output_dir, opts \\ []) do
    transformations = Keyword.get(opts, :transformations, [])
    tar_file = Keyword.get(opts, :tar_file, nil)

    with :ok <- ensure_output_dir(output_dir),
         {:ok, branches} <- list_language_branches(repo_path),
         :ok <- extract_branches(repo_path, output_dir, branches),
         :ok <- apply_transformations(output_dir, branches, transformations) do
      compress(output_dir, tar_file)
    end
  end

  @doc """
  Build all courses configured in the system.

  Reads course configurations from Application config (`:evo_git, :courses`) —
  a list of maps with `:name` and `:repo_path` keys.

  Returns a list of `{:ok, course_name, tar_path}` or `{:error, course_name, reason}`.

  ## Examples

      iex> EvoGit.Course.Builder.build_all()
      [{:ok, "my_course", "/tmp/courses/my_course.tar.zst"}]

  """
  @spec build_all(keyword()) :: [{:ok, String.t(), String.t()} | {:error, String.t(), term()}]
  def build_all(opts \\ []) do
    courses = Application.get_env(:evo_git, :courses, [])

    Enum.map(courses, fn %{name: name, repo_path: repo_path} ->
      output_dir = Path.join([System.tmp_dir!(), "evogit_courses", name])

      case build(repo_path, output_dir, opts) do
        {:ok, tar_path} -> {:ok, name, tar_path}
        {:error, reason} -> {:error, name, reason}
      end
    end)
  end

  # --- Private helpers ---

  defp ensure_output_dir(output_dir) do
    case File.mkdir_p(output_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to create output directory #{output_dir}: #{inspect(reason)}")
        {:error, {:output_dir_create_failed, output_dir, reason}}
    end
  end

  @doc false
  def list_language_branches(repo_path) do
    case System.cmd("git", ["branch", "-a"], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(fn
            "* " <> rest -> rest
            other -> other
          end)
          |> Enum.reject(&String.starts_with?(&1, "remotes/"))
          |> Enum.filter(&branch_matches?/1)
          |> Enum.sort()

        if branches == [] do
          Logger.warning("No language branches found in #{repo_path}")
        end

        {:ok, branches}

      {output, code} ->
        Logger.error("Failed to list branches in #{repo_path}: #{output}")
        {:error, {:git_branch_failed, code, String.trim(output)}}
    end
  end

  defp branch_matches?(branch) do
    branch == "main" or String.starts_with?(branch, "lang-")
  end

  defp extract_branches(repo_path, output_dir, branches) do
    results =
      Enum.map(branches, fn branch ->
        lang_code = branch_to_lang_code(branch)
        subdir = Path.join(output_dir, lang_code)

        with :ok <- File.mkdir_p(subdir),
             :ok <- extract_branch(repo_path, branch, subdir) do
          :ok
        else
          {:error, reason} ->
            Logger.error("Failed to extract branch #{branch}: #{inspect(reason)}")
            {:error, branch, reason}
        end
      end)

    case Enum.find(results, fn r -> match?({:error, _, _}, r) end) do
      {:error, branch, reason} -> {:error, {:extract_failed, branch, reason}}
      nil -> :ok
    end
  end

  defp extract_branch(repo_path, branch, subdir) do
    # Use git archive --output to a temp file, then tar -xf to extract.
    # We write to a path under subdir to stay on the same filesystem.
    tmp_tar = Path.join(subdir, ".evogit_archive_tmp.tar")

    case System.cmd("git", ["-C", repo_path, "archive", "--output", tmp_tar, branch],
           stderr_to_stdout: true) do
      {_output, 0} ->
        case System.cmd("tar", ["-xf", tmp_tar, "-C", subdir], stderr_to_stdout: true) do
          {_output, 0} ->
            File.rm(tmp_tar)
            :ok

          {output, code} ->
            File.rm(tmp_tar)
            Logger.error("tar extract failed for #{branch}: #{output}")
            {:error, {:tar_extract_failed, code, String.trim(output)}}
        end

      {output, code} ->
        Logger.error("git archive failed for #{branch}: #{output}")
        {:error, {:git_archive_failed, code, String.trim(output)}}
    end
  end

  defp branch_to_lang_code("main"), do: "en"
  defp branch_to_lang_code("lang-" <> code), do: code
  # fallback — should not happen given branch_matches? filtering
  defp branch_to_lang_code(other), do: other

  defp apply_transformations(_output_dir, _branches, []), do: :ok

  defp apply_transformations(output_dir, branches, transformation_modules) do
    Enum.reduce_while(transformation_modules, :ok, fn module, :ok ->
      result = module.transform(output_dir, branches: branches)

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.error("Transformation #{inspect(module)} failed: #{inspect(reason)}")
          {:halt, {:error, {:transformation_failed, module, reason}}}
      end
    end)
  end

  defp compress(output_dir, tar_file) do
    parent_dir = Path.dirname(output_dir)
    basename = Path.basename(output_dir)
    tar_path = tar_file || Path.join(parent_dir, "#{basename}.tar.zst")

    case System.cmd("tar", ["--zstd", "-cf", tar_path, "-C", parent_dir, basename]) do
      {_output, 0} ->
        Logger.info("Course built and compressed to #{tar_path}")
        {:ok, tar_path}

      {output, code} ->
        Logger.error("Failed to compress course: #{output}")
        {:error, {:tar_compress_failed, code, String.trim(output)}}
    end
  end
end
