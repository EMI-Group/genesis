defmodule EvoDash.DirectoryPicker.Wx.Fake do
  @moduledoc """
  Deterministic test double for `EvoDash.DirectoryPicker.Wx` — simulates wx
  server death and init failure without a display.

  Installed via `Application.put_env(:evo_dash, :directory_picker_wx, ...)` so
  the real picker exercises its full GenServer/Task flow without ever popping a
  native wx dialog (mirrors the `:directory_picker_module` injection convention
  used for `EvoDash.DirectoryPicker.Fake`).

  Modes (set with `set_mode/1`):

    * `:normal` — everything works. `new/0` spawns a fake wxe-server process
      whose pid is embedded in the `#wx_env{}` returned by `get_env/0`, so the
      picker's `Process.alive?/1` self-heal check observes real process state
      and `kill_server/0` can simulate the server dying between picks.
    * `:init_fails` — `new/0` returns `{:error, :wx_unavailable}` (like
      `:wx.new/0` on a headless machine).
    * `:server_dead` — `set_env/1` exits like `wxe_server:register_me/1` does
      when the server has stopped (`{:noproc, ...}`), simulating the server
      dying mid-pick, after the picker's alive-check.

  State (mode / fake server pid / optional dialog gate) lives in
  `:persistent_term` so it is shared across the picker GenServer and the pick
  Tasks. `reset/0` clears the mode and gate but deliberately keeps the server
  pid — the app-started picker GenServer caches its env across tests, so the
  fake server must stay consistent with that cached env.
  """

  @mode_key {__MODULE__, :mode}
  @server_key {__MODULE__, :server}
  @gate_key {__MODULE__, :gate}

  # Matches the real wx constants in EvoDash.DirectoryPicker (wx.hrl:
  # wxID_OK = 5100, wxID_CANCEL = 5101).
  @wx_id_ok 5100

  @doc "Resets the mode and gate (keeps the fake server pid — see moduledoc)."
  def reset do
    :persistent_term.erase(@mode_key)
    :persistent_term.erase(@gate_key)
    :ok
  end

  @doc "Sets the simulated backend mode: :normal | :init_fails | :server_dead."
  def set_mode(mode), do: :persistent_term.put(@mode_key, mode)

  @doc "Kills the fake wxe server so the picker observes a dead server pid."
  def kill_server do
    case :persistent_term.get(@server_key, nil) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)

        # Wait for the exit signal to take effect so `Process.alive?/1` observes
        # the death deterministically (kill is asynchronous).
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1000 -> :ok
        end
    end
  end

  @doc "Gates the modal dialog: show_modal/1 blocks until `:release_dialog` is sent to its Task."
  def set_gate(pid), do: :persistent_term.put(@gate_key, pid)

  defp mode, do: :persistent_term.get(@mode_key, :normal)

  # --- EvoDash.DirectoryPicker.Wx contract ---

  def available?, do: true

  def new do
    case mode() do
      :init_fails ->
        # Like :wx.new/0 returning {:error, _} on a headless machine.
        {:error, :wx_unavailable}

      _ ->
        # Retire any previous fake server so at most one leaked process
        # accumulates across tests (the picker's cached env is stale by the
        # time new/0 runs again — either it was killed or this is a first init).
        case :persistent_term.get(@server_key, nil) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end

        server = spawn(fn -> Process.sleep(:infinity) end)
        :persistent_term.put(@server_key, server)
        # The real wxApp object returned by :wx.new/0 (record #wx_ref{ref, type, state}).
        {:wx_ref, 0, :wx, []}
    end
  end

  def get_env do
    # The real #wx_env{} record is a 4-tuple {:wx_env, ref, sv, debug};
    # elem(env, 2) is the wxe_server pid the picker checks with Process.alive?/1.
    {:wx_env, 0, :persistent_term.get(@server_key, nil), 0}
  end

  def set_env(_env) do
    case mode() do
      :server_dead ->
        # Like wxe_server:register_me/1 → gen_server:call on a dead server.
        exit({:noproc, {:gen_server, :call, [:wxe_server_dead, :register_me, :infinity]}})

      _ ->
        :ok
    end
  end

  def new_dir_dialog(_wx_ref, _opts), do: {:wx_ref, 1, :wxDirDialog, []}

  def show_modal(_dialog) do
    case :persistent_term.get(@gate_key, nil) do
      nil ->
        @wx_id_ok

      pid ->
        # One-shot gate: consume it so later dialogs (e.g. the follow-up pick
        # in the same test) don't block too. The dialog blocks until the test
        # releases it (proves busy serialization deterministically). Timeout →
        # wxID_CANCEL so a stuck test never wedges the picker.
        :persistent_term.erase(@gate_key)
        send(pid, {:dialog_open, self()})

        receive do
          :release_dialog -> @wx_id_ok
        after
          5000 -> 5101
        end
    end
  end

  def get_path(_dialog), do: "/fake/picked/dir"
  def destroy(_dialog), do: :ok
end
