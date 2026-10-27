defmodule EvoGit.Agent.ToolInvocationTest do
  @moduledoc """
  Unit tests for `EvoGit.Agent.ToolInvocation` — the pure preparation helpers run
  at the tool-dispatch boundary for ONE tool call: the tolerant three-stage
  arguments parse and the per-call timeout rule.

  Pins that the arguments parse never lets an undecodable argument shape reach
  the tool layer as a crash: a decoded JSON object is passed through as a map, a
  non-blank but unparseable raw argument string is handed on VERBATIM (the tool
  layer answers it with a self-correcting error string), and nothing recoverable
  becomes `{:error, reason}` which the caller renders as the standard
  `Error: invalid arguments: <reason>` result. A call that is not a
  `%ReqLLM.ToolCall{}` at all (a plain map, nil, an RPC-decoded term) takes that
  same "nothing recoverable" path rather than raising `FunctionClauseError` out
  of a struct-only accessor. `arguments_map/1` stays TOTAL for
  the same shapes (a map or `%{}`, never a raise), because the hint/telemetry
  helpers downstream of tool execution are map-only.

  Also pins the timeout rule: an explicit positive integer `timeout` argument is
  used and clamped by the configured maximum, an invalid or unreadable one is
  treated as ABSENT, an omitted timeout means the generous platform-shell
  default (never lower than the configured default) for a shell tool and the
  configured `[:scheduler, :default_tool_timeout]` for everything else.

  `async: true` is safe: `ToolInvocation` is pure (no git, no HTTP, no
  scheduler, no app env, no ETS, no `:persistent_term`) and the configured
  defaults/maximums are passed in as plain function arguments here, so nothing
  another concurrently running module can observe is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ToolInvocation

  # Build a tool call the way the provider layer does: a ReqLLM.ToolCall struct
  # whose `function.arguments` is the RAW JSON string the model emitted.
  defp call(name, arguments_json) do
    ReqLLM.ToolCall.new("call_1", name, arguments_json)
  end

  # ---------------------------------------------------------------------------
  # arguments/1
  # ---------------------------------------------------------------------------

  describe "arguments/1" do
    test "returns {:ok, map} for a decoded JSON object" do
      assert ToolInvocation.arguments(call("read", ~s({"path":"./lib/app.ex","limit":20}))) ==
               {:ok, %{"path" => "./lib/app.ex", "limit" => 20}}
    end

    test "returns {:ok, %{}} for an empty JSON object" do
      assert ToolInvocation.arguments(call("read", "{}")) == {:ok, %{}}
    end

    test "passes a non-blank undecodable argument string through as the SAME string" do
      raw = "not json{{"

      assert ToolInvocation.arguments(call("read", raw)) == {:ok, raw}
    end

    test "passes a truncated argument string through as the SAME string" do
      raw = ~s({"a":)

      assert ToolInvocation.arguments(call("read", raw)) == {:ok, raw}
    end

    test "returns {:error, reason} mentioning no arguments for an empty string" do
      assert {:error, reason} = ToolInvocation.arguments(call("read", ""))
      assert reason =~ "no arguments"
    end

    test "returns {:error, reason} mentioning no arguments for whitespace-only arguments" do
      assert {:error, reason} = ToolInvocation.arguments(call("read", "   \n\t"))
      assert reason =~ "no arguments"
    end

    test "returns {:error, reason} mentioning decoding for nil arguments" do
      assert {:error, reason} = ToolInvocation.arguments(call("read", nil))
      assert reason =~ "could not be decoded"
    end

    test "returns {:error, reason} for a non-ToolCall map instead of raising" do
      assert {:error, reason} = ToolInvocation.arguments(%{"id" => "x"})
      assert reason =~ "could not be decoded"
    end

    test "returns {:error, reason} for nil and other non-ToolCall values instead of raising" do
      for value <- [nil, "read", [id: "x"], :read_call] do
        assert {:error, reason} = ToolInvocation.arguments(value)
        assert reason =~ "could not be decoded"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # arguments_map/1
  # ---------------------------------------------------------------------------

  describe "arguments_map/1" do
    test "returns the decoded map for a JSON object" do
      assert ToolInvocation.arguments_map(call("read", ~s({"path":"./a.ex"}))) == %{
               "path" => "./a.ex"
             }
    end

    test "degrades undecodable garbage to %{} instead of raising" do
      assert ToolInvocation.arguments_map(call("read", "not json{{")) == %{}
    end

    test "degrades a truncated argument string to %{} instead of raising" do
      assert ToolInvocation.arguments_map(call("read", ~s({"a":))) == %{}
    end

    test "degrades an empty argument string to %{} instead of raising" do
      assert ToolInvocation.arguments_map(call("read", "")) == %{}
    end

    test "degrades nil arguments to %{} instead of raising" do
      assert ToolInvocation.arguments_map(call("read", nil)) == %{}
    end

    test "degrades a non-ToolCall map to %{} instead of raising" do
      assert ToolInvocation.arguments_map(%{"id" => "x"}) == %{}
    end

    test "degrades nil and other non-ToolCall values to %{} instead of raising" do
      for value <- [nil, "read", [id: "x"], :read_call] do
        assert ToolInvocation.arguments_map(value) == %{}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # invalid_arguments_result/1
  # ---------------------------------------------------------------------------

  describe "invalid_arguments_result/1" do
    test "renders the standard tool-result string" do
      assert ToolInvocation.invalid_arguments_result("boom") == "Error: invalid arguments: boom"
    end

    # The reason is a TERM, not necessarily a binary: an exception struct
    # renders its message (never `Protocol.UndefinedError` from the
    # interpolation), any other term its `inspect/1`.
    test "renders an exception struct reason via its message instead of raising" do
      assert ToolInvocation.invalid_arguments_result(%RuntimeError{message: "boom"}) ==
               "Error: invalid arguments: boom"
    end

    test "renders a non-exception term reason via inspect/1 instead of raising" do
      assert ToolInvocation.invalid_arguments_result(:oops) == "Error: invalid arguments: :oops"

      assert ToolInvocation.invalid_arguments_result({:error, :oops}) ==
               "Error: invalid arguments: {:error, :oops}"
    end
  end

  # ---------------------------------------------------------------------------
  # shell_tool?/1
  # ---------------------------------------------------------------------------

  describe "shell_tool?/1" do
    test "is true for every spelling of the platform shell tool" do
      for name <- ~w(bash run_bash run_powershell pwsh powershell shell sh execute_bash
                     bash_command run_shell shell_command) do
        assert ToolInvocation.shell_tool?(name), "expected #{inspect(name)} to be a shell tool"
      end
    end

    test "matches case-insensitively" do
      assert ToolInvocation.shell_tool?("BASH")
      assert ToolInvocation.shell_tool?("Run_PowerShell")
    end

    test "is false for other tools" do
      for name <- ["read", "write", "grep", "edit", ""] do
        refute ToolInvocation.shell_tool?(name),
               "expected #{inspect(name)} not to be a shell tool"
      end
    end

    test "is false for nil and for an atom" do
      refute ToolInvocation.shell_tool?(nil)
      refute ToolInvocation.shell_tool?(:bash)
    end
  end

  # ---------------------------------------------------------------------------
  # default_timeout/2
  # ---------------------------------------------------------------------------

  describe "default_timeout/2" do
    test "uses the generous shell default when the configured default is lower" do
      assert ToolInvocation.default_timeout("bash", 10_000) == 120_000
    end

    test "is never lower than the configured default" do
      assert ToolInvocation.default_timeout("run_bash", 200_000) == 200_000
    end

    test "uses the shell default when the configured default is exactly it" do
      assert ToolInvocation.default_timeout("run_powershell", 120_000) == 120_000
    end

    test "uses the configured default exactly for a non-shell tool" do
      assert ToolInvocation.default_timeout("read", 10_000) == 10_000
      assert ToolInvocation.default_timeout("read", 200_000) == 200_000
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_timeout/4
  # ---------------------------------------------------------------------------

  describe "resolve_timeout/4 — explicit timeout" do
    test "uses an explicit timeout as-is, below both defaults" do
      assert ToolInvocation.resolve_timeout("read", %{"timeout" => 500}, 10_000, 300_000) == 500
    end

    test "clamps an explicit timeout above the configured maximum" do
      assert ToolInvocation.resolve_timeout("read", %{"timeout" => 999_000}, 10_000, 60_000) ==
               60_000
    end

    test "keeps an explicit timeout equal to the configured maximum" do
      assert ToolInvocation.resolve_timeout("read", %{"timeout" => 60_000}, 10_000, 60_000) ==
               60_000
    end
  end

  describe "resolve_timeout/4 — invalid explicit timeout is treated as absent" do
    test "falls back to the shell default for a string timeout on a shell tool" do
      assert ToolInvocation.resolve_timeout("bash", %{"timeout" => "9000"}, 10_000, 300_000) ==
               120_000
    end

    test "falls back to the shell default for a negative timeout on a shell tool" do
      assert ToolInvocation.resolve_timeout("bash", %{"timeout" => -5}, 10_000, 300_000) ==
               120_000
    end

    test "falls back to the shell default for a zero timeout on a shell tool" do
      assert ToolInvocation.resolve_timeout("bash", %{"timeout" => 0}, 10_000, 300_000) ==
               120_000
    end

    test "falls back to the configured default for a non-shell tool" do
      assert ToolInvocation.resolve_timeout("read", %{"timeout" => "9000"}, 10_000, 300_000) ==
               10_000

      assert ToolInvocation.resolve_timeout("read", %{"timeout" => 0}, 10_000, 300_000) ==
               10_000
    end

    test "treats raw string arguments as carrying no timeout" do
      assert ToolInvocation.resolve_timeout("bash", "not json{{", 10_000, 300_000) == 120_000
      assert ToolInvocation.resolve_timeout("read", "not json{{", 10_000, 300_000) == 10_000
    end

    test "treats nil arguments as carrying no timeout" do
      assert ToolInvocation.resolve_timeout("bash", nil, 10_000, 300_000) == 120_000
      assert ToolInvocation.resolve_timeout("read", nil, 10_000, 300_000) == 10_000
    end

    test "treats non-map arguments as carrying no timeout" do
      assert ToolInvocation.resolve_timeout("read", [timeout: 500], 10_000, 300_000) == 10_000
    end
  end

  describe "resolve_timeout/4 — omitted timeout" do
    test "clamps the shell default by the configured maximum" do
      assert ToolInvocation.resolve_timeout("bash", %{}, 10_000, 60_000) == 60_000
    end

    test "gives a shell tool the generous default when the maximum allows it" do
      assert ToolInvocation.resolve_timeout("bash", %{}, 10_000, 300_000) == 120_000
    end

    test "gives a shell tool its configured default when that is higher" do
      assert ToolInvocation.resolve_timeout("bash", %{}, 200_000, 300_000) == 200_000
    end

    test "gives a non-shell tool the configured default" do
      assert ToolInvocation.resolve_timeout("read", %{}, 10_000, 300_000) == 10_000
    end

    test "clamps a non-shell tool's configured default by the configured maximum" do
      assert ToolInvocation.resolve_timeout("read", %{}, 10_000, 5_000) == 5_000
    end
  end
end
