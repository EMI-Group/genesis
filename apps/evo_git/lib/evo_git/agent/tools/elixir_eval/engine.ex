defmodule EvoGit.Agent.Tools.ElixirEval.Engine do
  @moduledoc """
  Fresh, bounded evaluation behind the tool's authorization/approval boundary.

  `run/4` accepts already validated timeout/output limits and an opaque authority
  context for Broker; it does not query scheduler/configuration secrets itself.
  The caller must revalidate lifecycle before and after calling this engine.

  Read/write use Dune 0.3.18's safe string parser and interpreter. IO.puts/inspect
  are redirected to the bounded broker; unqualified dbg is rejected in a safe
  parser preflight because Dune's sanitizer otherwise emits raw IO bypassing its
  allowlist. Dune's internal diagnostic StringIO remains, but evaluated user IO
  cannot reach it. Compiler/parser diagnostics are bounded indirectly by the code,
  heap and execution budgets, not by a patched upstream StringIO implementation.

  Sudo is approved native Code.eval_string with fresh bindings, NOT a security
  sandbox: it can intentionally read secrets, mutate the VM, spawn OS children or
  interfere with tracing. Its normal BEAM descendants are reaped, but no in-VM
  engine can contain actively hostile native code with full VM authority.
  """
  alias EvoGit.Agent.Tools.ElixirEval.{
    BoundedIO,
    Broker,
    ReadAllowlist,
    Render,
    WorkerTree,
    WriteAllowlist
  }

  @max_code_bytes 16_384
  @dune_heap_words 1_000_000
  @dune_reductions 5_000_000

  def max_code_bytes, do: @max_code_bytes

  @spec run(binary(), :read | :write | :sudo, map(), map()) ::
          {:ok, binary()} | {:error, binary()}
  def run(code, tier, context, limits)
      when is_binary(code) and tier in [:read, :write, :sudo] and is_map(context) and
             is_map(limits) do
    cond do
      byte_size(code) > @max_code_bytes ->
        {:error,
         Render.text(
           "Code exceeds the #{@max_code_bytes}-byte evaluation limit.",
           limits.max_output_bytes
         )}

      not String.valid?(code) ->
        {:error, Render.text("Code must be valid UTF-8.", limits.max_output_bytes)}

      true ->
        # The broker has no separate limits argument; carry only this non-secret
        # capture cap alongside the caller's authority context.
        context = Map.put(context, :max_output_bytes, limits.max_output_bytes)

        {status, text} =
          WorkerTree.run(context, tier, limits, fn _broker -> evaluate(code, tier, limits) end)

        {status, Render.text(text, limits.max_output_bytes)}
    end
  end

  defp evaluate(code, tier, limits) do
    {:ok, io} = BoundedIO.start(limits.max_output_bytes)
    Process.group_leader(self(), io)

    try do
      result =
        case tier do
          :sudo ->
            # Deliberately unrestricted, only after the top-level approval gate.
            {value, _bindings} = Code.eval_string(code, [])
            {:ok, "Result: " <> Render.term(value, limits.max_output_bytes)}

          tier ->
            dune(code, tier, limits)
        end

      case BoundedIO.output(io) do
        {:ok, ""} ->
          result

        {:ok, output} ->
          case Broker.call(:stdio, [output]) do
            :ok -> result
            {:ok, _} -> result
            _ -> {:error, "Captured output limit exceeded."}
          end

        {:error, _} ->
          {:error, "Captured output unavailable."}
      end
    after
      BoundedIO.stop(io)
    end
  end

  defp dune(code, tier, limits) do
    opts = [
      allowlist: if(tier == :read, do: ReadAllowlist, else: WriteAllowlist),
      max_length: @max_code_bytes,
      atom_pool_size: 1_000,
      max_heap_size: @dune_heap_words,
      max_reductions: @dune_reductions,
      timeout: limits.timeout_ms,
      parse_timeout: limits.timeout_ms
    ]

    # Never feed untrusted source to normal Code.string_to_quoted. Dune's safe
    # parser prevents atom leakage, including on this preflight-only pass.
    case Dune.string_to_quoted(code, opts) do
      %Dune.Success{value: ast} ->
        if contains_dbg?(ast) do
          {:error, "dbg is unavailable; use IO.inspect instead."}
        else
          case Dune.eval_string(code, opts) do
            %Dune.Success{inspected: inspected} ->
              {:ok, Render.text("Result: " <> inspected, limits.max_output_bytes)}

            %Dune.Failure{} = failure ->
              failure(failure, limits.max_output_bytes)
          end
        end

      %Dune.Failure{} = failure ->
        failure(failure, limits.max_output_bytes)
    end
  end

  defp contains_dbg?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:dbg, _, _} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  # Do not render Dune's raw message/stdio: exception terms and diagnostics can
  # include sensitive values returned by trusted native facades.
  defp failure(%Dune.Failure{type: type}, cap) do
    text =
      case type do
        :restricted ->
          "Evaluation rejected a restricted operation. Use admitted APIs such as EvoGit.TaskRegistry.list_tasks_page/0,1 or EvoGit.AgentScheduler.get_config/1; Read/Write facade APIs remain available. Call EvoGit.Agent.Tools.ElixirEval.Read.help() for exact MFAs and limits. Writes require the write tier and exact-code approval; no automatic escalation."

        :parsing ->
          "Evaluation could not parse the code."

        :timeout ->
          "Evaluation timed out."

        :memory ->
          "Evaluation memory limit exceeded."

        :reductions ->
          "Evaluation reductions limit exceeded."

        :stdio ->
          "Captured output limit exceeded."

        _ ->
          "Evaluation failed (invalid code or runtime exception)."
      end

    {:error, Render.text(text, cap)}
  end
end
