defmodule EvoDash.Test.ChatGPTLoginStub do
  @moduledoc """
  A hermetic per-test stand-in for `EvoDash.ChatGPTLogin` (the SIWC flow module).

  Injected through `EvoDashWeb.LLMSetup.ChatGPTSignIn.login_module/0`'s
  CALL-TIME `$callers` seam: `:chatgpt_login_module` is put into the TEST
  process dictionary, and the flow boundary resolves that key through this
  process and then its `:"$callers"` ancestors — `Phoenix.LiveViewTest` puts
  the test pid in the mounted view's `$callers`, and tasks spawned by the
  boundary carry it too. So `install!/1` seeds the test's OWN process and
  nothing here is BEAM-global.

  The mutable flow state (the answer `begin/2` gives, the queue of answers
  `status/1` gives, the ids `cancel/1` saw) lives in an Agent the test starts;
  every call resolves that pid through the `$callers` chain as well, because the
  sign-in boundary calls us from `Task.async` / poll tasks, never only from the
  view. That walk is TRANSITIVE (breadth-first, nearest caller first, read
  through each hop's own `$callers` entry, with a visited set and a depth
  bound), so a call made two or more hops below the test still finds the Agent;
  a direct-callers-only read returned `nil` there and the stub then exited
  `{:noproc, GenServer.call(nil, …)}`.

  When no hop names an Agent — i.e. no `install!/1` ran in the caller chain —
  the stub raises an ExUnit assertion error naming itself, the caller chain and
  the test pid, instead of calling an Agent that does not exist.

  `install!/1` options:

    * `begin:` — `{:ok, %{id:, url:, port:}}` or `{:error, reason}`
      (required). A LIST of such answers is a per-call queue, so one test can
      run several distinct flows without re-installing;
    * `statuses:` — the answer queue; each entry is a value or a zero-arity
      fun (an exhausted queue keeps answering `:pending`). A MAP keyed by flow
      id scopes each queue to its own flow, so a superseded flow's still-running
      poll can never consume the current flow's answer (a plain list keeps the
      first-come-first-served behaviour).

  A cancelled flow always answers `:pending`, like a facade that already
  retired it. Every call also notifies the test pid:
  `{:chatgpt_stub, :begin, account}`, `{:chatgpt_stub, :status, flow_id}` and
  `{:chatgpt_stub, :cancel, flow_id}`.

  The poll interval is shrunk to 5 ms and the cap lifted far beyond any test's
  lifetime, so no test here waits on a wall-clock timer. The per-call budget is
  lifted too: every stub call notifies the test from INSIDE the boundary's
  `Task.async` call, so the product's call budget also bounds that notification
  and a starved host could otherwise kill the task before it runs, losing the
  notification forever (production keeps its own 15 s default).
  """

  # Load-tolerant per-call budget for waits on ASYNC work on a shared host whose
  # scheduling swings 10-30x (test/CONTEXT.md).
  @call_budget_ms 30_000

  @doc """
  Starts the per-test agent and installs the flow-module seams in the CALLING
  process dictionary. Returns the agent pid.
  """
  def install!(opts) do
    test_pid = self()

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          begin: Keyword.fetch!(opts, :begin),
          statuses: Keyword.get(opts, :statuses, []),
          cancelled: [],
          test_pid: test_pid
        }
      end)

    Process.put(:chatgpt_login_module, __MODULE__)
    Process.put(:chatgpt_stub_pid, pid)
    # Keep the poll cheap; the cap is far beyond any test's lifetime.
    Process.put(:chatgpt_signin_poll_interval_ms, 5)
    Process.put(:chatgpt_signin_poll_timeout_ms, 60_000)
    # A stub call must never be killed by the product's per-call budget: the
    # notification is sent from inside the spawned task, so a killed call loses
    # it forever. Same call-time seam, no second mechanism.
    Process.put(:chatgpt_signin_call_timeout_ms, @call_budget_ms)
    pid
  end

  def begin(account, _opts) do
    Agent.get_and_update(pid!(), fn state ->
      send(state.test_pid, {:chatgpt_stub, :begin, account})
      {reply, rest} = pop_begin(state.begin)
      {reply, %{state | begin: rest}}
    end)
  end

  def status(flow_id) do
    Agent.get_and_update(pid!(), fn state ->
      send(state.test_pid, {:chatgpt_stub, :status, flow_id})

      {reply, statuses} =
        if flow_id in state.cancelled do
          {:pending, state.statuses}
        else
          case queue_for(state.statuses, flow_id) do
            [next | rest] -> {resolve(next), put_queue(state.statuses, flow_id, rest)}
            [] -> {:pending, state.statuses}
          end
        end

      {reply, %{state | statuses: statuses}}
    end)
  end

  def cancel(flow_id) do
    Agent.get_and_update(pid!(), fn state ->
      send(state.test_pid, {:chatgpt_stub, :cancel, flow_id})
      {:ok, %{state | cancelled: [flow_id | state.cancelled]}}
    end)
  end

  defp resolve(next) when is_function(next, 0), do: next.()
  defp resolve(next), do: next

  # A single answer, or one answer per `begin/2` call (an exhausted queue
  # degrades to an explicit failure instead of a value the boundary cannot read).
  defp pop_begin([]), do: {{:error, :sign_in_unavailable}, []}
  defp pop_begin([next | rest]), do: {resolve(next), rest}
  defp pop_begin(answer), do: {resolve(answer), answer}

  # A flow-keyed map scopes each queue to its own flow; a plain list keeps the
  # original first-come-first-served behaviour.
  defp queue_for(statuses, flow_id) when is_map(statuses), do: Map.get(statuses, flow_id, [])
  defp queue_for(statuses, _flow_id), do: statuses

  defp put_queue(statuses, flow_id, rest) when is_map(statuses),
    do: Map.put(statuses, flow_id, rest)

  defp put_queue(_statuses, _flow_id, rest), do: rest

  # ── Caller-chain resolution ────────────────────────────────────────────────
  #
  # The Agent pid is per-test process-dictionary state. A flow call can arrive
  # from a task several hops below the test (boundary `Task.async` → poll task
  # → the task calling us), so the `:"$callers"` chain is walked TRANSITIVELY:
  # each hop's OWN `$callers` entry is read too, nearest caller first. A visited
  # set terminates a shared/cyclic chain and the depth bound caps a pathological
  # one.

  # One level = one hop; 32 is far beyond any real call path.
  @max_caller_depth 32

  defp pid! do
    Process.get(:chatgpt_stub_pid) || callers_pid!()
  end

  defp callers_pid! do
    chain = caller_chain(ancestors(self()), MapSet.new([self()]), @max_caller_depth)

    case Enum.find_value(chain, &stub_pid_in/1) do
      nil -> not_installed!(chain)
      pid -> pid
    end
  end

  # Breadth-first, nearest first: level N's ancestors are appended before
  # level N+1's, so a closer install always wins over a farther one.
  defp caller_chain(level, visited, depth) when depth > 0 do
    {unvisited, visited} =
      Enum.reduce(level, {[], visited}, fn pid, {acc, visited} ->
        if is_pid(pid) and not MapSet.member?(visited, pid) do
          {[pid | acc], MapSet.put(visited, pid)}
        else
          {acc, visited}
        end
      end)

    unvisited = Enum.reverse(unvisited)

    case unvisited do
      [] -> []
      hops -> hops ++ caller_chain(Enum.flat_map(hops, &ancestors/1), visited, depth - 1)
    end
  end

  defp caller_chain(_level, _visited, _depth), do: []

  defp ancestors(pid) do
    case dictionary(pid) do
      nil ->
        []

      dictionary ->
        case Keyword.get(dictionary, :"$callers") do
          callers when is_list(callers) -> callers
          _not_a_list -> []
        end
    end
  end

  defp stub_pid_in(pid) do
    case dictionary(pid) do
      nil -> nil
      dictionary -> Keyword.get(dictionary, :chatgpt_stub_pid)
    end
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} when is_list(dictionary) -> dictionary
      _dead_or_unreadable -> nil
    end
  end

  defp not_installed!(chain) do
    test_pid =
      case List.last(chain) do
        nil -> :unknown
        pid -> pid
      end

    ExUnit.Assertions.flunk("""
    #{inspect(__MODULE__)} resolved no Agent pid: NO install!/1 was seen in the caller chain.

      requesting pid: #{inspect(self())}
      caller chain (nearest first): #{inspect(chain)}
      test pid: #{inspect(test_pid)}

    The stub's Agent is per-test process-dictionary state (`:chatgpt_stub_pid`),
    so install!/1 must run in the test process — or in an ancestor whose
    `:"$callers"` chain the calling task inherits. A raw `spawn/1` inherits
    nothing: pass the pid (or call from a Task/supervised child) instead.
    """)
  end
end
