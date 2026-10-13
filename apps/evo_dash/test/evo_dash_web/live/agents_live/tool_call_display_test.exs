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

  # Reads the single structured row value of a descriptor (the row KEY is a
  # localized msgid, so match by position rather than by label text).
  defp row_value(%{rows: [{_key, value}]}), do: value

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
end
