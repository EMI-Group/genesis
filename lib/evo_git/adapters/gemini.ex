defmodule EvoGit.Adapters.Gemini do
  @moduledoc """
  Wrapper for Gemini CLI integration.
  """
  alias EvoGit.Adapters.Gemini.Pool

  @doc """
  Calls the Gemini CLI with the given prompt and optional context files/input.

  `context_files`: List of file paths to be read and passed as context (stdin).
  `input`: Additional string input.
  """
  def call(prompt, context_files \\ [], input \\ nil, opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())

    Pool.run(fn ->
      execute(prompt, context_files, input, cd)
    end)
  end

  defp execute(prompt, context_files, input, cd) do
    # 1. Aggregate content
    content =
      Enum.map(context_files, fn file ->
        case File.read(file) do
          {:ok, text} -> "--- File: #{file} ---" <> text <> "\n"
          _ -> ""
        end
      end)
      |> Enum.join("\n")

    full_input = content <> "\n" <> (input || "")

    # 2. Write to temp file to avoid shell escaping issues
    random_id = :erlang.unique_integer([:positive])
    tmp_path = Path.join(System.tmp_dir!(), "gemini_in_#{random_id}.txt")
    File.write!(tmp_path, full_input)

    # 3. Execute
    # We use sh -c to handle the pipe easily
    # We ask for JSON output as per design recommendation for some cases,
    # but the generic call might want text.
    # The design says: `gemini -p "Explain this code" --output-format json`
    # Let's assume we default to text, but maybe valid JSON if the prompt asks for it?
    # The design examples show both.
    # Let's add an option to `call` for format?
    # For now, I'll stick to text unless specified.
    # Wait, the Agent will likely want JSON.
    # I'll modify the `call` signature in future if needed, but for now strict implementation.

    # Escaping the prompt for shell is important.
    # Ideally passing it as argument to gemini is handled by System.cmd if we call gemini directly.
    # But we are piping.
    # `gemini --prompt "prompt" < tmp_file`

    # We can avoid `sh -c` by using `File.open` as stdin?
    # System.cmd doesn't support file as stdin directly.

    cmd = "gemini"
    # args was unused
    # Forcing JSON as the agent likely expects structured response or at least consistent text.

    {output, exit_code} =
      System.cmd(
        "sh",
        ["-c", "#{cmd} --prompt #{escape_shell_arg(prompt)} --output-format json < #{tmp_path}"],
        cd: cd,
        stderr_to_stdout: true
      )

    File.rm(tmp_path)

    case exit_code do
      0 ->
        # Parse JSON
        case JSON.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :json_decode_error, output}
        end

      code ->
        {:error, code, output}
    end
  end

  defp escape_shell_arg(str) do
    # Basic single quote escaping for sh
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
