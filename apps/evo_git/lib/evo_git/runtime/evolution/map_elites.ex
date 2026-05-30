defmodule EvoGit.Runtime.Evolution.MapElites do
  @moduledoc """
  MAP-Elites quality diversity archive — grid of behavior descriptors to elite solutions.

  Maintains a grid where each cell is identified by a behavior descriptor tuple.
  Only the most novel fragment for each cell is retained. This ensures the archive
  preserves diverse approaches as genetic material for future evolution.
  """

  use GenServer

  alias EvoGit.Runtime.Evolution.Fragment

  # Behavior descriptor dimensions:
  #   - complexity (0.0–1.0) → 10 bins (0–9)
  #   - paradigm (atom) → 4 values: functional=0, mixed=1, declarative=2, imperative=3

  @complexity_bins 10
  @paradigm_mapping %{functional: 0, mixed: 1, declarative: 2, imperative: 3}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the MapElites GenServer.

  ## Options

    * `:name` — GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Inserts a fragment into the archive.

  If the fragment's novelty score exceeds the current elite for its behavior
  descriptor cell, the old elite is replaced.

  Returns `:ok` if no prior elite existed, or `{:replaced, old_fragment}` if
  an existing elite was displaced.
  """
  @spec insert(Fragment.t()) :: :ok | {:replaced, Fragment.t()}
  def insert(%Fragment{} = fragment) do
    GenServer.call(via_name(), {:insert, fragment})
  end

  @doc """
  Returns all `{descriptor_tuple, fragment}` pairs in the archive.
  """
  @spec get_elites() :: [{tuple(), Fragment.t()}]
  def get_elites do
    :ets.tab2list(table_name(via_name()))
  end

  @doc """
  Returns the elite fragment for a specific behavior descriptor cell.

  Returns `nil` if no elite exists for that cell.
  """
  @spec get_elite(tuple()) :: Fragment.t() | nil
  def get_elite(descriptor_tuple) when is_tuple(descriptor_tuple) do
    case :ets.lookup(table_name(via_name()), descriptor_tuple) do
      [{^descriptor_tuple, %Fragment{} = fragment}] -> fragment
      _ -> nil
    end
  end

  @doc """
  Returns all elite fragments as a flat list.
  """
  @spec all_fragments() :: [Fragment.t()]
  def all_fragments do
    :ets.tab2list(table_name(via_name()))
    |> Enum.map(fn {_descriptor, fragment} -> fragment end)
  end

  @doc """
  Returns the number of occupied cells in the archive.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(table_name(via_name()), :size)
  end

  @doc """
  Maps a fragment to its grid cell descriptor tuple.

  Uses `fragment.behavioral_profile` to extract:
    - `:complexity` (float 0.0–1.0, binned into 0–9)
    - `:paradigm` (atom, mapped to 0–3)

  Returns a tuple like `{complexity_bin, paradigm_index}`.
  """
  @spec descriptor_for(Fragment.t()) :: tuple()
  def descriptor_for(%Fragment{behavioral_profile: bp}) do
    complexity = Map.get(bp, :complexity, 0.5)
    paradigm = Map.get(bp, :paradigm, :mixed)

    complexity_bin = bin_complexity(complexity)
    paradigm_index = Map.get(@paradigm_mapping, paradigm, 1)

    {complexity_bin, paradigm_index}
  end

  @doc """
  Removes all elites from the archive.
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
  def init(name) do
    table = table_name(name)
    :ets.new(table, [:set, :named_table, :public])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:insert, %Fragment{} = fragment}, _from, %{table: table} = state) do
    descriptor = descriptor_for(fragment)

    result =
      case :ets.lookup(table, descriptor) do
        [{^descriptor, %Fragment{novelty_score: old_score} = old_fragment}]
        when fragment.novelty_score > old_score ->
          :ets.insert(table, {descriptor, fragment})
          {:replaced, old_fragment}

        [{^descriptor, _current}] ->
          :ok

        [] ->
          :ets.insert(table, {descriptor, fragment})
          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:clear, %{table: table} = state) do
    :ets.delete_all_objects(table)
    {:noreply, state}
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

  defp bin_complexity(complexity) when is_number(complexity) do
    clamped = complexity |> max(0.0) |> min(1.0)
    bin = floor(clamped * @complexity_bins) |> trunc()
    # Ensure the top value (1.0) maps to the last bin, not one past it
    min(bin, @complexity_bins - 1)
  end

  defp bin_complexity(_), do: 5
end
