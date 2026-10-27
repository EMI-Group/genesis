defmodule EvoGit.Agent.Tools.FailureTest do
  @moduledoc """
  Unit tests for `EvoGit.Agent.Tools.Failure` — the shared tool-message SHAPE
  helper (`error/1,2`, `notice/1`, `format_reason/1`).

  Pins that error rendering is TOTAL: a REASON that is not a binary — most
  importantly a struct such as `%YamlElixir.ParsingError{}`, which a skill tool
  hands to `Failure.error/1` — renders as readable text instead of crashing the
  tool call with `Protocol.UndefinedError: protocol String.Chars not implemented
  for ...`. Binaries still pass through VERBATIM (the exact `Error: `-prefixed
  prose around them must not gain `inspect/1` quoting), exceptions render their
  `Exception.message/1`, and everything else its `inspect/1`.

  `async: true` is safe: `Failure` is pure (no git, no temp dirs, no app env, no
  ETS, no `:persistent_term`, no process state).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.Failure

  @parsing_error %YamlElixir.ParsingError{
    line: 2,
    column: 45,
    type: :block_mapping_value_not_allowed,
    message: "Block mapping value not allowed here"
  }

  describe "format_reason/1 — binaries" do
    test "passes a binary through VERBATIM (no inspect quoting)" do
      assert Failure.format_reason("boom") == "boom"
      assert Failure.format_reason("Skill 'x' not found") == "Skill 'x' not found"
      assert Failure.format_reason("") == ""
    end
  end

  describe "format_reason/1 — exceptions" do
    test "renders a YAML parser struct via Exception.message/1, without raising" do
      message = Failure.format_reason(@parsing_error)

      assert is_binary(message)
      assert message =~ "Block mapping value not allowed here"
      # The parser's own `message/1` appends the position.
      assert message =~ "line: 2"
      assert message == Exception.message(@parsing_error)
    end

    test "renders a RuntimeError as its message" do
      assert Failure.format_reason(%RuntimeError{message: "boom"}) == "boom"
    end
  end

  describe "format_reason/1 — arbitrary terms" do
    test "renders a non-exception struct with inspect/1" do
      assert Failure.format_reason(%URI{}) == inspect(%URI{})
      assert Failure.format_reason(%{a: 1}) == "%{a: 1}"
    end

    test "renders tuples, keywords, atoms and numbers with inspect/1" do
      assert Failure.format_reason({:error, :boom}) == "{:error, :boom}"
      assert Failure.format_reason(reason: :boom) == "[reason: :boom]"
      assert Failure.format_reason(:oops) == ":oops"
      assert Failure.format_reason(42) == "42"
      assert Failure.format_reason(nil) == "nil"
    end
  end

  describe "error/1 — non-binary reasons never raise" do
    test "renders an exception struct behind the Error: prefix" do
      rendered = Failure.error(@parsing_error)

      assert is_binary(rendered)
      assert String.starts_with?(rendered, "Error: ")
      assert rendered =~ "Block mapping value not allowed here"
      refute rendered =~ "%YamlElixir.ParsingError"
    end

    test "renders arbitrary terms behind the Error: prefix" do
      assert Failure.error(:oops) == "Error: :oops"
      assert Failure.error({:error, :boom}) == "Error: {:error, :boom}"
    end
  end

  describe "notice/1 — non-binary reasons never raise" do
    test "renders an exception struct as a blank-line-separated block" do
      rendered = Failure.notice(@parsing_error)

      assert is_binary(rendered)
      assert rendered == "\n\n" <> Exception.message(@parsing_error)
    end

    test "renders arbitrary terms as a blank-line-separated block" do
      assert Failure.notice(:oops) == "\n\n:oops"
    end
  end

  describe "error/1 — binary behaviour is unchanged" do
    test "prefixes a plain message" do
      assert Failure.error("boom") == "Error: boom"
    end

    test "is idempotent for an already-prefixed message" do
      assert Failure.error("Error: boom") == "Error: boom"
      assert Failure.error(Failure.error("boom")) == "Error: boom"
    end

    test "canonicalizes an unspaced Error: prefix" do
      assert Failure.error("Error:boom") == "Error: boom"
    end

    test "strips leading markers" do
      assert Failure.error("⚠️ boom") == "Error: boom"
      assert Failure.error("[NOTICE] boom") == "Error: boom"
      assert Failure.error("💡 [WARNING] boom") == "Error: boom"
    end

    test "falls back to a default text for an empty message" do
      assert Failure.error("") == "Error: the tool call failed."
      assert Failure.error("   \n\t") == "Error: the tool call failed."
    end

    test "error/2 appends the guidance block" do
      assert Failure.error("boom", "try again") == "Error: boom\n\ntry again"
      assert Failure.error("boom", "") == "Error: boom"
    end
  end

  describe "notice/1 — binary behaviour is unchanged" do
    test "blank-line separates a non-empty guidance block" do
      assert Failure.notice("try again") == "\n\ntry again"
    end

    test "strips leading markers" do
      assert Failure.notice("⚠️ try again") == "\n\ntry again"
    end

    test "returns an empty string for empty guidance" do
      assert Failure.notice("") == ""
      assert Failure.notice("   ") == ""
    end

    test "is idempotent: a second call adds no further blank line" do
      assert Failure.notice(Failure.notice("x")) == "\n\nx"
    end
  end
end
