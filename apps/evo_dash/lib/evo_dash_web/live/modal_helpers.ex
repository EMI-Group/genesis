defmodule EvoDashWeb.ModalHelpers do
  @moduledoc """
  Shared modal event handlers for LiveViews.

  Injects `view_full_result/2`, `close_result_modal/1`,
  `view_full_options/2`, and `close_options_modal/1` directly
  into the host LiveView so they have access to `assign/2` (a
  Phoenix.LiveView macro).

  `view_full_result/2` reads the LAZY per-card detail cache
  (`:task_details`, owned by `EvoDashWeb.TasksLive.TaskDetail`) instead of the
  rendered task list: the list rows are lightweight summary maps that carry no
  `result`, so the full result exists only once that card's detail has been
  fetched. The assign it sets is a modal STATE — `%{state: :loading}`,
  `%{state: :ok, result: result}` or `%{state: :error, error: reason}` — so a
  not-yet-loaded card opens a "not loaded yet" modal instead of crashing.
  `view_full_options/2` keeps reading the summary row's `opts` (always present
  in the summary projection), so it needs no detail fetch.
  """

  defmacro __using__(_opts) do
    quote do
      @doc false
      def view_full_result(socket, task_id) do
        details = Map.get(socket.assigns, :task_details) || %{}

        state =
          case Map.get(details, task_id) do
            %{state: :ok, task: task} when is_map(task) ->
              %{state: :ok, result: Map.get(task, :result)}

            %{state: :error, error: reason} ->
              %{state: :error, error: reason}

            _ ->
              %{state: :loading}
          end

        {:noreply, assign(socket, :selected_result, state)}
      end

      @doc false
      def close_result_modal(socket) do
        {:noreply, assign(socket, :selected_result, nil)}
      end

      @doc false
      def view_full_options(socket, task_id) do
        task = Enum.find(socket.assigns.tasks, &(Map.get(&1, :id) == task_id))
        opts = Map.get(task || %{}, :opts) || []
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
