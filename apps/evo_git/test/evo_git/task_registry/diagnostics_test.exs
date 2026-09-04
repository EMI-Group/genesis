defmodule EvoGit.TaskRegistry.DiagnosticsTest do
  @moduledoc """
  Tests for `EvoGit.TaskRegistry.Diagnostics` — failed-transition diagnostic
  logging helpers used by `EvoGit.TaskRegistry`.

  These are pure Logger/Process.info functions with no GenServer or Store
  dependency, so no setup is required.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TaskRegistry.Diagnostics

  describe "log_failed_transition/4" do
    test "logs the greppable prefix, task_id, source, and prev_status" do
      log =
        capture_log(fn ->
          assert Diagnostics.log_failed_transition("task-123", :result_handler, :running, []) ==
                   :ok
        end)

      assert log =~ "TaskRegistry: FAILED_TRANSITION"
      assert log =~ "task_id=task-123"
      assert log =~ "source=result_handler"
      assert log =~ "prev_status=:running"
    end

    test "includes the result value when provided via :result opt" do
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-1", :down_handler, :running,
            result: {:exit, :killed}
          )
        end)

      assert log =~ "result={:exit, :killed}"
    end

    test "defaults result to nil when :result is absent" do
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-1", :reconcile, :running, [])
        end)

      assert log =~ "result=nil"
    end

    test "includes extra fields when provided via :extra opt" do
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-9", :update_status_cast, :finalizing,
            extra: [reason: "timeout", attempt: 3]
          )
        end)

      assert log =~ "reason=\"timeout\""
      assert log =~ "attempt=3"
    end

    test "omits the extra-fields segment when :extra is absent or empty" do
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-9", :update_status_cast, :finalizing, [])
        end)

      # No trailing key=value pairs after result=nil beyond the stacktrace.
      assert log =~ "result=nil\n"
    end

    test "includes caller pid and caller stack when :caller_info is a tuple" do
      caller_stack = [{MyMod, :foo, 2, [{~c"file.ex", 42}]}]

      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-7", :update_status_cast, :finalizing,
            caller_info: {self(), caller_stack}
          )
        end)

      assert log =~ "caller_pid="
      refute log =~ "caller_pid=N/A"
      assert log =~ "caller_stack="
    end

    test "marks caller as same-process when :caller_info is nil" do
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition("task-7", :result_handler, :running, caller_info: nil)
        end)

      assert log =~ "caller_pid=N/A (same-process transition)"
    end

    test "never crashes with varied inputs" do
      # Mix of nil prev_status, missing keys, and unusual result terms.
      log =
        capture_log(fn ->
          Diagnostics.log_failed_transition(nil, :reconcile, nil, [])
        end)

      assert log =~ "TaskRegistry: FAILED_TRANSITION"
    end
  end

  describe "capture_stacktrace/1" do
    test "returns a list" do
      trace = Diagnostics.capture_stacktrace(5)
      assert is_list(trace)
    end

    test "returns at most n frames" do
      trace = Diagnostics.capture_stacktrace(3)
      assert length(trace) <= 3
    end

    test "skips internal capture_stacktrace frames" do
      trace = Diagnostics.capture_stacktrace(5)

      refute Enum.any?(trace, fn
               {EvoGit.TaskRegistry.Diagnostics, :capture_stacktrace, _, _} -> true
               _ -> false
             end)
    end

    test "skips internal log_failed_transition frames" do
      trace = Diagnostics.capture_stacktrace(5)

      refute Enum.any?(trace, fn
               {EvoGit.TaskRegistry.Diagnostics, :log_failed_transition, _, _} -> true
               _ -> false
             end)
    end

    test "skips Process.info frames" do
      trace = Diagnostics.capture_stacktrace(5)

      refute Enum.any?(trace, fn
               {Process, :info, _, _} -> true
               _ -> false
             end)
    end

    test "skips gen_server frames" do
      trace = Diagnostics.capture_stacktrace(5)

      refute Enum.any?(trace, fn
               {:gen_server, _, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "format_stacktrace/1" do
    test "returns a placeholder for an empty list" do
      assert Diagnostics.format_stacktrace([]) == "  (no stacktrace available)"
    end

    test "formats each frame on its own indented line" do
      trace = [
        {:lists, :map, 2, [{~c"lists.erl", 100}]},
        {Enum, :"-map/2-lists^map/2-0-", 2, [{~c"enum.ex", 200}]}
      ]

      formatted = Diagnostics.format_stacktrace(trace)

      assert String.contains?(formatted, "lists.map/2 at lists.erl:100")
      assert String.contains?(formatted, "Enum.-map/2-lists^map/2-0-/2 at enum.ex:200")

      # One line per frame.
      assert length(String.split(formatted, "\n")) == 2
    end
  end

  describe "format_stacktrace_frame/1" do
    test "formats a standard 4-tuple frame with module, function/arity, and location" do
      frame = {MyMod, :foo, 2, [{~c"file.ex", 42}]}
      assert Diagnostics.format_stacktrace_frame(frame) == "MyMod.foo/2 at file.ex:42"
    end

    test "formats a frame with an args list instead of an arity integer" do
      frame = {MyMod, :bar, [:a, :b], [{~c"file.ex", 7}]}
      assert Diagnostics.format_stacktrace_frame(frame) == "MyMod.bar(2) at file.ex:7"
    end

    test "omits the location when location is not a file/line list" do
      frame = {MyMod, :baz, 0, []}
      assert Diagnostics.format_stacktrace_frame(frame) == "MyMod.baz/0"
    end

    test "falls back to inspect for non-tuple input" do
      assert Diagnostics.format_stacktrace_frame(:not_a_frame) == "    :not_a_frame"
    end
  end

  describe "format_function/2" do
    test "formats an atom name with an integer arity" do
      assert Diagnostics.format_function(:foo, 2) == "foo/2"
    end

    test "formats an atom name with an args list" do
      assert Diagnostics.format_function(:bar, [:a, :b, :c]) == "bar(3)"
    end

    test "falls back to inspect for non-atom names" do
      assert Diagnostics.format_function({"not", "atom"}, 2) == ~s({"not", "atom"})
    end

    test "falls back to inspect for a non-atom, non-list arity/args" do
      assert Diagnostics.format_function(:foo, :not_an_arity) == ":foo"
    end
  end

  describe "format_location/1" do
    test "formats a file/line charlist location" do
      assert Diagnostics.format_location([{~c"src/app.ex", 42}]) == " at src/app.ex:42"
    end

    test "includes only the first file/line pair" do
      assert Diagnostics.format_location([{~c"src/app.ex", 42}, {~c"other.ex", 1}]) ==
               " at src/app.ex:42"
    end

    test "returns empty string for an empty list" do
      assert Diagnostics.format_location([]) == ""
    end

    test "returns empty string for nil" do
      assert Diagnostics.format_location(nil) == ""
    end

    test "returns empty string for a non-charlist file" do
      assert Diagnostics.format_location([{"src/app.ex", 42}]) == ""
    end
  end
end
