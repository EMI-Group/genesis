defmodule EvoDashWeb.HomeLive.TaskPicker do
  @moduledoc "Scoped, searchable task summaries for the assistant's follow menu."
  import Phoenix.Component, only: [assign: 2]
  alias EvoDash.SafeCall
  alias EvoDashWeb.HomeLive.TaskTracking

  @page_size 20

  def new(seq \\ 0) do
    %{seq: seq, scope: nil, query: "", rows: [], next_offset: nil, loading: false, error: nil}
  end

  def view(assigns) do
    state = assigns[:task_picker] || new()
    if state.scope == TaskTracking.scope(assigns), do: state, else: new(state.seq)
  end

  def reset(socket) do
    state = socket.assigns[:task_picker] || new()
    assign(socket, task_picker: new(state.seq + 1))
  end

  def load(socket, query, more? \\ false) do
    state = view(socket.assigns)
    query = String.trim(query || "")
    offset = if more?, do: state.next_offset, else: 0

    if more? and (state.loading or is_nil(offset)) do
      socket
    else
      scope = TaskTracking.scope(socket.assigns)
      seq = state.seq + 1
      rows = if more?, do: state.rows, else: []

      state = %{
        state
        | seq: seq,
          scope: scope,
          query: query,
          rows: rows,
          next_offset: if(more?, do: state.next_offset),
          loading: true,
          error: nil
      }

      case SafeCall.start(self(), {:assistant_task_choices, seq, scope, offset}, fn ->
             fetch(scope, query, offset)
           end) do
        {:ok, _} -> assign(socket, task_picker: state)
        {:error, _} -> assign(socket, task_picker: %{state | loading: false, error: :unavailable})
      end
    end
  end

  def fetch({:unavailable, _}, _, _), do: {:error, :not_connected}

  def fetch({target, _}, query, offset) do
    opts = [limit: @page_size, offset: offset, search: query]

    result =
      if target == node() do
        {:ok, EvoGit.TaskRegistry.list_tasks_page(opts)}
      else
        EvoGit.RemoteNode.call_remote(target, EvoGit.TaskRegistry, :list_tasks_page, [opts])
      end

    with {:ok, %{rows: rows, total: total}} when is_list(rows) and is_integer(total) <- result do
      {:ok,
       %{
         rows: Enum.map(rows, &project/1),
         next_offset: if(offset + length(rows) < total, do: offset + length(rows))
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  def apply_result(socket, seq, scope, offset, result) do
    state = socket.assigns[:task_picker] || new()

    if seq == state.seq and scope == TaskTracking.scope(socket.assigns) and scope == state.scope do
      state =
        case result do
          {:ok, {:ok, %{rows: rows, next_offset: next_offset}}} ->
            rows = if offset == 0, do: rows, else: Enum.uniq_by(state.rows ++ rows, & &1.id)
            %{state | rows: rows, next_offset: next_offset, loading: false, error: nil}

          _ ->
            %{state | loading: false, error: :unavailable}
        end

      assign(socket, task_picker: state)
    else
      socket
    end
  end

  def project(row) do
    opts = Map.new(row[:opts] || [])

    objective =
      opts[:objective] || opts["objective"] || opts[:prompt] || opts["prompt"] || row[:objective]

    path = row[:project_path] || opts[:path] || opts["path"] || ""

    %{
      id: row.id,
      title:
        if(is_binary(objective) and String.trim(objective) != "",
          do: String.slice(objective, 0, 200),
          else: row.id
        ),
      status: row[:status],
      path: path
    }
  end
end
