defmodule EvoDashWeb.AgentsLive.HistoryEntry do
  @moduledoc """
  The ONE renderer for a single inspector history entry's BODY.

  The Agents page shows the same checkpoint entries twice: compact rows inside
  the "Chat History / Session Memory" panel and the FULL-message modal opened
  from a row's expand button. Both call `history_entry_body/1` so a new entry
  type is added in exactly one `case`.

  The two surfaces are deliberately NOT identical, and the difference is
  expressed by the `:surface` attr rather than by duplicated `case` arms:

    * `:row` — compact. Long bodies are TRUNCATED (complete results 500 chars,
      reasoning 200, response/system/user 300, tool results 500) and the raw
      fallback payload is rendered through `Render.data/1` so a huge term can
      never allocate an unbounded `inspect/1`.
    * `:modal` — full fidelity. The same bodies render untruncated (through
      `safe_text/1` where the payload may be a non-binary) and pretty-printed
      through `Render.args/1` / `Render.data/1`.

  Every element id, class, attribute and interpolation placement is preserved
  from the previous inline templates: the render tests query these exact rows
  (`#agent-history-entry-<id>-<index>`, `[data-inspector-reasoning]`,
  `<pre class="text-sm whitespace-pre-wrap">`, …).

  The inline thinking body must stay flush with its opening tag: the element is
  `whitespace-pre-wrap`, so any newline the template emitted between the tag and
  the interpolation would render as a spurious leading indent (regression test:
  "the inline thinking body does not start with template whitespace").
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.AgentsLive.{Render, ToolCallDisplay}

  # Row-surface truncation limits. The modal never truncates.
  @complete_limit 500
  @reason_limit 200
  @reasoning_limit 200
  @text_limit 300
  @tool_content_limit 500

  # The `~H` sigil's template body is not seen by the module-attribute usage
  # tracker, so the template reads each limit through a function accessor.
  defp complete_limit, do: @complete_limit
  defp reason_limit, do: @reason_limit
  defp reasoning_limit, do: @reasoning_limit
  defp text_limit, do: @text_limit
  defp tool_content_limit, do: @tool_content_limit

  attr :entry, :map, required: true
  attr :surface, :atom, values: [:row, :modal], required: true

  @doc """
  Renders one history entry's body for the `:row` list or the `:modal` view.
  """
  def history_entry_body(assigns) do
    ~H"""
    <%= case @entry.type do %>
      <% "USER_PROMPT" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap"><%= safe_text(@entry.data.content) %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-info/10 p-2 rounded">
            {@entry.data.content}
          </div>
        <% end %>
      <% "THOUGHT_CHUNK" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap"><%= @entry.data.text %></pre>
        <% else %>
          <div class="text-sm mt-1">
            {@entry.data.text}
          </div>
        <% end %>
      <% "TOOL_CALL_START" -> %>
        <%= if @surface == :modal do %>
          <div class="font-semibold mb-2">{@entry.data.name}</div>
          <pre class="text-sm"><%= Render.args(@entry.data.args) %></pre>
        <% else %>
          <div class="text-xs mt-1 bg-accent/10 p-2 rounded text-accent">
            <div class="font-semibold">{@entry.data.name}</div>
            <pre class="mt-1 overflow-x-auto"><%= Render.args(@entry.data.args) %></pre>
          </div>
        <% end %>
      <% "COMPLETE" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap"><%= safe_text(result_text(@entry.data)) %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-success/10 p-2 rounded text-success">
            {truncate_text(result_text(@entry.data), complete_limit())}
          </div>
        <% end %>
      <% "ERROR" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap text-error"><%= @entry.data.error %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-error/10 p-2 rounded text-error">
            {@entry.data.error}
          </div>
        <% end %>
      <% "RETRY" -> %>
        <%= if @surface == :modal do %>
          <div class="font-semibold mb-2">
            {gettext("Retry attempt %{attempt}", attempt: @entry.data.attempt)}
          </div>
          <pre class="text-sm whitespace-pre-wrap"><%= @entry.data.reason %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-warning/10 p-2 rounded text-warning">
            <div class="font-semibold">
              {gettext("Retry attempt %{attempt}", attempt: @entry.data.attempt)}
            </div>
            <div class="text-xs mt-1">
              {truncate_text(@entry.data.reason, reason_limit())}
            </div>
          </div>
        <% end %>
      <% "RETRY_DISPATCH" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm"><%= Render.data(@entry.data) %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-warning/10 p-2 rounded text-warning">
            <div class="font-semibold">
              {gettext("Retry #%{attempt} - Starting with %{backoff_seconds}s backoff",
                attempt: @entry.data.attempt,
                backoff_seconds: @entry.data.backoff_seconds
              )}
            </div>
            <div class="text-xs mt-1">
              Worktree: {Path.basename(@entry.data.worktree)}
            </div>
          </div>
        <% end %>
      <% "QUEUED" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm"><%= Render.data(@entry.data) %></pre>
        <% else %>
          <div class="text-sm mt-1 bg-base-content/5 p-2 rounded">
            {@entry.data.message}
          </div>
        <% end %>
      <% "CONTEXT_TREE" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap"><%= safe_text(@entry.data.content) %></pre>
        <% else %>
          <details class="text-xs mt-1">
            <summary class="cursor-pointer text-secondary">
              {gettext("View Context (Turn %{turn})", turn: @entry.data.turn)}
            </summary>
            <pre class="mt-2 bg-secondary/10 p-2 rounded overflow-x-auto text-secondary"><%= @entry.data.content %></pre>
          </details>
        <% end %>
      <% "system" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap text-accent"><%= safe_text(@entry.data.content) %></pre>
        <% else %>
          <div class="mt-1 space-y-2">
            <%= if @entry.data.content && String.trim(@entry.data.content) != "" do %>
              <div class="text-sm bg-accent/10 p-2 rounded text-accent">
                {truncate_text(@entry.data.content, text_limit())}
              </div>
            <% end %>
          </div>
        <% end %>
      <% "user" -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm whitespace-pre-wrap text-info"><%= safe_text(@entry.data.content) %></pre>
        <% else %>
          <div class="mt-1">
            <%= if @entry.data.content && String.trim(@entry.data.content) != "" do %>
              <div class="text-sm bg-info/10 p-2 rounded text-info">
                {truncate_text(@entry.data.content, text_limit())}
              </div>
            <% else %>
              <div class="text-sm text-base-content/70 italic">
                {gettext("<empty message>")}
              </div>
            <% end %>
            <%= if Map.get(@entry, :optimistic, false) do %>
              <div class="text-xs text-base-content/70 italic mt-1 flex items-center gap-1">
                <.icon name="hero-clock" class="size-3" />
                {gettext("Pending — will be added on the agent's next turn")}
              </div>
            <% end %>
          </div>
        <% end %>
      <% "assistant" -> %>
        <%= if @surface == :modal do %>
          <div class="space-y-4">
            <% reasoning_details = Map.get(@entry.data, :reasoning_details) %>
            <%= if reasoning_details do %>
              <div>
                <h4 class="font-semibold text-warning mb-2">{gettext("Thinking")}</h4>
                <pre class="text-sm whitespace-pre-wrap break-words bg-warning/10 p-3 rounded"><%= format_reasoning_details(reasoning_details) %></pre>
              </div>
            <% end %>
            <%= if @entry.data.content && (not is_binary(@entry.data.content) || String.trim(@entry.data.content) != "") do %>
              <div>
                <h4 class="font-semibold text-warning mb-2">{gettext("Response")}</h4>
                <pre class="text-sm whitespace-pre-wrap bg-warning/10 p-3 rounded"><%= safe_text(@entry.data.content) %></pre>
              </div>
            <% end %>
            <%= if @entry.data.tool_calls && @entry.data.tool_calls != [] do %>
              <div>
                <h4 class="font-semibold text-secondary mb-2">{gettext("Tool Calls")}</h4>
                <div class="space-y-2">
                  <%= for call <- @entry.data.tool_calls do %>
                    <% display = ToolCallDisplay.display(call, mode: :full) %>
                    <% background? = Map.get(display, :variant) == :background_shell %>
                    <div class={[
                      "p-3 rounded",
                      if(background?,
                        do: "bg-info/10 border-l-2 border-info/40",
                        else: "bg-secondary/10"
                      )
                    ]}>
                      <div class="flex items-start gap-2">
                        <span class={[
                          "font-mono font-semibold shrink-0 inline-flex items-center gap-1",
                          background? && "text-info"
                        ]}>
                          <%= if background? do %>
                            <.icon name="hero-clock" class="size-3" />
                          <% end %>
                          {display.label}
                        </span>
                        <%= if display.kind == :structured do %>
                          <div class="min-w-0 flex-1 max-h-[60vh] overflow-y-auto space-y-1">
                            <%= for {key, value} <- display.rows do %>
                              <div class="flex items-start gap-1.5">
                                <span class="font-mono text-xs uppercase tracking-wide text-base-content/70 shrink-0 w-20">{key}</span>
                                <span class="font-mono text-xs whitespace-pre-wrap break-all min-w-0">{safe_text(
                                  value
                                )}</span>
                              </div>
                            <% end %>
                          </div>
                        <% else %>
                          <div class="min-w-0 flex-1 max-h-[60vh] overflow-y-auto">
                            <span class="font-mono text-xs whitespace-pre-wrap break-all">{safe_text(
                              display.summary
                            )}</span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="mt-1 space-y-2">
            <% reasoning_details = Map.get(@entry.data, :reasoning_details) %>
            <%= if reasoning_details do %>
              <div
                data-inspector-reasoning
                class="text-xs bg-base-content/5 p-2 rounded text-base-content/70"
              >
                <div class="font-semibold mb-1">
                  {gettext("Thinking")}
                </div>
                <% thinking = format_reasoning_details(reasoning_details) || "" %>
                <% prev =
                  String.slice(thinking, 0, reasoning_limit()) <>
                    if(String.length(thinking) > reasoning_limit(), do: "...", else: "") %>
                <div class="whitespace-pre-wrap break-words">{prev}</div>
              </div>
            <% end %>
            <%= if @entry.data.content && String.trim(@entry.data.content) != "" do %>
              <div class="text-sm bg-primary/5 border border-primary/15 p-2 rounded text-base-content">
                <div class="text-xs font-medium mb-1 text-primary-standalone">
                  {gettext("Response")}
                </div>
                {truncate_text(@entry.data.content, text_limit())}
              </div>
            <% else %>
              <div class="text-sm text-base-content/70 italic">
                {gettext("<no text content>")}
              </div>
            <% end %>
            <%= if @entry.data.tool_calls && @entry.data.tool_calls != [] do %>
              <div class="text-xs bg-secondary/10 p-2 rounded text-secondary">
                <div class="font-semibold mb-1">
                  {gettext("Tool Calls (%{count})", count: length(@entry.data.tool_calls))}
                </div>
                <div class="space-y-1">
                  <%= for call <- @entry.data.tool_calls do %>
                    <% display = ToolCallDisplay.display(call) %>
                    <% background? = Map.get(display, :variant) == :background_shell %>
                    <div class={[
                      "flex items-start gap-2",
                      background? && "rounded bg-info/10 px-1 py-0.5"
                    ]}>
                      <span class={[
                        "font-mono font-semibold shrink-0 inline-flex items-center gap-1",
                        background? && "text-info"
                      ]}>
                        <%= if background? do %>
                          <.icon name="hero-clock" class="size-3" />
                        <% end %>
                        {display.label}
                      </span>
                      <%= if display.kind == :structured do %>
                        <div class="min-w-0 flex-1 max-h-12 overflow-y-auto space-y-0.5">
                          <%= for {key, value} <- display.rows do %>
                            <div class="flex items-start gap-1.5">
                              <span class="font-mono text-xs uppercase tracking-wide text-base-content/70 shrink-0 w-20">{key}</span>
                              <span class="font-mono text-xs whitespace-pre-wrap break-all min-w-0">{safe_text(
                                value
                              )}</span>
                            </div>
                          <% end %>
                        </div>
                      <% else %>
                        <span class="font-mono text-xs whitespace-nowrap overflow-hidden text-ellipsis min-w-0">{safe_text(
                          display.summary
                        )}</span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      <% "tool" -> %>
        <%= if @surface == :modal do %>
          <div class="space-y-4">
            <% tool_name = Map.get(@entry.data, :tool_name) %>
            <% result = tool_result_presentation(tool_name) %>
            <%= if tool_name do %>
              <h4 class={["font-semibold inline-flex items-center gap-1", result.text_class]}>
                <%= if result.icon do %>
                  <.icon name={result.icon} class="size-4" />
                <% end %>
                {result.label}
              </h4>
            <% end %>
            <pre class={[
              "text-sm whitespace-pre-wrap p-3 rounded max-h-[60vh] overflow-y-auto",
              result.panel_class,
              result.text_class,
              result.border_class
            ]}><%= safe_text(@entry.data.content) %></pre>
          </div>
        <% else %>
          <div class="mt-1 space-y-2">
            <% tool_name = Map.get(@entry.data, :tool_name) %>
            <% result = tool_result_presentation(tool_name) %>
            <%= if tool_name do %>
              <div class={[
                "text-xs px-2 py-1 rounded font-mono inline-flex items-center gap-1",
                result.chip_class,
                result.text_class
              ]}>
                <%= if result.icon do %>
                  <.icon name={result.icon} class="size-3" />
                <% end %>
                {result.label}
              </div>
            <% end %>
            <%= if @entry.data.content && String.trim(@entry.data.content) != "" do %>
              <div class={[
                "text-sm p-2 rounded max-h-48 overflow-y-auto",
                result.panel_class,
                result.text_class,
                result.border_class
              ]}>
                <pre class="text-xs whitespace-pre-wrap">{truncate_text(@entry.data.content, tool_content_limit(), "\n...[truncated]")}</pre>
              </div>
            <% else %>
              <div class="text-sm text-base-content/70 italic">
                {gettext("<empty result>")}
              </div>
            <% end %>
          </div>
        <% end %>
      <% _ -> %>
        <%= if @surface == :modal do %>
          <pre class="text-sm"><%= Render.data(@entry.data) %></pre>
        <% else %>
          <pre class="text-xs mt-1 overflow-x-auto bg-base-content/5 p-2 rounded"><%= Render.data(@entry.data) %></pre>
        <% end %>
    <% end %>
    """
  end

  # The COMPLETE payload is either a `%{result: text}` map or the raw text.
  defp result_text(data) when is_map(data) do
    if is_map(data.result), do: data.result.result, else: data.result
  end

  # Row-surface truncation: the head of the text plus a suffix only when the
  # value actually exceeded the limit (the modal renders everything).
  defp truncate_text(text, limit, suffix \\ "...") do
    String.slice(text, 0, limit) <> if(String.length(text) > limit, do: suffix, else: "")
  end
end
