defmodule EvoDashWeb.ModalHelpers do
  @moduledoc """
  Shared modal event handlers for LiveViews.

  Injects `view_full_result/2`, `close_result_modal/1`,
  `view_full_options/2`, and `close_options_modal/1` directly
  into the host LiveView so they have access to `assign/2` (a
  Phoenix.LiveView macro).
  """

  defmacro __using__(_opts) do
    quote do
      @doc false
      def view_full_result(socket, task_id) do
        task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
        result = Map.get(task || %{}, :result)
        {:noreply, assign(socket, :selected_result, result)}
      end

      @doc false
      def close_result_modal(socket) do
        {:noreply, assign(socket, :selected_result, nil)}
      end

      @doc false
      def view_full_options(socket, task_id) do
        task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
        opts = Map.get(task || %{}, :opts, [])
        primary_text = opts[:prompt] || opts[:objective] || ""
        {:noreply, assign(socket, :selected_options, primary_text)}
      end

      @doc false
      def close_options_modal(socket) do
        {:noreply, assign(socket, :selected_options, nil)}
      end
    end
  end
end
