defmodule EvoDashWeb.AgentsLive.StreamPanel do
  @moduledoc """
  Inspector-only current-call rows for the tail of Context Memory.

  Pass the StreamWatch assign as `stream` after checkpoint rows in the history
  list. Rendering is bounded by StreamPresentation; omission notices never imply
  that raw history was changed or that a live call matches a checkpoint row.
  Transport failures offer the page-owned `retry_inspector_stream` event.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.AgentsLive.StreamPresentation

  attr :stream, :any, default: nil

  def stream_panel(assigns) do
    assigns =
      assigns
      |> assign(:view, StreamPresentation.build(state(assigns.stream)))
      |> assign(:watch_failed, field(assigns.stream, :error) != nil)

    ~H"""
    <div :if={@stream != nil} id="inspector-stream" class="divide-y divide-base-300">
      <div :if={@view.messages == []} class="p-3">
        <.status_chrome stream={@stream} view={@view} />
      </div>
      <p :if={@view.omitted_messages > 0} class="p-3 text-xs text-base-content/70">
        {gettext("%{count} earlier live messages omitted from this preview.",
          count: @view.omitted_messages
        )}
      </p>
      <article
        :for={message <- @view.messages}
        id={"inspector-live-message-#{message.message_index}"}
        data-inspector-message={"live-#{message.message_index}"}
        class="space-y-2 p-3 hover:bg-base-300/40"
      >
        <header class="flex flex-wrap items-center gap-2 mb-1">
          <.icon
            name={EvoDashWeb.Helpers.history_entry_icon("assistant")}
            class="size-4 shrink-0"
          />
          <span class={["text-xs font-semibold", EvoDashWeb.Helpers.history_entry_color("assistant")]}>
            {gettext("assistant")}
          </span>
          <span
            :if={message.active and not @watch_failed}
            id="inspector-thinking"
            class="skeleton h-1 w-8 rounded motion-reduce:animate-none"
            role="status"
            aria-label={gettext("Generating response")}
          ></span>
          <div class="ml-auto flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="text-xs text-base-content/70">
              {gettext("Turn %{turn}", turn: message.turn || 0)}
            </span>
            <.status_chrome
              :if={message == List.last(@view.messages)}
              stream={@stream}
              view={@view}
            />
          </div>
        </header>
        <details
          :if={message.thinking != "" or message.omitted_thinking_bytes > 0}
          class="text-xs bg-base-content/5 p-2 rounded text-base-content/70"
        >
          <summary class={[
            "cursor-pointer text-xs font-medium",
            (message.active and not @watch_failed) && "inspector-thinking"
          ]}>
            {gettext("Thinking")}
          </summary>
          <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words text-xs">{message.thinking}</pre>
          <.omission count={message.omitted_thinking_bytes} />
        </details>
        <p :if={message.thinking_status == :none} class="text-xs text-base-content/60">
          {gettext("No thinking content available")}
        </p>
        <div
          :if={message.response != "" or message.omitted_response_bytes > 0}
          class="text-sm bg-primary/5 border border-primary/15 p-2 rounded text-base-content"
        >
          <div class="text-xs font-medium text-primary-standalone">{gettext("Response")}</div>
          <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words text-sm">{message.response}</pre>
          <.omission count={message.omitted_response_bytes} />
        </div>
        <span
          :if={message.active and not @watch_failed}
          id="inspector-stream-cursor"
          class="inline-block h-4 w-1.5 animate-pulse bg-primary motion-reduce:animate-none"
          aria-hidden="true"
        ></span>
        <ul :if={message.tool_calls != []} class="space-y-1 text-xs">
          <li :for={tool <- message.tool_calls} class="flex min-w-0 gap-2">
            <span class="min-w-0 truncate font-mono">{tool.name}</span>
            <.omission count={tool.omitted_name_bytes} />
            <span class="shrink-0 text-base-content/70">{tool_label(tool.status)}</span>
          </li>
        </ul>
        <p :if={message.omitted_tools > 0} class="text-xs text-base-content/70">
          {gettext("%{count} additional tool announcements omitted.", count: message.omitted_tools)}
        </p>
      </article>
    </div>
    """
  end

  attr :stream, :any, required: true
  attr :view, :map, required: true

  defp status_chrome(assigns) do
    ~H"""
    <div class="space-y-1 text-xs text-base-content/70">
      <span id="inspector-activity" aria-live="polite">
        {activity_label(@view.activity)}
      </span>
      <div :if={field(@stream, :error) != nil} class="text-error" role="alert">
        {gettext("Live updates are unavailable. Checkpoint history may be out of date.")}
        <button type="button" class="btn btn-ghost btn-xs" phx-click="retry_inspector_stream">
          {gettext("Retry")}
        </button>
      </div>
      <p :if={field(@stream, :snapshot) == nil and field(@stream, :error) == nil}>
        {gettext("Connecting to live updates…")}
      </p>
    </div>
    """
  end

  attr :count, :integer, required: true

  defp omission(assigns) do
    ~H"""
    <p :if={@count > 0} class="text-xs text-base-content/70">
      {gettext("%{count} bytes omitted from this live excerpt.", count: @count)}
    </p>
    """
  end

  defp activity_label(:llm), do: gettext("Generating response")
  defp activity_label(:tool), do: gettext("Executing tools")
  defp activity_label(:idle), do: gettext("Idle")
  defp activity_label(:waiting), do: gettext("Waiting for model capacity")
  defp activity_label(:llm_complete), do: gettext("Response generated")
  defp activity_label(:retry_wait), do: gettext("Waiting to retry")
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
