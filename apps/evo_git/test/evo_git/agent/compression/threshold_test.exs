defmodule EvoGit.Agent.Compression.ThresholdTest do
  # NOT async: the whole module swaps the global `:llm_model_metadata_fun` seam.
  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Threshold

  @seam :llm_model_metadata_fun
  @config_key [:llm, :compression_threshold_tokens]

  setup do
    previous = Application.get_env(:evo_git, @seam)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_git, @seam)
        value -> Application.put_env(:evo_git, @seam, value)
      end
    end)

    :ok
  end

  # Drives the window through the call-time seam that
  # `EvoGit.Config.Schema.LLM.model_metadata/1` already reads.
  defp stub_window(context, output) do
    Application.put_env(:evo_git, @seam, fn _model ->
      %{limits: %{context: context, output: output}, capabilities: %{}}
    end)
  end

  defp config_threshold, do: EvoGit.Config.resolve(@config_key)

  describe "for_model/1 with a known window" do
    test "a 1M-token window compresses at 80 % of it, not at the legacy fixed threshold" do
      stub_window(1_000_000, 8_192)

      info = Threshold.for_model("deepseek:deepseek-chat")

      assert info == %{threshold: 800_000, window: 1_000_000, source: :window}

      # The old fixed 180_000 trigger compressed a 1M window at ~18 % of its
      # capacity -- exactly the waste this module removes.
      refute Threshold.exceeded?(200_000, info)
      refute Threshold.exceeded?(800_000, info)
      assert Threshold.exceeded?(800_001, info)
    end

    test "a 128k-token window compresses comfortably before overflow" do
      stub_window(131_072, 8_192)

      info = Threshold.for_model("zai:glm-5")

      assert info == %{threshold: 57_344, window: 131_072, source: :window}
      refute Threshold.exceeded?(57_344, info)
      assert Threshold.exceeded?(60_000, info)
    end

    test "a tiny window still yields a positive threshold at or below 90 % of it" do
      stub_window(32_768, nil)

      info = Threshold.for_model("tiny:model")

      assert info.source == :window
      assert info.window == 32_768
      assert info.threshold == 29_491
      assert info.threshold > 0
      assert info.threshold <= trunc(32_768 * 0.9)
    end

    test "string-keyed limits are read exactly like atom-keyed ones" do
      Application.put_env(:evo_git, @seam, fn _model ->
        %{limits: %{"context" => 131_072, "output" => 8_192}, capabilities: %{}}
      end)

      assert Threshold.for_model("stringy:model").threshold == 57_344
      assert Threshold.for_model("stringy:model").window == 131_072
    end

    test "an oversized output limit is clamped and shrinks the threshold" do
      stub_window(200_000, 100_000)

      # reserved clamps to 32_768, so 200_000 - 32_768 - 65_536 = 101_696 beats
      # the 0.8 * W = 160_000 window fraction.
      assert Threshold.for_model("big:model").threshold == 101_696
    end

    test "a zero output limit falls back to the default reservation" do
      stub_window(131_072, 0)

      assert Threshold.for_model("zero:model").threshold == 57_344
    end
  end

  describe "for_model/1 with an unknown window" do
    test "falls back to the config value with source :config" do
      Application.put_env(:evo_git, @seam, fn _model -> nil end)

      assert Threshold.for_model("mystery:model") == %{
               threshold: config_threshold(),
               window: nil,
               source: :config
             }
    end

    test "a metadata map without a context limit also falls back to the config value" do
      Application.put_env(:evo_git, @seam, fn _model -> %{limits: %{output: 8_192}} end)

      info = Threshold.for_model("nolimit:model")

      assert info.source == :config
      assert info.window == nil
      assert info.threshold == config_threshold()
    end

    test "the config fallback is a positive integer" do
      Application.put_env(:evo_git, @seam, fn _model -> nil end)

      threshold = Threshold.for_model("mystery:model").threshold

      assert is_integer(threshold)
      assert threshold > 0
    end
  end

  describe "exceeded?/2" do
    test "is strictly greater than, and total for unusable info maps" do
      info = %{threshold: 100, window: nil, source: :window}

      assert Threshold.exceeded?(101, info)
      refute Threshold.exceeded?(100, info)
      refute Threshold.exceeded?(0, info)

      # Degenerate inputs never raise: an unusable threshold simply never fires.
      refute Threshold.exceeded?(1_000, %{threshold: nil})
      refute Threshold.exceeded?(1_000, %{})
      refute Threshold.exceeded?(1_000, %{threshold: "100"})
      refute Threshold.exceeded?(1_000, nil)
      refute Threshold.exceeded?(:not_a_number, info)
    end
  end

  describe "project/3" do
    test "scales the token count by the character ratio" do
      assert Threshold.project(100_000, 10_000, 5_000) == 50_000
      assert Threshold.project(200_000, 1_000_000, 250_000) == 50_000
      assert Threshold.project(1_000, 4_000, 1_000) == 250
      assert Threshold.project(100_000, 10_000, 9_999) == 99_990
      assert Threshold.project(100_000, 10_000, 0) == 0
    end

    test "never exceeds the reported token count" do
      assert Threshold.project(100_000, 10_000, 10_000) == 100_000
      assert Threshold.project(100_000, 10_000, 20_000) == 100_000
    end

    test "keeps the reported count when there is no usable ratio" do
      # chars_before == 0 has no ratio to apply.
      assert Threshold.project(123_456, 0, 0) == 123_456
      # Non-integer inputs are passed through untouched.
      assert Threshold.project(123, nil, 5) == 123
      assert Threshold.project(nil, 10, 5) == nil
    end
  end
end
