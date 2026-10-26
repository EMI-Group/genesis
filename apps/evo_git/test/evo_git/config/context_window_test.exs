defmodule EvoGit.Config.ContextWindowTest do
  @moduledoc """
  The ONE shared context-window resolver in `EvoGit.Config.Schema.LLM`:
  `default_context_window/0`, `context_window/1` (a single model profile —
  atom- or string-keyed) and `context_window_for/2` (a resolved config map +
  a model profile id).

  These helpers feed the context-compression window math, so their contract is
  total: a present positive integer is returned as-is, and EVERYTHING else
  (absent, nil, zero, negative, non-integer, non-map profile, unknown id,
  malformed config) degrades to the documented `200_000` default without ever
  raising — logging a warning only for a value that is PRESENT but invalid.

  `async: true` is safe: all three helpers are pure reads (the invalid-value
  path only emits a log line through `ExUnit.CaptureLog`). No app env,
  `:persistent_term`, ETS, process, or application singleton is touched.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Config.Schema.LLM

  @default 200_000

  describe "default_context_window/0" do
    test "is 200_000 tokens" do
      assert LLM.default_context_window() == @default
    end
  end

  describe "context_window/1 — a single model profile" do
    test "returns a present positive integer (atom-keyed)" do
      assert LLM.context_window(%{id: "default", context_window: 123_456}) == 123_456
      assert LLM.context_window(%{context_window: 1}) == 1
    end

    test "returns a present positive integer (string-keyed profile)" do
      assert LLM.context_window(%{"id" => "default", "context_window" => 50_000}) == 50_000
    end

    test "an atom key wins over a stale string key" do
      assert LLM.context_window(%{"context_window" => 1, context_window: 64_000}) == 64_000
    end

    test "an absent or nil context_window yields the default without warning" do
      log =
        capture_log(fn ->
          assert LLM.context_window(%{id: "default"}) == @default
          assert LLM.context_window(%{id: "default", context_window: nil}) == @default
          assert LLM.context_window(%{"id" => "default"}) == @default
        end)

      assert log == ""
    end

    test "zero, negative and non-integer values are invalid — default + warning" do
      # One branch (`invalid?`), three input shapes; each logs its own value.
      for {profile, logged} <- [
            {%{context_window: 0}, "Invalid LLM model profile context_window 0"},
            {%{context_window: -1}, "Invalid LLM model profile context_window -1"},
            {%{"context_window" => "big"}, ~s(Invalid LLM model profile context_window "big")}
          ] do
        log = capture_log(fn -> assert LLM.context_window(profile) == @default end)
        assert log =~ logged
      end

      # The warning also names the fallback it used.
      log = capture_log(fn -> assert LLM.context_window(%{context_window: 0}) == @default end)
      assert log =~ "using default #{@default}"
    end

    test "a non-map profile yields the default without raising" do
      log =
        capture_log(fn ->
          assert LLM.context_window(nil) == @default
          assert LLM.context_window("profile") == @default
          assert LLM.context_window(42) == @default
        end)

      assert log == ""
    end
  end

  describe "context_window_for/2 — resolved config map + model profile id" do
    test "returns the found profile's context window" do
      config = %{
        llm: %{
          models: [
            %{id: "fast", model: "google:gemini-flash", context_window: 64_000},
            %{id: "big", model: "anthropic:claude"}
          ]
        }
      }

      assert LLM.context_window_for(config, "fast") == 64_000
      # A profile without an explicit window resolves to the default.
      assert LLM.context_window_for(config, "big") == @default
    end

    test "an unknown id yields the default" do
      config = %{llm: %{models: [%{id: "fast", model: "google:gemini-flash"}]}}
      assert LLM.context_window_for(config, "missing") == @default
    end

    test "an empty or absent models list yields the default" do
      assert LLM.context_window_for(%{llm: %{models: []}}, "fast") == @default
      assert LLM.context_window_for(%{llm: %{}}, "fast") == @default
      assert LLM.context_window_for(%{}, "fast") == @default
    end

    test "a malformed config map or non-binary id yields the default" do
      assert LLM.context_window_for(%{llm: %{models: "notalist"}}, "fast") == @default
      assert LLM.context_window_for(nil, "fast") == @default
      assert LLM.context_window_for(%{llm: %{models: [%{id: "fast"}]}}, nil) == @default
      assert LLM.context_window_for(%{llm: %{models: [%{id: "fast"}]}}, :fast) == @default
    end

    test "an invalid window on the found profile degrades to the default with a warning" do
      config = %{llm: %{models: [%{id: "fast", model: "google:gemini-flash", context_window: 0}]}}

      log =
        capture_log(fn ->
          assert LLM.context_window_for(config, "fast") == @default
        end)

      assert log =~ "Invalid LLM model profile context_window 0"
    end
  end
end
