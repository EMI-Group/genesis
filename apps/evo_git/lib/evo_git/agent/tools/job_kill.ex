defmodule EvoGit.Agent.Tools.JobKill do
  @moduledoc """
  Tool for requesting cancellation of a running background job.

  ## Result text

    * `requested cancellation of job <id>` — the kill was requested (the job's
      detached process is asked to stop; its status settles to `killed`)
    * `job <id> had already finished [status: <status>]` — the job had already
      reached a terminal status, so nothing was killed
    * an `Error: ...` line — unknown id (see `job_list`), another agent's job, a
      backend failure to stop the process, or an unreachable registry (nothing is
      known about the id then: the job was NOT killed and may still be running, so
      the caller should retry shortly)

  ## Completion notice

  Killing a job SUPPRESSES its turn-boundary completion notice: the agent itself
  requested the stop, so `[NOTICE] ... killed ...` would be redundant (this also
  holds for the already-finished reply). A `job_output` call afterwards still
  returns the output the job produced before the kill. Only a backend failure to
  stop the process leaves the notice armed, because the final status is unknown.
  """

  alias EvoGit.Agent.Tools.Boundary
  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.JobOutput
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.BackgroundJobs

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "job_kill",
      description: "Request cancellation of a running background job.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "job_id" => %{
            "type" => "string",
            "description" => "Job id returned by the tool that started the background work."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Optional short reason, recorded on the job as the cancellation detail."
          }
        },
        "required" => ["job_id"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the job_kill tool.

  Reads `job_id` (required) and an optional `reason`. The repository paths are
  ignored. Never raises: a missing/non-string argument returns the shared
  descriptive error string, every kill failure is rendered as an `Error: ...`
  string, and an unexpected raise/exit at the tool boundary is caught too.
  """
  def execute(args, _repo_path, _repo_root) do
    # Cross-GenServer boundary (BackgroundJobs): see
    # `EvoGit.Agent.Tools.Boundary` for the ONE guard rationale.
    Boundary.run(
      fn ->
        with {:ok, job_id} <- Shared.fetch_string_arg(args, "job_id") do
          kill_job(job_id, args)
        else
          {:error, message} -> Failure.error(message)
        end
      end,
      &Failure.error/1
    )
  end

  defp kill_job(job_id, args) do
    owner = BackgroundJobs.current_owner_pid()

    case BackgroundJobs.kill(job_id, reason(args), Shared.owner_opts(owner)) do
      {:ok, _job} ->
        "requested cancellation of job #{job_id}"

      {:error, {:already_finished, job}} ->
        "job #{job_id} had already finished #{JobOutput.status_line(job)}"

      # A dead registry knows NOTHING about the id, so this must never render as
      # "No background job" (that would claim the job is gone). `BackgroundJobs.kill/3`
      # answers `{:error, :registry_unavailable}` verbatim for exactly this case, and
      # `Shared.error_message/2` has no clause for it (it would `inspect` the atom).
      {:error, :registry_unavailable} ->
        Failure.error(
          "The background job service is not running, so job #{job_id} was not killed " <>
            "and may still be running. Retry shortly."
        )

      {:error, error} ->
        Failure.error(Shared.error_message(error, job_id))
    end
  end

  defp reason(args) do
    case Shared.fetch_string_arg(args, "reason") do
      {:ok, value} ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      # `reason` is optional: a missing (or non-string) value simply records none.
      {:error, _message} ->
        nil
    end
  end
end
