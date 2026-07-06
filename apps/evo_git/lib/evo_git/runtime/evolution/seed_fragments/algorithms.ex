defmodule EvoGit.Runtime.Evolution.SeedFragments.Generators.Algorithms do
  @moduledoc """
  Algorithm-oriented seed fragments: graph algorithms, pattern matching, sorting, and tree traversal.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  def graph_algorithm_fragment do
    Fragment.new(
      ~S"""
      defmodule GraphAlgorithm do
        @moduledoc "BFS/DFS graph traversal with adjacency list."

        defstruct adjacency: %{}, directed: false

        def new(opts \\ []) do
          directed = Keyword.get(opts, :directed, false)
          %__MODULE__{adjacency: %{}, directed: directed}
        end

        def add_edge(%__MODULE__{adjacency: adj, directed: directed} = g, v1, v2, weight \\ 1) do
          adj = if directed do
            add_directed(adj, v1, v2, weight)
          else
            adj |> add_directed(v1, v2, weight) |> add_directed(v2, v1, weight)
          end
          %{g | adjacency: adj}
        end

        def add_directed(adj, v1, v2, weight) do
          Map.update(adj, v1, [{v2, weight}], fn neighbors ->
            if Enum.any?(neighbors, fn {v, _} -> v == v2 end) do
              neighbors
            else
              [{v2, weight} | neighbors]
            end
          end)
        end

        def bfs(%__MODULE__{adjacency: adj}, start) do
          do_bfs(:queue.in(start, :queue.new()), MapSet.new([start]), adj, [])
        end

        def do_bfs(queue, visited, adj, order) do
          case :queue.out(queue) do
            {:empty, _} -> Enum.reverse(order)
            {{:value, node}, rest} ->
              neighbors = neighbors_of(adj, node)
              {queue2, visited2} = enqueue_unvisited(neighbors, rest, visited)
              do_bfs(queue2, visited2, adj, [node | order])
          end
        end

        def dfs(%__MODULE__{adjacency: adj}, start) do
          do_dfs([start], MapSet.new([start]), adj, [])
        end

        def do_dfs([], _visited, _adj, order), do: Enum.reverse(order)
        def do_dfs([node | rest], visited, adj, order) do
          neighbors = neighbors_of(adj, node)
          unvisited = Enum.reject(neighbors, &MapSet.member?(visited, &1))
          new_visited = Enum.reduce(unvisited, visited, &MapSet.put(&2, &1))
          do_dfs(unvisited ++ rest, new_visited, adj, [node | order])
        end

        def shortest_path(%__MODULE__{adjacency: adj}, start, goal) do
          do_shortest_path(:queue.in({start, [start]}, :queue.new()), MapSet.new([start]), adj, goal)
        end

        def do_shortest_path(queue, visited, adj, goal) do
          case :queue.out(queue) do
            {:empty, _} -> nil
            {{:value, {^goal, path}}, _} -> path
            {{:value, {node, path}}, rest} ->
              neighbors = neighbors_of(adj, node)
              {q2, v2} = Enum.reduce(neighbors, {rest, visited}, fn n, {q, v} ->
                if MapSet.member?(v, n) do
                  {q, v}
                else
                  {:queue.in({n, path ++ [n]}, q), MapSet.put(v, n)}
                end
              end)
              do_shortest_path(q2, v2, adj, goal)
          end
        end

        def neighbors_of(adj, node), do: Map.get(adj, node, []) |> Enum.map(&elem(&1, 0))
        def enqueue_unvisited(neighbors, queue, visited) do
          Enum.reduce(neighbors, {queue, visited}, fn n, {q, v} ->
            if MapSet.member?(v, n), do: {q, v}, else: {:queue.in(n, q), MapSet.put(v, n)}
          end)
        end

        def to_dot(%__MODULE__{adjacency: adj}) do
          edges = for {v1, neighbors} <- adj, {v2, _w} <- neighbors, do: "  #{v1} -> #{v2};"
          "digraph G {\\n" <> Enum.join(edges, "\\n") <> "\\n}"
        end
      end
      """,
      language: "elixir",
      domain: "graph_algorithm"
    )
  end

  def pattern_matching_fragment do
    Fragment.new(
      ~S"""
      defmodule PatternMatching do
        @moduledoc "Recursive pattern matching on nested data structures."

        def deep_get(data, []), do: data
        def deep_get(data, [key | rest]) when is_map(data), do: deep_get(Map.get(data, key), rest)
        def deep_get(data, [index | rest]) when is_list(data) and is_integer(index) do
          deep_get(Enum.at(data, index), rest)
        end
        def deep_get(_data, _path), do: nil

        def deep_put(data, [], value), do: value
        def deep_put(data, [key | rest], value) when is_map(data) do
          existing = Map.get(data, key, %{})
          Map.put(data, key, deep_put(existing, rest, value))
        end
        def deep_put(data, [index | rest], value) when is_list(data) and is_integer(index) do
          List.replace_at(data, index, deep_put(Enum.at(data, index, %{}), rest, value))
        end
        def deep_put(_data, [key | rest], value) when is_binary(key) do
          deep_put(%{}, [key | rest], value)
        end

        def deep_match?(pattern, data) when is_map(pattern) and is_map(data) do
          Enum.all?(pattern, fn {k, v} ->
            case Map.get(data, k) do
              nil -> false
              dv -> deep_match?(v, dv)
            end
          end)
        end
        def deep_match?(pattern, data) when is_list(pattern) and is_list(data) do
          length(pattern) == length(data) and
            Enum.zip(pattern, data) |> Enum.all?(fn {p, d} -> deep_match?(p, d) end)
        end
        def deep_match?(%Regex{} = pattern, data) when is_binary(data), do: Regex.match?(pattern, data)
        def deep_match?({:any_of, options}, data), do: Enum.any?(options, &deep_match?(&1, data))
        def deep_match?(:_, _data), do: true
        def deep_match?(pattern, data), do: pattern == data

        def flatten_keys(data, prefix \\ []) when is_map(data) do
          data
          |> Enum.flat_map(fn {k, v} ->
            path = prefix ++ [k]
            case v do
              nested when is_map(nested) -> flatten_keys(nested, path)
              _ -> [{path, v}]
            end
          end)
          |> Map.new()
        end

        def transform(data, fun) when is_map(data) do
          Map.new(data, fn {k, v} -> {k, transform(v, fun)} end)
        end
        def transform(data, fun) when is_list(data), do: Enum.map(data, &transform(&1, fun))
        def transform(data, fun) when is_binary(data), do: fun.(data)
        def transform(data, _fun), do: data
      end
      """,
      language: "elixir",
      domain: "pattern_matching"
    )
  end

  def sorting_fragment do
    Fragment.new(
      ~S"""
      defmodule Sorting.MergeSort do
        @moduledoc "Merge sort implementation with configurable comparator."

        def sort(list, comparator \\ &<=/2) when is_list(list) do
          case length(list) do
            n when n <= 1 -> list
            _ ->
              {left, right} = split(list)
              merge(sort(left, comparator), sort(right, comparator), comparator)
            end
        end

        def split(list) do
          mid = div(length(list), 2)
          Enum.split(list, mid)
        end

        def merge([], right, _cmp), do: right
        def merge(left, [], _cmp), do: left
        def merge([lh | lt] = left, [rh | rt] = right, cmp) do
          if comparator.(lh, rh) do
            [lh | merge(lt, right, cmp)]
          else
            [rh | merge(left, rt, cmp)]
          end
        end

        def sort_by(list, key_fun) when is_function(key_fun, 1) do
          sort(list, fn a, b -> key_fun.(a) <= key_fun.(b) end)
        end

        def sort_desc(list) do
          sort(list, &>=/2)
        end

        def is_sorted?([], _cmp), do: true
        def is_sorted?([_], _cmp), do: true
        def is_sorted?([a, b | rest], comparator) do
          comparator.(a, b) and is_sorted?([b | rest], comparator)
        end

        def dedup_sorted(list) do
          list
          |> Enum.chunk_while(
            nil,
            fn
              item, nil -> {:cont, [item]}
              item, acc when hd(acc) == item -> {:cont, acc}
              item, acc -> {:cont, acc, [item | acc]}
            end,
            fn acc -> {:cont, acc, acc} end
          )
          |> Enum.reverse()
          |> List.flatten()
        end
      end

      defmodule Sorting.QuickSort do
        @moduledoc "Quicksort with median-of-three pivot selection."

        def sort([]), do: []
        def sort([x]), do: [x]
        def sort([pivot | rest]) do
          {less, greater} = Enum.split_with(rest, &(&1 <= pivot))
          sort(less) ++ [pivot] ++ sort(greater)
        end

        def sort_by([], _fun), do: []
        def sort_by([x], _fun), do: [x]
        def sort_by([pivot | rest], key_fun) do
          pk = key_fun.(pivot)
          {less, greater} = Enum.split_with(rest, fn x -> key_fun.(x) <= pk end)
          sort_by(less, key_fun) ++ [pivot] ++ sort_by(greater, key_fun)
        end
      end
      """,
      language: "elixir",
      domain: "sorting"
    )
  end

  def tree_traversal_fragment do
    Fragment.new(
      ~S"""
      defmodule TreeTraversal do
        @moduledoc "Recursive tree walker with accumulation and multiple strategies."

        defstruct value: nil, children: []

        def new(value, children \\ []) do
          %__MODULE__{value: value, children: children}
        end

        def leaf(value), do: new(value)

        def preorder(%__MODULE__{value: v, children: c} = _tree) do
          [v | Enum.flat_map(c, &preorder/1)]
        end

        def postorder(%__MODULE__{value: v, children: c} = _tree) do
          Enum.flat_map(c, &postorder/1) ++ [v]
        end

        def inorder(%__MODULE__{value: v, children: [left, right]}) do
          inorder(left) ++ [v] ++ inorder(right)
        end
        def inorder(%__MODULE__{value: v, children: []}), do: [v]
        def inorder(%__MODULE__{value: v, children: [left]}) do
          inorder(left) ++ [v]
        end

        def levelorder(tree) do
          do_levelorder(:queue.in(tree, :queue.new()), [])
        end

        def do_levelorder(queue, acc) do
          case :queue.out(queue) do
            {:empty, _} -> acc
            {{:value, nil}, q} -> do_levelorder(q, acc)
            {{:value, %__MODULE__{value: v, children: c}}, q} ->
              new_q = Enum.reduce(c, q, &:queue.in(&1, &2))
              do_levelorder(new_q, acc ++ [v])
          end
        end

        def map(%__MODULE__{value: v, children: c} = _tree, fun) do
          %__MODULE__{value: fun.(v), children: Enum.map(c, &map(&1, fun))}
        end

        def fold(%__MODULE__{value: v, children: c} = _tree, fun, acc) do
          new_acc = fun.(v, acc)
          Enum.reduce(c, new_acc, &fold(&1, fun, &2))
        end

        def depth(%__MODULE__{children: []}), do: 1
        def depth(%__MODULE__{children: c}) do
          1 + (c |> Enum.map(&depth/1) |> Enum.max())
        end

        def size(tree), do: fold(tree, fn _, acc -> acc + 1 end, 0)

        def find(%__MODULE__{value: v, children: c} = _tree, predicate) do
          cond do
            predicate.(v) -> {:ok, v}
            true -> Enum.find_value(c, &find(&1, predicate))
          end
        end

        def prune(%__MODULE__{value: v, children: c} = _tree, predicate) do
          if predicate.(v) do
            nil
          else
            pruned = c |> Enum.map(&prune(&1, predicate)) |> Enum.reject(&is_nil/1)
            %__MODULE__{value: v, children: pruned}
          end
        end

        def paths(tree), do: do_paths(tree, [])

        def do_paths(%__MODULE__{value: v, children: []}, prefix), do: [[v | prefix] |> Enum.reverse()]
        def do_paths(%__MODULE__{value: v, children: c}, prefix) do
          Enum.flat_map(c, &do_paths(&1, [v | prefix]))
        end
      end
      """,
      language: "elixir",
      domain: "tree_traversal"
    )
  end
end
