defmodule EvoDashWeb.ProjectsLive.LaunchOptionsTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.{LaunchOptions, Project}

  defp selection(rules_enabled \\ false) do
    Project.load_model_selection_from_config(
      %{
        llm: %{
          providers: [
            %{
              id: "account-a",
              provider: "anthropic",
              models: [
                %{model: "test-model", reasoning_efforts: ["low", "high"]},
                "plain-model"
              ],
              default_model: "test-model",
              default_reasoning_effort: "low"
            }
          ]
        }
      },
      rules_enabled
    )
  end

  defp payloads do
    # Both callers own these fields; LaunchOptions is their shared selection boundary.
    [
      [
        path: "/repo",
        mode: "simple",
        objective: "Normal task",
        attachments: [%{"data" => "eA=="}]
      ],
      [
        path: "/repo",
        mode: "simple",
        objective: "Fix issue #7\n\nIssue body",
        foreign_repos: [:repo]
      ]
    ]
  end

  test "normal and GitHub-shaped payloads receive the exact explicit spec and lock, never a legacy id" do
    spec = %{
      "provider_profile_id" => "account-a",
      "model" => "test-model",
      "reasoning_effort" => "high"
    }

    assigns = %{
      model_selection: selection(true),
      selected_model_spec: spec,
      selected_agent_id: "custom-agent",
      quality_level: "high_quality"
    }

    for payload <- payloads() do
      resumed =
        Keyword.merge(payload, model_id: "old-id", model_spec: %{}, model_id_locked: false)

      assert {:ok, opts} = LaunchOptions.apply(resumed, assigns)
      assert Keyword.take(opts, Keyword.keys(payload)) == payload
      assert opts[:model_spec] == spec
      assert opts[:model_id_locked] == true
      refute Keyword.has_key?(opts, :model_id)
      assert opts[:agent] == "custom-agent"
      assert opts[:quality_level] == "high_quality"
    end
  end

  test "Auto removes every carried model lock, agent and quality override on either launch payload" do
    for rules? <- [false, true], auto <- [%{}, ""], payload <- payloads() do
      resumed =
        Keyword.merge(payload,
          model_id: "old-id",
          model_spec: %{"provider_profile_id" => "old-account"},
          model_id_locked: true,
          agent: "old-agent",
          quality_level: "fast"
        )

      assert {:ok, opts} =
               LaunchOptions.apply(resumed, %{
                 model_selection: selection(rules?),
                 selected_model_spec: auto,
                 selected_agent_id: "",
                 quality_level: "balanced"
               })

      assert opts == payload
    end
  end

  test "uninitialized selection locks the configured default even when rules are enabled" do
    assert {:ok, opts} = LaunchOptions.apply([], %{model_selection: selection(true)})

    assert opts == [
             model_spec: %{
               "provider_profile_id" => "account-a",
               "model" => "test-model",
               "reasoning_effort" => "low"
             },
             model_id_locked: true
           ]
  end

  test "a model without an effort inventory never gains a task reasoning override" do
    assert {:ok, opts} =
             LaunchOptions.apply([], %{
               model_selection: selection(),
               selected_model_spec: %{
                 "provider_profile_id" => "account-a",
                 "model" => "plain-model"
               },
               quality_level: "fast"
             })

    assert opts[:model_spec] == %{
             "provider_profile_id" => "account-a",
             "model" => "plain-model"
           }

    assert opts[:model_id_locked] == true
    assert opts[:quality_level] == "fast"
  end

  test "stale provider, model and effort are errors rather than an Auto or default launch" do
    data = selection()

    for {spec, error} <- [
          {%{"provider_profile_id" => "removed"}, {:provider_profile_not_found, "removed"}},
          {%{"provider_profile_id" => "account-a", "model" => "removed"},
           {:model_not_found, "account-a", "removed"}},
          {%{
             "provider_profile_id" => "account-a",
             "model" => "test-model",
             "reasoning_effort" => "unsupported"
           }, {:unsupported_reasoning_effort, "unsupported", ["low", "high"]}},
          {42, :invalid_model_spec}
        ],
        payload <- payloads() do
      assert LaunchOptions.apply(payload, %{model_selection: data, selected_model_spec: spec}) ==
               {:error, error}
    end
  end

  test "an owned ready remote bundle authorizes explicit and Auto launches for either payload" do
    assigns = %{
      current_node_id: "remote-target",
      current_node: :"remote@127.0.0.1",
      model_selection: selection(),
      model_selection_scope: {"remote-target", :"remote@127.0.0.1"},
      model_selection_ready?: true,
      model_selection_error: nil,
      pending_model_selection: nil
    }

    spec = %{
      "provider_profile_id" => "account-a",
      "model" => "test-model",
      "reasoning_effort" => "high"
    }

    for payload <- payloads() do
      assert {:ok, opts} =
               LaunchOptions.apply(payload, Map.put(assigns, :selected_model_spec, spec))

      assert Keyword.take(opts, Keyword.keys(payload)) == payload

      assert Keyword.drop(opts, Keyword.keys(payload)) == [
               model_spec: spec,
               model_id_locked: true
             ]

      for auto <- [%{}, ""] do
        assert LaunchOptions.apply(payload, Map.put(assigns, :selected_model_spec, auto)) ==
                 {:ok, payload}
      end
    end
  end

  test "pending, unowned and unavailable bundles cannot authorize even an Auto launch" do
    assigns = %{
      current_node_id: "remote-target",
      current_node: :"remote@127.0.0.1",
      model_selection: selection(),
      model_selection_scope: {"remote-target", :"remote@127.0.0.1"},
      model_selection_ready?: true,
      model_selection_error: nil,
      pending_model_selection: nil
    }

    for {overrides, error} <- [
          {%{current_node: node()}, :model_selection_pending_remote},
          {%{model_selection_scope: nil}, :model_selection_scope_mismatch},
          {%{model_selection_scope: {"other-target", :"remote@127.0.0.1"}},
           :model_selection_scope_mismatch},
          {%{model_selection_scope: {"remote-target", :"old-remote@127.0.0.1"}},
           :model_selection_scope_mismatch},
          {%{model_selection_ready?: false}, :model_selection_not_loaded},
          {%{model_selection_error: :unavailable}, {:model_selection_load_failed, :unavailable}},
          {%{pending_model_selection: %{}}, :model_selection_restore_pending},
          {%{pending_model_selection: "legacy-profile"}, :model_selection_restore_pending}
        ],
        selected <- [
          nil,
          %{},
          "",
          %{"provider_profile_id" => "account-a", "model" => "test-model"}
        ],
        payload <- payloads() do
      blocked = assigns |> Map.merge(overrides) |> Map.put(:selected_model_spec, selected)
      assert LaunchOptions.apply(payload, blocked) == {:error, error}
    end
  end

  test "a picker that has not loaded cannot launch, including an explicit Auto" do
    for assigns <- [%{}, %{model_selection: nil, selected_model_spec: %{}}] do
      assert LaunchOptions.apply([], assigns) == {:error, :model_selection_not_loaded}
    end
  end
end
