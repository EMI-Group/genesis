defmodule EvoGit.Sandbox.HelpersTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.Helpers

  describe "shell_escape/1" do
    test "wraps a simple argument in single quotes" do
      assert Helpers.shell_escape("hello") == "'hello'"
    end

    test "wraps an empty string in single quotes" do
      assert Helpers.shell_escape("") == "''"
    end

    test "escapes single quotes using the '\\'' sequence" do
      # it's → 'it'\''s'
      assert Helpers.shell_escape("it's") == "'it'\\''s'"
    end

    test "escapes multiple single quotes" do
      # a'b'c → 'a'\''b'\''c
      assert Helpers.shell_escape("a'b'c") == "'a'\\''b'\\''c'"
    end

    test "escapes an argument that is a single quote" do
      assert Helpers.shell_escape("'") == "''\\'''"
    end

    test "handles arguments with shell metacharacters safely" do
      # Dangerous shell metacharacters must be inside the single-quoted wrapper
      # so they are treated literally.
      escaped = Helpers.shell_escape("; rm -rf /")

      assert String.starts_with?(escaped, "'")
      assert String.ends_with?(escaped, "'")
      assert escaped == "'; rm -rf /'"
    end

    test "handles backticks and dollar signs (no interpolation inside single quotes)" do
      assert Helpers.shell_escape("$(whoami)") == "'$(whoami)'"
      assert Helpers.shell_escape("`whoami`") == "'`whoami`'"
    end
  end

  describe "truncate_output/2" do
    test "returns the binary unchanged when max_bytes is nil" do
      assert Helpers.truncate_output("hello world", nil) == "hello world"
    end

    test "returns the binary unchanged when under max_bytes" do
      assert Helpers.truncate_output("small", 100) == "small"
    end

    test "returns the binary unchanged when it exactly equals max_bytes" do
      data = String.duplicate("A", 50)
      assert Helpers.truncate_output(data, 50) == data
    end

    test "returns the binary unchanged when it exceeds max_bytes but is under truncate_size (8192)" do
      # 200 bytes exceeds max_bytes=100 but is well under the 8192 truncate_size
      data = String.duplicate("E", 200)
      assert Helpers.truncate_output(data, 100) == data
    end

    test "truncates with notice when exceeding both max_bytes and truncate_size" do
      prefix = String.duplicate("X", 100)
      suffix = String.duplicate("Z", 100)
      middle = String.duplicate("M", 20_000 - 200)
      output = Helpers.truncate_output(prefix <> middle <> suffix, 5000)

      assert output =~ "[WARNING: Output exceeded 5000 bytes and was truncated to 8192 bytes]"
      assert output =~ String.duplicate("X", 100)
      assert output =~ String.duplicate("Z", 100)
      omitted = 20_000 - 8192
      assert output =~ "... [#{omitted} bytes omitted] ..."
    end

    test "keeps first 4096 and last 4096 bytes on truncation" do
      first = String.duplicate("A", 4096)
      middle = String.duplicate("B", 10_000)
      last = String.duplicate("C", 4096)
      output = Helpers.truncate_output(first <> middle <> last, 1000)

      # The first and last 4096 bytes should be present
      assert output =~ String.duplicate("A", 4096)
      assert output =~ String.duplicate("C", 4096)
      # The middle should be omitted
      refute output =~ String.duplicate("B", 100)
    end
  end

  describe "read_tempfile/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "helpers_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, %{dir: dir}}
    end

    test "reads and deletes a small file", %{dir: dir} do
      file = Path.join(dir, "small.txt")
      File.write!(file, "hello world")

      assert Helpers.read_tempfile(file, nil) == "hello world"
      refute File.exists?(file), "temp file should be deleted after reading"
    end

    test "returns empty string for a non-existent file" do
      refute File.exists?(Path.join(System.tmp_dir!(), "definitely_nonexistent_file"))

      assert Helpers.read_tempfile(
               Path.join(System.tmp_dir!(), "definitely_nonexistent_file"),
               nil
             ) == ""
    end

    test "reads the entire file when max_bytes is nil", %{dir: dir} do
      file = Path.join(dir, "full.txt")
      content = String.duplicate("A", 1000)
      File.write!(file, content)

      assert Helpers.read_tempfile(file, nil) == content
    end

    test "reads the entire file when size is under max_bytes", %{dir: dir} do
      file = Path.join(dir, "under.txt")
      content = String.duplicate("B", 100)
      File.write!(file, content)

      assert Helpers.read_tempfile(file, 500) == content
    end

    test "truncates with warning when file exceeds max_bytes and truncate_size", %{dir: dir} do
      file = Path.join(dir, "large.txt")
      prefix = String.duplicate("X", 100)
      suffix = String.duplicate("Z", 100)
      middle = String.duplicate("M", 20_000 - 200)
      File.write!(file, prefix <> middle <> suffix)

      output = Helpers.read_tempfile(file, 5000)

      assert output =~ "[WARNING: Output exceeded 5000 bytes and was truncated to 8192 bytes]"
      assert output =~ String.duplicate("X", 100)
      assert output =~ String.duplicate("Z", 100)
      omitted = 20_000 - 8192
      assert output =~ "... [#{omitted} bytes omitted] ..."
    end

    test "reads entire file when size exceeds max_bytes but is under truncate_size", %{dir: dir} do
      file = Path.join(dir, "edge.txt")
      content = String.duplicate("E", 200)
      File.write!(file, content)

      # max_bytes=100, file=200 bytes — file exceeds max_bytes but is well
      # under truncate_size (8192), so it should be read entirely.
      assert Helpers.read_tempfile(file, 100) == content
    end
  end

  describe "task_tmpdir_path/0" do
    test "returns nil when no per-task tmpdir is installed on the process" do
      # Fresh ExUnit test process: the pdict key is unset, so `current/0`
      # returns nil and the helper yields nil.
      assert Helpers.task_tmpdir_path() == nil
    end

    test "returns the installed per-task tmpdir path" do
      dir = Path.join(System.tmp_dir!(), "evogit_task_tmp_#{System.unique_integer([:positive])}")

      # The install is process-local (test-process pdict) and read back in the
      # SAME process by `task_tmpdir_path/0`, so no cross-process cleanup is
      # needed here.
      assert EvoGit.TaskTmpdir.put_current(dir) == :ok
      assert Helpers.task_tmpdir_path() == dir
    end
  end

  describe "temp_env_vars/0" do
    test "returns [] when no per-task tmpdir is installed on the process" do
      # Fresh ExUnit test process: the pdict key is unset.
      assert EvoGit.TaskTmpdir.current() == nil
      assert Helpers.temp_env_vars() == []
    end

    test "returns TMPDIR/TMP/TEMP tuples for the installed per-task tmpdir" do
      dir = Path.join(System.tmp_dir!(), "evogit_task_tmp_#{System.unique_integer([:positive])}")

      assert EvoGit.TaskTmpdir.put_current(dir) == :ok
      on_exit(fn -> EvoGit.TaskTmpdir.put_current(nil) end)

      assert Helpers.temp_env_vars() == [{"TMPDIR", dir}, {"TMP", dir}, {"TEMP", dir}]
    end
  end

  describe "port_env/1" do
    test "converts a binary name + binary value into a charlist tuple" do
      assert Helpers.port_env([{"TMPDIR", "/tmp/x"}]) == [{~c"TMPDIR", ~c"/tmp/x"}]
    end

    test "converts a Windows-style absolute path value verbatim" do
      assert Helpers.port_env([{"TMPDIR", "C:\\Users\\x\\Temp"}]) ==
               [{~c"TMPDIR", ~c"C:\\Users\\x\\Temp"}]
    end

    test "converts the exact temp_env_vars/0 output (the real call-site input)" do
      dir = Path.join(System.tmp_dir!(), "evogit_task_tmp_#{System.unique_integer([:positive])}")

      assert EvoGit.TaskTmpdir.put_current(dir) == :ok
      on_exit(fn -> EvoGit.TaskTmpdir.put_current(nil) end)

      # The binary shape the `None` backend feeds to the raw `Port.open/2`...
      assert Helpers.temp_env_vars() == [{"TMPDIR", dir}, {"TMP", dir}, {"TEMP", dir}]

      # ...and the charlist shape `port_env/1` must convert it to at the boundary.
      assert Helpers.port_env(Helpers.temp_env_vars()) == [
               {~c"TMPDIR", String.to_charlist(dir)},
               {~c"TMP", String.to_charlist(dir)},
               {~c"TEMP", String.to_charlist(dir)}
             ]
    end

    test "passes already-charlist entries through unchanged" do
      assert Helpers.port_env([{~c"BAR", ~c"baz"}]) == [{~c"BAR", ~c"baz"}]
    end

    test "converts atom names, atom values and integer values" do
      assert Helpers.port_env([{:FOO, 42}, {~c"BAR", ~c"baz"}, {:A, :b}]) ==
               [{~c"FOO", ~c"42"}, {~c"BAR", ~c"baz"}, {~c"A", ~c"b"}]
    end

    test "returns [] for an empty list" do
      assert Helpers.port_env([]) == []
    end

    test "preserves order and entry count" do
      assert Helpers.port_env([{"A", "1"}, {"B", "2"}, {"C", "3"}]) ==
               [{~c"A", ~c"1"}, {~c"B", ~c"2"}, {~c"C", ~c"3"}]
    end
  end

  # ---------------------------------------------------------------------------
  # Port.open/2 charlist-env contract (Windows `badarg` regression)
  # ---------------------------------------------------------------------------
  #
  # `Helpers.port_env/1` exists to fix a Windows-only hard crash: the sole raw
  # `Port.open/2` in `EvoGit.Sandbox.None.run_with_partial_windows/5` passed
  # BINARY env tuples, and `:erlang.open_port/2` rejects the whole option list
  # when any `{:env, [{name, value}]}` pair holds a binary. The rejection comes
  # from the VM's option VALIDATION, which runs on EVERY platform — so the tests
  # below reproduce it on Linux CI and are deliberately NOT gated on
  # `Platform.windows?/0` (there is no Windows CI runner).
  #
  # `bash` exists on every CI runner; the guard is COMPILE-TIME so an exotic host
  # without bash yields a genuine ExUnit *skip* rather than a silent pass.
  if System.find_executable("bash") do
    describe "port_env/1 → Port.open/2 (charlist env contract)" do
      test "a raw port accepts the converted env list and delivers the env to the child" do
        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        port =
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [
                {:args, ["-c", "echo TMPDIR=$TMPDIR"]},
                {:cd, tmp_dir},
                {:env, Helpers.port_env([{"TMPDIR", tmp_dir}])}
              ]
          )

        on_exit(fn -> if Port.info(port), do: Port.close(port) end)

        {output, exit_code} = collect_port_output(port)
        if Port.info(port), do: Port.close(port)

        assert exit_code == 0
        assert output =~ "TMPDIR=#{tmp_dir}"
      end

      test "the raw binary env shape is what Port.open/2 rejects (OTP open_port/2 contract)" do
        # Documents the VM contract the bug hinged on: an unconverted binary env
        # tuple invalidates the whole option list → ArgumentError. If a future
        # OTP release relaxes this, delete this single test.
        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        assert_raise ArgumentError, fn ->
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [
                {:args, ["-c", "echo hi"]},
                {:cd, tmp_dir},
                {:env, [{"TMPDIR", tmp_dir}]}
              ]
          )
        end
      end
    end

    # -------------------------------------------------------------------------
    # Port lifecycle (os-pid lookup + idempotent close)
    # -------------------------------------------------------------------------
    #
    # `wait_for_os_pid/2` must read `Port.info(port, :os_pid)` as the tuple
    # `{:os_pid, pid}` (the shape while the port is open; `nil` once closed).
    # Comparing it against a bare integer never matched, so it always fell
    # through to `:undefined` and every timeout kill path (Windows `taskkill`,
    # bwrap `kill -TERM -<pgid>`) silently skipped the group/process-tree kill.
    # `close_port/1` is the shared idempotent close that replaces bare
    # `Port.close/1`, which RAISES on an already-closed port. Both reproduce on
    # Linux CI, so nothing here is gated on `Platform.windows?/0`.
    describe "wait_for_os_pid/2 + close_port/1 (port lifecycle)" do
      test "wait_for_os_pid/2 returns the real integer os pid of a live port, matching the child" do
        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        port =
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [{:args, ["-c", "echo $$"]}, {:cd, tmp_dir}]
          )

        on_exit(fn -> if Port.info(port), do: Port.close(port) end)

        os_pid = Helpers.wait_for_os_pid(port)
        {output, exit_code} = collect_port_output(port)

        assert exit_code == 0
        assert is_integer(os_pid)
        # The os_pid of a `spawn_executable` port IS the spawned process (bash),
        # so it must equal the `$$` bash prints for itself.
        assert os_pid == output |> String.trim() |> String.to_integer()
      end

      test "close_port/1 is nil-safe and idempotent, unlike a bare Port.close/1" do
        assert Helpers.close_port(nil) == :ok

        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        port =
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [{:args, ["-c", "echo done"]}, {:cd, tmp_dir}]
          )

        on_exit(fn -> if Port.info(port), do: Port.close(port) end)

        # Let the child exit so the port auto-closes (`{:exit_status, _}` seen).
        {output, exit_code} = collect_port_output(port)

        assert exit_code == 0
        assert output =~ "done"
        refute Port.info(port)

        # Already-closed port: both guarded closes are no-ops returning :ok.
        assert Helpers.close_port(port) == :ok
        assert Helpers.close_port(port) == :ok

        # The exact reason the guard exists: a bare close RAISES on a closed port.
        # Delete this sub-assertion only if a future OTP relaxes that contract.
        assert_raise ArgumentError, fn -> Port.close(port) end
      end

      test "wait_for_os_pid/2 returns :undefined once the port is closed explicitly" do
        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        port =
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [{:args, ["-c", "echo $$; exec sleep 5"]}, {:cd, tmp_dir}]
          )

        on_exit(fn -> if Port.info(port), do: Port.close(port) end)

        # The child is still running, so the port is live and closes cleanly.
        assert Helpers.close_port(port) == :ok
        refute Port.info(port)

        assert Helpers.wait_for_os_pid(port) == :undefined
      end

      test "wait_for_os_pid/2 returns :undefined after the child exited (port auto-closed)" do
        bash = System.find_executable("bash")
        tmp_dir = port_tmp_dir!()

        port =
          Port.open(
            {:spawn_executable, bash},
            [:binary, :exit_status, :hide, :stderr_to_stdout] ++
              [{:args, ["-c", "echo bye"]}, {:cd, tmp_dir}]
          )

        on_exit(fn -> if Port.info(port), do: Port.close(port) end)

        {output, exit_code} = collect_port_output(port)

        assert exit_code == 0
        assert output =~ "bye"
        refute Port.info(port)

        assert Helpers.wait_for_os_pid(port) == :undefined
      end
    end
  else
    @tag :skip
    test "port_env/1 → Port.open/2 charlist env contract (skipped: no bash)" do
      # Only reachable on a host without bash on PATH (CI always has bash).
    end
  end

  # A real, self-cleaning dir for the raw-port tests — used both as the child's
  # cwd and as the injected `TMPDIR` value.
  defp port_tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "helpers_port_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Mirrors `EvoGit.Sandbox.None.collect_windows_output/5`: data messages first,
  # then the terminal exit status.
  defp collect_port_output(port, acc \\ []) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}
    after
      30_000 -> flunk("raw port produced no exit status within 30s")
    end
  end

  describe "system_cmd/2" do
    test "runs a command successfully and returns {:ok, output}" do
      assert {:ok, output} = Helpers.system_cmd("echo", ["hello"])
      assert String.contains?(output, "hello")
    end

    test "returns {:error, output} for a failing command" do
      # `false` always exits with code 1
      assert {:error, _output} = Helpers.system_cmd("false", [])
    end

    test "returns {:error, _} when the command is not found" do
      assert {:error, msg} = Helpers.system_cmd("this_command_definitely_does_not_exist_xyz", [])
      assert String.contains?(msg, "command not found")
    end
  end
end
