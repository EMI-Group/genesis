defmodule EvoDashWeb.HelpersTest do
  use ExUnit.Case, async: true

  import EvoDashWeb.Helpers

  describe "agent_status_color/1" do
    test "returns correct color for known statuses" do
      assert agent_status_color(:pending) == "text-base-content/70"
      assert agent_status_color(:running) == "text-success"
      assert agent_status_color(:waiting) == "text-warning"
      assert agent_status_color(:blocked) == "text-error"
      assert agent_status_color(:ready) == "text-info"
    end

    test "falls back to default for unknown status" do
      assert agent_status_color(:unknown) == "text-base-content/70"
    end
  end

  describe "agent_status_bg/1" do
    test "returns correct background for known statuses" do
      assert agent_status_bg(:pending) == "bg-base-100"
      assert agent_status_bg(:running) == "bg-success/10"
      assert agent_status_bg(:waiting) == "bg-warning/10"
      assert agent_status_bg(:blocked) == "bg-error/10"
      assert agent_status_bg(:ready) == "bg-info/10"
    end

    test "falls back to default for unknown status" do
      assert agent_status_bg(:unknown) == "bg-base-100"
    end
  end

  describe "agent_status_border/1" do
    test "returns correct border for known statuses" do
      assert agent_status_border(:pending) == "border-base-300"
      assert agent_status_border(:running) == "border-success/30"
      assert agent_status_border(:waiting) == "border-warning/30"
      assert agent_status_border(:blocked) == "border-error/30"
      assert agent_status_border(:ready) == "border-info/30"
    end

    test "falls back to default for unknown status" do
      assert agent_status_border(:unknown) == "border-base-300"
    end
  end

  describe "agent_status_icon/1" do
    test "returns correct icon for known statuses" do
      assert agent_status_icon(:pending) == "hero-clock"
      assert agent_status_icon(:running) == "hero-play-circle"
      assert agent_status_icon(:waiting) == "hero-pause-circle"
      assert agent_status_icon(:blocked) == "hero-exclamation-circle"
      assert agent_status_icon(:ready) == "hero-arrow-path"
    end

    test "falls back to question mark for unknown status" do
      assert agent_status_icon(:unknown) == "hero-question-mark-circle"
    end
  end

  describe "task_status_badge/1" do
    test "returns correct badge for known statuses" do
      assert task_status_badge(:running) =~ "text-success"
      assert task_status_badge(:completed) =~ "text-info"
      assert task_status_badge(:failed) =~ "text-error"
      assert task_status_badge(:cancelled) =~ "text-warning"
    end

    test "all badges have rounded-full" do
      for status <- [:running, :completed, :failed, :cancelled, :unknown] do
        assert task_status_badge(status) =~ "rounded-full"
      end
    end

    test "falls back to base badge for unknown status" do
      badge = task_status_badge(:unknown)
      assert badge =~ "bg-base-200"
      assert badge =~ "text-base-content/70"
    end
  end

  describe "task_type_icon/1" do
    test "returns correct icon for task types" do
      assert task_type_icon(:genesis) == "hero-cube"
      assert task_type_icon(:evolve) == "hero-arrow-path"
    end
  end

  describe "format_number/1" do
    test "formats integer with comma separators" do
      assert format_number(1_234_567) == "1,234,567"
    end

    test "formats binary string with comma separators" do
      assert format_number("1000000") == "1,000,000"
    end

    test "formats small numbers without commas" do
      assert format_number(999) == "999"
    end

    test "falls back to 0 for invalid input" do
      assert format_number(nil) == "0"
    end
  end

  describe "format_cost/1" do
    test "formats number with 6 decimal places" do
      assert format_cost(1.5) == "1.500000"
      assert format_cost(0) == "0.000000"
    end

    test "falls back to 0.000000 for invalid input" do
      assert format_cost(nil) == "0.000000"
      assert format_cost("abc") == "0.000000"
    end
  end

  describe "truncate_string/2" do
    test "returns empty string for nil" do
      assert truncate_string(nil, 10) == ""
    end

    test "truncates long string with ellipsis" do
      result = truncate_string("Hello World Foo Bar", 5)
      assert String.starts_with?(result, "Hello")
      assert String.ends_with?(result, "...")
    end

    test "returns short string unchanged" do
      assert truncate_string("Hi", 10) == "Hi"
    end
  end

  describe "format_module_name/1" do
    test "extracts last segment from atom module name" do
      assert format_module_name(EvoGit.Agent.Spatial) == "Spatial"
    end

    test "falls back to Unknown for non-atom input" do
      assert format_module_name("not-a-module") == "Unknown"
    end
  end

  describe "history_entry_icon/1" do
    test "returns correct icon for known roles" do
      assert history_entry_icon("system") == "hero-cog"
      assert history_entry_icon("user") == "hero-chat-bubble-left-ellipsis"
      assert history_entry_icon("assistant") == "hero-sparkles"
      assert history_entry_icon("tool") == "hero-wrench-screwdriver"
    end

    test "falls back to document icon for unknown role" do
      assert history_entry_icon("unknown") == "hero-document-text"
    end
  end

  describe "history_entry_color/1" do
    test "returns correct color for known roles" do
      assert history_entry_color("system") == "text-accent"
      assert history_entry_color("user") == "text-info"
      assert history_entry_color("assistant") == "text-warning"
      assert history_entry_color("tool") == "text-success"
    end

    test "falls back to muted color for unknown role" do
      assert history_entry_color("unknown") == "text-base-content/70"
    end
  end

  describe "tool_call_name/1" do
    test "extracts name from :function.name atom-key map" do
      assert tool_call_name(%{function: %{name: "read_file"}}) == "read_file"
    end

    test "extracts name from function string-key map" do
      assert tool_call_name(%{"function" => %{"name" => "write_file"}}) == "write_file"
    end

    test "extracts name from :name key" do
      assert tool_call_name(%{name: "exec"}) == "exec"
    end

    test "falls back to unknown for unrecognized format" do
      assert tool_call_name(%{}) == "unknown"
      assert tool_call_name(nil) == "unknown"
    end
  end

  describe "tool_call_arguments/1" do
    test "extracts arguments from :function atom-key map" do
      result = tool_call_arguments(%{function: %{arguments: "{}"}})
      assert result == "{}"
    end

    test "extracts arguments_json from :function atom-key map" do
      result = tool_call_arguments(%{function: %{arguments_json: "{\"a\": 1}"}})
      assert result == "{\"a\": 1}"
    end

    test "extracts arguments from function string-key map" do
      result = tool_call_arguments(%{"function" => %{"arguments" => "{}"}})
      assert result == "{}"
    end

    test "extracts from :arguments key directly" do
      assert tool_call_arguments(%{arguments: "raw"}) == "raw"
    end

    test "falls back to {} for unrecognized format" do
      assert tool_call_arguments(%{}) == "{}"
      assert tool_call_arguments(nil) == "{}"
    end
  end

  describe "format_reasoning_details/1" do
    test "returns nil for nil input" do
      assert format_reasoning_details(nil) == nil
    end

    test "joins text from list of structs with :text" do
      details = [%{text: "First"}, %{text: "Second"}]
      assert format_reasoning_details(details) == "FirstSecond"
    end

    test "returns nil for empty list" do
      assert format_reasoning_details([]) == nil
    end

    test "returns nil when all entries have blank text" do
      details = [%{text: ""}, %{other: "x"}]
      assert format_reasoning_details(details) == nil
    end
  end

  describe "relative_time/1" do
    test "returns just now for very recent datetime" do
      now = DateTime.utc_now()
      assert relative_time(now) == "just now"
    end

    test "returns seconds ago for recent past datetime" do
      dt = DateTime.utc_now() |> DateTime.add(-30, :second)
      result = relative_time(dt)
      assert result =~ ~r/\d+s ago/
    end

    test "accepts ISO8601 binary string" do
      dt = DateTime.utc_now() |> DateTime.add(-45, :second)
      iso = DateTime.to_iso8601(dt)
      result = relative_time(iso)
      assert result =~ ~r/\d+s ago/
    end
  end

  describe "mode_description/1" do
    test "returns description for genesis_new" do
      assert mode_description("genesis_new") =~ "codebase"
    end

    test "returns description for genesis_existing" do
      assert mode_description("genesis_existing") =~ "codebase"
    end

    test "returns description for evolve_simple" do
      assert mode_description("evolve_simple") =~ "codebase"
    end

    test "returns empty string for unknown mode" do
      assert mode_description("unknown_mode") == ""
    end
  end

  describe "mode_info_message/1" do
    test "returns message for genesis_new" do
      assert mode_info_message("genesis_new") =~ "Empty directory"
    end

    test "returns message for genesis_existing" do
      assert mode_info_message("genesis_existing") =~ "CONTEXT.md"
    end

    test "returns message for evolve_simple" do
      assert mode_info_message("evolve_simple") =~ "Evolution mode"
    end

    test "returns empty string for unknown mode" do
      assert mode_info_message("unknown_mode") == ""
    end
  end
end
