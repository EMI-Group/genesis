defmodule EvoDashWeb.AgentsLive.LoadDataModelLabelTest do
  @moduledoc """
  Integration coverage for the agent-detail panel's model label across the
  LOAD path: `EvoDashWeb.AgentsLive.LoadData` must attach `:model_label` to
  every agent map it builds (the page-load / refresh builder), so an agent
  spawned with an explicit canonical `model_spec` renders its provider-profile
  / model / effort instead of "N/A".

  `LoadData.refresh/2` is driven directly with a WARM threshold cache, so the
  only seam touched is `:agents_list_runner`.
  """
  # async: false — this module writes the BEAM-global app-env key
  # `:agents_list_runner`, which `EvoDashWeb.AgentsLiveTest` (async: true) also
  # drives; app env is shared by every concurrently running module.
  use ExUnit.Case, async: false
  alias EvoDashWeb.AgentsLive.{LoadData, ThresholdCache}

  setup do
    on_exit(fn -> Application.delete_env(:evo_dash, :agents_list_runner) end)
    :ok
  end

  test "an explicit canonical selection renders profile - model - effort" do
    summary =
      summary(
        model_id: nil,
        model_spec: %{
          "provider_profile_id" => "work",
          "model" => "glm-4.6",
          "reasoning_effort" => "high"
        },
        llm_model: "zai:glm-4.6"
      )

    assert [agent] = refresh([summary])
    assert agent.model_label == "work - glm-4.6 - high"
    # The legacy field keeps its own semantics (nil for explicit selections).
    assert agent.model_id == nil
  end

  test "a canonical selection without effort renders profile - model" do
    summary =
      summary(
        model_id: nil,
        model_spec: %{"provider_profile_id" => "work", "model" => "glm-4.6"}
      )

    assert [agent] = refresh([summary])
    assert agent.model_label == "work - glm-4.6"
  end

  test "a legacy summary keeps its model_id as the label" do
    assert [agent] = refresh([summary(model_id: "1:zai:glm-4.6")])
    assert agent.model_label == "1:zai:glm-4.6"
    assert agent.model_id == "1:zai:glm-4.6"
  end

  test "a summary with no model information carries a nil label (template N/A)" do
    assert [agent] = refresh([summary()])
    assert agent.model_label == nil
  end

  # Builds the rich agent maps from the stubbed summaries, bypassing the
  # config-status read with a WARM threshold cache (no `:agents_config_runner`
  # seam needed).
  defp refresh(summaries) do
    Application.put_env(:evo_dash, :agents_list_runner, fn _node -> summaries end)
    now = System.monotonic_time(:millisecond)
    cache = ThresholdCache.put(nil, node(), ThresholdCache.default_threshold(), now)
    {agents, _cache} = LoadData.refresh(node(), cache)
    agents
  end

  # A minimal `RemoteAPI.list_agents/0`-shaped summary.
  defp summary(overrides \\ []) do
    Map.merge(
      %{
        id: 1,
        task_local_id: nil,
        repo_id: nil,
        status: :running,
        depth: 0,
        parent_id: nil,
        usage: nil,
        total_tokens: 0,
        compression_count: 0,
        message_count: 0,
        objective: "test objective",
        result: nil,
        agent_module: EvoGit.Agents.Manager,
        started_at: nil,
        model_id: nil,
        provider_profile_id: nil,
        model_spec: nil,
        llm_model: nil,
        repo_root: nil,
        context_path: "./",
        worktree: nil,
        current_commit: "abc123",
        base_commit: "def456",
        task_id: "task-1",
        task_number: nil,
        retries: 0
      },
      Map.new(overrides)
    )
  end
end
