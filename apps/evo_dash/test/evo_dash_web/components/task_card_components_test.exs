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

  # Review-button candidacy is RESULT-AGNOSTIC: every completed/cancelled task
  # is reviewable (a multi-repo task may have changed ONLY writable foreign
  # repos, making no primary-repo changes), while `:reflect` (repo-less) tasks
  # are excluded explicitly.
  describe "task_card/1 — Review button candidacy" do
    test "a completed task with no primary branch renders the Review button" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task:
            review_task(
              status: :completed,
              result: {:ok, %{result: "nothing to do", no_changes: true}}
            )
        )

      assert html =~ "Review"
      assert html =~ "/review/"
    end

    test "a completed multi-repo task that changed only a foreign repo renders the Review button" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task:
            review_task(
              status: :completed,
              result:
                {:ok,
                 %{
                   result: "foreign-only change",
                   commit_sha: nil,
                   branch_name: nil,
                   repos: %{
                     "primary" => %{commit_sha: "aaaaaaa1", branch_name: nil},
                     "legacy-api" => %{commit_sha: "bbbbbbb2", branch_name: "evogit-agent_1"}
                   }
                 }}
            )
        )

      assert html =~ "Review"
      assert html =~ "/review/"
    end

    test "a cancelled task with no primary branch renders the Review button" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: review_task(status: :cancelled, result: {:ok, %{result: "stopped"}})
        )

      assert html =~ "Review"
      assert html =~ "/review/"
    end

    test "a completed :reflect (repo-less) task never renders the Review button" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: review_task(type: :reflect, status: :completed, result: {:ok, %{result: "chat"}})
        )

      refute html =~ "/review/"
      refute html =~ "hero-eye"
    end

    test "a cancelled :reflect task never renders the Review button" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: review_task(type: :reflect, status: :cancelled, result: {:ok, %{result: "chat"}})
        )

      refute html =~ "/review/"
      refute html =~ "hero-eye"
    end

    test "non-reviewable statuses never render the Review button" do
      for status <- [:pending, :running, :finalizing, :failed] do
        html =
          render_component(&TaskCardComponents.task_card/1,
            task: review_task(status: status, result: {:ok, %{branch_name: "genesis/agent_1"}})
          )

        refute html =~ "/review/"
      end
    end
  end

  # Rendering tests for the structured failed-task error record (TaskInfo
  # `error` field, ATOM-keyed map after the Store Codec decode). Contract:
  #   - ONLY `status: :failed` rows carry `error` (nil for all others/legacy).
  #   - COLLAPSED card: a compact error-tinted strip with the truncated
  #     error.message (~160 chars) — kind-label fallback when no usable message.
  #   - EXPANDED card: a full-detail block — kind + source label chips, the
  #     full message, and the LAST ≤8 stacktrace frames in a monospace <pre>.
  #   - The legacy `{:error, _}` / `{:exit, _}` RESULT box (render_result) is a
  #     SEPARATE record and stays preserved (both records may coexist).
  #   - `:failed` NEVER renders a Review button.
  # Exact class strings / gettext msgids asserted below mirror
  # task_card_components.ex + EvoDashWeb.Helpers (task_error_kind_label/1,
  # task_error_source_label/1, truncate_string/2).
  describe "task_card/1 — failed-task structured error display" do
    test "collapsed failed card renders the compact error strip with the truncated message" do
      message = String.duplicate("x", 200)
      truncated = EvoDashWeb.Helpers.truncate_string(message, 160)

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(error: error_record(message: message))
        )

      # Strip wrapper + truncate span carry the error-tinted classes; the span
      # text is truncated at 160 chars + "..." while the full message rides in
      # the title attribute (so `truncated` uniquely matches the span body).
      assert html =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      assert html =~ "class=\"text-xs font-medium text-error truncate min-w-0\""
      assert html =~ truncated
      assert html =~ "title=\"#{message}\""
      # Full-detail block is expanded-only — absent here.
      refute html =~ "rounded-lg p-4"
      refute html =~ "Stacktrace"
      refute html =~ "Source"
    end

    test "collapsed failed card falls back to the kind label when the message is missing or empty" do
      # Missing :message key → error_message/1 nil → kind label (:down → "Agent crashed").
      html =
        render_component(&TaskCardComponents.task_card/1,
          task:
            failed_task(error: %{kind: :down, source: :down_handler, stacktrace: ["  frame 1"]})
        )

      assert html =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      assert html =~ "Agent crashed"

      # Empty-string :message → same fallback (kind :exit → label "Failed").
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(error: %{kind: :exit, source: :result_handler, message: ""})
        )

      assert html =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      assert html =~ "Failed"
    end

    test "expanded failed card renders the full-detail error block with kind + source labels, full message, and the last ≤8 stacktrace frames" do
      message = "The agent process crashed while working on the objective"

      stacktrace =
        Enum.map(
          1..10,
          &"(frame #{&1}) lib/task_registry.ex:#{900 + &1}: EvoGit.TaskRegistry.handle_info/2"
        )

      last8 = Enum.take(stacktrace, -8)

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(error: error_record(message: message, stacktrace: stacktrace)),
          show_details: true
        )

      # Kind + source caption chips (Helpers labels: :down → "Agent crashed",
      # :down_handler → "Agent monitor"); the collapsed strip is NOT rendered
      # in the expanded view.
      assert html =~ "bg-error/10 border border-error/20 rounded-lg p-4"
      assert html =~ "Agent crashed"
      assert html =~ "Source: Agent monitor"
      refute html =~ "px-3 py-2 min-w-0"
      # Full untruncated message in the detail pre.
      assert html =~
               "<pre class=\"text-xs whitespace-pre-wrap break-words max-h-48 overflow-y-auto\">#{message}</pre>"

      # Monospace stacktrace block: only the LAST 8 of 10 frames render.
      assert html =~ "Stacktrace"
      assert html =~ "class=\"text-xs font-mono leading-relaxed whitespace-pre-wrap break-words\""
      assert html =~ Enum.join(last8, "\n")
      refute html =~ Enum.at(stacktrace, 0)
      refute html =~ Enum.at(stacktrace, 1)
    end

    test "expanded failed card keeps the legacy {:error, _} result box when both records coexist" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task:
            failed_task(
              error: error_record(),
              result: {:error, "legacy boom"}
            ),
          show_details: true
        )

      # Structured full-detail block...
      assert html =~ "bg-error/10 border border-error/20 rounded-lg p-4"
      assert html =~ "Agent crashed"
      assert html =~ "Source: Agent monitor"
      # ...AND the separate legacy render_result {:error, _} box (heading
      # gettext("Error") + inspected reason — quotes HTML-escaped in the text
      # node as &quot;) are both preserved.
      assert html =~ "Error"
      assert html =~ "&quot;legacy boom&quot;"
    end

    test "failed rows with error nil render exactly as before — no strip, no detail block, no crash" do
      # Full-shape decoded TaskInfo with an explicit error: nil key.
      task = failed_task(error: nil)

      collapsed = render_component(&TaskCardComponents.task_card/1, task: task)
      refute collapsed =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      refute collapsed =~ "hero-x-circle"

      expanded =
        render_component(&TaskCardComponents.task_card/1, task: task, show_details: true)

      refute expanded =~ "bg-error/10 border border-error/20 rounded-lg p-4"
      refute expanded =~ "Stacktrace"
      refute expanded =~ "Source"

      # Legacy failed row without any error key at all — same no-crash result.
      legacy = failed_task() |> Map.delete(:error)
      collapsed = render_component(&TaskCardComponents.task_card/1, task: legacy)
      refute collapsed =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"

      expanded =
        render_component(&TaskCardComponents.task_card/1, task: legacy, show_details: true)

      refute expanded =~ "Stacktrace"
      assert expanded =~ "Fix the failing feature"
    end

    test "non-map error values (string, list, arbitrary term) never crash and never render an error block" do
      for bad <- ["boom", ["frame 1", "frame 2"], 42, :garbage] do
        task = failed_task(error: bad)

        collapsed = render_component(&TaskCardComponents.task_card/1, task: task)
        refute collapsed =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
        refute collapsed =~ "hero-x-circle"

        expanded =
          render_component(&TaskCardComponents.task_card/1, task: task, show_details: true)

        refute expanded =~ "bg-error/10 border border-error/20 rounded-lg p-4"
        refute expanded =~ "Stacktrace"
        refute expanded =~ "Source"
      end
    end

    test "16-key summary maps with error present render the collapsed strip safely (no result key)" do
      message = "summary failed task error"
      summary = summary_map(error: error_record(message: message))

      assert map_size(summary) == 16

      html = render_component(&TaskCardComponents.task_card/1, task: summary)
      assert html =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      assert html =~ message
      refute html =~ "Repositories"
      refute html =~ "Agent Message"
    end

    test "16-key summary maps with error absent or nil render no error UI and do not crash" do
      for summary <- [summary_map(), summary_map() |> Map.delete(:error)] do
        collapsed = render_component(&TaskCardComponents.task_card/1, task: summary)
        refute collapsed =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
        refute collapsed =~ "hero-x-circle"

        expanded =
          render_component(&TaskCardComponents.task_card/1, task: summary, show_details: true)

        refute expanded =~ "Stacktrace"
        refute expanded =~ "Source"
        assert expanded =~ "summary failed task"
      end
    end

    test "a failed task never renders a Review button even with an error map" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(error: error_record())
        )

      assert html =~ "bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
      refute html =~ "Review"
      refute html =~ "/review/"
    end
  end

  # Test-data builders — a minimal failed TaskInfo-shaped map (ATOM keys, the
  # post-Codec-decoded shape) and an error record map.
  defp failed_task(overrides \\ %{}) do
    Map.merge(
      %{
        id: "t_fail",
        type: :evolve,
        status: :failed,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        agent_count: 1,
        model_id: nil,
        opts: [prompt: "Fix the failing feature", mode: "simple"]
      },
      Map.new(overrides)
    )
  end

  # A minimal completed/terminal TaskInfo-shaped map for Review-button
  # candidacy tests (ATOM keys, the post-Codec-decoded shape).
  defp review_task(overrides) do
    Map.merge(
      %{
        id: "t_review",
        type: :evolve,
        status: :completed,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        agent_count: 1,
        model_id: nil,
        opts: [prompt: "Review candidacy task", mode: "simple"]
      },
      Map.new(overrides)
    )
  end

  defp error_record(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :down,
        source: :down_handler,
        message: "The agent process crashed while working on the objective",
        stacktrace: ["  (frame 1) lib/task_registry.ex:901: EvoGit.TaskRegistry.handle_info/2"]
      },
      Map.new(overrides)
    )
  end

  # The 16-key summary projection shape (Store summary decode): no `result`
  # key; `updated_at` stays a raw ISO string; `error` is the 16th key.
  defp summary_map(overrides \\ %{}) do
    Map.merge(
      %{
        id: "s_fail",
        status: :failed,
        review_status: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        type: :evolve,
        project_path: "/proj",
        opts: [prompt: "summary failed task", mode: "simple"],
        branch_name: nil,
        model_id: nil,
        agent_count: 1,
        base_sha: nil,
        commit_sha: nil,
        lease_expires_at: nil,
        updated_at: "2026-01-01T00:00:00Z",
        error: nil
      },
      Map.new(overrides)
    )
  end
end
