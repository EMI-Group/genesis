defmodule EvoGit.Agent.StreamCase.InteractiveAgent do
  @moduledoc """
  The interactive stub role the streaming suites drive: `session_mode/0` is
  `:interactive`, so a tool-free reply becomes a `{:yield}` (the session parks
  in `:awaiting_input`) instead of a terminal completion.

  Defined ABOVE the template module on purpose: `mix test` starts the ExUnit
  async runner BEFORE requiring test files, so a helper defined later in the
  file can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the interactive streaming stub role."
  def system_prompt, do: "You are the streaming test interactive stub agent."

  @doc "No tools: every exchange in the streaming suites is scripted by a seam."
  def available_tools, do: []

  @doc "Interactive: a tool-free reply yields and parks the session."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.StreamCase.OneshotAgent do
  @moduledoc """
  The default `:oneshot` stub role — a tool-free reply completes the run
  instead of yielding. Used where a suite needs a TERMINAL exchange (e.g. the
  `{:finished, status}` delta).
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the one-shot streaming stub role."
  def system_prompt, do: "You are the streaming test one-shot stub agent."

  @doc "No tools: every exchange in the streaming suites is scripted by a seam."
  def available_tools, do: []

  @doc "Explicit, though it is also the behaviour default."
  def session_mode, do: :oneshot
end

