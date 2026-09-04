defmodule EvoDashWeb.HomeLive.ChatMessages do
  @moduledoc """
  Renders the Home chat page's message surface (`EvoDashWeb.HomeLive`): the
  empty state (brand logo mark, greeting, suggestion chips) and the transcript
  message list (user bubbles via `EvoDashWeb.HomeLive.UserMessage`, assistant
  mini task-cards via `EvoDashWeb.HomeLive.AssistantMessage`, error rows).

  Pure presentation — extracted from `home_live.ex` to keep the LiveView under
  the ~1000-line concern threshold. All interactivity bubbles up to the
  LiveView: the suggestion chips send `phx-click="send_message"` with
  `phx-value-message`; the assistant card's raw toggle and copy button use
  `phx-click="toggle_assistant_raw"` and the global `ClipboardCopy` hook
  (`phx-hook="ClipboardCopy"` + `data-content`, pushing the `"copied"` event).

  Total: every payload access is `Map.get`-guarded; transcript entries arrive
  normalized from `EvoDashWeb.HomeLive.Transcript` (always atom-keyed with
  binary ids/text).
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  import EvoDashWeb.HomeLive.AssistantMessage

  alias EvoDashWeb.HomeLive.UserMessage

  # Renders the empty state (no transcript entries yet): brand logo mark
  # (light/dark variants), kicker + greeting, and the four suggestion chips.
  def empty_state(assigns) do
    ~H"""
    <div class="h-full min-h-0 flex flex-col items-center justify-center gap-3 text-center px-6 pb-10">
      <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
      <img
        src={~p"/images/logo.svg"}
        class="h-14 w-auto dark:hidden"
        alt={gettext("EvoX Genesis")}
      />
      <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
      <img
        src={~p"/images/logo-alt.svg"}
        class="h-14 w-auto hidden dark:block"
        alt={gettext("EvoX Genesis")}
      />
      <p class="text-xs font-semibold uppercase tracking-[0.2em] text-base-content/60">
        <%!-- zh_CN: "开始对话" --%>{gettext("Start a conversation")}
      </p>
      <h2 class="text-2xl sm:text-3xl font-semibold tracking-tight text-base-content">
        <%!-- zh_CN: "今天有什么可以帮你的？" --%>{gettext("How can I help you today?")}
      </h2>
      <p class="max-w-md text-sm text-base-content/80">
        <%!-- zh_CN: "与 Genesis 助手聊天：询问代码库、探索源码、控制任务，或获得仪表盘引导" --%>{gettext(
          "Chat with the Genesis assistant: ask about the codebase, explore the source, control running tasks, or get guided through the dashboard."
        )}
      </p>
      <div class="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-2 w-full max-w-xl">
        <%!-- zh_CN: "解释 Genesis 的架构" --%>
        <.suggestion_chip message={gettext("Explain the Genesis architecture")}>
          <.icon
            name="hero-light-bulb"
            class="size-4 mt-0.5 shrink-0 text-primary/80 group-hover:text-primary"
          />
        </.suggestion_chip>
        <%!-- zh_CN: "任务取消是如何工作的？" --%>
        <.suggestion_chip message={gettext("How does task cancellation work?")}>
          <.icon
            name="hero-magnifying-glass"
            class="size-4 mt-0.5 shrink-0 text-primary/80 group-hover:text-primary"
          />
        </.suggestion_chip>
        <%!-- zh_CN: "你能帮我做什么？" --%>
        <.suggestion_chip message={gettext("What can you help me with?")}>
          <.icon
            name="hero-puzzle-piece"
            class="size-4 mt-0.5 shrink-0 text-primary/80 group-hover:text-primary"
          />
        </.suggestion_chip>
        <%!-- zh_CN: "引导我使用仪表盘" --%>
        <.suggestion_chip message={gettext("Guide me through the dashboard")}>
          <.icon
            name="hero-map"
            class="size-4 mt-0.5 shrink-0 text-primary/80 group-hover:text-primary"
          />
        </.suggestion_chip>
      </div>
    </div>
    """
  end

  attr(:transcript, :list, required: true)
  attr(:chat_task_status, :any, required: true)
  attr(:thought_process, :list, required: true)
  attr(:raw_entry_ids, :any, required: true)

  # The transcript message list, oldest first. User entries are right-aligned
  # content-fit bubbles; assistant entries are the mini task-card; error
  # entries use a soft red tint. Only the LAST assistant entry receives the
  # task badge + thought process.
  def message_list(assigns) do
    ~H"""
    <div class="px-4 py-6 pb-8 space-y-6">
      <%= for {entry, index} <- Enum.with_index(@transcript) do %>
        <div id={"chat-entry-" <> entry_id(entry)} class={bubble_wrapper_class(entry)}>
          <%= case Map.get(entry, :role) do %>
            <% :user -> %>
              <UserMessage.user_message entry={entry} />
            <% :assistant -> %>
              <% is_last = index == last_assistant_index(@transcript) %>
              <.assistant_message
                entry={entry}
                raw={MapSet.member?(@raw_entry_ids, Map.get(entry, :id))}
                task_status={if is_last, do: @chat_task_status, else: nil}
                thought_process={if is_last, do: @thought_process, else: []}
              />
            <% :error -> %>
              <div class="flex items-start gap-2 rounded-xl border border-error/25 bg-error/10 px-3.5 py-2.5 text-sm leading-relaxed text-error whitespace-pre-wrap break-words">
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {Map.get(entry, :text, "")}
              </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Bubble wrapper alignment: user entries right-aligned, assistant/error left.
  defp bubble_wrapper_class(entry) do
    case Map.get(entry, :role) do
      :user -> "flex justify-end"
      _ -> "flex justify-start"
    end
  end

  # Total id accessor (mirrors AssistantMessage.entry_id/1): real entries carry
  # normalized binary ids; malformed ones fall back to "" so the wrapper id
  # interpolation never raises.
  defp entry_id(entry) do
    case Map.get(entry, :id) do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  # Index of the LAST assistant entry in the transcript (the one tied to the
  # current/last chat task — only it gets the task badge + thought process).
  defp last_assistant_index(transcript) do
    transcript
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{role: :assistant}, index}, _acc -> index
      _, acc -> acc
    end)
  end

  attr(:message, :string,
    required: true,
    doc: "Translated suggestion text — used as both the visible label and phx-value-message"
  )

  slot(:inner_block, required: true, doc: "The suggestion chip's icon")

  # Empty-state suggestion chip: a button that sends the message as a chat
  # prompt. The root button keeps the `group` class so the slot icon's
  # `group-hover:` styles keep working.
  defp suggestion_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="send_message"
      phx-value-message={@message}
      class="group flex items-start gap-2.5 rounded-xl border border-base-300 bg-base-100 px-3.5 py-3 text-left text-[13px] leading-snug text-base-content/70 hover:border-primary/40 hover:bg-base-200/70 hover:text-base-content transition-colors"
    >
      {render_slot(@inner_block)}
      {@message}
    </button>
    """
  end
end
