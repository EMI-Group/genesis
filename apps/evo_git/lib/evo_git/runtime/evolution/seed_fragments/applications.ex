defmodule EvoGit.Runtime.Evolution.SeedFragments.Generators.Applications do
  @moduledoc """
  Application-oriented seed fragments: physics simulation, game loops, and data pipelines.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  def physics_fragment do
    Fragment.new(
      ~S"""
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

        def step(particles, dt) do
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

  def game_loop_fragment do
    Fragment.new(
      ~S"""
      defmodule GameLoop.State do
        @moduledoc "2D game state machine with update/render cycle."

        defstruct scene: :menu, entities: [], score: 0, tick: 0, running: true

        def new do
          %__MODULE__{entities: [player(), enemy(1), enemy(2)]}
        end

        def player, do: %{type: :player, x: 400.0, y: 300.0, hp: 100, speed: 5.0}
        def enemy(id), do: %{type: :enemy, id: id, x: :rand.uniform(800) * 1.0, y: :rand.uniform(600) * 1.0, hp: 30}

        def update(%__MODULE__{running: false} = state), do: state
        def update(%__MODULE__{tick: tick} = state) do
          state
          |> update_entities()
          |> check_collisions()
          |> handle_scene_transitions()
          |> Map.put(:tick, tick + 1)
        end

        def update_entities(%{entities: entities} = state) do
          %{state | entities: Enum.map(entities, &update_entity/1)}
        end

        def update_entity(%{type: :enemy, x: ex, y: ey} = e) do
          dx = :rand.uniform() * 4 - 2
          dy = :rand.uniform() * 4 - 2
          %{e | x: max(0, min(800, ex + dx)), y: max(0, min(600, ey + dy))}
        end
        def update_entity(entity), do: entity

        def check_collisions(%{entities: entities} = state) do
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

        def handle_scene_transitions(%{entities: entities} = state) do
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

        def draw_cell(x, y, entities) do
          Enum.find_value(entities, ".", fn e ->
            if div(trunc(e.x), 200) == x and div(trunc(e.y), 150) == y, do: render_char(e.type), else: nil
          end)
        end

        def render_char(:player), do: "@"
        def render_char(:enemy), do: "E"
      end
      """,
      language: "elixir",
      domain: "game_loop"
    )
  end

  def data_pipeline_fragment do
    Fragment.new(
      ~S"""
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

        def apply_stages(stream, stages) do
          Enum.reduce(stages, stream, fn stage, acc ->
            apply_stage_stream(acc, stage)
          end)
        end

        def apply_stage_stream(stream, {:map, fun}), do: Stream.map(stream, fun)
        def apply_stage_stream(stream, {:filter, fun}), do: Stream.filter(stream, fun)
        def apply_stage_stream(stream, {:reduce, acc, fun}) do
          Stream.transform(stream, acc, fn item, a ->
            new_acc = fun.(item, a)
            {[new_acc], new_acc}
          end)
        end
        def apply_stage_stream(stream, {:flat_map, fun}), do: Stream.flat_map(stream, fun)
        def apply_stage_stream(stream, {:each, fun}) do
          Stream.each(stream, fun)
        end

        def apply_stage(data, {:map, fun}), do: Enum.map(data, fun)
        def apply_stage(data, {:filter, fun}), do: Enum.filter(data, fun)
        def apply_stage(data, {:reduce, acc, fun}), do: Enum.reduce(data, acc, fun)
        def apply_stage(data, {:flat_map, fun}), do: Enum.flat_map(data, fun)
        def apply_stage(data, {:sort_by, fun}), do: Enum.sort_by(data, fun)

        def validate(item) when is_map(item), do: {:ok, item}
        def validate(item) when is_list(item), do: {:ok, Map.new(item)}
        def validate({k, v}) when is_atom(k), do: {:ok, %{k => v}}
        def validate(_), do: {:error, :invalid_input}

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
end
