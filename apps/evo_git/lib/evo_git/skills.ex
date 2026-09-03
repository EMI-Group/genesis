defmodule EvoGit.Skills do
  @moduledoc """
  Skills system for EvoGit.

  Skills are custom tools defined as markdown files in `<repo_root>/.agents/skills/`.
  Each skill file uses YAML frontmatter to declare its name, description, and parameters,
  and the markdown body defines what the skill does (typically a bash command block).

  ## Skill File Format

      ---
      name: my-skill
      description: Does something useful with the project
      parameters:
        - name: input_file
          type: string
          description: Path to the input file
          required: true
        - name: output_format
          type: string
          description: Output format (json, yaml, text)
          required: false
          default: json
      ---

      # My Skill

      Description of what this skill does...

      ## Command
      ```bash
      #!/bin/bash
      INPUT="{{input_file}}"
      FORMAT="{{output_format}}"
      echo "Processing $INPUT in $FORMAT format..."
      ```

  ## Execution Model

  When a skill is called by an agent, the module:
  1. Extracts the first ```bash code block from the skill body
  2. Substitutes `{{param_name}}` placeholders with actual argument values
  3. Executes the resulting script via bash
  4. Returns stdout/stderr to the agent

  If no bash code block is found, the skill's body text is returned as-is
  (allowing the agent to use it as instructions with its other tools).

  ## Module Structure

  - `EvoGit.Skills.Executor` — skill execution (finding, parameter substitution, bash scripting)
  - `EvoGit.Skills.CRUD` — skill file management (create, read, update, delete)
  - `EvoGit.Skills.ContextIntegration` — hierarchical enablement via CONTEXT.md frontmatter
  - `EvoGit.Skills.Skill` — the `%Skill{}` struct
  """

  alias EvoGit.Skills.Skill
  alias EvoGit.Skills.{Executor, CRUD, ContextIntegration}

  @doc false
  # Single source of truth for the skills directory name, shared by the CRUD
  # module (which builds filesystem paths and user-facing messages from it).
  def skills_dir, do: ".agents/skills"

  # ---------------------------------------------------------------------------
  # Loading & Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Loads all skills from `<repo_root>/.agents/skills/`.

  Returns a list of `%EvoGit.Skills.Skill{}` structs.
  Returns an empty list if the directory doesn't exist.
  """
  @spec load_skills(String.t()) :: [Skill.t()]
  def load_skills(repo_root) do
    skills_path = Path.join(repo_root, skills_dir())

    case File.ls(skills_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          file_path = Path.join(skills_path, filename)
          parse_skill_file(file_path)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Parses a single skill markdown file.

  Returns `%Skill{}` on success, `nil` if the file can't be read or parsed.
  """
  @spec parse_skill_file(String.t()) :: Skill.t() | nil
  def parse_skill_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {:ok, metadata, body} ->
            name = Map.get(metadata, "name") || filename_to_name(file_path)
            desc = Map.get(metadata, "description") || ""
            params = Map.get(metadata, "parameters", [])

            %Skill{
              name: name,
              description: desc,
              parameters: normalize_parameters(params),
              body: String.trim(body),
              file_path: file_path
            }

          {:error, _reason} ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Tool Schema Generation
  # ---------------------------------------------------------------------------

  @doc """
  Converts a list of skills into `ReqLLM.tool()` schemas.

  Each skill becomes a tool with:
  - name: the skill's name (used directly as tool name)
  - description: the skill's description
  - parameter_schema: JSON Schema derived from the skill's parameter definitions
  """
  @spec to_tool_schemas([Skill.t()]) :: [ReqLLM.Tool.t()]
  def to_tool_schemas(skills) do
    Enum.map(skills, &skill_to_tool/1)
  end

  defp skill_to_tool(%Skill{} = skill) do
    props =
      Map.new(skill.parameters, fn param ->
        prop = %{
          "type" => param.type,
          "description" => param.description
        }

        prop =
          if Map.has_key?(param, :default) do
            Map.put(prop, "default", param.default)
          else
            prop
          end

        {param.name, prop}
      end)

    required =
      skill.parameters
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)

    ReqLLM.tool(
      name: skill.name,
      description: skill.description,
      parameter_schema: %{
        "type" => "object",
        "properties" => props,
        "required" => required
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  # ---------------------------------------------------------------------------
  # Skill Lookup
  # ---------------------------------------------------------------------------

  @doc """
  Finds a skill by name from a list of skills.
  """
  @spec find_skill([Skill.t()], String.t()) :: Skill.t() | nil
  def find_skill(skills, name) do
    Enum.find(skills, &(&1.name == name))
  end

  @doc """
  Returns all skill names from a list of skills.
  """
  @spec skill_names([Skill.t()]) :: [String.t()]
  def skill_names(skills) do
    Enum.map(skills, & &1.name)
  end

  # ---------------------------------------------------------------------------
  # Delegation Wrappers — Executor
  # ---------------------------------------------------------------------------

  @doc """
  Executes a skill with the given arguments.

  Delegates to `EvoGit.Skills.Executor.execute/4`.
  """
  @spec execute([Skill.t()], String.t(), map(), String.t()) :: String.t()
  defdelegate execute(skills, skill_name, args, repo_path), to: Executor

  @doc """
  Extracts the first ```bash code block from markdown content.
  Delegates to `EvoGit.Skills.Executor.extract_bash_block/1`.
  """
  defdelegate extract_bash_block(markdown), to: Executor

  @doc """
  Substitutes `{{param_name}}` placeholders in a script with actual argument values.
  Delegates to `EvoGit.Skills.Executor.substitute_params/3`.
  """
  defdelegate substitute_params(script, parameters, args), to: Executor

  # ---------------------------------------------------------------------------
  # Delegation Wrappers — CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new skill file in `.agents/skills/`.

  Delegates to `EvoGit.Skills.CRUD.add_skill/4`.
  """
  @spec add_skill(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate add_skill(repo_root, content, description, params), to: CRUD

  @doc """
  Updates an existing skill file by name.

  Delegates to `EvoGit.Skills.CRUD.edit_skill/3`.
  """
  @spec edit_skill(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate edit_skill(repo_root, name, new_content), to: CRUD

  @doc """
  Removes a skill file by name.

  Delegates to `EvoGit.Skills.CRUD.remove_skill/2`.
  """
  @spec remove_skill(String.t(), String.t()) :: :ok | {:error, String.t()}
  defdelegate remove_skill(repo_root, name), to: CRUD

  @doc """
  Lists all available skills with their names and descriptions.

  Delegates to `EvoGit.Skills.CRUD.list_skills/1`.
  """
  @spec list_skills(String.t()) :: String.t()
  defdelegate list_skills(repo_root), to: CRUD

  @doc """
  Reads a skill file's full content by name.

  Delegates to `EvoGit.Skills.CRUD.read_skill/2`.
  """
  @spec read_skill(String.t(), String.t()) :: String.t()
  defdelegate read_skill(repo_root, name), to: CRUD

  @doc """
  Validates that a skill body text will produce a valid skill when parsed.

  Delegates to `EvoGit.Skills.CRUD.validate_skill_text/1`.
  """
  defdelegate validate_skill_text(content), to: CRUD

  # ---------------------------------------------------------------------------
  # Delegation Wrappers — ContextIntegration
  # ---------------------------------------------------------------------------

  @doc """
  Parses a CONTEXT.md file's YAML front matter to extract the `skill` field.

  Delegates to `EvoGit.Skills.ContextIntegration.extract_context_skill_names/1`.
  """
  @spec extract_context_skill_names(String.t()) :: [String.t()]
  defdelegate extract_context_skill_names(content), to: ContextIntegration

  @doc """
  Strips the YAML front matter from a CONTEXT.md content string.

  Delegates to `EvoGit.Skills.ContextIntegration.strip_front_matter/1`.
  """
  @spec strip_front_matter(String.t()) :: String.t()
  defdelegate strip_front_matter(content), to: ContextIntegration

  @doc """
  Reads the CONTEXT.md file at the given absolute directory path and extracts
  the enabled skill names from its YAML front matter.

  Delegates to `EvoGit.Skills.ContextIntegration.skill_names_at_dir/1`.
  """
  @spec skill_names_at_dir(String.t()) :: [String.t()]
  defdelegate skill_names_at_dir(abs_dir), to: ContextIntegration

  @doc """
  Walks the hierarchy from the repository root down to `relative_path` and
  collects all skill names enabled at each level.

  Delegates to `EvoGit.Skills.ContextIntegration.hierarchical_skill_names/2`.
  """
  @spec hierarchical_skill_names(String.t(), String.t()) :: [String.t()]
  defdelegate hierarchical_skill_names(relative_path, repo_path), to: ContextIntegration

  @doc """
  Filters a list of skills to only include those whose names appear in `names`.

  Delegates to `EvoGit.Skills.ContextIntegration.filter_skills/2`.
  """
  @spec filter_skills([Skill.t()], [String.t()]) :: [Skill.t()]
  defdelegate filter_skills(skills, names), to: ContextIntegration

  @doc """
  Searches all CONTEXT.md files in the repository to find which nodes have a
  given skill enabled.

  Delegates to `EvoGit.Skills.ContextIntegration.where_enabled/2`.
  """
  @spec where_enabled(String.t(), String.t()) :: [String.t()]
  defdelegate where_enabled(skill_name, repo_root), to: ContextIntegration

  @doc """
  Enables a skill at a specific node level by adding it to the CONTEXT.md
  YAML front matter's `skill` list.

  Delegates to `EvoGit.Skills.ContextIntegration.enable_skill/3`.
  """
  @spec enable_skill(String.t(), String.t(), String.t()) ::
          {:ok, :already_enabled_here}
          | {:ok, :already_enabled_above, String.t()}
          | {:ok, :enabled, String.t()}
          | {:error, String.t()}
  defdelegate enable_skill(skill_name, node_path, repo_path), to: ContextIntegration

  @doc """
  Disables a skill at a specific node level by removing it from the CONTEXT.md
  YAML front matter's `skill` list.

  Delegates to `EvoGit.Skills.ContextIntegration.disable_skill/3`.
  """
  @spec disable_skill(String.t(), String.t(), String.t()) ::
          {:ok, :disabled, String.t()} | {:ok, :not_enabled} | {:error, String.t()}
  defdelegate disable_skill(skill_name, node_path, repo_path), to: ContextIntegration

  @doc """
  Removes all references to a skill name from all CONTEXT.md files in the
  repository.

  Delegates to `EvoGit.Skills.ContextIntegration.remove_skill_from_all_contexts/2`.
  """
  @spec remove_skill_from_all_contexts(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  defdelegate remove_skill_from_all_contexts(skill_name, repo_root), to: ContextIntegration

  # ---------------------------------------------------------------------------
  # YAML Frontmatter Parser
  # ---------------------------------------------------------------------------

  @doc """
  Parses YAML frontmatter from markdown content.

  Expects content to start with:
      ---
      key: value
      parameters:
        - name: param1
          type: string
          ...
      ---
      body content...

  Returns `{:ok, metadata_map, body}` or `{:error, reason}`.
  """
  def parse_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n(.*)\z/s, content) do
      [_, yaml_str, body] ->
        case parse_yaml_simple(String.trim(yaml_str)) do
          {:ok, metadata} -> {:ok, metadata, String.trim(body)}
          {:error, _} = error -> error
        end

      nil ->
        # Try with just --- at start (no closing ---)
        case Regex.run(~r/\A---\s*\n(.*)\z/s, content) do
          [_, _rest] ->
            # No frontmatter found; treat entire content as body
            {:ok, %{}, String.trim(content)}

          nil ->
            {:ok, %{}, String.trim(content)}
        end
    end
  end

  @doc """
  Parses a simple YAML subset sufficient for skill frontmatter.

  Supports:
  - `key: value` (string scalars)
  - `parameters:` followed by list items with `- name: value` sub-maps

  Returns `{:ok, map}` where map has string keys.
  """
  def parse_yaml_simple(yaml_str) do
    YamlElixir.read_from_string(yaml_str)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Delegates to CRUD.filename_to_name/1 so that parse_skill_file/1 still works
  # without a compile-time circular dependency on the CRUD module.
  defp filename_to_name(file_path) do
    CRUD.filename_to_name(file_path)
  end

  defp normalize_parameters(params) when is_list(params) do
    Enum.map(params, fn param ->
      %{
        name: Map.get(param, "name", "unknown"),
        type: Map.get(param, "type", "string"),
        description: Map.get(param, "description", ""),
        required: Map.get(param, "required", false),
        default: Map.get(param, "default", nil)
      }
      |> then(fn p -> if is_nil(p.default), do: Map.drop(p, [:default]), else: p end)
    end)
  end

  defp normalize_parameters(_), do: []
end
