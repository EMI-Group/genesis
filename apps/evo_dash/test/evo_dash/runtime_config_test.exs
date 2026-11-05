defmodule EvoDash.RuntimeConfigTest do
  @moduledoc """
  Boot-time regression coverage for the REAL root `config/runtime.exs`.

  `Config.Reader.read!/2` evaluates the file exactly as a release's
  `Config.Provider` does at boot — and it RAISES on any error, which is the
  behaviour under test: any raise here aborts the whole backend start (the
  desktop sidecar then dies and the Tauri shell shows "backend unavailable").

  The pinned regression: `PHX_SERVER=true` (set by the Tauri sidecar) is the
  STRING `"true"`, and feeding an env-var string to Elixir's strict `or`
  raises `BadBooleanError` — which crashed every desktop boot.
  """

  # async: false — this module mutates OS-process-global state that a
  # concurrently running module can observe: the OS PROCESS ENVIRONMENT
  # (`System.put_env`/`delete_env` for PHX_SERVER, EVOGIT_DESKTOP, EVOGIT_SERVER,
  # EVOGIT_REMOTE_DAEMON, RELEASE_NAME, HOME, XDG_DATA_HOME, APPDATA —
  # process-wide, not per-test), the `:evo_dash` `:desktop_release` app-env
  # flag, and the `:evo_git` `:config_dir_fun` seam (installed by
  # test_helper.exs, activated per process through `EvoDash.Test.ConfigDir`).
  # It also evaluates the real runtime.exs, whose prod branches create
  # `<data_dir>/logs` and persist a secret key.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @env_keys ~w(PHX_SERVER EVOGIT_DESKTOP EVOGIT_SERVER EVOGIT_REMOTE_DAEMON RELEASE_NAME HOME XDG_DATA_HOME APPDATA)

  setup do
    original_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    original_desktop_release = Application.get_env(:evo_dash, :desktop_release)

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case original_desktop_release do
        nil -> Application.delete_env(:evo_dash, :desktop_release)
        value -> Application.put_env(:evo_dash, :desktop_release, value)
      end
    end)

    # Every mode signal starts OFF; each test opts in to exactly the signal it
    # exercises.
    Enum.each(@env_keys, &System.delete_env/1)
    Application.delete_env(:evo_dash, :desktop_release)

    # The prod branches of runtime.exs WRITE into `EvoGit.Platform.data_dir()`
    # (`<data_dir>/logs` in desktop mode, `<data_dir>/secret_key_base` in server
    # mode), so redirect the data dir into a per-test temp dir.
    # `EvoGit.Platform.base_dir/3` resolves it from XDG_DATA_HOME (Linux),
    # `System.user_home!()`/HOME (macOS) or APPDATA (Windows) — redirect all
    # three, so the guard below holds on every platform.
    data_home =
      Path.join(
        System.tmp_dir!(),
        "evogit_runtime_config-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_home)
    on_exit(fn -> File.rm_rf!(data_home) end)

    System.put_env("HOME", data_home)
    System.put_env("XDG_DATA_HOME", data_home)
    System.put_env("APPDATA", data_home)

    # runtime.exs calls `EvoGit.Config.resolve/0,1` (reads config.toml) — isolate
    # that per process so the operator's real ~/.config/genesis is never read.
    EvoDash.Test.ConfigDir.isolate!("evogit_runtime_config")

    :ok
  end

  describe "PHX_SERVER (endpoint server toggle)" do
    test ~s(PHX_SERVER="true" enables the endpoint server instead of raising BadBooleanError) do
      # The exact shape the Tauri sidecar sets at boot
      # (desktop/src-tauri/src/sidecar.rs).
      System.put_env("PHX_SERVER", "true")

      # `read!` raises on any evaluation error — this IS the regression
      # assertion (the raw string reached a strict `or` before the fix).
      cfg = read_runtime_config!(:test)

      assert get_in(cfg, [:evo_dash, EvoDashWeb.Endpoint, :server]) == true
    end

    test "PHX_SERVER unset leaves the endpoint server disabled" do
      cfg = read_runtime_config!(:test)

      refute get_in(cfg, [:evo_dash, EvoDashWeb.Endpoint, :server]) == true
    end

    test "an empty PHX_SERVER is treated as unset (presence semantics)" do
      System.put_env("PHX_SERVER", "")

      cfg = read_runtime_config!(:test)

      refute get_in(cfg, [:evo_dash, EvoDashWeb.Endpoint, :server]) == true
    end

    test ~s(any non-empty PHX_SERVER enables the server, including "false") do
      # Phoenix's generated runtime.exs presence-checks the variable, so the
      # literal string "false" still ENABLES the server. Pinned so a future
      # "parse it as a boolean" change is a deliberate decision, not a drift.
      System.put_env("PHX_SERVER", "false")

      cfg = read_runtime_config!(:test)

      assert get_in(cfg, [:evo_dash, EvoDashWeb.Endpoint, :server]) == true
    end
  end

  describe "prod config env" do
    test "desktop mode enables the endpoint server and a binary secret key base" do
      System.put_env("EVOGIT_DESKTOP", "1")

      # The real desktop boot carries BOTH desktop signals: the Tauri sidecar
      # sets EVOGIT_DESKTOP=1, and the genesis_desktop release bakes the
      # `desktop_release` app-env flag. The endpoint toggle has no desktop arm
      # of its own, so the flag is what turns `server: true` on in this env
      # (the sidecar also sets PHX_SERVER=true — covered above).
      Application.put_env(:evo_dash, :desktop_release, true)

      assert_data_dir_isolated!()

      endpoint = read_prod_endpoint()

      assert endpoint[:server] == true
      # The desktop branch of the endpoint `cond`.
      assert endpoint[:check_origin] == false
      assert is_binary(endpoint[:secret_key_base])
      assert endpoint[:secret_key_base] != ""
    end

    test "server mode enables the endpoint server and persists its secret key base" do
      System.put_env("RELEASE_NAME", "genesis_server")

      data_dir = assert_data_dir_isolated!()

      endpoint = read_prod_endpoint()

      assert endpoint[:server] == true
      assert endpoint[:check_origin] == false
      assert is_binary(endpoint[:secret_key_base])
      assert endpoint[:secret_key_base] != ""

      # Server mode persists the key inside the (isolated) data dir, so cookies
      # survive restarts — and never outside it.
      assert File.exists?(Path.join(data_dir, "secret_key_base"))
    end

    test "a legacy remote-daemon flag no longer disables the endpoint server" do
      # One instance per host: `genesis_server` serves the Phoenix dashboard
      # over HTTP and has Erlang distribution enabled/disabled at runtime on
      # that same BEAM (`EvoGit.DaemonControl`, driven by
      # `<launcher> remote start|stop`). A leftover `EVOGIT_REMOTE_DAEMON=1`
      # from an older install therefore must NOT suppress the endpoint — the
      # remote host's dashboard stays reachable.
      System.put_env("RELEASE_NAME", "genesis_server")
      System.put_env("EVOGIT_SERVER", "1")
      System.put_env("EVOGIT_REMOTE_DAEMON", "1")

      data_dir = assert_data_dir_isolated!()

      endpoint = read_prod_endpoint()

      assert endpoint[:server] == true
      assert endpoint[:check_origin] == false
      assert is_binary(endpoint[:secret_key_base])
      assert endpoint[:secret_key_base] != ""

      # Still a server (not desktop) for secret-key purposes: the instance
      # persists its own key inside the data dir.
      assert File.exists?(Path.join(data_dir, "secret_key_base"))
    end
  end

  describe "supervision tree (mode-invariant endpoint)" do
    test "the endpoint child is present with no mode signal set" do
      assert EvoDashWeb.Endpoint in EvoDash.Application.children()

      # The LIVE supervisor agrees: the endpoint child is really started (it
      # just does not accept connections in test — `server: false`).
      assert Enum.any?(Supervisor.which_children(EvoDash.Supervisor), fn {id, _, _, _} ->
               id == EvoDashWeb.Endpoint
             end)
    end

    test "a legacy remote-daemon flag cannot drop the endpoint child" do
      # Regression pin against reintroducing an env-var branch in the child
      # list: the endpoint is mode-INVARIANT.
      System.put_env("EVOGIT_REMOTE_DAEMON", "1")
      System.put_env("EVOGIT_SERVER", "1")

      children = EvoDash.Application.children()

      assert EvoDashWeb.Endpoint in children
      # ... while the desktop-only lifetime watcher stays gated on the desktop
      # env vars, which are unset here.
      refute {EvoDash.DesktopLifetime, []} in children
      refute EvoDash.DesktopLifetime in children
    end
  end

  # Reads the real runtime.exs for `env`, returning the endpoint config.
  # The prod desktop branch prints a "[desktop] Logging to file: …" line, which
  # is captured so the suite output stays clean.
  defp read_prod_endpoint do
    {endpoint, _output} =
      with_io(fn ->
        get_in(read_runtime_config!(:prod), [:evo_dash, EvoDashWeb.Endpoint])
      end)

    endpoint
  end

  defp read_runtime_config!(env) do
    Config.Reader.read!(runtime_config_path(), env: env)
  end

  # Mix runs an app's tests with cwd = that app's dir (`apps/evo_dash`); also
  # accept the repository root so a direct `mix test` from either place finds
  # the real file.
  defp runtime_config_path do
    [
      Path.expand("../../config/runtime.exs", File.cwd!()),
      Path.expand("config/runtime.exs", File.cwd!())
    ]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        raise ExUnit.AssertionError,
          message: "could not locate config/runtime.exs from cwd #{inspect(File.cwd!())}"

      path ->
        path
    end
  end

  # The prod branches write into `EvoGit.Platform.data_dir()`; refuse to
  # evaluate them against anything but the per-test temp dir created in setup.
  defp assert_data_dir_isolated! do
    data_dir = EvoGit.Platform.data_dir()

    assert String.starts_with?(data_dir, System.tmp_dir!()),
           "refusing to evaluate the prod config against a non-temp data dir: " <>
             inspect(data_dir)

    data_dir
  end
end
