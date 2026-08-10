defmodule EvoGit.Powershell do
  @moduledoc """
  Pure helpers for invoking PowerShell on Windows via `-EncodedCommand`.

  Spawning `powershell.exe -Command <script>` from Erlang is broken by
  construction: PowerShell does not parse `-Command` arguments with standard
  Windows argv rules — it re-joins the raw command line and re-parses it as
  PowerShell code, so quoting/escaping inserted by the Erlang VM's argument
  encoding gets mangled. When the script argument is lost, PowerShell falls
  back to interactive mode; with closed/EOF stdin it then exits 0 with no
  output at all.

  The canonical fix implemented here is `-EncodedCommand` with a
  BOM-less UTF-16LE-encoded script (immune to command-line re-parsing),
  plus a wrapper that forces UTF-8 stdout and merges all PowerShell
  streams (`*>&1`).

  This module is pure — no I/O, no process — so it is fully testable on any
  platform, including Linux CI.
  """

  @powershell_names ~w(powershell powershell.exe pwsh pwsh.exe)

  @doc """
  Returns true when `executable` names a PowerShell binary.

  Matches `"powershell"`, `"powershell.exe"`, `"pwsh"`, `"pwsh.exe"`
  (case-insensitive) and full/partial paths to them, using both Windows
  (`C:\\Windows\\...\\powershell.exe`) and forward-slash path separators.
  Any non-binary input returns false.
  """
  @spec powershell_executable?(term()) :: boolean()
  def powershell_executable?(executable) when is_binary(executable) do
    # Normalize backslashes FIRST: on Unix, Path.basename/1 does not treat
    # backslash as a path separator.
    normalized = String.replace(executable, "\\", "/")
    String.downcase(Path.basename(normalized)) in @powershell_names
  end

  def powershell_executable?(_other), do: false

  @doc """
  Wraps `script` to force UTF-8 stdout and merge all PowerShell streams.

  The wrapper runs the script inside a script block that sets
  `[Console]::OutputEncoding` to UTF-8, then redirects every stream
  (`*>&1`) so `Write-Host`/information output and errors all appear on
  stdout.
  """
  @spec wrap_script(String.t()) :: String.t()
  def wrap_script(script) when is_binary(script) do
    "& { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; " <> script <> " } *>&1"
  end

  @doc """
  Encodes a script for PowerShell `-EncodedCommand`.

  Wraps the script via `wrap_script/1`, transcodes it to UTF-16LE without a
  byte-order mark (what `-EncodedCommand` expects), and base64-encodes the
  result. `{:utf16, :little}` emits surrogate pairs correctly for non-BMP
  characters.
  """
  @spec encode_command(String.t()) :: String.t()
  def encode_command(script) when is_binary(script) do
    script
    |> wrap_script()
    |> :unicode.characters_to_binary(:unicode, {:utf16, :little})
    |> Base.encode64()
  end

  @doc """
  Returns the full PowerShell argument list for `-EncodedCommand`.

  `["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
  "-EncodedCommand", encode_command(script)]` — this is what
  `EvoGit.Platform.shell_args/1` returns on Windows.
  """
  @spec invoke_args(String.t()) :: [String.t()]
  def invoke_args(script) when is_binary(script) do
    [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-EncodedCommand",
      encode_command(script)
    ]
  end

  @doc """
  Transforms `-Command` args into `-EncodedCommand` args.

  Returns `{:ok, invoke_args(cmd)}` only when `executable` is a PowerShell
  binary AND `args` is exactly the two-element `["-Command", cmd]` shape.
  Any other executable or arg shape returns `:error` untouched — this
  prevents double-transformation of already-encoded args.
  """
  @spec transform_args(String.t(), [String.t()]) :: {:ok, [String.t()]} | :error
  def transform_args(executable, args) do
    with true <- powershell_executable?(executable),
         ["-Command", cmd] when is_binary(cmd) <- args do
      {:ok, invoke_args(cmd)}
    else
      _ -> :error
    end
  end

  @utf16le_bom <<0xFF, 0xFE>>
  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Defensively decodes PowerShell output to UTF-8. Idempotent, never crashes.

  - UTF-16LE BOM prefix (`<<0xFF, 0xFE>>`) → strip the BOM and transcode the
    rest from UTF-16LE to UTF-8; on transcode failure the original binary is
    returned unchanged.
  - UTF-8 BOM prefix (`<<0xEF, 0xBB, 0xBF>>`) → strip it.
  - Anything else (incl. empty) → unchanged.
  """
  @spec decode_output(binary()) :: binary()
  def decode_output(<<@utf16le_bom, body::binary>>) do
    case :unicode.characters_to_binary(body, {:utf16, :little}, :utf8) do
      {:error, _, _} -> <<@utf16le_bom, body::binary>>
      {:incomplete, _, _} -> <<@utf16le_bom, body::binary>>
      utf8 when is_binary(utf8) -> utf8
    end
  end

  def decode_output(<<@utf8_bom, body::binary>>), do: body

  def decode_output(binary) when is_binary(binary), do: binary
end
