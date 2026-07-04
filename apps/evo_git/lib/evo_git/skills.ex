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

  # Placeholder, not used
  defp skill_name(_args), do: ""

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

    result =
      with :ok <- File.write(tmp_file, script),
           :ok <- File.chmod(tmp_file, 0o755) do
        case System.cmd("bash", [tmp_file],
               cd: repo_path,
               stderr_to_stdout: true,
               parallelism: false
             ) do
          {output, 0} ->
            "Skill executed successfully:\n#{String.trim(output)}"

          {output, exit_code} ->
            "Skill failed with exit code #{exit_code}:\n#{String.trim(output)}"
        end
      else
        {:error, reason} ->
          "Error setting up skill script at #{tmp_file}: #{:file.format_error(reason)}"
      end

    File.rm(tmp_file)
    result
  end

  # ---------------------------------------------------------------------------
  # Skill Management (CRUD)
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
        {:ok, metadata, _body} = parse_frontmatter(content)
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
    skills = load_skills(repo_root)

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

  # ---------------------------------------------------------------------------
  # Hierarchical Skill Management (Spatial Dimension)
  # ---------------------------------------------------------------------------

  @doc """
  Parses a CONTEXT.md file's YAML front matter to extract the `skill` field.

  Returns a list of skill name strings enabled at that context level.
  Returns an empty list if there is no front matter or no `skill` field.
  """
  @spec extract_context_skill_names(String.t()) :: [String.t()]
  def extract_context_skill_names(content) when is_binary(content) do
    case parse_frontmatter(content) do
      {:ok, metadata, _body} ->
        skills = Map.get(metadata, "skill", [])
        if is_list(skills), do: Enum.map(skills, &to_string/1), else: []

      {:error, _} ->
        []
    end
  end

  @doc """
  Strips the YAML front matter from a CONTEXT.md content string, returning
  only the body. If there is no front matter, returns the content unchanged.
  """
  @spec strip_front_matter(String.t()) :: String.t()
  def strip_front_matter(content) when is_binary(content) do
    case parse_frontmatter(content) do
      {:ok, _metadata, body} -> body
      {:error, _} -> content
    end
  end

  @doc """
  Reads the CONTEXT.md file at the given absolute directory path and extracts
  the enabled skill names from its YAML front matter.

  Returns `[String.t()]` — possibly empty if no CONTEXT.md, no front matter,
  or no `skill` field.
  """
  @spec skill_names_at_dir(String.t()) :: [String.t()]
  def skill_names_at_dir(abs_dir) when is_binary(abs_dir) do
    context_path = Path.join(abs_dir, "CONTEXT.md")

    case File.read(context_path) do
      {:ok, content} -> extract_context_skill_names(content)
      {:error, _} -> []
    end
  end

  @doc """
  Walks the hierarchy from the repository root down to `relative_path` and
  collects all skill names enabled at each level.

  Returns a deduplicated list of skill name strings inherited from root to node.
  """
  @spec hierarchical_skill_names(String.t(), String.t()) :: [String.t()]
  def hierarchical_skill_names(relative_path, repo_path)
      when is_binary(relative_path) and is_binary(repo_path) do
    case EvoGit.Core.ContextNode.hierarchy_nodes(relative_path, repo_path) do
      {:ok, nodes} ->
        nodes
        |> Enum.filter(fn node ->
          abs_path = Path.expand(node.path, node.repo)
          File.dir?(abs_path)
        end)
        |> Enum.flat_map(fn node ->
          abs_path = Path.expand(node.path, node.repo)
          skill_names_at_dir(abs_path)
        end)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  @doc """
  Filters a list of skills to only include those whose names appear in `names`.
  """
  @spec filter_skills([Skill.t()], [String.t()]) :: [Skill.t()]
  def filter_skills(skills, names) when is_list(skills) and is_list(names) do
    if Enum.empty?(names) do
      []
    else
      name_set = MapSet.new(names)
      Enum.filter(skills, fn skill -> MapSet.member?(name_set, skill.name) end)
    end
  end

  @doc """
  Searches all CONTEXT.md files in the repository to find which nodes have a
  given skill enabled.

  Returns a list of relative node paths (e.g., `["./", "./lib", "./apps/evo_git"]`).
  """
  @spec where_enabled(String.t(), String.t()) :: [String.t()]
  def where_enabled(skill_name, repo_root) when is_binary(skill_name) and is_binary(repo_root) do
    repo_root
    |> find_all_context_files()
    |> Enum.filter(fn {_abs_dir, content} ->
      skill_name in extract_context_skill_names(content)
    end)
    |> Enum.map(fn {abs_dir, _content} ->
      Path.relative_to(abs_dir, repo_root)
      |> then(fn
        "" -> "./"
        p -> "./" <> p
      end)
    end)
    |> Enum.sort()
  end

  @doc """
  Enables a skill at a specific node level by adding it to the CONTEXT.md
  YAML front matter's `skill` list.

  Checks if the skill is already enabled at this level or a higher level
  to avoid redundant entries.

  Returns:
  - `{:ok, :already_enabled_here}` — skill already in this node's front matter
  - `{:ok, :already_enabled_above, node_path}` — skill enabled at a higher level
  - `{:ok, :enabled, node_path}` — skill was added to this node's front matter
  - `{:error, reason}` — something went wrong
  """
  @spec enable_skill(String.t(), String.t(), String.t()) ::
          {:ok, :already_enabled_here}
          | {:ok, :already_enabled_above, String.t()}
          | {:ok, :enabled, String.t()}
          | {:error, String.t()}
  def enable_skill(skill_name, node_path, repo_path)
      when is_binary(skill_name) and is_binary(node_path) and is_binary(repo_path) do
    abs_dir = Path.expand(node_path, repo_path)

    unless File.dir?(abs_dir) do
      {:error, "Directory '#{node_path}' does not exist"}
    else
      # Check if already enabled at this level
      current_skills = skill_names_at_dir(abs_dir)

      if skill_name in current_skills do
        {:ok, :already_enabled_here}
      else
        # Check if already enabled at a higher level
        higher_skills = hierarchical_skill_names(node_path, repo_path)

        if skill_name in higher_skills do
          # Find which higher node it's enabled at
          case find_skill_node(skill_name, node_path, repo_path) do
            nil -> {:ok, :already_enabled_above, "./"}
            path -> {:ok, :already_enabled_above, path}
          end
        else
          # Add to this node's front matter
          case add_skill_to_context_frontmatter(skill_name, abs_dir, current_skills) do
            :ok -> {:ok, :enabled, node_path}
            {:error, reason} -> {:error, reason}
          end
        end
      end
    end
  end

  @doc """
  Disables a skill at a specific node level by removing it from the CONTEXT.md
  YAML front matter's `skill` list.

  Returns:
  - `{:ok, :disabled, node_path}` — skill removed from this node
  - `{:ok, :not_enabled}` — skill was not enabled at this node
  - `{:error, reason}` — something went wrong
  """
  @spec disable_skill(String.t(), String.t(), String.t()) ::
          {:ok, :disabled, String.t()} | {:ok, :not_enabled} | {:error, String.t()}
  def disable_skill(skill_name, node_path, repo_path)
      when is_binary(skill_name) and is_binary(node_path) and is_binary(repo_path) do
    abs_dir = Path.expand(node_path, repo_path)

    unless File.dir?(abs_dir) do
      {:error, "Directory '#{node_path}' does not exist"}
    else
      current_skills = skill_names_at_dir(abs_dir)

      if skill_name not in current_skills do
        {:ok, :not_enabled}
      else
        case remove_skill_from_context_frontmatter(skill_name, abs_dir, current_skills) do
          :ok -> {:ok, :disabled, node_path}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  Removes all references to a skill name from all CONTEXT.md files in the
  repository. Used when a skill file is being deleted.

  Returns `{:ok, count}` where count is the number of files modified.
  """
  @spec remove_skill_from_all_contexts(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def remove_skill_from_all_contexts(skill_name, repo_root)
      when is_binary(skill_name) and is_binary(repo_root) do
    context_files = find_all_context_files(repo_root)

    results =
      Enum.map(context_files, fn {abs_dir, content} ->
        current_skills = extract_context_skill_names(content)

        if skill_name in current_skills do
          case remove_skill_from_context_frontmatter(skill_name, abs_dir, current_skills) do
            :ok -> {:modified, abs_dir}
            {:error, _} -> :error
          end
        else
          :skipped
        end
      end)

    modified = Enum.count(results, fn r -> r != :skipped and r != :error end)
    {:ok, modified}
  end

  # ---------------------------------------------------------------------------
  # CONTEXT.md Front Matter Helpers
  # ---------------------------------------------------------------------------

  defp find_all_context_files(repo_root) do
    repo_root
    |> Path.join("**/CONTEXT.md")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      String.contains?(path, "/.genesis/") or
        String.contains?(path, "/.git/") or
        String.contains?(path, "/_build/") or
        String.contains?(path, "/deps/") or
        String.contains?(path, "/node_modules/")
    end)
    |> Enum.map(fn path ->
      abs_dir = Path.dirname(path)

      case File.read(path) do
        {:ok, content} -> {abs_dir, content}
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp find_skill_node(skill_name, node_path, repo_path) do
    case EvoGit.Core.ContextNode.hierarchy_nodes(node_path, repo_path) do
      {:ok, nodes} ->
        # Walk up from root to (but not including) node_path
        nodes
        |> Enum.filter(fn node ->
          abs_path = Path.expand(node.path, node.repo)
          File.dir?(abs_path)
        end)
        |> Enum.reject(fn node -> node.path == node_path end)
        |> Enum.find_value(fn node ->
          abs_path = Path.expand(node.path, node.repo)
          skills = skill_names_at_dir(abs_path)
          if skill_name in skills, do: node.path
        end)

      {:error, _} ->
        nil
    end
  end

  defp add_skill_to_context_frontmatter(skill_name, abs_dir, current_skills) do
    context_path = Path.join(abs_dir, "CONTEXT.md")

    case File.read(context_path) do
      {:ok, content} ->
        new_content = merge_skill_into_frontmatter(content, skill_name, current_skills)
        File.write(context_path, new_content)

      {:error, :enoent} ->
        # No CONTEXT.md exists — create one with just the front matter
        new_content = """
        ---
        skill:
          - #{skill_name}
        ---
        """

        File.write(context_path, new_content)

      {:error, reason} ->
        {:error, "Failed to read CONTEXT.md: #{:file.format_error(reason)}"}
    end
  end

  defp remove_skill_from_context_frontmatter(skill_name, abs_dir, current_skills) do
    context_path = Path.join(abs_dir, "CONTEXT.md")

    case File.read(context_path) do
      {:ok, content} ->
        new_skills = List.delete(current_skills, skill_name)
        new_content = replace_skill_list_in_frontmatter(content, new_skills)
        File.write(context_path, new_content)

      {:error, reason} ->
        {:error, "Failed to read CONTEXT.md: #{:file.format_error(reason)}"}
    end
  end

  defp merge_skill_into_frontmatter(content, skill_name, _current_skills) do
    case parse_frontmatter(content) do
      {:ok, metadata, body} ->
        existing_skills = Map.get(metadata, "skill", [])
        existing_skills = if is_list(existing_skills), do: existing_skills, else: []
        new_skills = existing_skills ++ [skill_name]
        build_frontmatter_content(new_skills, metadata, body)

      {:error, _} ->
        # Can't parse? Append as new front matter at top
        """
        ---
        skill:
          - #{skill_name}
        ---
        #{content}
        """
    end
  end

  defp replace_skill_list_in_frontmatter(content, new_skills) do
    case parse_frontmatter(content) do
      {:ok, metadata, body} ->
        build_frontmatter_content(new_skills, metadata, body)

      {:error, _} ->
        content
    end
  end

  defp build_frontmatter_content(new_skills, metadata, body) do
    # Build the YAML front matter preserving other keys
    other_keys = Map.drop(metadata, ["skill"])

    lines = ["---"]

    # Emit skill if non-empty
    lines =
      if Enum.empty?(new_skills) do
        lines
      else
        lines ++ ["skill:"] ++ Enum.map(new_skills, fn s -> "  - #{s}" end)
      end

    # Emit other keys
    lines =
      Enum.reduce(other_keys, lines, fn {key, value}, acc ->
        acc ++ [yaml_kv(key, value, 0)]
      end)

    # If we have no keys at all, don't write empty front matter
    if length(lines) == 1 and Enum.empty?(new_skills) and map_size(other_keys) == 0 do
      body
    else
      lines = lines ++ ["---"]
      yaml_str = Enum.join(lines, "\n")
      yaml_str <> "\n" <> body
    end
  end

  defp yaml_kv(key, value, _indent) when is_list(value) do
    ("#{key}:" <> Enum.map(value, fn v -> "\n  - #{v}" end)) |> Enum.join()
  end

  defp yaml_kv(key, value, _indent) do
    "#{key}: #{value}"
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
