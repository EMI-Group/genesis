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

  # When truncating large output, keep this many bytes total (first half +
  # last half). Matches OutputSanitizer's truncation window.
  @truncate_size 8192

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

  # ---------------------------------------------------------------------------
  # Output truncation (for large command outputs)
  # ---------------------------------------------------------------------------

  @doc """
  Truncates a binary to fit within `max_bytes`, keeping the first and last
  portions so that both the beginning and end of the output remain visible.

  - When `max_bytes` is `nil`, the binary is returned unchanged (no truncation).
  - When the binary is at most `max_bytes` bytes, it is returned unchanged.
  - When the binary exceeds `max_bytes` but is at most `#{@truncate_size}`
    bytes, it is returned unchanged (not worth truncating such a small amount).
  - Otherwise, the first and last `#{@truncate_size |> div(2)}` bytes are kept
    with a truncation notice in between.

  This is used both for in-memory truncation (e.g. `run_with_partial` on
  Windows where output comes directly from `System.cmd` rather than a temp
  file) and indirectly by `read_tempfile/2`.
  """
  @spec truncate_output(binary(), integer() | nil) :: binary()
  def truncate_output(output, max_bytes) do
    size = byte_size(output)

    cond do
      is_nil(max_bytes) or size <= max_bytes ->
        output

      size <= @truncate_size ->
        output

      true ->
        half_size = div(@truncate_size, 2)
        # UTF-8-safe truncation: avoid splitting multi-byte codepoints, which
        # would produce invalid UTF-8 that crashes Jason.encode! downstream.
        first_part = EvoGit.UTF8.safe_binary_part(output, 0, half_size)
        last_part = EvoGit.UTF8.safe_binary_part_from_end(output, half_size)
        omitted = size - @truncate_size
        format_truncation_notice(first_part, last_part, omitted, max_bytes)
    end
  end

  # Shared truncation message formatting used by both truncate_output/2
  # (in-memory binary_part) and read_truncated/3 (disk reads via :file.pread).
  defp format_truncation_notice(first_part, last_part, omitted, max_bytes) do
    """
    [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]
    The output was too large. Consider using more specific arguments
    or alternative tools to retrieve only the needed portion of data.
    #{first_part}
    ... [#{omitted} bytes omitted] ...
    #{last_part}
    """
    |> String.trim()
  end

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
  # positioned reads and :raw/:binary mode for speed. The truncation notice is
  # formatted by the shared `format_truncation_notice/4` helper.
  defp read_truncated(path, file_size, max_bytes) do
    if file_size <= @truncate_size do
      case File.read(path) do
        {:ok, data} -> data
        {:error, _} -> ""
      end
    else
      half_size = div(@truncate_size, 2)
      omitted = file_size - @truncate_size

      {:ok, device} = File.open(path, [:read, :raw, :binary])

      {:ok, raw_first} = :file.pread(device, 0, half_size)
      {:ok, raw_last} = :file.pread(device, file_size - half_size, half_size)

      File.close(device)

      # The pread byte boundaries may split multi-byte UTF-8 codepoints.
      # Run each part through the UTF-8-safe helpers so the result is always
      # valid UTF-8 before formatting the truncation notice.
      first_part = EvoGit.UTF8.safe_binary_part(raw_first, 0, byte_size(raw_first))
      last_part = EvoGit.UTF8.safe_binary_part_from_end(raw_last, byte_size(raw_last))

      format_truncation_notice(first_part, last_part, omitted, max_bytes)
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
