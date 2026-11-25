defmodule EvoDash.Test.Seam do
  @moduledoc """
  Installs an `EvoDash.Seam` override for ONE test's process tree.

  `put/2` writes the override into the CALLING process' dictionary — in an
  ExUnit test that is the test process itself — and `EvoDash.Seam.get/2`
  resolves a seam by walking the spawn chain, so the override reaches exactly
  the pages, LiveView processes and supervised load tasks descended from the
  test and NOTHING else. A page mounted by a concurrently running test walks
  its own chain, finds no entry and resolves the production default, which is
  what makes a runner fixture safe in an `async: true` module.
  It never touches application env, so it cannot leak into another test's page
  no matter how the suite is scheduled.

  The override lives in the test process' dictionary, so it disappears with
  that process; `put/2` additionally registers an `ExUnit.Callbacks.on_exit/1`
  restore so a slot installed from a longer-lived process is put back
  explicitly, and `delete/1` clears it mid-test.
  """

  @doc """
  Installs `value` for `key` on the current process' dictionary and returns it.
  The previous value is restored by a registered `on_exit` callback.
  """
  @spec put(atom(), term()) :: term()
  def put(key, value) when is_atom(key) do
    previous = Process.get(key, :__evodash_seam_unset__)
    Process.put(key, value)

    ExUnit.Callbacks.on_exit({__MODULE__, key}, fn ->
      case previous do
        :__evodash_seam_unset__ -> Process.delete(key)
        restored -> Process.put(key, restored)
      end
    end)

    value
  end

  @doc """
  Clears the override for `key` on the current process.
  """
  @spec delete(atom()) :: :ok
  def delete(key) when is_atom(key) do
    Process.delete(key)
    :ok
  end

  @doc """
  Installs every `{key, value}` pair of `seams` (a keyword list).
  """
  @spec put_all(Enumerable.t()) :: :ok
  def put_all(seams) do
    Enum.each(seams, fn {key, value} -> put(key, value) end)
    :ok
  end
end
