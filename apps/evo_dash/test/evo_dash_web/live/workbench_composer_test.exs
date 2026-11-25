defmodule EvoDashWeb.WorkbenchComposerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvoDashWeb.HomeLive.Composer
  alias EvoDashWeb.ProjectsLive.RemoteView
  alias EvoDashWeb.TaskFormComponents

  @surface ".workbench-composer-surface"
  @editor ".workbench-composer-editor"
  @toolbar ".workbench-composer-toolbar"
  @options ".workbench-task-options"

  # Exercise the public renderers used by each page without mounting a LiveView
  # (in particular, a connected Assistant mount writes to shared ChatHistory).
  for {layout, draft} <- [
        {"compact", "Refine the parser"},
        {"expanded", String.duplicate("x", 1301)}
      ] do
    test "New Task keeps its editor and launch controls in the shared #{layout} surface" do
      draft = unquote(draft)

      dom =
        render(&TaskFormComponents.task_form/1,
          prompt: draft,
          mode: "evolve_simple",
          model_spec: %{"provider_profile_id" => "test", "model" => "test-model"},
          show_options: false
        )

      assert [_] =
               Floki.find(dom, "#input-layout[data-layout=#{unquote(layout)}] #{@surface}")

      {editor, toolbar} = composer_regions(dom, "task")

      assert [prompt] = within(editor, "textarea#prompt[name=prompt][phx-hook=AdaptiveInput]")
      assert Floki.text(prompt) == draft

      assert [task_form] = Floki.find(dom, "form#task-form[phx-submit=task_submit]")
      assert [^prompt] = within(task_form, "textarea#prompt")
      assert [_] = within(task_form, "input[type=hidden][name=mode][value=evolve_simple]")

      assert [_] = within(toolbar, "#objective-file-attach[phx-hook=FilePicker]")

      assert [_] =
               within(
                 toolbar,
                 "#mode-speed-capsule [phx-click=select_quality_level][phx-value-level=balanced]"
               )

      assert [_] = within(toolbar, "#task-llm-selection")
      assert [launch] = within(toolbar, "button#task-launch-button[type=submit]:not([disabled])")

      # A real submit must target task-form, by ancestry or explicit ownership.
      assert [^launch] =
               Floki.find(
                 dom,
                 "#task-form #task-launch-button:not([form]), #task-launch-button[form=task-form]"
               )

      assert Floki.find(
               dom,
               "#chat-form, #chat-message-input, [phx-submit=send_message], #{@options}, #task-options"
             ) == []
    end
  end

  test "Assistant keeps its message, attachment, send and stop controls in the shared surface" do
    dom =
      render(&Composer.composer/1,
        chat_draft: "Explain the parser",
        chat_status: :running,
        model_snapshot: %{node: node(), config: %{}}
      )

    {editor, toolbar} = composer_regions(dom, "assistant")

    assert [message] =
             within(
               editor,
               "textarea#chat-message-input[name=message][phx-hook=AssistantComposer]"
             )

    assert Floki.text(message) == "Explain the parser"

    assert [chat_form] =
             Floki.find(dom, "form#chat-form[phx-submit=send_message][phx-change=chat_input]")

    assert [^message] = within(chat_form, "textarea#chat-message-input")
    assert Floki.find(dom, "#chat-form form") == []

    assert [_] = within(toolbar, "#chat-llm-selection")

    assert [_] =
             within(
               toolbar,
               "#chat-attach-menu form#chat-attach-manual-form[phx-submit=chat_attach_manual]"
             )

    assert [_] =
             within(
               toolbar,
               "button[type=submit][form=chat-form]:not([phx-click]):not([disabled]):not(.hidden)"
             )

    assert [_] =
             within(toolbar, "button[type=button][phx-click=stop]:not([disabled]):not(.hidden)")

    assert Floki.find(
             dom,
             "#task-form, #prompt, #task-launch-button, [phx-submit=task_submit], #{@options}"
           ) == []
  end

  test "New Task options keep routine and advanced controls associated with the separate task form" do
    dom =
      render(&RemoteView.task_configuration/1,
        active_project_path: "/example",
        inline: true,
        task_mode: "evolve_simple",
        task_starting_commit: "release/next",
        task_archive: true
      )

    assert [options] = Floki.find(dom, @options)
    assert [_] = within(options, "#task-options-title")
    assert [_] = within(options, "input[name=archive][form=task-form][checked]")

    assert [_] =
             within(options, "#persist-agent-state-toggle[phx-click=toggle_persist_agent_state]")

    assert [_] =
             within(
               options,
               "details#task-advanced-options[open] input[name=starting_commit][form=task-form][value='release/next']"
             )

    assert Floki.find(dom, "#{@options} form, #workbench-task-settings #{@options}, #{@surface}") ==
             []
  end

  defp composer_regions(dom, kind) do
    assert [surface] = Floki.find(dom, @surface)

    # Keep variant identity without requiring it to live on the surface itself.
    variant = ".workbench-composer[data-composer-kind=#{kind}]"
    assert [^surface] = Floki.find(dom, "#{variant}#{@surface}, #{variant} #{@surface}")

    assert [editor] = Floki.find(dom, @editor)
    assert [toolbar] = Floki.find(dom, @toolbar)
    assert [^editor, ^toolbar] = within(surface, "#{@editor}, #{@toolbar}")
    assert Floki.find(editor, @toolbar) == []
    assert Floki.find(toolbar, @editor) == []

    {editor, toolbar}
  end

  defp within(node, selector), do: Floki.find([node], selector)

  defp render(component, assigns) do
    component |> render_component(assigns) |> Floki.parse_document!()
  end
end
