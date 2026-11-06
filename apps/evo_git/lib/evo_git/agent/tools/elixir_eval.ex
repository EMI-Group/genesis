defmodule EvoGit.Agent.Tools.ElixirEval do
  @moduledoc """
  Assistant-only Elixir evaluation boundary with explicit read, write and sudo tiers.

  Authorization comes from the owning agent, not the fresh tool process's role
  dictionary. The engine supplies fresh bindings on every call; this wrapper never
  evaluates code to infer its tier and never escalates a refused evaluation.
  """

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, DirectAPI, Engine}
  alias EvoGit.Agent.Tools.Failure

  @max_code_bytes 16_000
  @default_timeout_ms 2_000
  @max_timeout_ms 5_000
  @default_output_bytes 16_384
  @max_output_bytes 65_536
  @min_output_bytes 256
  @truncation_marker "\n...[truncated]"

  @doc "Returns the assistant-only tool schema."
  def schema do
    ReqLLM.tool(
      name: "elixir_eval",
      description:
        "Evaluate Elixir with fresh bindings. Inspect source with read/glob/rg, then call " <>
          "explicitly admitted real APIs in Dune at read (default) or write tier; Read/Write " <>
          "facades are optional conveniences. Write requires manual approval of the exact code. " <>
          "Sudo is dangerous, UNSANDBOXED full VM Code evaluation, available only AFTER " <>
          "manual approval. Never auto-escalate. Timeout/output caps are best effort for sudo; " <>
          "side effects cannot be rolled back.\n\n" <> help(),
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "code" => %{
            "type" => "string",
            "description" =>
              "Exact Elixir code to evaluate (nonblank UTF-8, at most 16000 bytes)."
          },
          "tier" => %{
            "type" => "string",
            "enum" => ["read", "write", "sudo"],
            "default" => "read",
            "description" => "Explicit capability tier; no inference or automatic escalation."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "default" => @default_timeout_ms,
            "description" =>
              "Positive integer milliseconds; clamped to 5000. Approval wait is separate."
          },
          "max_output_bytes" => %{
            "type" => "integer",
            "default" => @default_output_bytes,
            "description" =>
              "Positive integer byte budget; clamped to 256..65536, including errors."
          },
          "target_node" => %{
            "type" => "string",
            "description" => "Local node only: current, local, or the exact current node name."
          }
        },
        "required" => ["code"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc "Whether the current tool call belongs to the authorized assistant owner."
  def authorized_assistant?, do: Authorization.assistant_owner?()

  @doc "Authorizes the assistant owner and optional local target node."
  def authorize(target_node \\ nil), do: Authorization.authorize(target_node)

  @doc """
  The evaluator's persona-facing capability contract.
  """
  def help do
    """
    Elixir evaluator capabilities (local node only):
    Inspect source with read/glob/rg to understand real APIs, then call only the
    explicitly admitted module/function/arities for your tier (catalog below).
    Source visibility and public API status do not grant evaluation authority.
    Examples (read tier):
      EvoGit.TaskRegistry.list_tasks_page(limit: 10)
      EvoGit.AgentScheduler.get_config(:max_turns)
    Example (write tier, exact-code approval; runtime-only, not persisted):
      EvoGit.AgentScheduler.update_config(max_tool_concurrency: 8)
    Read/Write facades are optional convenience APIs, not the sole path:
    Read facade (EvoGit.Agent.Tools.ElixirEval.Read):
      help/0 (this contract), system_info/0, list_tasks/0, list_tasks/1,
      get_task/1 (task id), list_agents/0, scheduler_status/0, model_profiles/0,
      configuration_status/0.
    Write facade (EvoGit.Agent.Tools.ElixirEval.Write; write tier required):
      start_task/2 (type string, options map), cancel_task/1 (task id),
      force_kill_task/1 (task id), delete_task/1 (task id),
      guide/1 (message), guide/2 (message, options map), update_scheduler_config/1 (options map).
    Use fully qualified module names; Dune does not support alias declarations.
    list_tasks/1 accepts %{limit: 25, offset: 0, status: "all"} (defaults);
    list_tasks/0 is equivalent. Limit: integer 1..50; offset: integer 0..10000.
    Status: "all" or pending/running/finalizing/cancelling/completed/failed/cancelled
    (status string or atom). Only limit/offset/status atom or string keys are accepted.
    Task ids: 1..128 bytes, ASCII letters/digits/underscore/hyphen only.

    configuration_status/0 returns exactly default_llm_max_concurrency,
    max_tool_concurrency, max_turns, max_turns_root and paused from the live scheduler;
    no credentials, raw configuration or file paths. Reads are not an atomic snapshot.
    update_scheduler_config/1 accepts a nonempty map with atom or string keys from
    those same five fields; unknown keys and duplicate normalized keys are rejected.
    default_llm_max_concurrency/max_tool_concurrency: integers 1..256;
    max_turns/max_turns_root: integers 1..10000. paused: boolean, standalone only,
    never mixed with numeric settings. Numeric strings, floats and nil are rejected.
    Changes are runtime-only, never persisted, and may be replaced by restart/reload
    or another runtime update. Turn caps apply to future agent registrations only.
    Timeout or lost authority does not roll back committed effects; inspect
    EvoGit.Agent.Tools.ElixirEval.Read.configuration_status() before retrying.

    start_task/2: type is "genesis", "evolve", "reflect" or "extract_skills".
    Only %{path: ..., mode: ..., objective: ..., prompt: ..., model_id: ...} options
    are accepted (atom or string keys, no duplicate spellings). All supplied values
    must be nonblank UTF-8 strings without NUL, <=8000 bytes each.
    Genesis mode defaults to "new"; valid modes: "new"/"existing". Supply prompt or
    objective (prompt wins if both supplied). Evolve mode defaults to and only accepts
    "simple"; reflect mode defaults to and only accepts "reflect"; both need objective
    and reject prompt. Extract_skills accepts only path/model_id, no mode/objective/prompt.
    Non-reflect tasks require an absolute path <=1024 bytes to an existing directory,
    except genesis-new may create a new directory. Reflect rejects path entirely.
    Optional model_id must name a configured profile and locks that model choice.
    Custom/merge/resume/foreign-repo options are not exposed.
    Mutations cannot target the calling assistant's own task. Cancel accepts only
    pending/running tasks; force-kill only running/cancelling; delete only terminal
    completed/failed/cancelled tasks. Delete is a CAST queued acknowledgement, NOT
    confirmation of persisted deletion. On uncertain submission, inspect before retrying.

    guide/2: message is nonblank UTF-8 without NUL, <=2000 bytes.
    Only page/selector/dismissible atom or string keys, no duplicate spellings.
    Page defaults to nil; allowed: nil, "/", "/help", "/projects", "/tasks", "/agents",
    "/settings", "/system". Selector defaults to nil, otherwise a simple #id <=80 bytes:
    # followed by an ASCII letter, then ASCII letters/digits/underscore/hyphen only.
    Dismissible is boolean, default true. guide/1 uses these defaults.
    Fixed per-evaluation facade quotas: 128 broker requests (including IO), 32 reads,
    500 charged projected rows, 16 writes, four task starts; one pending runtime operation.
    Row charges: requested task-page limit, 100 per agent/model-profile read, one otherwise.

    Examples (read tier):
      EvoGit.Agent.Tools.ElixirEval.Read.help()
      EvoGit.Agent.Tools.ElixirEval.Read.list_tasks(%{limit: 10, offset: 0, status: "running"})
      EvoGit.Agent.Tools.ElixirEval.Read.system_info()
      EvoGit.Agent.Tools.ElixirEval.Read.configuration_status()
    Examples (write tier, require approval):
      EvoGit.Agent.Tools.ElixirEval.Write.update_scheduler_config(%{max_tool_concurrency: 8, max_turns: 256})
      EvoGit.Agent.Tools.ElixirEval.Write.update_scheduler_config(%{"paused" => true})
      EvoGit.Agent.Tools.ElixirEval.Write.start_task("reflect", %{objective: "Explain task status"})
      EvoGit.Agent.Tools.ElixirEval.Write.guide("Open Tasks", %{page: "/tasks", dismissible: true})
      EvoGit.Agent.Tools.ElixirEval.Write.cancel_task("task_id")
    Read/write run in Dune: pure Elixir plus explicitly admitted real APIs and
    optional Read/Write facades, not arbitrary public runtime APIs.
    Write and sudo require manual approval of the EXACT submitted code every call.
    Sudo is UNSANDBOXED full VM Code evaluation: dangerous, not a sandbox escape retry.
    Fresh bindings every call; no persistent REPL state and no automatic escalation.
    Code: <=16000 UTF-8 bytes. Timeout: positive integer ms, default 2000, cap 5000.
    Output: positive integer bytes, default 16384, clamped to 256..65536 (errors too).
    Sudo limits are best effort; timeouts or later cancellation cannot roll back effects.
    Source inspection remains in the separate read, glob and rg tools.
    """ <> "\n" <> DirectAPI.help()
  end

  @doc "Executes one authorized evaluation and always returns bounded tool prose."
  def execute(args, _repo_path, _repo_root) do
    output_cap = output_cap(args)
    args |> safe_execute() |> render_result() |> cap_output(output_cap)
  end

  # Central tool boundary: authorization, approval and evaluation touch live runtime
  # services and user code. Do not expose exception messages, exit terms or stacktraces
  # (which can contain credentials) to the model.
  defp safe_execute(args) do
    with {:ok, code, tier, target, limits} <- validate_args(args),
         {:ok, context} <- authorize(target),
         :ok <- Authorization.revalidate(context),
         :ok <- approve(code, tier, context),
         :ok <- Authorization.revalidate(context) do
      result = Engine.run(code, tier, context, limits)

      # Revalidate even an engine failure: stale/cancelling authority must not return
      # runtime data captured before the lifecycle changed.
      with :ok <- Authorization.revalidate(context), do: result
    end
  rescue
    _ -> {:error, "Elixir evaluation failed; internal error details are withheld."}
  catch
    _kind, _reason ->
      {:error, "Elixir evaluation interrupted; internal error details are withheld."}
  end

  defp approve(_code, :read, _context), do: :ok

  defp approve(code, tier, context) when tier in [:write, :sudo] do
    case EvoGit.CommandApproval.request_eval(
           code,
           tier,
           context.target_node,
           context.agent_id,
           context.task_id
         ) do
      :approved -> :ok
      :denied -> {:error, "Elixir evaluation denied by the user; code was not executed."}
      :timeout -> {:error, "Elixir evaluation approval timed out; code was not executed."}
      _ -> {:error, "Elixir evaluation approval unavailable; code was not executed."}
    end
  end

  defp validate_args(args) when is_map(args) do
    with {:ok, code} <- validate_code(Map.get(args, "code")),
         {:ok, tier} <- validate_tier(Map.get(args, "tier", "read")),
         {:ok, target} <- validate_target(args),
         {:ok, timeout} <- positive_integer(args, "timeout_ms", @default_timeout_ms),
         {:ok, output} <- positive_integer(args, "max_output_bytes", @default_output_bytes) do
      {:ok, code, tier, target,
       %{
         timeout_ms: min(timeout, @max_timeout_ms),
         max_output_bytes: clamp_output(output)
       }}
    end
  end

  defp validate_args(_), do: {:error, "elixir_eval arguments must be an object."}

  defp validate_code(code) when is_binary(code) do
    cond do
      byte_size(code) > @max_code_bytes -> {:error, "code exceeds the 16000-byte limit."}
      not String.valid?(code) -> {:error, "code must be valid UTF-8."}
      String.trim(code) == "" -> {:error, "code must be a nonblank string."}
      true -> {:ok, code}
    end
  end

  defp validate_code(_), do: {:error, "code is required and must be a string."}

  defp validate_tier("read"), do: {:ok, :read}
  defp validate_tier("write"), do: {:ok, :write}
  defp validate_tier("sudo"), do: {:ok, :sudo}
  defp validate_tier(_), do: {:error, "tier must be read, write or sudo."}

  defp validate_target(args) do
    case Map.fetch(args, "target_node") do
      :error ->
        {:ok, nil}

      {:ok, target} when is_binary(target) ->
        if target in ["current", "local", Atom.to_string(node())],
          do: {:ok, target},
          else:
            {:error,
             "target_node must name the current/local node; remote evaluation is disabled."}

      _ ->
        {:error, "target_node must be a string naming the current/local node."}
    end
  end

  defp positive_integer(args, key, default) do
    case Map.get(args, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, "#{key} must be a positive integer."}
    end
  end

  defp output_cap(args) when is_map(args) do
    case positive_integer(args, "max_output_bytes", @default_output_bytes) do
      {:ok, n} -> clamp_output(n)
      {:error, _} -> @default_output_bytes
    end
  end

  defp output_cap(_), do: @default_output_bytes
  defp clamp_output(n), do: n |> max(@min_output_bytes) |> min(@max_output_bytes)

  defp render_result({:ok, output}) when is_binary(output), do: output
  defp render_result({:error, message}) when is_binary(message), do: Failure.error(message)
  defp render_result(_), do: Failure.error("Elixir evaluation returned an invalid result.")

  defp cap_output(output, cap) do
    {output, _warning} = EvoGit.UTF8.ensure_utf8(output)

    if byte_size(output) <= cap do
      output
    else
      String.byte_slice(output, 0, cap - byte_size(@truncation_marker)) <> @truncation_marker
    end
  end
end
