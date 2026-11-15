defmodule EvoDashWeb.HomeLive.Uploads do
  @moduledoc "Browser uploads are consumed on the dashboard and staged for the selected conversation."
  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, upload_errors: 1, upload_errors: 2]
  import Phoenix.LiveView, only: [allow_upload: 3, cancel_upload: 3, consume_uploaded_entry: 3]

  alias EvoDashWeb.HomeLive.{Attachments, ChatState}

  def init(socket, progress) do
    socket
    |> assign(upload_in_progress: false, upload_error: nil, chat_upload_scope: nil)
    |> allow_upload(:chat_files,
      accept: :any,
      validator: &validate_entry/1,
      max_entries: Attachments.max_attachments(),
      max_file_size: Attachments.max_attachment_bytes(),
      auto_upload: true,
      progress: progress
    )
  end

  defp validate_entry(entry) do
    with {:ok, name} <- EvoDash.AttachedFile.upload_name(entry.client_name),
         true <- String.downcase(Path.extname(name)) in EvoDash.AttachedFile.upload_extensions() do
      :ok
    else
      _ -> {:error, :not_accepted}
    end
  end

  def cancel_all(socket) do
    socket =
      Enum.reduce(entries(socket), socket, fn entry, acc ->
        cancel_upload(acc, :chat_files, entry.ref)
      end)

    assign(socket, upload_in_progress: false, upload_error: nil, chat_upload_scope: nil)
  end

  def validate(socket) do
    if socket.assigns[:chat_status] in [:cancelling, :ended] do
      cancel_all(socket)
    else
      pending = entries(socket)
      config = socket.assigns.uploads.chat_files

      slots =
        max(
          0,
          Attachments.max_attachments() - Attachments.count(socket.assigns[:pending_attachments])
        )

      too_many = length(pending) > slots or :too_many_files in upload_errors(config)

      {socket, _, error} =
        Enum.reduce(pending, {socket, 0, nil}, fn entry, {acc, count, error} ->
          errors = upload_errors(config, entry)

          cond do
            errors != [] ->
              {cancel_upload(acc, :chat_files, entry.ref), count,
               error || describe_error(hd(errors))}

            count >= slots ->
              {cancel_upload(acc, :chat_files, entry.ref), count,
               error || Attachments.describe_error(:too_many, nil)}

            true ->
              {acc, count + 1, error}
          end
        end)

      error = error || if(too_many, do: Attachments.describe_error(:too_many, nil))
      socket |> assign(chat_upload_scope: scope(socket), upload_error: error) |> refresh()
    end
  end

  def progress(entry, socket) do
    cond do
      not Enum.any?(entries(socket), &(&1.ref == entry.ref)) ->
        refresh(socket)

      socket.assigns[:chat_upload_scope] != scope(socket) ->
        socket |> cancel_entry(entry.ref)

      entry.done? ->
        pending = socket.assigns[:pending_attachments]

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Attachments.stage_uploaded(pending, path, entry.client_name)}
          end)

        case result do
          {:ok, staged} ->
            socket |> assign(pending_attachments: staged) |> refresh() |> ChatState.persist()

          {:error, reason} ->
            socket
            |> assign(upload_error: Attachments.describe_error(reason, entry.client_name))
            |> refresh()
        end

      true ->
        refresh(socket)
    end
  end

  def cancel_entry(socket, ref) do
    if Enum.any?(entries(socket), &(&1.ref == ref)) do
      socket |> cancel_upload(:chat_files, ref) |> assign(upload_error: nil) |> refresh()
    else
      socket
    end
  end

  def clear_error(socket), do: assign(socket, upload_error: nil)

  defp refresh(socket) do
    assign(socket, upload_in_progress: Enum.any?(entries(socket), &(not &1.done?)))
  end

  defp entries(socket) do
    (get_in(socket.assigns, [:uploads, :chat_files, Access.key(:entries, [])]) || [])
    |> Enum.reject(& &1.cancelled?)
  end

  defp scope(socket),
    do:
      {socket.assigns[:chat_id], socket.assigns[:current_node], socket.assigns[:current_node_id]}

  defp describe_error(:too_large), do: gettext("Each file must be 15 MiB or smaller.")
  defp describe_error(:not_accepted), do: gettext("This file type is not supported.")
  defp describe_error(:too_many_files), do: Attachments.describe_error(:too_many, nil)
  defp describe_error(_), do: gettext("Upload failed. Choose the file again.")
end
