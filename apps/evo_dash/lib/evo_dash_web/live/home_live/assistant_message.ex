defmodule EvoDashWeb.HomeLive.AssistantMessage do
  @moduledoc """
  Assistant chat entry for the Home chat page (`EvoDashWeb.HomeLive`).

  Renders the sparkles avatar plus a "mini task card" frame carrying:

    * the chat task's status badge (reusing
      `EvoDashWeb.Helpers.task_status_badge/1` and the pulsing-dot/spinner
      conventions of `EvoDashWeb.TaskCardComponents`),
    * the streamed/final assistant text — pulsing dots while empty +
      streaming, blinking caret while streaming (raw text), and for the
      FINALIZED (non-streaming) text a **Markdown render** via
      `EvoDash.MarkdownRender.render/1` (the same helper the tasks/review
      pages use; always-safe HTML — MDEx `unsafe_: true` with an
      HTML-escaped fallback), OR the plain raw text when the per-message
      `raw` flag is set,
    * a hover-revealed action group at the card's bottom-right corner
      (finalized entries only): a raw/markdown toggle for THAT message
      (`phx-click="toggle_assistant_raw"` with `phx-value-id`) and a
      copy-whole-text button (global `ClipboardCopy` hook with
      `data-content`, pushing the `"copied"` event),
    * when present, a collapsible zero-JS `<details>` "Thought process"
      section listing the agent's context-history entries (the
      `EvoDashWeb.HomeLive.Messages.to_entries/1` shape; tool calls rendered
      via `EvoDashWeb.AgentsLive.ToolCallDisplay.display/1`).

  `task_status`/`thought_process` are passed only for the transcript's LAST
  assistant entry (the one tied to the current/last chat task); earlier
  assistant entries render the frame without the badge/details.

  Total: every payload access is `Map.get`-guarded — nil/absent keys and
  malformed entries degrade instead of raising.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.AgentsLive.ToolCallDisplay

  attr(:entry, :map, required: true)
  attr(:task_status, :any, default: nil)
  attr(:thought_process, :list, default: [])

  # Per-message raw view flag (ephemeral UI state owned by HomeLive's
  # :raw_entry_ids assign): true → show the plain raw text instead of the
  # markdown render. Streaming entries are always raw and ignore this flag.
  attr(:raw, :boolean, default: false)

  def assistant_message(assigns) do
    ~H"""
    <div class="flex justify-start gap-3 w-full">
      <div class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-base-200 ring-1 ring-base-300/60">
        <.icon name="hero-sparkles" class="size-3.5 text-primary" />
      </div>
      <div class="min-w-0 flex-1 pt-0.5">
        <div class={[
          "relative group/assistant overflow-hidden rounded-lg border bg-base-100 shadow-sm",
          card_border(@task_status)
        ]}>
          <%= if @task_status != nil do %>
            <div class="flex items-center justify-between gap-2 border-b border-base-300 bg-base-200/30 px-3 py-1.5">
              <span class="text-xs font-bold uppercase tracking-widest text-base-content/70">
                <%!-- zh_CN: "任务" --%>{gettext("Task")}
              </span>
              <span class={[
                "badge border-0 font-medium px-2 py-1 text-xs",
                EvoDashWeb.Helpers.task_status_badge(@task_status)
              ]}>
                <%= if @task_status in [:running, :cancelling] do %>
                  <span class="relative flex h-2 w-2 mr-1.5">
                    <span
                      class={[
                        "animate-ping absolute inline-flex h-full w-full rounded-full opacity-75",
                        EvoDashWeb.Helpers.task_status_dot_class(@task_status)
                      ]}
                      style="animation-duration: 2s"
                    ></span>
                    <span class={[
                      "relative inline-flex rounded-full h-2 w-2",
                      EvoDashWeb.Helpers.task_status_dot_class(@task_status)
                    ]}></span>
                  </span>
                <% end %>
                <%= if @task_status == :finalizing do %>
                  <span class="loading loading-spinner loading-xs mr-1.5"></span>
                <% end %>
                {status_label(@task_status)}
              </span>
            </div>
          <% end %>
          <%= if streaming?(@entry) and entry_text(@entry) == "" do %>
            <!-- Empty + streaming: pulsing dots pill (unchanged — never
                 markdown-rendered). -->
            <div class="px-3 py-2.5">
              <span class="inline-flex items-center gap-1 rounded-2xl rounded-bl-md bg-base-200/70 px-3 py-2.5">
                <span
                  class="size-1.5 rounded-full bg-base-content/50 animate-bounce"
                  style="animation-delay:0ms"
                ></span>
                <span
                  class="size-1.5 rounded-full bg-base-content/50 animate-bounce"
                  style="animation-delay:150ms"
                ></span>
                <span
                  class="size-1.5 rounded-full bg-base-content/50 animate-bounce"
                  style="animation-delay:300ms"
                ></span>
              </span>
            </div>
          <% else %>
            <%= if streaming?(@entry) do %>
              <!-- In-progress stream: raw partial text + blinking caret.
                   Streaming text is NEVER markdown-rendered (a half-rendered
                   stream would flicker) — the render switches to markdown only
                   when the entry is finalized (streaming: false). -->
              <div class="px-3 py-2.5 text-[15px] leading-relaxed whitespace-pre-wrap break-words text-base-content">
                {entry_text(@entry)}
                <span class="help-caret ml-0.5 inline-block h-4 w-[3px] rounded-full bg-primary align-[-3px]"></span>
              </div>
            <% else %>
              <%= if @raw do %>
                <!-- Per-message raw view: the plain (HTML-escaped) source text. -->
                <div class="px-3 py-2.5 text-[15px] leading-relaxed whitespace-pre-wrap break-words text-base-content">
                  {entry_text(@entry)}
                </div>
              <% else %>
                <!-- Finalized assistant text renders as Markdown — same helper
                     + call pattern as the tasks/review pages. Always-safe
                     HTML: MDEx render with an HTML-escaped fallback. -->
                <div class="px-3 py-2.5">
                  <div class="md-content text-[15px] leading-relaxed text-base-content">
                    {raw(EvoDash.MarkdownRender.render(entry_text(@entry)))}
                  </div>
                </div>
              <% end %>
            <% end %>
          <% end %>
          <%= if @thought_process != [] do %>
            <details class="group border-t border-base-300">
              <summary class="flex cursor-pointer select-none items-center gap-1.5 px-3 py-2 text-xs font-medium text-base-content/60 transition-colors hover:text-base-content">
                <.icon
                  name="hero-chevron-down"
                  class="size-3.5 transition-transform group-open:rotate-180"
                />
                <%!-- zh_CN: "思考过程" --%>{gettext("Thought process")}
                <span class="font-mono text-xs text-base-content/70">({length(@thought_process)})</span>
              </summary>
              <div class="space-y-1.5 px-3 pb-3">
                <%= for tp_entry <- @thought_process do %>
                  <.thought_entry entry={tp_entry} />
                <% end %>
              </div>
            </details>
          <% end %>
          <%= if not streaming?(@entry) do %>
            <!-- Bottom-right hover-revealed action group (finalized entries
                 only — there is nothing to toggle/copy mid-stream): a
                 per-message raw/markdown toggle + a copy-whole-text button
                 (global ClipboardCopy hook, pushes the "copied" event). -->
            <div class="absolute bottom-1.5 right-1.5 z-10 flex items-center gap-0.5 rounded-md bg-base-100/95 p-0.5 opacity-0 shadow-sm ring-1 ring-base-300 transition-opacity duration-150 group-hover/assistant:opacity-100">
              <%!-- zh_CN: 原始视图：显示本条消息的纯文本（未渲染的 Markdown 源文） --%>
              <button
                type="button"
                phx-click="toggle_assistant_raw"
                phx-value-id={entry_id(@entry)}
                title={if @raw, do: gettext("Show rendered markdown"), else: gettext("Show raw text")}
                aria-label={
                  if @raw, do: gettext("Show rendered markdown"), else: gettext("Show raw text")
                }
                class="flex size-6 items-center justify-center rounded text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
              >
                <.icon
                  name={if @raw, do: "hero-document-text", else: "hero-code-bracket"}
                  class="size-3.5"
                />
              </button>
              <%!-- zh_CN: 复制本条消息的完整文本到剪贴板 --%>
              <button
                type="button"
                id={"assistant-copy-" <> entry_id(@entry)}
                phx-hook="ClipboardCopy"
                data-content={entry_text(@entry)}
                title={gettext("Copy message text")}
                aria-label={gettext("Copy message text")}
                class="flex size-6 items-center justify-center rounded text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-clipboard" class="size-3.5" />
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)

  # One context-history entry inside the "Thought process" section: type/turn
  # header, optional reasoning text, content (or tool result for tool entries),
  # and tool-call rows via the agents-page ToolCallDisplay contract.
  defp thought_entry(assigns) do
    ~H"""
    <% data = if is_map(Map.get(@entry, :data)), do: Map.get(@entry, :data), else: %{} %>
    <% content = Map.get(data, :content) || "" %>
    <% tool_calls = Map.get(data, :tool_calls) || [] %>
    <% reasoning_details = Map.get(data, :reasoning_details) || [] %>
    <% tool_name = Map.get(data, :tool_name) %>
    <div class="rounded-md bg-base-200/50 px-2.5 py-1.5">
      <div class="flex items-center gap-2 text-xs">
        <span class={[
          "font-mono font-semibold uppercase tracking-wide",
          type_color(Map.get(@entry, :type))
        ]}>
          {entry_type(Map.get(@entry, :type))}
        </span>
        <%= if is_integer(Map.get(@entry, :turn)) do %>
          <span class="font-mono text-base-content/60">#{Map.get(@entry, :turn)}</span>
        <% end %>
        <span class="ml-auto font-mono text-base-content/60">{tp_timestamp(
          Map.get(@entry, :timestamp)
        )}</span>
      </div>
      <%= if reasoning_details != [] do %>
        <% reasoning_text = reasoning_text(reasoning_details) %>
        <%= if reasoning_text != "" do %>
          <div class="mt-1 max-h-32 overflow-y-auto whitespace-pre-wrap text-xs italic text-base-content/70">
            {reasoning_text}
          </div>
        <% end %>
      <% end %>
      <%= if Map.get(@entry, :type) == "tool" do %>
        <%= if tool_name do %>
          <div class="mt-1 font-mono text-xs text-success">
            {gettext("Tool Result: %{name}", name: tool_name)}
          </div>
        <% end %>
        <%= if content != "" do %>
          <div class="mt-1 max-h-32 overflow-y-auto whitespace-pre-wrap rounded bg-success/10 px-2 py-1 text-xs text-success">
            {content}
          </div>
        <% end %>
      <% else %>
        <%= if content != "" do %>
          <div class="mt-1 max-h-32 overflow-y-auto whitespace-pre-wrap break-words text-xs text-base-content/80">
            {content}
          </div>
        <% end %>
      <% end %>
      <%= if is_list(tool_calls) and tool_calls != [] do %>
        <div class="mt-1.5 space-y-1">
          <%= for call <- tool_calls do %>
            <% display = ToolCallDisplay.display(call) %>
            <div class="flex items-start gap-2">
              <span class="shrink-0 font-mono text-xs font-semibold text-secondary">{display.label}</span>
              <%= if display.kind == :structured do %>
                <div class="min-w-0 flex-1 space-y-0.5">
                  <%= for {key, value} <- display.rows do %>
                    <div class="flex items-start gap-1.5">
                      <span class="w-16 shrink-0 font-mono text-xs uppercase tracking-wide text-base-content/70">{key}</span>
                      <span class="min-w-0 break-all whitespace-pre-wrap font-mono text-xs">{value}</span>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <span class="min-w-0 truncate font-mono text-xs">{display.summary}</span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp streaming?(entry), do: Map.get(entry, :streaming) == true
  defp entry_text(entry), do: Map.get(entry, :text) || ""

  # Total id accessor: real entries always carry a normalized binary id;
  # malformed entries (direct component tests, stray data) fall back to "" so
  # the id interpolation never raises. In practice entries always pass through
  # `Transcript.normalize/1`, so ids are unique binaries.
  defp entry_id(entry) do
    case Map.get(entry, :id) do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  # Task status labels (the Helpers module owns the badge CLASSES; the label
  # text mirrors `TaskCardComponents`' rendering conventions).
  defp status_label(:running), do: gettext("Running")
  defp status_label(:pending), do: gettext("Pending")
  defp status_label(:finalizing), do: gettext("Finalizing")
  defp status_label(:completed), do: gettext("Completed")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(:cancelled), do: gettext("Cancelled")
  defp status_label(:cancelling), do: gettext("Cancelling…")
  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(_status), do: ""

  # Assistant-card frame border per task status — mirrors the LOCKED semantic
  # mapping (transitional/busy → warning amber, completed → success, failed →
  # error, cancelled/pending/unknown → neutral gray).
  defp card_border(:running), do: "border-warning/25"
  defp card_border(:finalizing), do: "border-warning/25"
  defp card_border(:cancelling), do: "border-warning/25"
  defp card_border(:completed), do: "border-success/25"
  defp card_border(:failed), do: "border-error/25"
  defp card_border(_status), do: "border-base-200/60"

  defp type_color("user"), do: "text-info"
  defp type_color("assistant"), do: "text-primary"
  defp type_color("tool"), do: "text-success"
  defp type_color(_type), do: "text-base-content/60"

  defp entry_type(type) when is_binary(type) and type != "", do: type
  defp entry_type(_type), do: "message"

  # Joins reasoning/thinking texts of a reasoning_details list. Total.
  defp reasoning_text(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      if is_map(entry) do
        case Map.get(entry, :text) || Map.get(entry, :thinking) do
          text when is_binary(text) -> [text]
          _ -> []
        end
      else
        []
      end
    end)
    |> Enum.join("\n")
  end

  defp reasoning_text(_entries), do: ""

  # Wall-clock timestamp: DateTime or Unix-seconds integer (as stamped by the
  # :evo_git runtime); anything else renders nothing. Named `tp_timestamp` to
  # avoid clashing with the imported `EvoDashWeb.Helpers.format_timestamp/1`
  # (millisecond-based, raises on bad input — not total).
  defp tp_timestamp(%DateTime{} = timestamp), do: Calendar.strftime(timestamp, "%H:%M:%S")

  defp tp_timestamp(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> nil
    end
  end

  defp tp_timestamp(_timestamp), do: nil
end
