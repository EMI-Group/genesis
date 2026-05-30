defmodule EvoGit.Runtime.Evolution.SeedFragments do
  @moduledoc """
  Built-in cross-domain code fragments for entropy pool initialization.

  Provides a curated collection of diverse Elixir code fragments spanning
  multiple paradigms and domains. The fragments are intentionally unrelated
  to each other to maximize diversity in the initial gene pool.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  @doc """
  Returns all built-in seed fragments.

  Each fragment is a `Fragment.t` containing 20–60 lines of idiomatic Elixir
  from a distinct domain: physics, game development, data pipelines, HTTP,
  graph algorithms, pattern matching, concurrency, streaming, sorting,
  encoding, middleware, tree traversal, rate limiting, caching, and events.
  """
  @spec all() :: [Fragment.t()]
  def all do
    [
      physics_fragment(),
      game_loop_fragment(),
      data_pipeline_fragment(),
      http_handler_fragment(),
      graph_algorithm_fragment(),
      pattern_matching_fragment(),
      process_pool_fragment(),
      stream_processing_fragment(),
      sorting_fragment(),
      encoding_fragment(),
      middleware_fragment(),
      tree_traversal_fragment(),
      rate_limiter_fragment(),
      cache_ttl_fragment(),
      event_emitter_fragment()
    ]
  end

  @doc """
  Filters built-in fragments by domain category.

  ## Example

      iex> fragments = EvoGit.Runtime.Evolution.SeedFragments.by_category(:physics)
      iex> length(fragments)
      1
  """
  @spec by_category(atom() | String.t()) :: [Fragment.t()]
  def by_category(category) when is_atom(category) or is_binary(category) do
    cat_str = if is_atom(category), do: Atom.to_string(category), else: category
    Enum.filter(all(), &(&1.domain == cat_str))
  end

  @doc """
  Returns `n` random fragments sampled without replacement from the full set.
  """
  @spec random(pos_integer()) :: [Fragment.t()]
  def random(n) when is_integer(n) and n > 0 do
    all()
    |> Enum.shuffle()
    |> Enum.take(n)
  end

  @doc """
  Generates `n` additional diverse fragments using the LLM.

  The LLM is asked to produce Elixir code snippets from domains *unrelated*
  to the given `objective`, maximizing entropy-pool diversity.

  ## Parameters

    * `objective` — the current evolution objective (used to avoid overlap).
    * `n`         — number of fragments to request.
    * `config`    — map with `:model` (LLM model string) and optional `:agent_id`.

  The caller is responsible for slot acquisition; this function does **not**
  call `AgentScheduler.with_llm_slot/2`.

  Returns a list of `Fragment.t` with `source: :generated`, or `[]` on error.
  """
  @spec generate_with_llm(String.t(), pos_integer(), map()) :: [Fragment.t()]
  def generate_with_llm(objective, n, %{model: model} = _config) when is_binary(objective) and is_integer(n) and n > 0 do
    prompt = build_generation_prompt(objective, n)

    try do
      context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

      with {:ok, stream_response} <- ReqLLM.stream_text(model, context),
           {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
           text <- ReqLLM.Response.text(response) do
        parse_code_blocks(text)
      else
        {:error, reason} ->
          require Logger
          Logger.warning("SeedFragments LLM generation failed: #{inspect(reason)}")
          []

        _ ->
          require Logger
          Logger.warning("SeedFragments LLM generation returned unexpected result")
          []
      end
    rescue
      e ->
        require Logger
        Logger.warning("SeedFragments LLM generation raised: #{Exception.message(e)}")
        []
    end
  end

  def generate_with_llm(_objective, _n, _config), do: []

  # ---------------------------------------------------------------------------
  # Prompt construction
  # ---------------------------------------------------------------------------

  defp build_generation_prompt(objective, n) do
    """
    Generate #{n} diverse, working Elixir code snippets. Each snippet should be
    20–60 lines of idiomatic Elixir from a distinct domain. The domains should
    be UNRELATED to the following objective:

    "#{objective}"

    Suggested domains (pick #{n} that differ from the objective):
    cryptography, music theory, compiler design, robotics, bioinformatics,
    financial modeling, image processing, natural language processing,
    distributed systems, math/linear algebra, database query planner,
    scheduling/optimization, parser combinators, statistics, networking.

    For each snippet:
    1. Wrap it in a ```elixir ... ``` code block.
    2. On the line IMMEDIATELY before the code block, write the domain as a
       single word in square brackets, e.g. [cryptography].

    Output ONLY the code blocks with their domain labels — no other text.
    """
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  @doc false
  def parse_code_blocks(text) when is_binary(text) do
    # Match patterns like [domain]\n```elixir\n...code...\n```
    regex = ~r/\[(\w+)\]\s*\n```elixir\s*\n(.*?)```/s

    Regex.scan(regex, text, capture: :all_but_first)
    |> Enum.map(fn [domain_str, code] ->
      Fragment.new(String.trim(code),
        language: "elixir",
        domain: domain_str,
        source: :generated
      )
    end)
  end

  def parse_code_blocks(_), do: []

  # ===========================================================================
  # Fragment definitions — one per domain
  # ===========================================================================

  defp physics_fragment do
    Fragment.new(
      """
      defmodule Physics.Particle do
        @moduledoc "Simple 2D particle simulation with velocity and acceleration."

        defstruct x: 0.0, y: 0.0, vx: 0.0, vy: 0.0, ax: 0.0, ay: 0.0, mass: 1.0

        def new(opts \\ []) do
          struct(__MODULE__, opts)
        end

        def update(%__MODULE__{} = p, dt) when dt > 0 do
          # Verlet-style integration
          vx = p.vx + p.ax * dt
          vy = p.vy + p.ay * dt
          x = p.x + vx * dt
          y = p.y + vy * dt
          %{p | x: x, y: y, vx: vx, vy: vy}
        end

        def apply_force(%__MODULE__{mass: m} = p, fx, fy) do
          %{p | ax: p.ax + fx / m, ay: p.ay + fy / m}
        end

        def kinetic_energy(%__MODULE__{mass: m, vx: vx, vy: vy}) do
          0.5 * m * (vx * vx + vy * vy)
        end

        def distance(p1, p2) do
          dx = p2.x - p1.x
          dy = p2.y - p1.y
          :math.sqrt(dx * dx + dy * dy)
        end

        def gravity_force(p1, p2, g \\ 6.674e-2) do
          r = distance(p1, p2)
          if r < 1.0, do: {0.0, 0.0}, else: (fn ->
            f = g * p1.mass * p2.mass / (r * r)
            dx = p2.x - p1.x
            dy = p2.y - p1.y
            {f * dx / r, f * dy / r}
          end).()
        end

        def simulate(particles, dt, steps) do
          Enum.reduce(1..steps, particles, fn _, acc ->
            step(acc, dt)
          end)
        end

        defp step(particles, dt) do
          Enum.map(particles, fn p ->
            forces = for other <- particles, other != p, reduce: {0.0, 0.0} do
              {fx, fy} ->
                {gx, gy} = gravity_force(p, other)
                {fx + gx, fy + gy}
            end
            p = apply_force(%{p | ax: 0.0, ay: 0.0}, elem(forces, 0), elem(forces, 1))
            update(p, dt)
          end)
        end
      end
      """,
      language: "elixir",
      domain: "physics"
    )
  end

  defp game_loop_fragment do
    Fragment.new(
      """
      defmodule GameLoop.State do
        @moduledoc "2D game state machine with update/render cycle."

        defstruct scene: :menu, entities: [], score: 0, tick: 0, running: true

        def new do
          %__MODULE__{entities: [player(), enemy(1), enemy(2)]}
        end

        defp player, do: %{type: :player, x: 400.0, y: 300.0, hp: 100, speed: 5.0}
        defp enemy(id), do: %{type: :enemy, id: id, x: :rand.uniform(800) * 1.0, y: :rand.uniform(600) * 1.0, hp: 30}

        def update(%__MODULE__{running: false} = state), do: state
        def update(%__MODULE__{tick: tick} = state) do
          state
          |> update_entities()
          |> check_collisions()
          |> handle_scene_transitions()
          |> Map.put(:tick, tick + 1)
        end

        defp update_entities(%{entities: entities} = state) do
          %{state | entities: Enum.map(entities, &update_entity/1)}
        end

        defp update_entity(%{type: :enemy, x: ex, y: ey} = e) do
          dx = :rand.uniform() * 4 - 2
          dy = :rand.uniform() * 4 - 2
          %{e | x: max(0, min(800, ex + dx)), y: max(0, min(600, ey + dy))}
        end
        defp update_entity(entity), do: entity

        defp check_collisions(%{entities: entities} = state) do
          player = Enum.find(entities, &(&1.type == :player))
          enemies = Enum.filter(entities, &(&1.type == :enemy))

          {alive, hits} = Enum.reduce(enemies, {[], 0}, fn e, {acc, h} ->
            if abs(player.x - e.x) < 20 and abs(player.y - e.y) < 20 do
              {acc, h + 1}
            else
              {[e | acc], h}
            end
          end)

          %{state | entities: [player | alive], score: state.score + hits * 10}
        end

        defp handle_scene_transitions(%{entities: entities} = state) do
          player = Enum.find(entities, &(&1.type == :player))
          enemies = Enum.filter(entities, &(&1.type == :enemy))
          cond do
            player.hp <= 0 -> %{state | scene: :game_over, running: false}
            enemies == [] -> %{state | scene: :victory, running: false}
            true -> state
          end
        end

        def render(%__MODULE__{scene: scene, score: score, entities: entities, tick: tick}) do
          frame = for y <- 0..3, reduce: [] do
            rows ->
              row = for x <- 0..3, do: draw_cell(x, y, entities)
              [row | rows]
          end
          %{scene: scene, score: score, frame: frame, tick: tick}
        end

        defp draw_cell(x, y, entities) do
          Enum.find_value(entities, ".", fn e ->
            if div(trunc(e.x), 200) == x and div(trunc(e.y), 150) == y, do: render_char(e.type), else: nil
          end)
        end

        defp render_char(:player), do: "@"
        defp render_char(:enemy), do: "E"
      end
      """,
      language: "elixir",
      domain: "game_loop"
    )
  end

  defp data_pipeline_fragment do
    Fragment.new(
      """
      defmodule DataPipeline do
        @moduledoc "Stream-based data transformation with map/reduce/filter."

        defstruct stages: [], stats: %{processed: 0, filtered: 0, errors: 0}

        def new(opts \\ []) do
          stages = Keyword.get(opts, :stages, [])
          %__MODULE__{stages: stages}
        end

        def add_stage(%__MODULE__{stages: stages} = pipe, stage) do
          %{pipe | stages: stages ++ [stage]}
        end

        def run(%__MODULE__{stages: stages}, data) when is_list(data) do
          data
          |> Stream.map(&validate/1)
          |> Stream.filter(fn {:ok, _} = item -> item; {:error, _} -> false end)
          |> Stream.map(fn {:ok, v} -> v end)
          |> apply_stages(stages)
          |> Enum.to_list()
        end

        def run_stream(%__MODULE__{stages: stages}, data, chunk_size \\ 100) do
          data
          |> Stream.chunk_every(chunk_size)
          |> Stream.map(fn chunk ->
            chunk
            |> Enum.map(&validate/1)
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, v} -> v end)
            |> then(fn valid ->
              Enum.reduce(stages, valid, fn stage, acc -> apply_stage(acc, stage) end)
            end)
          end)
          |> Stream.flat_map(& &1)
        end

        defp apply_stages(stream, stages) do
          Enum.reduce(stages, stream, fn stage, acc ->
            apply_stage_stream(acc, stage)
          end)
        end

        defp apply_stage_stream(stream, {:map, fun}), do: Stream.map(stream, fun)
        defp apply_stage_stream(stream, {:filter, fun}), do: Stream.filter(stream, fun)
        defp apply_stage_stream(stream, {:reduce, acc, fun}) do
          Stream.transform(stream, acc, fn item, a ->
            new_acc = fun.(item, a)
            {[new_acc], new_acc}
          end)
        end
        defp apply_stage_stream(stream, {:flat_map, fun}), do: Stream.flat_map(stream, fun)
        defp apply_stage_stream(stream, {:each, fun}) do
          Stream.each(stream, fun)
        end

        defp apply_stage(data, {:map, fun}), do: Enum.map(data, fun)
        defp apply_stage(data, {:filter, fun}), do: Enum.filter(data, fun)
        defp apply_stage(data, {:reduce, acc, fun}), do: Enum.reduce(data, acc, fun)
        defp apply_stage(data, {:flat_map, fun}), do: Enum.flat_map(data, fun)
        defp apply_stage(data, {:sort_by, fun}), do: Enum.sort_by(data, fun)

        defp validate(item) when is_map(item), do: {:ok, item}
        defp validate(item) when is_list(item), do: {:ok, Map.new(item)}
        defp validate({k, v}) when is_atom(k), do: {:ok, %{k => v}}
        defp validate(_), do: {:error, :invalid_input}

        def summarize(results) do
          %{
            count: length(results),
            keys: results |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort(),
            sample: Enum.take(results, 5)
          }
        end
      end
      """,
      language: "elixir",
      domain: "data_pipeline"
    )
  end

  defp http_handler_fragment do
    Fragment.new(
      """
      defmodule HTTPHandler do
        @moduledoc "HTTP request handler with pattern matching on routes."

        defstruct method: :get, path: "/", headers: %{}, body: "", params: %{}

        def handle(%__MODULE__{method: :get, path: "/api/users"} = req) do
          users = list_users(req.params)
          json_response(200, %{users: users, count: length(users)})
        end

        def handle(%__MODULE__{method: :get, path: "/api/users/" <> id} = _req) do
          case find_user(id) do
            nil -> json_response(404, %{error: "User not found"})
            user -> json_response(200, user)
          end
        end

        def handle(%__MODULE__{method: :post, path: "/api/users", body: body} = _req) do
          with {:ok, params} <- parse_body(body),
               :ok <- validate_user_params(params) do
            user = create_user(params)
            json_response(201, user)
          else
            {:error, :invalid_json} -> json_response(400, %{error: "Invalid JSON"})
            {:error, {:missing_field, f}} -> json_response(422, %{error: "Missing field: #{f}"})
          end
        end

        def handle(%__MODULE__{method: :delete, path: "/api/users/" <> id} = _req) do
          case delete_user(id) do
            :ok -> json_response(200, %{deleted: true})
            {:error, :not_found} -> json_response(404, %{error: "Not found"})
          end
        end

        def handle(%__MODULE__{method: :get, path: "/health"} = _req) do
          json_response(200, %{status: "ok", timestamp: System.system_time(:second)})
        end

        def handle(%__MODULE__{path: path} = _req) do
          json_response(404, %{error: "No route matches #{path}"})
        end

        defp json_response(status, body) do
          %{status: status, headers: %{"content-type" => "application/json"}, body: Jason.encode!(body)}
        end

        defp list_users(%{"role" => role}), do: Enum.filter(mock_users(), &(&1.role == role))
        defp list_users(_params), do: mock_users()

        defp find_user(id), do: Enum.find(mock_users(), &(&1.id == id))
        defp delete_user(id), do: if(find_user(id), do: :ok, else: {:error, :not_found})

        defp create_user(params), do: Map.put(params, "id", generate_id())
        defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

        defp validate_user_params(params) do
          required = ["name", "email"]
          missing = Enum.reject(required, &Map.has_key?(params, &1))
          if missing == [], do: :ok, else: {:error, {:missing_field, hd(missing)}}
        end

        defp parse_body(body) do
          try do
            {:ok, Jason.decode!(body)}
          rescue
            _ -> {:error, :invalid_json}
          end
        end

        defp mock_users do
          [%{id: "a1", name: "Alice", role: "admin"}, %{id: "b2", name: "Bob", role: "user"}]
        end
      end
      """,
      language: "elixir",
      domain: "http_handler"
    )
  end

  defp graph_algorithm_fragment do
    Fragment.new(
      """
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

        defp add_directed(adj, v1, v2, weight) do
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

        defp do_bfs(queue, visited, adj, order) do
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

        defp do_dfs([], _visited, _adj, order), do: Enum.reverse(order)
        defp do_dfs([node | rest], visited, adj, order) do
          neighbors = neighbors_of(adj, node)
          unvisited = Enum.reject(neighbors, &MapSet.member?(visited, &1))
          new_visited = Enum.reduce(unvisited, visited, &MapSet.put(&2, &1))
          do_dfs(unvisited ++ rest, new_visited, adj, [node | order])
        end

        def shortest_path(%__MODULE__{adjacency: adj}, start, goal) do
          do_shortest_path(:queue.in({start, [start]}, :queue.new()), MapSet.new([start]), adj, goal)
        end

        defp do_shortest_path(queue, visited, adj, goal) do
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

        defp neighbors_of(adj, node), do: Map.get(adj, node, []) |> Enum.map(&elem(&1, 0))
        defp enqueue_unvisited(neighbors, queue, visited) do
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

  defp pattern_matching_fragment do
    Fragment.new(
      """
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

  defp process_pool_fragment do
    Fragment.new(
      """
      defmodule ProcessPool do
        @moduledoc "GenServer-based worker pool with task dispatch."

        use GenServer

        defstruct workers: %{}, task_queue: :queue.new(), pending: %{}, next_id: 0

        def start_link(opts \\ []) do
          pool_size = Keyword.get(opts, :pool_size, 4)
          GenServer.start_link(__MODULE__, pool_size, name: __MODULE__)
        end

        def submit(task) do
          GenServer.call(__MODULE__, {:submit, task}, :infinity)
        end

        def status do
          GenServer.call(__MODULE__, :status)
        end

        @impl true
        def init(pool_size) do
          workers = for id <- 1..pool_size, into: %{} do
            pid = spawn_worker(self(), id)
            {id, %{pid: pid, task: nil}}
          end
          {:ok, %__MODULE__{workers: workers}}
        end

        @impl true
        def handle_call({:submit, task}, from, state) do
          task_id = state.next_id
          case find_idle_worker(state.workers) do
            nil ->
              new_queue = :queue.in({task_id, task, from}, state.task_queue)
              {:noreply, %{state | task_queue: new_queue, next_id: task_id + 1}}
            worker_id ->
              dispatch(worker_id, task_id, task, from, state)
          end
        end

        @impl true
        def handle_call(:status, _from, state) do
          busy = Enum.count(state.workers, fn {_, w} -> w.task != nil end)
          queued = :queue.len(state.task_queue)
          {:reply, %{busy: busy, idle: map_size(state.workers) - busy, queued: queued}, state}
        end

        @impl true
        def handle_info({:result, worker_id, task_id, result}, state) do
          case Map.get(state.pending, task_id) do
            nil -> {:noreply, state}
            from ->
              GenServer.reply(from, result)
              workers = put_in(state.workers[worker_id].task, nil)
              pending = Map.delete(state.pending, task_id)
              state = %{state | workers: workers, pending: pending}
              case dequeue_task(state) do
                nil -> {:noreply, state}
                {state2, tid, task, from2} -> {:noreply, dispatch(worker_id, tid, task, from2, state2)}
              end
          end
        end

        defp spawn_worker(pool_pid, id) do
          spawn(fn -> worker_loop(pool_pid, id) end)
        end

        defp worker_loop(pool_pid, id) do
          receive do
            {:run, task_id, fun} ->
              result = try do
                {:ok, fun.()}
              rescue
                e -> {:error, Exception.message(e)}
              end
              send(pool_pid, {:result, id, task_id, result})
              worker_loop(pool_pid, id)
          end
        end

        defp find_idle_worker(workers) do
          Enum.find_value(workers, fn {id, w} -> if w.task == nil, do: id end)
        end

        defp dispatch(worker_id, task_id, task, from, state) do
          send(state.workers[worker_id].pid, {:run, task_id, task})
          workers = put_in(state.workers[worker_id].task, task_id)
          pending = Map.put(state.pending, task_id, from)
          {:noreply, %{state | workers: workers, pending: pending, next_id: state.next_id + 1}}
        end

        defp dequeue_task(%{task_queue: q} = state) do
          case :queue.out(q) do
            {{:value, {tid, task, from}}, q2} ->
              {%{state | task_queue: q2}, tid, task, from}
            {:empty, _} -> nil
          end
        end
      end
      """,
      language: "elixir",
      domain: "process_pool"
    )
  end

  defp stream_processing_fragment do
    Fragment.new(
      """
      defmodule StreamProcessor do
        @moduledoc "Backpressure-aware stream processor with configurable stages."

        defstruct stages: [], buffer_size: 100, backpressure: :drop_oldest

        def new(opts \\ []) do
          %__MODULE__{
            buffer_size: Keyword.get(opts, :buffer_size, 100),
            backpressure: Keyword.get(opts, :backpressure, :drop_oldest),
            stages: Keyword.get(opts, :stages, [])
          }
        end

        def add_stage(%__MODULE__{stages: stages} = sp, name, fun, opts \\ []) do
          concurrency = Keyword.get(opts, :concurrency, 1)
          %{sp | stages: stages ++ [%{name: name, fun: fun, concurrency: concurrency}]}
        end

        def process(%__MODULE__{stages: stages, buffer_size: buf_size}, stream) do
          stages
          |> Enum.reduce(Stream.map(stream, &{:ok, &1}), fn stage, upstream ->
            apply_stage(upstream, stage, buf_size)
          end)
          |> Stream.filter(&match?({:ok, _}, &1))
          |> Stream.map(fn {:ok, v} -> v end)
        end

        defp apply_stage(upstream, %{fun: fun, concurrency: conc}, buffer_size) do
          upstream
          |> Stream.task_async_stream(
            fn {:ok, item} ->
              try do
                {:ok, fun.(item)}
              rescue
                e -> {:error, {:stage_error, Exception.message(e)}}
              end
            end,
            max_concurrency: conc,
            ordered: true,
            timeout: 30_000
          )
          |> Stream.map(fn {:ok, result} -> result; {:exit, reason} -> {:error, reason} end)
          |> apply_backpressure(buffer_size)
        end

        defp apply_backpressure(stream, buffer_size) do
          Stream.transform(stream, {[], 0}, fn item, {buffer, size} ->
            new_buffer = buffer ++ [item]
            new_size = size + 1
            if new_size > buffer_size do
              {tl(new_buffer), {tl(new_buffer), buffer_size}}
            else
              {[], {new_buffer, new_size}}
            end
          end)
          |> Stream.flat_map(fn
            list when is_list(list) -> list
            single -> [single]
          end)
        end

        def run_pipeline(sp, data, opts \\ []) do
          batch_size = Keyword.get(opts, :batch_size, 50)
          data
          |> Stream.chunk_every(batch_size)
          |> process(sp)
          |> Enum.to_list()
        end

        def measure_throughput(sp, data, duration_ms \\ 5000) do
          start = System.monotonic_time(:millisecond)
          stream = Stream.repeatedly(fn -> data end) |> Stream.flat_map(& &1)
          result = stream
          |> Stream.take_every(1)
          |> Stream.transform(0, fn item, count ->
            elapsed = System.monotonic_time(:millisecond) - start
            if elapsed >= duration_ms do
              {:halt, count}
            else
              {[item], count + 1}
            end
          end)
          |> Enum.to_list()
          elapsed = System.monotonic_time(:millisecond) - start
          %{items_processed: length(result), elapsed_ms: elapsed, per_second: div(length(result) * 1000, max(elapsed, 1))}
        end
      end
      """,
      language: "elixir",
      domain: "stream_processing"
    )
  end

  defp sorting_fragment do
    Fragment.new(
      """
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

        defp split(list) do
          mid = div(length(list), 2)
          Enum.split(list, mid)
        end

        defp merge([], right, _cmp), do: right
        defp merge(left, [], _cmp), do: left
        defp merge([lh | lt] = left, [rh | rt] = right, cmp) do
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

  defp encoding_fragment do
    Fragment.new(
      """
      defmodule Encoding.BinaryProtocol do
        @moduledoc "Custom binary serialization and deserialization."

        @type tag :: :uint8 | :uint16 | :uint32 | :string | :bool | :float64 | :list | :map

        def serialize(data) when is_integer(data) and data >= 0 and data <= 255, do: <<1, data::unsigned-8>>
        def serialize(data) when is_integer(data) and data >= 0 and data <= 65535, do: <<2, data::unsigned-big-16>>
        def serialize(data) when is_integer(data) and data >= 0, do: <<3, data::unsigned-big-32>>
        def serialize(data) when is_integer(data), do: <<4, data::signed-big-64>>
        def serialize(data) when is_binary(data) do
          len = byte_size(data)
          <<5, len::unsigned-big-16, data::binary>>
        end
        def serialize(true), do: <<6, 1>>
        def serialize(false), do: <<6, 0>>
        def serialize(data) when is_float(data), do: <<7, data::float-big-64>>
        def serialize(data) when is_atom(data), do: serialize(Atom.to_string(data))
        def serialize(data) when is_list(data) do
          encoded = Enum.map(data, &serialize/1)
          len = length(encoded)
          iolist = [<<8, len::unsigned-big-16>> | encoded]
          IO.iodata_to_binary(iolist)
        end
        def serialize(data) when is_map(data) do
          entries = Enum.map(data, fn {k, v} -> [serialize(k), serialize(v)] end)
          len = map_size(data)
          IO.iodata_to_binary([<<9, len::unsigned-big-16>> | List.flatten(entries)])
        end
        def serialize(nil), do: <<0>>

        def deserialize(<<0, rest::binary>>), do: {:ok, nil, rest}
        def deserialize(<<1, val::unsigned-8, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<2, val::unsigned-big-16, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<3, val::unsigned-big-32, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<4, val::signed-big-64, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<5, len::unsigned-big-16, str::binary-size(len), rest::binary>>) do
          {:ok, str, rest}
        end
        def deserialize(<<6, 1, rest::binary>>), do: {:ok, true, rest}
        def deserialize(<<6, 0, rest::binary>>), do: {:ok, false, rest}
        def deserialize(<<7, val::float-big-64, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<8, count::unsigned-big-16, rest::binary>>) do
          deserialize_list(rest, count, [])
        end
        def deserialize(<<9, count::unsigned-big-16, rest::binary>>) do
          deserialize_map(rest, count, %{})
        end
        def deserialize(_), do: {:error, :invalid_data}

        defp deserialize_list(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
        defp deserialize_list(data, count, acc) do
          with {:ok, val, rest} <- deserialize(data) do
            deserialize_list(rest, count - 1, [val | acc])
          end
        end

        defp deserialize_map(rest, 0, acc), do: {:ok, acc, rest}
        defp deserialize_map(data, count, acc) do
          with {:ok, key, rest1} <- deserialize(data),
               {:ok, val, rest2} <- deserialize(rest1) do
            deserialize_map(rest2, count - 1, Map.put(acc, key, val))
          end
        end

        def encode!(data), do: serialize(data)
        def decode!(binary) do
          case deserialize(binary) do
            {:ok, value, ""} -> value
            {:ok, value, rest} -> {value, rest}
            {:error, reason} -> raise "Decode error: #{inspect(reason)}"
          end
        end

        def roundtrip?(data) do
          encoded = serialize(data)
          {:ok, decoded, ""} = deserialize(encoded)
          decoded == data
        end
      end
      """,
      language: "elixir",
      domain: "encoding"
    )
  end

  defp middleware_fragment do
    Fragment.new(
      """
      defmodule Middleware do
        @moduledoc "Plug-like middleware chain with composition."

        defstruct stack: [], handler: nil

        @type next :: (map() -> map())
        @type middleware :: (map(), next -> map())

        def new(handler \\ &Function.identity/1) do
          %__MODULE__{handler: handler}
        end

        def use(%__MODULE__{stack: stack} = mw, middleware) do
          %{mw | stack: stack ++ [middleware]}
        end

        def call(%__MODULE__{stack: stack, handler: handler}, request) do
          chain = Enum.reverse([handler | stack])
          composed = compose(chain)
          composed.(request)
        end

        defp compose([final]), do: final
        defp compose([mw | rest]) do
          next = compose(rest)
          fn req -> mw.(req, next) end
        end

        # Built-in middlewares

        def logger(request, next) do
          start = System.monotonic_time(:microsecond)
          request = Map.put_new(request, :logs, [])
          response = next.(request)
          elapsed = System.monotonic_time(:microsecond) - start
          log_entry = %{at: elapsed, method: request[:method], path: request[:path]}
          Map.update!(response, :logs, &[log_entry | &1])
        end

        def add_headers(defaults), do: fn request, next ->
          headers = Map.merge(defaults, Map.get(request, :headers, %{}))
          next.(Map.put(request, :headers, headers))
        end

        def require_auth(request, next) do
          case Map.get(request, :auth) do
            nil -> Map.put(request, :status, 401)
            _ -> next.(request)
          end
        end

        def rate_limit(max_rps), do: fn request, next ->
          key = {request[:ip], System.system_time(:second)}
          request = ensure_rate_state(request, key, max_rps)
          state = request[:rate_limit_state]
          if state.count < max_rps do
            response = next.(request)
            Map.put(response, :rate_limit_state, %{state | count: state.count + 1})
          else
            Map.put(request, :status, 429)
          end
        end

        def transform_response(transformer) do
          fn request, next ->
            response = next.(request)
            transformer.(response)
          end
        end

        defp ensure_rate_state(request, key, max_rps) do
          state = Map.get(request, :rate_limit_state, %{key: key, count: 0, max: max_rps})
          if state.key != key, do: Map.put(request, :rate_limit_state, %{key: key, count: 0, max: max_rps}), else: request
        end
      end
      """,
      language: "elixir",
      domain: "middleware"
    )
  end

  defp tree_traversal_fragment do
    Fragment.new(
      """
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

        defp do_levelorder(queue, acc) do
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

        defp do_paths(%__MODULE__{value: v, children: []}, prefix), do: [[v | prefix] |> Enum.reverse()]
        defp do_paths(%__MODULE__{value: v, children: c}, prefix) do
          Enum.flat_map(c, &do_paths(&1, [v | prefix]))
        end
      end
      """,
      language: "elixir",
      domain: "tree_traversal"
    )
  end

  defp rate_limiter_fragment do
    Fragment.new(
      """
      defmodule RateLimiter do
        @moduledoc "Token bucket rate limiter with sliding window."

        defstruct max_tokens: 60, refill_rate: 1, tokens: 60, last_refill: nil, window_ms: 60_000, requests: []

        @type t :: %__MODULE__{
          max_tokens: pos_integer(),
          refill_rate: pos_integer(),
          tokens: non_neg_integer(),
          last_refill: integer() | nil,
          window_ms: pos_integer(),
          requests: [integer()]
        }

        def new(opts \\ []) do
          max = Keyword.get(opts, :max_tokens, 60)
          refill = Keyword.get(opts, :refill_rate, 1)
          window = Keyword.get(opts, :window_ms, 60_000)
          %__MODULE__{
            max_tokens: max,
            refill_rate: refill,
            tokens: max,
            last_refill: System.monotonic_time(:millisecond),
            window_ms: window,
            requests: []
          }
        end

        @spec allow?(t()) :: {:ok, t()} | {:error, :rate_limited, t()}
        def allow?(%__MODULE__{} = limiter) do
          limiter = refill_tokens(limiter)
          limiter = prune_window(limiter)
          if limiter.tokens > 0 do
            now = System.monotonic_time(:millisecond)
            {:ok, %{limiter | tokens: limiter.tokens - 1, requests: [now | limiter.requests]}}
          else
            {:error, :rate_limited, limiter}
          end
        end

        @spec wait_and_proceed(t()) :: t()
        def wait_and_proceed(%__MODULE__{} = limiter) do
          case allow?(limiter) do
            {:ok, new_limiter} -> new_limiter
            {:error, :rate_limited, limiter2} ->
              wait_time = compute_wait(limiter2)
              Process.sleep(wait_time)
              wait_and_proceed(refill_tokens(limiter2))
          end
        end

        defp refill_tokens(%__MODULE__{last_refill: nil} = limiter) do
          %{limiter | last_refill: System.monotonic_time(:millisecond)}
        end
        defp refill_tokens(%__MODULE__{} = limiter) do
          now = System.monotonic_time(:millisecond)
          elapsed = now - limiter.last_refill
          tokens_to_add = div(elapsed * limiter.refill_rate, 1000)
          new_tokens = min(limiter.max_tokens, limiter.tokens + tokens_to_add)
          %{limiter | tokens: new_tokens, last_refill: now}
        end

        defp prune_window(%__MODULE__{} = limiter) do
          cutoff = System.monotonic_time(:millisecond) - limiter.window_ms
          pruned = Enum.filter(limiter.requests, &(&1 > cutoff))
          %{limiter | requests: pruned}
        end

        defp compute_wait(%__MODULE__{requests: []}), do: 100
        defp compute_wait(%__MODULE__{requests: [oldest | _], window_ms: window}) do
          now = System.monotonic_time(:millisecond)
          remaining = oldest + window - now
          max(remaining, 0) + 1
        end

        def remaining(%__MODULE__{} = limiter) do
          limiter = refill_tokens(limiter)
          limiter.tokens
        end

        def reset(%__MODULE__{} = limiter) do
          %{limiter | tokens: limiter.max_tokens, requests: [], last_refill: System.monotonic_time(:millisecond)}
        end
      end
      """,
      language: "elixir",
      domain: "rate_limiter"
    )
  end

  defp cache_ttl_fragment do
    Fragment.new(
      """
      defmodule CacheTTL do
        @moduledoc "TTL-based cache with automatic expiration and lazy cleanup."

        defstruct entries: %{}, default_ttl_ms: 60_000, max_size: 1000, stats: %{hits: 0, misses: 0, evictions: 0}

        @type t :: %__MODULE__{
          entries: %{term() => {term(), integer()}},
          default_ttl_ms: pos_integer(),
          max_size: pos_integer(),
          stats: %{hits: non_neg_integer(), misses: non_neg_integer(), evictions: non_neg_integer()}
        }

        def new(opts \\ []) do
          %__MODULE__{
            default_ttl_ms: Keyword.get(opts, :ttl_ms, 60_000),
            max_size: Keyword.get(opts, :max_size, 1000)
          }
        end

        @spec get(t(), term()) :: {:ok, term(), t()} | {:miss, t()}
        def get(%__MODULE__{} = cache, key) do
          now = System.monotonic_time(:millisecond)
          case Map.get(cache.entries, key) do
            {value, expires_at} when expires_at > now ->
              {:ok, value, update_stats(cache, :hit)}
            _ ->
              {:miss, maybe_evict(cache, key, now)}
          end
        end

        @spec put(t(), term(), term(), keyword()) :: t()
        def put(%__MODULE__{} = cache, key, value, opts \\ []) do
          ttl = Keyword.get(opts, :ttl_ms, cache.default_ttl_ms)
          now = System.monotonic_time(:millisecond)
          expires_at = now + ttl
          cache = maybe_evict_expired(cache, now)
          entries = if map_size(cache.entries) >= cache.max_size do
            {evicted_key, _, rest} = evict_oldest(cache.entries)
            cache = update_stats(cache, :eviction)
            Map.put(rest, key, {value, expires_at})
            |> then(&{&1, cache})
          else
            {Map.put(cache.entries, key, {value, expires_at}), cache}
          end
          case entries do
            {e, c} -> %{c | entries: e}
            _ -> %{cache | entries: entries}
          end
        end

        @spec has_key?(t(), term()) :: boolean()
        def has_key?(%__MODULE__{} = cache, key) do
          now = System.monotonic_time(:millisecond)
          case Map.get(cache.entries, key) do
            {_value, expires_at} when expires_at > now -> true
            _ -> false
          end
        end

        @spec delete(t(), term()) :: t()
        def delete(%__MODULE__{} = cache, key) do
          %{cache | entries: Map.delete(cache.entries, key)}
        end

        @spec clear(t()) :: t()
        def clear(%__MODULE__{} = cache) do
          %{cache | entries: %{}, stats: %{hits: 0, misses: 0, evictions: 0}}
        end

        @spec size(t()) :: non_neg_integer()
        def size(%__MODULE__{} = cache) do
          now = System.monotonic_time(:millisecond)
          Enum.count(cache.entries, fn {_, {_, exp}} -> exp > now end)
        end

        @spec stats(t()) :: map()
        def stats(%__MODULE__{stats: s}) do
          total = s.hits + s.misses
          Map.put(s, :hit_rate, if(total > 0, do: s.hits / total, else: 0.0))
        end

        defp maybe_evict(cache, _key, _now), do: cache
        defp maybe_evict_expired(cache, now) do
          expired = for {k, {_, exp}} <- cache.entries, exp <= now, do: k
          entries = Map.drop(cache.entries, expired)
          %{cache | entries: entries, stats: Map.update!(cache.stats, :evictions, &(&1 + length(expired)))}
        end

        defp evict_oldest(entries) do
          {key, {_val, oldest}} = Enum.min_by(entries, fn {_, {_, exp}} -> exp end)
          {key, oldest, Map.delete(entries, key)}
        end

        defp update_stats(cache, :hit), do: %{cache | stats: Map.update!(cache.stats, :hits, &(&1 + 1))}
        defp update_stats(cache, :eviction), do: %{cache | stats: Map.update!(cache.stats, :evictions, &(&1 + 1))}
      end
      """,
      language: "elixir",
      domain: "cache_ttl"
    )
  end

  defp event_emitter_fragment do
    Fragment.new(
      """
      defmodule EventEmitter do
        @moduledoc "Pub/sub event system with pattern-based subscriptions."

        defstruct subscribers: %{}, next_id: 0

        @type subscription_id :: pos_integer()
        @type pattern :: Regex.t() | String.t() | atom() | (String.t() -> boolean())
        @type handler :: (map() -> :ok | {:stop, subscription_id})

        @type t :: %__MODULE__{
          subscribers: %{subscription_id() => %{pattern: pattern(), handler: handler()}},
          next_id: subscription_id()
        }

        def new do
          %__MODULE__{}
        end

        @spec subscribe(t(), pattern(), handler()) :: {subscription_id(), t()}
        def subscribe(%__MODULE__{subscribers: subs, next_id: id} = emitter, pattern, handler) do
          entry = %{pattern: pattern, handler: handler}
          {id, %{emitter | subscribers: Map.put(subs, id, entry), next_id: id + 1}}
        end

        @spec unsubscribe(t(), subscription_id()) :: t()
        def unsubscribe(%__MODULE__{subscribers: subs} = emitter, sub_id) do
          %{emitter | subscribers: Map.delete(subs, sub_id)}
        end

        @spec emit(t(), String.t(), map()) :: t()
        def emit(%__MODULE__{subscribers: subs} = emitter, event_name, payload) do
          event = Map.merge(payload, %{event: event_name, timestamp: System.monotonic_time(:millisecond)})
          subs
          |> Enum.filter(fn {_id, %{pattern: pattern}} -> matches?(pattern, event_name) end)
          |> Enum.reduce(emitter, fn {id, %{handler: handler}}, acc ->
            case handler.(event) do
              {:stop, ^id} -> unsubscribe(acc, id)
              :ok -> acc
            end
          end)
        end

        @spec once(t(), pattern(), handler()) :: {subscription_id(), t()}
        def once(%__MODULE__{} = emitter, pattern, handler) do
          sub_id = emitter.next_id
          wrapper = fn event ->
            result = handler.(event)
            unsubscribe(emitter, sub_id)
            result
          end
          subscribe(emitter, pattern, wrapper)
        end

        @spec subscriber_count(t()) :: non_neg_integer()
        def subscriber_count(%__MODULE__{subscribers: subs}), do: map_size(subs)

        @spec subscriber_count(t(), pattern()) :: non_neg_integer()
        def subscriber_count(%__MODULE__{subscribers: subs}, pattern) do
          Enum.count(subs, fn {_id, %{pattern: p}} -> matches?(p, pattern) end)
        end

        @spec clear(t()) :: t()
        def clear(%__MODULE__{} = emitter) do
          %{emitter | subscribers: %{}, next_id: 0}
        end

        defp matches?(%Regex{} = pattern, event_name), do: Regex.match?(pattern, event_name)
        defp matches?(pattern, event_name) when is_binary(pattern), do: pattern == event_name
        defp matches?(pattern, event_name) when is_atom(pattern), do: Atom.to_string(pattern) == event_name
        defp matches?(fun, event_name) when is_function(fun, 1), do: fun.(event_name)

        @spec wildcard(pattern :: String.t()) :: Regex.t()
        def wildcard(pattern) do
          pattern
          |> String.replace(".", "\\\\.")
          |> String.replace("*", ".*")
          |> then(&Regex.compile!("^#{&1}$"))
        end
      end
      """,
      language: "elixir",
      domain: "event_emitter"
    )
  end
end
