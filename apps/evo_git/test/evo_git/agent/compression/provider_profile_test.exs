defmodule EvoGit.Agent.Compression.ProviderProfileTest do
  @moduledoc """
  Canonical account/model selection feeds configured compression windows and
  catalog output reservations without conflating account ids with ReqLLM models.

  `async: false` because the metadata observer replaces the BEAM-global
  `:llm_model_metadata_fun`, also read by generation-parameter assembly and
  scheduler consumers. Config and credential files are isolated per process;
  no scheduler state, environment variables, timers or network are involved.
  Generation params may contain credentials: assert individual public fields,
  never print or log the resolved params/profile wholesale.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Agent.Compression.{Checkpoint, Recency, Threshold}
  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.LLM

  @metadata_seam :llm_model_metadata_fun
  @endpoint "https://compression.invalid/v1"

  setup do
    previous = Application.fetch_env(:evo_git, @metadata_seam)
    owner = self()
    ref = make_ref()

    Application.put_env(:evo_git, @metadata_seam, fn model ->
      send(owner, {ref, model})

      output =
        case model do
          "openai:small" -> 8_192
          %{provider: :openai, id: "small", base_url: @endpoint} -> 8_192
          %{provider: :openai, id: "wide", base_url: @endpoint} -> 16_384
          %{provider: :openai, id: "compact", base_url: @endpoint} -> 4_096
          _ -> nil
        end

      if output do
        # Deliberately contradict every configured window: only output may be used.
        %{
          limits: %{context: 9_000_000, output: output},
          capabilities: %{reasoning: %{enabled: true}}
        }
      end
    end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:evo_git, @metadata_seam, value)
        :error -> Application.delete_env(:evo_git, @metadata_seam)
      end
    end)

    EvoGit.TestSupport.ConfigDir.isolate!("compression-provider-profile")
    dir = EvoGit.Config.config_dir()
    File.mkdir_p!(dir)
    %{config_dir: dir, metadata_ref: ref}
  end

  describe "canonical selection to compression inputs" do
    test "the configured default account/model wins over both inventory order and stale legacy profiles",
         %{metadata_ref: ref} do
      config = config()

      for spec <- [nil, "work"] do
        resolved = resolve!(config, spec)
        assert resolved.provider_profile_id == "work"
        assert resolved.model == "small"
        assert resolved.model_spec == model_spec("small")
        assert resolved.reasoning_effort == "high"
        assert Keyword.fetch!(resolved.generation_params, :reasoning_effort) == :high
        assert LLM.context_window_for(config, "work") == 131_072

        assert_threshold(resolved, ref, 131_072, 57_344, 57_344, 26_214)
      end
    end

    test "nested model generation and window overrides win while other account defaults survive",
         %{metadata_ref: ref} do
      resolved = resolve!(config(), %{provider_profile_id: "work", model: "openai:wide"})

      assert resolved.model == "wide"
      assert resolved.model_spec == model_spec("wide")
      assert resolved.runtime_profile.context_window == 300_000
      assert resolved.reasoning_effort == "low"
      assert resolved.reasoning_efforts == ["low", "high"]
      assert Keyword.fetch!(resolved.generation_params, :reasoning_effort) == :low
      assert Keyword.fetch!(resolved.generation_params, :temperature) == 0.6
      assert Keyword.fetch!(resolved.generation_params, :max_tokens) == 4_096
      assert Keyword.fetch!(resolved.generation_params, :top_p) == 0.9
      refute Keyword.has_key?(resolved.generation_params, :context_window)

      # Reservation is the selected model's catalog OUTPUT (16_384), not its
      # requested max_tokens (4_096), the account id or the default small model.
      assert_threshold(resolved, ref, 300_000, 218_080, 150_000, 40_000)
    end

    test "models and efforts share account scheduling but keep their own compression windows",
         %{metadata_ref: ref} do
      small = resolve!(config(), "work")

      for effort <- ["low", "high"] do
        wide =
          resolve!(config(), %{
            provider_profile_id: "work",
            model: "wide",
            reasoning_effort: effort
          })

        assert wide.provider_profile_id == small.provider_profile_id
        assert wide.concurrency == small.concurrency
        assert wide.concurrency == 7
        assert wide.peak_concurrency == small.peak_concurrency
        assert wide.peak_concurrency == 0
        assert wide.peak_hours == small.peak_hours
        assert wide.timezone == small.timezone
        assert wide.off_peak_days == small.off_peak_days
        assert wide.reasoning_effort == effort

        assert Keyword.fetch!(wide.generation_params, :reasoning_effort) ==
                 LLM.convert_reasoning_effort(effort)

        assert_threshold(wide, ref, 300_000, 218_080, 150_000, 40_000)
      end

      # Resolving an alternate selection must not mutate the account default.
      default = resolve!(config(), "work")
      assert default.model == "small"
      assert default.reasoning_effort == "high"
      assert_threshold(default, ref, 131_072, 57_344, 57_344, 26_214)
    end

    test "nil nested overrides inherit account defaults rather than erase the compression window",
         %{metadata_ref: ref} do
      config =
        update_in(config(), [:llm, :providers], fn profiles ->
          Enum.map(profiles, fn
            %{id: "work"} = profile ->
              Map.put(profile, :models, [
                %{model: "small", context_window: nil, temperature: nil, max_tokens: nil}
              ])

            profile ->
              profile
          end)
        end)

      resolved = resolve!(config, "work")
      assert Keyword.fetch!(resolved.generation_params, :temperature) == 0.2
      assert Keyword.fetch!(resolved.generation_params, :max_tokens) == 2_048
      assert_threshold(resolved, ref, 131_072, 57_344, 57_344, 26_214)
    end

    test "reasoning is not invented, and an unsupported explicit effort cannot select a fallback model",
         %{metadata_ref: ref} do
      resolved = resolve!(config(), "other")
      assert resolved.reasoning_effort == nil
      refute Keyword.has_key?(resolved.generation_params, :reasoning_effort)
      assert_threshold(resolved, ref, 1_000_000, 800_000, 500_000, 40_000)

      assert Schema.resolve_model_spec(config(), %{
               provider_profile_id: "work",
               model: "wide",
               reasoning_effort: "xhigh"
             }) == {:error, {:unsupported_reasoning_effort, "xhigh", ["low", "high"]}}

      refute_received {^ref, _}
    end

    test "two accounts serving the same model do not borrow endpoint, defaults or window",
         %{metadata_ref: ref} do
      native = resolve!(config(), "other")
      custom = resolve!(config(), "work")

      assert native.model == custom.model
      assert native.model_spec == "openai:small"
      assert custom.model_spec == model_spec("small")
      assert native.concurrency == 2
      assert custom.concurrency == 7
      assert Keyword.fetch!(native.generation_params, :temperature) == 0.8
      assert Keyword.fetch!(custom.generation_params, :temperature) == 0.2
      assert Keyword.fetch!(native.generation_params, :provider_options)[:store] == false
      refute Keyword.has_key?(custom.generation_params, :provider_options)

      assert_threshold(native, ref, 1_000_000, 800_000, 500_000, 40_000)
      assert_threshold(custom, ref, 131_072, 57_344, 57_344, 26_214)
    end

    test "string-keyed persisted selections retain nested windows and reasoning choices",
         %{metadata_ref: ref} do
      # Exercise the persisted JSON key shape, not just in-memory atom maps.
      config = config() |> Jason.encode!() |> Jason.decode!()

      resolved =
        resolve!(config, %{
          "provider_profile_id" => "work",
          "model" => "compact",
          "reasoning_effort" => "low"
        })

      assert resolved.model_spec == model_spec("compact")
      assert resolved.reasoning_effort == "low"
      assert Keyword.fetch!(resolved.generation_params, :temperature) == 0.2
      assert Keyword.fetch!(resolved.generation_params, :max_tokens) == 2_048
      assert_threshold(resolved, ref, 64_000, 32_000, 32_000, 12_800)
    end

    test "absent account and model windows use the configured schema default, never catalog context",
         %{metadata_ref: ref} do
      config =
        update_in(config(), [:llm, :providers], fn profiles ->
          Enum.map(profiles, &Map.delete(&1, :context_window))
        end)

      resolved = resolve!(config, "work")
      assert resolved.context_window == LLM.default_context_window()
      assert_threshold(resolved, ref, 200_000, 126_272, 100_000, 40_000)
    end

    test "a present invalid nested window cannot silently inherit the larger account window",
         %{metadata_ref: ref} do
      config =
        update_in(config(), [:llm, :providers], fn profiles ->
          Enum.map(profiles, fn
            %{id: "work"} = profile ->
              update_in(profile, [:models], fn models ->
                Enum.map(models, &Map.put(&1, :context_window, 0))
              end)

            profile ->
              profile
          end)
        end)

      log =
        capture_log(fn ->
          resolved = resolve!(config, %{provider_profile_id: "work", model: "wide"})
          assert_threshold(resolved, ref, 200_000, 118_080, 100_000, 40_000)
        end)

      assert log =~ "Invalid LLM model profile context_window 0"
    end

    test "an explicit compression trigger preserves the selected model's window for both budgets",
         %{config_dir: dir, metadata_ref: ref} do
      File.write!(Path.join(dir, "config.toml"), "[llm]\ncompression_threshold_tokens = 45000\n")
      resolved = resolve!(config(), %{provider_profile_id: "work", model: "compact"})
      info = Threshold.for_model(resolved.model_spec, context_window: resolved.context_window)

      assert info == %{threshold: 45_000, window: 64_000, source: :config}
      assert Threshold.pruning_target(info, 0.5) == 32_000
      assert Recency.tail_budget(context_window: info.window) == 12_800
      refute Threshold.exceeded?(45_000, info)
      assert Threshold.exceeded?(45_001, info)
      # The explicit trigger short-circuits metadata, but selection itself did
      # resolve metadata using the ReqLLM identifier, not the task selection map.
      expected = model_spec("compact")
      assert_received {^ref, ^expected}
    end
  end

  test "checkpoint construction uses a selected nested window to bound an oversized recent exchange" do
    resolved = resolve!(config(), %{provider_profile_id: "work", model: "compact"})
    head = [ReqLLM.Context.system("SYSTEM"), ReqLLM.Context.user("OBJECTIVE")]

    turns =
      Enum.flat_map(1..6, fn turn ->
        call = ReqLLM.ToolCall.new("call_#{turn}", "read", "{}")

        [
          ReqLLM.Context.assistant("work", tool_calls: [call]),
          ReqLLM.Context.tool_result("call_#{turn}", "read", String.duplicate("x", 100_000))
        ]
        |> Enum.map(&ContextBuilder.tag_message_turn(&1, turn))
      end)

    result =
      Checkpoint.build(head ++ turns, "Keep the investigation results.",
        context_window: resolved.context_window
      )

    assert result.budget == 12_800
    assert result.replaced > 0
    assert result.shrunk
    assert Enum.take(result.messages, 2) == head
    assert Enum.count(result.messages, &Checkpoint.checkpoint?/1) == 1
    assert Checkpoint.prior_summary(result.messages) == "Keep the investigation results."

    tail = Enum.drop(result.messages, 3)
    assert result.kept == length(tail)
    assert tail != []
    assert Recency.estimate_tokens(tail) <= 12_800
    assert [%{role: :assistant, tool_calls: [call]}, %{role: :tool, tool_call_id: id}] = tail
    assert call.id == id
    assert id == "call_6"
    assert result.estimated_tokens < result.pre_estimate
  end

  defp assert_threshold(resolved, ref, window, trigger, pruning_target, tail_budget) do
    # Drain selection's metadata probes so this assertion proves Threshold itself
    # asked about the actual model. No generation params enter diagnostics.
    drain_metadata(ref)
    info = Threshold.for_model(resolved.model_spec, context_window: resolved.context_window)
    expected_model = resolved.model_spec
    assert_received {^ref, ^expected_model}
    refute_received {^ref, _}
    assert resolved.context_window == window
    assert info == %{threshold: trigger, window: window, source: :window}
    assert Threshold.pruning_target(info, 0.5) == pruning_target
    assert Recency.tail_budget(context_window: info.window) == tail_budget
    refute Threshold.exceeded?(trigger, info)
    assert Threshold.exceeded?(trigger + 1, info)
  end

  defp drain_metadata(ref) do
    receive do
      {^ref, _} -> drain_metadata(ref)
    after
      0 -> :ok
    end
  end

  defp resolve!(config, spec) do
    {:ok, resolved} = Schema.resolve_model_spec(config, spec)
    resolved
  end

  defp model_spec(id), do: %{provider: :openai, id: id, base_url: @endpoint}

  defp config do
    %{
      llm: %{
        default_provider_profile: "work",
        models: [%{id: "work", model: "openai:stale", context_window: 32_768}],
        providers: [
          %{
            id: "other",
            provider: "openai",
            models: ["small"],
            context_window: 1_000_000,
            concurrency: 2,
            temperature: 0.8
          },
          %{
            id: "work",
            provider: "openai",
            base_url: @endpoint,
            default_model: "small",
            context_window: 131_072,
            concurrency: 7,
            peak_concurrency: 0,
            peak_hours: [%{start: "09:00", end: "17:00"}],
            timezone: "Asia/Hong_Kong",
            off_peak_days: ["weekends"],
            temperature: 0.2,
            max_tokens: 2_048,
            top_p: 0.9,
            reasoning_efforts: ["high", "low"],
            default_reasoning_effort: "high",
            models: [
              %{
                model: "wide",
                context_window: 300_000,
                temperature: 0.6,
                max_tokens: 4_096,
                reasoning_efforts: ["low", "high"],
                default_reasoning_effort: "low"
              },
              %{model: "small"},
              %{model: "compact", context_window: 64_000}
            ]
          }
        ]
      }
    }
  end
end
