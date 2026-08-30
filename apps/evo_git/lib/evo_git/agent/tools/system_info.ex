defmodule EvoGit.Agent.Tools.SystemInfo do
  @moduledoc """
  Command handler for the `system.info` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Reports local platform and
  system information.

  Pure computation with no side effects: no shell, no git, no repository
  path usage — safe for repo-less agents. Reports OS, architecture,
  hostname, local/UTC time, language runtime versions, and the data
  directory.
  """

  @doc """
  Executes the system_info tool.

  Returns a multi-line `key: value` string of local system facts. Never
  raises: the whole body runs under a tool-boundary rescue/catch (data_dir
  resolution can call `System.user_home!()`, and other system calls can fail
  in exotic environments) — a failure is reported as a readable error string.
  """
  def execute(_args, _repo_path, _repo_root) do
    [
      key_value("os", "#{EvoGit.Platform.os()} (#{inspect(:os.type())})"),
      key_value("architecture", architecture()),
      key_value("hostname", hostname()),
      key_value("local time", format_datetime(NaiveDateTime.local_now())),
      key_value("timezone", timezone()),
      key_value("utc time", format_datetime(DateTime.utc_now())),
      key_value("elixir version", System.version()),
      key_value("otp version", System.otp_release()),
      key_value("data directory", EvoGit.Platform.data_dir())
    ]
    |> Enum.join("\n")
  rescue
    e ->
      "system info unavailable: #{Exception.message(e)}"
  catch
    :exit, reason ->
      "system info unavailable: #{inspect(reason)}"
  end

  defp architecture do
    to_string(:erlang.system_info(:system_architecture))
  end

  # Best-effort hostname: `:inet.gethostname/0` first, then the HOSTNAME env
  # var, then "unknown". Never raises.
  defp hostname do
    case :inet.gethostname() do
      {:ok, name} when is_list(name) -> List.to_string(name)
      {:ok, name} when is_binary(name) -> name
      {:error, _} -> System.get_env("HOSTNAME") || "unknown"
    end
  end

  # Best-effort timezone: only the TZ env var is reported (no IANA lookup —
  # dependency-free and non-crashing). When unset, note that the local time is
  # the server's local wall clock.
  defp timezone do
    case System.get_env("TZ") do
      tz when is_binary(tz) and tz != "" -> tz
      _ -> "server local (TZ unset)"
    end
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp key_value(key, value), do: "#{key}: #{value}"
end
