defmodule EvoDash.Test.ConfigDir do
  @moduledoc """
  Per-process isolation of the `~/.config/genesis` config directory for tests.

  This module is the `:evo_dash` MIRROR of `EvoGit.TestSupport.ConfigDir` (that
  file lives in `:evo_git`'s test-support dir, which is NOT on this app's
  compile path). It is the resolver behind the DEFAULT-INERT
  `:config_dir_fun` app-env seam of `EvoGit.Platform.config_dir/1`:
  `test/test_helper.exs` installs `{EvoDash.Test.ConfigDir, :resolve, []}` as
  `:config_dir_fun`, so every `EvoGit.Config.config_dir/0` call consults the
  CURRENT process (or one of its `$callers`) instead of the BEAM-global
  `XDG_CONFIG_HOME` env var. Production never sets `:config_dir_fun`, so
  production resolution stays byte-identical to the XDG/platform-directory
  behaviour.

  Both helpers use the SAME process-dictionary key (`:evogit_config_dir`), so an
  umbrella `mix test` that loads both apps' test helpers resolves identically
  whichever helper installed the fun last, and a module in either app can
  activate the override through either helper.

  ## `$callers` rule — what inherits the override

  `Process.get(:evogit_config_dir)` covers the process that called
  `activate/1`; every other process is resolved by walking the `:"$callers"`
  chain, which OTP 24+ `proc_lib` propagates from parent to child for
  `GenServer`/`Task`/`Supervisor` children started FROM the test process —
  including `Task.Supervisor.start_child/2` (the `EvoDash.SafeCall` async-load
  path). `Phoenix.LiveViewTest` additionally sets the mounted view's
  `:"$callers"` to the TEST pid explicitly
  (`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:1297`), so a mounted
  LiveView resolves the test's override AND so does every supervised load task
  the view spawns (the chain is view -> load task -> test pid).

  It does NOT cover:

    * processes with no caller chain back to the test — e.g. a raw `spawn/1`
      or `:proc_lib.spawn/1` (nothing propagates `$callers`), or a process
      started by a child that itself did not inherit one;
    * the app-global singletons started at BOOT — `EvoGit.AgentScheduler`,
      `EvoGit.TaskRegistry`, `EvoGit.Store`, `EvoGit.PeakHourEngine`. A module
      whose config reads happen INSIDE one of those (e.g. a `TaskRegistry` read
      worker, which the registry starts itself) must stay `async: false`,
      because there is no test-process ancestry to walk.

  The per-path `:persistent_term` config caches (`config.toml`,
  `version_state.toml`) are keyed by FILE PATH, so a unique directory per test
  is cache-safe.
  """

  @doc """
  The seam function installed as `:config_dir_fun` by `test/test_helper.exs`.

  Returns the override directory for the current execution context, or `nil`.
  Order: this process' own override, then the first override found in a
  `$callers` process dictionary (local node pids only).
  """
  @spec resolve() :: String.t() | nil
  def resolve do
    case Process.get(:evogit_config_dir) do
      dir when is_binary(dir) ->
        dir

      _ ->
        Process.get(:"$callers", [])
        |> Enum.find_value(fn pid -> caller_override(pid) end)
    end
  end

  @doc """
  Puts the config directory override into the CURRENT process dictionary.

  Call this from a `setup` block so the TEST process carries the override
  (children started by the test inherit it through OTP's `$callers`
  propagation).
  """
  @spec activate(String.t()) :: String.t()
  def activate(dir) when is_binary(dir) do
    Process.put(:evogit_config_dir, dir)
    dir
  end

  @doc """
  Creates a unique temporary config directory for a whole test module.

  Intended for `setup_all`: registers an `on_exit` cleanup that removes the
  directory. It does NOT touch the process dictionary, because `setup_all` runs
  in a different process than the tests — call `activate/1` from `setup`
  instead (or use `isolate!/1`).
  """
  @spec isolate_module!(String.t()) :: String.t()
  def isolate_module!(prefix \\ "evogit_config") when is_binary(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  Creates a unique temporary config directory AND activates it for the current
  (per-test) process. Returns the directory.

  Convenience for a plain `setup` block: `EvoDash.Test.ConfigDir.isolate!/1`.
  """
  @spec isolate!(String.t()) :: String.t()
  def isolate!(prefix \\ "evogit_config") when is_binary(prefix) do
    prefix |> isolate_module!() |> activate()
  end

  @doc """
  Resolves the concrete config directory the CALLING process would use.

  Convenience for assertions that need the real path rather than the override
  root: with an override active this is `<override>/genesis` (via
  `EvoGit.Platform.config_dir/0`), otherwise the platform/XDG directory.
  """
  @spec config_dir() :: String.t()
  def config_dir, do: EvoGit.Platform.config_dir()

  # Looks up a single caller's process dictionary. `Process.info/2` returns
  # `nil` for a dead pid, so that case falls through to the next caller.
  defp caller_override(pid) when is_pid(pid) do
    if node(pid) == node() do
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, :evogit_config_dir)
        nil -> nil
      end
    end
  end

  defp caller_override(_), do: nil
end
