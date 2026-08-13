defmodule EvoDash.DirectoryPicker.Fake do
  @moduledoc """
  Test double for `EvoDash.DirectoryPicker` (see `pick/2` and `pick/3`).

  Installed via `Application.put_env(:evo_dash, :directory_picker_module, ...)`
  so the dashboard's `directory_pick` event exercises the full local flow
  without ever popping a real wx dialog. Mirrors the real module's contract:
  never raises, and delivers exactly one result message per pick.

  `pick/2` and `pick(reply_to, picker_id, :directory)` always deliver
  `{:ok, "/fake/picked/dir"}`. File-mode picks (`pick/3` with `:file`) deliver
  a per-test settable result — default `{:ok, "/fake/picked/file.txt"}` — held
  under a `:persistent_term` key; change it with `set_file_result/1` and clear
  it with `reset/0`.
  """

  @file_result_key {__MODULE__, :file_result}

  @spec pick(pid(), term()) :: :ok
  def pick(reply_to, picker_id) do
    send(reply_to, {:directory_picker_result, picker_id, {:ok, "/fake/picked/dir"}})
    :ok
  end

  @spec pick(pid(), term(), :directory | :file) :: :ok
  def pick(reply_to, picker_id, :directory), do: pick(reply_to, picker_id)

  def pick(reply_to, picker_id, :file) do
    result = :persistent_term.get(@file_result_key, {:ok, "/fake/picked/file.txt"})
    send(reply_to, {:directory_picker_result, picker_id, result})
    :ok
  end

  @spec set_file_result({:ok, String.t()} | :cancelled | :unavailable) :: :ok
  def set_file_result(result) do
    :persistent_term.put(@file_result_key, result)
    :ok
  end

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@file_result_key)
    :ok
  end
end
