defmodule EvoDashWeb.SettingsLive.RemotePanel do
  @moduledoc """
  The `/settings` remote-connections VIEW: the whole `:remote_connections`
  category body (target list, per-target connect / disconnect / bootstrap
  controls, the add-or-edit form and the bootstrap restart dialog) plus the
  render-only presentation helpers it needs (status dot / badge / label, the
  connected predicate and the daisyUI step classes).

  Behaviour lives in `EvoDashWeb.SettingsLive.RemoteEvents`; this module owns no
  state and no side effects — `SettingsLive.render/1` calls
  `remote_connections_panel/1` with the page's own assigns, so every
  `phx-click` / `phx-change` binding is exactly the page's own binding.
  """
  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  # ===========================================================================
  # Presentation helpers
  # ===========================================================================

  # Step <li> classes: completed steps are primary-highlighted; in the error
  # final state the step where the failure occurred is shown as step-error;
  # the success final state colors all five steps green. A nil stage (freshly
  # started bootstrap, or an error before any stage was broadcast) leaves all
  # steps unhighlighted.
  @doc """
  The daisyUI step classes for one bootstrap step.
  """
  def bootstrap_step_class(stage_idx, step_index, status) do
    cond do
      status == :success -> ["step", "step-primary"]
      status == :error and stage_idx == step_index -> ["step", "step-error"]
      is_integer(stage_idx) and stage_idx >= step_index -> ["step", "step-primary"]
      true -> ["step"]
    end
  end

  # Phase → color mapping is owned by `EvoDashWeb.Helpers.connection_status_dot_class/1`;
  # this wrapper resolves the target's phase from the statuses map and keeps the
  # pulse animation for connecting phases (shape classes live at the call site).
  @doc """
  The status-dot classes for one remote target.
  """
  def remote_target_dot_color(target_id, statuses) do
    phase = remote_target_phase(target_id, statuses)
    pulse = if phase in [:connecting, :disconnecting], do: " animate-pulse", else: ""
    EvoDashWeb.Helpers.connection_status_dot_class(phase) <> pulse
  end

  defp remote_target_phase(target_id, statuses) do
    statuses |> Map.get(target_id, %{}) |> Map.get(:phase, :disconnected)
  end

  @doc """
  True when the target's phase is `:connected`.
  """
  def remote_connected?(target_id, statuses) do
    remote_target_phase(target_id, statuses) == :connected
  end

  # Composes the `badge badge-sm` base with the shared phase modifier
  # (`EvoDashWeb.Helpers.connection_status_badge_class/1` owns the mapping).
  @doc """
  The status-badge classes for one remote target.
  """
  def remote_status_badge_class(target_id, statuses) do
    "badge badge-sm " <>
      EvoDashWeb.Helpers.connection_status_badge_class(remote_target_phase(target_id, statuses))
  end

  @doc """
  The localized status label for one remote target.
  """
  def remote_status_label(target_id, statuses) do
    case remote_target_phase(target_id, statuses) do
      :connected -> gettext("Connected")
      :connecting -> gettext("Connecting...")
      :disconnecting -> gettext("Disconnecting...")
      :error -> gettext("Error")
      :disconnected -> gettext("Disconnected")
      _ -> gettext("Unknown")
    end
  end

  # ===========================================================================
  # View: the remote-connections category panel
  # ===========================================================================

  @doc """
  The body of the `/settings` `:remote_connections` category: the target list
  with per-target connect / disconnect / bootstrap controls, the add-or-edit
  form, and the bootstrap restart confirmation dialog.

  Rendered by `SettingsLive.render/1`, which hands it the page's own assigns, so
  the markup and every `phx-click` / `phx-change` binding stay exactly as they
  are on the page — this is a pure relocation of the page's HEEx, not a new
  component contract.
  """
  def remote_connections_panel(assigns) do
    ~H"""
    <%!-- Remote Connections UI — same design as category_section but
                   for the special :remote_connections pseudo-category. Carries
                   `overflow-y-auto` (md+ bounded column) so the sticky header
                   below sticks within this column's own scroll. --%>
    <div
      class="flex-1 flex flex-col min-w-0 overflow-y-auto"
      id="category-remote_connections"
    >
      <EvoDashWeb.SettingsComponents.SectionHeader.section_header
        icon="hero-globe-alt"
        title={gettext("Remote Connections")}
        description={gettext("Manage SSH connections to remote Genesis daemons.")}
      />

      <div class="px-4 sm:px-6 py-4 sm:py-6 space-y-5">
        <%!-- 远程运行 Genesis 分两步：先在服务器上安装远程守护进程（Install），再连接（Connect）；连接后任务在服务器上运行，即使本地应用关闭也会继续 --%>
        <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
          <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
          <p class="text-sm text-base-content/80">
            {gettext(
              "Running Genesis on a remote server takes two steps: first install the remote daemon on the server, then connect to it. Once connected, tasks run on the server and keep running even when you close this app."
            )}
          </p>
        </div>

        <%!-- Note about separate TOML file --%>
        <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
          <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
          <p class="text-sm text-base-content/80">
            {gettext(
              "Connection data is stored in `~/.config/genesis/remote_connections.toml`, separate from the main configuration file."
            )}
          </p>
        </div>

        <%!-- Existing targets --%>
        <div :if={@remote_targets != []} class="space-y-3">
          <div
            :for={target <- @remote_targets}
            class="rounded-lg border border-base-300 bg-base-100 p-4"
          >
            <div class="flex items-start justify-between gap-2">
              <div class="flex items-center gap-3 min-w-0">
                <span class={[
                  "w-2.5 h-2.5 rounded-full shrink-0 mt-1",
                  remote_target_dot_color(target.id, @remote_statuses)
                ]}></span>
                <div class="min-w-0">
                  <p class="font-semibold text-sm truncate">{target.name}</p>
                  <p class="text-xs text-base-content/70 font-mono truncate">
                    {target[:ssh_target] ||
                      "#{target[:user]}@#{target[:host]}#{if target[:port] && target[:port] != 22, do: ":#{target[:port]}", else: ""}"}
                  </p>
                </div>
              </div>
              <span class={remote_status_badge_class(target.id, @remote_statuses)}>
                {remote_status_label(target.id, @remote_statuses)}
              </span>
            </div>

            <div class="flex items-center gap-1 mt-3 flex-wrap">
              <button
                class="btn btn-sm btn-ghost gap-1"
                phx-click="edit_remote_target"
                phx-value-id={target.id}
              >
                <.icon name="hero-pencil-square" class="size-3.5" />
                {gettext("Edit")}
              </button>
              <button
                class="btn btn-sm btn-ghost gap-1"
                phx-click="delete_remote_target"
                phx-value-id={target.id}
              >
                <.icon name="hero-trash" class="size-3.5" />
                {gettext("Delete")}
              </button>
              <div class="flex-1"></div>
              <%= if remote_connected?(target.id, @remote_statuses) do %>
                <button
                  class="btn btn-sm btn-ghost gap-1 text-warning"
                  phx-click="disconnect_remote_target"
                  phx-value-id={target.id}
                >
                  <.icon name="hero-arrow-left-end-on-rectangle" class="size-3.5" />
                  {gettext("Disconnect")}
                </button>
              <% else %>
                <%= if bootstrap_entry = @bootstrap_progress[target.id] do %>
                  <% stage_idx = bootstrap_entry.stage %>
                  <% bootstrap_status = bootstrap_entry.status %>
                  <div class="w-full space-y-2">
                    <ul class="steps steps-horizontal text-xs w-full">
                      <li class={bootstrap_step_class(stage_idx, 0, bootstrap_status)}>
                        <%!-- 探测远程平台/OS、上传本地发布包 --%>
                        {gettext("Probing / preparing")}
                      </li>
                      <li class={bootstrap_step_class(stage_idx, 1, bootstrap_status)}>
                        {gettext("Downloading")}
                      </li>
                      <li class={bootstrap_step_class(stage_idx, 2, bootstrap_status)}>
                        {gettext("Extracting")}
                      </li>
                      <li class={bootstrap_step_class(stage_idx, 3, bootstrap_status)}>
                        <%!-- 设置权限、复制配置、生成cookie、修补二进制、停止已运行的守护进程 --%>
                        {gettext("Configuring")}
                      </li>
                      <li class={bootstrap_step_class(stage_idx, 4, bootstrap_status)}>
                        {gettext("Starting daemon")}
                      </li>
                    </ul>

                    <%!-- Error-final: partial bar + error text + Install (retry) --%>
                    <%= if bootstrap_status == :error do %>
                      <p
                        :if={bootstrap_entry.error}
                        class="text-xs text-error flex items-start gap-1.5"
                      >
                        <.icon
                          name="hero-exclamation-triangle"
                          class="size-3.5 mt-0.5 shrink-0"
                        />
                        <span class="break-all">{bootstrap_entry.error}</span>
                      </p>
                      <div class="flex items-center gap-1 flex-wrap">
                        <button
                          class="btn btn-sm btn-ghost gap-1"
                          phx-click="bootstrap_remote_target"
                          phx-value-id={target.id}
                        >
                          <.icon name="hero-rocket-launch" class="size-3.5" />
                          {gettext("Install")}
                        </button>
                      </div>
                    <% end %>

                    <%!-- Success-final: all-green bar + Install/Connect still visible --%>
                    <%= if bootstrap_status == :success do %>
                      <div class="flex items-center gap-1 flex-wrap">
                        <button
                          class="btn btn-sm btn-ghost gap-1"
                          phx-click="bootstrap_remote_target"
                          phx-value-id={target.id}
                        >
                          <.icon name="hero-rocket-launch" class="size-3.5" />
                          {gettext("Install")}
                        </button>
                        <button
                          class="btn btn-sm btn-primary gap-1"
                          phx-click="connect_remote_target"
                          phx-value-id={target.id}
                        >
                          <.icon
                            name="hero-arrow-right-end-on-rectangle"
                            class="size-3.5"
                          />
                          {gettext("Connect")}
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <button
                    class="btn btn-sm btn-ghost gap-1"
                    phx-click="bootstrap_remote_target"
                    phx-value-id={target.id}
                  >
                    <.icon name="hero-rocket-launch" class="size-3.5" />
                    {gettext("Install")}
                  </button>
                  <button
                    class="btn btn-sm btn-primary gap-1"
                    phx-click="connect_remote_target"
                    phx-value-id={target.id}
                  >
                    <.icon name="hero-arrow-right-end-on-rectangle" class="size-3.5" />
                    {gettext("Connect")}
                  </button>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <div :if={@remote_targets == []} class="text-center py-10 text-base-content/70">
          <.icon
            name="hero-server-stack"
            class="size-12 mx-auto mb-3 text-base-content/40"
          />
          <p class="text-sm">{gettext("No remote connections configured.")}</p>
        </div>

        <%!-- SSH config help banner --%>
        <div class="rounded-lg border border-base-300 bg-base-200 p-3 flex items-start gap-3">
          <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
          <div class="space-y-1.5">
            <p class="text-sm text-base-content/80">
              {gettext(
                "Configure your SSH server in `~/.ssh/config` and set up SSH key authentication."
              )}
            </p>
            <p class="text-sm text-base-content/80">
              {gettext(
                "Enter the SSH target (the same string you'd type after `ssh`, e.g. `gpu-server` or `user@host`)."
              )}
            </p>
            <p class="text-sm text-base-content/80">
              {gettext(
                "SSH port, identity file, and other options are read from your SSH config — no need to enter them here."
              )}
            </p>
          </div>
        </div>

        <%!-- Add / Edit target form --%>
        <div class="border-t border-base-300 pt-5">
          <%= if @remote_form_target do %>
            <h4 class="font-semibold text-sm mb-4">
              <%= if @remote_form_target[:id] do %>
                {gettext("Edit Connection")}
              <% else %>
                {gettext("Add Connection")}
              <% end %>
            </h4>
            <form
              id="remote-connections-form"
              phx-submit="save_remote_target"
              phx-change="remote_connections_form_change"
              class="space-y-4"
            >
              <input type="hidden" name="_id" value={@remote_form_target[:id]} />
              <div class="grid grid-cols-2 gap-4">
                <div class="form-control col-span-2">
                  <label class="label">
                    <span class="label-text font-semibold text-xs">{gettext("Name")}</span>
                  </label>
                  <input
                    type="text"
                    name="name"
                    value={@remote_form_target[:name]}
                    placeholder={gettext("e.g. GPU Server")}
                    class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                  />
                </div>
                <div class="form-control col-span-2">
                  <label class="label">
                    <span class="label-text font-semibold text-xs">{gettext("SSH Target")}</span>
                  </label>
                  <input
                    type="text"
                    name="ssh_target"
                    value={@remote_form_target[:ssh_target]}
                    placeholder={gettext("gpu-server or user@host")}
                    class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                  />
                </div>
                <div class="col-span-2 flex">
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm gap-1 -mt-1 text-base-content/70"
                    phx-click="toggle_remote_advanced"
                  >
                    <.icon
                      name={"hero-chevron-" <> if(@remote_show_advanced, do: "up", else: "down")}
                      class="size-3.5"
                    />
                    {gettext("Advanced settings")}
                    <%!-- 高级设置（折叠面板标题，展开后显示高级连接字段） --%>
                  </button>
                </div>
                <%!-- CSS `hidden` (not `:if`) keeps the inputs in the DOM so they are
                             always submitted on save: editing an existing target with a
                             NON-default dist_port/remote_path would otherwise silently reset
                             those values to the backend defaults. With `hidden` the inputs
                             keep submitting their prefilled values exactly as today,
                             preserving custom values and keeping
                             build_remote_target_from_params/1 unchanged. --%>
                <div class={"grid grid-cols-2 gap-4 col-span-2" <> if(@remote_show_advanced, do: "", else: " hidden")}>
                  <div class="form-control col-span-2">
                    <label class="label">
                      <span class="label-text font-semibold text-xs">{gettext("Local Release Tarball")}</span>
                    </label>
                    <input
                      type="text"
                      name="local_binary_path"
                      value={@remote_form_target[:local_binary_path]}
                      placeholder="_build/prod/rel/genesis_server.tar.xz"
                      class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                    />
                    <p class="text-xs text-base-content/70 mt-1">
                      {gettext("Leave blank to auto-download the release on the remote")}
                    </p>
                  </div>
                  <div class="form-control col-span-2">
                    <label class="label">
                      <span class="label-text font-semibold text-xs">{gettext("Platform (optional)")}</span>
                    </label>
                    <input
                      type="text"
                      name="platform"
                      value={@remote_form_target[:platform]}
                      placeholder="linux_x64, darwin_arm64, windows_x64"
                      class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                    />
                    <p class="text-xs text-base-content/70 mt-1">
                      {gettext("Blank = auto-probe the remote OS/arch")}
                    </p>
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text font-semibold text-xs">{gettext("Dist Port")}</span>
                    </label>
                    <input
                      type="number"
                      name="dist_port"
                      value={@remote_form_target[:dist_port]}
                      placeholder="9000"
                      class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                    />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text font-semibold text-xs">{gettext("Remote Path")}</span>
                    </label>
                    <input
                      type="text"
                      name="remote_path"
                      value={@remote_form_target[:remote_path]}
                      placeholder="/tmp/genesis_server"
                      class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                    />
                  </div>
                </div>
              </div>
              <div class="flex items-center justify-end gap-2 pt-1">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm rounded-lg"
                  phx-click="cancel_edit_remote"
                >
                  {gettext("Cancel")}
                </button>
                <button type="submit" class="btn btn-primary btn-sm rounded-lg">
                  <%= if @remote_form_target[:id] do %>
                    {gettext("Save")}
                  <% else %>
                    {gettext("Add")}
                  <% end %>
                </button>
              </div>
            </form>
          <% else %>
            <button
              class="btn btn-ghost btn-sm gap-2 w-full border border-dashed border-base-300 rounded-lg"
              phx-click="add_remote_target"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add Connection")}
            </button>
          <% end %>
        </div>
      </div>
    </div>

    <%!-- Distribution-already-enabled permission dialog — opened when
                   a bootstrap attempt is refused because the remote host is
                   already running with Erlang distribution enabled for another
                   connection ({:error, {:daemon_running, details}}).
                   Confirming re-bootstraps via
                   EvoGit.RemoteConnection.bootstrap/2 with on_running: :restart,
                   which only runs `remote stop` (detaching distribution) and
                   re-enables it with this connection's identity — the remote
                   server and its tasks keep running (core broadcasts
                   :stopping_daemon → step 3 "Configuring", then the normal
                   stages). Driven by the @bootstrap_restart_confirm
                   assign (nil = closed, %{id:, details:} = open). --%>
    <%= if @bootstrap_restart_confirm do %>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div
          class="fixed inset-0 bg-black/50 backdrop-blur-sm"
          phx-click="cancel_bootstrap_restart"
          phx-value-target_id={@bootstrap_restart_confirm.id}
        >
        </div>
        <div class="relative bg-base-100 rounded-xl shadow-2xl border border-base-300 max-w-lg w-full p-5 sm:p-6">
          <div class="flex items-center gap-3 mb-4">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
            <h3 class="text-lg font-semibold">
              {gettext("Remote node already connected")}
            </h3>
          </div>

          <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
            {gettext(
              "That host's Genesis server already has Erlang distribution enabled for another connection. Continuing will disconnect that node and re-enable distribution with this connection's identity. The server and its tasks keep running."
            )}
          </p>
          <p class="text-xs text-base-content/70 mb-5 leading-relaxed font-mono break-all">
            {@bootstrap_restart_confirm.details}
          </p>

          <div class="flex justify-end gap-3 pt-2">
            <button
              type="button"
              class="btn btn-ghost rounded-md px-6"
              phx-click="cancel_bootstrap_restart"
              phx-value-target_id={@bootstrap_restart_confirm.id}
            >
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              class="btn btn-warning rounded-md px-6 gap-2"
              phx-click="confirm_bootstrap_restart"
              phx-value-target_id={@bootstrap_restart_confirm.id}
            >
              <.icon name="hero-arrow-path" class="size-4.5" />
              {gettext("Reconnect & re-enable")}
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
