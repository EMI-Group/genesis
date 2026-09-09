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

  Image/audio attachments from the native picker are staged instead of
  appended to the prompt: `handle_binary_attach_result/3` enforces the
  per-task count cap, reads the raw bytes via `EvoDash.AttachedFile.read_kind/2`,
  appends a `%{"type", "name", "media_type", "data"}` entry to the
  `:staged_attachments` assign, and pushes the `picker_result:<picker_id>`
  payload for the chip-row re-render (no textarea write).
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

  # Picker ids for the image/audio attach buttons — must match the
  # `data-picker-id` on their FilePicker hook buttons in
  # EvoDashWeb.TaskFormComponents.task_form/1 and the `@attach_picker_id_image`
  # / `@attach_picker_id_audio` module attributes in EvoDashWeb.ProjectsLive
  # (kept as literals in both modules — a compile-time function call in a
  # module attribute is fragile under parallel compilation).
  @attach_picker_id_image "objective_file_image"
  @attach_picker_id_audio "objective_file_audio"

  # Keep in sync with EvoGit.Attachments in :evo_git (the authoritative
  # validation)
  @max_attachments 4
  @max_attachment_bytes 15 * 1024 * 1024

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

  @doc """
  Stages an image/audio attachment picked via the native file dialog into the
  `:staged_attachments` socket assign (a list of maps with STRING keys
  `%{"type", "name", "media_type", "data"}` — `"data"` holds the RAW binary).

  Called by `EvoDashWeb.ProjectsLive`'s
  `handle_info({:directory_picker_result, <image|audio picker id>, {:ok, path}}, ...)`
  clauses and the `"file_pick_manual"` image/audio branches with the STRING
  kind `"image"` / `"audio"` (the event-boundary vocabulary — the same string
  `EvoDash.AttachedFile.read_kind/2` accepts); callers wrap the returned
  socket: `{:noreply, AttachFile.handle_binary_attach_result(socket, path, "image")}`.

  Enforces the per-task attachment caps declared above (at most
  #{@max_attachments} attachments; the file is never read when the count cap
  is reached — each file is capped at #{div(@max_attachment_bytes, 1024 * 1024)}
  MiB raw, enforced upstream by `read_kind/2`), then reads the bytes via
  `EvoDash.AttachedFile.read_kind/2`.
  Success appends the staged entry and pushes `%{attached: true, name, kind}`
  — deliberately NO `prompt`/`block`: the chip-row re-render is the feedback
  and the FilePicker JS hook must NOT write the textarea. A read failure puts
  a friendly error flash (via `EvoDash.AttachedFile.describe_error/2`) and
  pushes `%{error: true}`.

  The raw bytes live ONLY inside the staged map's `"data"` key — they are
  never rendered, logged, serialized, or sent to the client.
  """
  def handle_binary_attach_result(socket, path, kind) when kind in ["image", "audio"] do
    staged = socket.assigns[:staged_attachments] || []

    if length(staged) >= @max_attachments do
      # zh_CN: 已达每个任务最多可附加文件数的上限，提示用户移除附件或不再添加 → "每个任务最多附加 %{count} 个文件"
      msg = gettext("Maximum of %{count} attachments per task", count: @max_attachments)

      socket
      |> put_flash(:error, msg)
      |> push_event("picker_result:#{picker_id_for(kind)}", %{error: true})
    else
      case EvoDash.AttachedFile.read_kind(path, kind) do
        {:ok, %{type: type, media_type: media_type, bytes: bytes}} ->
          name = Path.basename(path)
          entry = %{"type" => type, "name" => name, "media_type" => media_type, "data" => bytes}

          socket
          |> assign(:staged_attachments, staged ++ [entry])
          |> push_event("picker_result:#{picker_id_for(kind)}", %{
            attached: true,
            name: name,
            kind: kind
          })

        {:error, reason} ->
          # zh_CN: 图片/音频附件无法读取（类型不支持、超过大小上限或文件不可读）→ "附加文件失败"
          msg =
            gettext("Failed to attach file: %{reason}",
              reason: EvoDash.AttachedFile.describe_error(reason, path)
            )

          socket
          |> put_flash(:error, msg)
          |> push_event("picker_result:#{picker_id_for(kind)}", %{error: true})
      end
    end
  end

  # Maps a binary kind string to its picker-result channel. Exhaustive over the
  # kinds accepted by `handle_binary_attach_result/3` (guarded to "image" |
  # "audio"), so no catch-all is needed — a wrong kind is a programming error
  # and should crash loudly rather than silently route to the text channel.
  defp picker_id_for("image"), do: @attach_picker_id_image
  defp picker_id_for("audio"), do: @attach_picker_id_audio
end
