defmodule EvoGit.Agent.Exchange.Seams do
  @moduledoc """
  The seam contract that makes ONE exchange runnable in a bare process.

  `EvoGit.Agent.Exchange.run/2` (the engine) is a plain function over
  `%EvoGit.Agent.State{}`: it needs no scheduler, no ETS table and no live agent
  process. The four seams below are the ONLY places it touches the outside
  world, so an exchange can be executed and asserted in a bare test process with
  four stubs (the first three are the behaviour seams, `:checkpoint` is
  observable-only).

  ## Default-inert by construction

  Every seam defaults to `nil`, meaning "use the PRODUCTION path" — an absent
  seam key means BYTE-IDENTICAL production behaviour. The seams exist ONLY so an
  unwatched exchange is executable and assertable in a bare process; they must
  NEVER be used to change production behaviour (no seam may be set in a shipped
  configuration — only tests and the engine's own injection point set them).

  ## Resolution order (`from_opts/1`)

  For each seam, in order:

  1. the explicit `opts` key (`:llm_call` / `:tool_batch` / `:scheduler` /
     `:checkpoint`) when present — even when its value is `nil` (an explicit
     `nil` means "use the production path", overriding any app-env default);
  2. the app-env default, read AT CALL TIME (`Application.get_env(:evo_git,
     :agent_exchange_llm_call)` / `:agent_exchange_tool_batch` /
     `:agent_exchange_scheduler` / `:agent_exchange_checkpoint`), `nil` when
     unset;
  3. `nil`.

  ## The additional opts-only clock pin (`:now`)

  `Exchange.run/2` and `Turn.run/3` also read an OPTIONAL `:now` key from the
  same `opts` (see `EvoGit.Agent.Clock`): an integer Unix second, a `DateTime`,
  a `NaiveDateTime` (read as UTC) or a 0-arity function returning one of those,
  pinning every per-message `metadata[:timestamp]` this exchange stamps.

  It is NOT one of the four seams and has NO app-env default: a `:now` key can
  only come from the caller's `opts`, an absent (or explicitly `nil`) value
  means the real clock, and the pin is PROCESS-DICTIONARY scoped so a
  concurrent exchange is never affected. The four behaviour seams above keep
  their resolution order unchanged.

  ## The four seams

  ### `llm_call` — arity 5

      (context, tools, llm_generation_params, agent_id, max_retries) ->
        {:ok, response} | {:implicit_completion, response, text} | {:error, reason}

  Production default: `&EvoGit.Agent.LLMPrompting.prompt_until_tools_or_limit/5`
  (see `default_llm_call/0`). The engine calls it whenever `seam == nil`.

  ### `tool_batch` — arity 2

      (indexed_calls, state) -> indexed_results

  `indexed_calls` is the same list todays' batch entry point receives, and
  `indexed_results` must be in the EXACT shape
  `EvoGit.Agent.ToolDispatch.batch_execute_tools/5` returns to its caller:
  `[{index, tool_call_id, name, output}]`.

  `nil` means the real
  `EvoGit.Agent.ToolDispatch.process_standard_calls/2` path. When set, it
  REPLACES the whole standard-call batch (no `EvoGit.ToolRuntime` call, no
  delegation-hint tracking, no commit sync after tools) — but the per-call
  result assembly, the result ordering, the subagent partitioning and the
  `%ReqLLM.Message{}` construction all stay the engine's.

  ### `scheduler` — arity 3

      (kind, payload, state) -> term()

  ONE adapter for every scheduler CONTROL-PLANE interaction the loop performs.
  It carries only the input/control surface (`:drain_inputs`,
  `:cancel_requested?`, `:clear_cancel`) — the conversation state itself is
  owned by the session process and published through the `:checkpoint` seam, so
  there is no per-turn ETS write-through anymore. A test seam is normally
  `fn _kind, _payload, _state -> :ok end`. The kinds and their production
  defaults (`default_scheduler/3`):

  | `kind` | `payload` | default implementation |
  |---|---|---|
  | `:drain_inputs` | ignored | `EvoGit.AgentScheduler.Store.drain_pending_user_messages(state.agent_id)` → `[String.t() \\| map()]` |
  | `:cancel_requested?` | ignored | `EvoGit.AgentScheduler.Store.cancel_requested?(state.agent_id)` → `boolean()` |
  | `:clear_cancel` | ignored | `EvoGit.AgentScheduler.Store.clear_cancel_requested(state.agent_id)` |

  ### `checkpoint` — arity 1

      (state) -> term()

  Receives the state at EVERY turn boundary: once per turn, AFTER that turn's
  state update, and it is called with the state the turn produced — for a
  continuing turn the state handed to the recursive loop step, for a finishing
  turn the final state, once, before the outcome is returned.

  The return value is DISCARDED — this seam is observable-only and MUST NOT
  change the state or the outcome. It exists so a session/streaming layer can
  observe each turn boundary without being wired into the engine's control flow.

  Default-inert by construction: an absent key (nil, or an explicit `false`)
  means "no checkpointing" and the engine performs NO extra state work, so an
  un-seamed exchange stays byte-identical to the un-checkpointed loop.
  """

  alias EvoGit.Agent.State

  defstruct llm_call: nil, tool_batch: nil, scheduler: nil, checkpoint: nil

  @typedoc "See the moduledoc for the contract of each seam."
  @type llm_call ::
          (ReqLLM.Context.t(), [ReqLLM.Tool.t()], keyword(), pos_integer(), non_neg_integer() ->
             {:ok, ReqLLM.Response.t()}
             | {:implicit_completion, ReqLLM.Response.t(), String.t()}
             | {:error, term()})

  @type tool_batch ::
          ([{ReqLLM.ToolCall.t(), non_neg_integer()}], State.t() ->
             [{non_neg_integer(), String.t(), String.t(), term()}])

  @type scheduler_kind ::
          :drain_inputs
          | :cancel_requested?
          | :clear_cancel

  @type scheduler :: (scheduler_kind(), term(), State.t() -> term())

  @typedoc """
  Observable-only per-turn checkpoint hook: called once per turn AFTER the
  turn's state update; the return value is discarded.
  """
  @type checkpoint :: (State.t() -> term())

  @type t :: %__MODULE__{
          llm_call: llm_call() | nil,
          tool_batch: tool_batch() | nil,
          scheduler: scheduler() | nil,
          checkpoint: checkpoint() | nil
        }

  @llm_call_env :agent_exchange_llm_call
  @tool_batch_env :agent_exchange_tool_batch
  @scheduler_env :agent_exchange_scheduler
  @checkpoint_env :agent_exchange_checkpoint

  @doc """
  Builds the seam set for one exchange from a keyword list.

  See the moduledoc for the resolution order. An absent key resolves to the
  app-env default (read at call time) and then to `nil` = production path.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    %__MODULE__{
      llm_call: resolve(opts, :llm_call, @llm_call_env),
      tool_batch: resolve(opts, :tool_batch, @tool_batch_env),
      scheduler: resolve(opts, :scheduler, @scheduler_env),
      checkpoint: resolve(opts, :checkpoint, @checkpoint_env)
    }
  end

  # Explicit opts key wins (even when nil), else the call-time app-env default.
  defp resolve(opts, key, env_key) do
    case Keyword.fetch(opts, key) do
      {:ok, seam} -> seam
      :error -> Application.get_env(:evo_git, env_key)
    end
  end

  @doc """
  The production `llm_call` seam: `EvoGit.Agent.LLMPrompting.prompt_until_tools_or_limit/5`.
  """
  @spec default_llm_call() :: llm_call()
  def default_llm_call, do: &EvoGit.Agent.LLMPrompting.prompt_until_tools_or_limit/5

  @doc """
  The production `scheduler` seam: the exact control-plane calls the turn loop
  performs today.

  See the moduledoc for the kind list. An unknown kind raises a
  `FunctionClauseError` on purpose (a seam that silently swallowed an
  interaction the engine relies on would hide a broken exchange).
  """
  @spec default_scheduler(scheduler_kind(), term(), State.t()) :: term()
  def default_scheduler(:drain_inputs, _payload, %State{agent_id: agent_id}) do
    EvoGit.AgentScheduler.Store.drain_pending_user_messages(agent_id)
  end

  def default_scheduler(:cancel_requested?, _payload, %State{agent_id: agent_id}) do
    EvoGit.AgentScheduler.Store.cancel_requested?(agent_id)
  end

  def default_scheduler(:clear_cancel, _payload, %State{agent_id: agent_id}) do
    EvoGit.AgentScheduler.Store.clear_cancel_requested(agent_id)
  end
end
