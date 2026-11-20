defmodule EvoDash.WorkbenchSidebarCache do
  @moduledoc """
  Last-known sidebar data for a browser's LiveView transport.

  push_navigate replaces the LiveView but reuses its WebSocket transport.
  Seed the destination sidebar from the same transport's data while it
  refreshes from the servers. Entries are discarded when the transport exits.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get(%Phoenix.LiveView.Socket{transport_pid: pid}, key) when is_pid(pid) do
    case :ets.lookup(@table, {pid, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def get(_socket, _key), do: nil

  def put(%Phoenix.LiveView.Socket{transport_pid: pid}, key, value) when is_pid(pid) do
    :ets.insert(@table, {{pid, key}, value})

    if :ets.insert_new(@table, {{pid, :owner}, true}) do
      GenServer.cast(__MODULE__, {:monitor_transport, pid})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_socket, _key, _value), do: :ok

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_cast({:monitor_transport, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _reference, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {{pid, :_}, :_})
    {:noreply, state}
  end
end
