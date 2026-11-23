defmodule EvoDashWeb.ProjectsLive.AsyncLoadSelectionTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.{AsyncLoad, ModelSelectionScope, Project}

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

  # A dropped result must NEVER leave the picker in the endless
  # "Loading models…" state (`ready? == false` with no recorded error): the
  # user choice survives, the unusable bundle is discarded and the retryable
  # reason is recorded.
  defp assert_settled_drop(original, message_node, prev_node_id, path, result, reason) do
    assert {updated, false} =
             AsyncLoad.handle_result(original, message_node, prev_node_id, path, result)

    assert updated.assigns.model_selection_error == reason
    assert updated.assigns.model_selection_ready? == false
    assert updated.assigns.model_selection == nil
    assert updated.assigns.model_selection_scope == nil
    assert updated.assigns.provider_profiles == []
    assert updated.assigns.model_selections == []

    # The dropped batch applied nothing else either.
    refute Map.has_key?(updated.assigns, :custom_agents)

    # Choices are PRESERVED — only launch readiness is revoked.
    assert updated.assigns.selected_model_spec == original.assigns.selected_model_spec
    assert updated.assigns.pending_model_selection == original.assigns.pending_model_selection

    # The recorded reason is what the task form renders as a retryable error
    # (a pending remote target answers its own launch verdict, so it is never
    # wrapped in the generic load-failure one).
    expected_bundle_error =
      case reason do
        :model_selection_pending_remote -> :model_selection_pending_remote
        reason -> {:model_selection_load_failed, reason}
      end

    assert {:error, ^expected_bundle_error} = ModelSelectionScope.bundle(updated.assigns)

    updated
  end

  test "node, target id, generation and active path mismatches discard the whole batch" do
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
      assert_settled_drop(
        socket(),
        message_node,
        "target-a",
        path,
        result,
        :model_selection_superseded
      )
    end
  end

  test "a pending remote target rejects a local batch without reading local config" do
    original = socket(%{current_node: node(), pending_model_selection: @spec_map})

    assert_settled_drop(
      original,
      node(),
      "target-a",
      "/remote/repo",
      results(),
      :model_selection_pending_remote
    )

    # The batch stays self-describing: a pending target produces NO projects,
    # NO notified-id seed and a typed picker outcome instead of a keyless map
    # that would look like a silent load.
    assert AsyncLoad.default_batch(node(), false, "target-a", "/remote/repo", true, true) == %{
             projects: [],
             terminal_ids: nil,
             auto_activate?: false,
             model_selection: {:error, :model_selection_pending_remote}
           }
  end

  test "a dropped result preserves an already-applied, owned bundle" do
    data = selection()

    original =
      socket(%{
        model_selection: data,
        model_selection_scope: {"target-a", @remote_node},
        model_selection_ready?: true,
        model_selection_error: nil,
        provider_profiles: data.provider_profiles,
        model_selections: data.model_selections
      })

    for {message_node, path} <- [
          {node(), "/remote/repo"},
          {@remote_node, "/other/repo"},
          {@remote_node, "/remote/repo"}
        ] do
      # A superseded drop must never revoke a picker that is already launchable.
      assert {updated, false} =
               AsyncLoad.handle_result(
                 original,
                 message_node,
                 "target-a",
                 path,
                 results(%{load_scope: %{seq: 3, node_id: "target-a", selection: @spec_map}})
               )

      assert updated.assigns.model_selection_ready? == true
      assert updated.assigns.model_selection_error == nil
      assert updated.assigns.model_selection == data
      assert updated.assigns.model_selection_scope == {"target-a", @remote_node}
      assert updated.assigns.provider_profiles == data.provider_profiles
      assert updated.assigns.model_selections == data.model_selections
      assert {:ok, ^data} = ModelSelectionScope.bundle(updated.assigns)
    end
  end

  test "a result without a model_selection key settles into a recorded error" do
    # A batch that carries no picker bundle at all is an explicit outcome, not a
    # silent no-op: the picker records a retryable error and every OTHER result
    # key still applies.
    assert {updated, true} =
             AsyncLoad.handle_result(
               socket(),
               @remote_node,
               "target-a",
               "/remote/repo",
               results()
             )

    assert updated.assigns.model_selection_error == :model_selection_missing
    assert updated.assigns.model_selection_ready? == false
    assert updated.assigns.model_selection == nil
    assert updated.assigns.provider_profiles == []
    assert updated.assigns.model_selections == []
    assert updated.assigns.custom_agents == [:fresh_agent]

    # The recorded outcome is retryable, not terminal: the task form renders
    # its error banner with a Retry action (`#model-selection-error` /
    # `retry_model_selection`) instead of the endless loading span. The mounted
    # retry click is pinned in `projects_live_test.exs`
    # ("config-change driven model picker reload").
    assert {:error, {:model_selection_load_failed, :model_selection_missing}} =
             ModelSelectionScope.bundle(updated.assigns)
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
