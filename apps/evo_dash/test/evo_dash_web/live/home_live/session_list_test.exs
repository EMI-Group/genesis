defmodule EvoDashWeb.HomeLive.SessionListTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.HomeLive.SessionList` — the `/help` left-rail
  conversation list.

  Three surfaces are covered without mounting a page and without mutating
  global state:

    * `build_rows/3` / `row_title/2` — the PURE, TOTAL row builder (ordering,
      live-over-cached precedence, titles, defensive degradation);
    * `load/1` — the `SessionActions.list/1` boundary, including its
      `{:error, reason}` and non-pair answers (the list runner is a CALL-TIME
      app-env seam, injected and restored in `on_exit`);
    * `session_list/1` HEEx + the `spawn_load/2` / `applied/4` async contract —
      rendered in isolation with `render_component/2` and driven on a
      hand-built `%Phoenix.LiveView.Socket{}`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.HomeLive.SessionList

  # Sentinel for "this seam was not set before the test".
  @unset :__session_list_seam_unset__

  # A spawned loader is a real supervised task; the wait is bounded but generous
  # (this host is shared), like every other async-load budget in the suite.
  @assert_timeout 10_000

  defp seam(key, value) do
    previous = Application.get_env(:evo_dash, key, @unset)

    on_exit(fn ->
      case previous do
        @unset -> Application.delete_env(:evo_dash, key)
        restored -> Application.put_env(:evo_dash, key, restored)
      end
    end)

    Application.put_env(:evo_dash, key, value)
  end

  defp summary(id, status, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        status: status,
        agent_module: EvoGit.Agents.SelfReflective,
        parent_id: nil,
        objective: "session #{id}"
      },
      extra
    )
  end

  defp unique_id do
    1_000_000_000 + System.unique_integer([:positive, :monotonic])
  end

  defp socket(overrides) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          current_node: node(),
          current_node_id: nil,
          current_session_id: nil,
          session_list: [],
          session_list_seq: 0,
          session_list_loading: false,
          session_list_error: nil
        },
        overrides
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp render_panel(assigns) do
    html = render_component(&SessionList.session_list/1, assigns)
    Floki.parse_document!(html)
  end

  defp text(doc, selector) do
    doc |> Floki.find(selector) |> Floki.text() |> String.trim()
  end

  describe "build_rows/3 ordering" do
    test "awaiting rows come first, then running, then cached rows in cached order" do
      rows =
        SessionList.build_rows(
          [summary(3, :awaiting_input), summary(5, :running), summary(4, :awaiting_input)],
          [%{agent_id: 3}, %{agent_id: 4}],
          [6, {7, %{objective: "seven"}}]
        )

      assert Enum.map(rows, & &1.id) == [4, 3, 5, 6, 7]

      assert Enum.map(rows, & &1.marker) == [
               :awaiting_input,
               :awaiting_input,
               :running,
               :ended,
               :ended
             ]

      assert Enum.map(rows, & &1.title) == [
               "session 4",
               "session 3",
               "session 5",
               "Session 6",
               "seven"
             ]
    end

    test "a live session wins over a cached chat with the same id" do
      rows = SessionList.build_rows([summary(5, :running)], [], [5, 9])

      assert Enum.map(rows, & &1.id) == [5, 9]
      assert Enum.count(rows, &(&1.id == 5)) == 1
      assert Enum.find(rows, &(&1.id == 5)).marker == :running
    end

    test "the awaiting list is authoritative for a session parked idle" do
      rows = SessionList.build_rows([summary(8, :running)], [%{"agent_id" => 8}], [])

      assert [%{id: 8, marker: :awaiting_input}] = rows
    end
  end

  describe "row_title/2" do
    test "prefers the first user transcript entry" do
      source = %{
        transcript: [
          %{role: :assistant, text: "an answer"},
          %{role: "user", text: "  the question  "},
          %{role: :user, text: "a later question"}
        ],
        objective: "the objective"
      }

      assert SessionList.row_title(source, 1) == "the question"

      assert SessionList.row_title(%{"transcript" => [%{"role" => "user", "text" => "q2"}]}, 1) ==
               "q2"
    end

    test "falls back to the documented objective/preview/title/message keys (atom and string)" do
      for key <- [
            :objective,
            "objective",
            :objective_preview,
            "objective_preview",
            :title,
            "title",
            :first_message,
            "first_message",
            :message,
            "message"
          ] do
        assert SessionList.row_title(%{key => "from #{inspect(key)}"}, 1) ==
                 "from #{inspect(key)}",
               "expected the title to come from #{inspect(key)}"
      end
    end

    test "blank or unusable sources fall back to a stable non-empty label" do
      assert SessionList.row_title(%{}, 42) == "Session 42"
      assert SessionList.row_title(nil, 42) == "Session 42"
      assert SessionList.row_title(:junk, 42) == "Session 42"
      assert SessionList.row_title(%{objective: "   "}, 42) == "Session 42"
      assert SessionList.row_title(%{objective: nil}, 42) == "Session 42"
      assert SessionList.row_title(%{objective: :atom}, 42) == "Session 42"
      assert SessionList.row_title(%{transcript: :junk}, 42) == "Session 42"

      assert SessionList.row_title(%{transcript: [%{role: :user, text: "   "}]}, 42) ==
               "Session 42"

      assert SessionList.row_title(%{}, "abc") == "Session abc"
      refute SessionList.row_title(%{}, 42) == ""
    end

    test "caps the title at 80 characters" do
      title = String.duplicate("a", 100)

      assert SessionList.row_title(%{objective: title}, 1) == String.duplicate("a", 80)
      assert String.length(SessionList.row_title(%{objective: title}, 1)) == 80
    end
  end

  describe "build_rows/3 totality" do
    test "non-list agent/awaiting answers degrade to the cached rows" do
      assert [%{id: 9, marker: :ended}] = SessionList.build_rows(:junk, :junk, [9])
      assert SessionList.build_rows(nil, nil, :junk) == []
      assert SessionList.build_rows([], [], []) == []
    end

    test "non-map entries and non-positive/invalid cached ids are skipped" do
      rows =
        SessionList.build_rows(
          [:junk, summary(7, :running), "x", nil],
          [%{"agent_id" => 7}, :junk, %{}, %{"agent_id" => "7"}, %{"agent_id" => -1}],
          [0, -1, "3", nil, %{}, 5]
        )

      assert Enum.map(rows, & &1.id) == [7, 5]
      assert Enum.find(rows, &(&1.id == 7)).marker == :awaiting_input
    end

    test "dedupes repeated cached ids" do
      rows = SessionList.build_rows([], [], [6, 6, {6, %{objective: "dup"}}])

      assert [%{id: 6, title: "Session 6", marker: :ended}] = rows
    end
  end

  describe "load/1" do
    test "returns {:error, reason} verbatim from the list seam" do
      seam(:home_session_list_runner, fn _node -> {:error, :boom} end)

      assert SessionList.load(node()) == {:error, :boom}
    end

    test "a non-pair seam answer returns {:ok, cached_rows}" do
      seam(:home_session_list_runner, fn _node -> Process.get(:list_answer) end)

      for answer <- [:garbage, nil, {:ok, [1], :extra}] do
        Process.put(:list_answer, answer)

        assert {:ok, rows} = SessionList.load(node())
        assert is_list(rows)

        assert Enum.all?(rows, &(&1.marker == :ended)),
               "expected only cached rows for #{inspect(answer)}"
      end
    end

    test "a documented pair builds live rows" do
      id = unique_id()
      seam(:home_session_list_runner, fn _node -> {[summary(id, :running)], []} end)

      assert {:ok, rows} = SessionList.load(node())
      assert Enum.any?(rows, &(&1.id == id and &1.marker == :running))
    end
  end

  describe "session_list/1 panel" do
    test "renders the heading and one patch row per conversation" do
      doc =
        render_panel(%{
          session_list: [
            %{id: 3, title: "three", marker: :awaiting_input},
            %{id: 4, title: "four", marker: :running}
          ],
          current_session_id: 4
        })

      assert text(doc, "#chat-session-list h2") == "Conversations"

      assert Floki.find(doc, "a#chat-session-3") |> length() == 1
      assert Floki.find(doc, "a#chat-session-4") |> length() == 1

      assert Floki.find(doc, "a#chat-session-3") |> Floki.attribute("href") == ["/help?session=3"]
      assert Floki.find(doc, "a#chat-session-3") |> Floki.attribute("data-phx-link") == ["patch"]
      assert Floki.find(doc, "a#chat-session-3") |> Floki.attribute("aria-current") == []
      assert Floki.find(doc, "a#chat-session-4") |> Floki.attribute("aria-current") == ["page"]

      assert text(doc, "#chat-session-3 span.truncate") == "three"
      assert text(doc, "#chat-session-4 span.truncate") == "four"
    end

    test "appends the viewed node param to every row's patch URL" do
      doc =
        render_panel(%{
          session_list: [%{id: 3, title: "three", marker: :ended}],
          current_node_id: "t1"
        })

      assert Floki.find(doc, "a#chat-session-3") |> Floki.attribute("href") ==
               ["/help?session=3&node=t1"]
    end

    test "paints the awaiting, running and ended markers distinctly" do
      doc =
        render_panel(%{
          session_list: [
            %{id: 3, title: "three", marker: :awaiting_input},
            %{id: 4, title: "four", marker: :running},
            %{id: 5, title: "five", marker: :ended}
          ]
        })

      awaiting_dot = dot_classes(doc, 3)
      assert awaiting_dot =~ "bg-[oklch(0.68_0.17_290)]"

      running_dot = dot_classes(doc, 4)
      assert running_dot =~ "bg-warning"
      assert running_dot =~ "animate-pulse"

      ended_dot = dot_classes(doc, 5)
      assert ended_dot =~ "bg-base-content/30"

      assert Floki.find(doc, "#chat-session-3") |> Floki.text() =~ "Waiting for you"
      assert Floki.find(doc, "#chat-session-4") |> Floki.text() =~ "Running"
      assert Floki.find(doc, "#chat-session-5") |> Floki.text() =~ "Ended"
    end

    test "renders the empty state when no assigns are supplied at all" do
      doc = render_panel(%{})

      assert text(doc, "#chat-session-list") =~ "No conversations yet."
      assert Floki.find(doc, "a") == []
    end

    test "renders an error alert instead of the empty state" do
      doc = render_panel(%{session_list_error: :boom})

      assert length(Floki.find(doc, "#chat-session-list [role='alert']")) == 1
      assert text(doc, "#chat-session-list [role='alert']") == "Could not load conversations."
      refute text(doc, "#chat-session-list") =~ "No conversations yet."
    end

    test "shows the loading flag without the empty state" do
      doc = render_panel(%{session_list_loading: true})

      assert text(doc, "#chat-session-list") =~ "Loading…"
      refute text(doc, "#chat-session-list") =~ "No conversations yet."
    end

    test "filters out rows whose id, title or marker is unusable" do
      doc =
        render_panel(%{
          session_list: [
            %{id: 0, title: "zero", marker: :ended},
            %{id: 3, title: "three", marker: :ended},
            %{id: 4, title: 42, marker: :ended},
            %{id: 5, title: "five", marker: :weird},
            %{title: "no id", marker: :ended},
            :junk
          ]
        })

      assert Floki.find(doc, "a#chat-session-3") |> length() == 1
      assert Floki.find(doc, "a[id^='chat-session-']") |> length() == 1
    end
  end

  describe "async load contract" do
    test "spawn_load/2 increments the seq, sets loading and sends the NESTED tag" do
      target = :list_target@host
      id = unique_id()
      seam(:home_session_list_runner, fn _node -> {[summary(id, :running)], []} end)

      socket = socket(%{current_node: target, session_list_seq: 2, session_list_error: :stale})
      socket = SessionList.spawn_load(socket, target)

      assert socket.assigns.session_list_seq == 3
      assert socket.assigns.session_list_loading == true
      assert socket.assigns.session_list_error == nil

      assert_receive {{:session_list_loaded, 3, ^target}, {:ok, {:ok, rows}}}, @assert_timeout
      assert Enum.any?(rows, &(&1.id == id and &1.marker == :running))
    end

    test "applied/4 only applies a result whose seq and node still match" do
      viewed = node()
      old_rows = [%{id: 1, title: "old", marker: :ended}]
      fresh_rows = [%{id: 2, title: "fresh", marker: :running}]

      socket =
        socket(%{
          current_node: viewed,
          session_list_seq: 5,
          session_list: old_rows,
          session_list_loading: true
        })

      stale = SessionList.applied(socket, 4, viewed, {:ok, {:ok, fresh_rows}})
      assert stale.assigns.session_list == old_rows
      assert stale.assigns.session_list_loading == true
      assert stale.assigns.session_list_error == nil

      foreign = SessionList.applied(socket, 5, :other@host, {:ok, {:ok, fresh_rows}})
      assert foreign.assigns.session_list == old_rows
      assert foreign.assigns.session_list_loading == true

      current = SessionList.applied(socket, 5, viewed, {:ok, {:ok, fresh_rows}})
      assert current.assigns.session_list == fresh_rows
      assert current.assigns.session_list_loading == false
      assert current.assigns.session_list_error == nil
    end

    test "applied/4 keeps the shown rows and records an error result" do
      viewed = node()
      old_rows = [%{id: 1, title: "old", marker: :ended}]

      socket =
        socket(%{
          current_node: viewed,
          session_list_seq: 5,
          session_list: old_rows,
          session_list_loading: true
        })

      errored = SessionList.applied(socket, 5, viewed, {:error, :boom})
      assert errored.assigns.session_list == old_rows
      assert errored.assigns.session_list_error == :boom
      assert errored.assigns.session_list_loading == false
    end

    test "applied/4 accepts a bare row list and tags an unexpected result" do
      viewed = node()
      rows = [%{id: 2, title: "fresh", marker: :running}]
      socket = socket(%{current_node: viewed, session_list_seq: 5})

      applied = SessionList.applied(socket, 5, viewed, {:ok, rows})
      assert applied.assigns.session_list == rows
      assert applied.assigns.session_list_loading == false

      unexpected = SessionList.applied(socket, 5, viewed, :junk)

      assert unexpected.assigns.session_list_error ==
               {:unexpected_session_list_result, :junk}

      assert unexpected.assigns.session_list_loading == false
    end
  end

  defp dot_classes(doc, id) do
    doc
    |> Floki.find(~s(#chat-session-#{id} span[aria-hidden="true"]))
    |> Floki.attribute("class")
    |> List.first()
    |> to_string()
  end
end
