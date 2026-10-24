defmodule EvoGit.Agent.BackgroundJobNotice do
  @moduledoc """
  Pure renderers that surface an agent's background shell jobs into the LLM context.

  Background jobs outlive the tool call that started them, so an uncompressed
  agent can still see them (they are in its own transcript) while a COMPRESSED
  agent may lose every trace of them once the old span is replaced by a summary.
  The two renderers here are the shared, IO-free text sources for that state:

    * `section/1` — the `<context>` sub-section carried by the runtime-context
      refresh message appended on every compression event
      (`EvoGit.Agent.ContextBuilder.build_context_block/1`), so the live job list
      is re-injected after compaction;
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
      These are THIS agent's background shell jobs (live or finished). …
      - `bash-0123456789abcdef` — running — `mix test`
      - `bash-fedcba9876543210` — completed (exit code: 0) — `mix format --check-formatted`

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
       "Read a job's output with `job_output` (pass its id) and list them with `job_list`.\n" <>
       lines)
    |> cap()
  end

  def section(_jobs), do: ""

  ## Notice (the just-finished `[NOTICE]` message)

  @doc """
  Renders ONE combined `[NOTICE]`-prefixed message for `jobs` that just reached
  a terminal status, or `nil` for `nil`/`[]` (nothing to announce).

  Shape:

      [NOTICE] 2 background shell jobs finished:
      - `bash-0123456789abcdef` — completed (exit code: 0) — `mix test`
      - `bash-fedcba9876543210` — failed (exit code: 1) — `mix credo`
      Call `job_output` with a job id to read its output, or `job_list` to see all of this agent's jobs.

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
       "\nCall `job_output` with a job id to read its output, or `job_list` to see " <>
       "all of this agent's jobs.")
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
