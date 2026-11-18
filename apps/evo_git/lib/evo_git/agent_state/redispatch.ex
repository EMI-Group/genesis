defmodule EvoGit.AgentState.Redispatch do
  @moduledoc """
  The ONE owner of the normalized "how to rebuild this agent" blob.

  A durable agent-state row must survive the loss of every in-memory structure
  that produced the run. `build/2` projects a `%EvoGit.AgentSpec{}` plus the
  run/spawn facts the scheduler already knows into ONE STRING-keyed, JSON-clean
  map (persisted in the row's `redispatch` column), and `to_spec_opts/1` is its
  inverse: the keyword list a later resume phase feeds back into
  `EvoGit.AgentSpec.new/5` to rebuild the same agent.

  ## The key list is explicit and closed

  The blob contains EXACTLY these keys — nothing else ever leaks in:

      agent_type, delegation_level, tools, max_turns, custom_agent_id,
      model_spec, node_path, repo_id, objective, task_number, task_local_id,
      foreign_repos, quality_level, archive, repo_less, parent_id, depth,
      spawn_turn, spawn_index

  It is built by projection, never by `Map.from_struct/1`, so it can never
  carry a pid, a fun, credentials, provider options, request or generation
  parameters, a context node, a phylo node or a repo notes block. Values are
  run through a JSON normalizer that additionally drops anything that is not a
  string/atom/number/boolean/nil/list/plain map (a stray pid, ref, tuple or
  struct becomes `nil`), so `Jason.encode!/1` always succeeds.

  ## Precedence

  Facts (the second argument) describe the RUN and the SPAWN; the spec
  describes the AGENT. Per key:

    * **spec-owned** — `objective` and `repo_id` come from the spec struct;
      `foreign_repos` is the spec's list normalized to plain maps;
      `agent_type`/`delegation_level` come from the spec's `agent_module`
      callbacks; `max_turns` is the spec's `opts[:max_turns]` when positive.
    * **facts-first, spec fallback** — `custom_agent_id`, `model_spec`,
      `node_path`, `quality_level`, `archive`, `repo_less`, `parent_id` and
      `depth` are taken from the facts when present (they are the RESOLVED
      values of the run) and otherwise projected out of `spec.opts` (or
      `spec.model_spec` for the selection).
    * **facts-only** — `tools`, `task_number`, `task_local_id`, `spawn_turn`
      and `spawn_index` exist nowhere on the spec: they are resolved by the
      scheduler/session at registration and spawn time.

  `nil` means "unknown/absent"; `false` is a real value (an explicit
  `archive: false` is preserved, not treated as missing).

  ## Round-trip

  Every value survives `Jason.encode!/1` + `Jason.decode/1` unchanged in
  meaning: atoms are stored as their string form (`"read"`, `"low"`, …) and
  `to_spec_opts/1` turns the known role atoms back into atoms, so the opts of
  the JSON-decoded blob equal the opts of the live blob.
  """

  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo

  @doc """
  Builds the normalized re-dispatch blob for one agent run.

  `spec` is the agent's `%EvoGit.AgentSpec{}`; `facts` is a keyword list or map
  (atom- or string-keyed) carrying the run/spawn facts — see the moduledoc for
  the exact precedence of every key.

  Total: unknown keys in `facts` are ignored, and any value that is not
  JSON-representable is dropped rather than blowing up the caller.
  """
  @spec build(AgentSpec.t(), keyword() | map()) :: map()
  def build(%AgentSpec{} = spec, facts \\ []) do
    facts = facts_map(facts)

    %{
      "agent_type" => jsonify(prefer(spec_agent_type(spec), fact(facts, :agent_type))),
      "delegation_level" =>
        jsonify(prefer(spec_delegation_level(spec), fact(facts, :delegation_level))),
      "tools" => normalize_tools(fact(facts, :tools)),
      "max_turns" => jsonify(prefer(spec_max_turns(spec), fact(facts, :max_turns))),
      "custom_agent_id" =>
        jsonify(prefer(fact(facts, :custom_agent_id), spec_opt(spec, :custom_agent_id))),
      "model_spec" => jsonify(prefer(fact(facts, :model_spec), spec.model_spec)),
      "node_path" => jsonify(prefer(fact(facts, :node_path), spec_opt(spec, :node_path))),
      "repo_id" => jsonify(spec.repo_id),
      "objective" => jsonify(spec.objective),
      "task_number" => jsonify(fact(facts, :task_number)),
      "task_local_id" => jsonify(fact(facts, :task_local_id)),
      "foreign_repos" => foreign_repo_blobs(spec.foreign_repos),
      "quality_level" =>
        jsonify(prefer(fact(facts, :quality_level), spec_opt(spec, :quality_level))),
      "archive" => jsonify(prefer(fact(facts, :archive), spec_opt(spec, :archive, false))),
      "repo_less" => jsonify(prefer(fact(facts, :repo_less), spec_opt(spec, :repo_less))),
      "parent_id" => jsonify(prefer(fact(facts, :parent_id), spec_opt(spec, :parent_id))),
      "depth" => jsonify(prefer(fact(facts, :depth), spec_opt(spec, :depth))),
      "spawn_turn" => jsonify(fact(facts, :spawn_turn)),
      "spawn_index" => jsonify(fact(facts, :spawn_index))
    }
  end

  @doc """
  The inverse of `build/2`: the rebuildable facts as an `AgentSpec` option
  list.

  Keys are the atom forms (`:agent_type`, `:delegation_level`, `:tools`,
  `:max_turns`, `:custom_agent_id`, `:model_spec`, `:node_path`, `:repo_id`,
  `:objective`, `:task_number`, `:task_local_id`, `:foreign_repos`,
  `:quality_level`, `:archive`, `:repo_less`, `:parent_id`, `:depth`,
  `:spawn_turn`, `:spawn_index`). Foreign repos are rebuilt as
  `%EvoGit.Core.ForeignRepo{}` structs, so the consumer never has to handle the
  persisted JSON shape itself.

  `nil` entries are dropped (so `Keyword.get/3` defaults still apply), while
  `false` is kept. Total for any input: a non-map answers `[]`, and an
  atom-keyed map is accepted exactly like a string-keyed (JSON-decoded) one.
  """
  @spec to_spec_opts(term()) :: keyword()
  def to_spec_opts(map) when is_map(map) do
    [
      agent_type: as_atom(get(map, :agent_type)),
      delegation_level: as_atom(get(map, :delegation_level)),
      tools: as_tools(get(map, :tools)),
      max_turns: as_positive_integer(get(map, :max_turns)),
      custom_agent_id: as_string(get(map, :custom_agent_id)),
      model_spec: as_map(get(map, :model_spec)),
      node_path: as_string(get(map, :node_path)),
      repo_id: as_string(get(map, :repo_id)),
      objective: as_string(get(map, :objective)),
      task_number: as_integer(get(map, :task_number)),
      task_local_id: as_integer(get(map, :task_local_id)),
      foreign_repos: as_foreign_repos(get(map, :foreign_repos)),
      quality_level: as_string(get(map, :quality_level)),
      archive: as_boolean(get(map, :archive)),
      repo_less: as_boolean(get(map, :repo_less)),
      parent_id: as_integer(get(map, :parent_id)),
      depth: as_integer(get(map, :depth)),
      spawn_turn: as_integer(get(map, :spawn_turn)),
      spawn_index: as_integer(get(map, :spawn_index))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def to_spec_opts(_other), do: []

  # --- Facts access ---------------------------------------------------------

  # A keyword list or map is accepted; anything else contributes no facts.
  defp facts_map(facts) when is_list(facts) do
    if Keyword.keyword?(facts), do: Map.new(facts), else: %{}
  end

  defp facts_map(facts) when is_map(facts), do: facts
  defp facts_map(_other), do: %{}

  # String keys are tried as well, so a JSON-decoded facts map works too.
  defp fact(facts, key) do
    Map.get(facts, key, Map.get(facts, Atom.to_string(key)))
  end

  # Facts win when they carry a value; `nil` (absent) falls through to the
  # spec. `false` is a real value and never falls through.
  defp prefer(nil, fallback), do: fallback
  defp prefer(value, _fallback), do: value

  # --- Spec projections -----------------------------------------------------

  defp spec_agent_type(%AgentSpec{agent_module: module}), do: module_call(module, :agent_type)

  defp spec_delegation_level(%AgentSpec{agent_module: module}),
    do: module_call(module, :delegation_level)

  defp spec_max_turns(%AgentSpec{} = spec) do
    case spec_opt(spec, :max_turns) do
      turns when is_integer(turns) and turns > 0 -> turns
      _other -> nil
    end
  end

  defp spec_opt(%AgentSpec{opts: opts}, key, default \\ nil) do
    if is_list(opts), do: Keyword.get(opts, key, default), else: default
  end

  # A spec's agent module is the only owner of the role facts. The callback is
  # invoked defensively: a dynamic module (a custom agent definition resolved
  # from process state) may legitimately raise, and a rebuild blob must never
  # take the caller down for it.
  defp module_call(module, function) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      apply(module, function, [])
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp module_call(_module, _function), do: nil

  # --- Foreign repos --------------------------------------------------------

  # Plain maps (never structs) so the blob is a Jason-encodable value:
  # `%{"id" => .., "path" => .., "writable" => boolean, "base_sha" => ..}`.
  # `description` is display-only metadata and is intentionally NOT part of the
  # rebuildable identity.
  defp foreign_repo_blobs(repos) when is_list(repos) do
    repos
    |> Enum.map(&foreign_repo_blob/1)
    |> Enum.reject(&is_nil/1)
  end

  defp foreign_repo_blobs(_other), do: []

  defp foreign_repo_blob(repo) do
    case ForeignRepo.normalize(repo) do
      %ForeignRepo{id: id, root: root, writable: writable, base_sha: base_sha} ->
        %{"id" => id, "path" => root, "writable" => writable == true, "base_sha" => base_sha}

      nil ->
        nil
    end
  end

  defp as_foreign_repos(repos) when is_list(repos) do
    repos
    |> Enum.map(&ForeignRepo.normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp as_foreign_repos(_other), do: nil

  # --- Tools ----------------------------------------------------------------

  # Tool names are stored as their string form. A schema struct contributed by a
  # caller is accepted by name; anything without a usable name is dropped.
  defp normalize_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tools(_other), do: nil

  defp as_tools(tools), do: normalize_tools(tools)

  defp tool_name(name) when is_binary(name) and name != "", do: name
  defp tool_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp tool_name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name),
    do: Atom.to_string(name)

  defp tool_name(_other), do: nil

  # --- JSON cleanliness -----------------------------------------------------

  # Normalizes a value into something `Jason.encode!/1` handles and
  # `Jason.decode/1` returns unchanged in meaning: atoms become strings, plain
  # maps get string keys, and anything else (pid, ref, fun, tuple, struct) is
  # dropped to `nil` — the blob only ever carries rebuildable data.
  defp jsonify(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonify(nil), do: nil
  defp jsonify(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonify(value) when is_list(value), do: Enum.map(value, &jsonify/1)

  defp jsonify(%{__struct__: _struct} = _value), do: nil

  defp jsonify(value) when is_map(value) do
    Map.new(value, fn {key, entry} -> {json_key(key), jsonify(entry)} end)
  end

  defp jsonify(_other), do: nil

  defp json_key(key) when is_binary(key), do: key

  defp json_key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  defp json_key(key) when is_number(key), do: to_string(key)
  defp json_key(_other), do: nil

  # --- Inverse value coercion ----------------------------------------------

  # Reads a key from an atom- or string-keyed map (a JSON round-trip yields
  # string keys). The string form is tried first, mirroring the persisted
  # shape's primary encoding.
  defp get(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  # Role atoms are part of a small, statically-known set (`:read`,
  # `:read_write`, `:high`, `:low`); `String.to_existing_atom/1` keeps an
  # unknown string a string instead of minting a new atom in the VM.
  defp as_atom(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: value

  defp as_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp as_atom(_other), do: nil

  defp as_string(value) when is_binary(value), do: value
  defp as_string(_other), do: nil

  defp as_map(value) when is_map(value) and not is_struct(value), do: value
  defp as_map(_other), do: nil

  defp as_integer(value) when is_integer(value), do: value
  defp as_integer(_other), do: nil

  defp as_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp as_positive_integer(_other), do: nil

  defp as_boolean(value) when is_boolean(value), do: value
  defp as_boolean(_other), do: nil
end
