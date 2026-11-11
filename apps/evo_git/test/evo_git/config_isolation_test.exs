defmodule EvoGit.ConfigIsolationTest do
  use ExUnit.Case, async: false
  alias EvoGit.{Config, Platform}

  setup do
    base = Path.join(System.tmp_dir!(), "config_isolation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    env = Map.take(System.get_env(), ["APPDATA", "XDG_CONFIG_HOME"])
    dictionary = Process.delete(:evogit_config_dir)
    System.put_env("APPDATA", Path.join(base, "host"))
    System.put_env("XDG_CONFIG_HOME", Path.join(base, "tests"))

    on_exit(fn ->
      for key <- ["APPDATA", "XDG_CONFIG_HOME"] do
        if env[key], do: System.put_env(key, env[key]), else: System.delete_env(key)
      end

      if dictionary, do: Process.put(:evogit_config_dir, dictionary)
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  test "unscoped processes retain a platform independent suite override", %{base: base} do
    host = Path.join([base, "host", "genesis"])
    File.mkdir_p!(host)
    sentinel = Path.join(host, "config.toml")
    File.write!(sentinel, "user configuration")
    parent = self()

    spawn(fn ->
      override = EvoGit.TestSupport.ConfigDir.resolve()
      path = Config.config_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "test configuration")
      send(parent, {:resolved, override, path})
    end)

    assert_receive {:resolved, override, path}
    assert override == Path.join(base, "tests")
    assert path == Path.join([base, "tests", "genesis", "config.toml"])
    assert File.read!(sentinel) == "user configuration"
  end

  test "missing XDG setting still resolves inside this test run" do
    System.delete_env("XDG_CONFIG_HOME")
    expected = Application.fetch_env!(:evo_git, :test_config_root)
    parent = self()
    spawn(fn -> send(parent, {:fallback, Platform.config_dir()}) end)
    assert_receive {:fallback, path}
    assert path == Path.join(expected, "genesis")
  end

  test "per-test override takes precedence over the suite fallback", %{base: base} do
    EvoGit.TestSupport.ConfigDir.activate(Path.join(base, "specific"))
    assert Platform.config_dir() == Path.join([base, "specific", "genesis"])
  end
end
