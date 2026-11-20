defmodule EvoDashWeb.ProjectsLive.AttachFile do
  @moduledoc """
  Shared attach-file pipeline for the objective editor's "+" buttons
  (`EvoDashWeb.ProjectsLive`).

  Two entry points funnel into it:
  - the native picker flow — `handle_info({:directory_picker_result, ...})`
    (EvoDash.DirectoryPicker `:file` mode)
  - the manual path fallback — the `"file_pick_manual"` event (the FilePicker
    JS hook reveals an inline path input when the native picker is
    unavailable and submits the typed path here)

  ## The async path (the LiveView never reads a file)

  A read can decode a multi-megabyte PDF/DOCX (or pull 15 MiB of image/audio
  bytes), so it must never run in the LiveView process. The async pairs are:

    * `start_text_read/3` — reads the file in a supervised
      `EvoDash.TaskSupervisor` child via `EvoDash.AttachedFile.read/1`;
    * `start_binary_read/4` — reads image/audio bytes via
      `EvoDash.AttachedFile.read_kind/2` (kind `"image"` / `"audio"`).

  Both answer `:ok` when the read was started, or `{:error, reason}` when it
  was not (nothing is sent to the caller in that case), and both send exactly
  ONE message:

      {{:attachment_loaded, picker_id, path, kind_atom}, result}

  where `kind_atom` is `:text` from `start_text_read/3` and `:image` / `:audio`
  from `start_binary_read/4`, and `result` is the read's own
  `{:ok, value} | {:error, reason}` — a raise/exit inside the child is
  captured and also arrives as `{:error, reason}`, so a UI affordance can
  never hang waiting for a read that died. It is a plain `send/2`, hence the
  doubly nested shape: the LiveView matches the message and calls
  `handle_loaded/6` with the `base` prompt it snapshotted at pick time.

  ## One result applier

  `handle_loaded/6` is the SINGLE applier for every read outcome; the
  synchronous entry points `handle_attach_result/2` and
  `handle_binary_attach_result/3` delegate to it, so the payload logic exists
  once:

    * text success assigns `:task_prompt` (`base <> block`), clears the
      `file_pick_bases` snapshot for that picker, and pushes the
      `picker_result:<picker_id>` payload `%{prompt, block, attached: true,
      name}` the FilePicker JS hook writes into the `phx-update="ignore"`
      textarea (the DOM is authoritative, the re-render is not);
    * image/audio success appends `%{"type", "name", "media_type", "data"}` to
      the `:staged_attachments` assign (raw bytes live only in `"data"`) and
      pushes `%{attached: true, name, kind}` — deliberately NO `prompt`/`block`,
      because the chip row is the feedback and the hook must not write the
      textarea;
    * any failure puts a friendly error flash
      (`EvoDash.AttachedFile.describe_error/2`) and pushes `%{error: true}`.

  Per-task caps are enforced here: `@max_attachments` (count) and
  `@max_attachment_bytes` (per-file size, also enforced by the readers —
  kept in sync with `EvoGit.Attachments` in `:evo_git`, the authoritative
  validation). `count_cap_reached?/1` lets a caller refuse BEFORE spawning a
  read, and `push_count_cap_error/2` produces the exact cap flash + payload.

  Every function here is total for odd input (nil base, unknown kind,
  unrecognized result shape, a non-map `file_pick_bases`): no clause raises,
  and no client-supplied string is ever converted to an atom.
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

  # The supervisor every attachment read runs in (same one the page's other
  # async loads use); a module attribute so the read never names the
  # supervisor inline at each call site.
  @task_supervisor EvoDash.TaskSupervisor

  @typedoc "Kind tag carried by an `:attachment_loaded` message."
  @type kind_atom :: :text | :image | :audio

  @typedoc "A read's outcome — the readers' own `{:ok, value} | {:error, reason}`."
  @type read_result :: {:ok, term()} | {:error, term()}

  @typedoc """
  The ONE message a spawned attachment read sends its caller (a plain
  `send/2`, so the tag is the first element of the outer pair).
  """
  @type load_message :: {{:attachment_loaded, String.t(), String.t(), kind_atom}, read_result}

  @doc "The picker id the attach-file \"+\" button and the JS hook use."
  def attach_picker_id, do: @attach_picker_id

  @doc """
  Runs the synchronous attachment pipeline for `path`: resolves the base
  prompt from the `file_pick_bases` snapshot, reads the file with
  `EvoDash.AttachedFile.read/1`, and applies the outcome through
  `handle_loaded/6` (which assigns `:task_prompt`, clears the base snapshot
  and pushes the `picker_result:<picker_id>` payload).

  Kept for callers that still read inline; the async `start_text_read/3` +
  `handle_loaded/6` pair is the non-blocking equivalent.
  """
  @spec handle_attach_result(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_attach_result(socket, path) do
    base =
      Map.get(
        file_pick_bases(socket),
        @attach_picker_id,
        socket.assigns[:task_prompt] || ""
      )

    handle_loaded(socket, @attach_picker_id, path, :text, base, EvoDash.AttachedFile.read(path))
  end

  @doc """
  Synchronously stages an image/audio attachment picked via the native file
  dialog into the `:staged_attachments` socket assign (a list of maps with
  STRING keys `%{"type", "name", "media_type", "data"}` — `"data"` holds the
  RAW binary).

  Called by `EvoDashWeb.ProjectsLive`'s
  `handle_info({:directory_picker_result, <image|audio picker id>, {:ok, path}}, ...)`
  clauses and the `"file_pick_manual"` image/audio branches with the STRING
  kind `"image"` / `"audio"` (the event-boundary vocabulary — the same string
  `EvoDash.AttachedFile.read_kind/2` accepts); callers wrap the returned
  socket: `{:noreply, AttachFile.handle_binary_attach_result(socket, path, "image")}`.

  Enforces the per-task count cap first (see `count_cap_reached?/1` and
  `push_count_cap_error/2` — the file is never read when the cap is reached),
  then reads the bytes and applies the outcome through `handle_loaded/6`.

  The raw bytes live ONLY inside the staged map's `"data"` key — they are
  never rendered, logged, serialized, or sent to the client.
  """
  @spec handle_binary_attach_result(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_binary_attach_result(socket, path, kind) when kind in ["image", "audio"] do
    if count_cap_reached?(staged_count(socket)) do
      push_count_cap_error(socket, kind)
    else
      handle_loaded(
        socket,
        picker_id_for(kind),
        path,
        kind_to_atom(kind),
        "",
        EvoDash.AttachedFile.read_kind(path, kind)
      )
    end
  end

  @doc """
  Starts the async TEXT attachment read for `path` in a supervised
  `EvoDash.TaskSupervisor` child and sends `parent` ONE
  `{{:attachment_loaded, picker_id, path, :text}, result}` message once the
  read finishes (`result` = the `EvoDash.AttachedFile.read/1` outcome).

  Returns `:ok` when the read was started, or `{:error, reason}` when it was
  not (a refused/failed supervisor start, or a non-binary path) — nothing is
  sent to `parent` in the error case, so a caller should surface the refusal
  itself (a read that RAISES after a successful start still reports back, as
  `{:error, reason}`).

  The caller matches the message and applies it with `handle_loaded/6`,
  passing the `base` prompt it snapshotted when the pick started.
  """
  @spec start_text_read(pid() | atom(), String.t(), String.t()) :: :ok | {:error, term()}
  def start_text_read(parent, picker_id, path) do
    start_read(parent, picker_id, path, :text, fn -> EvoDash.AttachedFile.read(path) end)
  end

  @doc """
  Starts the async IMAGE/AUDIO attachment read for `path` (kind `"image"` /
  `"audio"`) and sends `parent` ONE
  `{{:attachment_loaded, picker_id, path, :image | :audio}, result}` message
  once the read finishes (`result` = the
  `EvoDash.AttachedFile.read_kind/2` outcome).

  Same `:ok | {:error, reason}` contract as `start_text_read/3`; an
  unrecognized kind is refused as `{:error, {:unsupported_kind, kind}}`.

  Callers enforce the per-task count cap BEFORE starting the read
  (`count_cap_reached?/1` + `push_count_cap_error/2`); each file is capped at
  #{div(@max_attachment_bytes, 1024 * 1024)} MiB of raw bytes by the reader.
  """
  @spec start_binary_read(pid() | atom(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def start_binary_read(parent, picker_id, path, kind) when kind in ["image", "audio"] do
    start_read(parent, picker_id, path, kind_to_atom(kind), fn ->
      EvoDash.AttachedFile.read_kind(path, kind)
    end)
  end

  def start_binary_read(_parent, _picker_id, _path, kind), do: {:error, {:unsupported_kind, kind}}

  @doc """
  Applies ONE attachment read outcome — the SINGLE result applier shared by the
  async message handler and the synchronous entry points above.

  `picker_id` is the picker-result channel the payload is pushed on (`nil` /
  `""` falls back to the kind's own channel), `kind_atom` is `:text` /
  `:image` / `:audio`, `base` is the prompt snapshot taken at pick time, and
  `result` is the read's `{:ok, value} | {:error, reason}`.

    * `:text` + `{:ok, content}` → assigns `:task_prompt` = `base <> block`,
      drops `picker_id` from `:file_pick_bases`, pushes
      `%{prompt: new_prompt, block: block, attached: true, name: basename}`;
    * `:image` / `:audio` + `{:ok, %{type: type, media_type: media_type,
      bytes: bytes}}` → appends the staged entry to `:staged_attachments`,
      pushes `%{attached: true, name: basename, kind: "image" | "audio"}`;
    * an `{:error, reason}` (or any unrecognized result shape) → the friendly
      `gettext("Failed to attach file: …")` flash via
      `EvoDash.AttachedFile.describe_error/2` plus `%{error: true}`.

  Total for odd input: a nil/non-binary `base` reads as `""`, an unknown
  `kind_atom` lands on the text channel, a non-binary `path` degrades to an
  inspected label, and a non-map staged list/`file_pick_bases` reads as
  empty.
  """
  @spec handle_loaded(
          Phoenix.LiveView.Socket.t(),
          String.t() | nil,
          String.t() | nil,
          kind_atom() | term(),
          term(),
          read_result() | term()
        ) :: Phoenix.LiveView.Socket.t()
  def handle_loaded(socket, picker_id, path, :text, base, {:ok, content})
      when is_binary(content) do
    basename = Path.basename(display_path(path))
    block = "\n\n---\n## Attached file: #{basename}\n\n" <> content <> "\n"
    new_prompt = base_or_empty(base) <> block

    socket
    |> assign(:task_prompt, new_prompt)
    |> assign(:file_pick_bases, Map.delete(file_pick_bases(socket), picker_id))
    |> push_event("picker_result:#{result_channel(picker_id, :text)}", %{
      prompt: new_prompt,
      block: block,
      attached: true,
      name: basename
    })
  end

  def handle_loaded(socket, picker_id, path, kind_atom, _base, {:ok, payload})
      when kind_atom in [:image, :audio] do
    case binary_entry(payload, path) do
      {:ok, name, entry} ->
        socket
        |> assign(:staged_attachments, staged_list(socket) ++ [entry])
        |> push_event("picker_result:#{result_channel(picker_id, kind_atom)}", %{
          attached: true,
          name: name,
          kind: Atom.to_string(kind_atom)
        })

      :error ->
        push_read_error(socket, picker_id, path, kind_atom, {:unexpected_result, payload})
    end
  end

  def handle_loaded(socket, picker_id, path, kind_atom, _base, {:error, reason}) do
    push_read_error(socket, picker_id, path, kind_atom, reason)
  end

  def handle_loaded(socket, picker_id, path, kind_atom, _base, other) do
    push_read_error(socket, picker_id, path, kind_atom, {:unexpected_result, other})
  end

  @doc """
  Whether the per-task attachment COUNT cap (#{@max_attachments} attachments)
  is already reached for `staged_count`.

  Lets a caller refuse a binary attachment BEFORE spawning a read. Total: a
  non-integer (or negative) count is never at the cap.
  """
  @spec count_cap_reached?(term()) :: boolean()
  def count_cap_reached?(staged_count)
      when is_integer(staged_count) and staged_count >= @max_attachments,
      do: true

  def count_cap_reached?(_staged_count), do: false

  @doc """
  Pushes the per-task attachment cap flash plus `%{error: true}` on `kind`'s
  picker channel — the exact payload the synchronous flow produced.

  `kind` is the string `"image"` / `"audio"` (or the matching atom); any other
  value uses the text channel, so this helper is total.
  """
  @spec push_count_cap_error(Phoenix.LiveView.Socket.t(), String.t() | atom()) ::
          Phoenix.LiveView.Socket.t()
  def push_count_cap_error(socket, kind) do
    # zh_CN: 已达每个任务最多可附加文件数的上限，提示用户移除附件或不再添加 → "每个任务最多附加 %{count} 个文件"
    msg = gettext("Maximum of %{count} attachments per task", count: @max_attachments)

    socket
    |> put_flash(:error, msg)
    |> push_event("picker_result:#{picker_id_for(kind)}", %{error: true})
  end

  ## Reads (guarded: a raise/exit still reports back, so the UI never hangs)

  # Spawns the read and guarantees exactly ONE `load_message` back to `parent`.
  # The tag is the full 4-tuple, so the plain `send/2` in the child produces
  # the documented doubly nested shape.
  defp start_read(parent, picker_id, path, kind_atom, read_fun) when is_binary(path) do
    tag = {:attachment_loaded, picker_id, path, kind_atom}

    # Same deliberate catch-`exit` boundary as `EvoDash.SafeCall.start/3`: does
    # it expect the error? YES — `Task.Supervisor.start_child/2` performs a
    # `GenServer.call` on the supervisor, which EXITS the caller when that
    # name/pid is unknown or dead (a `rescue` cannot catch it). Is this the
    # cleanest approach? YES — the caller is a LiveView handling a picker
    # result, and a supervisor hiccup must surface as a value, not tear the
    # page down.
    try do
      Task.Supervisor.start_child(@task_supervisor, fn ->
        send(parent, {tag, guarded_read(read_fun)})
      end)
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
    |> case do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # A non-binary path can never be read; refuse it before spawning so the
  # caller learns synchronously instead of waiting on a child that dies.
  defp start_read(_parent, _picker_id, _path, _kind_atom, _read_fun), do: {:error, :invalid_path}

  # The read's own result, with a raise/exit/throw folded into an error value
  # (the child always sends its message, so a caller's pending affordance
  # always resolves).
  defp guarded_read(read_fun) do
    case EvoDash.SafeCall.run(read_fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp push_read_error(socket, picker_id, path, kind_atom, reason) do
    # zh_CN: 附件无法读取（类型不支持、超过大小上限、文件不可读或解码失败）→ "附加文件失败"
    msg =
      gettext("Failed to attach file: %{reason}",
        reason: EvoDash.AttachedFile.describe_error(reason, display_path(path))
      )

    socket
    |> put_flash(:error, msg)
    |> push_event("picker_result:#{result_channel(picker_id, kind_atom)}", %{error: true})
  end

  ## Helpers (all total)

  # Maps a binary kind string (or its atom) to the picker-result channel it is
  # pushed on. An unrecognized kind uses the text channel — the binary entry
  # point's own guard already rejects anything but "image" | "audio", so this
  # fallback only keeps the async helpers total.
  defp picker_id_for(kind) when kind in ["image", :image], do: @attach_picker_id_image
  defp picker_id_for(kind) when kind in ["audio", :audio], do: @attach_picker_id_audio
  defp picker_id_for(_kind), do: @attach_picker_id

  defp result_channel(picker_id, _kind_atom) when is_binary(picker_id) and picker_id != "",
    do: picker_id

  defp result_channel(_picker_id, kind_atom), do: picker_id_for(kind_atom)

  defp kind_to_atom("image"), do: :image
  defp kind_to_atom("audio"), do: :audio
  defp kind_to_atom(_kind), do: :text

  # `Path.basename/1` (and interpolating the path into an error message) needs
  # a binary; a nil/odd path degrades to an inspected label instead of raising.
  defp display_path(path) when is_binary(path), do: path
  defp display_path(other), do: inspect(other)

  defp base_or_empty(base) when is_binary(base), do: base
  defp base_or_empty(_base), do: ""

  defp file_pick_bases(socket) do
    case socket.assigns[:file_pick_bases] do
      bases when is_map(bases) -> bases
      _other -> %{}
    end
  end

  defp staged_list(socket) do
    case socket.assigns[:staged_attachments] do
      staged when is_list(staged) -> staged
      _other -> []
    end
  end

  defp staged_count(socket), do: length(staged_list(socket))

  # The staged entry for a well-formed `read_kind/2` payload; any other shape
  # is an error value, never a crash.
  defp binary_entry(%{type: type, media_type: media_type, bytes: bytes}, path) do
    name = Path.basename(display_path(path))

    {:ok, name, %{"type" => type, "name" => name, "media_type" => media_type, "data" => bytes}}
  end

  defp binary_entry(_payload, _path), do: :error
end
