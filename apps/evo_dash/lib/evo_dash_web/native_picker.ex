defmodule EvoDashWeb.NativePicker do
  @moduledoc """
  Provides a native OS directory picker dialog for selecting project paths,
  using Erlang's built-in :wx library (no external CLI tools required).

  This only works when the server and browser are on the same machine,
  since the dialog opens on the server side.
  """

  import EvoDashWeb.Gettext

  @doc """
  Opens a native OS directory picker dialog and returns the selected path.

  ## Returns

    * `{:ok, path}` — the absolute path of the selected directory
    * `{:error, reason}` — if the picker failed or is unavailable
  """
  def pick_directory do
    # We run wx in a separate process because wx requires the process
    # that initializes it to be the same one that runs the event loop.
    # Using Task.async ensures clean initialization and teardown.
    task = Task.async(fn -> do_pick_directory() end)

    case Task.yield(task, 120_000) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, gettext("Directory picker timed out")}
    end
  end

  defp do_pick_directory do
    # Ensure wx is started
    :wx.new()

    try do
      dialog =
        :wxDirDialog.new(
          :wx.null(),
          title: ~c"#{gettext("Select Project Directory")}",
          style: 0
        )

      result =
        case :wxDirDialog.showModal(dialog) do
          5100 ->
            # wxID_OK
            path = :wxDirDialog.getPath(dialog) |> List.to_string()
            {:ok, path}

          _ ->
            {:error, :cancelled}
        end

      :wxDirDialog.destroy(dialog)
      result
    rescue
      e ->
        {:error, gettext("wx directory picker failed: %{message}", message: Exception.message(e))}
    after
      :wx.destroy()
    end
  end
end
