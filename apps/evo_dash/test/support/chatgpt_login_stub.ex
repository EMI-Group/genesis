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
  every call resolves that pid through `$callers` as well, because the sign-in
  boundary calls us from `Task.async` / poll tasks, never only from the view.

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
  lifetime, so no test here waits on a wall-clock timer.
  """

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

  defp pid! do
    Process.get(:chatgpt_stub_pid) ||
      Enum.find_value(Process.get(:"$callers") || [], fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> Keyword.get(dictionary, :chatgpt_stub_pid)
          _ -> nil
        end
      end)
  end
end
