defmodule EvoGit.CustomTools do
  @moduledoc """
  Public API for **user-defined custom tools**.

  Custom tools are plain Elixir modules authored by the user and dropped into
  `<config_dir>/tools/` as `.ex`, `.exs` or `.beam` files. They are loaded
  dynamically by `EvoGit.CustomTools.Loader` (see `EvoGit.CustomTools.Tool` for
  the behaviour a tool module must implement) and exposed to agents as ordinary
  `ReqLLM.Tool` schemas.

  This module is the thin orchestration/facade layer: it delegates loading and
  caching to `EvoGit.CustomTools.Loader`, exposes the loaded schemas, answers
  the dispatch write-gate question (`write_tool?/1`) and executes tools by name.
  It is NOT a GenServer — all state lives in `:persistent_term` via the loader.

  ## Loading

  Loading is **lazy** (first `load/0` / `schemas/0` / `execute/3` / `status/0`
  call) and cached via a file fingerprint, so a broken custom tool can never
  block application boot. `reload/0` (called by `EvoGit.CustomAgents.reload/0`)
  invalidates the cache so the next call re-reads the directory.

  ## Naming & collisions

  A tool's name is `schema().name`. A name that collides with a BUILT-IN tool is
  rejected (built-in wins); a name that collides with an already-loaded custom
  tool is rejected (first-wins, file order sorted by basename). Both are logged
  and reported through `status/0`.

  ## Security

  Files under `<config_dir>/tools/` are **user-authored code**, exactly like the
  `agents.toml` `[model_selection] script`: they are compiled and loaded into
  the running BEAM with full privileges, and their `execute/2` runs unsandboxed
  by default (a tool may apply `EvoGit.Sandbox` itself). Only load tools you
  trust. `execute/3` wraps the call so a user-code raise/throw/exit becomes an
  error string rather than crashing the agent loop.
  """

  alias EvoGit.CustomTools.Loader

  @doc """
  Returns the custom-tools directory (`<config_dir>/tools`).
  """
  @spec tools_dir() :: String.t()
  defdelegate tools_dir, to: Loader

  @doc """
  Loads all custom tools.

  Returns `%{tool_name => entry}` where `entry` is
  `%{name: String.t(), module: module(), schema: ReqLLM.Tool.t(), read_only?: boolean(), file: String.t()}`.
  Missing/empty directory → `%{}`.
  """
  @spec load() :: %{optional(String.t()) => Loader.entry()}
  def load, do: Loader.load()

  @doc """
  Returns the schemas of all loaded custom tools, sorted by tool name.

  Cheap — reads the cache. Never raises.
  """
  @spec schemas() :: [ReqLLM.Tool.t()]
  def schemas do
    load()
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(& &1.schema)
  end

  @doc """
  Returns whether `name` is a loaded custom tool.
  """
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(load(), name)
  def known?(_name), do: false

  @doc """
  Returns whether `name` is a loaded custom tool that must be treated as a
  WRITE tool by the dispatch write gate.

  Returns `true` for a known custom tool whose `read_only?/0` is `false` or
  absent (the conservative default); `false` for a known read-only custom tool;
  and `false` for any UNKNOWN name — so this never accidentally blocks a
  built-in tool (the write gate handles built-ins separately).
  """
  @spec write_tool?(term()) :: boolean()
  def write_tool?(name) when is_binary(name) do
    case Map.get(load(), name) do
      %{read_only?: read_only?} -> read_only? != true
      nil -> false
    end
  end

  def write_tool?(_name), do: false

  @doc """
  Executes the custom tool `name` with `args` and the caller's `ctx`.

  `ctx` is the map described by `EvoGit.CustomTools.Tool`:
  `%{repo_path: String.t(), repo_root: String.t() | nil, node_path: String.t() | nil}`.

  Returns:

    * `{:ok, output}` — the tool's output string
    * `{:error, reason}` — the tool raised/threw/exited, or returned a non-string
    * `:unknown` — no loaded custom tool has that name

  The name is looked up with `Map.get/2` on the loaded map — LLM-provided input
  is NEVER atomized. The tool call is wrapped so user-authored code can never
  crash the agent loop; a failure is surfaced as an `{:error, reason}` string.
  """
  @spec execute(String.t(), map(), map()) ::
          {:ok, String.t()} | {:error, String.t()} | :unknown
  def execute(name, args, ctx) when is_binary(name) do
    case Map.get(load(), name) do
      nil ->
        :unknown

      %{module: module} ->
        # try/rescue + try/catch are justified: execute/2 is USER-AUTHORED code
        # that can raise (or throw/exit). It runs inside the agent loop, so the
        # failure must be surfaced as an `{:error, ...}` string — never allowed
        # to crash the agent or the process that dispatched the tool.
        try do
          case module.execute(args, ctx) do
            output when is_binary(output) ->
              {:ok, output}

            other ->
              {:error,
               "custom tool '#{name}' returned a non-string value: #{inspect(other, limit: 5)}"}
          end
        rescue
          error ->
            {:error, "custom tool '#{name}' raised: #{Exception.message(error)}"}
        catch
          kind, reason ->
            {:error, "custom tool '#{name}' #{kind}: #{inspect(reason)}"}
        end
    end
  end

  def execute(_name, _args, _ctx), do: :unknown

  @doc """
  Reports the current custom-tools status.

  Returns EXACTLY:

      %{
        ok: [%{name: String.t(), file: String.t(), module: module(), read_only?: boolean()}],
        errors: [%{file: String.t(), reason: String.t()}]
      }

  `ok` lists the loaded tools (sorted by name); `errors` lists every load
  problem (compile failure, `schema/0` raise, missing behaviour callbacks, name
  collision, ...). Never raises; `%{ok: [], errors: []}` when nothing is
  configured.
  """
  @spec status() :: %{
          ok: [%{name: String.t(), file: String.t(), module: module(), read_only?: boolean()}],
          errors: [%{file: String.t(), reason: String.t()}]
        }
  def status do
    {entries, errors} = Loader.load_with_errors(tools_dir())

    ok =
      entries
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn entry ->
        %{
          name: entry.name,
          file: entry.file,
          module: entry.module,
          read_only?: entry.read_only?
        }
      end)

    %{ok: ok, errors: errors}
  end

  @doc """
  Invalidates the custom-tools cache so the next call re-reads the directory.

  Safe when nothing is cached — always returns `:ok`. Called from
  `EvoGit.CustomAgents.reload/0`.
  """
  @spec reload() :: :ok
  def reload do
    Loader.invalidate()
    :ok
  end
end
