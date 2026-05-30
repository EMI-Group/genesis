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
  """

  alias EvoGit.Skills.Skill

  @skills_dir ".agents/skills"

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
    skills_path = Path.join(repo_root, @skills_dir)

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
  Loads skills available at the given node path by checking the hierarchy
  of CONTEXT.md files from root to the node for declared skills.

  Returns only those skills whose names appear in the `skills` field of
  at least one CONTEXT.md along the hierarchy path.
  """
  @spec load_hierarchical_skills(String.t(), String.t()) :: [Skill.t()]
  def load_hierarchical_skills(repo_root, node_path) do
    all_skills = load_skills(repo_root)

    case EvoGit.Core.ContextNode.get_hierarchy_skills(node_path, repo_root) do
      {:ok, allowed_names} ->
        if Enum.empty?(allowed_names) do
          []
        else
          allowed_set = MapSet.new(allowed_names)
          Enum.filter(all_skills, fn skill -> MapSet.member?(allowed_set, skill.name) end)
        end

      {:error, _} ->
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

  @doc """
  Validates that a skill body text will produce a valid skill when parsed.
  Used by management tools to preview/validate before writing.
  """
  def validate_skill_text(content) when is_binary(content) do
    case parse_frontmatter(content) do
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
  # Skill Execution
  # ---------------------------------------------------------------------------

  @doc """
  Executes a skill with the given arguments.

  1. Finds the skill in the loaded list
  2. Extracts the bash code block from the skill body
  3. Substitutes `{{param}}` placeholders with actual values
  4. Executes the script via bash
  5. Returns stdout/stderr

  If no bash code block is found, returns the skill body as a text result
  (the agent can use it as instructions).
  """
  @spec execute([Skill.t()], String.t(), map(), String.t()) :: String.t()
  def execute(skills, skill_name, args, repo_path) do
    case find_skill(skills, skill_name) do
      nil ->
        "Error: Skill '#{skill_name}' not found. Available skills: #{inspect(skill_names(skills))}"

      skill ->
        execute_skill(skill, args, repo_path)
    end
  end

  defp execute_skill(%Skill{body: body, parameters: params}, args, repo_path) do
    case extract_bash_block(body) do
      nil ->
        # No bash block — return the body text as instructions
        "Skill '#{skill_name(args)}' instructions:\n\n#{body}"

      script ->
        substituted = substitute_params(script, params, args)
        run_script(substituted, repo_path)
    end
  end

  defp skill_name(_args), do: ""  # Placeholder, not used

  @doc """
  Extracts the first ```bash code block from markdown content.
  Returns nil if no bash block is found.
  """
  def extract_bash_block(markdown) do
    case Regex.run(~r/```bash\s*\n(.*?)```/s, markdown) do
      [_, code] -> String.trim(code)
      nil -> nil
    end
  end

  @doc """
  Substitutes `{{param_name}}` placeholders in a script with actual argument values.

  Missing parameters are replaced with empty strings.
  """
  def substitute_params(script, parameters, args) do
    Enum.reduce(parameters, script, fn param, acc ->
      value = get_param_value(param, args)
      String.replace(acc, "{{#{param.name}}}", value)
    end)
  end

  defp get_param_value(param, args) do
    case Map.fetch(args, param.name) do
      {:ok, value} ->
        to_string(value)

      :error ->
        if Map.has_key?(param, :default) do
          to_string(param.default)
        else
          ""
        end
    end
  end

  defp run_script(script, repo_path) do
    tmp_file = Path.join(System.tmp_dir!(), "evogit_skill_#{System.unique_integer()}.sh")

    try do
      File.write!(tmp_file, script)
      File.chmod!(tmp_file, 0o755)

      case System.cmd("bash", [tmp_file], cd: repo_path, stderr_to_stdout: true, parallelism: false) do
        {output, 0} ->
          "Skill executed successfully:\n#{String.trim(output)}"

        {output, exit_code} ->
          "Skill failed with exit code #{exit_code}:\n#{String.trim(output)}"
      end
    rescue
      e in RuntimeError ->
        "Error executing skill: #{Exception.message(e)}"
    after
      File.rm(tmp_file)
    end
  end

  # ---------------------------------------------------------------------------
  # Skill Management (CRUD)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new skill file in `.agents/skills/`.

  Returns `{:ok, file_path}` on success, `{:error, reason}` on failure.
  """
  @spec add_skill(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def add_skill(repo_root, content, _description, _params) do
    # Validate the skill content
    case validate_skill_text(content) do
      {:ok, _name} ->
        # Extract the name to determine filename
        {:ok, metadata, _body} = parse_frontmatter(content)
        name = Map.get(metadata, "name")
        filename = skill_filename(name)
        skills_path = ensure_skills_dir(repo_root)
        file_path = Path.join(skills_path, filename)

        if File.exists?(file_path) do
          {:error, "Skill '#{name}' already exists at #{file_path}"}
        else
          case File.write(file_path, content) do
            :ok -> {:ok, file_path}
            {:error, reason} -> {:error, "Failed to write skill file: #{:file.format_error(reason)}"}
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
    repo_root
    |> load_skills()
    |> list_skills_from()
  end

  @doc """
  Lists skills from a pre-loaded list of skills.
  """
  @spec list_skills_from([Skill.t()]) :: String.t()
  def list_skills_from(skills) do
    if Enum.empty?(skills) do
      "No skills available at your current context level. Skills are declared via the `skills` field in CONTEXT.md front matter."
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

      "Available skills at your current context level:\n\n#{Enum.join(lines, "\n\n")}"
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

  @doc """
  Reads a skill file's full content by name from a pre-loaded skills list.
  """
  @spec read_skill_from([Skill.t()], String.t()) :: String.t()
  def read_skill_from(skills, name) do
    case find_skill(skills, name) do
      nil ->
        "Error: Skill '#{name}' not found or not available at your current context level."

      skill ->
        case File.read(skill.file_path) do
          {:ok, content} -> content
          {:error, reason} -> "Error reading skill '#{name}': #{:file.format_error(reason)}"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp ensure_skills_dir(repo_root) do
    skills_path = Path.join(repo_root, @skills_dir)
    File.mkdir_p!(skills_path)
    skills_path
  end

  defp skill_filename(name) do
    "#{name}.md"
  end

  defp filename_to_name(file_path) do
    file_path
    |> Path.basename(".md")
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp find_skill_file(skills_path, name) do
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
