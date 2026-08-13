defmodule EvoDashWeb.ProjectsLive.AttachFile do
  @moduledoc """
  Shared attach-file pipeline for the objective editor's "+" button
  (`EvoDashWeb.ProjectsLive`).

  Both entry points funnel into `handle_attach_result/2`:
  - the native picker flow — `handle_info({:directory_picker_result, ...})`
    (EvoDash.DirectoryPicker `:file` mode)
  - the manual path fallback — the `"file_pick_manual"` event (the FilePicker
    JS hook reveals an inline path input when the native picker is
    unavailable and submits the typed path here)

  The base prompt is resolved from the `file_pick_bases` snapshot (seeded by
  the caller from the DOM textarea value at pick/submit time, falling back to
  `task_prompt`), the file is read with `EvoDash.AttachedFile.read/1`, and the
  `picker_result:<picker_id>` payload the FilePicker JS hook consumes is
  pushed. The textarea is `phx-update="ignore"` (the DOM is authoritative), so
  the hook — not the re-render — writes the new prompt into the DOM.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  # Picker id for the objective editor's attach-file button — must match the
  # `data-picker-id` on the FilePicker hook button in
  # EvoDashWeb.TaskFormComponents.task_form/1, the JS hook's
  # `picker_result:<picker_id>` channel, and the `@attach_picker_id` module
  # attribute in EvoDashWeb.ProjectsLive (kept as a literal in both modules —
  # a compile-time function call in a module attribute is fragile under
  # parallel compilation).
  @attach_picker_id "objective_file"

  @doc "The picker id the attach-file \"+\" button and the JS hook use."
  def attach_picker_id, do: @attach_picker_id

  @doc """
  Runs the shared attachment pipeline for `path`: resolves the base prompt
  from the `file_pick_bases` snapshot, reads the file with
  `EvoDash.AttachedFile.read/1`, builds the Markdown block, assigns
  `:task_prompt`, clears the base snapshot, and pushes the
  `picker_result:<picker_id>` payload.

  Success pushes `%{prompt, block, attached: true, name}`; a read failure
  puts an error flash and pushes `%{error: true}`.
  """
  def handle_attach_result(socket, path) do
    base =
      Map.get(
        socket.assigns.file_pick_bases || %{},
        @attach_picker_id,
        socket.assigns.task_prompt || ""
      )

    case EvoDash.AttachedFile.read(path) do
      {:ok, content} ->
        basename = Path.basename(path)
        block = "\n\n---\n## Attached file: #{basename}\n\n" <> content <> "\n"
        new_prompt = base <> block

        socket
        |> assign(:task_prompt, new_prompt)
        |> assign(
          :file_pick_bases,
          Map.delete(socket.assigns.file_pick_bases || %{}, @attach_picker_id)
        )
        |> push_event("picker_result:#{@attach_picker_id}", %{
          prompt: new_prompt,
          block: block,
          attached: true,
          name: basename
        })

      {:error, reason} ->
        # zh_CN: Failed to attach file → "附加文件失败"
        msg =
          gettext("Failed to attach file: %{reason}",
            reason: EvoDash.AttachedFile.describe_error(reason, path)
          )

        socket
        |> put_flash(:error, msg)
        |> push_event("picker_result:#{@attach_picker_id}", %{error: true})
    end
  end
end
