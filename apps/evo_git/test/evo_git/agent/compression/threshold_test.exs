defmodule EvoGit.Agent.Compression.ThresholdTest do
  @moduledoc """
  `EvoGit.Agent.Compression.Threshold` — the window-relative compression trigger.

  The trigger is derived from the CONFIGURED context window (`opts[:context_window]`,
  default `EvoGit.Config.Schema.LLM.default_context_window/0` = 200_000); the model
  catalog supplies ONLY the output reservation. `[:llm, :compression_threshold_tokens]`
  is an optional positive-integer OVERRIDE (`source: :config`).

  `async: false` — the module swaps the BEAM-global `:llm_model_metadata_fun` seam
  and redirects the process-wide `XDG_CONFIG_HOME` so the operator's real
  `~/.config/genesis/config.toml` (which may carry a
  `compression_threshold_tokens` override) can never leak into a window-derived
  assertion.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Threshold

  @seam :llm_model_metadata_fun
  @config_key [:llm, :compression_threshold_tokens]

  # `EvoGit.Config.Schema.LLM.default_context_window/0`.
  @default_window 200_000

  # The default window's formula result with the default 8_192-token output
  # reservation: min(0.8 * 200_000, 200_000 - 8_192 - 65_536) = 126_272.
  @default_threshold 126_272

  setup do
    previous_seam = Application.get_env(:evo_git, @seam)

    on_exit(fn ->
      case previous_seam do
        nil -> Application.delete_env(:evo_git, @seam)
        value -> Application.put_env(:evo_git, @seam, value)
      end
    end)

    # Pin the catalog to a plain 8_192-token output reservation: every worked
    # example below is then the documented one and no real catalog lookup (which
    # would force the multi-second `LLMDB.load/1` decode) ever runs.
    stub_metadata(%{limits: %{output: 8_192}, capabilities: %{}})

    %{config_dir: isolate_config!()}
  end

  # --- Helpers -------------------------------------------------------------

  # Swaps the call-time metadata seam `EvoGit.Config.Schema.LLM.model_metadata/1`
  # reads (`nil` means "no catalog metadata").
  defp stub_metadata(metadata) do
    Application.put_env(:evo_git, @seam, fn _model -> metadata end)
  end

  # Redirects the process-wide `XDG_CONFIG_HOME` at a fresh temp dir and returns
  # the config directory the runtime then resolves (so the write below always
  # lands where `EvoGit.Config` reads). `on_exit` restores the env var and
  # removes the temp dir, so no `:persistent_term` file cache entry survives.
  defp isolate_config! do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-threshold-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      case original_xdg do
        nil -> System.delete_env("XDG_CONFIG_HOME")
        value -> System.put_env("XDG_CONFIG_HOME", value)
      end

      File.rm_rf!(tmp_xdg)
    end)

    config_dir = EvoGit.Config.config_dir()
    File.mkdir_p!(config_dir)
    config_dir
  end

  defp write_config!(config_dir, contents) do
    File.write!(Path.join(config_dir, "config.toml"), contents)
  end

  defp config_threshold, do: EvoGit.Config.resolve(@config_key)

  # --- The window comes from configuration ---------------------------------

  describe "for_model/2 — the threshold derives from the configured window" do
    test "the default window (200_000) derives 126_272 with source :window" do
      info = Threshold.for_model(nil)

      assert info == %{threshold: @default_threshold, window: @default_window, source: :window}
      assert Threshold.exceeded?(@default_threshold + 1, info)
      refute Threshold.exceeded?(@default_threshold, info)
    end

    test "a 1M-token window compresses at 80 % of it" do
      info = Threshold.for_model("deepseek:deepseek-chat", context_window: 1_000_000)

      assert info == %{threshold: 800_000, window: 1_000_000, source: :window}

      # The legacy fixed 180_000 trigger compressed a 1M window at ~18 % of its
      # capacity -- exactly the waste this module removes.
      refute Threshold.exceeded?(200_000, info)
      refute Threshold.exceeded?(800_000, info)
      assert Threshold.exceeded?(800_001, info)
    end

    test "a 128k-token window compresses comfortably before overflow" do
      info = Threshold.for_model("zai:glm-5", context_window: 131_072)

      assert info == %{threshold: 57_344, window: 131_072, source: :window}
      refute Threshold.exceeded?(57_344, info)
      assert Threshold.exceeded?(60_000, info)
    end

    test "a tiny window still yields a positive threshold at or below 90 % of it" do
      info = Threshold.for_model("tiny:model", context_window: 32_768)

      assert info.source == :window
      assert info.window == 32_768
      assert info.threshold == 29_491
      assert info.threshold > 0
      assert info.threshold <= trunc(32_768 * 0.9)
    end

    test "the 32_000 floor wins on a window whose 0.8 fraction is smaller" do
      # 64_000 - 8_192 - 65_536 is negative, so the raw term loses and the floor
      # (capped at 0.9 * 64_000 = 57_600) governs.
      assert Threshold.for_model(nil, context_window: 64_000) == %{
               threshold: 32_000,
               window: 64_000,
               source: :window
             }
    end

    test "an unusable :context_window option falls back to the default window" do
      for unusable <- [nil, 0, -1, "131072", 131_072.0, :window] do
        assert Threshold.for_model(nil, context_window: unusable) == %{
                 threshold: @default_threshold,
                 window: @default_window,
                 source: :window
               },
               "expected #{inspect(unusable)} to fall back to the default window"
      end
    end
  end

  # --- The catalog window is deliberately ignored --------------------------

  describe "for_model/2 — the model catalog supplies only the output reservation" do
    test "a 10M-token catalog context limit does not move the threshold" do
      stub_metadata(%{limits: %{context: 10_000_000, output: 8_192}, capabilities: %{}})

      # The CONFIGURED window governs: the default one ...
      assert Threshold.for_model("wide:model") == %{
               threshold: @default_threshold,
               window: @default_window,
               source: :window
             }

      # ... and an explicitly supplied one, even though it is far smaller than
      # the catalog's.
      assert Threshold.for_model("wide:model", context_window: 131_072) == %{
               threshold: 57_344,
               window: 131_072,
               source: :window
             }
    end

    test "a catalog context limit with no output limit still uses the default reservation" do
      stub_metadata(%{limits: %{context: 10_000_000}, capabilities: %{}})

      assert Threshold.for_model("wide:model").threshold == @default_threshold
    end

    test "an oversized output limit is clamped and shrinks the threshold" do
      # reserved clamps to 32_768, so 200_000 - 32_768 - 65_536 = 101_696 beats
      # the 0.8 * W = 160_000 window fraction.
      stub_metadata(%{limits: %{context: 10_000_000, output: 100_000}, capabilities: %{}})

      assert Threshold.for_model("big:model") == %{
               threshold: 101_696,
               window: @default_window,
               source: :window
             }
    end

    test "a smaller-than-default output limit raises the threshold" do
      stub_metadata(%{limits: %{output: 1_024}, capabilities: %{}})

      # 200_000 - 1_024 - 65_536 = 133_440 (still under 0.8 * W = 160_000).
      assert Threshold.for_model("small:model").threshold == 133_440
    end

    test "string-keyed limits are read exactly like atom-keyed ones" do
      stub_metadata(%{
        limits: %{"context" => 131_072, "output" => 8_192},
        capabilities: %{}
      })

      info = Threshold.for_model("stringy:model", context_window: 131_072)

      assert info == %{threshold: 57_344, window: 131_072, source: :window}
    end

    test "nil and zero output limits fall back to the default reservation" do
      for output <- [nil, 0, -8_192, "8192"] do
        stub_metadata(%{limits: %{output: output}, capabilities: %{}})

        assert Threshold.for_model("zero:model").threshold == @default_threshold,
               "expected output limit #{inspect(output)} to use the 8_192 default"
      end
    end

    test "no metadata at all (and a raising lookup) degrades to the default reservation" do
      stub_metadata(nil)
      assert Threshold.for_model("mystery:model").threshold == @default_threshold

      Application.put_env(:evo_git, @seam, fn _model -> raise "catalog exploded" end)

      assert Threshold.for_model("mystery:model") == %{
               threshold: @default_threshold,
               window: @default_window,
               source: :window
             }
    end
  end

  # --- The explicit config override ---------------------------------------

  describe "for_model/2 — [:llm, :compression_threshold_tokens] override" do
    test "with the key unset (the schema default nil) the source is :window", %{
      config_dir: config_dir
    } do
      write_config!(config_dir, "")

      assert config_threshold() == nil

      assert Threshold.for_model(nil, context_window: 131_072) == %{
               threshold: 57_344,
               window: 131_072,
               source: :window
             }
    end

    test "a positive override wins verbatim, EVEN with a window supplied", %{
      config_dir: config_dir
    } do
      write_config!(config_dir, "[llm]\ncompression_threshold_tokens = 90000\n")

      assert config_threshold() == 90_000

      assert Threshold.for_model(nil, context_window: 1_000_000) == %{
               threshold: 90_000,
               window: 1_000_000,
               source: :config
             }

      # No window supplied: the override is still reported against the default
      # window (which is never nil).
      assert Threshold.for_model(nil) == %{
               threshold: 90_000,
               window: @default_window,
               source: :config
             }
    end

    test "the override ignores the catalog output reservation too", %{config_dir: config_dir} do
      write_config!(config_dir, "[llm]\ncompression_threshold_tokens = 42_000\n")
      stub_metadata(%{limits: %{output: 100_000}, capabilities: %{}})

      assert Threshold.for_model("big:model", context_window: 32_768) == %{
               threshold: 42_000,
               window: 32_768,
               source: :config
             }
    end
  end

  # --- Stage-1 pruning target ---------------------------------------------

  describe "pruning_target/2" do
    test "the default fraction is 0.5 and lands on half the DEFAULT window" do
      info = Threshold.for_model(nil)

      assert Threshold.default_pruning_target_fraction() == 0.5

      assert Threshold.pruning_target(info, Threshold.default_pruning_target_fraction()) ==
               100_000

      assert Threshold.pruning_target(info, 0.5) == 100_000
    end

    test "a smaller window caps the target at the threshold" do
      info = Threshold.for_model(nil, context_window: 131_072)

      # 0.5 * 131_072 = 65_536 > the 57_344 threshold, so the threshold wins.
      assert info.threshold == 57_344
      assert Threshold.pruning_target(info, 0.5) == 57_344
    end

    test "a custom fraction scales with the window" do
      info = Threshold.for_model(nil)

      assert Threshold.pruning_target(info, 0.25) == 50_000
      assert Threshold.pruning_target(info, 0.1) == 20_000
      # 0.75 * 200_000 = 150_000 is still capped at the 126_272 threshold.
      assert Threshold.pruning_target(info, 0.75) == @default_threshold
      assert Threshold.pruning_target(info, 0.9) == @default_threshold
    end

    test "a fraction outside (0, 1) normalizes to the default 0.5" do
      info = Threshold.for_model(nil)

      for bad <- [0, 1, -1, 2, 0.0, 1.0, -0.25, 1.5, "0.5", nil, :half] do
        assert Threshold.pruning_target(info, bad) == 100_000,
               "expected fraction #{inspect(bad)} to normalize to 0.5"
      end
    end

    test "a nil or unusable window yields the threshold itself" do
      for window <- [nil, 0, -1, "200000", 200_000.0] do
        assert Threshold.pruning_target(%{threshold: 42, window: window, source: :window}, 0.5) ==
                 42,
               "expected window #{inspect(window)} to fall back to the threshold"
      end
    end

    test "an unusable info map yields 0" do
      assert Threshold.pruning_target(nil, 0.5) == 0
      assert Threshold.pruning_target(:not_a_map, 0.5) == 0
      assert Threshold.pruning_target(%{}, 0.5) == 0
      assert Threshold.pruning_target(%{threshold: nil, window: @default_window}, 0.5) == 0
      assert Threshold.pruning_target(%{threshold: "100", window: @default_window}, 0.5) == 0
    end
  end

  # --- The gate and the projection ----------------------------------------

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
      # A zero/negative reported count is never scaled upwards.
      assert Threshold.project(0, 10_000, 1) == 0
    end
  end
end
