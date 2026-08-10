defmodule EvoDash.DirectoryPicker do
  @moduledoc """
  Native-first directory-dialog picker for the dashboard's Browse buttons.

  Uses a "native first, wx fallback" model on ALL platforms:

  * **macOS** — uses `osascript` to invoke the native `choose folder` dialog.
    This avoids the Erlang dock icon that `:wx.new/0` creates (wx registers as a
    GUI application on macOS, showing the Erlang icon in the dock even after the
    dialog closes). The native dialog has no dock icon and no Erlang branding.

  * **Linux** — uses `zenity --file-selection --directory` (GTK native dialog).
    Falls back to wx if zenity is not installed or fails at runtime.

  * **Windows** — uses PowerShell `[System.Windows.Forms.FolderBrowserDialog]`
    (.NET native dialog). Falls back to wx if PowerShell/.NET fails at runtime.

  * **Fallback (all platforms)** — Erlang's `:wx` module (`wxDirDialog`) is
    used when the native tool is unavailable or fails at runtime. wx is
    initialized lazily inside the pick Task (NOT cached in GenServer state).

  Only one native dialog can be open at a time: this GenServer marks itself
  busy during a pick and rejects concurrent picks with `{:error, :unavailable}`.
  The blocking dialog itself runs in a separate Task process (never the
  GenServer, never the LiveView), so a modal dialog stalls neither.

  ## wx ownership (fallback path only)

  wx is initialized lazily INSIDE the pick Task — NOT cached in GenServer
  state. Each pick that falls through to the wx fallback calls `:wx.new/0`
  fresh in its Task. Since each Task is short-lived, this means wx is
  initialized per-fallback-pick rather than once for the GenServer lifetime.
  This is simpler and avoids the complexity of caching and self-healing wx
  state across picks, at the cost of a small init latency when the native tool
  is unavailable.

  `:wx.new/0` prints harmless GTK `dconf-CRITICAL` warnings to stderr; ignore
  them.

  Result protocol: the caller receives
  `{:directory_picker_result, picker_id, result}` where `result` is
  `{:ok, path} | :cancelled | :unavailable`. Synchronous failures (disabled by
  config, neither native nor wx available, the GenServer not running, or
  another pick in flight) return `{:error, :unavailable}` from `pick/2` without
  a result message.

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

  # Verified from the installed source
  # (`:code.lib_dir(:wx)` → include/wx.hrl): wxID_OK = 5100, wxID_CANCEL = 5101.
  @wx_id_ok 5100
  @wx_id_cancel 5101

  @doc """
  Opens the native directory dialog and delivers the result to `reply_to`.

  Returns `:ok` when the pick was accepted, or `{:error, :unavailable}` when the
  picker is disabled by config, neither native nor wx is available, the
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

      # 2. Neither native tool nor wx fallback is available.
      not native_available?() and not wx_backend().available?() ->
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
    # wx state is no longer cached — wx is initialized fresh in each fallback
    # pick Task. Only the busy flag is tracked.
    {:ok, %{busy: false}}
  end

  @impl true
  def handle_call({:pick, _reply_to, _picker_id}, _from, %{busy: true} = state) do
    # Another pick is already in flight — dialogs are serialized.
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:pick, reply_to, picker_id}, _from, %{busy: false} = state) do
    # Always spawn a single Task — no platform branching, no wx init here.
    # Everything is deferred to the Task which tries native first, then wx.
    gen_server = self()
    Task.start(fn -> run_pick(gen_server, reply_to, picker_id) end)
    {:reply, :ok, %{state | busy: true}}
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

  # --- Native tool availability ---

  # Returns true if the platform's native directory-dialog tool is available.
  #
  # * macOS: always true (osascript is part of macOS)
  # * Linux: true when `zenity` is found in PATH
  # * Windows: always true (PowerShell + .NET Forms)
  # * Other: false
  defp native_available? do
    cond do
      EvoGit.Platform.macos?() -> true
      EvoGit.Platform.linux?() -> System.find_executable("zenity") != nil
      EvoGit.Platform.windows?() -> true
      true -> false
    end
  end

  # --- Unified pick runner ---

  # Runs one pick outside the GenServer process. Tries the native dialog first;
  # falls back to wx if native returns `:unavailable`. Always reports a result
  # to `reply_to` and clears the busy flag via `:pick_done`.
  #
  # ALL external interaction is wrapped in try/catch/rescue: a picker crash
  # must never crash the LiveView — every failure path degrades to
  # `:unavailable`. `rescue` alone does NOT catch exits, so `:exit` and
  # `:throw` are caught explicitly.
  defp run_pick(gen_server, reply_to, picker_id) do
    result =
      try do
        case show_dialog_native() do
          :unavailable -> show_dialog_wx_fallback()
          other -> other
        end
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

  # --- Native dialog dispatcher ---

  # Platform-specific native dialog. Returns `{:ok, path} | :cancelled | :unavailable`.
  # Wrapped in try/catch/rescue so a platform-native-tool crash never propagates —
  # the caller will fall back to wx (or degrade to :unavailable).
  defp show_dialog_native do
    try do
      cond do
        EvoGit.Platform.macos?() -> show_dialog_macos()
        EvoGit.Platform.linux?() -> show_dialog_zenity()
        EvoGit.Platform.windows?() -> show_dialog_powershell()
        true -> :unavailable
      end
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
      :throw, _ -> :unavailable
    end
  end

  # --- macOS: osascript ---

  # Invokes the native macOS folder picker via `osascript` (`choose folder`).
  # This shows a proper macOS-native dialog with no dock icon and no Erlang
  # branding — unlike wx, which registers as a GUI app and shows the Erlang icon
  # in the dock.
  defp show_dialog_macos do
    try do
      default_path = System.user_home() || "/"
      script =
        ~s[POSIX path of (choose folder with prompt "Select Directory" default location (POSIX file "#{default_path}"))]

      case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
        {path, 0} ->
          path = String.trim(path)

          if path != "" do
            {:ok, path}
          else
            :cancelled
          end

        {_, _} ->
          :cancelled
      end
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
      :throw, _ -> :unavailable
    end
  end

  # --- Linux: zenity ---

  defp show_dialog_zenity do
    try do
      case System.cmd("zenity", ["--file-selection", "--directory", "--title=Select Directory"],
             stderr_to_stdout: true) do
        {path, 0} ->
          path = String.trim(path)

          if path != "" do
            {:ok, path}
          else
            :cancelled
          end

        {_, _} ->
          :cancelled
      end
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
      :throw, _ -> :unavailable
    end
  end

  # --- Windows: PowerShell FolderBrowserDialog ---

  defp show_dialog_powershell do
    script = """
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select Directory"
    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Output $dialog.SelectedPath
    }
    """

    try do
      case System.cmd("powershell", ["-NoProfile", "-Command", script],
             stderr_to_stdout: true) do
        {path, 0} ->
          path = String.trim(path)

          if path != "" do
            {:ok, path}
          else
            :cancelled
          end

        {_, _} ->
          :cancelled
      end
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
      :throw, _ -> :unavailable
    end
  end

  # --- wx fallback ---

  # wx fallback: initializes wx fresh in this Task and shows the dialog.
  # Returns `{:ok, path} | :cancelled | :unavailable`.
  defp show_dialog_wx_fallback do
    unless wx_backend().available?() do
      :unavailable
    else
      case wx_new_task() do
        {:ok, ref, env} -> show_dialog(ref, env)
        {:error, _} -> :unavailable
      end
    end
  end

  # The wx backend is injectable via the app env so tests can substitute a
  # deterministic fake (see `EvoDash.DirectoryPicker.Wx` and
  # `test/support/fake_directory_picker_wx.ex`).
  defp wx_backend do
    Application.get_env(:evo_dash, :directory_picker_wx, EvoDash.DirectoryPicker.Wx)
  end

  # Initializes wx in the current (Task) process. Returns `{:ok, ref, env}` or
  # `{:error, :unavailable}`. Each fallback pick initializes wx fresh in its Task —
  # there is no GenServer-cached wx state.
  defp wx_new_task do
    wx = wx_backend()

    # Deliberate try/catch/rescue boundary (see the codebase try/rescue policy):
    # this module's contract is to degrade to :unavailable on every failure path,
    # and `:wx.new/0` can raise, exit, or return a non-wx term (headless Linux
    # with no display). We EXPECT such failures here — wx is an optional
    # runtime dependency and every failure must surface as :unavailable, never
    # as a crash.
    try do
      case wx.new() do
        {:wx_ref, _, _, _} = ref ->
          # `:wx.new/0` installs the env in THIS process's (the Task's)
          # process dictionary; capture it so subsequent wx calls can use it.
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

  defp show_dialog(wx_ref, wx_env) do
    wx = wx_backend()

    # wx commands are delivered per-process: this Task process must adopt the
    # env before any wx call, otherwise `?get_env()` raises
    # `{wx, :unknown_env}`.
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
