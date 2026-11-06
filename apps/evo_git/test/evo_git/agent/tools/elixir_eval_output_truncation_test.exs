Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.OutputTruncationTest do
  @moduledoc """
  Real-Dune integration coverage for the evaluator's stdout-truncation contract.

  The broker is the single enforcement point for the captured-stdout budget:
  an item larger than the remaining budget is truncated to it (longest valid
  UTF-8 prefix plus the marker, inside the cap), a write with no budget left is
  a bounded no-op, and the evaluation continues normally. Only expired
  authority or a malformed item fails; output volume never does.

  Async-safe: each test owns its Store/TaskRegistry, config directory and
  uniquely keyed scheduler rows, and no global configuration is changed.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @limits %{timeout_ms: 5_000, max_output_bytes: 16_384}
  @marker "\n[output truncated]"
  # Render.text/2 keeps its 19-byte marker inside the cap, so a truncated item
  # ends up as `cap - marker` payload bytes plus the marker.
  @marker_bytes byte_size("\n[output truncated]")

  setup %{store: store, registry: registry} do
    EvoGit.TestSupport.ConfigDir.isolate!("eval_output_truncation")
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  describe "oversized stdout is truncated, never fatal" do
    test "single print far over the default cap still succeeds", ctx do
      code = "IO.puts(String.duplicate(\"a\", 20_000)); :ok"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{})

        assert String.valid?(output)
        assert byte_size(output) == 16_384
        assert String.ends_with?(output, @marker)

        # stdout consumed the whole budget, so only 'a' payload survives.
        body = binary_part(output, 0, byte_size(output) - @marker_bytes)
        assert body == String.duplicate("a", 16_384 - @marker_bytes)

        refute output =~ "Result:"
        # This is THE reported regression: an overflow must not fail the run.
        refute output =~ "Captured output limit exceeded"
      end
    end

    test "a small cap truncates an oversized print exactly to the cap", ctx do
      code = "IO.puts(String.duplicate(\"a\", 300)); :ok"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{max_output_bytes: 256})

        assert String.valid?(output)
        assert byte_size(output) == 256
        assert String.starts_with?(output, String.duplicate("a", 237))
        assert String.ends_with?(output, @marker)
        assert binary_part(output, 0, 256 - @marker_bytes) == String.duplicate("a", 237)
        refute output =~ "Result:"
      end
    end

    test "stdout that overflows after producing output keeps a bounded result", ctx do
      code = "IO.puts(\"start\"); IO.puts(String.duplicate(\"b\", 400)); :done"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{max_output_bytes: 256})

        assert String.valid?(output)
        assert byte_size(output) <= 256
        assert String.starts_with?(output, "start\n")
        assert String.ends_with?(output, @marker)
        # 6 bytes of "start\n" plus the 'b' payload that still fit.
        assert output == "start\n" <> String.duplicate("b", 237 - 6) <> @marker
        refute output =~ "Result:"
        refute output =~ "Captured output limit exceeded"
      end
    end
  end

  describe "per-item render cap and untruncated baselines" do
    test "a small print under the cap keeps its result text verbatim", ctx do
      code = "IO.puts(String.duplicate(\"a\", 100)); :ok"

      for tier <- [:read, :write] do
        assert evaluate(ctx.fixture, code, tier, %{max_output_bytes: 256}) ==
                 {:ok, String.duplicate("a", 100) <> "\nResult: :ok"}
      end
    end

    test "per-item render cap truncates the item but the run still finishes", ctx do
      code = "IO.puts(String.duplicate(\"a\", 20_000)); :ok"

      for tier <- [:read, :write] do
        assert {:ok, output} = evaluate(ctx.fixture, code, tier, %{max_output_bytes: 65_536})

        assert String.valid?(output)
        assert byte_size(output) <= 65_536
        # IOShim rendered at most 16_384 bytes per call; the normal Result text
        # after it proves per-item truncation never fails the evaluation.
        assert String.ends_with?(output, @marker <> "\nResult: :ok")

        assert output ==
                 String.duplicate("a", 16_384 - @marker_bytes) <> @marker <> "\nResult: :ok"
      end
    end

    test "an item exactly filling the per-item cap is not truncated at a wide budget", ctx do
      code = "IO.puts(String.duplicate(\"a\", 16_383)); :ok"

      for tier <- [:read, :write] do
        assert evaluate(ctx.fixture, code, tier, %{max_output_bytes: 65_536}) ==
                 {:ok, String.duplicate("a", 16_383) <> "\nResult: :ok"}
      end
    end
  end

  defp evaluate(fixture, code, tier, overrides) do
    limits = Map.merge(@limits, overrides)

    fixture
    |> Fixture.call_async(fn ->
      {:ok, authority} = Authorization.authorize()
      Engine.run(code, tier, authority, limits)
    end)
    |> Fixture.await()
  end
end
