defmodule EvoDashWeb.ProjectsLive.TaskComposerTest do
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @async_wait_budget_ms 30_000
  @shell ".workbench-composer[data-composer-kind=task]"
  @form "#{@shell} form#task-form"

  test "New task mounts one shared editor and its quality control updates the project draft", %{
    conn: conn
  } do
    root = EvoDash.Test.ConfigDir.isolate!("evodash-task-composer")
    EvoGit.Config.VersionState.complete_onboarding()
    project = Path.join(root, "project with spaces")
    File.mkdir!(project)

    {:ok, view, _} = live(conn, ~p"/projects?#{%{project: project}}")
    refute has_element?(view, ".workbench-composer")

    view |> element("#overview-new-task", "New task") |> render_click()

    assert %URI{path: "/projects", query: query} =
             view |> assert_patch(@async_wait_budget_ms) |> URI.parse()

    assert URI.decode_query(query) == %{"project" => project, "wb_task" => "1"}
    refute has_element?(view, "#workbench-project-overview")

    doc = view |> render() |> Floki.parse_document!()
    assert [_] = Floki.find(doc, ".workbench-composer")
    assert [_] = Floki.find(doc, "form#task-form")

    assert has_element?(view, "#workbench-task-composer #{@form}[phx-submit=task_submit]")
    assert has_element?(view, "#{@form} textarea#prompt[name=prompt][phx-hook=AdaptiveInput]")
    assert has_element?(view, "#{@form} button#task-launch-button[type=submit]")

    balanced = "#{@form} #quality-level-balanced"
    high = "#{@form} #quality-level-high_quality"
    assert has_element?(view, ~s(#{balanced}[aria-pressed="true"]))
    assert has_element?(view, ~s(#{high}[aria-pressed="false"]))

    view |> element(high, "High quality") |> render_click()

    assert has_element?(view, ~s(#{balanced}[aria-pressed="false"]))
    assert has_element?(view, ~s(#{high}[aria-pressed="true"]))

    assert_push_event(
      view,
      "persist_state",
      %{project: ^project, quality_level: "high_quality"},
      @async_wait_budget_ms
    )
  end
end

defmodule EvoDashWeb.ProjectsLive.AssistantComposerTest do
  # Following the live navigation mounts HomeLive and writes the shared ChatHistory.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @async_wait_budget_ms 30_000
  @poll_interval_ms 2
  @shell ".workbench-composer[data-composer-kind=assistant]"
  @form "#{@shell} form#chat-form"
  @input "#{@form} textarea#chat-message-input[name=message][phx-hook=AssistantComposer]"

  test "Chat with Assistant opens a project-scoped shared composer and keeps an unsent draft", %{
    conn: conn
  } do
    root = EvoDash.Test.ConfigDir.isolate!("evodash-assistant-composer")
    EvoGit.Config.VersionState.complete_onboarding()
    project = Path.join(root, "project with spaces")
    File.mkdir!(project)
    assert {:ok, mount} = EvoGit.VCT.mount(project, name: "Composer fixture")
    on_exit(fn -> EvoGit.VCT.forget(mount.point) end)

    {:ok, projects, _} = live(conn, ~p"/projects?#{%{project: project}}")
    assert has_element?(projects, "#workbench-project-overview [data-overview-path]", project)
    refute has_element?(projects, ".workbench-composer")

    await_assistant_link(projects, project)

    navigation =
      projects |> element("a#overview-chat-assistant", "Chat with Assistant") |> render_click()

    assert {:error, {:live_redirect, %{to: url}}} = navigation
    assert %URI{path: "/assistant", query: query} = URI.parse(url)
    params = URI.decode_query(query)
    assert %{"wb_project" => ^project, "wb_draft" => draft} = params
    assert draft =~ ~r/\A[0-9a-f]{24}\z/
    refute Map.has_key?(params, "session")

    on_exit(fn ->
      for token <- [project, mount.point] do
        EvoDash.ChatHistory.delete_draft({:workbench, {nil, node(), token, draft}})
      end
    end)

    assert {:ok, assistant, _} = follow_redirect(navigation, conn, url)
    await_project(assistant, project)

    doc = assistant |> render() |> Floki.parse_document!()
    assert [_] = Floki.find(doc, ".workbench-composer")
    assert [_] = Floki.find(doc, "form#chat-form")
    assert Floki.text(Floki.find(doc, @input)) == ""

    assert has_element?(
             assistant,
             "#assistant-surface #{@form}[phx-change=chat_input][phx-submit=send_message]"
           )

    assert has_element?(assistant, "#{@input}:not([disabled])")
    assert has_element?(assistant, "#{@shell} #chat-llm-selection")
    assert has_element?(assistant, "#{@shell} button[type=submit][form=chat-form]", "Send")
    assert has_element?(assistant, ~s(#chat-header p[title="#{project}"]), mount.name)

    assert has_element?(
             assistant,
             ~s(#app-layout[data-workbench-draft="#{draft}"][data-workbench-draft-project="#{project}"])
           )

    message = "Draft a plan for <this project>."
    assistant |> form(@form, %{"message" => message}) |> render_change()

    assert has_element?(assistant, @input, message)
    refute has_element?(assistant, "#app-layout[data-workbench-session]")
    refute has_element?(assistant, "#chat-messages", message)

    GenServer.stop(assistant.pid)
    {:ok, reopened, _} = live(recycle(conn), url)
    await_project(reopened, project)

    assert has_element?(reopened, @input, message)
    refute has_element?(reopened, "#app-layout[data-workbench-session]")
  end

  defp await_project(view, project) do
    await_project(view, project, System.monotonic_time(:millisecond) + @async_wait_budget_ms)
  end

  # The overview's Assistant entry point, awaited as the page's OWN rendered
  # evidence. `Overview.assistant_path/1` stays nil until the connected mount's
  # async VCT batch has APPLIED this project's registry row — `confirmed_scope?/2`
  # matches the mount in `assigns[:projects]` and the mount seeds `projects: []`
  # (`{:async_project_load, …}` fills it a frame later) — so the overview first
  # renders a DISABLED `button#overview-chat-assistant` beside the "Open this
  # project through the project picker" hint. The enabled link IS the claim.
  defp await_assistant_link(view, project) do
    await_assistant_link(
      view,
      project,
      System.monotonic_time(:millisecond) + @async_wait_budget_ms
    )
  end

  defp await_assistant_link(view, project, deadline) do
    selector = "#workbench-project-overview a#overview-chat-assistant[href]"

    cond do
      has_element?(view, selector) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("""
        The Assistant link for #{project} did not render within #{@async_wait_budget_ms} ms.
        #{assistant_entry_report(view)}\
        """)

      true ->
        # The suites' poll cadence: a bounded receive, never a fixed wait.
        receive do
        after
          @poll_interval_ms -> :ok
        end

        await_assistant_link(view, project, deadline)
    end
  end

  # The failing render named clause by clause, so a timeout says WHICH overview
  # state the page was still in instead of "an element was missing".
  defp assistant_entry_report(view) do
    doc = view |> render() |> Floki.parse_document!()
    disabled? = Floki.find(doc, "button#overview-chat-assistant[disabled]") != []
    hint? = Floki.find(doc, "#overview-assistant-project-picker") != []

    """
    Overview state at the deadline:
      disabled button#overview-chat-assistant: #{disabled?}
      project-picker hint rendered:           #{hint?}
      loaded registry paths:                  #{inspect(registry_paths(view))}
    """
  end

  defp registry_paths(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid, @async_wait_budget_ms)

    assigns[:projects]
    |> List.wrap()
    |> Enum.flat_map(fn
      %{path: path} when is_binary(path) -> [path]
      _other -> []
    end)
  end

  defp await_project(view, project, deadline) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid, @async_wait_budget_ms)

    cond do
      match?(%{path: ^project}, assigns.workspace) ->
        :ok

      assigns.workspace_error ->
        flunk("Could not resolve project draft: #{assigns.workspace_error}")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Project draft did not resolve")

      true ->
        Process.sleep(@poll_interval_ms)
        await_project(view, project, deadline)
    end
  end
end
