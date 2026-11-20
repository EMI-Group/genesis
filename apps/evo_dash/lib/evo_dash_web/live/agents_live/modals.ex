defmodule EvoDashWeb.AgentsLive.Modals do
  @moduledoc """
  The three Agents page modals, each rendered only while its driving assign is
  set: the FULL MESSAGE modal (`#full-message-modal`, one checkpoint entry
  through the shared `HistoryEntry` body on `surface: :modal`), the FULL
  OBJECTIVE modal (`#full-objective-modal`) and the SEND MESSAGE modal
  (`#send-message-modal` + `#send-message-form-<agent_id>`).

  Pure presentation: every open/close and submit event is routed by
  `EvoDashWeb.AgentsLive.Inspector` (`view_full_message` /
  `close_message_modal` / `view_full_objective` / `close_objective_modal`) and
  `EvoDashWeb.AgentsLive.SendMessage` (`open` / `close` / `validate` / `send`).
  """
  use EvoDashWeb, :html

  attr :selected_history_entry, :any, default: nil
  attr :selected_objective, :any, default: nil
  attr :send_message_agent_id, :any, default: nil
  attr :send_message_text, :string, default: ""
  attr :id_to_display, :map, default: %{}

  def modals(assigns) do
    ~H"""
    <!-- Full Message Modal -->
    <%= if @selected_history_entry do %>
      <div class="modal modal-open bg-black/50" id="full-message-modal">
        <div class="modal-box w-11/12 max-w-5xl">
          <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
            <.icon name={history_entry_icon(@selected_history_entry.type)} class="size-5" />
            {@selected_history_entry.type}
            <span class="text-sm font-normal text-base-content/70 ml-auto">
              {format_turn(@selected_history_entry.turn)}
            </span>
          </h3>

          <div class="bg-base-200/50 border border-base-300 p-4 rounded-lg overflow-x-auto max-h-[70vh] overflow-y-auto">
            <EvoDashWeb.AgentsLive.HistoryEntry.history_entry_body
              entry={@selected_history_entry}
              surface={:modal}
            />
          </div>

          <div class="modal-action">
            <button class="btn" phx-click="close_message_modal">{gettext("Close")}</button>
          </div>
        </div>

        <div class="modal-backdrop" phx-click="close_message_modal">
          <button class="cursor-default">{gettext("close")}</button>
        </div>
      </div>
    <% end %>

    <!-- Full Objective Modal -->
    <%= if @selected_objective do %>
      <div class="modal modal-open bg-black/50" id="full-objective-modal">
        <div class="modal-box w-11/12 max-w-5xl">
          <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
            <.icon name="hero-document-text" class="size-5" />
            {gettext("Full Objective")}
          </h3>

          <div class="bg-base-200/50 border border-base-300 p-4 rounded-lg overflow-x-auto max-h-[70vh] overflow-y-auto">
            <pre class="text-sm whitespace-pre-wrap"><%= @selected_objective %></pre>
          </div>

          <div class="modal-action">
            <button class="btn" phx-click="close_objective_modal">{gettext("Close")}</button>
          </div>
        </div>

        <div class="modal-backdrop" phx-click="close_objective_modal">
          <button class="cursor-default">{gettext("close")}</button>
        </div>
      </div>
    <% end %>

    <!-- Send Message Modal -->
    <%= if @send_message_agent_id do %>
      <div class="modal modal-open bg-black/50" id="send-message-modal">
        <div class="modal-box w-11/12 max-w-2xl">
          <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
            {gettext("Send Message to Agent #%{id}",
              id: @id_to_display[@send_message_agent_id] || @send_message_agent_id
            )}
          </h3>

          <p class="text-sm text-base-content/60 mb-4">
            {gettext("Your message will be added to the agent's context on its next turn.")}
          </p>

          <form
            id={"send-message-form-" <> to_string(@send_message_agent_id)}
            phx-submit="send_agent_message"
            phx-change="validate_send_message"
          >
            <input type="hidden" name="agent_id" value={@send_message_agent_id} />
            <textarea
              class="textarea textarea-bordered w-full min-h-32"
              name="message"
              placeholder={gettext("Type your message here...")}
              autofocus
            ><%= @send_message_text %></textarea>

            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close_send_message">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                <.icon name="hero-paper-airplane" class="size-4" />
                {gettext("Send")}
              </button>
            </div>
          </form>
        </div>

        <div class="modal-backdrop" phx-click="close_send_message">
          <button class="cursor-default">{gettext("close")}</button>
        </div>
      </div>
    <% end %>
    """
  end
end
