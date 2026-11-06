defmodule EvoDashWeb.HomeLive.ApprovalCardRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.ApprovalCard

  # Pure rendering avoids /help mounts and their process-global ChatHistory writes.
  # Nothing in these fixtures evaluates code, sends decisions, or starts a task.
  defp card(request, opts \\ []) do
    render_component(&ApprovalCard.approval_card/1, Keyword.put(opts, :request, request))
    |> Floki.parse_document!()
  end

  defp evaluator(tier, overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "eval-<request>&1",
        kind: :elixir_eval,
        tier: tier,
        target_node: :"genesis_remote_fixture@127.0.0.1",
        code: "Config.put(:enabled, true)",
        # A stale legacy field must not override evaluator presentation.
        level: 3
      },
      overrides
    )
  end

  defp text(dom, selector), do: dom |> Floki.find(selector) |> Floki.text() |> String.trim()

  defp classes(dom, selector) do
    dom |> Floki.find(selector) |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)
  end

  defp assert_decisions(dom, request_id, busy?) do
    buttons = Floki.find(dom, "button")
    assert length(buttons) == 2

    assert Enum.map(buttons, &Floki.attribute([&1], "phx-value-decision")) == [
             ["approve"],
             ["deny"]
           ]

    for {"button", attrs, _children} = button <- buttons do
      assert Floki.attribute([button], "type") == ["button"]
      assert Floki.attribute([button], "phx-click") == ["approval_response"]
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

  test "write permission is for this exact code once on the exact target, never future evaluations" do
    dom = card(evaluator(:write))

    assert text(dom, "h3") == "Allow this Elixir code once?"

    assert text(dom, "p.leading-relaxed") ==
             "Allow one execution of exactly the code below on this target runtime. This is not permission for future evaluations."

    assert text(dom, "p.break-all") ==
             "Target runtime: genesis_remote_fixture@127.0.0.1"

    assert text(dom, "button[phx-value-decision='approve']") == "Allow once"
    assert text(dom, "button[phx-value-decision='deny']") == "Deny"
    assert Floki.find(dom, ".badge") == []
    refute Floki.text(dom) =~ "Level"
    refute Floki.text(dom) =~ "Confirm"
    refute Floki.text(dom) =~ "OS root"
    assert_decisions(dom, "eval-<request>&1", false)
  end

  test "write and sudo preserve long original Elixir including whitespace and escaped HTML characters" do
    code =
      "\nif value < 10 && enabled do\n  IO.puts(\"<script>alert('x')</script> & \\\"quoted\\\"\")\n" <>
        "  # " <>
        String.duplicate("untruncated <>& content ", 1_000) <>
        "\n  :last_line\nend\n\n"

    for tier <- [:write, :sudo] do
      dom = card(evaluator(tier, %{code: code}))

      # Do not trim or normalize: the approval must show precisely what runs.
      assert dom |> Floki.find("pre code") |> Floki.text() == code
      assert length(Floki.find(dom, "pre code")) == 1
      assert Floki.find(dom, "script") == []
      assert "overflow-auto" in classes(dom, "pre")
      assert "whitespace-pre-wrap" in classes(dom, "pre")
    end
  end

  test "sudo warns about the live runtime, mutable state, no rollback and no OS root, plus request warning" do
    warning = "Unrestricted <Elixir> & side effects\n  Check this exact request."
    dom = card(evaluator(:sudo, %{warning: warning, level: 2}))

    assert text(dom, "h3") == "Danger — unrestricted Elixir execution"

    assert text(dom, "p.leading-relaxed") ==
             "This runs unrestricted ordinary Elixir in the target's live runtime. It can change running processes, files and configuration. There is no rollback. This is not OS root access. Approve only if you trust this exact code."

    assert text(dom, "p.break-all") ==
             "Target runtime: genesis_remote_fixture@127.0.0.1"

    assert text(dom, "p.text-error") == warning

    assert text(dom, "button[phx-value-decision='approve']") ==
             "Allow unrestricted execution once"

    assert Floki.find(dom, ".badge") == []
    refute Floki.text(dom) =~ "Level"
    refute Floki.text(dom) =~ "Confirm"
    assert_decisions(dom, "eval-<request>&1", false)
  end

  test "evaluator write is informational while sudo is unmistakably danger styled" do
    for {tier, frame, heading, icon, button, absent} <- [
          {:write, "border-info/30", "text-info", "hero-information-circle", "btn-primary",
           "bg-error/10"},
          {:sudo, "border-error/40", "text-error", "hero-exclamation-triangle", "btn-error",
           "bg-info/10"}
        ] do
      dom = card(evaluator(tier))

      assert frame in classes(dom, ".rounded-lg")
      assert heading in classes(dom, "h3")
      assert heading in classes(dom, "span.#{icon}")
      assert button in classes(dom, "button[phx-value-decision='approve']")
      assert "btn-ghost" in classes(dom, "button[phx-value-decision='deny']")
      refute absent in classes(dom, ".rounded-lg")
    end
  end

  test "busy disables both decisions without changing their request identity or payload" do
    for request <- [
          evaluator(:write),
          evaluator(:sudo),
          %{request_id: "legacy-busy", level: 2, command: "ListTasks.list_tasks", args: ""}
        ] do
      dom = card(request, busy: true)
      assert_decisions(dom, request.request_id, true)
    end
  end

  test "legacy level 2 and 3 retain command, args, Confirm and their distinct level styling" do
    command = "StartTask.start_task"
    args = "evolve \"Fix <this> & that\"\n  --path /project"

    for {level, title, badge, button} <- [
          {2, "The assistant wants your attention", "badge-info", "btn-primary"},
          {3, "Action required — real side effects", "badge-error", "btn-error"}
        ] do
      request = %{request_id: "legacy-#{level}", level: level, command: command, args: args}
      dom = card(request)

      assert text(dom, "h3") == title
      assert text(dom, ".badge") == "Level #{level}"
      assert badge in classes(dom, ".badge")
      assert button in classes(dom, "button[phx-value-decision='approve']")
      assert text(dom, "code") == command
      assert text(dom, "p.whitespace-pre-wrap") == args
      assert text(dom, "button[phx-value-decision='approve']") == "Confirm"
      assert text(dom, "button[phx-value-decision='deny']") == "Deny"
      assert Floki.find(dom, "pre, p.break-all") == []
      assert_decisions(dom, request.request_id, false)

      if level == 3 do
        assert text(dom, "h3 + .badge") == "Level 3"

        assert Floki.text(dom) =~
                 "This action has real side effects — the assistant is starting, cancelling, force-killing, or deleting a task."
      else
        assert Floki.text(dom) =~ "It is asking you to confirm an action before it continues."
      end
    end
  end

  test "missing target is honestly unknown, empty code is preserved, and absent optional text is omitted" do
    for target <- [nil, "untrusted-node-string"] do
      dom = card(evaluator(:sudo, %{target_node: target, code: "", warning: nil}))

      assert text(dom, "p.break-all") == "Target runtime: Unknown target"
      assert length(Floki.find(dom, "pre code")) == 1
      assert dom |> Floki.find("pre code") |> Floki.text() == ""
      assert Floki.find(dom, "p.text-error") == []
    end

    dom = card(%{request_id: "legacy-no-args", level: 2, command: "ListTasks.list_tasks"})
    assert text(dom, "code") == "ListTasks.list_tasks"
    assert Floki.find(dom, "p.whitespace-pre-wrap") == []
    assert_decisions(dom, "legacy-no-args", false)
  end
end
