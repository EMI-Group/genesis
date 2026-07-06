defmodule EvoGit.Runtime.Evolution.SeedFragments.Generators.Systems do
  @moduledoc """
  Systems-oriented seed fragments: process pools, stream processing, rate limiting, TTL caching, and event emitters.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  def process_pool_fragment do
    Fragment.new(
      ~S"""
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

        def spawn_worker(pool_pid, id) do
          spawn(fn -> worker_loop(pool_pid, id) end)
        end

        def worker_loop(pool_pid, id) do
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

        def find_idle_worker(workers) do
          Enum.find_value(workers, fn {id, w} -> if w.task == nil, do: id end)
        end

        def dispatch(worker_id, task_id, task, from, state) do
          send(state.workers[worker_id].pid, {:run, task_id, task})
          workers = put_in(state.workers[worker_id].task, task_id)
          pending = Map.put(state.pending, task_id, from)
          {:noreply, %{state | workers: workers, pending: pending, next_id: state.next_id + 1}}
        end

        def dequeue_task(%{task_queue: q} = state) do
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

  def stream_processing_fragment do
    Fragment.new(
      ~S"""
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

        def apply_stage(upstream, %{fun: fun, concurrency: conc}, buffer_size) do
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

        def apply_backpressure(stream, buffer_size) do
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

  def rate_limiter_fragment do
    Fragment.new(
      ~S"""
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

        def refill_tokens(%__MODULE__{last_refill: nil} = limiter) do
          %{limiter | last_refill: System.monotonic_time(:millisecond)}
        end
        def refill_tokens(%__MODULE__{} = limiter) do
          now = System.monotonic_time(:millisecond)
          elapsed = now - limiter.last_refill
          tokens_to_add = div(elapsed * limiter.refill_rate, 1000)
          new_tokens = min(limiter.max_tokens, limiter.tokens + tokens_to_add)
          %{limiter | tokens: new_tokens, last_refill: now}
        end

        def prune_window(%__MODULE__{} = limiter) do
          cutoff = System.monotonic_time(:millisecond) - limiter.window_ms
          pruned = Enum.filter(limiter.requests, &(&1 > cutoff))
          %{limiter | requests: pruned}
        end

        def compute_wait(%__MODULE__{requests: []}), do: 100
        def compute_wait(%__MODULE__{requests: [oldest | _], window_ms: window}) do
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

  def cache_ttl_fragment do
    Fragment.new(
      ~S"""
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

        def maybe_evict(cache, _key, _now), do: cache
        def maybe_evict_expired(cache, now) do
          expired = for {k, {_, exp}} <- cache.entries, exp <= now, do: k
          entries = Map.drop(cache.entries, expired)
          %{cache | entries: entries, stats: Map.update!(cache.stats, :evictions, &(&1 + length(expired)))}
        end

        def evict_oldest(entries) do
          {key, {_val, oldest}} = Enum.min_by(entries, fn {_, {_, exp}} -> exp end)
          {key, oldest, Map.delete(entries, key)}
        end

        def update_stats(cache, :hit), do: %{cache | stats: Map.update!(cache.stats, :hits, &(&1 + 1))}
        def update_stats(cache, :eviction), do: %{cache | stats: Map.update!(cache.stats, :evictions, &(&1 + 1))}
      end
      """,
      language: "elixir",
      domain: "cache_ttl"
    )
  end

  def event_emitter_fragment do
    Fragment.new(
      ~S"""
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

        def matches?(%Regex{} = pattern, event_name), do: Regex.match?(pattern, event_name)
        def matches?(pattern, event_name) when is_binary(pattern), do: pattern == event_name
        def matches?(pattern, event_name) when is_atom(pattern), do: Atom.to_string(pattern) == event_name
        def matches?(fun, event_name) when is_function(fun, 1), do: fun.(event_name)

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
