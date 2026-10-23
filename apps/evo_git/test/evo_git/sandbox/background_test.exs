defmodule EvoGit.Sandbox.BackgroundTest do
  @moduledoc """
  Sandbox-level coverage for the detached (background) command layer
  (`EvoGit.Sandbox.Background` / `EvoGit.Sandbox.spawn_detached/1`).

  `async: false` because the suite performs REAL OS process work that no other
  concurrently-running module may observe:

    * one genuine `spawn_detached/1` round trip — a live `sleep` child is spawned
      through a `Port` owned by this test process, then killed and probed with
      `kill -0` until the OS confirms it is gone;
    * `kill -0` liveness probes against a reaped child pid.

  Everything else is PURE and therefore needs no isolation: the systemd unit-name
  builder, the `systemctl show` / `list-units` output parsers and classifiers,
  and the `systemd-run` argv builders (`args/4` foreground vs `detached_args/5`
  background). No real systemd unit is ever started — the test environment has
  no systemd **user bus** (`EvoGit.Sandbox.Linux.enabled?/0` is false under
  `Mix.env() == :test`), so `spawn/1` always takes the plain-port path; the
  systemd/unit shape is pinned at the pure argv level only.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Platform
  alias EvoGit.Sandbox
  alias EvoGit.Sandbox.Background
  alias EvoGit.Sandbox.Helpers
  alias EvoGit.Sandbox.Linux

  @wait_timeout_ms 15_000

  setup do
    original = Application.get_env(:evo_git, :nix_enabled)
    Application.put_env(:evo_git, :nix_enabled, false)
    on_exit(fn -> Application.put_env(:evo_git, :nix_enabled, original) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Local helpers
  # ---------------------------------------------------------------------------

  # The ONE bounded wait of this file — every wait below is event-driven; the
  # budget only absorbs scheduling latency.
  defp wait_until(fun, timeout \\ @wait_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_wait_until(fun, deadline)
      end
    end
  end

  # All `-p <property>` values in a systemd-run argv, preserving PAIRING (a bare
  # element preceded by `-p` is a property; membership alone would not prove
  # that the builder emitted the flag/property pair systemd requires).
  defp property_pairs(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["-p", value] -> [value]
      _ -> []
    end)
  end

  defp property_predecessor(argv, property) do
    case Enum.find_index(argv, &(&1 == property)) do
      nil -> :not_found
      index -> Enum.at(argv, index - 1)
    end
  end

  defp contains_slice?(list, slice) do
    slice_length = length(slice)

    list
    |> Enum.chunk_every(slice_length, 1, :discard)
    |> Enum.any?(&(&1 == slice))
  end

  # POSIX liveness probe — a non-zero exit means the pid is gone (ESRCH).
  defp os_pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  defp nonexistent_path do
    Path.join(
      System.tmp_dir!(),
      "evogit_background_missing_#{System.unique_integer([:positive])}"
    )
  end

  # ---------------------------------------------------------------------------
  # unit_name/1 — the transient-unit ownership proof
  # ---------------------------------------------------------------------------

  describe "unit_name/1" do
    test "embeds the owning BEAM's OS pid and ends with the job id" do
      name = Background.unit_name("bash-0123456789abcdef")

      assert String.starts_with?(name, "genesis-job-b#{System.pid()}-")
      assert String.ends_with?(name, "bash-0123456789abcdef")
      assert name == "genesis-job-b#{System.pid()}-bash-0123456789abcdef"
    end

    test "folds characters systemd rejects in unit names to \"_\"" do
      assert Background.unit_name("bash-a/b c") ==
               "genesis-job-b#{System.pid()}-bash-a_b_c"

      folded = Background.unit_name("a b/c?d")

      assert folded == "genesis-job-b#{System.pid()}-a_b_c_d"
      refute folded =~ " "
      refute folded =~ "/"
      refute folded =~ "?"
    end

    test "preserves [A-Za-z0-9_.:-] unchanged" do
      assert Background.unit_name("a.b:c-d_9") ==
               "genesis-job-b#{System.pid()}-a.b:c-d_9"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_systemctl_show/1
  # ---------------------------------------------------------------------------

  describe "parse_systemctl_show/1" do
    test "parses Key=Value lines into a map" do
      assert Background.parse_systemctl_show(
               "ActiveState=active\nExecMainStatus=0\nExecMainCode=1\n"
             ) == %{
               "ActiveState" => "active",
               "ExecMainStatus" => "0",
               "ExecMainCode" => "1"
             }
    end

    test "trims a trailing CR and surrounding whitespace" do
      assert Background.parse_systemctl_show("ActiveState=active\r\nExecMainStatus= 0 \r\n") ==
               %{"ActiveState" => "active", "ExecMainStatus" => "0"}
    end

    test "skips lines without '=' and blank lines" do
      output = "\nActiveState=inactive\nthis line has no separator\n\nExecMainCode=1\n \n"

      assert Background.parse_systemctl_show(output) == %{
               "ActiveState" => "inactive",
               "ExecMainCode" => "1"
             }
    end

    test "returns %{} for non-binary input" do
      assert Background.parse_systemctl_show(nil) == %{}
      assert Background.parse_systemctl_show(42) == %{}
      assert Background.parse_systemctl_show(%{}) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # classify_unit_state/1 — the status table, pinned row by row
  # ---------------------------------------------------------------------------

  describe "classify_unit_state/1 — running states" do
    test "active / activating / reloading are running, whatever ExecMain* says" do
      for state <- ["active", "activating", "reloading"],
          exec <- [
            %{},
            %{"ExecMainCode" => "1", "ExecMainStatus" => "0"},
            %{"ExecMainCode" => "2", "ExecMainStatus" => "15"}
          ] do
        info = Map.put(exec, "ActiveState", state)

        assert Background.classify_unit_state(info) == {:running, nil},
               "expected {#{state}, #{inspect(exec)}} to be running"
      end
    end
  end

  describe "classify_unit_state/1 — inactive" do
    test "ExecMainCode=1 surfaces the exit status" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainCode" => "1",
               "ExecMainStatus" => "0"
             }) == {:exited, 0}

      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainCode" => "1",
               "ExecMainStatus" => "3"
             }) == {:exited, 3}
    end

    test "ExecMainCode=2 (killed by a signal) is an exit with no code" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainCode" => "2",
               "ExecMainStatus" => "0"
             }) == {:exited, nil}

      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainCode" => "2",
               "ExecMainStatus" => "143"
             }) == {:exited, nil}
    end

    test "any other / absent ExecMainCode is unknown" do
      assert Background.classify_unit_state(%{"ActiveState" => "inactive"}) == {:unknown, nil}

      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainStatus" => "0"
             }) == {:unknown, nil}

      assert Background.classify_unit_state(%{
               "ActiveState" => "inactive",
               "ExecMainCode" => "0",
               "ExecMainStatus" => "0"
             }) == {:unknown, nil}
    end
  end

  describe "classify_unit_state/1 — failed" do
    test "a signal-killed failed unit is an exit with no code" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "failed",
               "ExecMainCode" => "2"
             }) == {:exited, nil}

      assert Background.classify_unit_state(%{
               "ActiveState" => "failed",
               "ExecMainCode" => "2",
               "ExecMainStatus" => "9"
             }) == {:exited, nil}
    end

    test "a failed unit with a normal exit code surfaces that code" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "failed",
               "ExecMainCode" => "1",
               "ExecMainStatus" => "1"
             }) == {:exited, 1}
    end

    test "a failed unit with a non-numeric ExecMainStatus is an exit with no code" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "failed",
               "ExecMainCode" => "1",
               "ExecMainStatus" => "nowhere"
             }) == {:exited, nil}
    end
  end

  describe "classify_unit_state/1 — unknown inputs" do
    test "a garbled/empty map is unknown" do
      assert Background.classify_unit_state(%{}) == {:unknown, nil}
      assert Background.classify_unit_state(%{"ExecMainStatus" => "0"}) == {:unknown, nil}
    end

    test "an unknown ActiveState value is unknown" do
      assert Background.classify_unit_state(%{
               "ActiveState" => "deactivating",
               "ExecMainCode" => "1",
               "ExecMainStatus" => "0"
             }) == {:unknown, nil}
    end

    test "non-map input is unknown" do
      assert Background.classify_unit_state(nil) == {:unknown, nil}
      assert Background.classify_unit_state("ActiveState=active") == {:unknown, nil}
      assert Background.classify_unit_state([{"ActiveState", "active"}]) == {:unknown, nil}
    end
  end

  describe "the full systemctl show pipeline (parse |> classify)" do
    test "a running unit" do
      output = "ActiveState=active\nExecMainStatus=0\nExecMainCode=1\n"

      assert output |> Background.parse_systemctl_show() |> Background.classify_unit_state() ==
               {:running, nil}
    end

    test "a failed unit with an exit status" do
      output = "ActiveState=failed\nExecMainCode=1\nExecMainStatus=2\n"

      assert output |> Background.parse_systemctl_show() |> Background.classify_unit_state() ==
               {:exited, 2}
    end

    test "an inactive unit that exited cleanly" do
      output = "ActiveState=inactive\nExecMainCode=1\nExecMainStatus=0\n"

      assert output |> Background.parse_systemctl_show() |> Background.classify_unit_state() ==
               {:exited, 0}
    end

    test "unparsable output classifies as unknown, never raises" do
      assert "not systemctl output at all\n"
             |> Background.parse_systemctl_show()
             |> Background.classify_unit_state() == {:unknown, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # parse_list_units/1
  # ---------------------------------------------------------------------------

  describe "parse_list_units/1" do
    test "parses UNIT LOAD ACTIVE SUB DESCRIPTION columns into 5-tuples" do
      output = """
      genesis-job-b1234-bash-abc.service loaded active running Some job description
      genesis-job-b5678-bash-def.service loaded failed failed Another job
      """

      assert Background.parse_list_units(output) == [
               {"genesis-job-b1234-bash-abc.service", "loaded", "active", "running",
                "Some job description"},
               {"genesis-job-b5678-bash-def.service", "loaded", "failed", "failed", "Another job"}
             ]
    end

    test "collapses runs of whitespace and re-joins a multi-word description" do
      output = "  genesis-job-b1-x.service   loaded\t  active   running   a    b   c  \n"

      assert Background.parse_list_units(output) == [
               {"genesis-job-b1-x.service", "loaded", "active", "running", "a b c"}
             ]
    end

    test "skips lines with fewer than four columns and blank lines" do
      output = """
      genesis-job-b1-x.service loaded active running ok

      too few columns
      genesis-job-b2-y.service loaded inactive dead
      """

      assert Background.parse_list_units(output) == [
               {"genesis-job-b1-x.service", "loaded", "active", "running", "ok"},
               {"genesis-job-b2-y.service", "loaded", "inactive", "dead", ""}
             ]
    end

    test "returns [] for non-binary input" do
      assert Background.parse_list_units(nil) == []
      assert Background.parse_list_units(:nope) == []
      assert Background.parse_list_units(%{}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # beam_pid_from_unit/1
  # ---------------------------------------------------------------------------

  describe "beam_pid_from_unit/1" do
    test "extracts the owning BEAM pid" do
      assert Background.beam_pid_from_unit("genesis-job-b1234-bash-0123456789abcdef") ==
               {:ok, 1234}
    end

    test "accepts the .service suffix" do
      assert Background.beam_pid_from_unit("genesis-job-b1234-bash-0123456789abcdef.service") ==
               {:ok, 1234}
    end

    test "is :error for a name without the b<pid> marker" do
      assert Background.beam_pid_from_unit("genesis-job-bash-0123456789abcdef") == :error
      assert Background.beam_pid_from_unit("some-other-unit.service") == :error
    end

    test "is :error for an empty string and for non-binary input" do
      assert Background.beam_pid_from_unit("") == :error
      assert Background.beam_pid_from_unit(nil) == :error
      assert Background.beam_pid_from_unit(1234) == :error
    end
  end

  # ---------------------------------------------------------------------------
  # detached_args/5 vs args/4 — the two shapes must not drift
  # ---------------------------------------------------------------------------

  describe "Linux.detached_args/5 (background) vs Linux.args/4 (foreground)" do
    setup do
      cwd = System.tmp_dir!()
      output_path = Path.join(System.tmp_dir!(), "genesis_job_test.log")
      unit = "genesis-job-b#{System.pid()}-bash-0123456789abcdef"
      command = "echo detached-shape"

      on_exit(fn -> File.rm(output_path) end)

      detached =
        Linux.detached_args(
          cwd,
          Platform.shell(),
          Platform.shell_args(command),
          output_path,
          unit
        )

      foreground = Linux.args(cwd, Platform.shell(), Platform.shell_args(command), nil)

      %{
        cwd: cwd,
        output_path: output_path,
        unit: unit,
        command: command,
        detached: detached,
        foreground: foreground
      }
    end

    test "detached_args/5 emits the transient-unit shape", %{
      cwd: cwd,
      output_path: output_path,
      unit: unit,
      detached: detached
    } do
      assert "--user" in detached
      assert "--unit=#{unit}" in detached

      # Exactly ONE unit element — no second (generated) unit name.
      assert Enum.count(detached, &String.starts_with?(&1, "--unit=")) == 1

      # The unit outlives the client: none of the foreground flow-control flags.
      refute "--wait" in detached
      refute "--pipe" in detached
      refute "--collect" in detached

      # systemd writes the job's output itself, so BOTH stdio properties must be
      # emitted as real `-p <property>` PAIRS.
      assert "StandardOutput=append:#{output_path}" in property_pairs(detached)
      assert "StandardError=append:#{output_path}" in property_pairs(detached)

      assert property_predecessor(detached, "StandardOutput=append:#{output_path}") == "-p"
      assert property_predecessor(detached, "StandardError=append:#{output_path}") == "-p"

      # The working directory is pinned as a property pair.
      assert "WorkingDirectory=#{cwd}" in property_pairs(detached)
      assert property_predecessor(detached, "WorkingDirectory=#{cwd}") == "-p"
    end

    test "args/4 emits the foreground shape", %{detached: detached, foreground: foreground} do
      assert "--wait" in foreground
      assert "--pipe" in foreground
      assert "--collect" in foreground

      assert Enum.count(foreground, &String.starts_with?(&1, "--unit=")) == 0

      # Pin BOTH sides in one test so the shapes cannot silently converge.
      assert Enum.count(detached, &String.starts_with?(&1, "--unit=")) == 1
      refute "--wait" in detached
      refute "--pipe" in detached
      refute "--collect" in detached
    end

    test "both shapes carry the shared sandbox fragments", %{
      cwd: cwd,
      detached: detached,
      foreground: foreground
    } do
      for argv <- [foreground, detached] do
        assert "--user" in argv

        assert "WorkingDirectory=#{cwd}" in property_pairs(argv),
               "expected a `-p WorkingDirectory=#{cwd}` pair in #{inspect(argv)}"

        assert Enum.any?(argv, &String.starts_with?(&1, "--setenv=PATH=")),
               "expected a PATH forwarding element in #{inspect(argv)}"

        assert Enum.any?(argv, &String.starts_with?(&1, "--setenv=HOME=")),
               "expected a HOME forwarding element in #{inspect(argv)}"
      end
    end

    test "detached_args/5 passes the command through verbatim", %{
      command: command,
      detached: detached
    } do
      expected_tail = [Platform.shell() | Platform.shell_args(command)]

      assert contains_slice?(detached, expected_tail),
             "expected #{inspect(expected_tail)} to appear verbatim in #{inspect(detached)}"

      assert command in detached
      assert List.last(detached) == command

      # The command is NOT wrapped in an in-shell redirection — the file is
      # written by systemd itself, so the command string must reach the shell
      # untouched.
      refute Enum.any?(detached, &String.contains?(&1, ">>"))
    end

    test "the argv builders are pure — the output file is never created", %{
      output_path: output_path,
      detached: detached
    } do
      assert is_list(detached)
      refute File.exists?(output_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Totality of the detached entry points
  # ---------------------------------------------------------------------------

  describe "EvoGit.Sandbox.spawn_detached/1 — invalid specs" do
    test "missing keys are an {:error, _} tuple, never a raise" do
      assert {:error, {:invalid_spec, _}} =
               Sandbox.spawn_detached(%{command: "true", cwd: System.tmp_dir!()})

      assert {:error, {:invalid_spec, _}} = Sandbox.spawn_detached(%{})
      assert {:error, {:invalid_spec, _}} = Sandbox.spawn_detached(:not_a_spec)
      assert {:error, {:invalid_spec, _}} = Sandbox.spawn_detached(nil)
    end

    test "an empty command is rejected" do
      assert {:error, {:invalid_spec, _}} =
               Sandbox.spawn_detached(%{
                 command: "",
                 cwd: System.tmp_dir!(),
                 output_path: Path.join(System.tmp_dir!(), "genesis_job_test_invalid.log"),
                 job_id: "bash-invalid"
               })
    end

    # OBSERVED vs EXPECTED (documented divergence — `lib/` deliberately NOT
    # edited, reported instead): `EvoGit.Sandbox.Background.spawn/1`'s
    # @moduledoc claims "Every function is total: OS failures come back as
    # `{:error, term()}` and never raise." The systemd-run path DOES return
    # `{:error, {:systemd_run_failed, _}}` for an unusable cwd, but the PORT
    # path does not: OTP's `Port.open/2` accepts a `{:cd, dir}` that does not
    # exist, the child dies in the port-setup `chdir` (exit status 2, before
    # `exec`), and `spawn/1` therefore returns `{:ok, %{kind: :port, ...}}` for
    # a job that never ran. Verified directly:
    # `Port.open(..., {:cd, "/tmp/definitely_missing"})` yields a live port
    # whose only message is `{:exit_status, 2}`.
    #
    # The test below PINS that observed behavior (so a future fix to the
    # contract fails loudly here) and asserts the part that is contractual in
    # both shapes: it never raises.
    test "a non-existent cwd never raises (the port path surfaces it as a child exit)" do
      cwd = nonexistent_path()
      refute File.dir?(cwd)

      spec = %{
        command: "true",
        cwd: cwd,
        output_path: Path.join(System.tmp_dir!(), "genesis_job_test_nocwd.log"),
        job_id: "bash-nocwd"
      }

      assert {:ok, handle} = Sandbox.spawn_detached(spec)

      on_exit(fn -> Sandbox.kill_detached(handle) end)

      assert handle.kind == :port

      # The job is dead immediately (the child never exec'd), so the status must
      # not stay `{:running, nil}` forever.
      assert wait_until(fn -> Sandbox.detached_status(handle) != {:running, nil} end),
             "expected the failed-cwd job to stop reporting {:running, nil}"
    end
  end

  describe "EvoGit.Sandbox.kill_detached/1 — garbage handles" do
    test "a bogus kind is an {:error, {:invalid_handle, _}} tuple" do
      assert Sandbox.kill_detached(%{kind: :bogus}) ==
               {:error, {:invalid_handle, %{kind: :bogus}}}

      assert Sandbox.kill_detached(%{}) == {:error, {:invalid_handle, %{}}}
      assert Sandbox.kill_detached(nil) == {:error, {:invalid_handle, nil}}
      assert Sandbox.kill_detached(:not_a_handle) == {:error, {:invalid_handle, :not_a_handle}}
    end
  end

  describe "EvoGit.Sandbox.detached_status/1 — garbage handles" do
    test "reports {:unknown, nil} and never raises" do
      assert Sandbox.detached_status(%{kind: :bogus}) == {:unknown, nil}
      assert Sandbox.detached_status(%{}) == {:unknown, nil}
      assert Sandbox.detached_status(:not_a_handle) == {:unknown, nil}
      assert Sandbox.detached_status(nil) == {:unknown, nil}
    end
  end

  describe "EvoGit.Sandbox.Helpers.kill_process_tree/1 — totality" do
    test "returns :ok for a pid that is already gone" do
      # The probe child must be ALIVE long enough for `wait_for_os_pid/1` to
      # observe its pid: a child that exits in microseconds (`true`,
      # `exit 0`) auto-closes its port before the first poll, so the CORRECT
      # helper returns `:undefined` and the fixture — not the code under test —
      # would fail. `sleep 30` is killed explicitly below, and the port reaps
      # it, so the pid is provably dead before `kill_process_tree/1` runs (no
      # random live pid is ever targeted).
      port =
        Port.open(
          {:spawn_executable, System.find_executable(Platform.shell())},
          [:exit_status, :hide, {:args, Platform.shell_args("sleep 30")}]
        )

      pid = Helpers.wait_for_os_pid(port)

      assert is_integer(pid)
      assert os_pid_alive?(pid)

      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      assert_receive {^port, {:exit_status, _code}}, @wait_timeout_ms
      Helpers.close_port(port)

      assert wait_until(fn -> not os_pid_alive?(pid) end)
      assert Helpers.kill_process_tree(pid) == :ok
    end

    test "returns :ok for non-integer input and never raises" do
      assert Helpers.kill_process_tree("1234") == :ok
      assert Helpers.kill_process_tree(nil) == :ok
      assert Helpers.kill_process_tree(:nope) == :ok
      assert Helpers.kill_process_tree(%{}) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # ONE real round trip through the port path (this is what the test env uses)
  # ---------------------------------------------------------------------------

  describe "the plain port path (real OS round trip)" do
    test "spawn -> running -> kill -> gone" do
      unique = System.unique_integer([:positive])
      output_path = Path.join(System.tmp_dir!(), "evogit_background_roundtrip_#{unique}.log")

      spec = %{
        command: "sleep 30",
        cwd: System.tmp_dir!(),
        output_path: output_path,
        job_id: "bash-test#{unique}"
      }

      assert {:ok, handle} = Sandbox.spawn_detached(spec)

      # The registry is not involved here, so the port belongs to THIS process —
      # teardown must be idempotent (killing a dead job is not an error).
      on_exit(fn ->
        Sandbox.kill_detached(handle)
        File.rm(output_path)
      end)

      assert handle.kind == :port
      assert is_integer(handle.os_pid)
      assert handle.backend == EvoGit.Sandbox.Linux

      pid = handle.os_pid
      assert os_pid_alive?(pid)

      assert Sandbox.detached_status(handle) == {:running, nil}

      # The detached port path writes the file only through the registry's
      # `{:data, chunk}` handling, which is not installed here.
      refute File.exists?(output_path)

      assert Sandbox.kill_detached(handle) == :ok

      assert wait_until(fn -> not os_pid_alive?(pid) end),
             "expected the spawned child (pid #{pid}) to be gone after kill_detached/1"

      assert wait_until(fn -> Sandbox.detached_status(handle) != {:running, nil} end),
             "expected detached_status/1 to stop reporting {:running, nil} after the child died"

      # Idempotent teardown: killing it again is still :ok, never a raise.
      assert Sandbox.kill_detached(handle) == :ok
      refute File.exists?(output_path)
    end
  end
end
