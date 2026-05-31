defmodule EvoGit.Runtime.Evolution.EntropyPool do
  @moduledoc """
  ETS-backed chaotic repository of cross-domain code fragments.

  Stores Fragment structs in an ETS table for fast access. Supports
  novelty-based selection, random sampling, and eviction of redundant
  fragments to maintain a fixed pool size.
  """

  use GenServer

  alias EvoGit.Runtime.Evolution.Fragment

  @default_max_size 50

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the EntropyPool GenServer.

  ## Options

    * `:name` — GenServer name (default: `__MODULE__`)
    * `:max_size` — maximum number of fragments before auto-eviction (default: `#{@default_max_size}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    GenServer.start_link(__MODULE__, {name, max_size}, name: name)
  end

  @doc """
  Inserts a fragment into the pool.

  If the pool exceeds `max_size`, the most redundant fragment (lowest
  `novelty_score`) is automatically evicted.
  """
  @spec insert(Fragment.t()) :: :ok
  def insert(%Fragment{} = fragment) do
    GenServer.cast(via_name(), {:insert, fragment})
  end

  @doc """
  Inserts multiple fragments into the pool.
  """
  @spec insert_all([Fragment.t()]) :: :ok
  def insert_all(fragments) when is_list(fragments) do
    GenServer.cast(via_name(), {:insert_all, fragments})
  end

  @doc """
  Retrieves a fragment by ID. Returns `nil` if not found.
  """
  @spec get(String.t()) :: Fragment.t() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(table_name(via_name()), id) do
      [{^id, %Fragment{} = fragment}] -> fragment
      _ -> nil
    end
  end

  @doc """
  Returns all fragments in the pool.
  """
  @spec all() :: [Fragment.t()]
  def all do
    :ets.tab2list(table_name(via_name()))
    |> Enum.map(fn {_id, fragment} -> fragment end)
  end

  @doc """
  Returns the number of fragments in the pool.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(table_name(via_name()), :size)
  end

  @doc """
  Returns the top `n` fragments ranked by `novelty_score` (highest first).
  """
  @spec select_novel(pos_integer()) :: [Fragment.t()]
  def select_novel(n) when is_integer(n) and n > 0 do
    all()
    |> Enum.sort_by(& &1.novelty_score, :desc)
    |> Enum.take(n)
  end

  @doc """
  Returns `n` random fragments sampled without replacement.
  """
  @spec select_random(pos_integer()) :: [Fragment.t()]
  def select_random(n) when is_integer(n) and n > 0 do
    all()
    |> Enum.shuffle()
    |> Enum.take(n)
  end

  @doc """
  Removes and returns the fragment with the lowest `novelty_score`.

  Returns `nil` if the pool is empty.
  """
  @spec evict_most_redundant() :: Fragment.t() | nil
  def evict_most_redundant do
    GenServer.call(via_name(), :evict_most_redundant)
  end

  @doc """
  Updates an existing fragment (matched by `fragment.id`).
  """
  @spec update_fragment(Fragment.t()) :: :ok
  def update_fragment(%Fragment{} = fragment) do
    GenServer.cast(via_name(), {:update, fragment})
  end

  @doc """
  Removes all fragments from the pool.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(via_name(), :clear)
  end

  @doc """
  Stops the GenServer.
  """
  @spec stop() :: :ok
  def stop do
    GenServer.stop(via_name(), :normal)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({name, max_size}) do
    table = table_name(name)
    :ets.new(table, [:set, :named_table, :public, {:keypos, 1}])
    {:ok, %{table: table, max_size: max_size}}
  end

  @impl true
  def handle_cast({:insert, %Fragment{} = fragment}, %{table: table, max_size: max_size} = state) do
    :ets.insert(table, {fragment.id, fragment})
    maybe_evict(table, max_size)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:insert_all, fragments}, %{table: table, max_size: max_size} = state) do
    Enum.each(fragments, fn %Fragment{id: id} = fragment ->
      :ets.insert(table, {id, fragment})
    end)
    maybe_evict_to_capacity(table, max_size)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update, %Fragment{} = fragment}, %{table: table} = state) do
    :ets.insert(table, {fragment.id, fragment})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, %{table: table} = state) do
    :ets.delete_all_objects(table)
    {:noreply, state}
  end

  @impl true
  def handle_call(:evict_most_redundant, _from, %{table: table} = state) do
    result =
      case find_least_novel(table) do
        nil ->
          nil

        {id, fragment} ->
          :ets.delete(table, id)
          fragment
      end

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp via_name do
    __MODULE__
  end

  defp table_name(name) do
    :"#{name}_table"
  end

  defp maybe_evict(table, max_size) do
    current = :ets.info(table, :size)

    if current > max_size do
      case find_least_novel(table) do
        nil -> :ok
        {id, _fragment} -> :ets.delete(table, id)
      end
    end
  end

  defp maybe_evict_to_capacity(table, max_size) do
    current = :ets.info(table, :size)

    if current > max_size do
      to_remove = current - max_size

      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, %Fragment{novelty_score: score}} -> score end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {id, _fragment} -> :ets.delete(table, id) end)
    end
  end

  defp find_least_novel(table) do
    :ets.tab2list(table)
    |> Enum.min_by(fn {_id, %Fragment{novelty_score: score}} -> score end, fn -> nil end)
  end
end
