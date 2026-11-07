defmodule EvoDashWeb.ProjectsLive.ModelSelectionPersistenceTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.{Project, StatePersistence}

  @spec_map %{"provider_profile_id" => "account-a", "model" => "test-model"}

  defp socket(overrides) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: nil,
            current_node: node(),
            current_node_id: nil,
            model_selection: nil,
            selected_model_spec: nil,
            pending_model_selection: nil
          },
          overrides
        ),
      private: %{live_temp: %{}}
    }
  end

  defp selection do
    Project.load_model_selection_from_config(
      %{llm: %{providers: [%{id: "account-a", provider: "anthropic", models: ["test-model"]}]}},
      false
    )
  end

  test "canonical persistence contains only picker fields, not resolved credentials or a stale legacy id" do
    spec = Map.merge(@spec_map, %{"reasoning_effort" => "high", "api_key" => "secret"})

    assert StatePersistence.model_selection_state(%{
             selected_model_spec: spec,
             selected_model_id: "stale",
             model_selection: %{config: %{api_key: "secret"}}
           }) == %{model_spec: Map.take(spec, ~w(provider_profile_id model reasoning_effort))}

    assert StatePersistence.model_selection_state(%{selected_model_spec: %{}}) == %{
             model_spec: %{}
           }
  end

  test "pending canonical and legacy restores take precedence until their node's bundle arrives" do
    assert StatePersistence.model_selection_state(%{
             pending_model_selection: @spec_map,
             selected_model_spec: %{}
           }) == %{model_spec: @spec_map}

    for legacy <- ["old-profile", ""] do
      assert StatePersistence.model_selection_state(%{
               pending_model_selection: legacy,
               selected_model_spec: @spec_map
             }) == %{selected_model_id: legacy}
    end
  end

  test "canonical Auto wins over a stale legacy id and missing/invalid fields leave state untouched" do
    original = socket(%{selected_model_spec: @spec_map})

    restored =
      StatePersistence.maybe_restore_model_selection(original, %{
        "model_spec" => %{},
        "selected_model_id" => "stale"
      })

    assert restored.assigns.pending_model_selection == %{}
    assert restored.assigns.selected_model_spec == @spec_map

    for state <- [
          %{},
          %{"model_spec" => nil},
          %{"model_spec" => 42},
          %{"selected_model_id" => nil}
        ] do
      assert StatePersistence.maybe_restore_model_selection(original, state) == original
    end
  end

  test "a pending remote target cannot validate browser state with a local bundle" do
    original =
      socket(%{
        current_node_id: "remote-target",
        model_selection: selection(),
        selected_model_spec: %{}
      })

    restored =
      StatePersistence.maybe_restore_model_selection(original, %{"model_spec" => @spec_map})

    assert restored.assigns.pending_model_selection == @spec_map
    assert restored.assigns.selected_model_spec == %{}
    assert Phoenix.LiveView.Utils.get_push_events(restored) == []
  end

  test "a loaded node reconciles canonical, legacy and stale selections before partial persistence" do
    original = socket(%{model_selection: selection(), selected_model_spec: %{}})

    for {state, expected} <- [
          {%{"model_spec" => @spec_map, "selected_model_id" => "stale"}, @spec_map},
          {%{"selected_model_id" => "account-a"}, @spec_map},
          {%{"model_spec" => %{"provider_profile_id" => "removed"}}, @spec_map},
          {%{"model_spec" => %{}}, %{}},
          {%{"selected_model_id" => ""}, %{}}
        ] do
      restored = StatePersistence.maybe_restore_model_selection(original, state)
      assert restored.assigns.selected_model_spec == expected
      assert restored.assigns.pending_model_selection == nil

      assert Phoenix.LiveView.Utils.get_push_events(restored) == [
               ["persist_model_selection", %{model_spec: expected, node: "local"}]
             ]
    end
  end

  test "partial persistence is node-scoped, contains no prompt, and waits for pending restores" do
    original =
      socket(%{
        current_node_id: "remote-target",
        current_node: :"remote@127.0.0.1",
        model_selection: selection(),
        model_selection_scope: {"remote-target", :"remote@127.0.0.1"},
        model_selection_ready?: true,
        model_selection_error: nil,
        selected_model_spec: Map.put(@spec_map, "api_key", "must-not-leak"),
        task_prompt: "DOM-owned draft"
      })

    persisted = StatePersistence.maybe_persist_model_selection(original)

    assert Phoenix.LiveView.Utils.get_push_events(persisted) == [
             ["persist_model_selection", %{model_spec: @spec_map, node: "remote-target"}]
           ]

    assert persisted.assigns.task_prompt == "DOM-owned draft"

    for overrides <- [
          %{pending_model_selection: %{}},
          %{pending_model_selection: "legacy-profile"},
          %{selected_model_spec: nil},
          %{current_node: node()},
          %{model_selection: nil},
          %{model_selection_scope: nil},
          %{model_selection_scope: {"other-target", :"remote@127.0.0.1"}},
          %{model_selection_scope: {"remote-target", :"old-remote@127.0.0.1"}},
          %{model_selection_ready?: false},
          %{model_selection_error: :unavailable}
        ] do
      blocked = %{original | assigns: Map.merge(original.assigns, overrides)}
      assert StatePersistence.maybe_persist_model_selection(blocked) == blocked
      assert Phoenix.LiveView.Utils.get_push_events(blocked) == []
    end

    auto = %{original | assigns: Map.put(original.assigns, :selected_model_spec, %{})}

    assert Phoenix.LiveView.Utils.get_push_events(
             StatePersistence.maybe_persist_model_selection(auto)
           ) == [["persist_model_selection", %{model_spec: %{}, node: "remote-target"}]]
  end

  test "full state persistence carries pending canonical Auto rather than a stale picker or legacy id" do
    original =
      socket(%{
        active_project_path: "/repo",
        task_mode: "evolve_simple",
        selected_agent_id: nil,
        task_prompt: "draft",
        task_node_path: "./",
        task_starting_commit: "",
        task_resume_from: "",
        show_advanced: false,
        show_project_settings: false,
        task_archive: false,
        selected_model_spec: @spec_map,
        selected_model_id: "stale",
        pending_model_selection: %{}
      })

    persisted = StatePersistence.maybe_persist_state(original)
    assert [["persist_state", state]] = Phoenix.LiveView.Utils.get_push_events(persisted)
    assert state.model_spec == %{}
    assert state.task_prompt == "draft"
    assert state.node == "local"
    refute Map.has_key?(state, :selected_model_id)
    refute Map.has_key?(state, :model_selection)
  end
end
