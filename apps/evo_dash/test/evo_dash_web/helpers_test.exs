defmodule EvoDashWeb.HelpersTest do
  use ExUnit.Case, async: true

  import EvoDashWeb.Helpers

  describe "agent_status_color/1" do
    test "returns correct color for known statuses" do
      assert agent_status_color(:pending) == "text-base-content/80"
      assert agent_status_color(:running) == "text-success"
      assert agent_status_color(:waiting) == "text-warning"
      assert agent_status_color(:blocked) == "text-base-content/80"
      assert agent_status_color(:ready) == "text-info"
    end

    test "blocked presents identically to pending" do
      assert agent_status_color(:blocked) == agent_status_color(:pending)
    end

    test "falls back to default for unknown status" do
      assert agent_status_color(:unknown) == "text-base-content/80"
    end
  end

  describe "agent_status_bg/1" do
    test "returns correct background for known statuses" do
      assert agent_status_bg(:pending) == "bg-base-200/60"
      assert agent_status_bg(:running) == "bg-success/10"
      assert agent_status_bg(:waiting) == "bg-warning/10"
      assert agent_status_bg(:blocked) == "bg-base-200/60"
      assert agent_status_bg(:ready) == "bg-info/10"
    end

    test "blocked presents identically to pending" do
      assert agent_status_bg(:blocked) == agent_status_bg(:pending)
    end

    test "falls back to default for unknown status" do
      assert agent_status_bg(:unknown) == "bg-base-200/60"
    end
  end

  describe "agent_status_border/1" do
    test "returns correct border for known statuses" do
      assert agent_status_border(:pending) == "border-base-content/20"
      assert agent_status_border(:running) == "border-success/30"
      assert agent_status_border(:waiting) == "border-warning/30"
      assert agent_status_border(:blocked) == "border-base-content/20"
      assert agent_status_border(:ready) == "border-info/30"
    end

    test "blocked presents identically to pending" do
      assert agent_status_border(:blocked) == agent_status_border(:pending)
    end

    test "falls back to default for unknown status" do
      assert agent_status_border(:unknown) == "border-base-content/20"
    end
  end

  describe "agent_status_icon/1" do
    test "returns correct icon for known statuses" do
      assert agent_status_icon(:pending) == "hero-clock"
      assert agent_status_icon(:running) == "hero-play-circle"
      assert agent_status_icon(:waiting) == "hero-pause-circle"
      assert agent_status_icon(:blocked) == "hero-clock"
      assert agent_status_icon(:ready) == "hero-arrow-path"
    end

    test "blocked presents identically to pending" do
      assert agent_status_icon(:blocked) == agent_status_icon(:pending)
    end

    test "falls back to question mark for unknown status" do
      assert agent_status_icon(:unknown) == "hero-question-mark-circle"
    end
  end

  describe "agent_status_label/1" do
    test "merges blocked into pending" do
      assert agent_status_label(:blocked) == "Pending"
      assert agent_status_label(:pending) == "Pending"
    end

    test "returns capitalized labels for known statuses" do
      assert agent_status_label(:running) == "Running"
      assert agent_status_label(:waiting) == "Waiting"
      assert agent_status_label(:ready) == "Ready"
    end

    test "falls back to capitalized name for unknown atoms" do
      assert agent_status_label(:unknown) == "Unknown"
      assert agent_status_label(:starting) == "Starting"
    end

    test "falls back to Unknown for non-atoms" do
      assert agent_status_label("running") == "Unknown"
      assert agent_status_label(%{}) == "Unknown"
    end

    test "treats nil (an atom) via the capitalized-name fallback" do
      # nil is an atom in Elixir, so it follows the atom fallback (matching
      # the pre-existing `is_atom` behavior in the projects_live remote panel).
      assert agent_status_label(nil) == "Nil"
    end
  end

  describe "task_status_badge/1" do
    test "returns correct badge for known statuses" do
      # Transitional/busy states share the warning (amber) family
      assert task_status_badge(:running) ==
               "bg-warning/10 text-warning rounded-full flex items-center justify-center"

      assert task_status_badge(:finalizing) ==
               "bg-warning/10 text-warning rounded-full flex items-center justify-center"

      assert task_status_badge(:cancelling) ==
               "bg-warning/10 text-warning rounded-full flex items-center justify-center"

      # Completed is success, failed is error
      assert task_status_badge(:completed) ==
               "bg-success/10 text-success rounded-full flex items-center justify-center"

      assert task_status_badge(:failed) ==
               "bg-error/10 text-error rounded-full flex items-center justify-center"

      # Terminal-neutral states are muted base-content
      assert task_status_badge(:cancelled) ==
               "bg-base-content/10 text-base-content/60 rounded-full flex items-center justify-center"

      assert task_status_badge(:pending) ==
               "bg-base-content/10 text-base-content/60 rounded-full flex items-center justify-center"
    end

    test "all badges have rounded-full" do
      for status <- [:running, :completed, :failed, :cancelled, :cancelling, :unknown] do
        assert task_status_badge(status) =~ "rounded-full"
      end
    end

    test "cancelling badge differs from the unknown-status fallback" do
      refute task_status_badge(:cancelling) =~ "bg-base-200"
      refute task_status_badge(:cancelling) == task_status_badge(:unknown)
    end

    test "falls back to base badge for unknown status" do
      badge = task_status_badge(:unknown)
      assert badge =~ "bg-base-200"
      assert badge =~ "text-base-content/70"
    end
  end

  describe "task_status_dot_class/1" do
    test "returns correct dot class for known statuses" do
      assert task_status_dot_class(:running) == "bg-warning"
      assert task_status_dot_class(:finalizing) == "bg-warning"
      assert task_status_dot_class(:cancelling) == "bg-warning"
      assert task_status_dot_class(:completed) == "bg-success"
      assert task_status_dot_class(:failed) == "bg-error"
      assert task_status_dot_class(:pending) == "bg-base-content/40"
      assert task_status_dot_class(:cancelled) == "bg-base-content/40"
    end

    test "transitional/busy statuses share the warning dot" do
      assert task_status_dot_class(:running) == task_status_dot_class(:cancelling)
      assert task_status_dot_class(:finalizing) == task_status_dot_class(:cancelling)
    end

    test "pending and cancelled share the neutral dim dot" do
      assert task_status_dot_class(:pending) == task_status_dot_class(:cancelled)
    end

    test "falls back to a dim neutral gray for unknown statuses" do
      assert task_status_dot_class(:unknown) == "bg-base-content/30"
      assert task_status_dot_class(nil) == "bg-base-content/30"
      assert task_status_dot_class("running") == "bg-base-content/30"
    end
  end

  describe "task_status_tint/1" do
    test "returns correct tint for known statuses" do
      assert task_status_tint(:running) == "bg-warning/5 shadow-warning/10 border-warning/20"
      assert task_status_tint(:finalizing) == "bg-warning/5 shadow-warning/10 border-warning/20"
      assert task_status_tint(:cancelling) == "bg-warning/5 shadow-warning/10 border-warning/20"
      assert task_status_tint(:completed) == "bg-success/5 shadow-success/10 border-success/20"
      assert task_status_tint(:failed) == "bg-error/5 shadow-error/10 border-error/20"
    end

    test "transitional/busy statuses share the warning tint" do
      assert task_status_tint(:running) == task_status_tint(:cancelling)
      assert task_status_tint(:finalizing) == task_status_tint(:cancelling)
    end

    test "falls back to the neutral tint for pending/cancelled/unknown" do
      neutral = "bg-base-200/40 border-base-300/20"
      assert task_status_tint(:pending) == neutral
      assert task_status_tint(:cancelled) == neutral
      assert task_status_tint(:unknown) == neutral
      assert task_status_tint(nil) == neutral
    end
  end

  describe "connection_status_dot_class/1" do
    test "returns correct dot class for known phases" do
      assert connection_status_dot_class(:local) == "bg-info"
      assert connection_status_dot_class(:connected) == "bg-success"
      assert connection_status_dot_class(:connecting) == "bg-warning"
      assert connection_status_dot_class(:disconnecting) == "bg-warning"
      assert connection_status_dot_class(:error) == "bg-error"
    end

    test "connecting and disconnecting share the warning dot" do
      assert connection_status_dot_class(:connecting) ==
               connection_status_dot_class(:disconnecting)
    end

    test "falls back to a dim neutral gray for disconnected/unknown phases" do
      assert connection_status_dot_class(:disconnected) == "bg-base-content/40"
      assert connection_status_dot_class(:unknown) == "bg-base-content/40"
      assert connection_status_dot_class(:bogus) == "bg-base-content/40"
      assert connection_status_dot_class(nil) == "bg-base-content/40"
    end
  end

  describe "connection_status_badge_class/1" do
    test "returns correct badge modifier for known phases" do
      assert connection_status_badge_class(:local) == "badge-ghost"
      assert connection_status_badge_class(:connected) == "badge-success"
      assert connection_status_badge_class(:connecting) == "badge-warning"
      assert connection_status_badge_class(:disconnecting) == "badge-warning"
      assert connection_status_badge_class(:error) == "badge-error"
    end

    test "connecting and disconnecting share the warning modifier" do
      assert connection_status_badge_class(:connecting) ==
               connection_status_badge_class(:disconnecting)
    end

    test "falls back to the neutral ghost modifier for disconnected/unknown phases" do
      assert connection_status_badge_class(:disconnected) == "badge-ghost"
      assert connection_status_badge_class(:unknown) == "badge-ghost"
      assert connection_status_badge_class(:bogus) == "badge-ghost"
      assert connection_status_badge_class(nil) == "badge-ghost"
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

    test "falls back to Unknown for non-module input" do
      assert format_module_name(123) == "Unknown"
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

  describe "tool_call_is_shell?/1" do
    test "returns true for run_bash and run_powershell" do
      assert tool_call_is_shell?(%{function: %{name: "run_bash"}})
      assert tool_call_is_shell?(%{"function" => %{"name" => "run_powershell"}})

      assert tool_call_is_shell?(%ReqLLM.ToolCall{
               id: "call_1",
               function: %{name: "run_bash", arguments: "{}"}
             })
    end

    test "returns false for other tools and unknown shapes" do
      refute tool_call_is_shell?(%{function: %{name: "read_file"}})
      refute tool_call_is_shell?(%{"function" => %{"name" => "search"}})
      refute tool_call_is_shell?(%{})
      refute tool_call_is_shell?(nil)
    end
  end

  describe "tool_call_command/1" do
    test "extracts command from run_bash arguments (atom-key map)" do
      call = %{function: %{name: "run_bash", arguments: ~s({"command":"ls -la","timeout":30})}}
      assert tool_call_command(call) == "ls -la"
    end

    test "extracts command from run_powershell arguments (string-key map)" do
      call =
        %{
          "function" => %{
            "name" => "run_powershell",
            "arguments" => ~s({"command":"Get-Process","timeout":60})
          }
        }

      assert tool_call_command(call) == "Get-Process"
    end

    test "extracts command from a ReqLLM.ToolCall struct" do
      call =
        %ReqLLM.ToolCall{
          id: "call_1",
          function: %{name: "run_bash", arguments: ~s({"command":"echo hi"})}
        }

      assert tool_call_command(call) == "echo hi"
    end

    test "falls back to the raw arguments string when JSON cannot be decoded" do
      call = %{function: %{name: "run_bash", arguments: "not-json"}}
      assert tool_call_command(call) == "not-json"
    end

    test "falls back to the raw string when the command field is missing" do
      call = %{function: %{name: "run_bash", arguments: ~s({"timeout":30})}}
      assert tool_call_command(call) == ~s({"timeout":30})
    end

    test "falls back to {} for missing/malformed arguments" do
      assert tool_call_command(%{}) == "{}"
      assert tool_call_command(nil) == "{}"
    end
  end

  describe "tool_call_arguments_pretty/1" do
    test "pretty-prints decodable JSON arguments" do
      call = %{function: %{name: "read_file", arguments: ~s({"path":"./x","limit":10})}}
      assert tool_call_arguments_pretty(call) == "{\n  \"limit\": 10,\n  \"path\": \"./x\"\n}"
    end

    test "returns the raw string for undecodable arguments" do
      call = %{function: %{name: "read_file", arguments: "not-json"}}
      assert tool_call_arguments_pretty(call) == "not-json"
    end

    test "returns {} for missing arguments" do
      assert tool_call_arguments_pretty(%{}) == "{}"
      assert tool_call_arguments_pretty(nil) == "{}"
    end
  end

  describe "tool_call_display/1" do
    test "returns {Shell call, command} for shell calls" do
      call = %{function: %{name: "run_bash", arguments: ~s({"command":"mix test"})}}
      assert tool_call_display(call) == {"Shell call", "mix test"}
    end

    test "returns {name, pretty arguments} for other calls" do
      call = %{function: %{name: "read_file", arguments: ~s({"path":"./x"})}}
      assert tool_call_display(call) == {"read_file", "{\n  \"path\": \"./x\"\n}"}
    end

    test "never crashes on unknown shapes" do
      assert tool_call_display(%{}) == {"unknown", "{}"}
      assert tool_call_display(nil) == {"unknown", "{}"}
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

    test "returns description for custom_agent" do
      assert mode_description("custom_agent") =~ "root agent"
      assert mode_description("custom_agent") =~ "custom agent"
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

    test "returns message for custom_agent" do
      assert mode_info_message("custom_agent") =~ "Custom Agent"
      assert mode_info_message("custom_agent") =~ "requires picking a custom agent"
    end

    test "returns empty string for unknown mode" do
      assert mode_info_message("unknown_mode") == ""
    end
  end

  describe "with_node_param/2" do
    test "appends ?node=<id> when a node id is given" do
      assert with_node_param("/agents", "gpu-server") == "/agents?node=gpu-server"
    end

    test "handles paths that already carry query params" do
      assert with_node_param("/review/task-1?tab=diff", "gpu-server") ==
               "/review/task-1?tab=diff?node=gpu-server"
    end

    test "returns the path unchanged for nil node id (local node)" do
      assert with_node_param("/agents", nil) == "/agents"
    end
  end
end