defmodule EvoGit.Agent.StreamCase do
  @moduledoc """
  Shared fixtures for the P4 push-only streaming suites
  (`docs/agent-runtime-refactor.md` §3 D5, §4.6 and §7 invariant 2).

  The template mirrors the P3 session suites' harness
  (`test/evo_git/agent/session/interactive_test.exs`) instead of inventing a
  second one: a session is started DIRECTLY (`Session.start_link/1`) against a
  repo-less `dispatch_ctx` whose `:exchange_opts` carries a scripted
  `:llm_call` engine seam, so no git repository, worktree, LLM request or
  scheduler dispatch is involved. The `:scheduler` seam is this test process,
  so the session's yield/resume/terminal notices arrive in the test mailbox.

  ## Why `async: true` is safe

  Everything the fixtures touch is per-agent:
  `:evogit_agent_summary` / `:evogit_sched_meta` / the control-plane inbox are
  BEAM-global ETS tables, so every fixture uses a PER-TEST UNIQUE agent id
  (`9_960_000 + System.unique_integer/1`), installs one PRODUCTION-SHAPED row
  and deletes exactly that row (plus its temp dir and any pending message) in
  `on_exit`. Nothing asserts on a table as a whole and no app-env key, Logger
  level or `:persistent_term` entry is touched. PubSub subscriptions are keyed
  by the unique per-agent topic, so no two suites share a topic.
  """

  use ExUnit.CaseTemplate

  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.{Batcher, Interrupted, Sink, Snapshot, Watchers}
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.Core.ContextNode

  using do
    quote do
      import EvoGit.Agent.StreamCase

      alias EvoGit.Agent.Result
      alias EvoGit.Agent.Session
      alias EvoGit.Agent.Stream
      alias EvoGit.Agent.Stream.{Batcher, Interrupted, Sink, Snapshot, Watchers}
      alias EvoGit.Agent.State
      alias EvoGit.AgentScheduler
      alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
      alias EvoGit.AgentScheduler.ControlPlane
      alias EvoGit.AgentScheduler.Store, as: SchedStore
    end
  end

  # Kept disjoint from the other suites' id ranges (9_9xx_000).
  @agent_id_base 9_960_000

  setup do
    agent_id = new_agent_id()
    tmp_dir = new_tmp_dir(agent_id)
    register_agent(agent_id, tmp_dir)

    on_exit(fn -> unregister_agent(agent_id, tmp_dir) end)

    %{agent_id: agent_id, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc "A per-test unique agent id in this suite's disjoint range."
  def new_agent_id, do: @agent_id_base + System.unique_integer([:positive])

  @doc "A per-test unique repo-less source directory, created on disk."
  def new_tmp_dir(agent_id) do
    dir = Path.join(System.tmp_dir!(), "evogit_stream_#{agent_id}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Installs the production-shaped scheduler rows for `agent_id`.

  `opts`: `:agent_module` (default `InteractiveAgent`), `:cache_key`
  (default `"genesis-stream-fixture-<id>"`), `:mode` (row `mode`, default
  `:oneshot` — the `AgentState` default; the role callback still decides unless
  the dispatch ctx carries an explicit `:session_mode`).
  """
  def register_agent(agent_id, tmp_dir, opts \\ []) do
    :ok = SchedStore.put_agent_state(agent_id, agent_state(agent_id, opts))
    :ok = SchedStore.put_sched_meta(agent_id, sched_meta(agent_id, tmp_dir, opts))
    :ok
  end

  @doc "Deletes everything `register_agent/3` installed, plus scratch state."
  def unregister_agent(agent_id, tmp_dir) do
    _ = SchedStore.drain_pending_user_messages(agent_id)
    SchedStore.delete_agent_state(agent_id)
    SchedStore.delete_sched_meta(agent_id)
    SchedStore.clear_cancel_requested(agent_id)
    File.rm_rf(tmp_dir)
    :ok
  end

  @doc """
  Starts a session directly (no scheduler dispatch) and returns
  `{:ok, pid, monitor_ref}`; the process is unlinked and killed on exit.
  """
  def start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  @doc """
  The dispatch context for a repo-less session bound to one agent id.

  `exchange_opts` is forwarded verbatim as the worker's engine seam list
  (`:llm_call` etc.) — production passes none.
  """
  def dispatch_ctx(agent_id, tmp_dir, exchange_opts \\ []) do
    agent_module = Keyword.get(exchange_opts, :agent_module, __MODULE__.InteractiveAgent)
    repo_less_opts = Keyword.get(exchange_opts, :repo_less_opts, [])

    spec = %EvoGit.AgentSpec{
      context_node: %ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: agent_module,
      objective: "streaming session test objective",
      opts: [repo_less: true, task_tmpdir: tmp_dir] ++ repo_less_opts
    }

    meta = %SchedMeta{
      id: agent_id,
      depth: 0,
      spec: spec,
      task_id: "task-#{agent_id}"
    }

    [
      agent_id: agent_id,
      depth: 0,
      repo_root: tmp_dir,
      repo_id: "primary",
      worktree_path: Path.join(tmp_dir, "worker"),
      retries: 0,
      spec: spec,
      meta: meta,
      repo_less: true,
      repo_less_repo_path: tmp_dir,
      notify: self(),
      # A TEST-OWNED scheduler sink: session notices land in this process.
      scheduler: self(),
      exchange_opts: Keyword.drop(exchange_opts, [:agent_module, :repo_less_opts])
    ]
  end

  # ---------------------------------------------------------------------------
  # Scripted LLM seam
  # ---------------------------------------------------------------------------

  @doc "A genuine `%ReqLLM.Response{}` for a tool-free assistant reply."
  def response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "stream-test-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  @doc """
  A seam whose single tool-free reply is `text` (a yield for an interactive
  role, a completion for a one-shot one).
  """
  def yielding_llm_call(text) do
    fn context, _tools, _params, _agent_id, _retries ->
      {:implicit_completion, response(context, text), text}
    end
  end

  @doc """
  A seam that hands control to `fun` — called in the WORKER process with the
  seam arguments — so a test can emit deltas through the installed
  `EvoGit.Agent.Stream.Sink` and drive the exchange step by step.
  """
  def scripted_llm_call(fun) do
    fn context, tools, params, agent_id, retries ->
      fun.(context, tools, params, agent_id, retries)
    end
  end

  @doc """
  The test-driven seam: every LLM attempt parks in the WORKER process and
  reports `{:llm_call, worker_pid, context}` to `test_pid`; the test then
  answers with one of

    * `{:reply, text}` — a tool-free reply (yield or completion);
    * `{:emit, events, text}` — emit each event through `Sink.emit/1` (one
      `{:delta, …}` message per event, so a burst is genuinely MANY messages),
      then reply;
    * `{:emit_waves, [events_a, events_b, …], text}` — emit the first wave, wait
      for `:next_wave`, emit the next, and so on, so a test can observe one
      coalesced batch before releasing the next window.

  This makes every step of the exchange (and the moment a watcher attaches)
  deterministic: the worker cannot advance past the current attempt until the
  test says so. The seam runs in the worker process, which is exactly where
  `Sink.install/2` put the sink.
  """
  def driver_llm_call(test_pid) do
    scripted_llm_call(fn context, _tools, _params, _agent_id, _retries ->
      send(test_pid, {:llm_call, self(), context})

      receive do
        {:reply, text} ->
          {:implicit_completion, response(context, text), text}

        {:emit, events, text} ->
          Enum.each(events, &Sink.emit/1)
          {:implicit_completion, response(context, text), text}

        {:emit_waves, waves, text} ->
          emit_waves(waves)
          {:implicit_completion, response(context, text), text}
      end
    end)
  end

  defp emit_waves([]), do: :ok

  defp emit_waves([wave]), do: Enum.each(wave, &Sink.emit/1)

  defp emit_waves([wave | rest]) do
    Enum.each(wave, &Sink.emit/1)

    # Bounded escape hatch so a wedged test can never leave the worker parked
    # forever; the normal path is the test's `:next_wave`.
    receive do
      :next_wave -> emit_waves(rest)
    after
      5_000 -> emit_waves(rest)
    end
  end

  @doc "Non-destructive peek at the agent's queued (pending) user messages."
  def pending_messages(agent_id), do: ControlPlane.pending_messages(agent_id)

  # ---------------------------------------------------------------------------
  # Observation helpers (all bounded/event-driven — no fixed sleeps)
  # ---------------------------------------------------------------------------

  @doc "Bounded poll until `fun` returns truthy (`true`), else `false`."
  def wait_until(fun, timeout \\ 2_000) do
    do_wait_until(fun, deadline(timeout))
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if remaining(deadline) > 0 do
        Process.sleep(5)
        do_wait_until(fun, deadline)
      else
        false
      end
    end
  end

  @doc "Bounded poll of the session phase."
  def await_phase(pid, phase, timeout \\ 2_000) do
    wait_until(
      fn ->
        match?({:ok, %{phase: ^phase}}, Session.inspect(pid, 200))
      end,
      timeout
    )
  end

  @doc "Bounded wait for a yielded-text notice (falls back to the idle phase)."
  def await_yield(pid, text, timeout \\ 2_000) do
    receive do
      {:agent_session_yield, _agent_id, ^pid, ^text} -> true
    after
      timeout ->
        await_phase(pid, :awaiting_input, 200)
    end
  end

  @doc "Waits for the ONE terminal result notice of a session run."
  def await_terminal(agent_id, session_pid, timeout \\ 5_000) do
    receive do
      {:agent_session_result, ^agent_id, ^session_pid, result} -> result
    after
      timeout -> :no_terminal_result
    end
  end

  @doc "Asserts that NO terminal result notice arrives within `timeout`."
  def refute_terminal(agent_id, session_pid, timeout \\ 300) do
    refute_receive {:agent_session_result, ^agent_id, ^session_pid, result},
                   timeout,
                   "expected NO terminal result, got #{inspect(result)}"
  end

  @doc """
  Subscribes the calling process to the agent's delta topic WITHOUT registering
  it as a watcher — the observer shape of the zero-watcher suites.
  """
  def subscribe_topic(agent_id) do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, Stream.topic(agent_id))
  end

  @doc """
  Collects every `{:agent_delta, agent_id, seq, events}` already queued (or
  arriving within `first_timeout`) plus any that follow within
  `quiet_timeout` of the previous one.

  A bounded observation window, not a fixed wait for a correctness signal: the
  batcher's own 75 ms flush is the event, and the quiet tail only decides when
  "no more batches" has been observed.
  """
  def collect_deltas(agent_id, first_timeout \\ 2_000, quiet_timeout \\ 250) do
    receive do
      {:agent_delta, ^agent_id, seq, events} ->
        [{seq, events} | collect_more_deltas(agent_id, quiet_timeout)]
    after
      first_timeout -> []
    end
  end

  defp collect_more_deltas(agent_id, quiet_timeout) do
    receive do
      {:agent_delta, ^agent_id, seq, events} ->
        [{seq, events} | collect_more_deltas(agent_id, quiet_timeout)]
    after
      quiet_timeout -> []
    end
  end

  @doc "Bounded deadline bookkeeping shared by the wait helpers."
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @doc "Milliseconds left on a `deadline/1`, floored at zero."
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc "The text parts of a `%ReqLLM.Message{}` joined in order."
  def text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  def text_of(_other), do: ""

  # ---------------------------------------------------------------------------
  # Production-shaped scheduler rows
  # ---------------------------------------------------------------------------

  defp agent_state(agent_id, opts) do
    key = Keyword.get(opts, :cache_key, "genesis-stream-fixture-#{agent_id}")

    %AgentState{
      context_node: %ContextNode{path: "./", repo: "[system]"},
      objective: "streaming registration objective sentinel",
      parent_id: nil,
      archive: false,
      llm_model: nil,
      model_id: "stream-case-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000,
      mode: Keyword.get(opts, :mode, :oneshot),
      # The cache identity has no dedicated row field: `Session` PROJECTS it
      # from the account's provider options, exactly where registration puts it.
      llm_generation_params: [
        temperature: 0.2,
        provider_options: [prompt_cache_key: key]
      ]
    }
  end

  defp sched_meta(agent_id, tmp_dir, opts) do
    %SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: "task-#{agent_id}",
      from: {self(), make_ref()},
      spec: %EvoGit.AgentSpec{
        context_node: %ContextNode{path: "./", repo: "[system]"},
        phylo_node: nil,
        agent_module: Keyword.get(opts, :agent_module, __MODULE__.InteractiveAgent),
        objective: "streaming session test objective",
        opts: [repo_less: true, task_tmpdir: tmp_dir]
      }
    }
  end
end
