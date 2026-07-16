defmodule EvoGit.Sandbox.Helpers do
  @moduledoc """
  Shared utility functions for the sandbox subsystem.

  Extracted from the individual sandbox backend implementations
  (`EvoGit.Sandbox.Linux`, `EvoGit.Sandbox.MacOS`, `EvoGit.Sandbox.None`),
  `EvoGit.Nix`, and the sandbox lifecycle modules (`EvoGit.SandboxSlice`,
  `EvoGit.SandboxProcessRegistry`) to eliminate copy-paste duplication.

  All functions are pure or perform only the I/O they are explicitly
  responsible for (temp-file reads, `System.cmd` execution).
  """

  # ---------------------------------------------------------------------------
  # Shell escaping
  # ---------------------------------------------------------------------------

  @doc """
  POSIX-safe shell escaping for a single argument.

  Wraps the argument in single quotes and replaces every literal single-quote
  with the standard `\\''` escape sequence. This is **security-sensitive** — it
  is used to prevent command injection when assembling shell command strings
  (e.g. `bash -c "<escaped-cmd>"`).

  All sandbox backends and `EvoGit.Nix` share this single implementation so
  that the escaping logic is defined in exactly one place.
  """
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  @doc """
  PowerShell-safe escaping for a single argument.

  Wraps the argument in double quotes for embedding inside a
  `powershell -Command "<cmd>"` string. This is **security-sensitive** — it
  prevents command injection when assembling PowerShell command strings.

  Inside PowerShell double-quoted strings the escape character is the backtick
  (`` ` ``). The following transformations are applied **in order** (order
  matters so that backticks added for `$` escaping are not themselves
  double-escaped):

    1. Backtick → double-backtick (`` ` `` → ``` `` ```)
    2. Dollar sign → backtick-dollar (`$` → `` `$ ``) so variable expansion is
       suppressed.
    3. Double-quote → doubled (`"` → `""`).

  The result is then wrapped in double quotes.

  ## Examples

      iex> powershell_escape("git")
      "\\"git\\""

      iex> powershell_escape("my file.txt")
      "\\"my file.txt\\""

      iex> powershell_escape("$HOME")
      "\\"`$HOME\\""
  """
  @spec powershell_escape(String.t()) :: String.t()
  def powershell_escape(arg) do
    escaped =
      arg
      |> String.replace("`", "``")
      |> String.replace("$", "`$")
      |> String.replace("\"", "\"\"")

    "\"" <> escaped <> "\""
  end

  # ---------------------------------------------------------------------------
  # Temp-file reading (for run_with_partial/6 partial-output recovery)
  # ---------------------------------------------------------------------------

  @doc """
  Reads content from a temp file and deletes it.

  Returns an empty string if the file does not exist or cannot be read.

  ## Options

    * `max_bytes` — when `nil`, reads the entire file. When set and the file
      exceeds this size, reads only the first and last portions (never loading
      the entire file into memory).
  """
  @spec read_tempfile(Path.t(), integer() | nil) :: String.t()
  def read_tempfile(path, max_bytes) do
    content =
      case File.stat(path) do
        {:ok, %{size: size}} ->
          if is_nil(max_bytes) or size <= max_bytes do
            case File.read(path) do
              {:ok, data} -> data
              {:error, _} -> ""
            end
          else
            read_truncated(path, size, max_bytes)
          end

        {:error, _} ->
          ""
      end

    _ = File.rm(path)
    content
  end

  # Reads only the first and last portions of a large file directly from disk
  # without loading the entire file into memory. Uses :file.pread/3 for
  # positioned reads and :raw/:binary mode for speed. The truncation size
  # (8192 bytes: 4096 first + 4096 last) matches OutputSanitizer.
  defp read_truncated(path, file_size, max_bytes) do
    truncate_size = 8192

    if file_size <= truncate_size do
      case File.read(path) do
        {:ok, data} -> data
        {:error, _} -> ""
      end
    else
      half_size = div(truncate_size, 2)
      omitted = file_size - truncate_size

      {:ok, device} = File.open(path, [:read, :raw, :binary])

      {:ok, first_part} = :file.pread(device, 0, half_size)
      {:ok, last_part} = :file.pread(device, file_size - half_size, half_size)

      File.close(device)

      """
      [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{truncate_size} bytes]
      The output was too large. Consider using more specific arguments
      or alternative tools to retrieve only the needed portion of data.
      #{first_part}
      ... [#{omitted} bytes omitted] ...
      #{last_part}
      """
      |> String.trim()
    end
  end

  # ---------------------------------------------------------------------------
  # Command execution (for SandboxSlice / SandboxProcessRegistry)
  # ---------------------------------------------------------------------------

  @doc """
  Runs a `System.cmd/3` and normalizes the result into `{:ok, output}` or
  `{:error, output}`.

  `System.cmd/3` raises `ErlangError(:enoent)` when the binary is missing; this
  function pre-checks executability via `System.find_executable/1` to avoid the
  exception and return an `{:error, ...}` tuple instead.
  """
  @spec system_cmd(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def system_cmd(cmd, args) do
    if System.find_executable(cmd) do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    else
      {:error, "command not found: #{cmd}"}
    end
  end
end
