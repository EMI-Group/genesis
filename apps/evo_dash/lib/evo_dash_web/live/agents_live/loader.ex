defmodule EvoDashWeb.AgentsLive.Loader do
  @moduledoc """
  Owns asynchronous agent page loads and their result admission. A focused task
  uses one generation for both initial load and refresh: its row and agent tree
  are applied together, never independently across scopes.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias EvoDash.SafeCall
  alias EvoDashWeb.AgentsLive.{AgentMerge, CommitGraphState, Inspector, LoadData, Scope}

  def start_page_load(socket) do
    if connected?(socket) and Scope.available?(socket.assigns) do
      {_, node, task_id} = scope = Scope.identity(socket.assigns)
      gen = Map.get(socket.assigns, :load_generation, 0) + 1
      cache = socket.assigns.threshold_cache
      tag = {:agents_data_loaded, scope, gen}

      socket = assign(socket, agents_loading: true, load_generation: gen, agents_error: nil)

      socket =
        if task_id && !socket.assigns[:scoped_task],
          do: assign(socket, :scoped_task_state, :loading),
          else: socket

      runner =
        if task_id,
          do: fn -> LoadData.load_scoped(node, task_id, cache) end,
          else: fn -> LoadData.load(node, cache) end

      case SafeCall.start(self(), tag, runner) do
        {:ok, _pid} ->
          if task_id, do: assign(socket, :scoped_page_load, {scope, gen}), else: socket

        {:error, reason} ->
          fail_page(socket, reason)
      end
    else
      socket
    end
  end

  @doc "Whether a started, current scoped load has yet to resolve the task's project metadata."
  def history_scope_pending?(assigns) do
    case assigns[:scoped_page_load] do
      {{_, _, task_id} = scope, gen} when is_binary(task_id) ->
        is_nil(assigns[:scoped_task]) and owns?(assigns, scope, gen, :load_generation)

      _ ->
        false
    end
  end

  def spawn_refresh(socket) do
    cond do
      socket.assigns[:task_scope_id] -> start_page_load(socket)
      connected?(socket) and Scope.available?(socket.assigns) -> spawn_unscoped_refresh(socket)
      true -> socket
    end
  end

  defp spawn_unscoped_refresh(socket) do
    {_, node, nil} = scope = Scope.identity(socket.assigns)
    seq = Map.get(socket.assigns, :refresh_seq, 0) + 1
    cache = socket.assigns.threshold_cache
    tag = {:agents_refresh_result, scope, seq}
    socket = assign(socket, :refresh_seq, seq)

    case SafeCall.start(self(), tag, fn -> LoadData.refresh(node, cache) end) do
      {:ok, _pid} -> socket
      {:error, _reason} -> socket
    end
  end

  def loaded(socket, scope, gen, result) do
    assigns = socket.assigns

    if owns?(assigns, scope, gen, :load_generation) and
         (is_nil(assigns[:task_scope_id]) or assigns[:scoped_page_load] == {scope, gen}) do
      {:noreply, socket |> assign(:scoped_page_load, nil) |> apply_page(result)}
    else
      {:noreply, socket}
    end
  end

  def refreshed(socket, {_, _, nil} = scope, seq, result) do
    if owns?(socket.assigns, scope, seq, :refresh_seq) do
      case result do
        {:ok, {agents, cache}} ->
          {:noreply,
           socket
           |> assign(:threshold_cache, cache)
           |> AgentMerge.apply_result(agents)
           |> CommitGraphState.maybe_load([])}

        _ ->
          # Unscoped refresh keeps the last good tree; later pushes can retry.
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def refreshed(socket, _scope, _seq, _result), do: {:noreply, socket}

  # Legacy unscoped receipts cannot stand in for a scoped production receipt.
  def legacy_loaded(socket, node, gen, result),
    do: loaded(socket, {nil, node, nil}, gen, {:ok, result})

  def legacy_refreshed(socket, node, seq, {:ok, agents, cache}),
    do: refreshed(socket, {nil, node, nil}, seq, {:ok, {agents, cache}})

  def legacy_refreshed(socket, _node, _seq, _result), do: {:noreply, socket}

  @doc "Drains only the current timer's events, deferring scoped pushes during a snapshot read."
  def flush(socket, token) do
    cond do
      not Scope.available?(socket.assigns) ->
        {:noreply, socket}

      not AgentMerge.flush_due?(socket, token) ->
        {:noreply, socket}

      socket.assigns[:task_scope_id] && socket.assigns.agents_loading ->
        {:noreply, AgentMerge.defer_flush(socket)}

      true ->
        {socket, action} = AgentMerge.flush(socket)

        socket =
          case action do
            :refresh -> spawn_refresh(socket)
            :refetch -> Inspector.refetch_selected_history(socket)
            :none -> socket
          end

        {:noreply, CommitGraphState.maybe_load(socket, [])}
    end
  end

  defp owns?(assigns, scope, seq, counter) do
    Scope.available?(assigns) and scope == Scope.identity(assigns) and
      seq == Map.get(assigns, counter)
  end

  defp apply_page(socket, {:ok, {:ok, %{task: nil} = data}}) do
    refresh? = socket.assigns.pending_agents_refresh

    socket =
      socket
      |> assign(config_status: data.config_status, threshold_cache: data.threshold_cache)
      |> Scope.missing_task()

    if refresh?, do: AgentMerge.buffer_refresh(socket), else: socket
  end

  defp apply_page(socket, {:ok, {:ok, %{agents: agents} = data}}) when is_list(agents) do
    socket =
      case Map.fetch(data, :task) do
        {:ok, task} -> assign(socket, scoped_task: task, scoped_task_state: :ready)
        :error -> socket
      end

    socket
    |> assign(
      config_status: data.config_status,
      threshold_cache: data.threshold_cache,
      agents_loading: false,
      agents_error: nil
    )
    |> AgentMerge.apply_result(agents)
    |> Inspector.select_requested()
    |> AgentMerge.resume_flush()
    |> CommitGraphState.maybe_load([])
  end

  defp apply_page(socket, {:ok, {:error, reason}}), do: fail_page(socket, reason)
  defp apply_page(socket, {:error, reason}), do: fail_page(socket, reason)
  defp apply_page(socket, _result), do: fail_page(socket, :invalid_load_result)

  defp fail_page(socket, reason) do
    socket = assign(socket, agents_loading: false, agents_error: reason, scoped_page_load: nil)

    socket =
      if socket.assigns[:task_scope_id] && !socket.assigns[:scoped_task],
        do: assign(socket, :scoped_task_state, :error),
        else: socket

    AgentMerge.resume_flush(socket)
  end
end
