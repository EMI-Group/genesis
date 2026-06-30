defmodule EvoGit.Agent.Tools.Ripgrep do
  @moduledoc """
  Tool for executing ripgrep (rg) commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "rg",
      description: """
      Executes ripgrep (rg) to search for patterns in files. Provide arguments as a list of strings.
      The working directory is set to git repo path (the current git worktree path).

      ripgrep (rg) recursively searches the current directory for lines matching a regex pattern.
      By default, ripgrep will respect gitignore rules and automatically skip hidden files/directories and binary files.
      IMPORTANT: Explicitly provide the pattern and path arguments, otherwise rg will try to read them from stdin, which will cause the command to hang and timeout.

      USAGE:
          rg [OPTIONS] PATTERN [PATH ...]
          rg [OPTIONS] -e PATTERN ... [PATH ...]
          rg [OPTIONS] -f PATTERNFILE ... [PATH ...]
          rg [OPTIONS] --files [PATH ...]
          rg [OPTIONS] --type-list
          command | rg [OPTIONS] PATTERN
          rg [OPTIONS] --help
          rg [OPTIONS] --version

      EXAMPLE ARGS:
          ["-n", "TODO", "src/"] - searches for the pattern "TODO" in the "src/" and prints line numbers
          ["-i", "-e", "fixme", "."] - case-insensitive

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
            "description" => "List of arguments to pass to rg, e.g. ['-n', 'pattern', 'path']"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output.",
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
        {output, exit_code} =
          EvoGit.sandbox_run(repo_path, "rg", sanitized_args, repo_root)

        hint = build_hint(sanitized_args)

        cond do
          exit_code == 0 ->
            "Command executed successfully.\nOutput:\n#{output}"

          exit_code == 1 and output == "" ->
            base = "No matches found."
            if hint, do: base <> "\n" <> hint, else: base

          true ->
            base = "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
            if hint, do: base <> "\n" <> hint, else: base
        end

      {:error, message} ->
        message
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
      Regex.match?(~r/\A-\d+\z/, arg) ->
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
