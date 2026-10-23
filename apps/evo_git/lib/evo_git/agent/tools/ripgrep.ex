defmodule EvoGit.Agent.Tools.Ripgrep do
  @moduledoc """
  Tool for executing ripgrep (rg) commands.

  Two output conventions, chosen by the caller's args (see `bare_args?/1`):

    * BARE args (`PATTERN [PATH ...]`, no option token) — the tool injects
      `--line-number` and `--no-heading` and caps the payload at `@max_lines`
      lines with a narrowing footer, so the model gets a plain
      `path:line:text` listing. Nothing matched renders exactly
      `No matches found.`.
    * EXPLICIT args (any leading-dash token: `-l`, `-c`, `--json`, `-A/-B/-C`,
      and the `-e`/`-f` forms) — passed through VERBATIM under the legacy
      `Command executed successfully.\\nOutput:\\n<raw>` envelope. The caller
      asked for exactly that shape, so nothing is injected and nothing capped.

  Failures are rendered through `EvoGit.Agent.Tools.Failure`, so they always
  start with the literal `Error: ` and carry any grep-mistake tip as a trailing
  block instead of blending it into the sentence.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @bare_numeric_flag_regex ~r/\A-\d+\z/

  # Injected for the BARE-args case only: a line number in front of each match
  # and one match per line (`path:line:text`) instead of matches grouped under
  # bare file headings.
  @bare_default_flags ["--line-number", "--no-heading"]

  # Payload cap for the BARE-args case. Unbounded rg output (a 50 000-match
  # search) floods the context window; the model narrows the pattern instead.
  @max_lines 250

  @truncation_footer "[results truncated at #{@max_lines} matches; narrow the pattern or add a path to see fewer]"

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "rg",
      description: """
      Use the rg tool to search file contents with ripgrep (rg) — it is recursive by default and respects .gitignore.

      Explicitly provide the pattern and path — rg reads stdin and hangs otherwise.

      ARGS: `["PATTERN"]`, `["PATTERN", "PATH"]`, or the same plus your own flags. When no flag is passed, rg runs with line numbers on, no headings, and a #{@max_lines}-line cap, so the output is a plain `path:line:text` listing. Pass your own flags to control the output exactly — an explicit flag set is passed through unchanged.

      EXAMPLE ARGS:
          ["TODO", "src/"] - finds TODO under src/, prints path:line:text
          ["-i", "-e", "fixme", "."] - case-insensitive, pattern given via -e
          ["-l", "defmodule"] - filenames only

      COMMON MISTAKES (rg is NOT grep):
          1. `-<n>` (e.g. `-9`): This is grep syntax, NOT ripgrep. ripgrep does not support bare numerical shorthand flags (no `-1`, `-5`, `-99`). To control context lines, use `-C <n>` / `--context <n>` (lines before AND after), `-A <n>` / `--after-context <n>` (lines after), or `-B <n>` / `--before-context <n>` (lines before).
          2. `-r`: In grep this means recursive, but rg is recursive BY DEFAULT. In rg, `-r` means `--replace`. Do NOT use `-r` expecting recursive search.
          3. `--exclude-dir`: NOT supported by rg. To exclude a directory, use `-g '!dirname'` instead.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "List of arguments to pass to rg, e.g. ['TODO', 'src/'] or ['-l', 'TODO']"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          }
        },
        "required" => ["args"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the rg tool.
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_array_arg(args, "args") do
      {:ok, sanitized_args} ->
        bare? = bare_args?(sanitized_args)

        {output, exit_code} =
          EvoGit.sandbox_run(repo_path, "rg", rg_args(sanitized_args, bare?), repo_root)

        render(output, exit_code, build_hint(sanitized_args), bare?)

      {:error, message} ->
        message
    end
  end

  # A BARE call is `PATTERN [PATH ...]` with NO option token at all: no element
  # starts with `-`. That keeps every explicit flag set intact for free — `-l`,
  # `-c`, `--json`, `-A/-B/-C`, and the `-e`/`-f` forms (which take the pattern
  # as an option VALUE) all carry a leading-dash token and are therefore NOT
  # bare. An EMPTY list is not bare either: there is no pattern to shape, so the
  # call is passed through unchanged rather than silently rewritten.
  defp bare_args?([_ | _] = args), do: not Enum.any?(args, &String.starts_with?(&1, "-"))
  defp bare_args?(_args), do: false

  defp rg_args(args, true), do: @bare_default_flags ++ args
  defp rg_args(args, false), do: args

  # BARE-args success: a plain `path:line:text` listing, capped. The footer sits
  # OUTSIDE the cap, so a truncated result never hides its own footer.
  defp render(output, 0, hint, true) do
    case payload_lines(output) do
      [] -> no_matches(hint)
      lines -> cap_lines(lines) <> hint_notice(hint)
    end
  end

  # EXPLICIT-args success: the caller chose its own flags, so the raw payload
  # goes out untouched under the legacy envelope.
  defp render(output, 0, _hint, false), do: "Command executed successfully.\nOutput:\n#{output}"

  # rg exits 1 when nothing matched — same sentence in both conventions.
  defp render(_output, 1, hint, _bare), do: no_matches(hint)

  defp render(output, exit_code, hint, _bare) do
    guidance = output_block(output) <> hint_notice(hint)
    Failure.error("rg failed with exit code #{exit_code}.", guidance)
  end

  defp no_matches(hint), do: "No matches found." <> hint_notice(hint)

  # `build_hint/1` returns nil when the args carry no grep mistake — never hand
  # that to `Failure.notice/1`, which would stringify it to "nil".
  defp hint_notice(nil), do: ""
  defp hint_notice(hint), do: Failure.notice(hint)

  defp payload_lines(output) do
    case String.trim_trailing(output) do
      "" -> []
      text -> String.split(text, "\n")
    end
  end

  # Caps the payload at `@max_lines` and appends the narrowing footer ONLY when
  # lines were dropped, so a complete listing is returned byte-identical.
  defp cap_lines(lines) do
    if length(lines) > @max_lines do
      (lines |> Enum.take(@max_lines) |> Enum.join("\n")) <> "\n" <> @truncation_footer
    else
      Enum.join(lines, "\n")
    end
  end

  defp output_block(output) do
    case String.trim_trailing(output) do
      "" -> ""
      text -> "Output:\n" <> text
    end
  end

  @doc """
  Inspects rg command args for common grep-to-rg mistakes.
  Returns `nil` if no mistake is detected, or a hint string describing the
  problem and how to fix it.
  """
  def build_hint(sanitized_args) do
    sanitized_args
    |> Enum.flat_map(&detect_mistakes/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      hint -> hint
    end
  end

  defp detect_mistakes(arg) do
    cond do
      # Bare numeric flag like -9, -1, -99 (grep syntax, not rg)
      Regex.match?(@bare_numeric_flag_regex, arg) ->
        [
          ~s"""
          Tip: ripgrep (rg) doesn't support -<n> numerical shorthand flags (that's grep syntax). To control context lines:
          - -C <n> or --context <n>: Shows <n> lines of context before and after the match.
          - -A <n> or --after-context <n>: Shows <n> lines of context after the match.
          - -B <n> or --before-context <n>: Shows <n> lines of context before the match.
          """
          |> String.trim_trailing()
        ]

      # -r means --replace in rg, NOT recursive
      arg == "-r" ->
        [
          "Tip: In rg, '-r' means '--replace', NOT recursive. rg searches recursively by default — remove '-r' unless you intend text replacement."
        ]

      # --exclude-dir is not supported by rg
      String.starts_with?(arg, "--exclude-dir") ->
        ["Tip: rg doesn't support '--exclude-dir'. To exclude a directory, use: -g '!dirname'"]

      true ->
        []
    end
  end
end
