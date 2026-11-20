defmodule EvoDashWeb.ProjectsLive.Attachments do
  @moduledoc """
  Page-side attachment machinery for `EvoDashWeb.ProjectsLive`.

  `EvoDashWeb.ProjectsLive.AttachFile` owns the READERS and the ONE result
  applier; this module owns the PAGE STATE around them — the `:attach_pending`
  guard, the `:file_pick_bases` prompt snapshots and the dispatch into the
  readers — so the page keeps only thin delegating clauses.

  ## Contract

  Every function takes the LiveView socket and returns the updated socket; the
  page's `handle_event`/`handle_info` clauses stay wrappers with the SAME
  message tags and guards, so no message is re-tagged, reordered or dropped.

    * `manual/2` — the `"file_pick_manual"` event body: the FilePicker JS hook
      reveals an inline path input when the native picker is unavailable and
      submits the typed path here. Validates the path, snapshots the submitted
      textarea value into `:file_pick_bases` (identical base-prompt semantics
      to the native flow) and starts the read.
    * `start_pick/3` — the native `{:directory_picker_result, picker_id,
      {:ok, path}}` dispatch for the three attachment picker ids: the text id
      starts a text read, the image/audio ids start a binary read.
    * `loaded/5` — the ONE applier of `{{:attachment_loaded, picker_id, path,
      kind}, result}`, the plain-`send/2` message an off-process read delivers.

  ## Invariants

  - `:attach_pending` (`picker_id => base prompt`) is the guard: an entry is
    written when a read STARTS and removed exactly ONCE, when its result is
    applied, so one pick can never append a file twice and a superseded pick
    (or a node switch, which clears the map together with `:file_pick_bases`
    and `:staged_attachments`) is dropped instead of applied on top of a newer
    prompt.
  - A file is NEVER read in the LiveView process: reads run in
    `EvoDash.TaskSupervisor` via `AttachFile.start_text_read/3` /
    `start_binary_read/4`, and a REFUSED start is surfaced through
    `AttachFile.handle_loaded/6` exactly like a failed read, so no affordance
    can hang waiting for a message that will never arrive.
  - The objective textarea is `phx-update="ignore"` (the DOM is authoritative),
    so text content reaches the client only as the
    `picker_result:<picker_id>` push the FilePicker hook writes; those payload
    shapes and the picker ids are owned by
    `EvoDashWeb.ProjectsLive.AttachFile` and re-declared here as literals
    (a compile-time function call in a module attribute is fragile under
    parallel compilation).
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias EvoDashWeb.ProjectsLive.AttachFile

  # Picker id for the objective editor's attach-file button — must match the
  # `data-picker-id` on the FilePicker hook button in
  # EvoDashWeb.TaskFormComponents.task_form/1, the `@attach_picker_id` literal
  # in AttachFile and the module attribute in EvoDashWeb.ProjectsLive.
  @attach_picker_id "objective_file"

  # Picker ids for the image/audio attach buttons — same literal-duplication
  # contract as @attach_picker_id (they pair with the AttachFile literals and
  # the page's clause heads).
  @attach_picker_id_image "objective_file_image"
  @attach_picker_id_audio "objective_file_audio"

  @typedoc "The LiveView socket these helpers read and re-assign."
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The `"file_pick_manual"` event body: validates the typed path and starts the
  matching attachment read for `params`.

  `params` is read defensively (`Map.get/3`) so legacy callers/tests sending
  only `picker_id` + `path` still work; `kind` defaults to `"text"`.

  An empty/missing/non-binary path and a path that is not a regular file are
  refused WITHOUT touching `:file_pick_bases` (the prompt and the inline error
  stay put, the input stays open). Otherwise the submitted textarea value is
  snapshotted as the base prompt and the read starts — text for any unknown
  kind, the kind's own picker channel for image/audio.
  """
  @spec manual(socket(), map()) :: socket()
  def manual(socket, params) do
    picker_id = Map.get(params, "picker_id", @attach_picker_id)
    path = Map.get(params, "path")
    prompt = Map.get(params, "prompt")
    prompt = if is_binary(prompt), do: prompt, else: ""

    # Kind ("text" | "image" | "audio") selects the attachment pipeline in the
    # `true` branch below; absent in legacy callers/tests → text. The two
    # path-validation branches above apply to ALL kinds.
    kind = Map.get(params, "kind", "text")

    cond do
      not is_binary(path) or path == "" ->
        # zh_CN: 手动输入为空 → "请输入文件路径。"
        reason = gettext("Please enter a file path.")
        push_manual_attach_error(socket, picker_id, reason)

      not File.regular?(path) ->
        # zh_CN: 输入的路径不是可读文件 → "文件不存在：%{path}"
        reason = gettext("File not found: %{path}", path: path)
        push_manual_attach_error(socket, picker_id, reason)

      true ->
        socket =
          assign(
            socket,
            :file_pick_bases,
            Map.put(socket.assigns.file_pick_bases, picker_id, prompt)
          )

        # The file is NEVER read here: a 15 MiB image or a large PDF would
        # freeze the tab. The pick is recorded in :attach_pending and the read
        # runs in a supervised task; its outcome arrives as an
        # `{{:attachment_loaded, picker_id, path, kind}, result}` message (see
        # loaded/5), which flashes the same errors this branch used to.
        case kind do
          # Image/audio files route to the binary staging flow: raw bytes are
          # staged in-memory (base64 encoding happens only at submit) behind
          # the per-task count cap. The picker-id channel is the KIND's own
          # (the binary buttons' ids), exactly as before.
          "image" -> start_binary_attach(socket, @attach_picker_id_image, path, kind)
          "audio" -> start_binary_attach(socket, @attach_picker_id_audio, path, kind)
          # Text (and any unknown kind, defaulting to text): the original text
          # pipeline, now off-process.
          _ -> start_text_attach(socket, picker_id, path)
        end
    end
  end

  @doc """
  Dispatches a native picker result on one of the three attachment picker ids:
  the text id starts a text read, the image/audio ids start a binary read.

  The kind is implied by the picker id, so the three page clauses (which must
  stay pattern-identical on those exact ids) all delegate here. Total for any
  other id: it is treated as a text pick.
  """
  @spec start_pick(socket(), String.t(), String.t()) :: socket()
  def start_pick(socket, @attach_picker_id, path),
    do: start_text_attach(socket, @attach_picker_id, path)

  def start_pick(socket, @attach_picker_id_image, path),
    do: start_binary_attach(socket, @attach_picker_id_image, path, "image")

  def start_pick(socket, @attach_picker_id_audio, path),
    do: start_binary_attach(socket, @attach_picker_id_audio, path, "audio")

  def start_pick(socket, picker_id, path), do: start_text_attach(socket, picker_id, path)

  @doc """
  Applies ONE off-process read outcome — the guard around
  `AttachFile.handle_loaded/6`.

  A result whose picker id is no longer pending was superseded by a newer pick
  for the same picker (or discarded by a node switch), so it is dropped
  instead of being applied on top of a newer prompt. Otherwise the entry is
  removed exactly once and the outcome is applied with the base prompt
  snapshotted when that pick started.
  """
  @spec loaded(socket(), String.t() | nil, String.t() | nil, term(), term()) :: socket()
  def loaded(socket, picker_id, path, kind, result) do
    pending = socket.assigns.attach_pending

    if Map.has_key?(pending, picker_id) do
      base = Map.get(pending, picker_id)

      socket
      |> assign(:attach_pending, Map.delete(pending, picker_id))
      |> AttachFile.handle_loaded(picker_id, path, kind, base, result)
    else
      socket
    end
  end

  # Attach-file flow, async half: start the TEXT read for `path` off-process.
  #
  # The prompt snapshot taken when the pick started becomes the base the file's
  # content is appended to, and it is ALSO the pending marker the
  # `{{:attachment_loaded, ...}}` handler keys on (see the :attach_pending
  # seed). A refused start (non-binary path, dead supervisor) is surfaced
  # through AttachFile.handle_loaded/6 exactly like a failed read, so the user
  # always gets the friendly error flash plus `%{error: true}`.
  defp start_text_attach(socket, picker_id, path) do
    base =
      case Map.fetch(socket.assigns.file_pick_bases, picker_id) do
        {:ok, base} when is_binary(base) -> base
        _other -> socket.assigns[:task_prompt] || ""
      end

    socket = put_attach_pending(socket, picker_id, base)

    case AttachFile.start_text_read(self(), picker_id, path) do
      :ok ->
        socket

      {:error, reason} ->
        socket
        |> drop_attach_pending(picker_id)
        |> AttachFile.handle_loaded(picker_id, path, :text, base, {:error, reason})
    end
  end

  # Attach-file flow, async half: start the IMAGE/AUDIO byte read for `path`
  # off-process. The per-task count cap (4 attachments) is refused BEFORE
  # spawning, so a capped task never reads the file; the base prompt is unused
  # for binary kinds (raw bytes are staged, base64 happens at submit).
  defp start_binary_attach(socket, picker_id, path, kind) do
    if AttachFile.count_cap_reached?(length(socket.assigns.staged_attachments)) do
      AttachFile.push_count_cap_error(socket, kind)
    else
      socket = put_attach_pending(socket, picker_id, "")

      case AttachFile.start_binary_read(self(), picker_id, path, kind) do
        :ok ->
          socket

        {:error, reason} ->
          socket
          |> drop_attach_pending(picker_id)
          |> AttachFile.handle_loaded(picker_id, path, kind_atom(kind), "", {:error, reason})
      end
    end
  end

  defp put_attach_pending(socket, picker_id, base) do
    assign(socket, :attach_pending, Map.put(socket.assigns.attach_pending, picker_id, base))
  end

  defp drop_attach_pending(socket, picker_id) do
    assign(socket, :attach_pending, Map.delete(socket.assigns.attach_pending, picker_id))
  end

  # The read's kind ATOM — the vocabulary AttachFile.handle_loaded/6 applies
  # ("image" / "audio" are the only binary kinds; anything else is text).
  defp kind_atom("image"), do: :image
  defp kind_atom("audio"), do: :audio
  defp kind_atom(_kind), do: :text

  # Validation failure in the manual attach flow: error flash (native flow
  # parity) + `%{error: true, reason: ...}` push — the FilePicker hook shows
  # the reason inline next to the path input and keeps it open.
  defp push_manual_attach_error(socket, picker_id, reason) do
    socket
    |> put_flash(:error, reason)
    |> push_event("picker_result:#{picker_id}", %{error: true, reason: reason})
  end
end
