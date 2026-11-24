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

  ## Evicted records (tombstones)

  A job whose record aged out of retention (a TOMBSTONE) is still listed.
  It keeps the normal line and gains ONE trailing marker naming the eviction and
  the surviving log path:

      bash-1 [bash] completed — mix test (aged out of retention; log at /path/to/genesis_job_bash-1.log)

  The marker drops its `; log at <path>` clause when the record names no log path,
  so an aged-out job is never presented as a live one.
  A normal row is byte-identical to before.
  """

  alias EvoGit.Agent.Tools.Boundary
  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared
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
    # Cross-GenServer boundary (BackgroundJobs): see
    # `EvoGit.Agent.Tools.Boundary` for the ONE guard rationale.
    Boundary.run(
      fn ->
        owner = BackgroundJobs.current_owner_pid()

        case BackgroundJobs.list(Shared.owner_opts(owner)) do
          [] -> "(no background jobs)"
          jobs when is_list(jobs) -> jobs |> Enum.map(&job_line/1) |> Enum.join("\n")
        end
      end,
      &Failure.error/1
    )
  end

  defp job_line(job) do
    "#{field(job, :id) || "unknown"} [#{field(job, :kind) || "bash"}] #{status(job)} — #{field(job, :label) || ""}" <>
      tombstone_marker(job)
  end

  # TOMBSTONE detection belongs to the registry's retention policy — NEVER
  # re-implemented here (`tombstone?/1` is true iff the record carries
  # `:evicted_reason`). The `Code.ensure_loaded?/1` guard keeps the list total on
  # a build where that policy module is not compiled yet: a LIVE row then renders
  # exactly as before.
  defp tombstone?(job) when is_map(job) do
    Code.ensure_loaded?(BackgroundJobs.Retention) and BackgroundJobs.Retention.tombstone?(job)
  end

  defp tombstone?(_job), do: false

  # ONE trailing marker on an aged-out row, so a pruned record is never read as a
  # live one. A normal row renders nothing extra.
  defp tombstone_marker(job) do
    if tombstone?(job) do
      " (aged out of retention" <> log_suffix(job) <> ")"
    else
      ""
    end
  end

  defp log_suffix(%{output_path: path}) when is_binary(path) and path != "",
    do: "; log at #{path}"

  defp log_suffix(_job), do: ""

  defp status(job) do
    case BackgroundJobs.status_string(field(job, :status)) do
      nil -> "unknown"
      text -> text
    end
  end

  defp field(job, key) when is_map(job), do: Map.get(job, key)
  defp field(_job, _key), do: nil
end
