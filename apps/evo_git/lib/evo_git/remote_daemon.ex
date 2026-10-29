defmodule EvoGit.RemoteDaemon do
  @moduledoc """
  Pure Linux/systemd command building and scope resolution for the
  `genesis_remote` daemon managed by `EvoGit.RemoteConnection`.

  ## Root targets use SYSTEM scope

  Every daemon operation targets a systemd unit named
  `genesis-remote-<target_id>`. Which systemd manager OWNS that unit depends on
  the remote SSH login user:

    * **non-root login user** → the USER manager (`systemctl --user ...` /
      `systemd-run --user ...`), driven by the user's session bus. This is the
      unchanged behavior for every existing target.
    * **root login user** (`root`, or the numeric id `0`) → the SYSTEM manager
      (`systemctl ...` / `systemd-run --system --collect ...`). A root SSH login
      usually has NO user manager and no session bus ("Failed to connect to
      bus: No medium found"), so a `--user` command can never start the daemon
      there.

  `scope_for/1` is the single place that decides the scope; every builder below
  emits the matching command so no caller hand-writes `--user`. Both scopes use
  the SAME per-target unit name, so a scope never leaves an old unit behind
  under a different name.

  Everything here is a pure string builder — no I/O, no ports. The commands are
  executed on the remote host by `EvoGit.RemoteConnection.run_ssh_command/4`,
  which additionally wraps them (`sh_wrap/1`, `/bin/sh -c '<script>'`). Every
  command below is single-quote-free so it survives any remote login shell. For
  `:user` scope every emitted command is byte-identical to the pre-root-support
  form, so non-root bootstrap behavior is unchanged.
  """

  @type scope :: :user | :system

  # Prints the remote login user; blank/failing output just yields no user.
  @login_user_probe "id -un 2>/dev/null || true"

  @doc """
  Names the remote login user from the current SSH session
  (`id -un 2>/dev/null || true`).
  """
  @spec login_user_probe_command() :: String.t()
  def login_user_probe_command, do: @login_user_probe

  @doc """
  Resolves the systemd scope for a remote login user: `:system` for `root`
  (name or numeric id `0`), `:user` for everyone else — including `nil` (the
  login user could not be determined), which keeps the historical user-manager
  behavior.
  """
  @spec scope_for(String.t() | nil) :: scope()
  def scope_for(login_user) do
    case normalize_user(login_user) do
      "root" -> :system
      "0" -> :system
      _ -> :user
    end
  end

  @doc """
  `systemctl [--user] is-active <unit> 2>/dev/null` — the daemon-running probe.
  """
  @spec is_active_command(scope(), String.t()) :: String.t()
  def is_active_command(scope, unit), do: systemctl(scope, "is-active #{unit} 2>/dev/null")

  @doc """
  `systemctl [--user] show <unit> -p Environment --value` — the launch-identity
  read used to verify RELEASE_NODE/RELEASE_COOKIE.
  """
  @spec show_environment_command(scope(), String.t()) :: String.t()
  def show_environment_command(scope, unit),
    do: systemctl(scope, "show #{unit} -p Environment --value")

  @doc """
  `systemctl [--user] reset-failed <unit> 2>/dev/null; true` — clears a stale
  unit before `systemd-run` creates a fresh one (best-effort: always exits 0).
  """
  @spec reset_failed_command(scope(), String.t()) :: String.t()
  def reset_failed_command(scope, unit) do
    systemctl(scope, "reset-failed #{unit} 2>/dev/null; true")
  end

  @doc """
  `systemctl [--user] stop <unit>` — stops the daemon unit.
  """
  @spec stop_command(scope(), String.t()) :: String.t()
  def stop_command(scope, unit), do: systemctl(scope, "stop #{unit}")

  @doc """
  `systemctl [--user] status <unit> 2>&1 | tail -20` — diagnostic status output.
  """
  @spec status_command(scope(), String.t()) :: String.t()
  def status_command(scope, unit), do: systemctl(scope, "status #{unit} 2>&1 | tail -20")

  @doc """
  Starts the daemon unit with `systemd-run`, in the given scope.

  User scope: `systemd-run --user --unit=<unit> --setenv=RELEASE_NODE=<node>
  --setenv=RELEASE_COOKIE=<cookie> <launcher> start`.

  System scope (root logins): `systemd-run --system --collect --unit=<unit>
  --setenv=RELEASE_NODE=<node> --setenv=RELEASE_COOKIE=<cookie> <launcher>
  start` — `--collect` keeps a finished unit from lingering as failed, matching
  the user-scope `reset-failed` pre-step.
  """
  @spec start_command(scope(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def start_command(:user, unit, node, cookie, launcher_path) do
    "systemd-run --user --unit=#{unit} " <>
      setenv(node, cookie) <> " #{launcher_path} start"
  end

  def start_command(:system, unit, node, cookie, launcher_path) do
    "systemd-run --system --collect --unit=#{unit} " <>
      setenv(node, cookie) <> " #{launcher_path} start"
  end

  @doc """
  The human command that prints a unit's environment:
  `systemctl [--user] show <unit> -p Environment` (the body a user types after
  `ssh <target> '...'`). Used by scope-aware diagnostics.
  """
  @spec show_environment_hint(scope(), String.t()) :: String.t()
  def show_environment_hint(scope, unit), do: systemctl(scope, "show #{unit} -p Environment")

  @doc """
  The human command that stops a unit: `systemctl [--user] stop <unit>`. Used by
  scope-aware diagnostics and remediation text.
  """
  @spec stop_hint(scope(), String.t()) :: String.t()
  def stop_hint(scope, unit), do: systemctl(scope, "stop #{unit}")

  defp systemctl(scope, args), do: "systemctl#{user_flag(scope)} #{args}"

  defp user_flag(:user), do: " --user"
  defp user_flag(:system), do: ""

  defp setenv(node, cookie) do
    "--setenv=RELEASE_NODE=#{node} --setenv=RELEASE_COOKIE=#{cookie}"
  end

  defp normalize_user(user) when is_binary(user), do: String.trim(user)
  defp normalize_user(_), do: ""
end
