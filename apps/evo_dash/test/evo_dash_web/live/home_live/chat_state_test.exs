defmodule EvoDashWeb.HomeLive.ChatStateTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.HomeLive.Transcript

  # Unit tests for the persisted chat-state shape (ChatState.build/1 → persist,
  # ChatState.restore/1 → mount). Both directions are TOTAL: persisted garbage
  # degrades to safe defaults, never raises.

  @default_state %{
    transcript: [],
    chat_draft: "",
    chat_status: :idle,
    chat_task_id: nil,
    chat_agent_id: nil,
    agent_message_count: nil,
    chat_task_status: nil,
    chat_node: nil,
    selected_model_id: nil,
    thought_process: []
  }

  @thought_entry %{turn: 1, timestamp: 1_700_000_000, type: "tool", data: %{content: "r"}}

  describe "build/1" do
    test "extracts every persisted field from assigns" do
      entry = Transcript.entry(:user, "hi")

      assigns = %{
        transcript: [entry],
        chat_draft: "draft",
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: 7,
        agent_message_count: 3,
        chat_task_status: :running,
        chat_node: :node@host,
        selected_model_id: "profile-a",
        thought_process: [@thought_entry]
      }

      assert ChatState.build(assigns) == assigns
    end

    test "missing keys and nil values degrade to the safe defaults" do
      assert ChatState.build(%{}) == @default_state

      assert ChatState.build(%{
               transcript: nil,
               chat_draft: nil,
               chat_status: nil,
               thought_process: nil
             }) == @default_state
    end
  end

  describe "restore/1" do
    test "restores a fully-populated state map unchanged" do
      entry = Transcript.entry(:assistant, "text")

      state = %{
        transcript: [entry],
        chat_draft: "draft",
        chat_status: :cancelling,
        chat_task_id: "t1",
        chat_agent_id: 7,
        agent_message_count: 2,
        chat_task_status: :cancelling,
        chat_node: :node@host,
        selected_model_id: "profile-a",
        thought_process: [@thought_entry]
      }

      assert ChatState.restore(state) == state
    end

    test "non-map state and malformed fields degrade to the empty default per key" do
      for garbage <- [nil, "x", 42, [:a], %{}] do
        assert ChatState.restore(garbage) == @default_state,
               "expected defaults for #{inspect(garbage)}"
      end

      assert ChatState.restore(%{
               transcript: "not a list",
               chat_draft: 42,
               chat_status: :bogus,
               chat_task_id: 42,
               # chat_agent_id is deliberately NOT validated (arbitrary term).
               chat_agent_id: "kept-as-is",
               agent_message_count: -1,
               chat_task_status: :weird,
               chat_node: "not-an-atom",
               thought_process: "nope"
             }) == %{@default_state | chat_agent_id: "kept-as-is"}
    end

    test "empty-string task id degrades to nil; selected_model_id is normalized" do
      assert ChatState.restore(%{chat_task_id: ""}).chat_task_id == nil
      assert ChatState.restore(%{chat_task_id: "ok"}).chat_task_id == "ok"

      for {stored, expected} <- [{"p1", "p1"}, {"", nil}, {nil, nil}] do
        assert ChatState.restore(%{selected_model_id: stored}).selected_model_id == expected
      end

      assert ChatState.restore(%{}).selected_model_id == nil
    end

    test "nested transcript and thought_process entries are normalized" do
      restored =
        ChatState.restore(%{
          transcript: [
            %{id: 7, role: "user", text: 123, streaming: "yes"},
            :junk,
            %{role: :weird, text: nil},
            %{id: nil, role: :assistant, text: "x"}
          ]
        })

      [e1, e2, e3] = restored.transcript
      assert {e1.id, e1.role, e1.text, e1.streaming} == {"7", :user, "123", false}
      # Unknown roles keep the entry visible, left-aligned.
      assert {e2.role, e2.text} == {:assistant, ""}
      # nil id gets a fresh unique id.
      assert e3.id != "" and e3.role == :assistant

      assert ChatState.restore(%{
               thought_process: [
                 %{turn: "x", type: :tool, data: %{k: 1}},
                 :junk,
                 %{turn: 3, type: "assistant", data: "bad"}
               ]
             }).thought_process == [
               %{turn: 0, timestamp: nil, type: "tool", data: %{k: 1}},
               %{turn: 3, timestamp: nil, type: "assistant", data: %{}}
             ]
    end
  end

  describe "provider-profile selection persistence" do
    test "round-trips only picker fields, never the credential-bearing snapshot or bundle" do
      scope = {nil, node()}

      spec = %{
        "provider_profile_id" => "work-account",
        "model" => "reasoned-model",
        "reasoning_effort" => "high"
      }

      state =
        ChatState.build(%{
          model_spec: spec,
          model_selection_scope: scope,
          selected_model_id: "obsolete-id",
          model_snapshot: %{config: %{api_key: "secret"}},
          model_selection_bundle: %{config: %{api_key: "secret"}},
          provider_profiles: [%{"api_key" => "secret"}],
          model_selections: [%{model: "reasoned-model"}],
          model_select_loading: true,
          model_select_seq: 7,
          model_select_load_error: :unavailable
        })

      expected =
        Map.merge(@default_state, %{
          model_spec: spec,
          model_selection_scope: scope,
          model_selection_error: nil
        })

      assert state == expected
      assert ChatState.restore(state) == expected
      assert ChatState.restore_selection(state, scope) == Map.take(expected, selection_keys())
    end

    test "nil is uninitialized, an empty map is explicit Auto, and neither is malformed" do
      scope = {nil, node()}

      for spec <- [nil, %{}] do
        state = ChatState.build(%{model_spec: spec, model_selection_scope: scope})
        restored = ChatState.restore(state)
        assert restored.model_spec == spec
        assert restored.model_selection_error == nil
        assert ChatState.restore_selection(restored, scope).model_spec == spec
      end

      auto = ChatState.build(%{model_spec: %{}, selected_model_id: "old-pin"})
      assert auto.selected_model_id == nil
      assert ChatState.restore(auto).model_spec == %{}
    end

    test "malformed specs remain errors across repeated persistence, never becoming Auto" do
      scope = {nil, node()}

      for spec <- [
            false,
            "work-account",
            [],
            %{"model" => 42},
            %{provider_profile_id: "work-account"},
            %{"provider_profile_id" => "work-account", "api_key" => "secret"}
          ] do
        state =
          ChatState.build(%{
            model_spec: spec,
            model_selection_scope: scope,
            selected_model_id: "old-pin"
          })

        expected = %{
          model_spec: nil,
          model_selection_scope: scope,
          model_selection_error: :invalid_model_spec,
          selected_model_id: nil
        }

        assert Map.take(state, selection_keys()) == expected
        assert ChatState.restore_selection(state, scope) == expected

        # A normalized nil spec must not erase the error on the next save/mount.
        assert state |> ChatState.restore() |> ChatState.build() |> ChatState.restore() == state
      end
    end

    test "persistence validates shape only, leaving defaults and stale membership to the resolver" do
      scope = {nil, node()}

      for spec <- [
            %{"provider_profile_id" => "removed-account"},
            %{"provider_profile_id" => "", "model" => ""},
            %{"model" => "removed-model", "reasoning_effort" => "unsupported"}
          ] do
        state = ChatState.build(%{model_spec: spec, model_selection_scope: scope})
        assert state.model_spec == spec
        assert state.model_selection_error == nil
        assert ChatState.restore_selection(state, scope).model_spec == spec
      end
    end
  end

  describe "restore_selection/2 node scoping and legacy migration" do
    test "a saved choice survives only the exact target-id and BEAM-node pair" do
      scope = {"server-a", :assistant_remote@host}

      state = %{
        model_spec: %{"provider_profile_id" => "work-account", "model" => "fast-model"},
        model_selection_scope: scope
      }

      assert ChatState.restore_selection(state, scope) ==
               Map.merge(state, %{selected_model_id: nil, model_selection_error: nil})

      for other_scope <- [
            {nil, node()},
            {"server-b", :assistant_remote@host},
            {"server-a", :replacement@host},
            # Disconnected targets share a local fallback node but NOT an id.
            {"server-a", node()}
          ] do
        assert ChatState.restore_selection(state, other_scope) == empty_selection(other_scope)
      end
    end

    test "pending remote ids do not borrow each other's or the local pin" do
      scope = {"pending-a", node()}
      state = %{model_spec: %{}, model_selection_scope: scope}
      assert ChatState.restore_selection(state, scope).model_spec == %{}

      assert ChatState.restore_selection(state, {"pending-b", node()}) ==
               empty_selection({"pending-b", node()})

      assert ChatState.restore_selection(state, {nil, node()}) == empty_selection({nil, node()})
    end

    test "unscoped legacy ids migrate locally only, without inventing a canonical spec" do
      for id <- ["legacy:account:with:colons", "removed-id"] do
        state = %{selected_model_id: id}
        restored = ChatState.restore(state)
        refute Map.has_key?(restored, :model_spec)
        refute Map.has_key?(restored, :model_selection_scope)

        assert ChatState.restore_selection(restored, {nil, node()}) ==
                 %{empty_selection({nil, node()}) | selected_model_id: id}

        for scope <- [{"remote", :assistant_remote@host}, {"pending", node()}] do
          assert ChatState.restore_selection(restored, scope) == empty_selection(scope)
        end
      end
    end

    test "an explicit unscoped spec cannot use the legacy-local migration exception" do
      state = %{model_spec: %{}, selected_model_id: "legacy-id"}
      assert ChatState.restore_selection(state, {nil, node()}) == empty_selection({nil, node()})
    end

    test "malformed scopes and non-map state cannot restore a pin" do
      for scope <- [nil, "remote", {"", node()}, {false, node()}, {nil, nil}, {nil, "node"}] do
        state = %{model_spec: %{}, model_selection_scope: scope, selected_model_id: "legacy-id"}
        assert ChatState.restore_selection(state, scope) == empty_selection(nil)
        assert ChatState.restore(state).model_selection_scope == nil
      end

      for state <- [nil, false, 42, [], "garbage"] do
        assert ChatState.restore_selection(state, {nil, node()}) == empty_selection({nil, node()})
      end
    end
  end

  defp selection_keys do
    [:model_spec, :selected_model_id, :model_selection_scope, :model_selection_error]
  end

  defp empty_selection(scope) do
    %{
      model_spec: nil,
      selected_model_id: nil,
      model_selection_scope: scope,
      model_selection_error: nil
    }
  end

  describe "normalize_model_id/1" do
    test "non-empty legacy ids are kept as migration input; everything else becomes nil" do
      # This validates shape, not membership: nil is uninitialized, not explicit
      # Auto (%{}). Whitespace ids survive for the resolver to reject.
      for {input, expected} <- [
            {nil, nil},
            {"", nil},
            {42, nil},
            {"profile-a", "profile-a"},
            {"  ", "  "}
          ] do
        assert ChatState.normalize_model_id(input) == expected,
               "expected #{inspect(expected)} for #{inspect(input)}"
      end
    end
  end
end
