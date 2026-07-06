defmodule EvoGit.Skills.CRUD do
  @moduledoc """
  Skill management (CRUD) — create, read, update, delete skill files in
  `.agents/skills/`.
  """

  alias EvoGit.Skills

  @skills_dir ".agents/skills"

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validates that a skill body text will produce a valid skill when parsed.
  Used by management tools to preview/validate before writing.
  """
  def validate_skill_text(content) when is_binary(content) do
    case Skills.parse_frontmatter(content) do
      {:ok, metadata, _body} ->
        name = Map.get(metadata, "name", "")

        cond do
          is_nil(name) or name == "" ->
            {:error, "Skill must have a 'name' in its frontmatter"}

          not String.match?(name, ~r/^[a-z][a-z0-9_-]*$/i) ->
            {:error,
             "Skill name '#{name}' is invalid. Use only letters, numbers, hyphens, and underscores. Must start with a letter."}

          true ->
            {:ok, name}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new skill file in `.agents/skills/`.

  Returns `{:ok, file_path}` on success, `{:error, reason}` on failure.
  """
  @spec add_skill(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def add_skill(repo_root, content, _description, _params) do
    # Validate the skill content
    case validate_skill_text(content) do
      {:ok, _name} ->
        # Extract the name to determine filename
        {:ok, metadata, _body} = Skills.parse_frontmatter(content)
        name = Map.get(metadata, "name")
        filename = skill_filename(name)
        skills_path = ensure_skills_dir(repo_root)
        file_path = Path.join(skills_path, filename)

        if File.exists?(file_path) do
          {:error, "Skill '#{name}' already exists at #{file_path}"}
        else
          case File.write(file_path, content) do
            :ok ->
              {:ok, file_path}

            {:error, reason} ->
              {:error, "Failed to write skill file: #{:file.format_error(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates an existing skill file by name.

  Returns `{:ok, file_path}` on success, `{:error, reason}` on failure.
  """
  @spec edit_skill(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def edit_skill(repo_root, name, new_content) do
    skills_path = Path.join(repo_root, @skills_dir)
    file_path = find_skill_file(skills_path, name)

    case file_path do
      nil ->
        {:error, "Skill '#{name}' not found"}

      path ->
        case validate_skill_text(new_content) do
          {:ok, validated_name} ->
            if validated_name != name do
              {:error,
               "Skill name mismatch: content declares '#{validated_name}' but editing '#{name}'. The name in frontmatter must match."}
            else
              case File.write(path, new_content) do
                :ok -> {:ok, path}
                {:error, reason} -> {:error, "Failed to write: #{:file.format_error(reason)}"}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Removes a skill file by name.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec remove_skill(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_skill(repo_root, name) do
    skills_path = Path.join(repo_root, @skills_dir)

    case find_skill_file(skills_path, name) do
      nil ->
        {:error, "Skill '#{name}' not found"}

      path ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to remove: #{:file.format_error(reason)}"}
        end
    end
  end

  @doc """
  Lists all available skills with their names and descriptions.

  Returns a formatted string listing all skills.
  """
  @spec list_skills(String.t()) :: String.t()
  def list_skills(repo_root) do
    skills = Skills.load_skills(repo_root)

    if Enum.empty?(skills) do
      "No skills defined. Skills live in #{@skills_dir}/ as markdown files with YAML frontmatter."
    else
      lines =
        Enum.map(skills, fn skill ->
          param_str =
            if Enum.empty?(skill.parameters) do
              "no parameters"
            else
              params =
                Enum.map(skill.parameters, fn p ->
                  req = if p.required, do: " (required)", else: " (optional)"
                  "    - #{p.name}: #{p.type}#{req} — #{p.description}"
                end)

              "\n#{Enum.join(params, "\n")}"
            end

          "* **#{skill.name}** — #{skill.description}#{param_str}"
        end)

      "Available skills in #{@skills_dir}/:\n\n#{Enum.join(lines, "\n\n")}"
    end
  end

  @doc """
  Reads a skill file's full content by name.

  Returns the raw markdown content on success, or an error string.
  """
  @spec read_skill(String.t(), String.t()) :: String.t()
  def read_skill(repo_root, name) do
    skills_path = Path.join(repo_root, @skills_dir)

    case find_skill_file(skills_path, name) do
      nil ->
        "Error: Skill '#{name}' not found"

      path ->
        case File.read(path) do
          {:ok, content} -> content
          {:error, reason} -> "Error reading skill '#{name}': #{:file.format_error(reason)}"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers (now public for reuse)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures the `.agents/skills/` directory exists under the given repo root.
  Creates it (and parent directories) if needed.
  """
  def ensure_skills_dir(repo_root) do
    skills_path = Path.join(repo_root, @skills_dir)
    File.mkdir_p!(skills_path)
    skills_path
  end

  @doc """
  Returns the expected filename for a skill with the given name.
  Appends `.md` extension.
  """
  def skill_filename(name) do
    "#{name}.md"
  end

  @doc """
  Converts a skill file path to a skill name by stripping the `.md` extension
  and replacing non-alphanumeric characters with hyphens.
  """
  def filename_to_name(file_path) do
    file_path
    |> Path.basename(".md")
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  @doc """
  Finds a skill file on disk by skill name.

  Does an exact filename match first, then falls back to case-insensitive
  matching.
  """
  def find_skill_file(skills_path, name) do
    filename = skill_filename(name)
    file_path = Path.join(skills_path, filename)

    if File.exists?(file_path) do
      file_path
    else
      # Also try case-insensitive match
      case File.ls(skills_path) do
        {:ok, files} ->
          Enum.find_value(files, fn f ->
            if String.downcase(f) == String.downcase(filename) do
              Path.join(skills_path, f)
            end
          end)

        {:error, _} ->
          nil
      end
    end
  end
end
