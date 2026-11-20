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

    test "falls back to :objective when :prompt is absent or nil (and trims it)" do
      assert TaskCardComponents.objective_text(objective: "  Fix the login bug  ") ==
               "Fix the login bug"

      assert TaskCardComponents.objective_text(prompt: nil, objective: "fallback text") ==
               "fallback text"
    end

    test "empty, nil, or whitespace-only opts return an empty string" do
      assert TaskCardComponents.objective_text([]) == ""
      assert TaskCardComponents.objective_text(nil) == ""
      assert TaskCardComponents.objective_text(%{}) == ""
      assert TaskCardComponents.objective_text(prompt: "   ") == ""
    end
  end

  describe "result_copy_text/1" do
    test "success (incl. no-changes) and plain map results copy the raw agent message" do
      assert TaskCardComponents.result_copy_text({:ok, %{result: "the agent message"}}) ==
               "the agent message"

      assert TaskCardComponents.result_copy_text(
               {:ok, %{no_changes: true, result: "nothing to do"}}
             ) == "nothing to do"

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
      # The collapsed indicator derives from the SUMMARY row
      # (`opts[:foreign_repos]`, `commit_sha`) enriched by the lazily-fetched
      # `detail` — the summary itself carries no `result`, so the per-repo
      # `repos` map only reaches the card through `detail.task`.
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: %{
            id: "t1",
            type: :genesis,
            status: :completed,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            agent_count: 1,
            opts: [
              prompt: "multi repo task",
              mode: "simple",
              foreign_repos: [%{id: "legacy-api", root: "/tmp/legacy", writable: true}]
            ]
          },
          detail: %{
            state: :ok,
            task: %{
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
          }
        )

      assert html =~ "legacy-api:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
    end
  end

  # The "Model" line renders `EvoDashWeb.ModelLabel.task_label/1` output, NOT
  # the raw legacy `model_id`: a canonical task selection persists `model_spec`
  # in the task OPTS (string-keyed inner map) and leaves `model_id` nil by
  # design, which used to hide the model entirely.
  describe "task_card/1 — Model line" do
    test "renders profile - model - effort for a canonical selection with effort" do
      html =
        render_model_card(
          model_id: nil,
          opts: [
            prompt: "canonical task",
            mode: "simple",
            model_spec: %{
              "provider_profile_id" => "work",
              "model" => "glm-4.6",
              "reasoning_effort" => "high"
            }
          ]
        )

      assert html =~ "Model"
      assert html =~ "work - glm-4.6 - high"
    end

    test "renders profile - model for a canonical selection without effort" do
      html =
        render_model_card(
          model_id: nil,
          opts: [
            prompt: "canonical task",
            mode: "simple",
            model_spec: %{"provider_profile_id" => "work", "model" => "glm-4.6"}
          ]
        )

      assert html =~ "Model"
      assert html =~ "work - glm-4.6"
      refute html =~ "work - glm-4.6 -"
    end

    test "a legacy model_id only still renders the raw id" do
      html =
        render_model_card(
          model_id: "1:zai:glm-4.6",
          opts: [prompt: "legacy task", mode: "simple"]
        )

      assert html =~ "Model"
      assert html =~ "1:zai:glm-4.6"
    end

    test "no model information renders NO Model line at all (no N/A clutter)" do
      html = render_model_card(model_id: nil, opts: [prompt: "bare task", mode: "simple"])

      refute html =~ "Model"
      refute html =~ "N/A"
    end

    test "the lazily-fetched full row is an equal-shaped fallback" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: summary_map(model_id: nil, opts: [prompt: "fallback task", mode: "simple"]),
          show_details: true,
          detail: %{
            state: :ok,
            task: %{
              opts: [model_spec: %{"provider_profile_id" => "side", "model" => "kimi-k2"}]
            }
          }
        )

      assert html =~ "side - kimi-k2"
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

    test "a :reflect (repo-less) task never renders the Review button" do
      for status <- [:completed, :cancelled] do
        html =
          render_component(&TaskCardComponents.task_card/1,
            task: review_task(type: :reflect, status: status, result: {:ok, %{result: "chat"}})
          )

        refute html =~ "/review/"
        refute html =~ "hero-eye"
      end
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
      # The legacy `{:error, _}` RESULT lives on the lazily-fetched FULL
      # TaskInfo (`detail.task`), while the structured `error` record is a
      # summary key — both render in the expanded card.
      html =
        render_component(&TaskCardComponents.task_card/1,
          task:
            failed_task(
              error: error_record(),
              result: {:error, "legacy boom"}
            ),
          show_details: true,
          detail: %{state: :ok, task: %{result: {:error, "legacy boom"}}}
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

  describe "task_card/1 — best-effort cost notice" do
    test "renders the shared cost caveat inside the usage card when usage is present" do
      usage = %{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: 0.001,
        output_cost: 0.002,
        total_cost: 0.003
      }

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(usage: usage),
          show_details: true,
          detail: %{state: :ok, task: %{usage: usage}}
        )

      assert html =~ "Token &amp; Cost Usage"
      assert html =~ "best-effort estimate"
    end

    test "does not render the cost caveat when no usage is present" do
      html =
        render_component(&TaskCardComponents.task_card/1,
          task: failed_task(),
          show_details: true
        )

      refute html =~ "best-effort estimate"
    end
  end

  describe "Archive accessors — the paged archive envelope" do
    alias EvoDashWeb.TaskCardComponents.Archive

    # The envelope owned by EvoDashWeb.TasksLive.TaskDetail.
    defp envelope(overrides) do
      Map.merge(
        %{
          state: :ok,
          entries: [%{"agent_id" => "a"}, %{"agent_id" => "b"}],
          total: 7_149,
          next_offset: 2,
          loading_more?: false,
          more_error: nil,
          error: nil,
          seq: 3,
          agent_results: %{
            "a" => %{state: :ok, entry: %{"agent_id" => "a", "result" => "done"}, error: nil}
          }
        },
        Map.new(overrides)
      )
    end

    test "reads the state, the loaded entries and the TRUE total" do
      envelope = envelope(%{})

      assert Archive.archive_state(envelope) == :ok
      assert Archive.archive_records(envelope) == [%{"agent_id" => "a"}, %{"agent_id" => "b"}]
      assert Archive.archive_total(envelope) == 7_149
      assert Archive.archive_loading_more?(envelope) == false
      assert Archive.archive_more_error(envelope) == nil

      assert Archive.archive_agent_results(envelope) == %{
               "a" => %{state: :ok, entry: %{"agent_id" => "a", "result" => "done"}, error: nil}
             }
    end

    test "reads the append state" do
      envelope = envelope(%{loading_more?: true, more_error: {:exit, :boom}})

      assert Archive.archive_loading_more?(envelope) == true
      assert Archive.archive_more_error(envelope) == {:exit, :boom}
    end

    test "total falls back to the loaded count when the envelope carries none" do
      assert Archive.archive_total(%{state: :ok, entries: [%{}, %{}]}) == 2
      assert Archive.archive_total(%{state: :ok, entries: [], total: nil}) == 0
    end

    test "every accessor is total over nil and garbage" do
      for bad <- [nil, "junk", 42, []] do
        assert Archive.archive_state(bad) == nil
        assert Archive.archive_records(bad) == []
        assert Archive.archive_total(bad) == 0
        assert Archive.archive_agent_results(bad) == %{}
        assert Archive.archive_loading_more?(bad) == false
        assert Archive.archive_more_error(bad) == nil
        refute Archive.archive_opt?(bad)
      end
    end
  end

  describe "task_card/1 — paged archive pass-through" do
    test "passes the envelope's total, append state and agent results to the archive section" do
      task =
        failed_task(%{
          status: :completed,
          opts: [prompt: "Archived task", mode: "simple", archive: true]
        })

      archive = %{
        state: :ok,
        entries: [
          %{"agent_id" => "agent-root", "parent_id" => nil, "objective" => "paged root objective"}
        ],
        total: 500,
        next_offset: 1,
        loading_more?: false,
        more_error: nil,
        error: nil,
        seq: 1,
        agent_results: %{}
      }

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: task,
          show_details: true,
          detail: %{state: :ok, task: task, archive: archive}
        )

      assert html =~ "500 agents — showing 1–1"
      assert html =~ ~s(phx-click="load_more_task_archive")
      assert html =~ ~s(phx-value-task-id="t_fail")
      assert html =~ ~s(phx-click="load_task_archive_agent_result")
      assert html =~ ~s(phx-value-agent-id="agent-root")
      assert html =~ "Show result"
    end

    test "renders no Load more button once every page is loaded" do
      task =
        failed_task(%{
          status: :completed,
          opts: [prompt: "Archived task", mode: "simple", archive: true]
        })

      archive = %{
        state: :ok,
        entries: [
          %{"agent_id" => "agent-root", "parent_id" => nil, "result" => "archived result"}
        ],
        total: 1,
        next_offset: 1,
        loading_more?: false,
        more_error: nil,
        error: nil,
        seq: 1,
        agent_results: %{}
      }

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: task,
          show_details: true,
          detail: %{state: :ok, task: task, archive: archive}
        )

      assert html =~ "1 agents"
      assert html =~ "archived result"
      refute html =~ ~s(phx-click="load_more_task_archive")
    end
  end

  describe "task_card/1 — :awaiting_input session panel" do
    # Interactive agent SESSIONS — `:awaiting_input` is a NON-terminal status:
    # the task's root agent is a live session, idle and waiting for the user,
    # so the card offers a reply box (`phx-submit="session_send_message"`) and
    # a Close session control (`phx-click="open_close_session_modal"`). The
    # panel is gated on BOTH the status and a non-nil `session_agent_id` attr.
    test "renders the reply form and the Close session control for an idle session" do
      html =
        render_session_card(
          %{id: "t_session", status: :awaiting_input, session_mode: "interactive"},
          "agent-root"
        )

      tree = parse(html)

      # Panel wrapper + heading copy.
      assert html =~ ~s(id="task-t_session-session")
      assert html =~ "rounded-lg border border-violet-500/30 bg-violet-500/5 p-3"
      assert html =~ "Interactive session"
      assert html =~ "Waiting for your next message."

      # Reply form — the task id rides as a `phx-value-task_id` on the form, so
      # the submitted params are `%{"task_id" => id, "message" => text}`.
      assert [form] = Floki.find(tree, "form[phx-submit='session_send_message']")
      assert Floki.attribute(form, "phx-value-task_id") == ["t_session"]
      assert html =~ ~s(phx-value-task_id="t_session")

      assert [textarea] = Floki.find(form, "textarea[name='message']")
      assert Floki.attribute(textarea, "id") == ["task-t_session-session-message"]
      assert Floki.attribute(textarea, "rows") == ["3"]

      assert [label] = Floki.find(form, "label[for='task-t_session-session-message']")
      assert Floki.text(label) |> String.trim() == "Message"

      assert [send] = Floki.find(form, "button[type='submit']")
      assert Floki.text(send) |> String.trim() =~ "Send"

      # Close session — only the modal trigger; the modal itself belongs to the
      # owning LiveView.
      assert [close] = Floki.find(tree, "button[phx-click='open_close_session_modal']")
      assert Floki.attribute(close, "phx-value-task_id") == ["t_session"]
      assert Floki.text(close) |> String.trim() =~ "Close session"

      # User-facing status label — never the raw `awaiting_input` atom.
      badge = tree |> Floki.find(".badge") |> Floki.text()
      assert badge =~ "Awaiting input"
      assert badge =~ "(waiting for you)"
      refute html =~ "awaiting_input"
    end

    test "renders no reply panel without a session id while keeping the awaiting marker" do
      html = render_session_card(%{id: "t_session", status: :awaiting_input})
      tree = parse(html)

      refute html =~ ~s(id="task-t_session-session")
      refute html =~ "session_send_message"
      refute html =~ "open_close_session_modal"
      refute html =~ "Close session"
      refute html =~ "Interactive session"
      # The legacy card stays form-free — no wrapper element, no hidden form.
      assert Floki.find(tree, "form") == []

      # …the awaiting marker itself is unchanged.
      assert html =~ "Awaiting input"
      assert html =~ "bg-violet-500/10 text-violet-600 dark:text-violet-400"
    end

    test "the panel is status-gated — a non-:awaiting_input card with a session id renders no panel" do
      for status <- [:pending, :running, :finalizing, :cancelling, :completed, :failed] do
        html =
          render_session_card(
            %{id: "t_session", status: status, session_mode: "interactive"},
            "agent-root"
          )

        refute html =~ ~s(id="task-t_session-session")
        refute html =~ "session_send_message"
        refute html =~ "open_close_session_modal"
        refute html =~ "Close session"
        assert Floki.find(parse(html), "form") == []
      end
    end

    test "Cancel covers :awaiting_input and Force kill covers :awaiting_input and :cancelling only" do
      awaiting =
        render_session_card(
          %{id: "t_session", status: :awaiting_input, session_mode: "interactive"},
          "agent-root"
        )
        |> parse()

      assert [cancel] = Floki.find(awaiting, "button[phx-click='open_cancel_modal']")
      assert Floki.attribute(cancel, "phx-value-task_id") == ["t_session"]
      assert Floki.text(cancel) |> String.trim() =~ "Cancel"

      for class <-
            ~w(btn btn-sm btn-outline border-base-300 rounded-md px-4) do
        assert class in class_list(cancel)
      end

      assert [force] = Floki.find(awaiting, "ul.menu button[phx-click='open_force_kill_modal']")
      assert Floki.text(force) |> String.trim() =~ "Force kill"

      for class <- ~w(text-error rounded-md) do
        assert class in class_list(force)
      end

      assert awaiting |> Floki.find("li.menu-title") |> Floki.text() |> String.trim() ==
               "Danger zone"

      # Terminal task: neither action is offered.
      completed = render_session_card(%{id: "t_session", status: :completed}) |> parse()
      assert Floki.find(completed, "button[phx-click='open_cancel_modal']") == []

      assert Floki.find(completed, "button[phx-click='open_force_kill_modal']") == []
      refute Floki.text(completed) =~ "Danger zone"

      # Graceful cancel in flight: Cancel is gone, force kill (escalation) stays.
      cancelling = render_session_card(%{id: "t_session", status: :cancelling}) |> parse()
      assert Floki.find(cancelling, "button[phx-click='open_cancel_modal']") == []
      assert [_] = Floki.find(cancelling, "button[phx-click='open_force_kill_modal']")
    end

    test ":awaiting_input styling is violet, pulsing and distinct from :running/:cancelling" do
      html = render_session_card(%{id: "t_session", status: :awaiting_input})
      tree = parse(html)

      # Accent bar + card tint belong to the violet idle-session family.
      assert html =~ "h-1 opacity-80 bg-violet-500"
      assert html =~ "bg-violet-500/5 shadow-violet-500/10 border-violet-500/30"
      assert html =~ "bg-violet-500/10 text-violet-600 dark:text-violet-400 rounded-full"
      refute html =~ "bg-warning"

      # It pulses like a running task, but in violet.
      assert [ping] = Floki.find(tree, "span.animate-ping")
      assert "bg-violet-500" in class_list(ping)
      assert [dot] = Floki.find(tree, "span.relative.inline-flex.rounded-full")
      assert "bg-violet-500" in class_list(dot)

      # The busy family pulses too — with the amber color, never violet.
      for status <- [:running, :cancelling] do
        other = render_session_card(%{id: "t_other", status: status})
        assert other =~ "animate-ping"
        assert other =~ "h-1 opacity-80 bg-warning"
        refute other =~ "bg-violet-500"
      end
    end
  end

  describe "task_card/1 — pause / resume" do
    # Task-level pause/resume controls live in the card's action row, just
    # before Cancel: Pause while the task is `:running`/`:pausing`, Resume for
    # `:paused`. The `action_busy` attr (a map keyed by the STRING task id,
    # value `:pause` | `:resume`) marks an async call in flight and disables
    # BOTH of that task's buttons. The paused explainer is status-driven
    # (`pause_kind` `:dirty` = restart-recovered → warning; `:clean`/nil →
    # neutral) and needs NO LiveView round-trip.
    test "Pause is offered only for :running/:pausing, Resume only for :paused" do
      for status <- [:running, :pausing] do
        tree = render_action_card(%{id: "t_pause", status: status}) |> parse()

        assert [pause] = Floki.find(tree, "button[phx-click='open_pause_modal']")
        assert Floki.attribute(pause, "phx-value-task_id") == ["t_pause"]
        assert Floki.find(tree, "button[phx-click='resume_task']") == []
      end

      paused = render_action_card(%{id: "t_pause", status: :paused}) |> parse()
      assert [resume] = Floki.find(paused, "button[phx-click='resume_task']")
      assert Floki.attribute(resume, "phx-value-task_id") == ["t_pause"]
      assert Floki.find(paused, "button[phx-click='open_pause_modal']") == []

      for status <- [
            :pending,
            :finalizing,
            :cancelling,
            :awaiting_input,
            :completed,
            :failed,
            :cancelled
          ] do
        tree = render_action_card(%{id: "t_other", status: status}) |> parse()

        assert Floki.find(tree, "button[phx-click='open_pause_modal']") == []
        assert Floki.find(tree, "button[phx-click='resume_task']") == []
      end
    end

    test "Pause is NOT offered for an interactive-session task (the core refuses it)" do
      # The core answers `{:error, :not_pausable}` for an INTERACTIVE-session
      # root, so rendering the control would offer an action that can never
      # succeed. `session_mode` is read defensively (absent → "oneshot").
      for status <- [:running, :pausing] do
        tree =
          render_action_card(%{id: "t_interactive", status: status, session_mode: "interactive"})
          |> parse()

        assert Floki.find(tree, "button[phx-click='open_pause_modal']") == []
        # The rest of the action row is unaffected: the danger zone stays.
        assert [_] = Floki.find(tree, "ul.menu button[phx-click='open_force_kill_modal']")
      end

      # An interactive `:running` card still offers Cancel.
      running =
        render_action_card(%{id: "t_interactive", status: :running, session_mode: "interactive"})
        |> parse()

      assert [_] = Floki.find(running, "button[phx-click='open_cancel_modal']")
    end

    test "Pause stays offered for a one-shot run, enabled while running and disabled while :pausing" do
      running =
        render_action_card(%{id: "t_oneshot", status: :running, session_mode: "oneshot"})
        |> parse()

      assert [pause] = Floki.find(running, "button[phx-click='open_pause_modal']")
      refute disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pause"

      pausing =
        render_action_card(%{id: "t_oneshot", status: :pausing, session_mode: "oneshot"})
        |> parse()

      assert [pause] = Floki.find(pausing, "button[phx-click='open_pause_modal']")
      assert disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pausing…"
    end

    test "a card without session_mode renders normally and still offers Pause" do
      # Hand-built summary maps may lack `session_mode`; the card must not
      # crash and must keep the pre-existing behavior (treated as one-shot).
      html = render_action_card(%{id: "t_legacy", status: :running})
      tree = parse(html)

      assert [pause] = Floki.find(tree, "button[phx-click='open_pause_modal']")
      refute disabled?(pause)
      assert Floki.find(tree, "button[phx-click='open_cancel_modal']") != []
      assert tree |> Floki.find(".badge") |> Floki.text() =~ "Running"
    end

    test "Resume is not gated on session_mode" do
      # A pause can only exist for a non-interactive run, so Resume needs no
      # gate of its own — the control renders from the status alone.
      for session_mode <- ["oneshot", "interactive", nil] do
        task = %{id: "t_resume", status: :paused}
        task = if session_mode, do: Map.put(task, :session_mode, session_mode), else: task

        tree = render_action_card(task) |> parse()

        assert [resume] = Floki.find(tree, "button[phx-click='resume_task']")
        refute disabled?(resume)
        assert Floki.text(resume) |> String.trim() == "Resume"
        assert Floki.find(tree, "button[phx-click='open_pause_modal']") == []
      end
    end

    test "Cancel stays unchanged — :pending/:running/:awaiting_input only, never a paused task" do
      for status <- [:pending, :running, :awaiting_input] do
        tree = render_action_card(%{id: "t_cancel", status: status}) |> parse()
        assert [_] = Floki.find(tree, "button[phx-click='open_cancel_modal']")
      end

      for status <- [:pausing, :paused, :finalizing, :cancelling, :completed, :failed, :cancelled] do
        tree = render_action_card(%{id: "t_cancel", status: status}) |> parse()
        assert Floki.find(tree, "button[phx-click='open_cancel_modal']") == []
      end
    end

    test "Force kill covers :pausing and :paused (Delete is unconditional)" do
      for status <- [:running, :awaiting_input, :cancelling, :pausing, :paused] do
        tree = render_action_card(%{id: "t_kill", status: status}) |> parse()

        assert [_] = Floki.find(tree, "ul.menu button[phx-click='open_force_kill_modal']")
        assert [_] = Floki.find(tree, "ul.menu button[phx-click='delete_task']")

        assert tree |> Floki.find("li.menu-title") |> Floki.text() |> String.trim() ==
                 "Danger zone"
      end

      # Terminal / not-yet-started statuses keep Delete and lose force kill.
      for status <- [:pending, :completed, :failed, :cancelled] do
        tree = render_action_card(%{id: "t_kill", status: status}) |> parse()

        assert Floki.find(tree, "ul.menu button[phx-click='open_force_kill_modal']") == []
        assert [_] = Floki.find(tree, "ul.menu button[phx-click='delete_task']")
        refute Floki.text(tree) =~ "Danger zone"
      end
    end

    test "the badge renders the Pausing…/Paused labels; :pausing pulses, :paused never does" do
      pausing_html = render_action_card(%{id: "t_label", status: :pausing})
      pausing_tree = parse(pausing_html)

      assert pausing_tree |> Floki.find(".badge") |> Floki.text() =~ "Pausing…"
      # Still draining work → pulses in the amber busy family (like :running).
      assert pausing_html =~ "animate-ping"
      assert pausing_html =~ "h-1 opacity-80 bg-warning"

      paused_html = render_action_card(%{id: "t_label", status: :paused})
      paused_tree = parse(paused_html)

      assert paused_tree |> Floki.find(".badge") |> Floki.text() =~ "Paused"
      assert paused_html =~ "h-1 opacity-80 bg-info"
      # Nothing is running → no pulse, and no amber busy styling anywhere.
      refute paused_html =~ "animate-ping"
      refute paused_html =~ "bg-warning"
    end

    test "a :pausing card disables Pause, shows the spinner label and explains the wait" do
      tree = render_action_card(%{id: "t_pausing", status: :pausing}) |> parse()

      assert [pause] = Floki.find(tree, "button[phx-click='open_pause_modal']")
      assert disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pausing…"

      assert [spinner] = Floki.find(pause, "span.loading.loading-spinner")
      assert "loading-xs" in class_list(spinner)

      assert Floki.attribute(pause, "title") ==
               ["The agent finishes its current tool call before stopping"]
    end

    test "the pause/resume buttons of a running/paused task are enabled when nothing is in flight" do
      running = render_action_card(%{id: "t_idle", status: :running}) |> parse()
      assert [pause] = Floki.find(running, "button[phx-click='open_pause_modal']")
      refute disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pause"
      assert Floki.find(pause, "span.loading.loading-spinner") == []

      paused = render_action_card(%{id: "t_idle", status: :paused}) |> parse()
      assert [resume] = Floki.find(paused, "button[phx-click='resume_task']")
      refute disabled?(resume)
      assert Floki.text(resume) |> String.trim() == "Resume"
      assert Floki.find(resume, "span.loading.loading-spinner") == []
    end

    test "an in-flight :action_busy entry disables BOTH buttons and spins the matching one" do
      # A pause call in flight on a still-:running task.
      busy_pause =
        render_action_card(%{id: "t_busy", status: :running}, action_busy: %{"t_busy" => :pause})
        |> parse()

      assert [pause] = Floki.find(busy_pause, "button[phx-click='open_pause_modal']")
      assert disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pausing…"
      assert [_] = Floki.find(pause, "span.loading.loading-spinner")

      # ANY entry for the task also disables Resume — even a `:pause` one.
      pause_entry =
        render_action_card(%{id: "t_busy", status: :paused}, action_busy: %{"t_busy" => :pause})
        |> parse()

      assert [resume] = Floki.find(pause_entry, "button[phx-click='resume_task']")
      assert disabled?(resume)
      assert Floki.text(resume) |> String.trim() == "Resume"

      # The matching `:resume` entry renders its spinner label.
      resume_entry =
        render_action_card(%{id: "t_busy", status: :paused}, action_busy: %{"t_busy" => :resume})
        |> parse()

      assert [resume] = Floki.find(resume_entry, "button[phx-click='resume_task']")
      assert disabled?(resume)
      assert Floki.text(resume) |> String.trim() == "Resuming…"
      assert [_] = Floki.find(resume, "span.loading.loading-spinner")

      # The markers are keyed by task id, so another task's entry is inert.
      other =
        render_action_card(%{id: "t_mine", status: :running}, action_busy: %{"t_other" => :pause})
        |> parse()

      assert [pause] = Floki.find(other, "button[phx-click='open_pause_modal']")
      refute disabled?(pause)
      assert Floki.text(pause) |> String.trim() == "Pause"
    end

    test "a clean pause shows the neutral explainer and resumes directly (no confirmation)" do
      html = render_action_card(%{id: "t_clean", status: :paused, pause_kind: :clean})

      assert html =~ "bg-info/5 border border-info/20"
      assert html =~ "Paused by you — resume continues where it stopped."
      refute html =~ "Resumed after a restart"
      refute html =~ "subagents that were still running"

      assert [resume] = html |> parse() |> Floki.find("button[phx-click='resume_task']")
      assert Floki.attribute(resume, "data-confirm") == []
    end

    test "a dirty pause warns about inconsistent state and confirms before resuming" do
      html = render_action_card(%{id: "t_dirty", status: :paused, pause_kind: :dirty})

      assert html =~ "bg-warning/10 border border-warning/20"

      assert html =~
               "Resumed after a restart: the last tool call may not have completed, so files and background jobs may be inconsistent. Resuming tells the agents so."

      assert html =~ "subagents that were still running"
      assert html =~ "A subagent whose result was already collected is not revived"
      assert html =~ "one with no saved record is reported as lost"
      refute html =~ "Paused by you"

      assert [resume] = html |> parse() |> Floki.find("button[phx-click='resume_task']")

      assert Floki.attribute(resume, "data-confirm") == [
               "Resume anyway? The last tool call may not have completed, so files and background jobs may be inconsistent."
             ]
    end

    test "a legacy paused row without a pause_kind key renders the neutral explainer" do
      # `pause_kind` is read defensively (`Map.get/2`) — a row that predates the
      # column (key absent entirely) must render the clean/neutral variant.
      task = summary_map(%{id: "t_legacy", status: :paused})
      refute Map.has_key?(task, :pause_kind)

      html = render_component(&TaskCardComponents.task_card/1, task: task)

      assert html =~ "Paused by you — resume continues where it stopped."
      refute html =~ "Resumed after a restart"

      assert [resume] = html |> parse() |> Floki.find("button[phx-click='resume_task']")
      assert Floki.attribute(resume, "data-confirm") == []
    end

    test "the explainer renders for no other status (even with a dirty pause_kind)" do
      for status <- [
            :pending,
            :running,
            :pausing,
            :finalizing,
            :cancelling,
            :awaiting_input,
            :completed,
            :failed,
            :cancelled
          ] do
        html = render_action_card(%{id: "t_other", status: status, pause_kind: :dirty})

        refute html =~ "Paused by you"
        refute html =~ "Resumed after a restart"
        refute html =~ "subagents that were still running"
      end
    end

    test "a paused or pausing task is never reviewable" do
      for status <- [:pausing, :paused] do
        html = render_action_card(%{id: "t_rev", status: status})

        refute html =~ "/review/"
        assert Floki.find(parse(html), "a[href*='/review/']") == []
      end

      # `show_review_button?/1` stays a :completed/:cancelled ALLOWLIST.
      for status <- [:completed, :cancelled] do
        html = render_action_card(%{id: "t_rev", status: status})
        assert [_] = Floki.find(parse(html), "a[href*='/review/']")
      end
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

  # Renders the EXPANDED card from a summary fixture — the Model line lives in
  # the "Agents Spawned" panel, which needs the lazily-fetched full row.
  defp render_model_card(overrides) do
    render_component(&TaskCardComponents.task_card/1,
      task: summary_map(overrides),
      show_details: true,
      detail: %{state: :ok, task: %{}}
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

  # Renders the COLLAPSED card from the summary-map shape, handing it an
  # interactive session id through the `session_agent_id` attr (nil = no panel).
  defp render_session_card(overrides, session_agent_id \\ nil) do
    render_component(&TaskCardComponents.task_card/1,
      task: summary_map(overrides),
      session_agent_id: session_agent_id
    )
  end

  # Renders the COLLAPSED card from the summary-map shape plus extra attrs —
  # the pause/resume tests pass `action_busy: %{task_id_string => :pause | :resume}`.
  defp render_action_card(overrides, attrs \\ []) do
    render_component(&TaskCardComponents.task_card/1, [task: summary_map(overrides)] ++ attrs)
  end

  # A boolean HTML attribute (`disabled`) renders without a value; Floki answers
  # `[]` when the attribute is absent.
  defp disabled?(node), do: node |> Floki.attribute("disabled") |> Enum.any?()

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)

  defp class_list(node) do
    node |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
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
