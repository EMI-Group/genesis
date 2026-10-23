defmodule EvoGit.Agent.OutputSanitizer do
  @moduledoc """
  Centralizes all tool output sanitization and truncation logic.

  Provides a pipeline for cleaning and truncating tool outputs before they are
  returned to the LLM, preventing context bloat from:
  - Invalid UTF-8 binary data
  - ANSI escape sequences (colors, cursor movement, etc.)
  - Progress bar artifacts from CLI tools
  - Excessively large outputs

  ## Pipeline

  All functions return `{result, truncation_info}` tuples where:
  - `result` is the sanitized/truncated output
  - `truncation_info` is `nil` when no truncation occurred, or a map:
      `%{reason: :invalid_utf8 | :size_exceeded, original_size: pos_integer,
        truncated_size: pos_integer}` — the size-exceeded variant additionally
      carries `effective_max`, `global_max` and `spill_path` (see below).

  Steps: ensure_utf8 → strip_ansi → strip_progress_bars → truncate

  ## Truncation spill file

  A size-exceeded truncation writes the FULL (pre-truncation, post-sanitize)
  output to a spill file inside the current task's scratch directory
  (`EvoGit.TaskTmpdir.current/0`), named
  `tool_output_<tool_name>_<millis>_<unique>.txt`. The inline result keeps the
  head+tail slices and gains a trailing locator line
  `[output truncated; full output: <path>]`, so the model can `read` the omitted
  middle instead of narrowing blindly. The write is best-effort: with no
  per-task tmpdir installed (direct/unit-test callers) or on a filesystem error
  the locator simply omits the path — a spill failure never fails the tool call.
  The path is reported as `truncation_info.spill_path` (`nil` when none).
  ## Wrap boundary (BINARY-ONLY contract)

  This module is BINARY-ONLY: it takes a string and returns a string. It never
  receives or returns a `%EvoGit.Agent.ToolOutput{}` — the wrap/unwrap between a
  binary and a `%ToolOutput{}` happens ONLY inside `EvoGit.Agent.ToolDispatch`
  (see `EvoGit.Agent.ToolOutput` → "Wrap boundary invariant"). `ToolDispatch`
  therefore always calls `sanitize_and_truncate/3` with `ToolOutput.text/1` and
  re-attaches the sanitized string with `ToolOutput.with_text/2`, so any media a
  tool attached survives sanitization untouched.
  """
  require Logger

  # Tools whose default cap is the SMALLER `[:truncation, :tool_output_default_max_bytes]`
  # (everything else defaults to the global ceiling). The tool name handed to
  # the sanitizer is the RAW model-facing name, and the model-facing names are
  # being aligned with DeepSeek-Harness conventions (`read_file` → `read`,
  # `run_bash` → `bash`, `search_web` → `web_search`, …). BOTH spellings are
  # listed here on purpose so the per-tool default cap keeps applying whichever
  # spelling the caller passes — deliberately without depending on the
  # (concurrently changing) tool-name alias table.
  @high_output_tools MapSet.new([
                       # shell / exec
                       "run_bash",
                       "bash",
                       "shell",
                       "run_powershell",
                       "powershell",
                       "pwsh",
                       # read / write / edit
                       "read_file",
                       "read",
                       "write_file",
                       "write",
                       "edit_file",
                       "edit",
                       # search / network / language intelligence
                       "rg",
                       "grep",
                       "run_git",
                       "git",
                       "search_web",
                       "web_search",
                       "web_fetch",
                       "lsp",
                       "search_context",
                       "search_history"
                     ])
  @ansi_regex ~r/\e\[[0-9;]*[a-zA-Z]|\e\][^\x07]*\x07|\e[()][AB012]|\e\[[0-9;]*m/
  @progress_bar_regex ~r/^[\s\r]*\[[=\->#*_ ]+\]\s*\d*%?\s*$/
  @spinner_regex ~r/^[\|\/\-\\]$/

  # Cap for the tool-name slug embedded in a spill file name (keeps the name
  # well under filesystem limits regardless of what a caller passes).
  @spill_tool_slug_max 48
  # --- Public API ---

  @doc """
  Full sanitization + truncation pipeline for tool outputs.

  Steps: ensure_utf8 → strip_ansi → strip_progress_bars → truncate

  Returns `{result, truncation_info}` where truncation_info is `nil` when no
  truncation occurred, or `%{reason: atom, original_size: pos_integer, truncated_size: pos_integer}`.
  """
  def sanitize_and_truncate(result, tool_name, tool_args) do
    {result, utf8_info} = EvoGit.UTF8.ensure_utf8(result)

    result =
      result
      |> strip_ansi()
      |> strip_progress_bars()

    {result, truncate_info} = truncate(result, tool_name, tool_args)

    {result, truncate_info || utf8_info}
  end

  @doc """
  Strip ANSI escape sequences from a string.

  Removes:
  - CSI sequences (colors, cursor movement, screen clearing)
  - OSC sequences (title setting)
  - Common two-byte sequences

  Non-binary results pass through unchanged.
  """
  def strip_ansi(input) when is_binary(input) do
    Regex.replace(@ansi_regex, input, "")
  end

  def strip_ansi(input) when not is_binary(input), do: input

  @doc """
  Strip progress bar artifacts from CLI output.

  Detects and removes:
  - Carriage-return overwritten lines (keeps only the last segment after `\\r`)
  - Progress bar patterns like `[====>      ]`
  - Spinner patterns like `|`, `/`, `-`, `\\`
  - Purely whitespace lines
  """
  def strip_progress_bars(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      processed = handle_carriage_returns(line)
      if progress_bar_line?(processed), do: acc, else: [processed | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  def strip_progress_bars(input) when not is_binary(input), do: input

  @doc """
  Truncate output that exceeds the configured threshold.

  Uses per-tool truncation limits:
  - High-output tools (run_bash, read_file, rg, etc.) use a smaller default limit
  - Other tools use the global ceiling
  - `max_bytes` in tool_args overrides the default (capped by global ceiling)

  Reads thresholds from config:
  - `[:truncation, :tool_output_max_bytes]` (default: 128 KB) — global ceiling
  - `[:truncation, :tool_output_default_max_bytes]` (default: 16 KB) — for high-output tools
  - `[:truncation, :tool_output_truncate_size]` (default: 8192 bytes)

  Returns `{result, truncation_info}` where truncation_info is `nil` when no
  truncation occurred, or
  `%{reason: :size_exceeded, original_size: pos_integer, truncated_size: pos_integer,
     effective_max: pos_integer, global_max: pos_integer, spill_path: String.t() | nil}`.

  On truncation the full original output is spilled to the current task's
  scratch directory (see the moduledoc) and located inline; `spill_path` is the
  spill file path, or `nil` when the spill could not be written.

  Non-binary results pass through as `{result, nil}`.
  """
  def truncate(result, tool_name, tool_args) when is_binary(result) do
    global_max = EvoGit.Config.resolve([:truncation, :tool_output_max_bytes])
    default_max = EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes])
    truncate_size = EvoGit.Config.resolve([:truncation, :tool_output_truncate_size])

    effective_max = determine_effective_max(tool_name, tool_args, global_max, default_max)

    original_size = byte_size(result)

    if original_size <= effective_max do
      {result, nil}
    else
      Logger.warning(
        "Tool output truncated for '#{tool_name}' (arguments: #{inspect(tool_args)}): " <>
          "original #{original_size} bytes exceeded effective max #{effective_max} bytes. " <>
          "Raise the limit via the `[truncation] tool_output_default_max_bytes` / " <>
          "`[truncation] tool_output_max_bytes` config keys or a per-call `max_bytes` " <>
          "argument (capped by the global ceiling)."
      )

      {first_part, last_part, retained, omitted} = head_tail_slices(result, truncate_size)

      body =
        if omitted == 0 do
          first_part
        else
          first_part <> "\n... [#{omitted} bytes omitted] ...\n" <> last_part
        end

      # Spill the FULL (pre-truncation, post-sanitize) output so a follow-up
      # `read` can open the omitted middle instead of narrowing blindly.
      spill_path = write_spill_file(result, tool_name)

      truncated =
        (truncation_header(effective_max, original_size, first_part, last_part, omitted) <>
           "\n" <> body <> spill_locator(spill_path))
        |> String.trim()

      # Defensive UTF-8 safety net: String.byte_slice/3 is already
      # UTF-8-boundary-safe (Elixir 1.17+ backs off to the last valid codepoint),
      # but keep the final assembled string valid no matter what. ensure_utf8/1
      # on an already-valid string is a no-op returning {result, nil} — keep only
      # the first element so the :size_exceeded truncation_info below is never
      # clobbered by a repair info.
      {truncated, _utf8_info} = EvoGit.UTF8.ensure_utf8(truncated)

      {truncated,
       %{
         reason: :size_exceeded,
         original_size: original_size,
         truncated_size: retained,
         effective_max: effective_max,
         global_max: global_max,
         spill_path: spill_path
       }}
    end
  end

  def truncate(result, _tool_name, _tool_args) when not is_binary(result), do: {result, nil}

  # --- Private Helpers ---

  # Computes the head/tail content slices for a truncated output using the
  # kept-budget clamp: never slice more than the original size, so the head and
  # tail cannot overlap and the omitted count can never go negative. Returns
  # {first_part, last_part, retained, omitted} where `retained` is the ACTUAL
  # number of content bytes kept (byte_slice may return slightly fewer bytes on
  # codepoint backoff) and `omitted` = original_size - retained (always >= 0).
  defp head_tail_slices(result, truncate_size) do
    original_size = byte_size(result)
    kept_budget = min(truncate_size, original_size)

    if kept_budget >= original_size do
      # Output exceeded the threshold but is smaller than the keep size: keep
      # the whole original content unchanged (nothing omitted).
      {result, "", original_size, 0}
    else
      half = div(kept_budget, 2)
      first = String.byte_slice(result, 0, half)
      last = String.byte_slice(result, -half, half)
      retained = byte_size(first) + byte_size(last)
      {first, last, retained, original_size - retained}
    end
  end

  # Short, factual inline header the LLM sees at the top of a truncated output.
  # Must be accurate in both cases: omitted > 0 (head + tail kept) and the
  # edge case where the whole output was retained (omitted == 0). Deliberately
  # decoration-free (no bracketed warning tag, no emoji) and terse: the hint plus
  # the caps live in `EvoGit.Agent.TruncationFeedback`'s trailing notice and in
  # the spill-file locator, never here.
  defp truncation_header(effective_max, original_size, first_part, last_part, omitted) do
    if omitted == 0 do
      "[Output truncated: original #{original_size} bytes exceeded the " <>
        "#{effective_max}-byte limit; the full output was retained unchanged (nothing omitted)]"
    else
      first_size = byte_size(first_part)
      last_size = byte_size(last_part)

      "[Output truncated: original #{original_size} bytes exceeded the " <>
        "#{effective_max}-byte limit; kept first #{first_size} + last #{last_size} bytes, " <>
        "#{omitted} bytes omitted]"
    end
  end

  # Appended AFTER the kept head+tail content: the locator line that lets the
  # model open the full output with a follow-up read. Empty when the spill could
  # not be written (no per-task tmpdir, filesystem error).
  defp spill_locator(nil), do: ""

  defp spill_locator(path) when is_binary(path),
    do: "\n\n[output truncated; full output: #{path}]"

  # Writes the FULL, pre-truncation output into the current task's scratch
  # directory and returns the path, or `nil` when there is no per-task tmpdir
  # (direct/unit-test callers) or the write fails. Plain `case` matches only —
  # a spill must never fail the tool call, and a write error is already the
  # fully-handled `{:error, reason}` shape (no raise to guard against).
  defp write_spill_file(full_output, tool_name) do
    case EvoGit.TaskTmpdir.current() do
      dir when is_binary(dir) ->
        path = Path.join(dir, spill_file_name(tool_name))

        case File.write(path, full_output) do
          :ok ->
            path

          {:error, reason} ->
            Logger.debug(
              "OutputSanitizer: could not write spill file #{path}: #{inspect(reason)}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  # `tool_output_<slug>_<millis>_<unique>.txt` — self-describing per call and
  # collision-free: `System.unique_integer([:positive, :monotonic])` is unique
  # per BEAM even for two truncations in the same millisecond (the millis
  # component keeps the name human-readable/chronological).
  defp spill_file_name(tool_name) do
    "tool_output_#{spill_tool_slug(tool_name)}_" <>
      "#{System.system_time(:millisecond)}_" <>
      "#{System.unique_integer([:positive, :monotonic])}.txt"
  end

  defp spill_tool_slug(tool_name) when is_binary(tool_name) do
    slug =
      tool_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @spill_tool_slug_max)

    if slug == "", do: "tool", else: slug
  end

  defp spill_tool_slug(_tool_name), do: "tool"

  defp determine_effective_max(tool_name, tool_args, global_max, default_max) do
    case tool_args do
      %{"max_bytes" => max} when is_integer(max) and max > 0 ->
        min(max, global_max)

      _ ->
        if MapSet.member?(@high_output_tools, tool_name) do
          default_max
        else
          global_max
        end
    end
  end

  # When \r appears within a line, keep only the last segment (after the final \r).
  # This handles progress bars that overwrite the same line using \r.
  defp handle_carriage_returns(line) do
    line |> String.split("\r") |> List.last()
  end

  # Returns true if the line is a progress bar artifact that should be filtered out.
  defp progress_bar_line?(line) do
    stripped = String.trim(line)

    cond do
      # Empty or whitespace-only lines
      stripped == "" -> true
      # Pure progress bar: [====>      ] 50%
      Regex.match?(@progress_bar_regex, stripped) -> true
      # Spinner patterns: | / - \
      Regex.match?(@spinner_regex, stripped) -> true
      # Otherwise keep the line
      true -> false
    end
  end
end
