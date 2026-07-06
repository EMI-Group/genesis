defmodule EvoGit.Skills.ContextIntegration do
  @moduledoc """
  Hierarchical skill management — enables/disables skills at Context Tree nodes
  via CONTEXT.md YAML frontmatter.

  Skills are globally defined in `.agents/skills/` but hierarchically enabled
  per node. Each CONTEXT.md may carry a `skill:` list in its frontmatter,
  inherited downward from root to leaf.
  """

  alias EvoGit.Skills
  alias EvoGit.Skills.Skill

  # ---------------------------------------------------------------------------
  # CONTEXT.md Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a CONTEXT.md file's YAML front matter to extract the `skill` field.

  Returns a list of skill name strings enabled at that context level.
  Returns an empty list if there is no front matter or no `skill` field.
  """
  @spec extract_context_skill_names(String.t()) :: [String.t()]
  def extract_context_skill_names(content) when is_binary(content) do
    case Skills.parse_frontmatter(content) do
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
    case Skills.parse_frontmatter(content) do
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

  # ---------------------------------------------------------------------------
  # Enable / Disable
  # ---------------------------------------------------------------------------

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

  @doc """
  Finds all CONTEXT.md files in a repository, excluding build/dependency
  directories. Returns a list of `{absolute_dir, content}` tuples.
  """
  def find_all_context_files(repo_root) do
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

  @doc """
  Walks up the Context Tree hierarchy from root to (but not including)
  `node_path`, looking for a node that has the given skill enabled.
  Returns the relative path of the first matching ancestor, or nil.
  """
  def find_skill_node(skill_name, node_path, repo_path) do
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

  @doc """
  Adds a skill name to a node's CONTEXT.md frontmatter.
  If CONTEXT.md doesn't exist, creates one with just the frontmatter.
  """
  def add_skill_to_context_frontmatter(skill_name, abs_dir, current_skills) do
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

  @doc """
  Removes a skill name from a node's CONTEXT.md frontmatter by rebuilding
  the frontmatter without it.
  """
  def remove_skill_from_context_frontmatter(skill_name, abs_dir, current_skills) do
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

  @doc """
  Merges a skill name into a CONTEXT.md file's frontmatter, preserving
  other frontmatter keys.
  """
  def merge_skill_into_frontmatter(content, skill_name, _current_skills) do
    case Skills.parse_frontmatter(content) do
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

  @doc """
  Replaces the skill list in a CONTEXT.md file's frontmatter with a new list,
  preserving other frontmatter keys.
  """
  def replace_skill_list_in_frontmatter(content, new_skills) do
    case Skills.parse_frontmatter(content) do
      {:ok, metadata, body} ->
        build_frontmatter_content(new_skills, metadata, body)

      {:error, _} ->
        content
    end
  end

  @doc """
  Builds a CONTEXT.md content string from a skill list and existing metadata,
  preserving non-skill frontmatter keys.
  """
  def build_frontmatter_content(new_skills, metadata, body) do
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
        acc ++ [yaml_kv(key, value)]
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

  @doc """
  Converts a key-value pair to a YAML line.
  For list values, emits `key:` followed by `  - item` lines.
  For scalar values, emits `key: value`.
  """
  def yaml_kv(key, value) when is_list(value) do
    ("#{key}:" <> Enum.map(value, fn v -> "\n  - #{v}" end)) |> Enum.join()
  end

  def yaml_kv(key, value) do
    "#{key}: #{value}"
  end
end
