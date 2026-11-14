defmodule EvoGit.Agent.ToolBatch do
  @moduledoc """
  The durable IN-FLIGHT tool-batch marker of one agent turn.

  `%EvoGit.Agent.State{pending_tool_batch: nil | batch}` records that a tool
  batch is executing RIGHT NOW, so a crash in the middle of it can be recognised
  after a restart (`EvoGit.Agent.Resume`). The invariant is exact:

      pending_tool_batch != nil  <=>  a tool batch is executing right now

  Every path that stops executing the batch clears it: the normal completion
  (`EvoGit.Agent.ToolDispatch.continue_after_tools/7`), the protocol-violation
  path, and the exchange's terminal checkpoints. The marker is written ONCE per
  tool-calling turn, immediately before the batch runs, and the pre-batch
  checkpoint makes it durable together with the assistant `tool_calls` message
  (so a resumed run can tell which calls were in flight and of what class).

  ## Shape

      %{
        turn: integer(),
        started_at: "2026-01-01T00:00:00Z",
        calls: [
          %{index: 0, id: "call_abc" | nil, name: "bash", class: :shell},
          ...
        ]
      }

  The batch is SMALL on purpose: it is persisted in a JSON column on every
  tool-calling turn, so it carries only what a resumed run needs — the turn, a
  start timestamp and one entry per call. It never carries arguments or output:
  the assistant message in the transcript already holds those.

  ## Classes

  `:subagent | :shell | :edit | :write | :read`, derived from the EXISTING
  sources of truth and never from a duplicated list:

    * `:subagent` — `EvoGit.Agent.SubagentSchemas.subagent_module_for/2` matches
      the call against the agent's declared subagent modules;
    * `:shell` — the platform shell tool (`EvoGit.Agent.ToolNames.shell_tool_name/0`,
      i.e. `run_bash`/`run_powershell`) plus `bash`/`shell`/… aliases through
      `ToolNames.normalize/1`, and the legacy `run_command` spelling;
    * `:edit` — the editing write tools (`edit`/`edit_file`/`edit_context`);
    * `:write` — every OTHER tool in `EvoGit.Agent.Tools`' write set (file
      creates, context writes, skill mutations, git…), which includes
      user-defined custom tools that are not read-only;
    * `:read` — everything else.

  ## JSON round-trip

  The marker survives persistence through a JSON column, so a restored batch has
  STRING keys and a STRING class. `normalize/1` is the ONE place that turns a
  restored value back into the atom-keyed shape; every consumer calls it and no
  other code may assume atom keys on a restored batch. Both `build/3` and
  `normalize/1` are total: malformed input degrades to `nil` (no marker) rather
  than raising in the resume path.
  """

  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Agent.ToolNames
  alias EvoGit.Agent.Tools

  @typedoc "The class of ONE interrupted tool call."
  @type class :: :subagent | :shell | :edit | :write | :read

  @typedoc "One interrupted call: its position, provider id, tool name and class."
  @type call :: %{
          index: non_neg_integer(),
          id: String.t() | nil,
          name: String.t() | nil,
          class: class()
        }

  @typedoc "The in-flight batch marker persisted on `%EvoGit.Agent.State{}`."
  @type t :: %{turn: integer() | nil, started_at: String.t() | nil, calls: [call()]}

  # The editing write tools, in `EvoGit.Agent.ToolNames`' NORMALIZED spelling.
  @edit_tools ["edit", "edit_file", "edit_context"]

  # The legacy shell spelling the alias table does not carry (`run_command` is
  # refused by `EvoGit.Agent.Tools.execute/5`, but it is a shell concept and a
  # historical transcript may still carry it).
  @legacy_shell_tools ["run_command"]

  @doc """
  Builds the marker for ONE tool batch from the model's tool calls.

  `turn` is the turn the batch belongs to — the caller passes the
  ALREADY-INCREMENTED `state.turn` (the turn was advanced before the batch
  started, which is what lets the session's pre-batch checkpoint be adopted).
  `subagent_modules` is the agent's declared subagent module list (used for the
  `:subagent` classification).

  Total: a non-list `tool_calls` yields `nil` (no marker), and an empty list
  yields `nil` — an empty batch is never "executing".
  """
  @spec build(term(), integer() | nil, term()) :: t() | nil
  def build(tool_calls, turn, subagent_modules) when is_list(tool_calls) and tool_calls != [] do
    %{
      turn: turn,
      started_at: now_iso8601(),
      calls:
        tool_calls
        |> Enum.with_index()
        |> Enum.map(fn {call, index} ->
          name = call_name(call)

          %{
            index: index,
            id: call_id(call),
            name: name,
            class: class(name, subagent_modules)
          }
        end)
    }
  end

  def build(_tool_calls, _turn, _subagent_modules), do: nil

  @doc """
  Classifies ONE tool name into its batch class.

  `subagent_modules` may be `nil` or a non-list; it is wrapped, so an agent with
  no declared subagents classifies nothing as `:subagent`. Total: a
  non-binary name is `:read`.
  """
  @spec class(term(), term()) :: class()
  def class(name, subagent_modules) when is_binary(name) do
    cond do
      subagent_call?(name, subagent_modules) -> :subagent
      shell_tool?(name) -> :shell
      edit_tool?(name) -> :edit
      Tools.write_tool_name?(name) -> :write
      true -> :read
    end
  end

  def class(_name, _subagent_modules), do: :read

  @doc """
  Normalizes a marker read back from durable JSON into the canonical
  atom-keyed shape.

  `nil` (no marker) and any non-map value answer `nil`. A map answers a
  canonical batch: `turn` only when it is an integer, `started_at` only when it
  is a binary, and the `calls` list filtered to well-formed entries with
  INTEGER-ordered indices and an ATOM class. Unknown/missing `class` values
  degrade to `:read` (the conservative class: "re-run it if needed").
  """
  @spec normalize(term()) :: t() | nil
  def normalize(nil), do: nil

  def normalize(%{} = batch) do
    # An EMPTY batch is not "executing", so it normalizes to NO marker — the
    # invariant `pending_tool_batch != nil <=> a batch is executing` holds for
    # restored values too.
    case normalize_calls(fetch(batch, :calls)) do
      [] ->
        nil

      calls ->
        %{
          turn: integer_or_nil(fetch(batch, :turn)),
          started_at: binary_or_nil(fetch(batch, :started_at)),
          calls: calls
        }
    end
  end

  def normalize(_batch), do: nil

  @doc """
  The calls of a (canonical or raw) marker. Total: `nil`/malformed answers `[]`.
  """
  @spec calls(term()) :: [call()]
  def calls(batch) do
    case normalize(batch) do
      %{calls: calls} -> calls
      nil -> []
    end
  end

  @doc """
  How many calls of each class the marker holds, in the fixed class order
  (`:subagent`, `:shell`, `:edit`, `:write`, `:read`) and omitting classes with
  no calls. Used by the `[RESUME]` notice; total.
  """
  @spec class_counts(term()) :: [{class(), pos_integer()}]
  def class_counts(batch) do
    counts = batch |> calls() |> Enum.frequencies_by(& &1.class)

    Enum.flat_map([:subagent, :shell, :edit, :write, :read], fn class ->
      case Map.get(counts, class) do
        count when is_integer(count) and count > 0 -> [{class, count}]
        _none -> []
      end
    end)
  end

  ## Classification internals

  defp subagent_call?(name, subagent_modules) do
    not is_nil(SubagentSchemas.subagent_module_for(name, List.wrap(subagent_modules)))
  end

  defp shell_tool?(name) do
    normalized = ToolNames.normalize(name)
    normalized == ToolNames.shell_tool_name() or normalized in @legacy_shell_tools
  end

  defp edit_tool?(name), do: ToolNames.normalize(name) in @edit_tools

  ## Shape helpers

  defp normalize_calls(calls) when is_list(calls) do
    calls
    |> Enum.with_index()
    |> Enum.flat_map(fn {call, position} ->
      case normalize_call(call, position) do
        nil -> []
        normalized -> [normalized]
      end
    end)
  end

  defp normalize_calls(_calls), do: []

  defp normalize_call(%{} = call, position) do
    %{
      index: integer_or_nil(fetch(call, :index)) || position,
      id: binary_or_nil(fetch(call, :id)),
      name: binary_or_nil(fetch(call, :name)),
      class: normalize_class(fetch(call, :class))
    }
  end

  defp normalize_call(_call, _position), do: nil

  @classes %{
    "subagent" => :subagent,
    "shell" => :shell,
    "edit" => :edit,
    "write" => :write,
    "read" => :read
  }

  defp normalize_class(class) when is_atom(class) do
    case Map.get(@classes, Atom.to_string(class)) do
      nil -> :read
      normalized -> normalized
    end
  end

  defp normalize_class(class) when is_binary(class), do: Map.get(@classes, class, :read)
  defp normalize_class(_class), do: :read

  # One accessor for BOTH key shapes: a freshly built marker is atom-keyed while a
  # restored one is string-keyed.
  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp call_name(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.name(call)

  defp call_name(call) when is_map(call),
    do: Map.get(call, :name) || Map.get(call, "name")

  defp call_name(_call), do: nil

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(call) when is_map(call), do: Map.get(call, :id) || Map.get(call, "id")
  defp call_id(_call), do: nil

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
