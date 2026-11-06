defmodule EvoGit.Agent.Tools.ElixirEval do
  @moduledoc """
  Assistant-only Elixir evaluation boundary with explicit read, write and sudo tiers.

  Authorization comes from the owning agent, not the fresh tool process's role
  dictionary. The engine supplies fresh bindings on every call; this wrapper never
  evaluates code to infer its tier and never escalates a refused evaluation.
  """

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
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
        "Evaluate Elixir with fresh bindings. Read (default) and write use Dune and only " <>
          "the documented Read/Write facades, never direct runtime APIs. Write requires " <>
          "manual approval of the exact code. Sudo is dangerous, UNSANDBOXED full VM " <>
          "Code evaluation, available only AFTER manual approval. Never auto-escalate. " <>
          "Timeout/output caps are best effort for sudo; side effects cannot be rolled back. " <>
          "Use the separate read/glob/rg tools for source inspection.\n\n" <> help(),
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
    Read = EvoGit.Agent.Tools.ElixirEval.Read:
      help, system_info, list_tasks, get_task, list_agents, scheduler_status, model_profiles.
    Write = EvoGit.Agent.Tools.ElixirEval.Write:
      start_task, cancel_task, force_kill_task, delete_task, guide.
    Use these fully qualified modules, or Elixir aliases Read and Write for them.
    Read.help() documents facade signatures; there is no source-access facade.
    Examples (read tier):
      EvoGit.Agent.Tools.ElixirEval.Read.help()
      EvoGit.Agent.Tools.ElixirEval.Read.list_tasks()
      alias EvoGit.Agent.Tools.ElixirEval.Read
      Read.system_info()
    Example (write tier, requires approval):
      EvoGit.Agent.Tools.ElixirEval.Write.cancel_task("task_id")
    Read/write run in Dune: pure Elixir plus the explicit facades only, not direct
    TaskRegistry, AgentScheduler, CommandShell, Tools.execute or other runtime APIs.
    Write and sudo require manual approval of the EXACT submitted code every call.
    Sudo is UNSANDBOXED full VM Code evaluation: dangerous, not a sandbox escape retry.
    Fresh bindings every call; no persistent REPL state and no automatic escalation.
    Code: <=16000 UTF-8 bytes. Timeout: positive integer ms, default 2000, cap 5000.
    Output: positive integer bytes, default 16384, clamped to 256..65536 (errors too).
    Sudo limits are best effort; timeouts or later cancellation cannot roll back effects.
    Source inspection remains in the separate read, glob and rg tools.
    """
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
