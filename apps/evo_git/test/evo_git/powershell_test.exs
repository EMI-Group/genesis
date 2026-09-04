defmodule EvoGit.PowershellTest do
  use ExUnit.Case, async: true

  alias EvoGit.Powershell

  describe "powershell_executable?/1" do
    test "returns true for bare PowerShell binary names (case-insensitive)" do
      assert Powershell.powershell_executable?("powershell")
      assert Powershell.powershell_executable?("powershell.exe")
      assert Powershell.powershell_executable?("pwsh")
      assert Powershell.powershell_executable?("pwsh.exe")
      assert Powershell.powershell_executable?("POWERSHELL.EXE")
      assert Powershell.powershell_executable?("PowerShell")
    end

    test "returns true for full and partial paths to PowerShell binaries" do
      assert Powershell.powershell_executable?(
               "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
             )

      assert Powershell.powershell_executable?(
               "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
             )

      assert Powershell.powershell_executable?("/usr/bin/pwsh")
      assert Powershell.powershell_executable?("/opt/microsoft/powershell/7/pwsh")
    end

    test "returns false for non-PowerShell executables" do
      refute Powershell.powershell_executable?("bash")
      refute Powershell.powershell_executable?("git")
      refute Powershell.powershell_executable?("powershell_extra")
      refute Powershell.powershell_executable?("")
    end

    test "returns false for non-binary input" do
      refute Powershell.powershell_executable?(nil)
      refute Powershell.powershell_executable?(:powershell)
      refute Powershell.powershell_executable?(123)
    end
  end

  describe "wrap_script/1" do
    test "forces UTF-8 output and merges all streams" do
      wrapped = Powershell.wrap_script("Get-Date")
      assert wrapped =~ "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"
      assert wrapped =~ "Get-Date"
      assert String.ends_with?(wrapped, " } *>&1")
    end
  end

  describe "encode_command/1" do
    test "produces base64 of BOM-less UTF-16LE that decodes back to the wrapped script" do
      script = "Write-Output 'hello'"
      b64 = Powershell.encode_command(script)
      assert is_binary(b64)

      utf16le = Base.decode64!(b64)
      refute String.starts_with?(utf16le, <<0xFF, 0xFE>>), "UTF-16LE must not include a BOM"

      decoded = :unicode.characters_to_binary(utf16le, {:utf16, :little}, :utf8)
      assert decoded =~ script
      assert decoded =~ "OutputEncoding"
      assert decoded =~ "*>&1"
      assert decoded == Powershell.wrap_script(script)
    end

    test "handles non-BMP characters via surrogate pairs" do
      script = "Write-Output '🎉'"
      b64 = Powershell.encode_command(script)
      utf16le = Base.decode64!(b64)

      decoded = :unicode.characters_to_binary(utf16le, {:utf16, :little}, :utf8)
      assert decoded =~ "🎉"
    end
  end

  describe "invoke_args/1" do
    test "returns the exact 6-element EncodedCommand arg list" do
      cmd = "Write-Output 'hi'"
      b64 = Powershell.encode_command(cmd)

      assert Powershell.invoke_args(cmd) == [
               "-NoProfile",
               "-NonInteractive",
               "-ExecutionPolicy",
               "Bypass",
               "-EncodedCommand",
               b64
             ]
    end

    test "encoded command matches encode_command/1" do
      cmd = "Get-Date"

      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", b64] =
        Powershell.invoke_args(cmd)

      assert b64 == Powershell.encode_command(cmd)
    end
  end

  describe "transform_args/2" do
    test "transforms -Command args for PowerShell executables" do
      for exe <- ["powershell", "powershell.exe", "pwsh", "pwsh.exe", "POWERSHELL.EXE"] do
        assert {:ok, args} = Powershell.transform_args(exe, ["-Command", "echo hi"])
        assert args == Powershell.invoke_args("echo hi")
      end
    end

    test "transforms Windows-style full paths (backslash normalization)" do
      exe = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

      assert {:ok, args} = Powershell.transform_args(exe, ["-Command", "echo hi"])
      assert args == Powershell.invoke_args("echo hi")
    end

    test "never transforms non-PowerShell executables" do
      assert :error = Powershell.transform_args("bash", ["-Command", "x"])
      assert :error = Powershell.transform_args("git", ["-Command", "x"])
    end

    test "never transforms non -Command arg shapes" do
      assert :error = Powershell.transform_args("powershell", ["-NoProfile", "-Command", "x"])
      assert :error = Powershell.transform_args("powershell", ["-Command"])
      assert :error = Powershell.transform_args("powershell", [])
    end
  end

  describe "decode_output/1" do
    test "decodes UTF-16LE BOM-prefixed output" do
      utf16le = :unicode.characters_to_binary("hello", :unicode, {:utf16, :little})
      assert Powershell.decode_output(<<0xFF, 0xFE>> <> utf16le) == "hello"
    end

    test "strips UTF-8 BOM" do
      assert Powershell.decode_output(<<0xEF, 0xBB, 0xBF>> <> "hi") == "hi"
    end

    test "passes plain UTF-8 through unchanged" do
      assert Powershell.decode_output("hello 日本語") == "hello 日本語"
    end

    test "returns the original binary unchanged when UTF-16LE decode fails" do
      original = <<0xFF, 0xFE, 0x41>>
      assert Powershell.decode_output(original) == original
    end

    test "empty binary stays empty" do
      assert Powershell.decode_output("") == ""
    end

    test "decoding is idempotent" do
      utf16le = :unicode.characters_to_binary("hi there", :unicode, {:utf16, :little})
      once = Powershell.decode_output(<<0xFF, 0xFE>> <> utf16le)
      assert Powershell.decode_output(once) == once
    end
  end
end
