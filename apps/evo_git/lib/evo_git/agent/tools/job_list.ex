defmodule EvoGit.Agent.Tools.JobList do
  @moduledoc """
  Tool for listing the calling agent's background jobs.

  ## Result text

  One line per job, newest first —

      bash-1 [bash] running — mix test
      bash-2 [bash] completed — npm run build

  — or `(no background jobs)` when this agent owns none. The kind comes from the
  job record (`bash` today); the status is the public status vocabulary of
  `EvoGit.BackgroundJobs.status_string/1`.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.BackgroundJobs

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "job_list",
      description:
        "List your background jobs (running and finished) with their ids and statuses.",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the job_list tool.

  Takes no arguments — the repository paths are ignored. Never raises: the
  registry's list API is list-shaped by contract (an unreachable registry yields
  `[]`), and an unexpected raise/exit at the tool boundary is rendered as an
  `Error: ...` string.
  """
  def execute(_args, _repo_path, _repo_root) do
    owner = BackgroundJobs.current_owner_pid()

    case BackgroundJobs.list(owner_opts(owner)) do
      [] -> "(no background jobs)"
      jobs when is_list(jobs) -> jobs |> Enum.map(&job_line/1) |> Enum.join("\n")
    end
  rescue
    e -> Failure.error(Exception.message(e))
  catch
    :exit, reason -> Failure.error(inspect(reason))
  end

  defp job_line(job) do
    "#{field(job, :id) || "unknown"} [#{field(job, :kind) || "bash"}] #{status(job)} — #{field(job, :label) || ""}"
  end

  defp status(job) do
    case BackgroundJobs.status_string(field(job, :status)) do
      nil -> "unknown"
      text -> text
    end
  end

  defp field(job, key) when is_map(job), do: Map.get(job, key)
  defp field(_job, _key), do: nil

  # The ownership fence is passed ONLY when the runner installed an owner pid;
  # otherwise an unscoped listing is used.
  defp owner_opts(nil), do: []
  defp owner_opts(pid), do: [owner_pid: pid]
end
