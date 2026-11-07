defmodule EvoDashWeb.ProjectsLive.AsyncLoadSelectionTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.{AsyncLoad, Project}

  @remote_node :"genesis_remote@127.0.0.1"
  @spec_map %{"provider_profile_id" => "account-a", "model" => "test-model"}

  defp socket(overrides \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: nil,
            current_node: @remote_node,
            current_node_id: "target-a",
            active_project_path: "/remote/repo",
            projects_load_seq: 4,
            selected_model_spec: @spec_map,
            pending_model_selection: nil,
            model_selection: nil,
            provider_profiles: [],
            model_selections: []
          },
          overrides
        ),
      private: %{live_temp: %{}}
    }
  end

  defp selection do
    Project.load_model_selection_from_config(
      %{llm: %{providers: [%{id: "account-a", provider: "anthropic", models: ["test-model"]}]}},
      true
    )
  end

  defp results(overrides \\ %{}) do
    Map.merge(
      %{
        load_scope: %{seq: 4, node_id: "target-a", selection: @spec_map},
        custom_agents: [:fresh_agent]
      },
      overrides
    )
  end

  test "node, target id, generation and active path mismatches discard the whole batch" do
    original = socket()

    for {message_node, path, result} <- [
          {node(), "/remote/repo", results()},
          {@remote_node, "/other/repo", results()},
          {@remote_node, "/remote/repo",
           results(%{load_scope: %{seq: 3, node_id: "target-a", selection: @spec_map}})},
          {@remote_node, "/remote/repo",
           results(%{load_scope: %{seq: 5, node_id: "target-a", selection: @spec_map}})},
          {@remote_node, "/remote/repo",
           results(%{load_scope: %{seq: 4, node_id: "other-target", selection: @spec_map}})}
        ] do
      assert AsyncLoad.handle_result(original, message_node, "target-a", path, result) ==
               {original, false}
    end
  end

  test "a pending remote target rejects a local batch without reading local config" do
    original = socket(%{current_node: node(), pending_model_selection: @spec_map})

    assert AsyncLoad.handle_result(original, node(), "target-a", "/remote/repo", results()) ==
             {original, false}

    assert AsyncLoad.default_batch(node(), false, "target-a", "/remote/repo", true, true) == %{
             recent_projects: [],
             terminal_ids: nil,
             auto_activate?: false
           }
  end

  test "matching refresh projects the node's bundle and persists only its canonical selection" do
    data = selection()
    original = socket()

    assert {updated, true} =
             AsyncLoad.handle_result(
               original,
               @remote_node,
               "target-a",
               "/remote/repo",
               results(%{model_selection: data})
             )

    assert updated.assigns.model_selection == data
    assert updated.assigns.provider_profiles == data.provider_profiles
    assert updated.assigns.model_selections == data.model_selections
    assert updated.assigns.selected_model_spec == @spec_map
    assert updated.assigns.custom_agents == [:fresh_agent]
    refute Map.has_key?(updated.assigns, :load_scope)

    assert Phoenix.LiveView.Utils.get_push_events(updated) == [
             ["persist_model_selection", %{model_spec: @spec_map, node: "target-a"}]
           ]
  end

  test "a late matching-scope batch cannot overwrite a newer user choice, including Auto" do
    data = selection()

    for newer_choice <- [%{}, %{"provider_profile_id" => "new-choice", "model" => "new-model"}] do
      original = socket(%{selected_model_spec: newer_choice})

      assert {updated, true} =
               AsyncLoad.handle_result(
                 original,
                 @remote_node,
                 "target-a",
                 "/remote/repo",
                 results(%{model_selection: data})
               )

      assert updated.assigns.selected_model_spec == newer_choice
      assert updated.assigns.model_selection == data
      assert Phoenix.LiveView.Utils.get_push_events(updated) == []
    end
  end

  test "pending browser restores win over the spawn snapshot and clear only after reconciliation" do
    data = selection()

    for {pending, expected} <- [
          {@spec_map, @spec_map},
          {"account-a", @spec_map},
          {%{}, %{}},
          {"", %{}},
          {%{"provider_profile_id" => "removed"}, @spec_map}
        ] do
      original = socket(%{selected_model_spec: nil, pending_model_selection: pending})

      assert {updated, true} =
               AsyncLoad.handle_result(
                 original,
                 @remote_node,
                 "target-a",
                 "/remote/repo",
                 results(%{model_selection: data})
               )

      assert updated.assigns.selected_model_spec == expected
      assert updated.assigns.pending_model_selection == nil

      assert Phoenix.LiveView.Utils.get_push_events(updated) == [
               ["persist_model_selection", %{model_spec: expected, node: "target-a"}]
             ]
    end
  end

  test "same-node refresh reconciles a removed provider rather than retaining a stale selection" do
    removed = %{"provider_profile_id" => "removed", "model" => "old-model"}
    original = socket(%{selected_model_spec: removed})

    assert {updated, true} =
             AsyncLoad.handle_result(
               original,
               @remote_node,
               "target-a",
               "/remote/repo",
               results(%{
                 load_scope: %{seq: 4, node_id: "target-a", selection: removed},
                 model_selection: selection()
               })
             )

    assert updated.assigns.selected_model_spec == @spec_map
  end
end
