defmodule EvoDashWeb.HomeLive.ExecutionIndicatorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.ExecutionIndicator

  defp running(phase, call \\ nil) do
    %{
      chat_status: :running,
      chat_stream: %{delta: %{activity: %{phase: phase, current_call: call}}}
    }
  end

  defp presentation(state, label, busy?, tone \\ :neutral) do
    %{state: state, label: label, busy?: busy?, tone: tone}
  end

  test "authoritative phases distinguish processing from waiting without inferring thinking from content" do
    for {phase, label, busy?, tone} <- [
          {:llm_waiting, "Waiting for model", false, :neutral},
          {:llm, "Generating response…", true, :neutral},
          {:llm_complete, "Preparing next step…", true, :neutral},
          {:retry_wait, "Waiting to retry", false, :warning},
          {:tools, "Running tools…", true, :neutral},
          {:compressing, "Compressing context…", true, :neutral},
          {:preparing, "Preparing next turn…", true, :neutral},
          {:idle, "Preparing next step…", false, :neutral}
        ],
        call <- [nil, %{thinking: "private reasoning"}, %{text: "partial answer"}] do
      assert ExecutionIndicator.state(running(phase, call)) ==
               presentation(phase, label, busy?, tone)
    end
  end

  test "pending approval takes precedence over tools, thinking and streamed answer text" do
    for phase <- [:tools, :llm, :retry_wait],
        call <- [%{thinking: "private reasoning"}, %{text: "partial answer"}],
        count <- [1, 3] do
      assigns = running(phase, call) |> Map.put(:pending_approval_count, count)

      assert ExecutionIndicator.state(assigns) ==
               presentation(:approval, "Waiting for approval", false, :warning)
    end

    # Approval acknowledgements are not pending requests and cannot turn an
    # execution into either a waiting state or a successful tool result.
    assigns = Map.put(running(:tools), :approval_response, :ok)

    for count <- [nil, 0, -1, "1", true] do
      assert ExecutionIndicator.state(Map.put(assigns, :pending_approval_count, count)) ==
               presentation(:tools, "Running tools…", true)
    end
  end

  test "ended lifecycle outranks stale activity, approvals and watch errors" do
    for {task_status, state, label, tone} <- [
          {:failed, :failed, "Failed", :error},
          {:cancelled, :cancelled, "Stopped", :neutral},
          {:completed, :completed, "Completed", :neutral},
          {nil, :ended, "Session ended", :neutral},
          {:unknown, :ended, "Session ended", :neutral}
        ] do
      assigns =
        running(:tools)
        |> Map.merge(%{
          chat_status: :ended,
          chat_task_status: task_status,
          pending_approval_count: 2
        })
        |> put_in([:chat_stream, :error], :session_not_found)

      assert ExecutionIndicator.state(assigns) == presentation(state, label, false, tone)
    end
  end

  test "stopping outranks watch errors and approvals without claiming completion" do
    assigns =
      running(:tools)
      |> Map.merge(%{chat_status: :cancelling, pending_approval_count: 1})
      |> put_in([:chat_stream, :error], :timeout)

    assert ExecutionIndicator.state(assigns) == presentation(:cancelling, "Stopping…", true)
  end

  test "watch failure outranks pending approvals and cached phases, not execution failure" do
    for status <- [:running, :idle, :awaiting_input] do
      assigns =
        running(:tools)
        |> Map.merge(%{chat_status: status, pending_approval_count: 1})
        |> put_in([:chat_stream, :error], {:timeout, :private_detail})

      assert ExecutionIndicator.state(assigns) ==
               presentation(:unavailable, "Live updates unavailable", false, :warning)
    end
  end

  test "idle lifecycle suppresses stale activity but not actual pending approval" do
    for status <- [:idle, :awaiting_input] do
      assigns = Map.put(running(:tools), :chat_status, status)

      assert ExecutionIndicator.state(assigns) ==
               presentation(:idle, "Ready for your message", false)

      assert ExecutionIndicator.state(Map.put(assigns, :pending_approval_count, 1)) ==
               presentation(:approval, "Waiting for approval", false, :warning)
    end
  end

  test "missing or malformed activity stays working, never fabricates thinking or tools" do
    for stream <- [nil, :invalid, %{}, %{delta: :invalid}, %{delta: %{activity: :invalid}}] do
      assert ExecutionIndicator.state(%{chat_status: :running, chat_stream: stream}) ==
               presentation(:working, "Working…", false)
    end

    for phase <- [nil, :unknown, "tools"] do
      assert ExecutionIndicator.state(running(phase, %{thinking: "private", text: "answer"})) ==
               presentation(:working, "Working…", false)
    end

    for assigns <- [nil, :invalid, [], %{}, %{chat_status: "running"}] do
      assert ExecutionIndicator.state(assigns) ==
               presentation(:idle, "Ready for your message", false)
    end
  end

  test "tool states are execution-only and unknown consent is not success" do
    for {status, label, busy?, tone} <- [
          {:running, "Running", true, :neutral},
          {:ok, "Done", false, :neutral},
          {:error, "Failed", false, :error},
          {:timeout, "Timed out", false, :warning}
        ] do
      assert ExecutionIndicator.tool_state(status) == presentation(status, label, busy?, tone)
    end

    for status <- [nil, :approved, :denied, true, "ok", %{}] do
      assert ExecutionIndicator.tool_state(status) ==
               presentation(:unknown, "Status unavailable", false)
    end
  end

  test "render reserves one polite single-line status region with a decorative shared execution dot" do
    doc =
      render_component(&ExecutionIndicator.execution_indicator/1, running(:tools))
      |> Floki.parse_document!()

    [region] = Floki.find(doc, "#assistant-execution-status")
    assert Floki.attribute([region], "role") == ["status"]
    assert Floki.attribute([region], "aria-live") == ["polite"]
    assert Floki.attribute([region], "aria-atomic") == ["true"]
    assert Floki.attribute([region], "aria-busy") == []
    assert Floki.attribute([region], "data-state") == ["tools"]
    assert Floki.attribute([region], "data-busy") == ["true"]
    assert "h-7" in (Floki.attribute([region], "class") |> hd() |> String.split())
    assert length(Floki.find(doc, "[role='status']")) == 1

    [dot] = Floki.find([region], ".assistant-execution-dot")
    assert Floki.attribute([dot], "aria-hidden") == ["true"]
    assert Floki.attribute([dot], "data-state") == ["tools"]
    assert Floki.attribute([dot], "data-busy") == ["true"]
    assert Floki.find([region], "span.truncate") |> Floki.text() == "Running tools…"
    assert Floki.find(doc, "button, .loading-spinner") == []
  end

  test "warning and terminal error rendering stays concise and never leaks stream payloads" do
    base =
      running(:llm, %{thinking: "secret reasoning", text: "secret answer"})
      |> put_in([:chat_stream, :delta, :activity, :tool_arguments], "secret command")
      |> put_in([:chat_stream, :delta, :activity, :total_tokens], 987_654)

    for {assigns, state, label, tone} <- [
          {Map.put(base, :pending_approval_count, 1), "approval", "Waiting for approval",
           "text-warning"},
          {put_in(base, [:chat_stream, :error], "secret error"), "unavailable",
           "Live updates unavailable", "text-warning"},
          {Map.merge(base, %{chat_status: :ended, chat_task_status: :failed}), "failed", "Failed",
           "text-error"}
        ] do
      html = render_component(&ExecutionIndicator.execution_indicator/1, assigns)
      refute html =~ "secret"
      refute html =~ "987654"
      doc = Floki.parse_document!(html)

      [region] = Floki.find(doc, "#assistant-execution-status")
      assert Floki.attribute([region], "data-state") == [state]
      assert Floki.attribute([region], "data-busy") == ["false"]
      assert tone in (Floki.attribute([region], "class") |> hd() |> String.split())
      assert String.trim(Floki.text([region])) == label
    end
  end
end
