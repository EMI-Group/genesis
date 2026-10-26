defmodule EvoDashWeb.AgentsLive.ToolCallDisplayTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.ToolCallDisplay — the rendering
  contract for tool-call messages in the Agents page chat-history viewer.

  These are pure data-transformation functions operating on plain tool-call
  maps — no LiveView, Phoenix socket, or DB setup is required.

  The tests run in the default `:en` locale, so the English msgids
  (`"Shell call"`) are asserted directly.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.ToolCallDisplay

  @long String.duplicate("x", 260)
  @capped String.duplicate("x", 200)

  # A shell tool call (`run_bash`) whose `command` argument is `cmd`.
  defp shell_call(cmd) do
    %ReqLLM.ToolCall{
      id: "c",
      function: %{name: "run_bash", arguments: Jason.encode!(%{"command" => cmd})}
    }
  end

  # A tool call for the model-facing name `name` with the given argument map.
  defp call(name, args) do
    %ReqLLM.ToolCall{id: "c", function: %{name: name, arguments: Jason.encode!(args)}}
  end

  # Reads the single structured row value of a descriptor (the row KEY is a
  # localized msgid, so match by position rather than by label text).
  defp row_value(%{rows: [{_key, value}]}), do: value

  describe "background shell calls" do
    # A `bash` call carrying `run_in_background: true` starts a DETACHED job
    # (the call returns a job id immediately) — it must be distinguishable from
    # a foreground shell call, which keeps the plain `Shell call` descriptor.
    test "a JSON boolean, the string \"true\" and map-shaped arguments all yield the background variant" do
      map_call = %ReqLLM.ToolCall{
        id: "c",
        function: %{
          name: "bash",
          arguments: %{"command" => "npm run dev", "run_in_background" => true}
        }
      }

      rows = [
        {call("bash", %{"command" => "npm run dev", "run_in_background" => true}), "npm run dev"},
        {call("bash", %{"command" => "npm run dev", "run_in_background" => "true"}),
         "npm run dev"},
        {map_call, "npm run dev"},
        # The background variant keeps the 200-char Command truncation contract.
        {call("bash", %{"command" => @long, "run_in_background" => true}),
         String.slice(@long, 0, 200) <> "…"}
      ]

      for {tool_call, expected_row} <- rows do
        descriptor = ToolCallDisplay.display(tool_call)

        assert {descriptor.kind, descriptor.variant, descriptor.label, row_value(descriptor)} ===
                 {:structured, :background_shell, "Background shell call", expected_row}
      end
    end

    test "false, junk and undecodable arguments all stay a normal Shell call" do
      args = [
        %{"command" => "ls", "run_in_background" => false},
        %{"command" => "ls", "run_in_background" => "false"},
        %{"command" => "ls"},
        %{"command" => "ls", "run_in_background" => "yes"},
        %{"command" => "ls", "run_in_background" => 1},
        %{"command" => "ls", "run_in_background" => nil}
      ]

      rows =
        [
          {%ReqLLM.ToolCall{id: "c", function: %{name: "bash", arguments: "not json"}},
           "not json"}
          | for(args <- args, do: {call("bash", args), "ls"})
        ]

      for {tool_call, expected_row} <- rows do
        descriptor = ToolCallDisplay.display(tool_call)

        # The historical descriptor shape stays byte-identical (no :variant key).
        assert {descriptor.label, descriptor.kind, row_value(descriptor),
                Map.has_key?(descriptor, :variant)} ===
                 {"Shell call", :structured, expected_row, false}
      end
    end

    test "the flag only affects the shell tool" do
      descriptor =
        ToolCallDisplay.display(call("read", %{"path" => "./a.ex", "run_in_background" => true}))

      assert descriptor == %{label: "read_file", kind: :inline, summary: "./a.ex"}
    end
  end

  describe "display/1 compact truncation and display/2 mode :full" do
    test "compact caps a Command row at 200 chars plus an ellipsis; :full never caps" do
      rows = [
        {[], @long, String.slice(@long, 0, 200) <> "…", true},
        # A command at exactly the 200-char cap is left untouched.
        {[], @capped, @capped, false},
        {[mode: :full], @long, @long, false}
      ]

      for {opts, cmd, expected, ellipsis?} <- rows do
        descriptor = ToolCallDisplay.display(shell_call(cmd), opts)

        assert {descriptor.kind, descriptor.label, row_value(descriptor),
                String.ends_with?(row_value(descriptor), "…")} ===
                 {:structured, "Shell call", expected, ellipsis?}
      end
    end

    test "an unknown :mode, a nil :mode and a non-keyword opts map all equal display/1" do
      tool_call = shell_call(@long)
      compact = ToolCallDisplay.display(tool_call)

      # Only `mode: :full` opts into full mode; every other opts shape resolves
      # to the compact default.
      for opts <- [[mode: :bogus], [mode: nil], %{mode: :full}, nil, [], [:mode]] do
        assert ToolCallDisplay.display(tool_call, opts) == compact
      end
    end

    test "nil and an empty map never raise and always carry a :label and :kind" do
      for tool_call <- [nil, %{}] do
        descriptor = ToolCallDisplay.display(tool_call)

        assert {is_binary(descriptor.label), descriptor.kind in [:structured, :inline]} ===
                 {true, true}
      end
    end
  end

  describe "alias-aware names (model-facing -> previous rendering)" do
    test "file and search tools render as their historical inline rows" do
      path = "./lib/app.ex"

      rows = [
        {"read", %{"path" => path}, %{label: "read_file", kind: :inline, summary: path}},
        {"read_file", %{"path" => path}, %{label: "read_file", kind: :inline, summary: path}},
        {"edit", %{"path" => path}, %{label: "edit_file", kind: :inline, summary: path}},
        {"write", %{"path" => "./lib/new.ex"},
         %{label: "write_file", kind: :inline, summary: "./lib/new.ex"}},
        {"web_search", %{"query" => "elixir genserver"},
         %{label: "search_web", kind: :inline, summary: ~s({"query":"elixir genserver"})}},
        {"rg", %{"pattern" => "TODO"},
         %{label: "rg", kind: :inline, summary: ~s({"pattern":"TODO"})}},
        {"glob", %{"pattern" => "**/*.ex"},
         %{label: "glob", kind: :inline, summary: ~s({"pattern":"**/*.ex"})}},
        {"my_custom_tool", %{"path" => path},
         %{label: "my_custom_tool", kind: :inline, summary: path}}
      ]

      for {name, args, expected} <- rows do
        assert ToolCallDisplay.display(call(name, args)) == expected
      end
    end

    test "shell tools render as a Shell call with a Command row" do
      for {name, cmd} <- [
            {"bash", "mix test apps/evo_dash/test"},
            {"Bash", "ls -la"},
            {"run_bash", "ls"}
          ] do
        descriptor = ToolCallDisplay.display(call(name, %{"command" => cmd}))

        assert {descriptor.label, descriptor.kind, row_value(descriptor)} ===
                 {"Shell call", :structured, cmd}
      end
    end

    test "the accepted subagent alias spellings render as structured subagent rows" do
      args = %{"path" => "./lib", "objective" => "Investigate the store"}
      expected = [{"Path", "./lib"}, {"Objective", "Investigate the store"}]

      for name <- ["subagent_manager", "subagent", "task"] do
        descriptor = ToolCallDisplay.display(call(name, args))

        # The label is the normalized internal key (`subagent_manager`).
        assert {descriptor.kind, descriptor.label, descriptor.rows} ===
                 {:structured, "subagent_manager", expected}
      end
    end

    test "a non-binary name falls back to the unknown label" do
      descriptor = ToolCallDisplay.display(%{name: nil})

      assert {descriptor.label, descriptor.kind} === {"unknown", :inline}
    end
  end
end
