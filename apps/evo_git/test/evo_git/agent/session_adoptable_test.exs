defmodule EvoGit.Agent.SessionAdoptableTest.AdoptionAgent do
  @moduledoc """
  The role the synthetic `%EvoGit.Agent.State{}` values name.

  The adoption rule is a PURE function over two states, so nothing is ever
  dispatched against this module — it only has to satisfy `%State{}`'s
  `:agent_module` enforce key.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the session adoption-rule stub agent."

  @doc "No tools: no schema is ever offered or dispatched."
  def available_tools, do: []
end

defmodule EvoGit.Agent.SessionAdoptableTest do
  @moduledoc """
  Unit contract for `EvoGit.Agent.Session.adoptable?/2` — the session's
  stale/duplicate guard for a checkpointed worker `%State{}`.

  It is `@doc false` + public ONLY so this rule is testable without a live
  `gen_statem`: an UNTESTED rule here either loses a turn of work (a rejected
  real checkpoint) or accepts a stale one (a duplicate write / lost update).

  ## The rule being pinned

    * an ADVANCING turn always wins — even when the transcript shrank
      (compression) or the incoming state carries a marker;
    * an OLDER turn never wins;
    * at an EQUAL turn the checkpoint is normally a duplicate and is IGNORED,
      with exactly ONE narrow exception: closing an in-flight tool batch. The
      turn is incremented BEFORE the batch runs (so the pre-batch checkpoint
      lands on the same turn as the batch-completion one), and the exception
      therefore requires ALL THREE of: the ADOPTED state carries the marker, the
      INCOMING state has cleared it, and the transcript GREW;
    * totality: anything that is not a `%State{}` on either side is `false`.

  Every negative arm is asserted explicitly: a guard test that only proves the
  accepting arms would pass for a blanket `true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.SessionAdoptableTest.AdoptionAgent

  # The pre-batch state's marker: two calls of the turn that is executing.
  defp marker(turn \\ 4) do
    ToolBatch.build(
      [%{id: "call_read", name: "read"}, %{id: "call_bash", name: "bash"}],
      turn,
      []
    )
  end

  describe "an advancing turn" do
    test "is always adopted" do
      assert Session.adoptable?(state(turn: 1, messages: 3), state(turn: 2, messages: 3))
      assert Session.adoptable?(state(turn: 1, messages: 3), state(turn: 3, messages: 9))
    end

    test "is adopted even when the transcript SHRANK (compression)" do
      # A later turn that compressed the context is still the newer truth.
      assert Session.adoptable?(state(turn: 4, messages: 40), state(turn: 5, messages: 6))
    end

    test "is adopted even when the INCOMING state still carries a marker" do
      # The marker only matters at an EQUAL turn; an advancing turn wins whole.
      assert Session.adoptable?(
               state(turn: 4, messages: 3, batch: marker()),
               state(turn: 5, messages: 5, batch: marker(5))
             )
    end
  end

  describe "an older or equal turn that does NOT close a batch" do
    test "an older turn is never adopted" do
      refute Session.adoptable?(state(turn: 5, messages: 5), state(turn: 4, messages: 9))
    end

    test "an older turn is rejected even when it carries a marker and grew" do
      refute Session.adoptable?(
               state(turn: 5, messages: 3),
               state(turn: 4, messages: 9, batch: marker(4))
             )
    end

    test "an EQUAL turn without a marker on the adopted state is a duplicate" do
      # The common case: the same turn checkpointed twice with no batch open.
      refute Session.adoptable?(state(turn: 4, messages: 3), state(turn: 4, messages: 3))
      # …and even a growing transcript does not make it adoptable without the
      # marker: the exception is ONLY about closing a tool batch.
      refute Session.adoptable?(state(turn: 4, messages: 3), state(turn: 4, messages: 9))
    end

    test "an EQUAL turn whose INCOMING state still carries a marker is not a close" do
      # A batch that is still executing must never be treated as finished, even
      # when a (bogus) transcript growth comes with it.
      refute Session.adoptable?(
               state(turn: 4, messages: 3, batch: marker()),
               state(turn: 4, messages: 9, batch: marker())
             )
    end
  end

  describe "an equal turn that CLOSES the in-flight tool batch" do
    test "is adopted when the adopted state has the marker, the incoming one cleared it, and the transcript grew" do
      assert Session.adoptable?(
               state(turn: 4, messages: 3, batch: marker()),
               state(turn: 4, messages: 5)
             )
    end

    test "is rejected when the transcript did NOT grow" do
      # Clearing the marker without adding the tool results is not a close.
      refute Session.adoptable?(
               state(turn: 4, messages: 3, batch: marker()),
               state(turn: 4, messages: 3)
             )
    end

    test "is rejected when the transcript SHRANK" do
      refute Session.adoptable?(
               state(turn: 4, messages: 5, batch: marker()),
               state(turn: 4, messages: 3)
             )
    end

    test "is adopted for an exact, explainable growth of one message" do
      # Boundary: growth of exactly ONE message is still growth.
      assert Session.adoptable?(
               state(turn: 4, messages: 3, batch: marker()),
               state(turn: 4, messages: 4)
             )
    end
  end

  describe "totality" do
    test "a non-%State{} on either side is never adopted" do
      valid = state(turn: 4, messages: 3)

      refute Session.adoptable?(nil, valid)
      refute Session.adoptable?(valid, nil)
      refute Session.adoptable?(nil, nil)
      refute Session.adoptable?(:not_a_state, valid)
      refute Session.adoptable?(valid, "not a state")

      # A map with an ADVANCING turn is still not a state: the guard is
      # structural, so a hand-built map can never sneak past it.
      refute Session.adoptable?(%{turn: 4, context: nil}, %{turn: 9, context: nil})
      refute Session.adoptable?(%{turn: 1}, valid)
    end

    test "a malformed context counts as an EMPTY transcript" do
      # `transcript_size/1` is total: a non-list context is size 0, so closing a
      # batch from 0 → 5 messages is still growth (and a raise here would crash
      # the session process).
      broken = %{state(turn: 4, messages: 2, batch: marker()) | context: nil}

      assert Session.adoptable?(broken, state(turn: 4, messages: 5))
      # …while the reverse direction is not growth.
      refute Session.adoptable?(
               %{state(turn: 4, messages: 2, batch: marker()) | context: %ReqLLM.Context{}},
               state(turn: 4, messages: 0)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp state(opts) do
    %State{
      agent_id: 1,
      agent_module: AdoptionAgent,
      depth: 0,
      node_path: "./",
      context: context(Keyword.fetch!(opts, :messages)),
      turn: Keyword.get(opts, :turn, 0),
      persistent_state: true,
      pending_tool_batch: Keyword.get(opts, :batch)
    }
  end

  # N user messages: only the COUNT matters to the adoption rule.
  defp context(0), do: ReqLLM.Context.new([])

  defp context(count) do
    ReqLLM.Context.new(
      Enum.map(1..count, fn index ->
        ReqLLM.Context.user("adoption fixture message #{index}")
      end)
    )
  end
end
