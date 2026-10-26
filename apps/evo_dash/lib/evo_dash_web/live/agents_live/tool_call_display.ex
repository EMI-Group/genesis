defmodule EvoDashWeb.AgentsLive.ToolCallDisplay do
  @moduledoc """
  Pure rendering contract for tool-call messages in the Agents page chat
  history viewer.

  `display/1` and `display/2` return either:
    - `%{label: String.t(), kind: :structured, rows: [{String.t(), String.t()}]}`
      — subagent (`subagent_*` prefix, including the accepted alias spellings
      `task`/`subagent`) and shell (the platform shell tool `bash` plus every
      accepted spelling of it) calls: key/value rows (path + objective /
      command).
    - `%{label: String.t(), kind: :inline, summary: String.t()}`
      — all other calls: a single one-line arguments summary.

  ## The `:variant` key (background shell calls)

  A `:variant` key is added ONLY to the descriptors that need a distinct
  presentation, so every other descriptor keeps the historical shape
  (`%{label:, kind:, rows:/summary:}`) byte-identical — read it with
  `Map.get(display, :variant)`, never with dot access.

  `:variant => :background_shell` marks the shell tool called with a truthy
  `run_in_background` argument (the "detached job" mode: the call returns a job
  id immediately and the command keeps running). Its label becomes
  `"Background shell call"` and the `Command` row / 200-char truncation
  contract is unchanged. Detection is deliberately as lenient as the core
  (`EvoGit.Agent.Tools.background_start?/1`): the JSON boolean `true` or the
  string `"true"` — anything else (absent, `false`, `"false"`, junk) is a
  FOREGROUND shell call.

  ## Alias-aware naming

  The MODEL-FACING tool names (`read`, `write`, `edit`, `bash`, `web_search`)
  differ from the INTERNAL dispatch keys (`read_file`, `write_file`,
  `edit_file`, `run_bash`/`run_powershell`, `search_web`). The tool key is
  derived ONCE through the core alias spine `EvoGit.Agent.ToolNames.normalize/1`
  and used for BOTH the subagent grouping test and the descriptor label, so a
  live agent's `read`/`edit`/`write`/`web_search` call renders EXACTLY as the
  historical `read_file`/`edit_file`/`write_file`/`search_web` call did. Names
  outside the alias table pass through UNCHANGED, so custom tools keep their own
  name. Shell classification is delegated to
  `EvoDashWeb.Helpers.tool_call_is_shell?/1` (itself alias-aware), which is why
  `bash` renders as a `Shell call` with a `Command` row.

  `display/2` takes a keyword list of options. `opts[:mode]` selects the
  rendering mode:
    - `:compact` (the default, and also the fallback for an unrecognized or
      non-keyword `opts` / unknown `:mode`) caps the structured row values at
      200 chars and the inline summary at 160 chars, each with a trailing `"…"`.
    - `:full` yields the SAME descriptor shape and label text but never caps or
      appends `"…"` — structured rows carry the complete objective / command and
      the inline summary the complete path, decoded-arguments JSON or
      whitespace-collapsed raw arguments.

  Both forms are height-constrained by their template (`agents_live.html.heex`)
  call sites. The compact inline detail panel (chat-history list) calls
  `display/1` — structured blocks render in a `max-h-12` + `overflow-y-auto`
  container and the inline summary is one line with CSS ellipsis. The
  full-message modal ("zoom-in" view) calls `display(call, mode: :full)` and
  renders the untruncated values inside scrollable `max-h-[60vh]`
  `overflow-y-auto` regions — the modal's inline summary wraps
  (`whitespace-pre-wrap`) instead of ellipsizing. Raw arguments JSON is NEVER
  dumped for subagent/shell calls.

  Never crashes on any input: defensive extraction reuses
  `EvoDashWeb.Helpers` (`tool_call_name/1`, `tool_call_arguments/1`,
  `tool_call_is_shell?/1`), name normalization reuses `EvoGit.Agent.ToolNames`,
  and JSON decoding is pattern-matched, not raised.
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

  # Resolve the tool key ONCE through the core alias spine: a model-facing name
  # (`read`/`write`/`edit`/`bash`/`web_search`/`task`/…) becomes its internal
  # dispatch key, while an unknown/custom name passes through UNCHANGED.
  defp do_display(call, name, mode) when is_binary(name) do
    key = EvoGit.Agent.ToolNames.normalize(name)

    cond do
      String.starts_with?(key, "subagent_") -> display_subagent(call, key, mode)
      tool_call_is_shell?(call) -> display_shell(call, mode)
      true -> build_inline(call, key, mode)
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
    descriptor = %{
      label: gettext("Shell call"),
      kind: :structured,
      rows: [{gettext("Command"), truncate(shell_command(call), 200, mode)}]
    }

    if background_start?(call) do
      # A detached job start is a DIFFERENT thing from a foreground command —
      # it returns a job id right away and keeps running. The `:variant` key is
      # present ONLY on this descriptor (see the moduledoc), so the markup can
      # give it its own accent without touching any other call's presentation.
      descriptor
      |> Map.put(:label, gettext("Background shell call"))
      |> Map.put(:variant, :background_shell)
    else
      descriptor
    end
  end

  # Lenient truthy check of the shell tool's `run_in_background` argument,
  # mirroring the core (`EvoGit.Agent.Tools.background_start?/1`): the model may
  # emit a real JSON boolean `true` or the string `"true"`; anything else
  # (absent, `false`, `"false"`, junk, undecodable arguments) is NOT a
  # background start.
  defp background_start?(call) do
    case decode_arguments(call) do
      {:ok, decoded} -> Map.get(decoded, "run_in_background") in [true, "true"]
      :error -> false
    end
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
