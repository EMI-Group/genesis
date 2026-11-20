defmodule EvoDashWeb.AgentsLive.SendMessage do
  @moduledoc """
  The Agents page's "Send Message" modal flow: open/close/validate the composer
  and deliver the message through the exit-safe sender.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  alias EvoDash.SafeCall
  alias EvoDashWeb.AgentsLive.OptimisticMessages

  @doc """
  Opens the modal for the agent named by a STRING id.
  """
  def open(socket, id) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, send_message_agent_id: agent_id, send_message_text: "")}
  end

  @doc """
  Closes the modal and clears the composer.
  """
  def close(socket) do
    {:noreply, assign(socket, send_message_agent_id: nil, send_message_text: "")}
  end

  @doc """
  Stores the composer draft.
  """
  def validate(socket, message) do
    {:noreply, assign(socket, :send_message_text, message)}
  end

  @doc """
  Sends the message and keeps the optimistic display in sync — only
  `{:ok, :ok}` is a success.
  """
  def send(socket, id, message) do
    agent_id = String.to_integer(id)
    node = socket.assigns.current_node

    # Return shapes (verified): success = {:ok, :ok} (local and remote); a
    # missing agent surfaces as a NESTED {:ok, {:error, :not_found}} on the
    # local path (RemoteNode wraps the RemoteAPI result in {:ok, _}); erpc
    # failures surface as {:error, reason}. Only {:ok, :ok} is a real success —
    # matching the old {:ok, _} falsely reported success for missing agents.
    # Deliberately synchronous (the user expects immediate feedback —
    # optimistic display — and this call is a cheap local/remote store append),
    # but wrapped in the exit-safe boundary: a GenServer.call timeout / dead
    # scheduler EXITS its caller, which would crash the page instead of
    # flashing an error.
    case send_user_message_safely(node, agent_id, message) do
      {:ok, :ok} ->
        optimistic_messages =
          OptimisticMessages.append(socket.assigns.optimistic_messages, agent_id, message)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Message sent to agent"))
         |> assign(
           send_message_agent_id: nil,
           send_message_text: "",
           optimistic_messages: optimistic_messages
         )}

      {:ok, {:error, reason}} ->
        {:noreply, send_message_error_flash(socket, reason)}

      {:error, reason} ->
        {:noreply, send_message_error_flash(socket, reason)}

      other ->
        {:noreply, send_message_error_flash(socket, other)}
    end
  end

  # Sends a user message through the exit-safe boundary and FLATTENS
  # `EvoDash.SafeCall`'s wrapper, so the result keeps its documented shape:
  # `{:ok, :ok}` (success), `{:ok, {:error, reason}}` (missing agent) or
  # `{:error, reason}` (RPC / exit failure — a `GenServer.call` timeout lands
  # here instead of killing the LiveView).
  # The transport is the call-time seam `:agents_send_message_runner` (the same
  # default-inert shape as `:agents_history_runner` / `:agents_list_runner`):
  # `(node, agent_id, message) -> {:ok, :ok} | {:ok, {:error, reason}} |
  # {:error, reason}`, resolved HERE — at the call site — so a test can drive
  # `send_agent_message` without the shared `EvoGit.AgentScheduler` GenServer
  # call (whose production 5 s budget EXITS on a loaded host). Production
  # behaviour is unchanged: the default is the real node-aware delegate.
  defp send_user_message_safely(node, agent_id, message) do
    runner =
      Application.get_env(
        :evo_dash,
        :agents_send_message_runner,
        &EvoDash.NodeContext.send_user_message/3
      )

    case SafeCall.run(fn -> runner.(node, agent_id, message) end) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  # Shared error flash for failed send attempts (nested {:ok, {:error, _}} on
  # the local path and {:error, _} erpc failures both land here).
  defp send_message_error_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to send message: %{reason}", reason: inspect(reason))
    )
  end
end
