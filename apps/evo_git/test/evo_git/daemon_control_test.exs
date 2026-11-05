defmodule EvoGit.DaemonControlTest do
  # `async: true` — every test drives the control plane against its OWN temp
  # directory with an opts-injected fake distribution module (and, where it
  # matters, a fake signal installer). No app env, no `:persistent_term`, no
  # real distribution, no signal handler, and every GenServer is registered
  # under a unique name.
  use ExUnit.Case, async: true

  alias EvoGit.DaemonControl

  # Echoes its arguments into the answer, so argument propagation (node,
  # cookie, port) is provable from dist.env alone.
  defmodule EchoDist do
    @moduledoc false
    def enable_runtime(node, cookie, port),
      do: {:ok, %{node: "#{node}|#{cookie}", dist_port: port}}

    def disable_runtime, do: :ok
    def active, do: %{enabled: false, node: "nonode@nohost", dist_port: nil}
  end

  defmodule FailingDist do
    @moduledoc false
    def enable_runtime(_node, _cookie, _port), do: {:error, :boom}
    def disable_runtime, do: {:error, :boom}
    def active, do: %{enabled: false, node: "nonode@nohost", dist_port: nil}
  end

  defmodule RaisingDist do
    @moduledoc false
    def enable_runtime(_node, _cookie, _port), do: raise("kaboom")
    def disable_runtime, do: raise("kaboom")
    def active, do: %{enabled: false, node: "nonode@nohost", dist_port: nil}
  end

  # Re-adopts a durable intent: `enable_runtime/3` reports the call back to
  # whoever STARTED the control plane (`$ancestors` → the test process), so the
  # adoption call is provable without app env or any other global state.
  defmodule AdoptingDist do
    @moduledoc false
    def enable_runtime(node, cookie, port) do
      notify({:adopted, node, cookie, port})
      {:ok, %{node: node, dist_port: port}}
    end

    def disable_runtime, do: :ok
    def active, do: %{enabled: true, node: "adopted@127.0.0.1", dist_port: 9000}

    defp notify(message) do
      case Process.get(:"$ancestors") do
        [parent | _rest] when is_pid(parent) -> send(parent, message)
        _other -> :ok
      end
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_daemon_control_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  describe "handle_control_request/2 — enable" do
    test "publishes the actual state, echoes SEQ and records the durable intent", %{dir: dir} do
      write_request(
        dir,
        "ACTION=enable\nNODE=genesis_remote_1@127.0.0.1\nCOOKIE=s3cret\nDIST_PORT=9000\nSEQ=7\n"
      )

      assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_DIST_ENABLED"] == "1"
      assert env["GENESIS_NODE"] == "genesis_remote_1@127.0.0.1|s3cret"
      assert env["GENESIS_DIST_PORT"] == "9000"
      assert env["GENESIS_CONTROL_SEQ"] == "7"

      assert env["GENESIS_CONTROL_MESSAGE"] ==
               "distribution enabled on genesis_remote_1@127.0.0.1|s3cret:9000"

      desired = desired_env(dir)
      assert desired["ENABLED"] == "1"
      assert desired["NODE"] == "genesis_remote_1@127.0.0.1"
      assert desired["COOKIE"] == "s3cret"
      assert desired["DIST_PORT"] == "9000"

      refute File.exists?(Path.join(dir, "control.request"))
      assert File.exists?(Path.join(dir, "dist.env"))
    end
  end

  describe "handle_control_request/2 — disable" do
    test "reports disabled state and clears the durable intent", %{dir: dir} do
      write_request(dir, "ACTION=disable\nSEQ=8\n")

      assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_DIST_ENABLED"] == "0"
      assert env["GENESIS_CONTROL_SEQ"] == "8"
      assert env["GENESIS_CONTROL_MESSAGE"] == "distribution disabled"

      # A disabled node keeps NO node name or cookie around as durable intent.
      assert desired_env(dir) == %{"ENABLED" => "0"}
      refute File.exists?(Path.join(dir, "control.request"))
    end
  end

  describe "handle_control_request/2 — SEQ echo" do
    test "an absent SEQ is echoed as empty", %{dir: dir} do
      write_request(dir, "ACTION=disable\n")

      assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_CONTROL_SEQ"] == ""
    end
  end

  describe "handle_control_request/2 — invalid requests" do
    for {label, body} <- [
          {"unknown ACTION", "ACTION=explode\nSEQ=1\n"},
          {"missing ACTION", "SEQ=1\n"},
          {"malformed", "this is not a request file\nSEQ=1\n"},
          {"missing NODE", "ACTION=enable\nCOOKIE=c\nDIST_PORT=9000\nSEQ=1\n"},
          {"empty NODE", "ACTION=enable\nNODE=  \nCOOKIE=c\nDIST_PORT=9000\nSEQ=1\n"},
          {"missing DIST_PORT", "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nSEQ=1\n"},
          {"non-numeric DIST_PORT",
           "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=abc\nSEQ=1\n"},
          {"negative DIST_PORT",
           "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=-5\nSEQ=1\n"},
          {"zero DIST_PORT", "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=0\nSEQ=1\n"}
        ] do
      test "a #{label} request reports an error and is deleted", %{dir: dir} do
        write_request(dir, unquote(body))

        assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

        env = dist_env(dir)
        assert env["GENESIS_CONTROL_RESULT"] == "error"
        assert env["GENESIS_CONTROL_MESSAGE"] != ""
        # The caller still gets its SEQ back — that is how it correlates.
        assert env["GENESIS_CONTROL_SEQ"] == "1"
        refute File.exists?(Path.join(dir, "control.request"))
        # A failed action never establishes (or clears) durable intent.
        refute File.exists?(Path.join(dir, "desired.env"))
      end
    end

    test "a failing distribution call reports the reason", %{dir: dir} do
      write_request(dir, "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=9000\nSEQ=2\n")

      assert :ok = DaemonControl.handle_control_request(dir, FailingDist)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "error"
      assert env["GENESIS_CONTROL_MESSAGE"] =~ "boom"
    end

    test "a failed action leaves an existing durable intent untouched", %{dir: dir} do
      File.write!(
        Path.join(dir, "desired.env"),
        "ENABLED=1\nNODE=old@127.0.0.1\nCOOKIE=old\nDIST_PORT=9000\n"
      )

      write_request(dir, "ACTION=enable\nNODE=new@127.0.0.1\nCOOKIE=new\nDIST_PORT=9001\nSEQ=3\n")

      assert :ok = DaemonControl.handle_control_request(dir, FailingDist)

      assert desired_env(dir) == %{
               "ENABLED" => "1",
               "NODE" => "old@127.0.0.1",
               "COOKIE" => "old",
               "DIST_PORT" => "9000"
             }
    end

    test "an unexpected raise is contained: the report is written and the process survives",
         %{dir: dir} do
      name = unique_name()

      start_supervised!(
        {DaemonControl, dir: dir, dist: RaisingDist, signal_install: fn -> :ok end, name: name}
      )

      write_request(dir, "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=9000\nSEQ=4\n")

      assert :ok = DaemonControl.reload(name)
      assert :ok = DaemonControl.sync(name)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "error"
      assert env["GENESIS_CONTROL_MESSAGE"] =~ "kaboom"
      assert env["GENESIS_CONTROL_SEQ"] == "4"
      refute File.exists?(Path.join(dir, "control.request"))
      assert Process.alive?(Process.whereis(name))
      assert %{dir: ^dir} = :sys.get_state(name)
    end
  end

  describe "handle_control_request/2 — no request pending" do
    test "is a true no-op: dist.env is neither created nor rewritten", %{dir: dir} do
      path = Path.join(dir, "dist.env")
      File.write!(path, "GENESIS_DIST_ENABLED=1\n")

      assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

      assert File.read!(path) == "GENESIS_DIST_ENABLED=1\n"
      refute File.exists?(Path.join(dir, "desired.env"))
    end
  end

  describe "init/1 boot state" do
    test "re-adopts a durable ENABLED=1 intent and publishes the actual state", %{dir: dir} do
      File.write!(
        Path.join(dir, "desired.env"),
        "ENABLED=1\nNODE=genesis_remote_9@127.0.0.1\nCOOKIE=abc\nDIST_PORT=9000\n"
      )

      # Started LINKED to the test process (not via start_supervised!/1) so the
      # fake's `$ancestors`-based report lands in this test's mailbox; a normal
      # test exit does not take a linked process down, so stop it explicitly.
      {:ok, pid} =
        DaemonControl.start_link(
          dir: dir,
          dist: AdoptingDist,
          signal_install: fn -> :ok end,
          name: unique_name()
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert Process.alive?(pid)
      assert_receive {:adopted, "genesis_remote_9@127.0.0.1", "abc", 9000}

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_DIST_ENABLED"] == "1"
      assert env["GENESIS_NODE"] == "adopted@127.0.0.1"
      assert env["GENESIS_DIST_PORT"] == "9000"
      assert env["GENESIS_CONTROL_SEQ"] == ""
    end

    test "publishes a disabled state for a non-distributed node and writes no intent", %{dir: dir} do
      start_supervised!(
        {DaemonControl,
         dir: dir, dist: EchoDist, signal_install: fn -> :ok end, name: unique_name()}
      )

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_DIST_ENABLED"] == "0"
      assert env["GENESIS_NODE"] == "nonode@nohost"
      assert env["GENESIS_DIST_PORT"] == "unknown"
      assert env["GENESIS_CONTROL_SEQ"] == ""
      refute File.exists?(Path.join(dir, "desired.env"))
    end
  end

  describe "reload/1" do
    test "processes a request dropped after boot", %{dir: dir} do
      name = unique_name()

      start_supervised!(
        {DaemonControl, dir: dir, dist: EchoDist, signal_install: fn -> :ok end, name: name}
      )

      write_request(dir, "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=9000\nSEQ=9\n")

      assert :ok = DaemonControl.reload(name)
      assert :ok = DaemonControl.sync(name)

      env = dist_env(dir)
      assert env["GENESIS_CONTROL_RESULT"] == "ok"
      assert env["GENESIS_CONTROL_SEQ"] == "9"
      assert env["GENESIS_DIST_ENABLED"] == "1"
      assert desired_env(dir)["ENABLED"] == "1"
      refute File.exists?(Path.join(dir, "control.request"))
    end
  end

  describe "state file shape" do
    test "dist.env and desired.env are 0600 and no temp file is left behind", %{dir: dir} do
      write_request(dir, "ACTION=enable\nNODE=n@127.0.0.1\nCOOKIE=c\nDIST_PORT=9000\nSEQ=5\n")

      assert :ok = DaemonControl.handle_control_request(dir, EchoDist)

      for file <- ["dist.env", "desired.env"] do
        stat = File.stat!(Path.join(dir, file))
        assert Bitwise.band(stat.mode, 0o777) == 0o600, "#{file} must be 0600"
      end

      # Only the two published files remain: the request is consumed and the
      # atomic-write temp file was renamed away.
      assert Enum.sort(File.ls!(dir)) == ["desired.env", "dist.env"]
    end
  end

  describe "SIGHUP installer seam" do
    test "init/1 runs the injected installer exactly once", %{dir: dir} do
      test_pid = self()

      start_supervised!(
        {DaemonControl,
         dir: dir,
         dist: EchoDist,
         signal_install: fn -> send(test_pid, :signal_installed) end,
         name: unique_name()}
      )

      assert_receive :signal_installed
      refute_receive :signal_installed, 20
    end

    # `EVOGIT_NO_SIGNAL_HOOK` is a process-wide OS env var, but NOTHING else in
    # the suite reads it (only EvoGit.DaemonControl's installer path, which the
    # test env never starts), and this module's own tests run sequentially, so
    # no concurrently running module can observe the flip.
    test "EVOGIT_NO_SIGNAL_HOOK=1 skips the installer entirely", %{dir: dir} do
      test_pid = self()
      previous = System.get_env("EVOGIT_NO_SIGNAL_HOOK")

      System.put_env("EVOGIT_NO_SIGNAL_HOOK", "1")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("EVOGIT_NO_SIGNAL_HOOK")
          value -> System.put_env("EVOGIT_NO_SIGNAL_HOOK", value)
        end
      end)

      start_supervised!(
        {DaemonControl,
         dir: dir,
         dist: EchoDist,
         signal_install: fn -> send(test_pid, :signal_installed) end,
         name: unique_name()}
      )

      refute_receive :signal_installed, 20
      # The control plane itself still booted and published its state.
      assert dist_env(dir)["GENESIS_CONTROL_RESULT"] == "ok"
    end
  end

  ## Helpers

  defp unique_name, do: :"daemon_control_test_#{System.unique_integer([:positive])}"

  defp write_request(dir, contents) do
    File.write!(Path.join(dir, "control.request"), contents)
  end

  defp dist_env(dir), do: read_kv(Path.join(dir, "dist.env"))
  defp desired_env(dir), do: read_kv(Path.join(dir, "desired.env"))

  defp read_kv(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end
end
