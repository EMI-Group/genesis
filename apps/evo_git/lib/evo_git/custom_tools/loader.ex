defmodule EvoGit.CustomTools.Loader do
  @moduledoc """
  Compiles/loads user-defined **custom tools** and caches the result.

  Custom tools live in `<config_dir>/tools/` (the same directory as
  `config.toml` / `agents.toml`, resolved by `EvoGit.Config.config_dir/0`).
  Every file in that directory with a `.ex`, `.exs` or `.beam` extension is a
  candidate. Each candidate module that exports BOTH `schema/0` and `execute/2`
  becomes a tool (see `EvoGit.CustomTools.Tool` for the behaviour contract).

  This is a **pure-ish module** (no GenServer): `load/1` reads the directory,
  rebuilds when the file set/content changed, and caches the accepted entries +
  errors in `:persistent_term` keyed `{EvoGit.CustomTools, :cache, dir}`.

  ## Caching & invalidation

  The cache entry is `{fingerprint, entries, errors}` where `fingerprint` is the
  sorted list of `{basename, mtime, size}` for every candidate file. `load/1`
  recomputes that fingerprint on every call (one `File.ls` + one `File.stat` per
  candidate file — cheap) and reuses the cached entries only when it is
  unchanged, so external edits are picked up automatically. `invalidate/0,1`
  erases the cache entry (`EvoGit.CustomTools.reload/0` calls it).

  ## Failure handling

  Nothing here is allowed to raise: compile errors, a module whose `schema/0`
  raises, and name collisions are all expected inputs (user-authored code) and
  are surfaced as `Logger.warning` + a `%{file, reason}` error record, never as a
  crash. This mirrors `EvoGit.CustomAgents.ModelSelector`'s treatment of the
  `[model_selection] script`.
  """

  require Logger

  @extensions [".ex", ".exs", ".beam"]

  # Built-in tools that exist only as dispatch clauses (not as `schemas/0`
  # entries) — they still must not be shadowed by a custom tool.
  @non_schema_builtins ["run_command", "complete_task"]

  @type entry :: %{
          name: String.t(),
          module: module(),
          schema: ReqLLM.Tool.t(),
          read_only?: boolean(),
          file: String.t()
        }

  @type error :: %{file: String.t(), reason: String.t()}

  @doc """
  Returns the custom-tools directory (`<config_dir>/tools`).
  """
  @spec tools_dir() :: String.t()
  def tools_dir do
    Path.join(EvoGit.Config.config_dir(), "tools")
  end

  @doc """
  Loads all custom tools from `dir` (defaults to `tools_dir/0`).

  Returns `%{tool_name => entry}`. Missing/empty directory → `%{}`.
  """
  @spec load() :: %{optional(String.t()) => entry()}
  @spec load(String.t()) :: %{optional(String.t()) => entry()}
  def load(dir \\ tools_dir()) when is_binary(dir) do
    {entries, _errors} = cached(dir)
    entries
  end

  @doc """
  Loads all custom tools from `dir`, returning `{entries, errors}`.

  `entries` is the accepted `%{tool_name => entry}` map; `errors` is the list of
  `%{file, reason}` records collected while loading.
  """
  @spec load_with_errors(String.t()) :: {%{optional(String.t()) => entry()}, [error()]}
  def load_with_errors(dir) when is_binary(dir) do
    cached(dir)
  end

  @doc """
  Returns the load errors for the default directory (`tools_dir/0`).
  """
  @spec errors() :: [error()]
  def errors, do: errors(tools_dir())

  @doc """
  Returns the load errors for `dir`.
  """
  @spec errors(String.t()) :: [error()]
  def errors(dir) when is_binary(dir) do
    {_entries, errors} = cached(dir)
    errors
  end

  @doc """
  Erases the cache entry for the default directory (`tools_dir/0`).
  """
  @spec invalidate() :: :ok
  def invalidate, do: invalidate(tools_dir())

  @doc """
  Erases the cache entry for `dir`. Safe when nothing is cached.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(dir) when is_binary(dir) do
    :persistent_term.erase(cache_key(dir))
    :ok
  end

  # --- Caching ---

  defp cache_key(dir), do: {EvoGit.CustomTools, :cache, dir}

  defp cached(dir) do
    fingerprint = fingerprint(dir)
    key = cache_key(dir)

    case :persistent_term.get(key, :not_cached) do
      {^fingerprint, entries, errors} ->
        {entries, errors}

      _miss_or_stale ->
        {entries, errors} = build(dir)
        :persistent_term.put(key, {fingerprint, entries, errors})
        {entries, errors}
    end
  end

  # Sorted list of `{basename, mtime, size}` for every candidate file. A missing
  # directory yields `[]` — the same as an empty one, which is correct because
  # both produce an empty tool set.
  defp fingerprint(dir) do
    dir
    |> candidate_files()
    |> Enum.map(fn name ->
      path = Path.join(dir, name)

      case File.stat(path) do
        {:ok, %{mtime: mtime, size: size}} -> {name, mtime, size}
        {:error, _reason} -> {name, nil, nil}
      end
    end)
  end

  # Basenames of candidate files, SORTED for a deterministic load order (needed
  # by the first-wins duplicate rule).
  defp candidate_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&candidate?/1)
        |> Enum.sort()

      {:error, _reason} ->
        # Missing or unreadable directory is the normal initial state — no warning.
        []
    end
  end

  defp candidate?(name) do
    Path.extname(name) in @extensions
  end

  # --- Building ---

  defp build(dir) do
    builtin = builtin_tool_names()

    {entries, errors, _seen} =
      dir
      |> candidate_files()
      |> Enum.reduce({%{}, [], MapSet.new()}, fn name, {acc, errs, seen} ->
        path = Path.join(dir, name)
        {file_entries, file_errors, seen} = load_file(path, builtin, seen)
        {Map.merge(acc, file_entries), errs ++ file_errors, seen}
      end)

    {entries, errors}
  end

  # Returns `{entries_map, errors, seen}` for one file. `seen` is the set of
  # already-accepted tool names (across files AND earlier modules in this file)
  # used by the first-wins duplicate rule.
  defp load_file(path, builtin, seen) do
    case load_modules(path) do
      {:error, reason} ->
        {%{}, [error(path, reason)], seen}

      {:ok, modules} ->
        qualifying = Enum.filter(modules, &qualifies?/1)

        if qualifying == [] do
          {%{}, [error(path, "no module exporting both schema/0 and execute/2")], seen}
        else
          Enum.reduce(qualifying, {%{}, [], seen}, fn module, {acc, errs, seen} ->
            case build_entry(module, path, builtin, seen) do
              {:ok, entry} ->
                {Map.put(acc, entry.name, entry), errs, MapSet.put(seen, entry.name)}

              {:error, reason} ->
                {acc, errs ++ [error(path, reason)], seen}
            end
          end)
        end
    end
  end

  # Compiles/loads the file and returns the modules it defines. try/rescue +
  # try/catch are justified: the file is USER-AUTHORED code, so compile errors
  # (SyntaxError, CompileError, ...) and loader failures are expected inputs,
  # not bugs. They must surface as an error tuple — the loader runs from the
  # dispatch path and must never crash the caller (mirrors ModelSelector's
  # treatment of the user script).
  defp load_modules(path) do
    try do
      case Path.extname(path) do
        ext when ext in [".ex", ".exs"] ->
          {:ok, path |> Code.compile_file() |> Enum.map(&elem(&1, 0))}

        ".beam" ->
          load_beam(path)
      end
    rescue
      error ->
        {:error, "failed to compile/load: #{Exception.format(:error, error)}"}
    catch
      kind, reason ->
        {:error, "failed to compile/load (#{kind}): #{inspect(reason)}"}
    end
  end

  defp load_beam(path) do
    charlist = String.to_charlist(path)

    # `:beam_lib.chunks/2` always returns the module name as the first element of
    # the `{:ok, {Module, Chunks}}` tuple; the chunk list is empty because the
    # name is what we need (`:module` is not a real BEAM chunk id — requesting it
    # errors with `:unknown_chunk`).
    with {:ok, {module, _chunks}} <- :beam_lib.chunks(charlist, []),
         {:ok, binary} <- File.read(path),
         {:module, ^module} <- :code.load_binary(module, charlist, binary) do
      {:ok, [module]}
    else
      {:error, _module, reason} -> {:error, "invalid beam file: #{inspect(reason)}"}
      {:error, reason} -> {:error, "failed to load beam module: #{inspect(reason)}"}
      other -> {:error, "failed to load beam module: #{inspect(other)}"}
    end
  end

  defp qualifies?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :schema, 0) and
      function_exported?(module, :execute, 2)
  end

  defp build_entry(module, path, builtin, seen) do
    case call_schema(module) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %ReqLLM.Tool{name: name} = tool} when is_binary(name) and name != "" ->
        cond do
          MapSet.member?(builtin, name) ->
            {:error, "tool name '#{name}' collides with a built-in tool"}

          MapSet.member?(seen, name) ->
            {:error, "duplicate custom tool name '#{name}' (first definition wins)"}

          true ->
            {:ok,
             %{
               name: name,
               module: module,
               schema: tool,
               read_only?: read_only?(module, name),
               file: path
             }}
        end

      {:ok, other} ->
        {:error,
         "schema/0 must return a %ReqLLM.Tool{} with a non-empty binary name, got: #{inspect(other, limit: 5)}"}
    end
  end

  # try/rescue + try/catch are justified: schema/0 is USER-AUTHORED code that can
  # raise (or throw/exit) at load time. That must surface as a logged error
  # record and a skipped module — never crash the scheduler that triggers the
  # load.
  defp call_schema(module) do
    try do
      {:ok, module.schema()}
    rescue
      error ->
        {:error, "schema/0 raised: #{Exception.format(:error, error)}"}
    catch
      kind, reason ->
        {:error, "schema/0 #{kind}: #{inspect(reason)}"}
    end
  end

  # read_only?/0 is optional and USER-AUTHORED. `false` (a WRITE tool) is the
  # conservative default, and is also used when the callback raises — the raise
  # is logged, never swallowed silently, and never crashes the load.
  defp read_only?(module, name) do
    if function_exported?(module, :read_only?, 0) do
      try do
        module.read_only?() == true
      rescue
        error ->
          Logger.warning(
            "Custom tool '#{name}' read_only?/0 raised " <>
              "(#{Exception.format(:error, error)}) — treating it as a WRITE tool"
          )

          false
      catch
        kind, reason ->
          Logger.warning(
            "Custom tool '#{name}' read_only?/0 #{kind} (#{inspect(reason)}) — " <>
              "treating it as a WRITE tool"
          )

          false
      end
    else
      false
    end
  end

  # Built-in tool names are computed at RUNTIME (never a module attribute) to
  # avoid a compile-time cycle with EvoGit.Agent.Tools, which calls back into
  # this subsystem for dispatch. A failure to enumerate them degrades to the
  # literal dispatch-only built-ins rather than crashing the load.
  defp builtin_tool_names do
    try do
      schema_names =
        (EvoGit.Agent.Tools.schemas() ++ EvoGit.Agent.Tools.read_only_schemas())
        |> Enum.map(&EvoGit.Agent.tool_name/1)
        |> Enum.reject(&is_nil/1)

      MapSet.new(schema_names ++ @non_schema_builtins)
    rescue
      error ->
        Logger.warning(
          "Custom tools: failed to enumerate built-in tool names " <>
            "(#{Exception.format(:error, error)}) — using dispatch-only built-ins only"
        )

        MapSet.new(@non_schema_builtins)
    catch
      kind, reason ->
        Logger.warning(
          "Custom tools: failed to enumerate built-in tool names (#{kind}, #{inspect(reason)}) — " <>
            "using dispatch-only built-ins only"
        )

        MapSet.new(@non_schema_builtins)
    end
  end

  defp error(file, reason), do: %{file: file, reason: reason}
end
