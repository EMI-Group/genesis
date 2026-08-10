defmodule EvoDash.DirectoryPicker do
  @moduledoc """
  Serializes native `:wx` directory-dialog usage for the dashboard's Browse buttons.

  Only one native dialog can be open at a time: this GenServer marks itself
  busy during a pick and rejects concurrent picks with `{:error, :unavailable}`.
  The blocking dialog itself runs in a separate Task process (never the
  GenServer, never the LiveView), so a modal dialog stalls neither.

  ## wx ownership (important)

  The GenServer itself owns the wx connection. OTP's `wxe_server` is **NOT a
  permanent singleton**: every process that calls `:wx.new/0` or `:wx.set_env/1`
  registers with the server as a "user", and the server stops itself when its
  LAST registered user exits (see OTP's `wxe_server.erl` — `handle_call
  register_me` monitors the caller, and `handle_info {'DOWN', ...}` stops the
  server when no users remain). Pick Tasks are short-lived, so if a Task were
  the wx owner the server would die with it and every later pick would fail.
  Instead:

  * the GenServer lazily calls `:wx.new/0` on the first pick (never at boot)
    and keeps the resulting wxApp ref + `#wx_env{}` in its state — because the
    GenServer is supervised and long-lived, it remains a registered wx user
    and the server survives between picks;
  * before every pick the GenServer verifies the cached wxe_server pid is
    still alive (`Process.alive?/1` on `elem(env, 2)` of the stored `#wx_env{}`)
    and re-runs `:wx.new/0` if it died (self-heal);
  * pick Tasks adopt the env via `:wx.set_env/1` (registering as transient
    users whose DOWN is harmless while the GenServer remains a user), run the
    modal dialog, and report the result.

  `:wx.new/0` prints harmless GTK `dconf-CRITICAL` warnings to stderr; ignore
  them.

  wx commands are delivered per-process: every wx call reads the calling
  process's environment from its process dictionary (a `#wx_env{}` installed by
  `:wx.new/0`/`:wx.set_env/1`), and calling a wx function without it raises
  `{wx, :unknown_env}`. Each pick runs in a fresh Task process, so the
  `#wx_env{}` stored in GenServer state is adopted by every pick Task via
  `:wx.set_env/1` before touching wx.

  Result protocol: the caller receives
  `{:directory_picker_result, picker_id, result}` where `result` is
  `{:ok, path} | :cancelled | :unavailable`. Synchronous failures (disabled by
  config, wx unavailable, the GenServer not running, another pick in flight, or
  wx init failure) return `{:error, :unavailable}` from `pick/2` without a
  result message.

  Disabled with `config :evo_dash, :directory_picker, enabled: false`. The wx
  backend is injectable via `config :evo_dash, :directory_picker_wx, Module`
  (see `EvoDash.DirectoryPicker.Wx`) for deterministic tests.
  """

  use GenServer

  # wx ships with OTP but is intentionally NOT a dependency of any umbrella app
  # (only loaded in the `genesis`/`genesis_desktop` releases via `wx: :load` in
  # the root mix.exs). Mix prunes OTP code paths not in the dependency graph
  # (`:prune_code_paths`), so the compiler cannot resolve `:wx`/`:wxDirDialog`
  # here — suppress the undefined-module warnings for this optional runtime
  # dependency. Availability is checked at runtime via `available?/0`
  # (`:code.which/1`).
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
  GenServer is not running, another pick is already in flight, or wx init
  failed.

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

      # 2. wx backend unavailable (default: OTP built without wx —
      #    `:code.which/1` returns the atom `:non_existing`, never `nil`).
      not wx_backend().available?() ->
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
    # wx_ref/wx_env stay nil until the first pick — never auto-start wx at
    # boot. On the first pick the GenServer itself calls `:wx.new/0` (becoming
    # the long-lived wx owner, see moduledoc) and caches the wxApp ref + the
    # `#wx_env{}` here; pick Tasks adopt the env via `:wx.set_env/1`.
    {:ok, %{wx_ref: nil, wx_env: nil, busy: false}}
  end

  @impl true
  def handle_call({:pick, _reply_to, _picker_id}, _from, %{busy: true} = state) do
    # 4. Another pick is already in flight — wx dialogs are serialized.
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:pick, reply_to, picker_id}, _from, %{busy: false} = state) do
    # Make sure we have a live wx connection BEFORE spawning the pick Task.
    # `ensure_wx/1` runs synchronously in the GenServer so the GenServer is the
    # process that calls `:wx.new/0` and thus the long-lived registered wx user
    # (see moduledoc). On a cold start this blocks the caller for the duration
    # of wx init — sub-second in practice; if the default 5s `GenServer.call`
    # timeout in `pick/2` is exceeded the caller degrades to `:unavailable`
    # without crashing anything.
    case ensure_wx(state) do
      {:ok, ref, env} ->
        gen_server = self()

        # Run the dialog in a separate Task (NOT this GenServer, NOT the
        # caller): `showModal/1` blocks until the user responds, and the
        # GenServer must keep serving other calls while the LiveView stays
        # responsive. `Task.start/1` spawns via `:erlang.spawn/1` — it either
        # returns `{:ok, pid}` or raises (process limit); a raise here crashes
        # the GenServer and the supervisor restarts it with a fresh
        # `busy: false` state, so the picker is never wedged.
        Task.start(fn -> run_pick(gen_server, ref, env, reply_to, picker_id) end)
        {:reply, :ok, %{state | wx_ref: ref, wx_env: env, busy: true}}

      {:error, :unavailable} ->
        # wx init failed (e.g. headless machine with no display): report
        # unavailable synchronously and do NOT set busy — the picker stays
        # usable for the next attempt.
        {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
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

  # The wx backend is injectable via the app env so tests can substitute a
  # deterministic fake (see `EvoDash.DirectoryPicker.Wx` and
  # `test/support/fake_directory_picker_wx.ex`).
  defp wx_backend do
    Application.get_env(:evo_dash, :directory_picker_wx, EvoDash.DirectoryPicker.Wx)
  end

  # Returns {:ok, ref, env} with a usable wx connection, or
  # {:error, :unavailable}. Called from handle_call — the GenServer is the
  # long-lived wx owner.
  defp ensure_wx(%{wx_ref: nil}), do: wx_new()
  defp ensure_wx(%{wx_env: nil}), do: wx_new()

  defp ensure_wx(%{wx_ref: ref, wx_env: env}) do
    if Process.alive?(wx_server_pid(env)) do
      {:ok, ref, env}
    else
      # The wxe_server stopped itself (OTP's wxe_server stops when its last
      # registered user exits). Self-heal by re-initializing.
      wx_new()
    end
  end

  # The #wx_env{} record is a 4-tuple `{:wx_env, ref, sv, debug}`; `sv`
  # (element 2) is the wxe_server pid (verified against OTP wx-2.6
  # `src/wx.erl` `get_env/0` and `wxe_server.erl`).
  defp wx_server_pid(env), do: elem(env, 2)

  defp wx_new do
    wx = wx_backend()

    # Deliberate try/catch boundary (see the codebase try/rescue policy): this
    # module's contract is to degrade to :unavailable on every failure path,
    # and `:wx.new/0` can raise, exit, or return a non-wx term (headless Linux
    # with no display). We EXPECT such failures here — wx is an optional
    # runtime dependency and every failure must surface as :unavailable, never
    # as a crash.
    try do
      case wx.new() do
        {:wx_ref, _, _, _} = ref ->
          # `:wx.new/0` installs the env in THIS process's (the GenServer's)
          # process dictionary; capture it so pick Tasks can adopt it via
          # `:wx.set_env/1` — without it every wx call raises `{wx, :unknown_env}`.
          {:ok, ref, wx.get_env()}

        # `:wx.new/0` can return `{:error, reason}` (e.g. no display available).
        _ ->
          {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
      :throw, _ -> {:error, :unavailable}
    end
  end

  # Runs one pick outside the GenServer process. Always reports a result to
  # `reply_to` and clears the busy flag via `:pick_done`.
  #
  # ALL wx interaction is wrapped in try/catch/rescue: wx can fail in headless
  # environments (no display server, GTK errors, ...) or exit when the
  # wxe_server died mid-pick (`:wx.set_env/1` → `wxe_server:register_me/1` →
  # `gen_server:call` EXITS with `{:noproc, ...}` when the server is dead).
  # A picker crash must never crash the LiveView — every failure path degrades
  # to `:unavailable`. `rescue` alone does NOT catch exits, so `:exit` and
  # `:throw` are caught explicitly.
  defp run_pick(gen_server, wx_ref, wx_env, reply_to, picker_id) do
    result =
      try do
        show_dialog(wx_ref, wx_env)
      rescue
        _ -> :unavailable
      catch
        :exit, _ -> :unavailable
        :throw, _ -> :unavailable
      end

    # Sending to a possibly-dead `reply_to` pid is harmless (plain send). These
    # two sends run on EVERY path — a failed pick must never wedge the picker
    # (otherwise `busy: true` would stick forever and every later pick would
    # report `{:error, :unavailable}`).
    send(reply_to, {:directory_picker_result, picker_id, result})
    send(gen_server, {:pick_done, self()})
  end

  defp show_dialog(wx_ref, wx_env) do
    wx = wx_backend()

    # wx commands are delivered per-process: this Task process must adopt the
    # GenServer-owned env before any wx call, otherwise `?get_env()` raises
    # `{wx, :unknown_env}`. `set_env/1` registers this Task as a transient wx
    # user; its DOWN when the Task exits is harmless because the GenServer
    # remains a registered user (see moduledoc).
    wx.set_env(wx_env)

    # Option names verified from the installed source
    # (`:code.lib_dir(:wx)` → src/gen/wxDirDialog.erl): `new/2` accepts
    # `title`, `defaultPath`, `style`, `pos`, `sz` — NOT `message` (a
    # `message` option raises `{:badoption, _}`). `System.user_home/0` can
    # return nil, so only pass `defaultPath` when a home exists.
    opts =
      [title: "Select Directory"] ++
        if(home = System.user_home(), do: [defaultPath: home], else: [])

    dialog = wx.new_dir_dialog(wx_ref, opts)

    result =
      case dialog do
        {:wx_ref, _, _, _} ->
          case wx.show_modal(dialog) do
            @wx_id_ok ->
              # `getPath/1` returns a plain `unicode:charlist()` (e.g.
              # `[47,104,111,109,101]`), NOT an `{:ok, path}` tuple.
              case wx.get_path(dialog) do
                path when is_list(path) or is_binary(path) -> {:ok, normalize_path(path)}
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

    # Clean up the dialog object. Inside the caller's try/catch/rescue, so even
    # a raise here degrades to `:unavailable` rather than crashing anything.
    wx.destroy(dialog)
    result
  end

  # wx getters return `unicode:chardata()` — a binary in modern unicode builds,
  # but possibly a charlist elsewhere. Normalize so the LiveView always gets a
  # string it can push to the client as-is.
  defp normalize_path(path) when is_list(path), do: List.to_string(path)
  defp normalize_path(path), do: path
end
