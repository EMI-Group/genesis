defmodule EvoDashWeb.AgentsLive.ToolCallDisplay do
  @moduledoc """
  Pure rendering contract for tool-call messages in the Agents page chat
  history viewer.

  `display/1` and `display/2` return either:
    - `%{label: String.t(), kind: :structured, rows: [{String.t(), String.t()}]}`
      — subagent (`subagent_*` prefix) and shell (`run_bash`/`run_powershell`)
      calls: key/value rows (path + objective / command).
    - `%{label: String.t(), kind: :inline, summary: String.t()}`
      — all other calls: a single one-line arguments summary.

  `display/2` takes a keyword list of options. `opts[:mode]` selects the
  rendering mode:
    - `:compact` (the default, and also the fallback for an unrecognized or
      non-keyword `opts` / unknown `:mode`) caps the structured row values at
      200 chars and the inline summary at 160 chars, each with a trailing `"…"`.
    - `:full` yields the SAME descriptor shape and label text but never caps or
      appends `"…"` — structured rows carry the complete objective / command and
      the inline summary the complete path, decoded-arguments JSON or
      whitespace-collapsed raw arguments.

  Both forms are height-constrained by the template (`agents_live.html.heex`):
  structured blocks render in a `max-h` + `overflow-y-auto` container, inline
  summaries are one line with CSS ellipsis. Raw arguments JSON is NEVER dumped
  for subagent/shell calls.

  Never crashes on any input: defensive extraction reuses
  `EvoDashWeb.Helpers` (`tool_call_name/1`, `tool_call_arguments/1`,
  `tool_call_is_shell?/1`) and JSON decoding is pattern-matched, not raised.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import EvoDashWeb.Helpers,
    only: [tool_call_name: 1, tool_call_arguments: 1, tool_call_is_shell?: 1]

  # Path-like argument keys used for the one-line summary of generic tools.
  @path_keys ["path", "file_path", "dir_path", "paths"]

  @doc """
  Returns the display descriptor for a tool call in `:compact` mode (see moduledoc).
  """
  def display(call) do
    display(call, [])
  end

  @doc """
  Returns the display descriptor for a tool call (see moduledoc).

  `opts[:mode]` is `:compact` (default) or `:full`; any unrecognized or
  non-keyword `opts` — or an unknown `:mode` — falls back to `:compact`.
  """
  def display(call, opts) do
    do_display(call, tool_call_name(call), display_mode(opts))
  end

  # Mode resolution is total: a non-keyword list, any other option list, or an
  # unknown `:mode` value all resolve to `:compact`.
  defp display_mode(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.get(opts, :mode) == :full, do: :full, else: :compact
  end

  defp display_mode(_opts), do: :compact

  # Subagent tool calls (core `subagent_tool_name/0` family: subagent_manager,
  # subagent_executor, subagent_investigator, ...) — structured rows.
  defp do_display(call, name, mode) when is_binary(name) do
    cond do
      String.starts_with?(name, "subagent_") -> display_subagent(call, name, mode)
      tool_call_is_shell?(call) -> display_shell(call, mode)
      true -> build_inline(call, name, mode)
    end
  end

  defp do_display(call, _name, mode), do: build_inline(call, "unknown", mode)

  defp display_subagent(call, label, mode) do
    case decode_arguments(call) do
      {:ok, decoded} ->
        rows =
          []
          |> add_row(gettext("Path"), subagent_path(decoded))
          |> add_row(gettext("Objective"), truncate_objective(subagent_objective(decoded), mode))

        if rows == [] do
          build_inline(call, label, mode)
        else
          %{label: label, kind: :structured, rows: rows}
        end

      :error ->
        build_inline(call, label, mode)
    end
  end

  defp display_shell(call, mode) do
    %{
      label: gettext("Shell call"),
      kind: :structured,
      rows: [{gettext("Command"), truncate(shell_command(call), 200, mode)}]
    }
  end

  defp build_inline(call, label, mode) do
    summary =
      case decode_arguments(call) do
        {:ok, decoded} ->
          case extract_path(decoded) do
            nil ->
              case Jason.encode(decoded) do
                {:ok, json} -> json
                _ -> collapse_one_line(tool_call_arguments(call))
              end

            path ->
              path
          end

        :error ->
          collapse_one_line(tool_call_arguments(call))
      end

    %{label: label, kind: :inline, summary: truncate(summary, 160, mode)}
  end

  # `tool_call_arguments/1` returns a JSON binary or a raw value; normalize
  # either into a decoded map, never raising.
  defp decode_arguments(call) do
    raw = tool_call_arguments(call)

    cond do
      is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> :error
        end

      is_map(raw) ->
        {:ok, raw}

      true ->
        :error
    end
  end

  defp subagent_path(decoded) do
    Enum.find_value(["path", "file_path"], fn key ->
      case Map.get(decoded, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp subagent_objective(decoded) do
    case Map.get(decoded, "objective") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp truncate_objective(nil, _mode), do: nil
  defp truncate_objective(objective, mode), do: truncate(objective, 200, mode)

  defp shell_command(call) do
    case decode_arguments(call) do
      {:ok, decoded} ->
        case Map.get(decoded, "command") do
          command when is_binary(command) and command != "" -> command
          _ -> collapse_one_line(tool_call_arguments(call))
        end

      :error ->
        collapse_one_line(tool_call_arguments(call))
    end
  end

  defp extract_path(decoded) when is_map(decoded) do
    Enum.find_value(@path_keys, fn key ->
      case Map.get(decoded, key) do
        value when is_binary(value) and value != "" ->
          value

        values when is_list(values) ->
          case Enum.filter(values, &is_binary/1) do
            [] -> nil
            binaries -> Enum.join(binaries, " ")
          end

        _ ->
          nil
      end
    end)
  end

  defp add_row(rows, _key, nil), do: rows
  defp add_row(rows, _key, ""), do: rows
  defp add_row(rows, key, value) when is_binary(value), do: rows ++ [{key, value}]

  defp truncate(value, _max, :full), do: value

  defp truncate(value, max, _mode) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "…"
    else
      value
    end
  end

  defp truncate(value, _max, _mode), do: value

  defp collapse_one_line(raw) when is_binary(raw) do
    raw
    |> String.split(~r/\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.join(" ")
  end

  defp collapse_one_line(_), do: ""
end
