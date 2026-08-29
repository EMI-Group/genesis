defmodule EvoDashWeb.TaskCardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.TaskCardComponents

  # Unit tests for the pure copy-text helpers behind the expanded task-card
  # detail view (TasksLive) and its zoom modals:
  #   - objective_text/1 — the trimmed objective (prompt, falling back to
  #     objective) shared by the collapsed-card preview, the expanded Objective
  #     card copy button, and render_options/2.
  #   - result_copy_text/1 — the plain-text copy payload for the Agent Message
  #     card and Full Result modal copy buttons (raw agent message on
  #     success/no-changes, inspected reason on error/crash, pretty-inspected
  #     fallback otherwise).
  describe "objective_text/1" do
    test "prefers :prompt over :objective and trims surrounding whitespace" do
      assert TaskCardComponents.objective_text(
               prompt: "  Build the web app  ",
               objective: "ignored fallback"
             ) == "Build the web app"
    end

    test "falls back to :objective when :prompt is absent" do
      assert TaskCardComponents.objective_text(objective: "  Fix the login bug  ") ==
               "Fix the login bug"
    end

    test "falls back to :objective when :prompt is nil" do
      assert TaskCardComponents.objective_text(prompt: nil, objective: "fallback text") ==
               "fallback text"
    end

    test "trims leading and trailing whitespace" do
      assert TaskCardComponents.objective_text(prompt: "   padded objective   ") ==
               "padded objective"
    end

    test "empty, nil, or whitespace-only opts return an empty string" do
      assert TaskCardComponents.objective_text([]) == ""
      assert TaskCardComponents.objective_text(nil) == ""
      assert TaskCardComponents.objective_text(%{}) == ""
      assert TaskCardComponents.objective_text(prompt: "   ") == ""
    end
  end

  describe "result_copy_text/1" do
    test "success result copies the raw agent message" do
      assert TaskCardComponents.result_copy_text({:ok, %{result: "the agent message"}}) ==
               "the agent message"
    end

    test "no-changes success still copies the raw agent message" do
      assert TaskCardComponents.result_copy_text(
               {:ok, %{no_changes: true, result: "nothing to do"}}
             ) == "nothing to do"
    end

    test "plain map result copies the raw message" do
      assert TaskCardComponents.result_copy_text(%{result: "plain message"}) == "plain message"
    end

    test "error reason is inspected (strings stay quoted)" do
      assert TaskCardComponents.result_copy_text({:error, "boom"}) == ~s("boom")
    end

    test "error map reason keeps the inspect shape" do
      assert TaskCardComponents.result_copy_text({:error, %{detail: "x"}}) =~ "%{detail:"
    end

    test "exit reason is inspected" do
      assert TaskCardComponents.result_copy_text({:exit, :killed}) == ":killed"
    end

    test "anything else falls back to a pretty-inspected representation" do
      assert TaskCardComponents.result_copy_text(%{other: "thing"}) =~ "%{other:"
    end
  end

  describe "result_repos/1" do
    test "normalizes a string-keyed repos map — primary first, foreign sorted by id" do
      assert TaskCardComponents.result_repos(
               {:ok,
                %{
                  result: "done",
                  repos: %{
                    "zeta-repo" => %{
                      "commit_sha" => "ccccccc3",
                      "branch_name" => "genesis/agent_1"
                    },
                    "primary" => %{"commit_sha" => "aaaaaaa1", "branch_name" => "genesis/agent_1"},
                    "alpha-repo" => %{"commit_sha" => "bbbbbbb2", "branch_name" => nil}
                  }
                }}
             ) == [
               %{id: "primary", commit_sha: "aaaaaaa1", branch_name: "genesis/agent_1"},
               %{id: "alpha-repo", commit_sha: "bbbbbbb2", branch_name: nil},
               %{id: "zeta-repo", commit_sha: "ccccccc3", branch_name: "genesis/agent_1"}
             ]
    end

    test "accepts atom-keyed in-memory repos maps too (pre-Codec shape)" do
      assert TaskCardComponents.result_repos(%{
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1", branch_name: nil}
               }
             }) == [%{id: "primary", commit_sha: "aaaaaaa1", branch_name: nil}]
    end

    test "returns nil for legacy results, errors, exits, and non-map input" do
      assert TaskCardComponents.result_repos({:ok, %{result: "legacy"}}) == nil
      assert TaskCardComponents.result_repos({:error, "boom"}) == nil
      assert TaskCardComponents.result_repos({:exit, :killed}) == nil
      assert TaskCardComponents.result_repos("raw string") == nil
      assert TaskCardComponents.result_repos(nil) == nil
      assert TaskCardComponents.result_repos(%{}) == nil
      assert TaskCardComponents.result_repos(%{result: "no repos key"}) == nil
      assert TaskCardComponents.result_repos(%{repos: %{}}) == nil
      assert TaskCardComponents.result_repos(%{repos: "not a map"}) == nil
      assert TaskCardComponents.result_repos(%{repos: %{"primary" => "not a map"}}) == nil
    end
  end

  describe "task_card/1 summary-map safety" do
    # Summary maps (the sidebar Active Tasks contract) have NO `result` key.
    # The card must render without crashing and without any per-repo markup.
    test "renders a summary map without a result key" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: %{
            id: "t1",
            type: :genesis,
            status: :completed,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            agent_count: 1,
            opts: [prompt: "summary task", mode: "simple"]
          }
        )

      assert html =~ "summary task"
      refute html =~ "Repositories"
      refute html =~ "legacy-api"
    end

    test "collapsed card shows the multi-repo indicator only when repos is present" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: %{
            id: "t1",
            type: :genesis,
            status: :completed,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            agent_count: 1,
            opts: [prompt: "multi repo task", mode: "simple"],
            result:
              {:ok,
               %{
                 result: "done",
                 commit_sha: "aaaaaaa1",
                 branch_name: "genesis/agent_1",
                 repos: %{
                   "primary" => %{commit_sha: "aaaaaaa1", branch_name: "genesis/agent_1"},
                   "legacy-api" => %{commit_sha: "bbbbbbb2", branch_name: "genesis/agent_1"}
                 }
               }}
          }
        )

      assert html =~ "legacy-api:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
    end
  end
end
