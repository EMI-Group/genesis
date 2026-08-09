defmodule EvoDash.DirectoryPicker.Fake do
  @moduledoc """
  Test double for `EvoDash.DirectoryPicker` (see `pick/2`).

  Installed via `Application.put_env(:evo_dash, :directory_picker_module, ...)`
  so the dashboard's `directory_pick` event exercises the full local flow
  without ever popping a real wx dialog. Mirrors the real module's contract:
  never raises, and delivers exactly one result message per pick.
  """

  @spec pick(pid(), term()) :: :ok
  def pick(reply_to, picker_id) do
    send(reply_to, {:directory_picker_result, picker_id, {:ok, "/fake/picked/dir"}})
    :ok
  end
end
