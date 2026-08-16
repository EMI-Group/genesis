defmodule EvoGit.CustomAgents do
  @moduledoc """
  Manages user-defined custom agents as a TOML file store.

  Custom agent definitions are persisted to `<config_dir>/agents.toml`
  (the same directory as `config.toml`, resolved by `EvoGit.Config.config_dir/0`)
  as an array-of-tables (`[[agents]]`), plus an optional `[model_selection]`
  section holding an Elixir script used for runtime model picking.

  This module is a collection of **pure functions** — it is NOT a GenServer.
  Every call reads from / writes to the TOML file directly (fresh per call —
  "reload-friendly"; nothing is cached in this module).

  ## TOML format

  ```toml
  [model_selection]
  script = \"\"\"...elixir...\"\"\"

  [[agents]]
  name = "Code Reviewer"          # human name (required)
  description = "Reviews code"    # optional
  prompt = "You are..."           # system prompt (required)
  agent_type = "read"             # optional: "read" | "read_write" (default "read_write")
  delegation_level = "low"        # optional: "high" | "low" (default "low")
  model_id = "gpt-5"              # optional: default model PROFILE id (nil = auto/default)
  max_turns = 40                  # optional: per-agent turn cap override
  tools = ["read_file", "run_bash"] # optional whitelist; absent = all standard tools
  subagents = ["executor", "investigator"] # optional built-in type names this agent may spawn
  ```

  ## Agent fields

  | Field | Type | Required | Default | Description |
  |---|---|---|---|---|
  | `id` | string | no | auto-generated | Unique identifier — auto-generated from `name` (slugified, max 40 chars) when omitted in the file; explicit ids are respected |
  | `name` | string | **yes** | — | Human name |
  | `description` | string | no | `nil` | Free-form description |
  | `prompt` | string | **yes** | — | System prompt |
  | `agent_type` | `:read` \| `:read_write` | no | `:read_write` | Read-only vs read-write capability |
  | `delegation_level` | `:high` \| `:low` | no | `:low` | Subagent delegation level |
  | `model_id` | string | no | `nil` | Default model PROFILE id (`nil` = auto/default) |
  | `max_turns` | pos_integer | no | `nil` | Per-agent turn cap override |
  | `tools` | [string] | no | `nil` | Tool whitelist; absent = all standard tools |
  | `subagents` | [string] | no | `[]` | Built-in agent type names this agent may spawn |

  Agent maps use **atom keys** internally; keys are stringified only when
  serialized to TOML. `agent_type`/`delegation_level` are normalized from TOML
  strings to atoms on read (`"read"` → `:read`); unknown values are left
  as-is on read and rejected by `save/1`. Unknown keys are ignored.

  The `[model_selection]` section is **always preserved** by agent saves and
  deletes — only the `agents` array is modified.
  """

  require Logger

  @config_filename "agents.toml"

  # Maps TOML string keys to atoms for the known agent schema. Unknown
  # keys are left as strings so we never raise on unexpected data.
  @key_map %{
    "id" => :id,
    "name" => :name,
    "description" => :description,
    "prompt" => :prompt,
    "agent_type" => :agent_type,
    "delegation_level" => :delegation_level,
    "model_id" => :model_id,
    "max_turns" => :max_turns,
    "tools" => :tools,
    "subagents" => :subagents
  }

  @non_alnum_re ~r/[^a-z0-9]+/
  @trim_underscore_re ~r/(?:^_+|_+$)/

  @type t :: map()

  # --- Public API ---

  @doc """
  Returns the full path to the custom agents TOML file.
  """
  @spec path() :: String.t()
  def path do
    Path.join(EvoGit.Config.config_dir(), @config_filename)
  end

  @doc """
  Lists all stored custom agent definitions.

  Reads the TOML file and returns a list of atom-keyed definition maps.
  Returns `[]` if the file does not exist or is empty, or if the `agents`
  key is absent / not a list.

  Reading is lenient: entries are not validated (an unknown `agent_type`
  string is returned as-is) — only `save/1` enforces validation.

  If the custom agents file does not exist yet, a skeleton file is created
  silently (no warning is logged for the normal "no file yet" case).
  """
  @spec list() :: [map()]
  def list do
    unless File.exists?(path()) do
      ensure_file()
      []
    else
      data = EvoGit.Config.read_toml_file(path(), %{}, description: "custom agents")

      case Map.get(data, "agents") do
        agents when is_list(agents) ->
          agents
          |> Enum.filter(&is_map/1)
          |> Enum.map(&atomize_agent/1)
          |> Enum.map(&normalize_definition/1)
          |> derive_ids()

        _ ->
          []
      end
    end
  end

  @doc """
  Fetches a single custom agent definition by its id.

  Returns the atom-keyed definition map, or `nil` when no agent has that id.
  """
  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Enum.find(list(), fn agent -> agent.id == id end)
  end

  @doc """
  Saves a custom agent definition, creating or updating it (upsert by id).

  When `:id` is absent, it is auto-generated by slugifying `:name` (max 40
  chars). Saving a definition with an **explicit** id updates the existing
  agent with that id; saving one **without** an id whose generated id
  collides with an existing agent returns `{:error, :duplicate_id}`.

  Validation errors (returned as `{:error, atom}`):

    * `:missing_name` — `:name` is nil or empty
    * `:missing_prompt` — `:prompt` is nil or empty
    * `:invalid_agent_type` — `:agent_type` is neither `:read`/`:read_write`
      (atom or string `"read"`/`"read_write"`) nor nil
    * `:invalid_delegation_level` — `:delegation_level` is neither
      `:high`/`:low` (atom or string) nor nil
    * `:invalid_max_turns` — `:max_turns` present but non-integer or
      non-positive
    * `:invalid_tools` — `:tools` present but not a list of strings
    * `:invalid_subagents` — `:subagents` present but not a list of strings

  Unknown keys are ignored. The `[model_selection]` section is preserved.

  Returns `{:ok, definition}` on success.
  """
  @spec save(map()) :: {:ok, map()} | {:error, atom()}
  def save(agent) when is_map(agent) do
    conn = atomize_agent(agent)

    with :ok <- validate(conn) do
      name = Map.get(conn, :name)

      case Map.get(conn, :id) do
        id when is_binary(id) and id != "" ->
          upsert(normalize_definition(Map.put(conn, :id, id)))

        _ ->
          generated_id = slugify(name)
          existing = list()

          if Enum.any?(existing, fn a -> a.id == generated_id end) do
            {:error, :duplicate_id}
          else
            normalized = normalize_definition(Map.put(conn, :id, generated_id))

            case write_agents(existing ++ [normalized]) do
              :ok -> {:ok, normalized}
              {:error, reason} -> {:error, reason}
            end
          end
      end
    end
  end

  @doc """
  Deletes the custom agent definition with the given id.

  Returns `:ok` on success, or `{:error, :not_found}` if no agent has that
  id. The `[model_selection]` section is preserved.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) when is_binary(id) do
    agents = list()

    if Enum.any?(agents, fn a -> a.id == id end) do
      updated = Enum.reject(agents, fn a -> a.id == id end)

      case write_agents(updated) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns the `[model_selection]` script string.

  Returns `nil` when the section/key is absent or the script is empty.
  """
  @spec model_selection_script() :: String.t() | nil
  def model_selection_script do
    case read_data() do
      %{"model_selection" => %{"script" => script}} when is_binary(script) ->
        if script == "", do: nil, else: script

      _ ->
        nil
    end
  end

  @doc """
  Sets (or replaces) the `[model_selection]` script.

  An empty string removes the `script` key. The `[[agents]]` array is
  preserved. Returns `:ok` on success, `{:error, reason}` on write failure.
  """
  @spec save_model_selection_script(String.t()) :: :ok | {:error, term()}
  def save_model_selection_script(script) when is_binary(script) do
    data = read_data()

    model_selection =
      case Map.get(data, "model_selection") do
        ms when is_map(ms) -> ms
        _ -> %{}
      end

    model_selection =
      if script == "" do
        Map.delete(model_selection, "script")
      else
        Map.put(model_selection, "script", script)
      end

    data =
      if map_size(model_selection) == 0 do
        Map.delete(data, "model_selection")
      else
        Map.put(data, "model_selection", model_selection)
      end

    write_data(data)
  end

  @doc """
  Invalidates the compile cache of `EvoGit.CustomAgents.ModelSelector`.

  Always returns `:ok`. The invalidation call is guarded with
  `Code.ensure_loaded?/1` + `function_exported?/3` so this module compiles
  and runs even before `EvoGit.CustomAgents.ModelSelector` exists.
  """
  @spec reload() :: :ok
  def reload do
    if Code.ensure_loaded?(EvoGit.CustomAgents.ModelSelector) and
         function_exported?(EvoGit.CustomAgents.ModelSelector, :invalidate, 0) do
      # apply/3 keeps this warning-free while ModelSelector has not landed yet
      # (guarded by ensure_loaded? + function_exported? above).
      apply(EvoGit.CustomAgents.ModelSelector, :invalidate, [])
    end

    :ok
  end

  # --- Private Helpers ---

  @skeleton_toml """
  # Genesis Custom Agents
  # Define user-defined agents below as [[agents]] entries and, optionally,
  # a [model_selection] section with an Elixir script for model picking.
  # See documentation for field descriptions.
  """

  # Creates a skeleton custom agents TOML file if it doesn't exist.
  # This prevents a misleading "Failed to read custom agents" warning
  # on first access — no file is the normal/expected initial state.
  defp ensure_file do
    dir = EvoGit.Config.config_dir()
    file_path = path()

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(file_path, @skeleton_toml, [:write]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to create custom agents file at #{file_path}: #{inspect(reason)}")

        :error
    end
  end

  # Reads the raw (string-keyed) TOML data from disk. Missing file is the
  # normal initial state — returns %{} without logging a warning.
  defp read_data do
    if File.exists?(path()) do
      EvoGit.Config.read_toml_file(path(), %{}, description: "custom agents")
    else
      %{}
    end
  end

  # Writes raw (string-keyed) TOML data to disk, preserving whatever other
  # sections the data map carries (e.g. [model_selection]).
  defp write_data(data) do
    dir = EvoGit.Config.config_dir()

    result =
      with :ok <- File.mkdir_p(dir),
           {:ok, toml} <- TomlElixir.encode(data) do
        File.write(path(), toml)
      end

    case result do
      {:error, reason} ->
        Logger.warning("Failed to write custom agents file at #{path()}: #{inspect(reason)}")
        {:error, reason}

      other ->
        other
    end
  end

  # Serializes the agent list to TOML and writes it to disk, preserving the
  # current [model_selection] section (only the agents array is modified).
  defp write_agents(agents) do
    read_data()
    |> Map.put("agents", Enum.map(agents, &stringify_keys/1))
    |> write_data()
  end

  # Upserts a normalized definition by its (explicit) id.
  defp upsert(normalized) do
    existing = list()

    updated =
      if Enum.any?(existing, fn a -> a.id == normalized.id end) do
        Enum.map(existing, fn a -> if a.id == normalized.id, do: normalized, else: a end)
      else
        existing ++ [normalized]
      end

    case write_agents(updated) do
      :ok -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  # Validates a raw (atomized) agent map. Returns :ok or {:error, atom}.
  defp validate(agent) do
    name = Map.get(agent, :name)
    prompt = Map.get(agent, :prompt)

    cond do
      is_nil(name) or name == "" ->
        {:error, :missing_name}

      is_nil(prompt) or prompt == "" ->
        {:error, :missing_prompt}

      not valid_agent_type?(Map.get(agent, :agent_type)) ->
        {:error, :invalid_agent_type}

      not valid_delegation_level?(Map.get(agent, :delegation_level)) ->
        {:error, :invalid_delegation_level}

      not valid_max_turns?(Map.get(agent, :max_turns)) ->
        {:error, :invalid_max_turns}

      not valid_string_list?(Map.get(agent, :tools)) ->
        {:error, :invalid_tools}

      not valid_string_list?(Map.get(agent, :subagents)) ->
        {:error, :invalid_subagents}

      true ->
        :ok
    end
  end

  defp valid_agent_type?(nil), do: true
  defp valid_agent_type?(value) when value in [:read, :read_write], do: true
  defp valid_agent_type?(value) when value in ["read", "read_write"], do: true
  defp valid_agent_type?(_), do: false

  defp valid_delegation_level?(nil), do: true
  defp valid_delegation_level?(value) when value in [:high, :low], do: true
  defp valid_delegation_level?(value) when value in ["high", "low"], do: true
  defp valid_delegation_level?(_), do: false

  defp valid_max_turns?(nil), do: true
  defp valid_max_turns?(value), do: is_integer(value) and value > 0

  defp valid_string_list?(nil), do: true
  defp valid_string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  # Normalizes a raw agent map (atom keys) into a fully-populated definition
  # with all defaults applied. Unknown keys are dropped.
  defp normalize_definition(agent) do
    %{
      id: Map.get(agent, :id),
      name: Map.get(agent, :name),
      description: Map.get(agent, :description),
      prompt: Map.get(agent, :prompt),
      agent_type: normalize_agent_type(Map.get(agent, :agent_type)),
      delegation_level: normalize_delegation_level(Map.get(agent, :delegation_level)),
      model_id: Map.get(agent, :model_id),
      max_turns: Map.get(agent, :max_turns),
      tools: Map.get(agent, :tools),
      subagents: Map.get(agent, :subagents) || []
    }
  end

  # Known values are normalized to atoms; nil gets the default; unknown
  # values are left as-is (list/0 is lenient — save/1 validation rejects them).
  defp normalize_agent_type(nil), do: :read_write
  defp normalize_agent_type(value) when value in [:read, :read_write], do: value
  defp normalize_agent_type("read"), do: :read
  defp normalize_agent_type("read_write"), do: :read_write
  defp normalize_agent_type(other), do: other

  defp normalize_delegation_level(nil), do: :low
  defp normalize_delegation_level(value) when value in [:high, :low], do: value
  defp normalize_delegation_level("high"), do: :high
  defp normalize_delegation_level("low"), do: :low
  defp normalize_delegation_level(other), do: other

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.replace(@non_alnum_re, "_")
    |> String.replace(@trim_underscore_re, "")
    |> String.slice(0, 40)
  end

  # Derives ids for definitions read WITHOUT one (hand-authored TOML entries),
  # so every agent is addressable by id. Explicit ids are never modified and
  # definitions keep their original order. A missing id is slugified from the
  # name (falling back to "agent_N" when the name slugifies to ""), and
  # collisions with already-assigned ids get a deterministic "_2", "_3", ...
  # suffix (first occurrence keeps the plain id). A warning is logged for each
  # derivation so users learn ids come from names.
  defp derive_ids(agents) do
    {derived, _assigned} =
      agents
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {agent, index}, assigned ->
        case Map.get(agent, :id) do
          id when is_binary(id) and id != "" ->
            {agent, MapSet.put(assigned, id)}

          _ ->
            id = derive_unique_id(agent, index, assigned)

            Logger.warning(
              "Custom agent #{inspect(Map.get(agent, :name))} in agents.toml has no id — " <>
                "derived \"#{id}\" from its name"
            )

            {Map.put(agent, :id, id), MapSet.put(assigned, id)}
        end
      end)

    derived
  end

  # Computes a unique id for a definition that has none: slugified name
  # (max 40 chars), "agent_N" fallback for missing/empty names or names that
  # slugify to "", and a deterministic "_2", "_3", ... suffix when the base
  # id collides with an already-assigned id.
  defp derive_unique_id(agent, index, assigned) do
    base =
      case Map.get(agent, :name) do
        name when is_binary(name) ->
          case slugify(name) do
            "" -> "agent_#{index + 1}"
            slug -> slug
          end

        _ ->
          "agent_#{index + 1}"
      end

    if MapSet.member?(assigned, base) do
      Enum.reduce_while(Stream.iterate(2, &(&1 + 1)), nil, fn n, _acc ->
        candidate = "#{base}_#{n}"

        if MapSet.member?(assigned, candidate) do
          {:cont, nil}
        else
          {:halt, candidate}
        end
      end)
    else
      base
    end
  end

  # Converts a string-keyed agent map (as decoded from TOML) into an
  # atom-keyed map. Unknown string keys are left as-is.
  defp atomize_agent(agent) when is_map(agent) do
    Map.new(agent, fn
      {key, value} when is_binary(key) ->
        {Map.get(@key_map, key, key), value}

      {key, value} ->
        {key, value}
    end)
  end

  # Recursively converts atom keys to string keys and drops nil values.
  # Modeled on `stringify_keys/1` in EvoGit.Config.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(nil), do: nil
  defp stringify_keys(value), do: value
end
