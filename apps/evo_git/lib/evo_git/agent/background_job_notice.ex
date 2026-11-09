defmodule EvoGit.Agent.BackgroundJobNotice do
  @moduledoc """
  Pure renderers that surface an agent's background shell jobs into the LLM context.

  Background jobs outlive the tool call that started them, so an uncompressed
  agent can still see them (they are in its own transcript) while a COMPRESSED
  agent may lose every trace of them once the old span is replaced by a summary.
  The two renderers here are the shared, IO-free text sources for that state:

    * `section/1` — the `<context>` sub-section of the runtime-context refresh
      message that `EvoGit.Agent.ContextBuilder.build_context_block/1` appends on
      every compression event. The job snapshot rides only the SUMMARISING
      (stage-2) compression path; the stage-1 prune-only path deliberately
      injects no job snapshot, so the live job list is re-injected only after a
      summary replaces the old span;
    * `notice/1` — ONE combined `[NOTICE]`-prefixed message for jobs that just
      reached a terminal status (rendered here, appended by the agent loop).

  Both are TOTAL: a `nil`/`[]` job list renders nothing, and a malformed or
  missing key on a job map never raises. Neither function performs IO, reads
  configuration or touches the process dictionary.
  """

  alias EvoGit.BackgroundJobs

  # A label is a short human description (defaulting to the command's first
  # line), so anything longer is noise in every subsequent LLM request.
  @max_label_chars 80

  # Defensive cap on the WHOLE rendered text — this is re-sent on every turn
  # after a compression, so a pathological job list must not balloon it.
  @max_rendered_chars 2_000

  # The statuses `EvoGit.BackgroundJobs.status_string/1` accepts. Checked here
  # first so a malformed record can never raise a `FunctionClauseError`.
  @statuses [:running, :stopping, :completed, :killed, :failed]

  ## Section (the `<context>` sub-section)

  @doc """
  Renders the `## Background Jobs` `<context>` sub-section for `jobs`.

  Returns `""` (so `EvoGit.Agent.ContextBuilder.blank?/1` drops it) for `nil`
  or `[]` — an agent with no background jobs keeps a byte-identical context
  block.

  Non-empty shape (one line per job, newest first as handed in):

      ## Background Jobs
      These are THIS agent's background shell jobs, live or finished. Read a job's output by calling `job_output` with that job's id as `job_id` (the id shown in backticks on each line below), and list them with `job_list`.
      - `bash-1` — running — `mix test`
      - `bash-2` — completed (exit code: 0) — `mix format --check-formatted`

  The orientation line deliberately names no concrete id: a fabricated example
  (`bash-1`) can collide with a REAL job of another snapshot, so it points at
  the ids the per-job lines already render instead.

  Each job line is `- `id` — status (detail) — label`; the parenthesised
  `detail` is omitted when absent/blank, and the ` — label` segment is omitted
  when the job carries no usable label. Labels have newlines folded into
  spaces and are truncated to #{@max_label_chars} characters; the whole text is
  capped at ~#{@max_rendered_chars} characters.
  """
  @spec section([map()] | nil) :: String.t()
  def section(nil), do: ""

  def section([]), do: ""

  def section(jobs) when is_list(jobs) do
    lines = Enum.map_join(jobs, "\n", &job_line/1)

    ("## Background Jobs\n" <>
       "These are THIS agent's background shell jobs, live or finished. " <>
       "Read a job's output by calling `job_output` with that job's id as `job_id` " <>
       "(the id shown in backticks on each line below), and list them with `job_list`.\n" <>
       lines)
    |> cap()
  end

  def section(_jobs), do: ""

  ## Notice (the just-finished `[NOTICE]` message)

  @doc """
  Renders ONE combined `[NOTICE]`-prefixed message for `jobs` that just reached
  a terminal status, or `nil` for `nil`/`[]` (nothing to announce).

  Shape (the trailing instruction line uses the FIRST job's id — jobs are
  handed in newest first — so the copy-ready `job_id` spelling is literal):

      [NOTICE] 2 background shell jobs finished:
      - `bash-1` — completed (exit code: 0) — `mix test`
      - `bash-2` — failed (exit code: 1) — `mix credo`
      Call `job_output` with job_id "bash-1" to read that job's output, or `job_list` to see all of this agent's jobs.

  When the first job carries no usable id (nil, non-map or blank), the line
  falls back to the generic wording that names no concrete `job_id` value, so
  the notice never promises an id it cannot keep.

  Never raises on a malformed/missing job key, and the whole text is capped at
  ~#{@max_rendered_chars} characters.
  """
  @spec notice([map()] | nil) :: String.t() | nil
  def notice(nil), do: nil

  def notice([]), do: nil

  def notice(jobs) when is_list(jobs) do
    count = length(jobs)

    ("[NOTICE] #{count} background shell #{plural(count)} finished:\n" <>
       Enum.map_join(jobs, "\n", &job_line/1) <>
       "\n" <> instruction_line(first_job_id(jobs)))
    |> cap()
  end

  def notice(_jobs), do: nil

  ## Rendering internals

  defp job_line(job) when is_map(job) do
    "- " <> id_text(job) <> " — " <> status_text(job) <> label_suffix(job)
  end

  defp job_line(_job), do: "- (unrecognized background job record)"

  defp id_text(job) do
    case Map.get(job, :id) do
      id when is_binary(id) ->
        case flatten(id) do
          "" -> "(unknown id)"
          text -> "`" <> text <> "`"
        end

      _other ->
        "(unknown id)"
    end
  end

  # The FIRST job's usable id: the copy-ready `job_id` spelling the notice
  # shows. Total: an empty list, a non-map first element, a missing/non-binary
  # id or a blank id all yield `nil` so the renderer falls back to a generic
  # line. Only ever called with a list (the caller guards on `is_list/1`).
  defp first_job_id(jobs) when is_list(jobs), do: usable_id(List.first(jobs))

  defp usable_id(job) when is_map(job) do
    case Map.get(job, :id) do
      id when is_binary(id) ->
        case flatten(id) do
          "" -> nil
          text -> text
        end

      _other ->
        nil
    end
  end

  defp usable_id(_job), do: nil

  # Names the exact parameter (`job_id`) when a real id is available; the
  # generic wording otherwise, so the notice never promises a fake spelling.
  defp instruction_line(first_id) when is_binary(first_id) do
    "Call `job_output` with job_id \"#{first_id}\" to read that job's output, or " <>
      "`job_list` to see all of this agent's jobs."
  end

  defp instruction_line(_first_id) do
    "Call `job_output` with a job id to read its output, or `job_list` to see " <>
      "all of this agent's jobs."
  end

  defp status_text(job) do
    status = render_status(Map.get(job, :status))

    case Map.get(job, :detail) do
      detail when is_binary(detail) ->
        case flatten(detail) do
          "" -> status
          text -> "#{status} (#{text})"
        end

      _other ->
        status
    end
  end

  defp render_status(status) when status in @statuses, do: BackgroundJobs.status_string(status)

  defp render_status(status) when is_binary(status) do
    case flatten(status) do
      "" -> "unknown"
      text -> text
    end
  end

  defp render_status(nil), do: "unknown"

  defp render_status(other), do: inspect(other)

  defp label_suffix(job) do
    case Map.get(job, :label) do
      label when is_binary(label) ->
        case label |> flatten() |> truncate(@max_label_chars) do
          "" -> ""
          text -> " — " <> text
        end

      _other ->
        ""
    end
  end

  # Fold every whitespace run (newlines included) into ONE space so a job line
  # can never break the markdown list.
  defp flatten(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp cap(text) do
    if String.length(text) > @max_rendered_chars do
      String.slice(text, 0, @max_rendered_chars) <> "\n[... more background jobs omitted]"
    else
      text
    end
  end

  defp plural(1), do: "job"
  defp plural(_count), do: "jobs"
end
