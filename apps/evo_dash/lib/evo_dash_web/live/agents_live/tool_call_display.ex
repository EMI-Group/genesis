defmodule EvoDashWeb.AgentsLive.ToolCallDisplay do
  @moduledoc """
  Pure rendering contract for tool-call messages in the Agents page chat
  history viewer.

  `display/1` returns either:
    - `%{label: String.t(), kind: :structured, rows: [{String.t(), String.t()}]}`
      — subagent (`subagent_*` prefix) and shell (`run_bash`/`run_powershell`)
      calls: key/value rows (path + truncated objective / truncated command).
    - `%{label: String.t(), kind: :inline, summary: String.t()}`
      — all other calls: a single compact one-line arguments summary.

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
  Returns the display descriptor for a tool call (see moduledoc).
  """
  def display(call) do
    do_display(call, tool_call_name(call))
  end

  # Subagent tool calls (core `subagent_tool_name/0` family: subagent_manager,
  # subagent_executor, subagent_investigator, ...) — structured rows.
  defp do_display(call, name) when is_binary(name) do
    cond do
      String.starts_with?(name, "subagent_") -> display_subagent(call, name)
      tool_call_is_shell?(call) -> display_shell(call)
      true -> build_inline(call, name)
    end
  end

  defp do_display(call, _name), do: build_inline(call, "unknown")

  defp display_subagent(call, label) do
    case decode_arguments(call) do
      {:ok, decoded} ->
        rows =
          []
          |> add_row(gettext("Path"), subagent_path(decoded))
          |> add_row(gettext("Objective"), truncate_objective(subagent_objective(decoded)))

        if rows == [] do
          build_inline(call, label)
        else
          %{label: label, kind: :structured, rows: rows}
        end

      :error ->
        build_inline(call, label)
    end
  end

  defp display_shell(call) do
    %{
      label: gettext("Shell call"),
      kind: :structured,
      rows: [{gettext("Command"), truncate(shell_command(call), 200)}]
    }
  end

  defp build_inline(call, label) do
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

    %{label: label, kind: :inline, summary: truncate(summary, 160)}
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

  defp truncate_objective(nil), do: nil
  defp truncate_objective(objective), do: truncate(objective, 200)

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

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "…"
    else
      value
    end
  end

  defp collapse_one_line(raw) when is_binary(raw) do
    raw
    |> String.split(~r/\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.join(" ")
  end

  defp collapse_one_line(_), do: ""
end
