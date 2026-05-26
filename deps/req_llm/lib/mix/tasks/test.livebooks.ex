defmodule Mix.Tasks.Test.Livebooks do
  @moduledoc """
  Validates livebook files by extracting Elixir code blocks.

  By default this task parses each livebook's Elixir code blocks together to
  verify they are syntactically valid and can be reviewed in ExDocs without
  obviously broken examples. Use `--execute` to run the combined script when
  a livebook is specifically written for non-interactive execution.

  ## Usage

      mix test.livebooks

  ## Options

      --verbose    Print detailed output for each livebook
      --path       Specify custom path to search for livebooks (default: guides/)
      --execute    Execute the combined script instead of syntax-checking it

  ## Exit Codes

  - 0: All livebooks passed
  - 1: One or more livebooks failed

  ## Limitations

  Execution mode does not support:
  - Kino UI interactions (inputs, outputs, frames)
  - Livebook-specific features like branching or smart cells
  - Code blocks marked with ` ```elixir#test:skip ` will be skipped

  Interactive livebooks should still be manually tested in Livebook.
  """

  use Mix.Task

  @shortdoc "Validate livebook Elixir code blocks"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [verbose: :boolean, path: :string, execute: :boolean])

    path = Keyword.get(opts, :path, "guides/")
    verbose = Keyword.get(opts, :verbose, false)
    execute? = Keyword.get(opts, :execute, false)

    livebooks = find_livebooks(path)

    if livebooks == [] do
      Mix.shell().info("No livebooks found in #{path}")
      :ok
    end

    Mix.shell().info("Testing #{length(livebooks)} livebook(s)...\n")

    results =
      Enum.map(livebooks, fn livebook ->
        test_livebook(livebook, verbose, execute?)
      end)

    passed = Enum.count(results, & &1.passed)
    failed = length(results) - passed

    Mix.shell().info("\n#{String.duplicate("=", 50)}")
    Mix.shell().info("Results: #{passed} passed, #{failed} failed")

    if failed > 0 do
      Mix.shell().error("\nFailed livebooks:")

      Enum.filter(results, fn r -> not r.passed end)
      |> Enum.each(fn r ->
        Mix.shell().error("  - #{r.file}: #{r.error}")
      end)

      Mix.raise("Livebook validation failed")
    else
      Mix.shell().info("\nAll livebooks passed!")
      :ok
    end
  end

  defp find_livebooks(path) do
    Path.join([path, "**", "*.livemd"])
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp test_livebook(file, verbose, execute?) do
    Mix.shell().info("Testing: #{file}")

    content = File.read!(file)
    code_blocks = extract_elixir_blocks(content)

    if verbose do
      Mix.shell().info("  Found #{length(code_blocks)} Elixir code block(s)")
    end

    if code_blocks == [] do
      Mix.shell().info("  ⚠️  No Elixir code blocks found")
      %{file: file, passed: true, error: nil}
    else
      check_code_blocks(file, code_blocks, verbose, execute?)
    end
  end

  defp extract_elixir_blocks(content) do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(content)
    |> Enum.map(fn [_, code] -> String.trim(code) end)
    |> Enum.reject(&skip_block?/1)
  end

  defp skip_block?(code) do
    String.starts_with?(code, "# test:skip") or
      String.starts_with?(code, "#test:skip")
  end

  defp check_code_blocks(file, code_blocks, verbose, execute?) do
    combined_code = Enum.join(code_blocks, "\n\n")

    if execute? do
      execute_code_blocks(file, combined_code, verbose)
    else
      validate_code_blocks(file, combined_code, verbose)
    end
  end

  defp validate_code_blocks(file, combined_code, verbose) do
    if verbose do
      Mix.shell().info("  Validating combined script syntax...")
    end

    case Code.string_to_quoted(combined_code, file: file) do
      {:ok, _quoted} ->
        Mix.shell().info("  ✓ Passed")
        %{file: file, passed: true, error: nil}

      {:error, error_details} ->
        message = format_parse_error(file, error_details)
        Mix.shell().error("  ✗ Failed: #{message}")
        %{file: file, passed: false, error: message}
    end
  end

  defp execute_code_blocks(file, combined_code, verbose) do
    temp_file =
      Path.join(System.tmp_dir!(), "livebook_test_#{:erlang.unique_integer([:positive])}.exs")

    File.write!(temp_file, combined_code)

    if verbose do
      Mix.shell().info("  Executing combined script...")
    end

    # Execute with mix run
    result =
      try do
        task = Task.async(fn -> System.cmd("elixir", [temp_file], stderr_to_stdout: true) end)

        case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            {:ok, output}

          {:ok, {output, exit_code}} ->
            {:error, "Exit code #{exit_code}: #{String.slice(output, 0, 200)}"}

          nil ->
            {:error, "Execution timed out (30s)"}
        end
      catch
        :exit, {:timeout, _} ->
          {:error, "Execution timed out (30s)"}
      after
        File.rm(temp_file)
      end

    case result do
      {:ok, _} ->
        Mix.shell().info("  ✓ Passed")
        %{file: file, passed: true, error: nil}

      {:error, reason} ->
        Mix.shell().error("  ✗ Failed: #{reason}")
        %{file: file, passed: false, error: reason}
    end
  end

  defp format_parse_error(file, {location, error, token}) do
    relative_file = Path.relative_to_cwd(file)
    line = Keyword.get(location, :line)
    column = Keyword.get(location, :column)

    case {line, column} do
      {line, column} when is_integer(line) and is_integer(column) ->
        "#{relative_file}:#{line}:#{column}: #{inspect(error)} #{inspect(token)}"

      {line, _} when is_integer(line) ->
        "#{relative_file}:#{line}: #{inspect(error)} #{inspect(token)}"

      _ ->
        "#{relative_file}: #{inspect(error)} #{inspect(token)}"
    end
  end
end
