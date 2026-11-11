defmodule EvoDashWeb.HomeLive.ModelSelection do
  @moduledoc """
  Node-scoped provider/model/reasoning selection state for the Genesis Assistant page.

  Selection is scoped by `{target_id, BEAM node}`, so a pending or remote target never
  borrows the local default or local credentials: a pending target records a load error,
  the local node resolves synchronously, and a connected remote socket loads through a
  supervised `EvoDash.SafeCall` task landing as `{{:model_select_loaded, seq, node}, result}`.

  Every entry point takes the socket and returns it, except `update_model_selection/3`
  which returns the `{:noreply, socket}` tuple so a `handle_event/3` clause can return it
  directly.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  alias EvoDash.SafeCall
  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.HomeLive.ModelSelect
  alias EvoDashWeb.LLMSelection

  def assign_model_select(socket) do
    {_target_id, target_node} = selection_scope(socket)
    seq = socket.assigns.model_select_seq + 1

    socket =
      assign(socket,
        model_select_seq: seq,
        model_snapshot: nil,
        model_selection_bundle: nil,
        provider_profiles: [],
        model_selections: [],
        model_selection_enabled: false,
        model_select_loading: false,
        model_select_load_error: nil
      )

    cond do
      pending_remote?(socket) ->
        assign(socket, model_select_load_error: :remote_not_connected)

      target_node == node() ->
        apply_model_snapshot(socket, ModelSelect.load(target_node))

      connected?(socket) ->
        case SafeCall.start(self(), {:model_select_loaded, seq, target_node}, fn ->
               ModelSelect.load(target_node)
             end) do
          {:ok, _pid} ->
            assign(socket, model_select_loading: true)

          {:error, reason} ->
            apply_model_snapshot(socket, {:error, reason})
        end

      true ->
        socket
    end
  end

  def apply_model_snapshot(socket, {:ok, %{node: target_node} = snapshot}) do
    if target_node == elem(selection_scope(socket), 1) and not pending_remote?(socket) do
      bundle = LLMSelection.from_config(snapshot.config, snapshot.model_selection_enabled)

      socket
      |> assign(
        model_snapshot: snapshot,
        model_selection_bundle: bundle,
        provider_profiles: bundle.provider_profiles,
        model_selections: bundle.model_selections,
        model_selection_enabled: bundle.model_selection_enabled,
        model_select_loading: false,
        model_select_load_error: nil
      )
      |> reconcile_model_selection()
    else
      socket
    end
  end

  def apply_model_snapshot(socket, {:error, reason}) do
    assign(socket, model_select_loading: false, model_select_load_error: reason)
  end

  def reconcile_model_selection(socket) do
    if socket.assigns.model_selection_error do
      socket
    else
      candidate =
        if is_nil(socket.assigns.model_spec),
          do: socket.assigns.selected_model_id,
          else: socket.assigns.model_spec

      spec = LLMSelection.reconcile(socket.assigns.model_selection_bundle, candidate)

      socket
      |> assign(model_spec: spec, selected_model_id: nil)
      |> ChatState.persist()
    end
  end

  def update_model_selection(socket, operation, value) do
    bundle = socket.assigns.model_selection_bundle

    result =
      if is_nil(bundle) or pending_remote?(socket) do
        {:error, :model_selection_not_loaded}
      else
        apply(LLMSelection, operation, [bundle, socket.assigns.model_spec, value])
      end

    case result do
      {:ok, spec} ->
        {:noreply,
         socket
         |> assign(
           model_spec: spec,
           selected_model_id: nil,
           model_selection_error: nil,
           model_selection_scope: selection_scope(socket)
         )
         |> ChatState.persist()}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Choose a valid provider profile, model and reasoning effort.")
         )}
    end
  end

  def selection_scope(socket) do
    {socket.assigns[:current_node_id], socket.assigns[:current_node] || node()}
  end

  def pending_remote?(socket) do
    {target_id, target_node} = selection_scope(socket)
    not is_nil(target_id) and target_node == node()
  end
end
