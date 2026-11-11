defmodule EvoDashWeb.HomeLive.Composer do
  @moduledoc """
  Composer card for the Genesis Assistant interactive-session UX
  (`EvoDashWeb.HomeLive` at `/assistant`): the message textarea, the pending
  attachment chips, the attach affordance (with its manual-path fallback), the
  shared provider/model/reasoning capsule, the Send / Stop / interrupt controls
  and the transient "queued for the next turn boundary" echoes.

  Every component here declares NO attributes and reads its values defensively
  from `assigns` (`assigns[:key]` with a sane default), because the page's
  render fixtures predate the interactive-session assigns and must still
  render.

  ## Enabled / disabled contract

  Two separate predicates keep the draft editable wherever the user could
  legitimately type: `compose_disabled?/1` (no new input at all) and
  `send_blocked?/1` (no usable model, so no send).

    * `compose_disabled?/1` is true only while the chat is `:cancelling` /
      `:ended` or while `EvoDashWeb.HomeLive.SourceGate.blocked?/1` holds.
      It drives the textarea's `disabled` attribute and the attach affordances.
    * the textarea is ENABLED in every other state: `:idle`, `:awaiting_input`,
      `:running` (a send during a run is queued, delivered at the next turn
      boundary), and every model-not-ready state (snapshot still loading,
      snapshot missing, invalid selection, pending/unconnected remote target).
    * `send_blocked?/1` is `compose_disabled?/1` plus a missing model snapshot
      or a model selection/load error. It drives ONLY the actions that need a
      resolved model: the Send button and the interrupt-turn button.
    * Send is available for `:idle` / `:running` and hidden while `:cancelling`
      / `:ended`; Stop is visible for `:running` / `:cancelling` and enabled
      only while `:running`.
    * the model capsule is disabled while the snapshot is still loading or
      absent (it is the control that needs one), independently of the draft.
    * `interrupt_button/1` is visible only while `:running` and delivers the
      draft at the next turn boundary — it never halts a chunk.

  ## Event contract (implemented by the page)

  `send_message` (form submit), `chat_input` (form change), `chat_keydown`,
  `chat_keyup`, `stop`, `interrupt_turn`, `chat_attach` (`phx-value-kind` =
  `"text"` / `"image"` / `"audio"`), `chat_attach_manual` (manual-path form
  submit with `path`) and `chat_attachment_remove` (`phx-value-index`).

  Everything is TOTAL: no dot access on optional maps, no atom conversion from
  untrusted input, no `try/rescue`.
  """

  use EvoDashWeb, :html

  import EvoDashWeb.LLMSelectionComponents, only: [llm_selection: 1]

  alias EvoDashWeb.HomeLive.Attachments
  alias EvoDashWeb.HomeLive.SourceGate

  @chat_statuses [:idle, :running, :cancelling, :awaiting_input, :ended]

  # Echo text cap: these are transient echoes, not the message itself.
  @echo_text_chars 200

  @doc """
  The composer card: textarea, attachment chips, attach affordance, model
  capsule, Send / Stop / interrupt and the keyboard hint.

  Assigns read (all optional): `:chat_draft`, `:chat_status`, `:transcript`,
  `:session_mode`, `:queued_echoes`, `:pending_attachments`,
  `:attach_unavailable`, `:provider_profiles`, `:model_selections`,
  `:model_spec`, `:model_selection_enabled`, `:model_select_loading`,
  `:model_select_load_error`, `:model_selection_error`, `:model_snapshot`,
  `:source_available` and `:current_node` (through `SourceGate.blocked?/1`).
  """
  def composer(assigns) do
    status = chat_status(assigns)
    disabled? = compose_disabled?(assigns)
    model_error? = model_error?(assigns)

    assigns =
      assign(assigns,
        composer_status: status,
        composer_draft: text_value(assigns[:chat_draft]),
        composer_provider_profiles: list_value(assigns[:provider_profiles]),
        composer_model_selections: list_value(assigns[:model_selections]),
        composer_model_spec: map_value(assigns[:model_spec]),
        composer_model_selection_enabled: assigns[:model_selection_enabled] == true,
        composer_picker_disabled?: picker_disabled?(assigns),
        composer_model_error?: model_error?,
        composer_textarea_disabled?: disabled?,
        composer_send_hidden?: status in [:cancelling, :ended],
        composer_send_disabled?: send_blocked?(assigns),
        composer_stop_visible?: status in [:running, :cancelling],
        composer_stop_disabled?: status != :running,
        composer_mistakes_note?: status == :idle and transcript_empty?(assigns[:transcript])
      )

    ~H"""
    <div class="shrink-0 px-3 pt-2 pb-3 sm:px-4 bg-base-100">
      <p
        :if={@composer_model_error?}
        role="alert"
        class="mb-1.5 text-xs text-error"
      >
        {gettext("Model selection is unavailable. Choose a valid model or reconnect to the node.")}
      </p>

      <%!-- The attach affordance sits OUTSIDE `#chat-form`: its manual-path
           fallback is its own small form, and no form may ever be nested inside
           the message form. --%>
      <div class="flex items-center gap-1 px-1 pb-1">
        <.attach_menu {assigns} />
      </div>

      <form
        id="chat-form"
        phx-submit="send_message"
        phx-change="chat_input"
        class="help-composer flex flex-col gap-1 rounded-2xl p-1"
      >
        <.attachment_chips {assigns} />

        <textarea
          name="message"
          value={@composer_draft}
          phx-keydown="chat_keydown"
          phx-keyup="chat_keyup"
          disabled={@composer_textarea_disabled?}
          placeholder={gettext("Message Genesis Assistant…")}
          rows="1"
          aria-label={gettext("Message Genesis Assistant…")}
          class="w-full min-w-0 min-h-[46px] max-h-[min(10rem,25dvh)] resize-y bg-transparent px-4 py-3 text-base leading-relaxed placeholder:text-base-content/50 focus:outline-none disabled:opacity-50"
        ></textarea>

        <%!-- Composer control bar: picker left, controls right. --%>
        <div id="chat-composer-controls" class="help-composer-controls">
          <.llm_selection
            id="chat-llm-selection"
            provider_profiles={@composer_provider_profiles}
            model_selections={@composer_model_selections}
            model_spec={@composer_model_spec}
            show_auto_option={@composer_model_selection_enabled}
            disabled={@composer_picker_disabled?}
            compact
            class="min-w-0"
          />
          <div class="ml-auto flex shrink-0 items-center gap-2">
            <%!-- The interrupt affordance is rendered by the PAGE, directly
                 above this card (exactly one `#chat-interrupt-button`). --%>
            <%!-- Send and Stop coexist while running: a send during a run is
                 QUEUED for the next turn boundary. Send is hidden only once
                 the chat can no longer accept input. --%>
            <button
              type="submit"
              disabled={@composer_send_disabled?}
              class={[
                "help-send-btn flex size-9 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content transition hover:opacity-90 active:scale-95 disabled:opacity-40 disabled:pointer-events-none",
                @composer_send_hidden? && "hidden"
              ]}
            >
              <.icon name="hero-paper-airplane" class="size-4" />
              <span class="sr-only"><%!-- zh_CN: "发送" --%>{gettext("Send")}</span>
            </button>
            <button
              type="button"
              phx-click="stop"
              disabled={@composer_stop_disabled?}
              class={[
                "flex size-9 shrink-0 items-center justify-center rounded-full bg-base-content text-base-100 transition hover:opacity-90 active:scale-95 disabled:opacity-40 disabled:pointer-events-none",
                not @composer_stop_visible? && "hidden"
              ]}
            >
              <.icon name="hero-stop" class="size-4" />
              <span class="sr-only"><%!-- zh_CN: "停止" --%>{gettext("Stop")}</span>
            </button>
          </div>
        </div>
      </form>

      <div class="mt-1.5 text-center text-xs text-base-content/60">
        <%!-- zh_CN: "回车发送 · Shift+回车换行" --%>{gettext(
          "Enter to send · Shift+Enter for a new line"
        )}
        <%= if @composer_mistakes_note? do %>
          <br />
          <%!-- zh_CN: Genesis Assistant 可能会出错，请核实重要信息。 --%>{gettext(
            "Genesis Assistant can make mistakes. Verify important information."
          )}
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The interrupt-turn button — visible ONLY while the chat is `:running`.

  It is a `type="button"` (never a submit) so it can live inside `#chat-form`
  without submitting it. It does NOT halt the running turn: the draft is
  delivered at the next turn boundary, exactly like a queued send.
  """
  def interrupt_button(assigns) do
    assigns =
      assign(assigns,
        interrupt_visible?: chat_status(assigns) == :running,
        interrupt_disabled?: send_blocked?(assigns)
      )

    ~H"""
    <button
      :if={@interrupt_visible?}
      id="chat-interrupt-button"
      type="button"
      phx-click="interrupt_turn"
      disabled={@interrupt_disabled?}
      title={gettext("Send now (interrupt turn)")}
      class="btn btn-ghost btn-xs shrink-0 gap-1 rounded-full text-base-content/80"
    >
      <.icon name="hero-bolt" class="size-3.5" />
      <%!-- zh_CN: 立即发送：把草稿插到下一条消息，当前回合跑完才生效，不会中途打断 --%>
      <span class="text-[11px]">{gettext("Send now (interrupt turn)")}</span>
    </button>
    """
  end

  @doc """
  One chip per staged attachment, each with a remove button
  (`chat_attachment_remove`, `phx-value-index` = 0-based index into the
  staging list), plus a `count / max` indicator.

  Reads `:pending_attachments` (an `EvoDashWeb.HomeLive.Attachments` pending
  map) — `nil`/garbage renders nothing.
  """
  def attachment_chips(assigns) do
    pending = assigns[:pending_attachments]

    assigns =
      assign(assigns,
        chip_entries: attachment_entries(pending),
        chip_count: Attachments.count(pending),
        chip_max: Attachments.max_attachments()
      )

    ~H"""
    <div
      :if={@chip_entries != []}
      id="chat-attachment-chips"
      class="flex flex-wrap items-center gap-1 px-2 pt-1"
    >
      <span
        :for={{name, index} <- @chip_entries}
        id={"chat-attachment-#{index}"}
        class="inline-flex max-w-[14rem] items-center gap-1 rounded-full border border-base-300 bg-base-200/60 px-2 py-0.5 text-[11px] text-base-content/80"
      >
        <span class="min-w-0 truncate">{name}</span>
        <button
          type="button"
          phx-click="chat_attachment_remove"
          phx-value-index={index}
          title={gettext("Remove attachment")}
          aria-label={gettext("Remove attachment")}
          class="shrink-0 text-base-content/50 transition hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </span>
      <span class="text-[11px] text-base-content/50">
        <%!-- zh_CN: 附件数量 / 上限 --%>{gettext("%{count}/%{max} attachments",
          count: @chip_count,
          max: @chip_max
        )}
      </span>
    </div>
    """
  end

  @doc """
  The attach affordance: a `chat-attach-button` icon button plus one
  `chat_attach` item per kind (`text` / `image` / `audio`), disabled when the
  compose surface is disabled or the pending set is at the cap.

  When `:attach_unavailable` is truthy a manual-path fallback form is rendered
  (`chat-attach-manual` input named `path`, `phx-submit="chat_attach_manual"`).
  """
  def attach_menu(assigns) do
    disabled? = compose_disabled?(assigns) or at_capacity?(assigns)

    assigns =
      assign(assigns,
        attach_disabled?: disabled?,
        attach_manual?: assigns[:attach_unavailable] == true
      )

    ~H"""
    <div id="chat-attach-menu" class="relative flex items-center gap-1">
      <button
        id="chat-attach-button"
        type="button"
        disabled={@attach_disabled?}
        title={gettext("Attach a file")}
        aria-label={gettext("Attach a file")}
        class="btn btn-ghost btn-sm btn-circle shrink-0 rounded-md text-base-content/70"
      >
        <.icon name="hero-paper-clip" class="size-4" />
      </button>
      <button
        type="button"
        phx-click="chat_attach"
        phx-value-kind="text"
        disabled={@attach_disabled?}
        class="btn btn-ghost btn-xs rounded-md text-base-content/70"
      >
        <%!-- zh_CN: 文本文件 --%>{gettext("File")}
      </button>
      <button
        type="button"
        phx-click="chat_attach"
        phx-value-kind="image"
        disabled={@attach_disabled?}
        class="btn btn-ghost btn-xs rounded-md text-base-content/70"
      >
        <%!-- zh_CN: 图片 --%>{gettext("Image")}
      </button>
      <button
        type="button"
        phx-click="chat_attach"
        phx-value-kind="audio"
        disabled={@attach_disabled?}
        class="btn btn-ghost btn-xs rounded-md text-base-content/70"
      >
        <%!-- zh_CN: 音频 --%>{gettext("Audio")}
      </button>

      <form
        :if={@attach_manual?}
        id="chat-attach-manual-form"
        phx-submit="chat_attach_manual"
        class="absolute bottom-full left-0 z-20 mb-1 flex items-center gap-1 rounded-md border border-base-300 bg-base-100 p-1 shadow-md"
      >
        <input
          id="chat-attach-manual"
          type="text"
          name="path"
          autocomplete="off"
          placeholder={gettext("Path to a file on this machine")}
          class="input input-xs w-56 rounded-md border border-base-300 bg-base-100 px-2 py-1 text-xs"
        />
        <button type="submit" class="btn btn-xs rounded-md">{gettext("Attach")}</button>
      </form>
    </div>
    """
  end

  @doc """
  Transient "queued" echoes — rendered AFTER the last transcript entry by the
  page. Each shows the queued text plus
  `gettext("Queued — sent at the next turn boundary")`.

  These are NOT assistant messages: no task badge, no markdown rendering,
  muted styling only. Total — a non-list renders nothing, non-map entries are
  dropped and a non-binary `text` renders as `""` (capped at 200 graphemes).
  """
  def queued_echoes(assigns) do
    assigns = assign(assigns, queued_echo_entries: echo_list(assigns[:queued_echoes]))

    ~H"""
    <div
      :if={@queued_echo_entries != []}
      id="chat-queued-echoes"
      class="flex flex-col gap-1 px-1 pb-1"
    >
      <div
        :for={echo <- @queued_echo_entries}
        id={"chat-queued-echo-#{echo.id}"}
        class="ml-auto max-w-[85%] rounded-lg border border-dashed border-base-300 bg-base-200/40 px-3 py-1.5 text-sm text-base-content/70"
      >
        <p class="whitespace-pre-wrap break-words">{echo.text}</p>
        <p class="mt-0.5 text-[11px] text-base-content/50">
          <%!-- zh_CN: 已排队——会在下一回合开始前发送 --%>{gettext(
            "Queued — sent at the next turn boundary"
          )}
        </p>
      </div>
    </div>
    """
  end

  ## Status & enablement

  defp chat_status(assigns) do
    case assigns[:chat_status] do
      status when status in @chat_statuses -> status
      _status -> :idle
    end
  end

  # "No new input at all" predicate: the chat is winding down (`:cancelling` /
  # `:ended`) or the Genesis source gate blocks the page. It drives the
  # textarea's `disabled` attribute and the attach affordances ONLY — every
  # model-not-ready state (still loading, no snapshot, invalid selection, a
  # pending/unconnected remote target) leaves the draft editable so typing is
  # never lost while the choice is repaired.
  defp compose_disabled?(assigns) do
    chat_status(assigns) in [:cancelling, :ended] or SourceGate.blocked?(assigns)
  end

  # "Sending is blocked" predicate: composing is disabled PLUS the model
  # snapshot/selection is not usable (missing, still loading, invalid, or a
  # pending remote target whose load failed). Drives ONLY actions that need a
  # resolved model — the Send button and the interrupt-turn button — never the
  # textarea.
  defp send_blocked?(assigns) do
    compose_disabled?(assigns) or model_missing?(assigns) or model_error?(assigns)
  end

  defp picker_disabled?(assigns) do
    assigns[:model_select_loading] == true or is_nil(assigns[:model_snapshot])
  end

  defp model_missing?(assigns), do: is_nil(assigns[:model_snapshot])

  defp model_error?(assigns) do
    not is_nil(assigns[:model_selection_error]) or
      not is_nil(assigns[:model_select_load_error])
  end

  defp transcript_empty?(transcript) when is_list(transcript), do: transcript == []
  defp transcript_empty?(_transcript), do: true

  defp at_capacity?(assigns) do
    Attachments.count(assigns[:pending_attachments]) >= Attachments.max_attachments()
  end

  ## Attachment & echo normalization

  defp attachment_entries(%{entries: entries}) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      case entry do
        %{name: name} when is_binary(name) -> [{chip_name(name), index}]
        _entry -> []
      end
    end)
  end

  defp attachment_entries(_pending), do: []

  defp chip_name(name) do
    case Path.basename(name) do
      "" -> "attachment"
      basename -> basename
    end
  end

  defp echo_list(echoes) when is_list(echoes) do
    echoes
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {echo, index} ->
      %{
        id: echo_id(echo, index),
        text: echo_text(echo),
        at: Map.get(echo, :at, Map.get(echo, "at"))
      }
    end)
  end

  defp echo_list(_echoes), do: []

  defp echo_id(echo, index) do
    case Map.get(echo, :id, Map.get(echo, "id")) do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _other -> Integer.to_string(index)
    end
  end

  defp echo_text(echo) do
    case Map.get(echo, :text, Map.get(echo, "text")) do
      text when is_binary(text) -> String.slice(text, 0, @echo_text_chars)
      _other -> ""
    end
  end

  ## Value normalizers

  defp text_value(value) when is_binary(value), do: value
  defp text_value(_value), do: ""

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}
end
