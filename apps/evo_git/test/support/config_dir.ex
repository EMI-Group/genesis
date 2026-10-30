defmodule EvoGit.TestSupport.ConfigDir do
  @moduledoc """
  Per-process isolation of the `~/.config/genesis` config directory for tests.

  This module is the default-inert seam behind `EvoGit.Platform.config_dir/1`:
  `test/test_helper.exs` installs `{EvoGit.TestSupport.ConfigDir, :resolve, []}`
  as the `:config_dir_fun` app env, so every `EvoGit.Config.config_dir/0` call
  consults the CURRENT process (or one of its `$callers`) instead of the
  BEAM-global `XDG_CONFIG_HOME` env var. Production never sets
  `:config_dir_fun`, so production resolution is byte-identical to before.

  ## Scope of the process-dictionary override

  `$callers` covers `GenServer`/`Task`/`Supervisor` children started FROM the
  test process (OTP 24+ `proc_lib` propagates `$callers`), but it does NOT cover
  the app-global singletons started at boot — `EvoGit.AgentScheduler`,
  `EvoGit.TaskRegistry`, `EvoGit.Store`, `EvoGit.PeakHourEngine`. A module whose
  config reads happen inside one of those must therefore stay `async: false`.

  The per-path `:persistent_term` config cache is keyed by FILE PATH, so a
  unique directory per test is cache-safe.
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

  Convenience for a plain `setup` block: `EvoGit.TestSupport.ConfigDir.isolate!/1`.
  """
  @spec isolate!(String.t()) :: String.t()
  def isolate!(prefix \\ "evogit_config") when is_binary(prefix) do
    prefix |> isolate_module!() |> activate()
  end

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
