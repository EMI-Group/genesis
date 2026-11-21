defmodule EvoDashWeb.HomeLive.Composer do
  @moduledoc """
  Composer card for the Genesis Assistant interactive-session UX
  (`EvoDashWeb.HomeLive` at `/assistant`): the message textarea, the pending
  attachment chips, browser uploads and a secondary server-path entry, the
  shared provider/model/reasoning capsule, the Send / Stop / interrupt controls
  and the transient "queued for the next turn boundary" echoes.

  Every component here declares NO attributes and reads its values defensively
  from `assigns` (`assigns[:key]` with a sane default), because the page's
  render fixtures predate the interactive-session assigns and must still
  render.

  ## Enabled / disabled contract

  Two separate predicates keep the draft editable wherever the user could
  legitimately type: `compose_disabled?/1` (no new input at all) and
  `send_blocked?/1` (content, upload, project or model is not ready to send).

    * `compose_disabled?/1` is true only while the chat is `:cancelling` /
      `:ended`.
      It drives the textarea's `disabled` attribute and the attach affordances.
    * the textarea is ENABLED in every other state: `:idle`, `:awaiting_input`,
      `:running` (a send during a run is queued, delivered at the next turn
      boundary), and every model-not-ready state (snapshot still loading,
      snapshot missing, invalid selection, pending/unconnected remote target).
    * `send_blocked?/1` is `compose_disabled?/1` plus a missing model snapshot
      or a model selection/load error, empty content, an active upload, a
      pending project selection, or a send already in flight
      (`:send_in_flight`). It drives ONLY the actions that need a
      resolved model: the Send button and the interrupt-turn button.
    * Send is available for `:idle` / `:running` and hidden while `:cancelling`
      / `:ended`; Stop is visible for `:running` / `:cancelling` and enabled
      only while `:running`.
    * the model capsule is disabled while the snapshot is still loading or
      absent (it is the control that needs one), independently of the draft.
    * `interrupt_button/1` is visible only while `:running` and delivers the
      draft at the next turn boundary — it never halts a chunk.

  ## Event contract (implemented by the page)

  `send_message` (form submit from Enter or the Send button), `chat_input` (form change,
  debounced 250 ms so typing does not round-trip a chat-state persist per keystroke),
  `stop`, `interrupt_turn`, `chat_upload_validate`,
  `chat_upload_cancel`, `chat_upload_clear_error`, `chat_attach_manual` (server-path form
  submit with `path`) and `chat_attachment_remove` (`phx-value-index`).

  Everything is TOTAL: no dot access on optional maps, no atom conversion from
  untrusted input, no `try/rescue`.
  """

  use EvoDashWeb, :html

  import EvoDashWeb.LLMSelectionComponents, only: [llm_selection: 1]

  alias EvoDashWeb.HomeLive.Attachments

  alias EvoDashWeb.HomeLive.Workspace

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
  `:send_in_flight`,
  Optional project selection loading only disables sending, preserving the draft.
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
        composer_stop_disabled?: status != :running
      )

    ~H"""
    <div class="assistant-compose">
      <p :if={@composer_model_error?} role="alert" class="assistant-compose-error">
        {gettext("Model selection is unavailable. Choose a valid model or reconnect to the node.")}
      </p>
      <p
        :if={assigns[:workbench_draft] && assigns[:workspace_error]}
        id="assistant-workspace-error"
        role="alert"
        class="assistant-compose-error"
      >
        {assigns[:workspace_error]}
      </p>
      <div class="assistant-input-card">
        <form
          id="chat-form"
          phx-submit="send_message"
          phx-change="chat_input"
          phx-debounce="250"
          class="assistant-message-form"
        >
          <.attachment_chips {assigns} />
          <textarea
            id="chat-message-input"
            name="message"
            phx-hook="AssistantComposer"
            disabled={@composer_textarea_disabled?}
            placeholder={gettext("Message Genesis Assistant…")}
            rows="3"
            aria-label={gettext("Message Genesis Assistant…")}
            aria-describedby="chat-keyboard-hint"
            class="assistant-textarea"
          >{@composer_draft}</textarea>
        </form>
        <div id="chat-composer-controls" class="assistant-context-bar">
          <div class="assistant-context-start">
            <.attach_menu {assigns} />
            <%= if is_nil(assigns[:workbench_draft]) do %>
              {EvoDashWeb.HomeLive.WorkspaceComponent.selector(assigns)}
            <% end %>
            {EvoDashWeb.HomeLive.TaskCard.follow_control(assigns)}
          </div>
          <div class="assistant-context-end">
            <.llm_selection
              id="chat-llm-selection"
              provider_profiles={@composer_provider_profiles}
              model_selections={@composer_model_selections}
              model_spec={@composer_model_spec}
              show_auto_option={@composer_model_selection_enabled}
              disabled={@composer_picker_disabled?}
              compact
              class="assistant-model-control"
            />
            <button
              type="submit"
              form="chat-form"
              disabled={@composer_send_disabled?}
              class={["assistant-send-button", @composer_send_hidden? && "hidden"]}
            >
              <.icon name="hero-arrow-up" class="size-4" />
              <span class="sr-only">{gettext("Send")}</span>
            </button>
            <button
              type="button"
              phx-click="stop"
              disabled={@composer_stop_disabled?}
              class={["assistant-stop-button", not @composer_stop_visible? && "hidden"]}
            >
              <.icon name="hero-stop" class="size-4" />
              <span class="sr-only">{gettext("Stop reply")}</span>
            </button>
          </div>
        </div>
      </div>
      <p id="chat-keyboard-hint" class="sr-only">
        {gettext("Enter to send · Shift+Enter for a new line")}
      </p>
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
      title={gettext("Queue for the next turn")}
      phx-remove={
        JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})
      }
      class="btn btn-ghost btn-xs shrink-0 gap-1 rounded-full text-base-content/80"
    >
      <.icon name="hero-bolt" class="size-3.5" />
      <%!-- zh_CN: 立即发送：把草稿插到下一条消息，当前回合跑完才生效，不会中途打断 --%>
      <span class="text-[11px]">{gettext("Queue for the next turn")}</span>
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
      phx-remove={
        JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})
      }
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

  @doc "Browser-local upload entry point plus a clearly separate server-path option."
  def attach_menu(assigns) do
    disabled? = compose_disabled?(assigns) or at_capacity?(assigns)
    upload = get_in(assigns, [:uploads, :chat_files])

    assigns =
      assign(assigns,
        attach_disabled?: disabled?,
        attach_upload: upload,
        attach_upload_error: assigns[:upload_error],
        attach_upload_entries:
          if(upload, do: Enum.reject(upload.entries, & &1.cancelled?), else: [])
      )

    ~H"""
    <div class="relative min-w-0">
      <%!-- This transient menu is dismissed CLIENT-side by `DisclosureMotion`
           (`data-disclosure-dismiss`), which is what lets the exit animate: it
           writes `data-disclosure-state="closing"` and only then removes `open`,
           whereas a server round-trip would strip `open` first and snap the
           panel shut. `open` therefore stays browser-owned. --%>
      <details
        id="chat-attach-menu"
        class="assistant-attach-menu motion-disclosure"
        phx-hook="DisclosureMotion"
        phx-mounted={JS.ignore_attributes("open")}
        data-disclosure-dismiss="true"
      >
        <summary
          id="chat-attach-button"
          title={gettext("Attach a file")}
          aria-label={gettext("Attach a file")}
          aria-disabled={to_string(@attach_disabled?)}
          class="assistant-icon-button"
        >
          <.icon name="hero-plus" class="size-5" />
        </summary>
        <div class="assistant-menu-panel assistant-attach-panel">
          <form
            :if={@attach_upload}
            id="chat-upload-form"
            phx-change="chat_upload_validate"
            phx-submit="chat_upload_validate"
          >
            <label
              for={@attach_upload.ref}
              class={[
                "assistant-menu-item cursor-pointer",
                @attach_disabled? && "opacity-40 cursor-not-allowed"
              ]}
            >
              <.icon name="hero-arrow-up-tray" class="size-4" />
              <span>{gettext("Upload files from this computer")}</span>
            </label>
            <.live_file_input
              upload={@attach_upload}
              accept={Enum.join(EvoDash.AttachedFile.upload_extensions(), ",")}
              class="sr-only"
              disabled={@attach_disabled?}
              aria-label={gettext("Upload files from this computer")}
            />
          </form>
          <button :if={is_nil(@attach_upload)} type="button" disabled class="assistant-menu-item">
            <.icon name="hero-arrow-up-tray" class="size-4" />
            <span>{gettext("Upload files from this computer")}</span>
          </button>
          <p class="px-3 pb-2 text-[11px] text-base-content/50">
            {gettext("Up to 4 files, 15 MiB each. Text, PDF, Word, images and audio.")}
          </p>
          <details
            id="chat-server-attachment"
            class="border-t border-base-300/60 pt-1 motion-disclosure"
            phx-hook="DisclosureMotion"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="assistant-menu-item cursor-pointer text-xs">
              {gettext("Add from Genesis server path")}
            </summary>
            <.form
              for={to_form(%{}, as: nil)}
              id="chat-attach-manual-form"
              phx-submit="chat_attach_manual"
              class="assistant-attachment-path-form"
            >
              <.input
                id="chat-attach-manual"
                type="text"
                name="path"
                value=""
                autocomplete="off"
                placeholder={gettext("Absolute file path on the selected server")}
                aria-label={gettext("Absolute file path on the selected server")}
                disabled={@attach_disabled?}
                class="assistant-path-input"
              />
              <button type="submit" disabled={@attach_disabled?} class="assistant-menu-submit">{gettext(
                "Attach"
              )}</button>
            </.form>
          </details>
        </div>
      </details>
      <%!-- `:if` sits on each chip wrapper, so the patch removes exactly this
           node and its own `phx-remove` runs: the last upload finishing (or the
           user dismissing the error) fades the overlay instead of popping it. --%>
      <div
        :if={@attach_upload_entries != []}
        id="chat-upload-progress"
        class="absolute bottom-full left-0 z-[70] mb-2 w-64 rounded-xl border border-base-300 bg-base-100 p-2 shadow-lg"
        phx-remove={
          JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})
        }
      >
        <div :for={entry <- @attach_upload_entries} class="flex items-center gap-2 py-1 text-xs">
          <span class="min-w-0 flex-1 truncate" role="status">{gettext(
            "Uploading %{name}: %{progress}%",
            name: entry.client_name,
            progress: entry.progress
          )}</span>
          <button
            type="button"
            phx-click="chat_upload_cancel"
            phx-value-ref={entry.ref}
            aria-label={gettext("Cancel upload")}
            class="shrink-0 text-base-content/60 hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>
      <div
        :if={@attach_upload_error}
        id="chat-upload-error"
        role="alert"
        class="absolute bottom-full left-0 z-[70] mb-2 flex w-72 items-start gap-2 rounded-xl border border-error/30 bg-base-100 p-3 text-xs text-error shadow-lg"
        phx-remove={
          JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})
        }
      >
        <span class="flex-1">{@attach_upload_error}</span>
        <button
          type="button"
          phx-click="chat_upload_clear_error"
          aria-label={gettext("Dismiss upload error")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
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
    <%!-- TWO exits, because two different patches discard nodes here. When the
         queue becomes EMPTY the patch removes this wrapper (the `:if` sits on
         it) and the wrapper's fade carries the rows out — they stay in the DOM
         while the removal is deferred. When ONE echo leaves the queue while
         others remain (it was delivered at the turn boundary) only that ROW is
         discarded, so the row owns its own fade + lift. A descendant's
         `phx-remove` never fires when an ancestor unmounts, which is why the
         wrapper needs its own binding. --%>
    <div
      :if={@queued_echo_entries != []}
      id="chat-queued-echoes"
      class="flex flex-col gap-1 px-1 pb-1"
      phx-remove={
        JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})
      }
    >
      <%!-- The entrance classes use `fill: both`, so their retained animation
           value outranks any exit class; they are removed first. --%>
      <div
        :for={echo <- @queued_echo_entries}
        id={"chat-queued-echo-#{echo.id}"}
        class="motion-panel motion-panel-slide motion-panel-open ml-auto max-w-[85%] rounded-lg border border-dashed border-base-300 bg-base-200/40 px-3 py-1.5 text-sm text-base-content/70"
        phx-remove={
          JS.remove_class("motion-panel-open motion-panel-slide")
          |> JS.hide(transition: {"motion-exit-lift", "motion-exit-visible", "motion-exit-hidden"})
        }
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
  # `:ended`). It drives the
  # textarea's `disabled` attribute and the attach affordances ONLY — every
  # model-not-ready state (still loading, no snapshot, invalid selection, a
  # pending/unconnected remote target) leaves the draft editable so typing is
  # never lost while the choice is repaired.
  defp compose_disabled?(assigns) do
    chat_status(assigns) in [:cancelling, :ended]
  end

  # "Sending is blocked" predicate: composing is disabled PLUS the model
  # snapshot/selection is not usable (missing, still loading, invalid, or a
  # pending remote target whose load failed), PLUS a send is already in flight
  # (`:send_in_flight`, seeded by the page) so a refused or queued send can never
  # be double-submitted. Drives ONLY actions that need a resolved model — the
  # Send button and the interrupt-turn button — never the textarea.
  defp send_blocked?(assigns) do
    compose_disabled?(assigns) or assigns[:send_in_flight] == true or
      assigns[:session_attach_pending?] == true or
      assigns[:workspace_loading] == true or
      Workspace.missing_draft_project?(assigns) or
      assigns[:upload_in_progress] == true or not has_content?(assigns) or
      model_missing?(assigns) or model_error?(assigns)
  end

  defp has_content?(assigns) do
    String.trim(text_value(assigns[:chat_draft])) != "" or
      Attachments.count(assigns[:pending_attachments]) > 0
  end

  defp picker_disabled?(assigns) do
    assigns[:model_select_loading] == true or is_nil(assigns[:model_snapshot])
  end

  defp model_missing?(assigns), do: is_nil(assigns[:model_snapshot])

  defp model_error?(assigns) do
    not is_nil(assigns[:model_selection_error]) or
      not is_nil(assigns[:model_select_load_error])
  end

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
