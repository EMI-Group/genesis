defmodule EvoGit.Adapters.Gemini do
  @moduledoc """
  Wrapper for Gemini CLI integration.
  """
  require Logger

  @model "gemini-3-flash-preview"

  @doc """
  Calls the Gemini CLI with the given prompt and optional context files/input.

  `context_files`: List of file paths to be read and passed as context (stdin).
  """
  def call(prompt, context_files \\ [], opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    execute(prompt, context_files, cd)
  end

  defp execute(prompt, context_files, cd) do
    # 1. Aggregate content
    # Gemini-cli expects the context as "@file1 @file2" in stdin
    content = Enum.map(context_files, &"@#{&1}") |> Enum.join(" ")

    full_input = content <> " " <> prompt
    Logger.debug("Gemini full input: #{full_input}")

    # 2. Write to temp file to avoid shell escaping issues
    random_id = :erlang.unique_integer([:positive])
    tmp_path = Path.join(System.tmp_dir!(), "gemini_in_#{random_id}.txt")
    File.write!(tmp_path, full_input)

    # 3. Execute
    # We use sh -c to handle the pipe easily
    # Pass the prompt via stdin
    # -m is used to specify model, -y for yes to all prompts (yolo mode)
    # `gemini -m <model> -y < tmp_file`

    cmd = "gemini"
    # args was unused
    # Forcing JSON as the agent likely expects structured response or at least consistent text.

    {output, exit_code} =
      System.cmd(
        "sh",
        ["-c", "#{cmd} -m #{@model} -y --output-format json < #{tmp_path}"],
        cd: cd
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
end
