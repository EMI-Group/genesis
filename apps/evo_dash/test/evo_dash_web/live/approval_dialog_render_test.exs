defmodule EvoDashWeb.HomeLive.ApprovalDialogRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.ApprovalDialog

  # Pure rendering avoids /assistant mounts and their process-global ChatHistory
  # writes. Nothing in these fixtures evaluates code, sends decisions, or starts
  # a task: the dialog is presentation only, and every decision payload carries
  # just a request identity plus a whitelisted `approve`/`deny` decision.
  defp bar(opts \\ []) do
    render_component(&ApprovalDialog.approval_bar/1, opts)
    |> Floki.parse_document!()
  end

  defp dialog(requests, opts \\ []) do
    assigns =
      opts
      |> Keyword.put(:pending_approvals, List.wrap(requests))
      |> Keyword.put_new(:approval_dialog_index, 0)

    render_component(&ApprovalDialog.approval_dialog/1, assigns)
    |> Floki.parse_document!()
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "eval-<request>&1",
        kind: :elixir_eval,
        tier: :write,
        # `target_text/1` reads `:target`. The core's PUBLIC request maps
        # (`EvoGit.CommandApproval.pending/0` / `request_eval/5`) carry
        # `:target_node`, so a real evaluator dialog currently renders
        # "Unknown target"; the fixtures follow the helper they pin.
        target: :"genesis_remote_fixture@127.0.0.1",
        code: "Config.put(:enabled, true)",
        # A stale legacy field must not override evaluator presentation.
        level: 3
      },
      overrides
    )
  end

  defp text(dom, selector), do: dom |> Floki.find(selector) |> Floki.text() |> String.trim()
  defp attr(dom, selector, name), do: dom |> Floki.find(selector) |> Floki.attribute(name)

  defp classes(dom, selector) do
    dom |> Floki.find(selector) |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)
  end

  defp decisions(dom), do: Floki.find(dom, "button[phx-click='approval_response']")

  defp assert_decisions(dom, request_id, busy?) do
    buttons = decisions(dom)
    assert length(buttons) == 2

    # Deny first, the allow/confirm action second, both driven by the same
    # server-owned request identity.
    assert Enum.map(buttons, &Floki.attribute([&1], "phx-value-decision")) == [
             ["deny"],
             ["approve"]
           ]

    for {"button", attrs, _children} = button <- buttons do
      assert Floki.attribute([button], "type") == ["button"]
      assert Floki.attribute([button], "phx-value-request_id") == [request_id]

      # The server owns the stored code and tier: the client supplies only a
      # request identity and a decision, including for legacy command requests.
      assert attrs
             |> Enum.filter(fn {name, _} -> String.starts_with?(name, "phx-value-") end)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort() == ["phx-value-decision", "phx-value-request_id"]

      assert Enum.any?(attrs, fn {name, _} -> name == "disabled" end) == busy?
    end
  end

  describe "one pending request at a time" do
    test "the dialog is the single-request modal the page mounts on demand" do
      dom = dialog(request())

      assert Floki.find(dom, "dialog#approval-dialog.modal[phx-hook='DialogModal']") != []
      assert text(dom, "dialog header p") == "Approval required"
      assert attr(dom, "button[phx-click='dialog_closed']", "aria-label") == ["Close"]

      # The native dialog is closed by its own backdrop form, which the page's
      # DialogModal hook turns back into `approval_dialog_open: false`.
      assert Floki.find(dom, "dialog form[method='dialog'].modal-backdrop") != []

      # A single pending request needs no stepping chrome at all.
      assert Floki.find(dom, ".badge") == []
      assert Floki.find(dom, "button[phx-click='prev_approval']") == []
      assert Floki.find(dom, "button[phx-click='next_approval']") == []
    end

    test "several pending requests are stepped one at a time with honest bounds" do
      requests = [
        request(%{request_id: "one"}),
        request(%{request_id: "two"}),
        request(%{request_id: "three"})
      ]

      # First of three: "previous" is disabled, "next" is available.
      first = dialog(requests, approval_dialog_index: 0)
      assert text(first, "dialog header .badge") == "1 of 3"
      assert Floki.find(first, "button[phx-click='prev_approval'][disabled]") != []
      assert Floki.find(first, "button[phx-click='next_approval']") != []
      assert Floki.find(first, "button[phx-click='next_approval'][disabled]") == []
      assert_decisions(first, "one", false)

      # Middle: both directions are available.
      middle = dialog(requests, approval_dialog_index: 1)
      assert text(middle, "dialog header .badge") == "2 of 3"
      assert Floki.find(middle, "button[phx-click='prev_approval'][disabled]") == []
      assert Floki.find(middle, "button[phx-click='next_approval'][disabled]") == []
      assert_decisions(middle, "two", false)

      # Last of three: "next" is disabled, "previous" is available.
      last = dialog(requests, approval_dialog_index: 2)
      assert text(last, "dialog header .badge") == "3 of 3"
      assert Floki.find(last, "button[phx-click='prev_approval']") != []
      assert Floki.find(last, "button[phx-click='prev_approval'][disabled]") == []
      assert Floki.find(last, "button[phx-click='next_approval'][disabled]") != []
      assert_decisions(last, "three", false)

      # An out-of-range cursor never blanks the modal: it clamps to the last
      # request, and `view/2` reports the same clamped position.
      assert {request, 3, 3} = ApprovalDialog.view(requests, 9)
      assert request.request_id == "three"
      assert {request, 1, 3} = ApprovalDialog.view(requests, -4)
      assert request.request_id == "one"
      assert {nil, 0, 0} = ApprovalDialog.view([], 0)
      assert {request, 1, 3} = ApprovalDialog.view(requests, :invalid)
      assert request.request_id == "one"
    end
  end

  describe "evaluator requests" do
    test "write permission is for this exact code once on the exact target, never future evaluations" do
      dom = dialog(request())

      assert text(dom, "h2") == "Allow this Elixir code once?"

      assert text(dom, "p.font-medium.leading-snug") ==
               "Run one piece of Elixir in the Genesis runtime."

      assert text(dom, "p.leading-relaxed") ==
               "Allow one execution of exactly the code below on this target runtime. This is not permission for future evaluations."

      assert text(dom, "p.break-all") ==
               "Target runtime: genesis_remote_fixture@127.0.0.1"

      assert text(dom, "button[phx-value-decision='approve']") == "Allow once"
      assert text(dom, "button[phx-value-decision='deny']") == "Deny"

      # A write grant must not look like the sudo warning, and it is not a
      # legacy command: no sudo heading, no command block, no "Level".
      refute Floki.text(dom) =~ "Unrestricted Elixir"
      refute Floki.text(dom) =~ "Level"
      refute Floki.text(dom) =~ "Confirm"
      refute Floki.text(dom) =~ "OS root"
      assert Floki.find(dom, "div.mt-2 code") == []
      assert_decisions(dom, "eval-<request>&1", false)
    end

    test "write and sudo preserve long original Elixir including whitespace and escaped HTML characters" do
      code =
        "\nif value < 10 && enabled do\n  IO.puts(\"<script>alert('x')</script> & \\\"quoted\\\"\")\n" <>
          "  # " <>
          String.duplicate("untruncated <>& content ", 1_000) <>
          "\n  :last_line\nend\n\n"

      for tier <- [:write, :sudo] do
        dom = dialog(request(%{tier: tier, code: code}))

        # Do not trim or normalize: the approval must show precisely what runs.
        assert dom |> Floki.find("pre code") |> Floki.text() == code
        assert length(Floki.find(dom, "pre code")) == 1
        assert Floki.find(dom, "script") == []
        assert "overflow-auto" in classes(dom, "pre")
        assert "whitespace-pre-wrap" in classes(dom, "pre")
      end
    end

    test "sudo warns about the live runtime, mutable state, no rollback and no OS root" do
      dom = dialog(request(%{tier: :sudo, level: 2}))

      assert text(dom, "h2") == "Danger — unrestricted Elixir execution"

      assert text(dom, "p.font-medium.leading-snug") ==
               "Run unrestricted Elixir in the live Genesis runtime."

      # The distinct sudo warning block: a loudly styled title plus its own
      # body inside one error-tinted frame.
      assert text(dom, "div[class*='border-error/40']") =~ "Unrestricted Elixir — no rollback"

      assert text(dom, "p.leading-relaxed") ==
               "This runs unrestricted ordinary Elixir in the target's live runtime. It can change running processes, files and configuration. There is no rollback. This is not OS root access. Approve only if you trust this exact code."

      assert text(dom, "p.break-all") ==
               "Target runtime: genesis_remote_fixture@127.0.0.1"

      assert text(dom, "button[phx-value-decision='approve']") ==
               "Allow unrestricted execution once"

      refute Floki.text(dom) =~ "Level"
      refute Floki.text(dom) =~ "Confirm"
      assert_decisions(dom, "eval-<request>&1", false)
    end

    test "evaluator write is informational while sudo is unmistakably danger styled" do
      for {tier, badge, icon, icon_class, button, absent} <- [
            {:write, "bg-info/10", "hero-information-circle", "text-info", "btn-primary",
             "bg-error/10"},
            {:sudo, "bg-error/10", "hero-exclamation-triangle", "text-error", "btn-error",
             "bg-info/10"}
          ] do
        dom = dialog(request(%{tier: tier}))

        assert badge in classes(dom, "dialog header > span")
        assert icon_class in classes(dom, "span.#{icon}")
        assert button in classes(dom, "button[phx-value-decision='approve']")
        assert "btn-ghost" in classes(dom, "button[phx-value-decision='deny']")
        refute absent in classes(dom, "dialog header > span")
        # Only the sudo tier owns the extra warning block.
        assert Floki.find(dom, "div[class*='border-error/40']") != [] == (tier == :sudo)
      end
    end

    test "missing target is honestly unknown, empty code is preserved and absent text is omitted" do
      for target <- [nil, "untrusted-node-string"] do
        dom = dialog(request(%{tier: :sudo, target: target, code: ""}))

        assert text(dom, "p.break-all") == "Target runtime: Unknown target"
        assert length(Floki.find(dom, "pre code")) == 1
        assert dom |> Floki.find("pre code") |> Floki.text() == ""
        # Nothing else claims to be a target runtime line.
        assert length(Floki.find(dom, "p.break-all")) == 1
      end
    end
  end

  describe "legacy command requests" do
    test "level 2 and 3 retain command, args, Confirm and their distinct danger styling" do
      command = "StartTask.start_task"
      args = "evolve \"Fix <this> & that\"\n  --path /project"

      for {level, title, summary, button} <- [
            {2, "The assistant wants your attention",
             "Confirm an action before the assistant continues.", "btn-primary"},
            {3, "Action required — real side effects", "Perform a destructive task action.",
             "btn-error"}
          ] do
        request = %{request_id: "legacy-#{level}", level: level, command: command, args: args}
        dom = dialog(request)

        assert text(dom, "h2") == title
        assert text(dom, "p.font-medium.leading-snug") == summary
        assert button in classes(dom, "button[phx-value-decision='approve']")
        assert text(dom, "code") == command
        assert text(dom, "p.whitespace-pre-wrap") == args
        assert text(dom, "button[phx-value-decision='approve']") == "Confirm"
        assert text(dom, "button[phx-value-decision='deny']") == "Deny"

        # No evaluator chrome: no exact-code block, no target runtime line.
        assert Floki.find(dom, "pre, p.break-all") == []
        assert_decisions(dom, request.request_id, false)

        if level == 3 do
          assert Floki.text(dom) =~
                   "This action has real side effects — the assistant is starting, cancelling, force-killing, or deleting a task."
        else
          assert Floki.text(dom) =~ "It is asking you to confirm an action before it continues."
        end
      end
    end

    test "a legacy request without args omits the args paragraph" do
      dom = dialog(%{request_id: "legacy-no-args", level: 2, command: "ListTasks.list_tasks"})

      assert text(dom, "code") == "ListTasks.list_tasks"
      assert Floki.find(dom, "p.whitespace-pre-wrap") == []
      assert_decisions(dom, "legacy-no-args", false)
    end
  end

  describe "in-flight responses" do
    test "busy disables both decisions without changing their request identity or payload" do
      for request <- [
            request(),
            request(%{tier: :sudo}),
            %{request_id: "legacy-busy", level: 2, command: "ListTasks.list_tasks", args: ""}
          ] do
        dom = dialog(request, approval_responses: %{request.request_id => 1})
        assert_decisions(dom, request.request_id, true)
      end

      # Another request's in-flight response never disables this one.
      dom = dialog(request(), approval_responses: %{"someone-else" => 1})
      assert_decisions(dom, "eval-<request>&1", false)
    end
  end

  describe "fixed-height status bar" do
    test "nothing pending reserves the same height and offers no Review button" do
      dom = bar()

      assert Floki.find(dom, "#approval-status-bar") != []
      assert "h-10" in classes(dom, "#approval-status-bar")
      assert "shrink-0" in classes(dom, "#approval-status-bar")

      assert Floki.find(dom, "#approval-status-bar button") == []
      assert Floki.find(dom, "#approval-status-bar .badge") == []
      assert Floki.find(dom, "#approval-status-bar [role='alert']") == []
      assert text(dom, "#approval-status-bar") == ""

      # The reserved height is the SAME whether or not a request is pending, so
      # an arriving/resolved approval never reflows the transcript column.
      pending = bar(pending_approvals: [request()])
      assert classes(pending, "#approval-status-bar") == classes(dom, "#approval-status-bar")
    end

    test "a pending request shows the count badge and the Review action" do
      dom = bar(pending_approvals: [request(), request(%{request_id: "second"})])

      assert text(dom, "#approval-status-bar p") == "Genesis is waiting for your approval"
      assert text(dom, "#approval-status-bar .badge") == "2"
      assert attr(dom, "#approval-status-bar .badge", "aria-label") == ["2 pending approvals"]

      assert attr(dom, "#approval-status-bar button", "phx-click") == ["open_approval_dialog"]
      assert text(dom, "#approval-status-bar button") == "Review"
      assert attr(dom, "#approval-status-bar button", "type") == ["button"]
    end

    test "a recovery error keeps its id, text and retry action, disabled while recovering" do
      error = {:recovery, :timeout}

      dom = bar(approval_error: error)

      assert attr(dom, "#approval-recovery-error", "role") == ["alert"]

      assert attr(dom, "#approval-recovery-error", "title") == [
               "Could not load pending approvals (:timeout) — existing requests are kept; retry to check again."
             ]

      assert text(dom, "#approval-recovery-error") =~
               "Could not load pending approvals (:timeout)"

      assert text(dom, "#approval-recovery-error") =~
               "existing requests are kept; retry to check again."

      assert attr(dom, "#approval-recovery-error", "class") |> List.first() =~ "text-warning"

      assert attr(dom, "button[phx-click='retry_approvals']", "type") == ["button"]
      assert text(dom, "button[phx-click='retry_approvals']") == "Retry approvals"
      assert Floki.find(dom, "button[phx-click='retry_approvals'][disabled]") == []

      recovering = bar(approval_error: error, approval_recovering: true)

      assert Floki.find(recovering, "button[phx-click='retry_approvals'][disabled]") != []
    end

    test "a response error renders only while its request is still pending and no recovery failed" do
      request = request()
      error = {:response, request.request_id, :timeout}

      dom = bar(approval_error: error, pending_approvals: [request])

      assert attr(dom, "#approval-response-error", "role") == ["alert"]

      assert attr(dom, "#approval-response-error", "title") == [
               "Failed to respond (:timeout) — the request is still pending; try again."
             ]

      assert attr(dom, "#approval-response-error", "class") |> List.first() =~ "text-error"
      assert Floki.find(dom, "#approval-recovery-error") == []

      # Resolved (no longer pending) → nothing to retry, so the notice goes.
      assert Floki.find(
               bar(approval_error: error, pending_approvals: []),
               "#approval-response-error"
             ) ==
               []

      assert Floki.find(bar(approval_error: error), "#approval-response-error") == []

      # A recovery failure is the authoritative notice: it owns the strip line.
      both = bar(approval_error: {:recovery, :timeout}, pending_approvals: [request])

      assert Floki.find(both, "#approval-recovery-error") != []
      assert Floki.find(both, "#approval-response-error") == []

      # Any other error shape is not a response failure.
      assert Floki.find(
               bar(approval_error: {:response, "other", :timeout}, pending_approvals: [request]),
               "#approval-response-error"
             ) == []
    end

    test "pending requests and a recovery error coexist in the one reserved line" do
      dom =
        bar(
          pending_approvals: [request()],
          approval_error: {:recovery, :timeout},
          approval_recovering: false
        )

      assert Floki.find(dom, "#approval-recovery-error") != []
      assert Floki.find(dom, "button[phx-click='retry_approvals']") != []
      # The requests themselves stay actionable through the dialog: recovery
      # never hides the Review control for them.
      assert Floki.find(dom, "button[phx-click='open_approval_dialog']") != []
      assert Floki.find(dom, ".badge") != []
    end
  end
end
