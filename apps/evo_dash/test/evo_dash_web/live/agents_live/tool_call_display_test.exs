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

  describe "background shell call detection" do
    # A `bash` call carrying `run_in_background: true` starts a DETACHED job
    # (the call returns a job id immediately) — it must be distinguishable from
    # a foreground shell call, which keeps the plain `Shell call` descriptor.
    test "a JSON boolean `true` yields the background variant" do
      descriptor =
        ToolCallDisplay.display(
          call("bash", %{"command" => "npm run dev", "run_in_background" => true})
        )

      assert descriptor.kind == :structured
      assert descriptor.variant == :background_shell
      assert descriptor.label == "Background shell call"
      assert descriptor.rows == [{"Command", "npm run dev"}]
    end

    test "the string \"true\" is accepted (the core's lenient reading)" do
      descriptor =
        ToolCallDisplay.display(
          call("bash", %{"command" => "npm run dev", "run_in_background" => "true"})
        )

      assert descriptor.variant == :background_shell
      assert descriptor.label == "Background shell call"
      assert row_value(descriptor) == "npm run dev"
    end

    test "map-shaped arguments (not a JSON string) are detected too" do
      map_call = %ReqLLM.ToolCall{
        id: "c",
        function: %{
          name: "bash",
          arguments: %{"command" => "make", "run_in_background" => true}
        }
      }

      assert %{variant: :background_shell, label: "Background shell call"} =
               ToolCallDisplay.display(map_call)
    end

    test "false, \"false\", absent and junk values all stay a normal Shell call" do
      for args <- [
            %{"command" => "ls", "run_in_background" => false},
            %{"command" => "ls", "run_in_background" => "false"},
            %{"command" => "ls"},
            %{"command" => "ls", "run_in_background" => "yes"},
            %{"command" => "ls", "run_in_background" => 1},
            %{"command" => "ls", "run_in_background" => nil}
          ] do
        descriptor = ToolCallDisplay.display(call("bash", args))

        assert descriptor.label == "Shell call"
        assert descriptor.kind == :structured
        assert row_value(descriptor) == "ls"
        # The historical descriptor shape stays byte-identical (no :variant key).
        refute Map.has_key?(descriptor, :variant)
      end
    end

    test "undecodable arguments fall back to a normal Shell call" do
      raw_call = %ReqLLM.ToolCall{id: "c", function: %{name: "bash", arguments: "not json"}}

      descriptor = ToolCallDisplay.display(raw_call)

      assert descriptor.label == "Shell call"
      refute Map.has_key?(descriptor, :variant)
    end

    test "the flag only affects the shell tool" do
      descriptor =
        ToolCallDisplay.display(call("read", %{"path" => "./a.ex", "run_in_background" => true}))

      assert descriptor == %{label: "read_file", kind: :inline, summary: "./a.ex"}
    end

    test "the background variant keeps the 200-char Command truncation contract" do
      cmd = String.duplicate("x", 260)

      descriptor =
        ToolCallDisplay.display(call("bash", %{"command" => cmd, "run_in_background" => true}))

      assert row_value(descriptor) == String.slice(cmd, 0, 200) <> "…"
    end
  end

  describe "display/1 truncation (compact mode)" do
    test "a shell call's Command row is capped at 200 chars plus a trailing ellipsis" do
      cmd = String.duplicate("x", 260)

      descriptor = ToolCallDisplay.display(shell_call(cmd))

      assert descriptor.kind == :structured
      assert descriptor.label == "Shell call"
      assert row_value(descriptor) == String.slice(cmd, 0, 200) <> "…"
    end

    test "a command at exactly the 200-char cap is left untouched" do
      cmd = String.duplicate("x", 200)

      descriptor = ToolCallDisplay.display(shell_call(cmd))

      assert row_value(descriptor) == cmd
      refute String.ends_with?(row_value(descriptor), "…")
    end
  end

  describe "display/2 mode: :full (uncapped)" do
    test "the complete command is returned with no trailing ellipsis" do
      cmd = String.duplicate("x", 260)

      descriptor = ToolCallDisplay.display(shell_call(cmd), mode: :full)

      assert descriptor.kind == :structured
      assert descriptor.label == "Shell call"
      assert row_value(descriptor) == cmd
      refute String.ends_with?(row_value(descriptor), "…")
    end
  end

  describe "display/2 mode fallback (unknown / nil / non-keyword opts -> compact)" do
    test "an unknown :mode, a nil :mode and a non-keyword opts map all equal display/1" do
      cmd = String.duplicate("x", 260)
      call = shell_call(cmd)

      compact = ToolCallDisplay.display(call)

      # Only `mode: :full` opts into full mode; every other opts shape resolves
      # to the compact default.
      assert ToolCallDisplay.display(call, mode: :bogus) == compact
      assert ToolCallDisplay.display(call, mode: nil) == compact
      assert ToolCallDisplay.display(call, %{mode: :full}) == compact
      assert ToolCallDisplay.display(call, nil) == compact
      assert ToolCallDisplay.display(call, []) == compact
      assert ToolCallDisplay.display(call, [:mode]) == compact
    end
  end

  describe "display/2 totality" do
    test "nil and an empty map never raise and always carry a :label and :kind" do
      for call <- [nil, %{}] do
        descriptor = ToolCallDisplay.display(call)

        assert is_binary(descriptor.label)
        assert descriptor.kind in [:structured, :inline]
      end
    end
  end

  describe "alias-aware names (model-facing -> previous rendering)" do
    test "read renders as the historical read_file inline path row" do
      descriptor = ToolCallDisplay.display(call("read", %{"path" => "./lib/app.ex"}))

      assert descriptor == %{label: "read_file", kind: :inline, summary: "./lib/app.ex"}
    end

    test "edit renders as the historical edit_file inline label" do
      descriptor = ToolCallDisplay.display(call("edit", %{"path" => "./lib/app.ex"}))

      assert descriptor.label == "edit_file"
      assert descriptor.kind == :inline
      assert descriptor.summary == "./lib/app.ex"
    end

    test "write renders as the historical write_file inline label" do
      descriptor = ToolCallDisplay.display(call("write", %{"path" => "./lib/new.ex"}))

      assert descriptor.label == "write_file"
      assert descriptor.kind == :inline
      assert descriptor.summary == "./lib/new.ex"
    end

    test "bash renders as a Shell call with a Command row" do
      cmd = "mix test apps/evo_dash/test"

      descriptor = ToolCallDisplay.display(call("bash", %{"command" => cmd}))

      assert descriptor.label == "Shell call"
      assert descriptor.kind == :structured
      assert row_value(descriptor) == cmd
    end

    test "Bash (capitalized) is a shell call too" do
      descriptor = ToolCallDisplay.display(call("Bash", %{"command" => "ls -la"}))

      assert descriptor.label == "Shell call"
      assert descriptor.kind == :structured
      assert row_value(descriptor) == "ls -la"
    end

    test "web_search renders as the historical search_web inline label" do
      descriptor = ToolCallDisplay.display(call("web_search", %{"query" => "elixir genserver"}))

      assert descriptor.label == "search_web"
      assert descriptor.kind == :inline
      assert descriptor.summary == ~s({"query":"elixir genserver"})
    end

    test "rg and glob keep their own names" do
      assert %{label: "rg"} = ToolCallDisplay.display(call("rg", %{"pattern" => "TODO"}))
      assert %{label: "glob"} = ToolCallDisplay.display(call("glob", %{"pattern" => "**/*.ex"}))
    end

    test "a legacy read_file call still labels read_file" do
      descriptor = ToolCallDisplay.display(call("read_file", %{"path" => "./lib/app.ex"}))

      assert descriptor == %{label: "read_file", kind: :inline, summary: "./lib/app.ex"}
    end

    test "an unknown/custom tool name passes through unchanged" do
      descriptor =
        ToolCallDisplay.display(call("my_custom_tool", %{"path" => "./lib/app.ex"}))

      assert descriptor.label == "my_custom_tool"
      assert descriptor.kind == :inline
      assert descriptor.summary == "./lib/app.ex"
    end

    test "the accepted subagent alias spellings render as structured subagent rows" do
      args = %{"path" => "./lib", "objective" => "Investigate the store"}

      for name <- ["subagent_manager", "subagent", "task"] do
        descriptor = ToolCallDisplay.display(call(name, args))

        assert descriptor.kind == :structured
        # The label is the normalized internal key (`subagent_manager`).
        assert descriptor.label == "subagent_manager"
        assert descriptor.rows == [{"Path", "./lib"}, {"Objective", "Investigate the store"}]
      end
    end

    test "a non-binary name falls back to the unknown label" do
      descriptor = ToolCallDisplay.display(%{name: nil})

      assert descriptor.label == "unknown"
      assert descriptor.kind == :inline
    end
  end
end
