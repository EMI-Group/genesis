defmodule EvoGit.Bench.SystemInfo do
  @moduledoc """
  Best-effort description of the host and filesystem a benchmark ran on.

  `collect/1` never raises and never aborts the report: each probe degrades to
  `nil` (or `"unknown"` for the hostname) when its executable, system call or
  parse is unavailable — including on Windows, where `df -T` does not exist.
  """

  @doc """
  Collects the host/filesystem facts for the filesystem holding `dir`.

  Returns a map with `os`, `arch`, `cpus`, `elixir`, `otp`, `hostname`,
  `git_version`, `fs_type`, `fs_device` and `mountpoint`. Only `collect/1`'s
  shape is stable — a probe that cannot answer yields `nil`.
  """
  @spec collect(Path.t()) :: map()
  def collect(dir) do
    fs = probe(fn -> fs_info(dir) end)

    %{
      os: probe(fn -> os_name() end),
      arch: probe(fn -> List.to_string(:erlang.system_info(:system_architecture)) end),
      cpus: probe(fn -> System.schedulers_online() end),
      elixir: probe(fn -> System.version() end),
      otp: probe(fn -> List.to_string(:erlang.system_info(:otp_release)) end),
      hostname: probe(fn -> hostname() end) || "unknown",
      git_version: probe(fn -> git_version() end),
      fs_type: fs[:type],
      fs_device: fs[:device],
      mountpoint: fs[:mountpoint]
    }
  end

  @doc false
  # Parses `df -T` output: the data row is the line after the header. A row
  # with fewer than 7 whitespace-separated fields (or a missing data row) is
  # unparseable and yields `nil`, so odd/wrapped output degrades instead of
  # reporting garbage.
  @spec parse_df(String.t()) ::
          %{device: String.t(), type: String.t(), mountpoint: String.t()} | nil
  def parse_df(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.at(1)
    |> parse_df_row()
  end

  # JUSTIFIED try/rescue/catch: collect/1 is a best-effort probe by contract —
  # a missing executable, an unavailable system call or a malformed response
  # must degrade to nil rather than abort the whole report. Probes are
  # independent, so one failure never masks another.
  defp probe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp os_name do
    case :os.type() do
      {:unix, :linux} -> "Linux"
      {:unix, :darwin} -> "macOS"
      {:win32, _} -> "Windows"
      {:unix, other} -> "Unix (#{other})"
      other -> inspect(other)
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, host} -> List.to_string(host)
      _ -> "unknown"
    end
  end

  defp git_version do
    case System.cmd(EvoGit.Executable.resolve("git"), ["--version"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> List.first()
      _ -> nil
    end
  end

  defp fs_info(dir) do
    case System.cmd("df", ["-T", dir], stderr_to_stdout: true) do
      {output, 0} -> parse_df(output)
      _ -> nil
    end
  end

  defp parse_df_row(nil), do: nil

  defp parse_df_row(line) do
    fields = String.split(line, ~r/\s+/, trim: true)

    if length(fields) >= 7 do
      %{
        device: Enum.at(fields, 0),
        type: Enum.at(fields, 1),
        mountpoint: List.last(fields)
      }
    else
      nil
    end
  end
end
