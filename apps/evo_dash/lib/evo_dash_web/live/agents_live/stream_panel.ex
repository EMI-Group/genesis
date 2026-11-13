defmodule EvoDashWeb.AgentsLive.StreamPanel do
  @moduledoc """
  Inspector-only live excerpt panel, separate from checkpoint history.

  Pass the StreamWatch assign as `stream`. Rendering is bounded by
  StreamPresentation; omission notices never imply that raw history was changed.
  This panel does not label checkpoint history as a reconciled live transcript.
  Transport failures offer the page-owned `retry_inspector_stream` event.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.AgentsLive.StreamPresentation

  attr :stream, :any, default: nil

  def stream_panel(assigns) do
    assigns = assign(assigns, :view, StreamPresentation.build(state(assigns.stream)))

    ~H"""
    <section
      :if={@stream != nil}
      id="inspector-stream"
      class="space-y-3 border-b border-base-300 pb-4"
    >
      <div class="flex items-center justify-between gap-3">
        <h4 class="text-sm font-semibold">{gettext("Live activity")}</h4>
        <span id="inspector-activity" class="text-xs text-base-content/70" aria-live="polite">
          {activity_label(@view.activity)}
        </span>
      </div>
      <div :if={field(@stream, :error) != nil} class="text-xs text-error" role="alert">
        {gettext("Live updates are unavailable. Checkpoint history may be out of date.")}
        <button type="button" class="btn btn-ghost btn-xs" phx-click="retry_inspector_stream">
          {gettext("Retry")}
        </button>
      </div>
      <p
        :if={field(@stream, :snapshot) == nil and field(@stream, :error) == nil}
        class="text-xs text-base-content/70"
      >
        {gettext("Connecting to live updates…")}
      </p>
      <p class="text-xs text-base-content/60">
        {gettext(
          "Live excerpts are separate from checkpoint history; content before attachment may not have been captured."
        )}
      </p>
      <p :if={@view.omitted_messages > 0} class="text-xs text-base-content/70">
        {gettext("%{count} earlier live messages omitted from this preview.",
          count: @view.omitted_messages
        )}
      </p>
      <article
        :for={message <- @view.messages}
        id={"inspector-live-message-#{message.message_index}"}
        class="space-y-2 rounded-md border border-base-300 bg-base-200/50 p-3"
      >
        <div class="text-xs text-base-content/70">
          {gettext("Turn %{turn}", turn: message.turn || 0)}
        </div>
        <details :if={message.thinking != ""}>
          <summary class="cursor-pointer text-xs font-medium">{gettext("Thinking")}</summary>
          <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words text-xs">{message.thinking}</pre>
          <.omission count={message.omitted_thinking} />
        </details>
        <p :if={message.thinking_status == :unavailable} class="text-xs text-base-content/60">
          {gettext("No thinking was captured for this response.")}
        </p>
        <div :if={message.response != ""}>
          <div class="text-xs font-medium">{gettext("Response")}</div>
          <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words text-sm">{message.response}</pre>
          <.omission count={message.omitted_response} />
        </div>
        <ul :if={message.tool_calls != []} class="space-y-1 text-xs">
          <li :for={tool <- message.tool_calls} class="flex min-w-0 gap-2">
            <span class="min-w-0 truncate font-mono">{tool.name}</span>
            <span class="shrink-0 text-base-content/70">{tool_label(tool.status)}</span>
          </li>
        </ul>
        <p :if={message.omitted_tools > 0} class="text-xs text-base-content/70">
          {gettext("%{count} additional tool announcements omitted.", count: message.omitted_tools)}
        </p>
      </article>
    </section>
    """
  end

  attr :count, :integer, required: true

  defp omission(assigns) do
    ~H"""
    <p :if={@count > 0} class="text-xs text-base-content/70">
      {gettext("%{count} characters omitted from this preview.", count: @count)}
    </p>
    """
  end

  defp activity_label(:llm), do: gettext("Generating response")
  defp activity_label(:tool), do: gettext("Executing tools")
  defp activity_label(:idle), do: gettext("Idle")
  defp activity_label(:waiting), do: gettext("Waiting")
  defp activity_label(_), do: gettext("Activity unavailable")

  defp tool_label(:announced), do: gettext("Announced")
  defp tool_label(:ok), do: gettext("Completed")
  defp tool_label(:error), do: gettext("Failed")
  defp tool_label(:timeout), do: gettext("Timed out")
  defp tool_label(_), do: gettext("Status unavailable")

  defp state(stream), do: field(stream, :state)
  defp field(value, key) when is_map(value), do: Map.get(value, key)
  defp field(_value, _key), do: nil
end
