defmodule EvoDash.DirectoryPicker do
  @moduledoc """
  Serializes native `:wx` directory-dialog usage for the dashboard's Browse buttons.

  The wx server is a singleton, so only one native dialog can be open at a time:
  this GenServer marks itself busy during a pick and rejects concurrent picks
  with `{:error, :unavailable}`. The blocking dialog itself runs in a separate
  Task process (never the GenServer, never the LiveView), so a modal dialog
  stalls neither.

  The wx server is started lazily on the first successful pick (`:wx.new/0`) and
  the ref is kept in GenServer state for reuse — it is NEVER started at boot,
  keeping headless dev servers clean. `:wx.new/0` prints harmless GTK
  `dconf-CRITICAL` warnings to stderr; ignore them.

  Result protocol: the caller receives
  `{:directory_picker_result, picker_id, result}` where `result` is
  `{:ok, path} | :cancelled | :unavailable`.

  Disabled with `config :evo_dash, :directory_picker, enabled: false`.
  """

  use GenServer

  # wx ships with OTP but is intentionally NOT a dependency of any umbrella app
  # (only loaded in the `genesis`/`genesis_desktop` releases via `wx: :load` in
  # the root mix.exs). Mix prunes OTP code paths not in the dependency graph
  # (`:prune_code_paths`), so the compiler cannot resolve `:wx`/`:wxDirDialog`
  # here — suppress the undefined-module warnings for this optional runtime
  # dependency. Availability is checked at runtime via `:code.which/1`.
  @compile {:no_warn_undefined, [:wx, :wxDirDialog]}

  # Verified from the installed wx header (`:code.lib_dir(:wx)` →
  # .../erlang/lib/wx-2.6, `include/wx.hrl`):
  #   line 1364: -define(wxID_OK, 5100).
  #   line 1365: -define(wxID_CANCEL, 5101).
  @wx_id_ok 5100
  @wx_id_cancel 5101

  @doc """
  Opens the native directory dialog and delivers the result to `reply_to`.

  Returns `:ok` when the pick was accepted, or `{:error, :unavailable}` when the
  picker is disabled by config, wx is not compiled into this OTP build, the
  GenServer is not running, or another pick is already in flight.

  MUST NEVER RAISE — the LiveView calls this from an event handler, so a crash
  must be impossible. The result is delivered asynchronously to `reply_to` as
  `{:directory_picker_result, picker_id, result}` where `result` is
  `{:ok, path} | :cancelled | :unavailable`.
  """
  @spec pick(pid(), term()) :: :ok | {:error, :unavailable}
  def pick(reply_to, picker_id) do
    cond do
      # 1. Disabled by config (`config :evo_dash, :directory_picker, enabled: false`).
      not enabled?() ->
        {:error, :unavailable}

      # 2. OTP built without wx — `:code.which/1` returns the atom
      #    `:non_existing` (never `nil`) when the module cannot be found.
      :code.which(:wx) == :non_existing ->
        {:error, :unavailable}

      # 3. GenServer not running. Guarded with `whereis` AND a try/catch around
      #    `GenServer.call` (whereis → call is a TOCTOU race): the picker must
      #    degrade gracefully in test setups where the app isn't fully started.
      true ->
        case GenServer.whereis(__MODULE__) do
          nil ->
            {:error, :unavailable}

          pid ->
            try do
              GenServer.call(pid, {:pick, reply_to, picker_id})
            catch
              :exit, _ -> {:error, :unavailable}
            end
        end
    end
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # wx_ref stays nil until the first pick succeeds — never auto-start wx at boot.
    {:ok, %{wx_ref: nil, busy: false}}
  end

  @impl true
  def handle_call({:pick, _reply_to, _picker_id}, _from, %{busy: true} = state) do
    # 4. Another pick is already in flight — wx dialogs are serialized.
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:pick, reply_to, picker_id}, _from, %{busy: false} = state) do
    gen_server = self()

    # Run the dialog in a separate Task (NOT this GenServer, NOT the caller):
    # `show_modal/1` blocks until the user responds, and the GenServer must keep
    # serving other calls while the LiveView stays responsive.
    Task.start(fn -> run_pick(gen_server, state.wx_ref, reply_to, picker_id) end)

    {:reply, :ok, %{state | busy: true}}
  end

  @impl true
  def handle_info({:wx_ref_ready, ref}, state) do
    # The first pick succeeded in starting the wx server; reuse the ref for
    # subsequent picks (the wx server is a singleton — no `:wx.stop/0`, we keep
    # the ref alive and never stop it).
    {:noreply, %{state | wx_ref: ref}}
  end

  def handle_info({:pick_done, _task_pid}, state) do
    {:noreply, %{state | busy: false}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp enabled? do
    Application.get_env(:evo_dash, :directory_picker, [])
    |> Keyword.get(:enabled, true)
  end

  # Runs one pick outside the GenServer process. Always reports a result to
  # `reply_to` and clears the busy flag via `:pick_done`.
  #
  # ALL wx interaction is wrapped in try/rescue: wx can fail in headless
  # environments (no display server, GTK errors, ...), and a picker crash must
  # never crash the LiveView — every failure path degrades to `:unavailable`.
  defp run_pick(gen_server, wx_ref, reply_to, picker_id) do
    result =
      try do
        case ensure_wx_ref(gen_server, wx_ref, reply_to, picker_id) do
          nil -> :unavailable
          ref -> show_dialog(ref)
        end
      rescue
        _ -> :unavailable
      end

    # Sending to a possibly-dead `reply_to` pid is harmless (plain send).
    send(reply_to, {:directory_picker_result, picker_id, result})
    send(gen_server, {:pick_done, self()})
  end

  # Lazily starts the wx server on the first pick. On success notifies the
  # GenServer to store the ref (`{:wx_ref_ready, ref}`) so later picks reuse it.
  # On failure returns nil — `run_pick/4` reports the single `:unavailable`
  # result to `reply_to` (exactly one result message per pick).
  defp ensure_wx_ref(gen_server, nil, _reply_to, _picker_id) do
    case :wx.new() do
      {:wx_ref, _, _, _} = ref ->
        send(gen_server, {:wx_ref_ready, ref})
        ref

      # `:wx.new/0` can return `{:error, reason}` (e.g. no display available).
      {:error, _} ->
        nil
    end
  end

  defp ensure_wx_ref(_gen_server, ref, _reply_to, _picker_id), do: ref

  defp show_dialog(wx_ref) do
    # Option names verified from the installed source
    # (`:code.lib_dir(:wx)` → src/gen/wxDirDialog.erl): `new/2` accepts
    # `title`, `defaultPath`, `style`, `pos`, `sz` — NOT `message` (a
    # `message` option raises `{:badoption, _}`). `System.user_home/0` can
    # return nil, so only pass `defaultPath` when a home exists.
    opts =
      [title: "Select Directory"] ++
        if(home = System.user_home(), do: [defaultPath: home], else: [])

    dialog = :wxDirDialog.new(wx_ref, opts)

    result =
      case dialog do
        {:wx_ref, _, _, _} ->
          case :wxDirDialog.show_modal(dialog) do
            @wx_id_ok ->
              case :wxDirDialog.get_path(dialog) do
                {:ok, path} -> {:ok, normalize_path(path)}
                _ -> :unavailable
              end

            @wx_id_cancel ->
              :cancelled

            # Any other return code (e.g. the dialog being closed) = no selection.
            _ ->
              :cancelled
          end

        # Dialog creation failed (wx returns `{:error, _}` or `:wxNull`).
        _ ->
          :unavailable
      end

    # Clean up the dialog object. Inside the caller's try/rescue, so even a
    # raise here degrades to `:unavailable` rather than crashing anything.
    :wxDirDialog.destroy(dialog)
    result
  end

  # wx getters return `unicode:chardata()` — a binary in modern unicode builds,
  # but possibly a charlist elsewhere. Normalize so the LiveView always gets a
  # string it can push to the client as-is.
  defp normalize_path(path) when is_list(path), do: List.to_string(path)
  defp normalize_path(path), do: path
end
