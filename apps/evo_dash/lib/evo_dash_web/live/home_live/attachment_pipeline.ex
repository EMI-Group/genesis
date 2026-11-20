defmodule EvoDashWeb.HomeLive.AttachmentPipeline do
  @moduledoc """
  The composer's ATTACHMENT PIPELINE for `EvoDashWeb.HomeLive`: every path a
  file takes into the pending attachments of the message being composed.
  `EvoDashWeb.HomeLive.Attachments` owns the attachment MODEL (picker ids,
  staging, caps, the outgoing conversion); this module is the page half:
    * the attach affordance (`chat_attach`) dispatches ONE whitelisted kind and
      runs the native picker on the LOCAL node only, revealing the manual-path
      fallback when no picker exists;
    * the async picker result (`{:directory_picker_result, …}`) and the manual
      path (`chat_attach_manual`) both stage through the SAME staging helpers,
      so the caps and the error wording live once;
    * browser uploads (`chat_upload_validate` / `chat_upload_cancel` /
      `chat_upload_clear_error`) and the pending-chip removal.
  Attachments stay local-filesystem-only (a remote/pending target offers the
  manual fallback), a TEXT file stays out of the composer draft until
  `Attachments.to_message/2` appends it at send time, and image/audio are
  staged as RAW bytes (base64 happens once, at send).
  Extracted verbatim; every gettext string and cap read is unchanged.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  alias EvoDash.{AttachedFile, DirectoryPicker}
  alias EvoDashWeb.HomeLive.{Attachments, ChatState, ModelSelection, Uploads}

  ## Browser uploads -----------------------------------------------------

  def upload_validate(socket), do: {:noreply, Uploads.validate(socket)}
  def upload_cancel(socket, %{"ref" => ref}), do: {:noreply, Uploads.cancel_entry(socket, ref)}
  def upload_clear_error(socket), do: {:noreply, Uploads.clear_error(socket)}

  ## Composer attachments ------------------------------------------------
  #
  # The attach affordance dispatches ONE whitelisted kind (pattern match, never
  # an atom conversion). The native picker runs on the LOCAL node only and
  # reports asynchronously ({:directory_picker_result, picker_id, result});
  # when it is unavailable the composer reveals its manual-path fallback.

  def chat_attach(socket, %{"kind" => kind}), do: {:noreply, begin_attach(socket, kind)}
  def chat_attach(socket, _params), do: {:noreply, socket}

  def chat_attach_manual(socket, %{"path" => path}),
    do: {:noreply, attach_manual(socket, path)}

  def chat_attach_manual(socket, _params), do: {:noreply, socket}

  def remove_attachment(socket, %{"index" => index}) do
    socket =
      case parse_attachment_index(index) do
        nil ->
          socket

        idx ->
          socket
          |> assign(
            pending_attachments: Attachments.remove(socket.assigns[:pending_attachments], idx)
          )
          |> ChatState.persist()
      end

    {:noreply, socket}
  end

  def remove_attachment(socket, _params), do: {:noreply, socket}

  # Picker id → attachment kind (the ONE place the mapping lives). Both the
  # picker ids and the 4-attachment / 15 MiB caps belong to
  # `EvoDashWeb.HomeLive.Attachments`, so they are read at call time.
  defp attach_kind(picker_id) do
    cond do
      picker_id == Attachments.picker_id() -> "text"
      picker_id == Attachments.picker_id_image() -> "image"
      picker_id == Attachments.picker_id_audio() -> "audio"
      true -> nil
    end
  end

  defp picker_id_for("text"), do: Attachments.picker_id()
  defp picker_id_for("image"), do: Attachments.picker_id_image()
  defp picker_id_for("audio"), do: Attachments.picker_id_audio()

  # Attachments are read from THIS node's filesystem, so the picker is local
  # only; a remote/pending target reveals the manual-path fallback instead of
  # attaching a file the agent could never see.
  defp begin_attach(socket, kind) when kind in ["text", "image", "audio"] do
    cond do
      not local_attach_node?(socket) ->
        assign(socket, attach_unavailable: true)

      at_attachment_cap?(socket) ->
        attachment_flash(socket, :too_many, nil)

      true ->
        case DirectoryPicker.pick(self(), picker_id_for(kind), :file) do
          :ok -> socket
          # No native picker here (headless server, OTP without wx, a dialog
          # already open): reveal the manual-path fallback.
          {:error, _reason} -> assign(socket, attach_unavailable: true)
        end
    end
  end

  defp begin_attach(socket, _kind), do: socket

  # NodeAware retains a target id while a remote connection still uses the local
  # node as a placeholder. Reuse the same authoritative pending predicate as sends.
  defp local_attach_node?(socket),
    do: socket.assigns[:current_node] == node() and not ModelSelection.pending_remote?(socket)

  defp at_attachment_cap?(socket) do
    Attachments.count(socket.assigns[:pending_attachments]) >= Attachments.max_attachments()
  end

  # Manual fallback: a TEXT file read from this node's filesystem (the native
  # picker is unavailable, but the read itself is a plain local file read).
  defp attach_manual(socket, path) do
    path = path |> to_string() |> String.trim()

    cond do
      not local_attach_node?(socket) ->
        put_flash(
          socket,
          :error,
          gettext(
            "Adding a server file is unavailable on the selected node. Upload a file from this computer instead."
          )
        )

      path == "" ->
        put_flash(socket, :error, gettext("Enter a file path to attach."))

      not File.regular?(path) ->
        attachment_flash(socket, :enoent, path)

      true ->
        case Attachments.stage_uploaded(
               socket.assigns[:pending_attachments],
               path,
               Path.basename(path)
             ) do
          {:ok, pending} -> store_pending_attachments(socket, pending)
          {:error, reason} -> attachment_flash(socket, reason, path)
        end
    end
  end

  ## Native picker results ---------------------------------------------

  # Async native-picker results for the composer's three attach ids; any other
  # picker id keeps the page's existing ignore behaviour.
  def handle_info(socket, {:directory_picker_result, picker_id, result})
      when is_binary(picker_id) do
    case attach_kind(picker_id) do
      nil -> {:noreply, socket}
      kind -> {:noreply, handle_attach_result(socket, kind, result)}
    end
  end

  defp handle_attach_result(socket, "text", {:ok, path}), do: stage_text_attachment(socket, path)

  defp handle_attach_result(socket, kind, {:ok, path}) when kind in ["image", "audio"],
    do: stage_binary_attachment(socket, kind, path)

  defp handle_attach_result(socket, _kind, :cancelled), do: socket

  defp handle_attach_result(socket, _kind, :unavailable),
    do: assign(socket, attach_unavailable: true)

  defp handle_attach_result(socket, _kind, {:unavailable, _reason}),
    do: assign(socket, attach_unavailable: true)

  defp handle_attach_result(socket, _kind, _other), do: socket

  # A TEXT attachment stays OUT of the composer draft: `Attachments.to_message/2`
  # appends its Markdown block to the outgoing body exactly once at send time.
  defp stage_text_attachment(socket, path) do
    case AttachedFile.read(path) do
      {:ok, content} ->
        case Attachments.stage_text(socket.assigns[:pending_attachments], path, content) do
          {:ok, pending} -> store_pending_attachments(socket, pending)
          {:error, :too_many} -> attachment_flash(socket, :too_many, path)
        end

      {:error, reason} ->
        attachment_flash(socket, reason, path)
    end
  end

  # Image/audio files are staged as RAW bytes (base64 happens once, inside
  # `Attachments.to_message/2`); the extension allowlist and the 15 MiB
  # per-file cap live in `EvoDash.AttachedFile.read_kind/2`.
  defp stage_binary_attachment(socket, kind, path) do
    case Attachments.stage_binary(socket.assigns[:pending_attachments], path, kind) do
      {:ok, pending} -> store_pending_attachments(socket, pending)
      {:error, reason} -> attachment_flash(socket, reason, path)
    end
  end

  defp attachment_flash(socket, reason, path) do
    put_flash(socket, :error, Attachments.describe_error(reason, path))
  end

  defp store_pending_attachments(socket, pending) do
    socket
    |> assign(pending_attachments: pending)
    |> ChatState.persist()
  end

  defp parse_attachment_index(index) when is_integer(index), do: if(index >= 0, do: index)

  defp parse_attachment_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {idx, ""} when idx >= 0 -> idx
      _other -> nil
    end
  end

  defp parse_attachment_index(_index), do: nil
end
