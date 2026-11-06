Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.EngineTest do
  @moduledoc """
  Real-Dune engine contracts, with genuine live SelfReflective authority.

  Async-safe: each test owns its Store/TaskRegistry, owner/tool Tasks, config
  directory and uniquely keyed scheduler rows; no global configuration changes.
  Direct Engine write/sudo calls model an already-approved tier. They deliberately
  do NOT establish that the public wrapper requests or enforces approval.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.Store
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @limits %{timeout_ms: 5_000, max_output_bytes: 16_384}
  @read "EvoGit.Agent.Tools.ElixirEval.Read"
  @write "EvoGit.Agent.Tools.ElixirEval.Write"
  @restricted "Evaluation rejected a restricted operation. Use admitted APIs such as EvoGit.TaskRegistry.list_tasks_page/0,1 or EvoGit.AgentScheduler.get_config/1; Read/Write facade APIs remain available. Call EvoGit.Agent.Tools.ElixirEval.Read.help() for exact MFAs and limits. Writes require the write tier and exact-code approval; no automatic escalation."

  setup_all do
    # Denial must concern real native modules, not an unavailable alias. Besides
    # loading the modules, these literal aliases intern their name segments for
    # Dune's existing-atom parser on a cold BEAM (without changing its allowlist).
    Code.ensure_loaded!(EvoGit.Agent.Tools.ElixirEval.Broker)
    Code.ensure_loaded!(EvoGit.CommandShell)
    :ok
  end

  setup %{store: store, registry: registry} do
    EvoGit.TestSupport.ConfigDir.isolate!("eval_engine")
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  describe "real interpreted facade discovery" do
    test "nested interpreted callbacks find the broker through Dune's own helpers", ctx do
      code = """
      Enum.map([1, 2], fn _ ->
        info = #{@read}.system_info()
        {info.elixir, info.otp, is_integer(info.schedulers) and info.schedulers > 0}
      end) |> Enum.uniq()
      """

      # Do not preload the facade/allowlist or warm up evaluation here: the
      # first user expression must discover this capability on a cold BEAM too.
      expected = inspect([{System.version(), System.otp_release(), true}])
      assert evaluate(ctx.fixture, code) == {:ok, "Result: " <> expected}
    end

    test "help is callable inside Dune and describes fully qualified facades", ctx do
      code = """
      contract = #{@read}.help()
      String.contains?(contract, "#{@read}") and
        String.contains?(contract, "#{@write}") and
        String.contains?(contract, "get_task/1")
      """

      assert evaluate(ctx.fixture, code) == {:ok, "Result: true"}
    end

    test "task reads use the captured isolated registry and omit private fields", ctx do
      secret = "private-objective-#{ctx.fixture.agent_id}"

      Fixture.update_task(
        ctx.fixture,
        &%{&1 | opts: [objective: secret], error: %{reason: secret}}
      )

      code = """
      task = #{@read}.get_task(#{inspect(ctx.fixture.task_id)})
      task.id == #{inspect(ctx.fixture.task_id)} and task.type == :reflect and
        task.status == :running and
        Enum.sort(Map.keys(task)) ==
          Enum.sort([:id, :type, :status, :review_status, :started_at,
                     :finished_at, :updated_at, :agent_count])
      """

      assert evaluate(ctx.fixture, code) == {:ok, "Result: true"}

      assert {:ok, output} =
               evaluate(ctx.fixture, "#{@read}.get_task(#{inspect(ctx.fixture.task_id)})")

      refute output =~ secret
      refute output =~ "objective"
      refute output =~ "error:"
    end

    test "interpreted page options reach the registry, rather than global task state", ctx do
      pending = seed_task(ctx, :pending)
      _completed = seed_task(ctx, :completed)

      code = """
      page = #{@read}.list_tasks(%{limit: 1, offset: 0, status: "pending"})
      {page.total, page.limit, page.offset,
       Enum.map(page.rows, fn row -> row.id end) == [#{inspect(pending.id)}]}
      """

      assert evaluate(ctx.fixture, code) == {:ok, "Result: {1, 1, 0, true}"}

      assert evaluate(ctx.fixture, "#{@read}.get_task(\"unknown_eval_task\")") ==
               {:ok, "Result: nil"}
    end
  end

  describe "read/write separation (Engine only, not approval integration)" do
    test "read cannot cancel a task; an already-approved write tier can", ctx do
      target = seed_task(ctx, :pending)
      code = "#{@write}.cancel_task(#{inspect(target.id)})"

      assert evaluate(ctx.fixture, code, :read) == {:error, @restricted}
      assert Store.get_task(ctx.store, target.id).status == :pending

      assert {:ok, output} = evaluate(ctx.fixture, code, :write)
      assert output =~ "status: :requested"
      assert output =~ target.id
      assert Store.get_task(ctx.store, target.id).status == :cancelled
    end

    test "write retains Read access but cannot mutate its own authority task", ctx do
      code = """
      current = #{@read}.get_task(#{inspect(ctx.fixture.task_id)})
      action = #{@write}.cancel_task(current.id)
      {current.status, action}
      """

      assert {:ok, output} = evaluate(ctx.fixture, code, :write)
      assert output =~ ":running"
      assert output =~ "Task action requires a different, existing task in an allowed state."
      assert Store.get_task(ctx.store, ctx.fixture.task_id).status == :running
    end
  end

  # Each case really enters Dune, under BOTH interpreted tiers. A higher tier
  # granting Write must not accidentally grant native/runtime access as well.
  for {label, code} <- [
        {"environment", ~s|System.get_env("HOME")|},
        {"filesystem", ~s|File.read!("mix.exs")|},
        {"process dictionary read", "Process.get(:evogit_eval_broker)"},
        {"process dictionary write", "Process.put(:evogit_eval_broker, nil)"},
        {"raw process dictionary", ":erlang.get()"},
        {"native process inspection", "Process.info(self(), :dictionary)"},
        {"native evaluator", ~s|Code.eval_string("1 + 2")|},
        {"native AST evaluation", "Code.eval_quoted({:+, [], [1, 2]})"},
        {"task registry wrong arity", "EvoGit.TaskRegistry.get_task()"},
        {"scheduler internals", "EvoGit.AgentScheduler.get_config()"},
        {"ETS internals", ":ets.tab2list(:evogit_agent_state)"},
        {"broker operation", "EvoGit.Agent.Tools.ElixirEval.Broker.call(:system_info, [])"},
        {"broker creation", "EvoGit.Agent.Tools.ElixirEval.Broker.start(%{}, :sudo)"},
        {"command shell", ~s|EvoGit.CommandShell.execute("help", approval: :auto)|},
        {"dynamic native apply", "apply(System, :get_env, [])"}
      ] do
    test "sandbox rejects #{label} in read AND write", ctx do
      for tier <- [:read, :write] do
        assert evaluate(ctx.fixture, unquote(code), tier) == {:error, @restricted}
      end
    end
  end

  describe "confidential failures and debug rejection" do
    test "filesystem writes are denied without executing them, including write tier", ctx do
      path = Path.join(ctx.data_dir, "must-not-be-written")
      code = "File.write!(#{inspect(path)}, \"not allowed\")"

      for tier <- [:read, :write] do
        assert evaluate(ctx.fixture, code, tier) == {:error, @restricted}
        refute File.exists?(path)
      end
    end

    test "dbg is refused before sanitizer debug IO can print its argument", ctx do
      secret = "debug-secret-#{ctx.fixture.agent_id}"

      for tier <- [:read, :write], expression <- ["dbg", "Kernel.dbg"] do
        assert {:error, output} = evaluate(ctx.fixture, "#{expression}(#{inspect(secret)})", tier)
        refute output =~ secret
        assert output =~ "dbg is unavailable" or output == @restricted
      end
    end

    test "runtime exceptions, throws and exits never echo their secret terms", ctx do
      secret = "exception-secret-#{ctx.fixture.agent_id}"

      for tier <- [:read, :write, :sudo],
          code <- [
            "raise #{inspect(secret)}",
            "throw(#{inspect(secret)})",
            "exit(#{inspect(secret)})"
          ] do
        assert {:error, output} = evaluate(ctx.fixture, code, tier)
        assert output =~ "Evaluation"
        refute output =~ secret
        refute output =~ "RuntimeError"
        refute output =~ "stacktrace"
        assert String.valid?(output)
      end
    end

    test "parse diagnostics do not echo source literals", ctx do
      secret = "parser-secret-#{ctx.fixture.agent_id}"
      code = "[#{inspect(secret)}"

      assert evaluate(ctx.fixture, code) == {:error, "Evaluation could not parse the code."}
    end
  end

  describe "native sudo is deliberately not a sandbox (direct Engine only)" do
    test "native filesystem access is sudo-only, not evidence of manual approval", ctx do
      path = Path.join(ctx.data_dir, "native-sudo-proof")
      contents = "fixture-local native write"
      code = "File.write!(#{inspect(path)}, #{inspect(contents)}); File.read!(#{inspect(path)})"

      assert evaluate(ctx.fixture, code, :read) == {:error, @restricted}
      assert evaluate(ctx.fixture, code, :write) == {:error, @restricted}
      refute File.exists?(path)

      assert evaluate(ctx.fixture, code, :sudo) == {:ok, "Result: " <> inspect(contents)}
      assert File.read!(path) == contents
    end

    test "deliberately returned or printed native secrets are NOT redacted", ctx do
      secret = "intentional-sudo-output-#{ctx.fixture.agent_id}"
      path = Path.join(ctx.data_dir, "sudo-secret")
      File.write!(path, secret)
      code = "value = File.read!(#{inspect(path)}); IO.puts(value); value"

      assert evaluate(ctx.fixture, code, :sudo) ==
               {:ok, secret <> "\nResult: " <> inspect(secret)}
    end
  end

  describe "fresh evaluation state" do
    test "bindings do not persist even across repeated runs in the SAME tool process", ctx do
      handle =
        Fixture.call_async(ctx.fixture, fn ->
          {:ok, authority} = Authorization.authorize()

          for tier <- [:read, :write, :sudo] do
            first = Engine.run("private_binding = 42; private_binding", tier, authority, @limits)
            # Native undefined-variable compilation writes a diagnostic directly
            # to stderr. Inspect its fresh binding list instead; Dune reports the
            # undefined variable through its normal failure boundary.
            probe = if tier == :sudo, do: "binding()", else: "private_binding"
            second = Engine.run(probe, tier, authority, @limits)
            third = Engine.run("6 * 7", tier, authority, @limits)
            {tier, first, second, third}
          end
        end)

      results = Fixture.await(handle)
      assert length(results) == 3

      for {tier, first, second, third} <- results do
        assert first == {:ok, "Result: 42"}

        if tier == :sudo do
          assert second == {:ok, "Result: []"}
        else
          assert {:error, _} = second
        end

        assert third == {:ok, "Result: 42"}
      end
    end
  end

  describe "cumulative byte budgets and bounded inspection" do
    test "small stdout and result are combined in order in every tier", ctx do
      for tier <- [:read, :write, :sudo] do
        assert evaluate(ctx.fixture, ~s|IO.puts("hello"); IO.inspect([1, 2]); :done|, tier) ==
                 {:ok, "hello\n[1, 2]\nResult: :done"}
      end
    end

    test "stdout exactly fitting its budget leaves no room for result text", ctx do
      # 3-byte characters plus newline = 256 BYTES, not 86 characters.
      line = String.duplicate("界", 85)
      code = "IO.puts(#{inspect(line)}); :done"

      for tier <- [:read, :write, :sudo] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{max_output_bytes: 256})
        assert_bounded(output, 256)
        assert output =~ "[output truncated]"
        assert String.starts_with?(output, "界界")
        refute output =~ "Result: :done"
      end
    end

    test "multiple individually small prints cannot exceed the cumulative cap", ctx do
      code = "Enum.each(1..20, fn _ -> IO.puts(#{inspect(String.duplicate("界", 12))}) end)"

      # The broker truncates to the remaining budget instead of failing: six full
      # 37-byte lines (222 bytes) plus the five whole "界" codepoints (15 bytes)
      # that still fit exhaust the 256-byte cap, so the evaluation still succeeds
      # and the final cap replaces the Result text with the marker.
      expected =
        String.duplicate(String.duplicate("界", 12) <> "\n", 6) <>
          String.duplicate("界", 5) <> "\n[output truncated]"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{max_output_bytes: 256})
        assert_bounded(output, 256)
        assert byte_size(output) == 256
        assert String.starts_with?(output, String.duplicate("界", 12) <> "\n")
        assert String.ends_with?(output, "\n[output truncated]")
        # Interpreted stdout filled the whole budget, so nothing else survived.
        refute output =~ "Result:"
        assert output == expected
      end

      # Native IO raises on enospc before Engine can transfer its group-leader
      # buffer to the broker. Its fixed failure is bounded too, but does not
      # promise preservation of previously written native stdout on failure.
      assert evaluate(ctx.fixture, code, :sudo, %{max_output_bytes: 256}) ==
               {:error, "Evaluation raised an exception."}
    end

    test "large return values are byte-capped without splitting UTF-8", ctx do
      for tier <- [:read, :write, :sudo] do
        assert {:ok, output} =
                 evaluate(ctx.fixture, ~s|String.duplicate("界", 1000)|, tier, %{
                   max_output_bytes: 257
                 })

        assert_bounded(output, 257)
        assert String.starts_with?(output, "Result: \"界")
        assert output =~ "[output truncated]"
      end
    end

    test "return-value inspection is bounded even when the output budget has spare room", ctx do
      for tier <- [:read, :write, :sudo] do
        assert {:ok, output} = evaluate(ctx.fixture, "Enum.to_list(1..1000)", tier)
        assert String.starts_with?(output, "Result: [1, 2, 3")
        assert output =~ "..."
        refute output =~ "999"
        refute output =~ "1000"
        assert byte_size(output) < 2_048
      end
    end

    test "IO.inspect cannot request infinite list inspection", ctx do
      code =
        "IO.inspect(Enum.to_list(1..1000), limit: :infinity, printable_limit: :infinity); :done"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier)
        assert output =~ "..."
        refute output =~ "999"
        refute output =~ "1000"
        assert String.ends_with?(output, "Result: :done")
        assert byte_size(output) < 2_048
      end
    end

    test "IO.inspect bounds binary inspection and label length despite infinity options", ctx do
      code = """
      IO.inspect(String.duplicate("x", 4000) <> "HIDDEN_TAIL",
        printable_limit: :infinity, limit: :infinity, label: String.duplicate("L", 1000))
      :done
      """

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier)
        refute output =~ "HIDDEN_TAIL"
        refute output =~ String.duplicate("L", 257)
        assert output =~ "..."
        assert byte_size(output) < 3_000
        assert String.ends_with?(output, "Result: :done")
      end
    end

    test "IO device arguments cannot bypass stdout capture", ctx do
      for code <- [~s|IO.puts(:stderr, "not printed")|, ~s|IO.inspect(:stderr, [1, 2], [])|],
          tier <- [:read, :write] do
        assert evaluate(ctx.fixture, code, tier) == {:error, @restricted}
      end
    end
  end

  describe "engine code validation independent of wrapper" do
    test "oversized or invalid UTF-8 code fails with a bounded error", ctx do
      assert Engine.max_code_bytes() == 16_384

      assert evaluate(ctx.fixture, String.duplicate(" ", Engine.max_code_bytes() + 1)) ==
               {:error, "Code exceeds the 16384-byte evaluation limit."}

      for tier <- [:read, :write, :sudo] do
        assert evaluate(ctx.fixture, <<255>>, tier) == {:error, "Code must be valid UTF-8."}
      end

      # The ceiling is inclusive; this remains valid code at exactly the cap.
      code = "42" <> String.duplicate(" ", Engine.max_code_bytes() - 2)
      assert evaluate(ctx.fixture, code) == {:ok, "Result: 42"}
    end
  end

  defp evaluate(fixture, code, tier \\ :read, overrides \\ %{}) do
    limits = Map.merge(@limits, overrides)

    fixture
    |> Fixture.call_async(fn ->
      {:ok, authority} = Authorization.authorize()
      Engine.run(code, tier, authority, limits)
    end)
    |> Fixture.await()
  end

  defp seed_task(ctx, status) do
    task = %EvoGit.TaskInfo{
      id: "engine_target_#{System.unique_integer([:positive])}",
      type: :reflect,
      status: status,
      opts: [mode: "reflect", objective: "Engine test target"],
      started_at: DateTime.utc_now()
    }

    :ok = Store.put_task(ctx.store, task)
    task
  end

  defp assert_bounded(output, cap) do
    assert is_binary(output)
    assert String.valid?(output)
    assert byte_size(output) <= cap
  end
end
