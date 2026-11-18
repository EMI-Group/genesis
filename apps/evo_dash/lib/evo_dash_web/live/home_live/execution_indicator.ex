defmodule EvoDashWeb.HomeLive.ExecutionIndicator do
  @moduledoc """
  Concise, text-first execution feedback for the Assistant.

  `execution_indicator/1` reads the page's `chat_status`, `chat_task_status`
  and `chat_stream` (only `delta.activity` and `error`), plus an optional
  `pending_approval_count` computed from actual pending requests. It never
  reads approval response acknowledgements or infers tool success from them.

  Render it in the page's existing fixed-height interrupt/status row, beside
  `Composer.interrupt_button/1`, not in the streamed answer. Its one-line
  status region announces phase changes politely, never text/thinking chunks,
  token counts, tool arguments or result bodies. The live region deliberately
  has no `aria-busy`: that would defer the phase announcement until work ended.
  Tool rows use `tool_state/1` without live announcements. CSS owns animation through the shared
  `assistant-execution-indicator` / `assistant-execution-dot` classes and
  `data-state` / `data-busy` attributes.

  Lifecycle and watch errors outrank cached activity. Missing activity means
  only "Working…", not "Thinking" or "Running tools". A watch error means
  live updates are unavailable, not that execution failed. `busy?` denotes
  active processing, not waiting for a slot, approval or retry.
  """

  use EvoDashWeb, :html

  @doc "A stable single-line phase status; all assigns are optional."
  def execution_indicator(assigns) do
    assigns = assign(assigns, :execution, state(assigns))

    ~H"""
    <div
      id="assistant-execution-status"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      class={[
        "assistant-execution-indicator flex h-7 min-w-0 items-center gap-1.5 overflow-hidden text-xs",
        tone_class(@execution.tone)
      ]}
      data-state={@execution.state}
      data-busy={to_string(@execution.busy?)}
    >
      <span
        class="assistant-execution-dot shrink-0"
        data-state={@execution.state}
        data-busy={to_string(@execution.busy?)}
        aria-hidden="true"
      ></span>
      <span class="truncate">{@execution.label}</span>
    </div>
    """
  end

  @doc "Total phase projection from page assigns; no I/O or stream mutation."
  def state(assigns) do
    status = field(assigns, :chat_status)
    task_status = field(assigns, :chat_task_status)
    stream = field(assigns, :chat_stream)
    activity = stream |> field(:delta) |> field(:activity)
    approvals = field(assigns, :pending_approval_count)

    cond do
      status == :ended ->
        terminal_state(task_status)

      status == :cancelling ->
        presentation(:cancelling, gettext("Stopping…"), true)

      field(stream, :error) != nil ->
        presentation(:unavailable, gettext("Live updates unavailable"), false, :warning)

      is_integer(approvals) and approvals > 0 ->
        presentation(:approval, gettext("Waiting for approval"), false, :warning)

      status in [:idle, :awaiting_input] ->
        presentation(:idle, gettext("Ready for your message"), false)

      status == :running ->
        phase_state(field(activity, :phase))

      true ->
        presentation(:idle, gettext("Ready for your message"), false)
    end
  end

  @doc "Tool-result feedback based ONLY on the execution status, never approval consent."
  def tool_state(status) do
    case status do
      :running -> presentation(:running, gettext("Running"), true)
      :ok -> presentation(:ok, gettext("Done"), false)
      :error -> presentation(:error, gettext("Failed"), false, :error)
      :timeout -> presentation(:timeout, gettext("Timed out"), false, :warning)
      _ -> presentation(:unknown, gettext("Status unavailable"), false)
    end
  end

  @doc false
  def tone_class(:error), do: "text-error"
  def tone_class(:warning), do: "text-warning"
  def tone_class(_tone), do: "text-base-content/60"

  defp phase_state(:llm_waiting),
    do: presentation(:llm_waiting, gettext("Waiting for model"), false)

  defp phase_state(:llm), do: presentation(:llm, gettext("Generating response…"), true)

  defp phase_state(:llm_complete),
    do: presentation(:llm_complete, gettext("Preparing next step…"), true)

  defp phase_state(:retry_wait),
    do: presentation(:retry_wait, gettext("Waiting to retry"), false, :warning)

  defp phase_state(:tools), do: presentation(:tools, gettext("Running tools…"), true)

  defp phase_state(:compressing),
    do: presentation(:compressing, gettext("Compressing context…"), true)

  defp phase_state(:preparing),
    do: presentation(:preparing, gettext("Preparing next turn…"), true)

  defp phase_state(:idle),
    do: presentation(:idle, gettext("Preparing next step…"), false)

  defp phase_state(_phase), do: presentation(:working, gettext("Working…"), false)

  defp terminal_state(:failed),
    do: presentation(:failed, gettext("Failed"), false, :error)

  defp terminal_state(:cancelled), do: presentation(:cancelled, gettext("Stopped"), false)
  defp terminal_state(:completed), do: presentation(:completed, gettext("Completed"), false)
  defp terminal_state(_status), do: presentation(:ended, gettext("Session ended"), false)

  defp presentation(state, label, busy?, tone \\ :neutral),
    do: %{state: state, label: label, busy?: busy?, tone: tone}

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil
end
