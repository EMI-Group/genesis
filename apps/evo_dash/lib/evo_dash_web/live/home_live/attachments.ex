defmodule EvoDashWeb.HomeLive.Attachments do
  @moduledoc """
  Attachment pipeline for the Genesis Assistant chat composer
  (`EvoDashWeb.HomeLive` at `/help`).

  Mirrors the Projects page objective-editor contract
  (`EvoDashWeb.ProjectsLive.AttachFile`), split into pure helpers because the
  chat composer has no `picker_result:<id>` DOM channel of its own:

    * TEXT files are appended to the message text as the SAME Markdown block
      the Projects editor uses (`"\\n\\n---\\n## Attached file: <basename>\\n\\n"`
      + content + `"\\n"`).
    * IMAGE / AUDIO files are staged as binary attachments
      `%{"type", "name", "media_type", "data"}` whose `"data"` holds the RAW
      bytes — base64 happens exactly once, at submit time
      (`EvoGit.Attachments` requires the base64 form on the wire, and raw
      non-UTF-8 binaries abort `Jason` in `EvoGit.Store.Codec`).

  ## Pending state

  The staging state is a plain map built by `new/0`:

      %{text: String.t(), entries: [entry()]}

  `:text` is the staged message body (staged text blocks are already appended
  in pick order) and `:entries` is one entry per staged attachment, in pick
  order — the cap counts text and binary attachments TOGETHER (4 per message,
  the core's `EvoGit.Attachments.max_count/0`). Entries are internal; the
  LiveView only reads the state through `text/1`, `count/1` and `to_message/2`.

  `stage_text/3` appends to the state's own `:text`, so the caller seeds the
  current composer value with `put_text/2` before staging and mirrors
  `text/1` back into the composer afterwards. `to_message/2` is forgiving of
  a caller that forgot to mirror: it appends any staged block the passed text
  does not already contain, so a staged file can never be silently dropped.

  Every function is TOTAL (bad input degrades to an empty/no-op result) and no
  function raises; there is no `try/rescue` here because no function rejects.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  # Keep in sync with EvoGit.Attachments in :evo_git (the authoritative
  # validation) and EvoDash.AttachedFile (the reader).
  @max_attachments 4
  @max_attachment_bytes 15 * 1024 * 1024

  # Picker ids for the chat composer's attach buttons. Must match the
  # `data-picker-id` on the FilePicker hook buttons in the HomeLive composer
  # and the `picker_result:<picker_id>` channel the JS hook listens on.
  @picker_id "chat_file"
  @picker_id_image "chat_file_image"
  @picker_id_audio "chat_file_audio"

  @type entry :: %{
          kind: String.t(),
          name: String.t(),
          block: String.t() | nil,
          media_type: String.t() | nil,
          data: binary() | nil
        }

  @typedoc "Staging state: the message body plus one entry per staged attachment."
  @type pending :: %{text: String.t(), entries: [entry()]}

  @typedoc """
  A submit-ready attachment map — STRING keys, `"data"` base64-encoded, exactly
  the shape `EvoGit.Attachments` accepts.
  """
  @type message_attachment :: %{required(String.t()) => String.t()}

  @doc """
  Maximum number of attachments per message (text, image and audio combined) —
  the core's `EvoGit.Attachments.max_count/0`.
  """
  @spec max_attachments() :: pos_integer()
  def max_attachments, do: @max_attachments

  @doc """
  Maximum RAW byte size of a single binary attachment, before base64 encoding —
  the core's `EvoGit.Attachments.max_bytes/0`.
  """
  @spec max_attachment_bytes() :: pos_integer()
  def max_attachment_bytes, do: @max_attachment_bytes

  @doc "Picker id for the composer's text-file attach button."
  @spec picker_id() :: String.t()
  def picker_id, do: @picker_id

  @doc "Picker id for the composer's image attach button."
  @spec picker_id_image() :: String.t()
  def picker_id_image, do: @picker_id_image

  @doc "Picker id for the composer's audio attach button."
  @spec picker_id_audio() :: String.t()
  def picker_id_audio, do: @picker_id_audio

  @doc "A fresh, empty staging state."
  @spec new() :: pending()
  def new, do: %{text: "", entries: []}

  @doc """
  A fresh, empty staging state — the reset after a successful send.
  """
  @spec clear() :: pending()
  def clear, do: new()

  @doc """
  The staged message body (staged text-file blocks already appended, in pick
  order). Total: an unusable state reads as `""`.
  """
  @spec text(term()) :: String.t()
  def text(pending), do: pending |> normalize() |> Map.fetch!(:text)

  @doc """
  Number of staged attachments (text, image and audio combined).
  """
  @spec count(term()) :: non_neg_integer()
  def count(pending), do: pending |> normalize() |> Map.fetch!(:entries) |> length()

  @doc """
  Seeds the staging state's message body with the CURRENT composer value.

  Call this before `stage_text/3` so the appended block lands after what the
  user actually typed (the composer is the source of truth for the text, the
  staging state for the attachments). Total: a non-binary `text` seeds `""`.
  """
  @spec put_text(term(), term()) :: pending()
  def put_text(pending, text) do
    %{normalize(pending) | text: if(is_binary(text), do: text, else: "")}
  end

  @doc """
  Stages a TEXT attachment: appends the Projects-editor Markdown block for
  `path` to the state's message body.

  `content` is the already-read file text (`EvoDash.AttachedFile.read/1`) —
  this module does no file I/O. Returns `{:ok, pending}` or
  `{:error, :too_many}` when the per-message cap is already reached.
  """
  @spec stage_text(term(), term(), term()) :: {:ok, pending()} | {:error, :too_many}
  def stage_text(pending, path, content) do
    pending = normalize(pending)

    if full?(pending) do
      {:error, :too_many}
    else
      name = basename(path)
      block = text_block(name, content)
      entry = %{kind: "text", name: name, block: block, media_type: nil, data: nil}

      {:ok, %{pending | text: pending.text <> block, entries: pending.entries ++ [entry]}}
    end
  end

  @doc """
  Stages an IMAGE or AUDIO attachment, reading the file's RAW bytes with
  `EvoDash.AttachedFile.read_kind/2` (extension allowlist + the 15 MiB
  per-file cap live there).

  `kind` is the STRING `"image"` / `"audio"`. The cap is checked FIRST, so a
  full message never reads the file. Returns `{:ok, pending}`,
  `{:error, :too_many}`, or the reader's `{:error, reason}` (a bare POSIX atom,
  `{:unsupported_extension, ext}`, `{:file_too_large, byte_size}`,
  `{:unsupported_kind, kind}`) — feed it to `describe_error/2` for display.

  The raw bytes live ONLY in the internal entry; the base64 form is produced by
  `to_message/2` and is never rendered, logged or sent to the client.
  """
  @spec stage_binary(term(), term(), term()) ::
          {:ok, pending()} | {:error, :too_many} | {:error, term()}
  def stage_binary(pending, path, kind) do
    pending = normalize(pending)

    if full?(pending) do
      {:error, :too_many}
    else
      case EvoDash.AttachedFile.read_kind(path, kind) do
        {:ok, %{type: type, media_type: media_type, bytes: bytes}} ->
          entry = %{
            kind: type,
            name: basename(path),
            block: nil,
            media_type: media_type,
            data: bytes
          }

          {:ok, %{pending | entries: pending.entries ++ [entry]}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes ONE staged attachment by 0-based index into the staging list, or by
  its `name` (the file's basename — the first match wins).

  Removing a TEXT attachment also strips its block from the message body, so
  the staged text and the staged entries never disagree. Total: an unknown
  index/name leaves the state unchanged.
  """
  @spec remove(term(), term()) :: pending()
  def remove(pending, index_or_id) do
    pending = normalize(pending)

    case find_index(pending.entries, index_or_id) do
      nil -> pending
      index -> drop_entry(pending, index)
    end
  end

  @doc """
  Converts the staging state into what the session API accepts:
  `{text, attachments}`.

  `text` is the passed composer value (or the staged body when the passed value
  is blank) with any staged text block it does not already contain appended;
  `attachments` is the base64-encoded, cap-enforced list of binary attachments
  — at most `max_attachments/0` entries, each at most
  `max_attachment_bytes/0` RAW bytes (oversized entries are dropped rather
  than failing the send).

  Pass the result to `EvoDashWeb.HomeLive.SessionActions.send_message/5`.
  """
  @spec to_message(term(), term()) :: {String.t(), [message_attachment()]}
  def to_message(text, pending) do
    pending = normalize(pending)
    {final_text(text, pending), encode_binary_entries(pending.entries)}
  end

  @doc """
  User-facing text for a staging failure — `{:error, :too_many}` or any
  `EvoDash.AttachedFile` read error.

  Delegates the read-error detail to `EvoDash.AttachedFile.describe_error/2`
  and wraps it in the same gettext message the Projects editor uses.
  """
  @spec describe_error(term(), term()) :: String.t()
  def describe_error(:too_many, _path) do
    # zh_CN: 附件数量已达上限 → "每条消息最多附加 %{count} 个文件"
    gettext("Maximum of %{count} attachments per message", count: @max_attachments)
  end

  def describe_error(reason, path) do
    # zh_CN: 附加文件失败（读取失败、类型不支持或超过大小上限）→ "附加文件失败：%{reason}"
    gettext("Failed to attach file: %{reason}",
      reason: EvoDash.AttachedFile.describe_error(reason, path)
    )
  end

  ## Staging internals

  defp full?(%{entries: entries}), do: length(entries) >= @max_attachments

  # Exactly the Projects editor's block shape; the trailing newline keeps
  # consecutive attachments visually separated.
  defp text_block(name, content) do
    content = if is_binary(content), do: content, else: ""
    "\n\n---\n## Attached file: #{name}\n\n" <> content <> "\n"
  end

  defp basename(path) when is_binary(path) do
    case Path.basename(path) do
      "" -> "attachment"
      name -> name
    end
  end

  defp basename(_path), do: "attachment"

  defp find_index(entries, index) when is_integer(index) do
    if index >= 0 and index < length(entries), do: index
  end

  defp find_index(entries, name) when is_binary(name) do
    Enum.find_index(entries, fn entry -> Map.get(entry, :name) == name end)
  end

  defp find_index(_entries, _index_or_id), do: nil

  defp drop_entry(pending, index) do
    {entry, entries} = List.pop_at(pending.entries, index)

    text =
      case entry do
        %{kind: "text", block: block} when is_binary(block) ->
          String.replace(pending.text, block, "", global: false)

        _entry ->
          pending.text
      end

    %{pending | text: text, entries: entries}
  end

  defp final_text(text, pending) do
    base = if is_binary(text) and text != "", do: text, else: pending.text

    Enum.reduce(pending.entries, base, fn
      %{kind: "text", block: block}, acc when is_binary(block) -> append_once(acc, block)
      _entry, acc -> acc
    end)
  end

  defp append_once(text, block) do
    if String.contains?(text, block), do: text, else: text <> block
  end

  defp encode_binary_entries(entries) do
    entries
    |> Enum.filter(&binary_entry?/1)
    |> Enum.filter(&(byte_size(&1.data) <= @max_attachment_bytes))
    |> Enum.take(@max_attachments)
    |> Enum.map(fn %{kind: kind, name: name, media_type: media_type, data: data} ->
      %{
        "type" => kind,
        "name" => name,
        "media_type" => media_type,
        "data" => Base.encode64(data)
      }
    end)
  end

  defp binary_entry?(%{kind: kind, data: data})
       when kind in ["image", "audio"] and is_binary(data),
       do: true

  defp binary_entry?(_entry), do: false

  # Tolerates a nil/garbage state: any function here is total, so a stale or
  # unmigrated assign degrades to "nothing staged" instead of crashing a send.
  defp normalize(%{text: text, entries: entries}) when is_list(entries) do
    %{
      text: if(is_binary(text), do: text, else: ""),
      entries: Enum.filter(entries, &valid_entry?/1)
    }
  end

  defp normalize(_pending), do: new()

  defp valid_entry?(%{kind: kind, name: name}) when is_binary(kind) and is_binary(name), do: true
  defp valid_entry?(_entry), do: false
end
