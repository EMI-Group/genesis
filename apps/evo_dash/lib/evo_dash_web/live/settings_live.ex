defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).
  """
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema
  alias EvoDash.SettingsUtils
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.CustomAgentEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers
  alias EvoDashWeb.SettingsLive.SearchEvents

  # Tag for the async node-data load result message (see
  # EvoDashWeb.SettingsLive.NodeData). Tests that deliver results
  # deterministically must use this same atom.
  @node_data_tag :settings_node_data_loaded

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:settings}
      config_status={@config_status}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <%= if @active_category not in [:remote_connections, :agents] do %>
          <%!-- Config file path display --%>
          <div class="mb-4 p-3 flex items-center gap-3 border-b border-base-300">
            <.icon name="hero-document-text" class="size-4 text-base-content/70 shrink-0" />
            <span class="text-xs font-medium text-base-content/70 shrink-0">{gettext(
              "Configuration file"
            )}</span>
            <code class="font-mono text-sm text-base-content/80 flex-1 truncate">{@config_path}</code>
            <button
              id="settings-config-path-copy"
              phx-hook="ClipboardCopy"
              data-content={@config_path}
              class="btn btn-ghost btn-sm btn-square"
              title={gettext("Copy path")}
            >
              <.icon name="hero-clipboard-document" class="size-4" />
            </button>
          </div>
          <%= if not @config_file_exists do %>
            <p class="mb-4 text-xs text-base-content/70">{gettext("File does not exist yet")}</p>
          <% end %>
        <% end %>

        <%!-- Config Status Warning --%>
        <%= if @config_status && not @config_status.ok? do %>
          <div class="mb-4 rounded-lg border border-warning/30 bg-warning/5 p-3 flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
            <div>
              <h3 class="font-bold text-sm text-warning mb-2">{gettext("Missing Configuration")}</h3>
              <ul class="space-y-1.5 mb-3">
                <%= for warning <- @config_status.warnings do %>
                  <li class="text-sm font-medium text-warning/80 flex items-start gap-2">
                    <.icon name="hero-chevron-right" class="size-4 mt-0.5 shrink-0 opacity-70" />
                    <span>{warning}</span>
                  </li>
                <% end %>
              </ul>
              <p class="text-sm font-semibold text-base-content/80">
                {gettext("Configure your LLM model in the LLM category to resolve these issues.")}
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Remote config load error — the remote node's config could not be
           fetched (node unreachable, RPC failure, ...). Shown INSTEAD of the
           "No LLM Model Configured" warning below so the user sees the real
           problem rather than a bogus unconfigured-model message. --%>
        <%= if @remote_config_error do %>
          <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
            <div>
              <h3 class="font-bold text-sm text-error mb-2">
                {gettext("Remote Configuration Unavailable")}
              </h3>
              <p class="text-sm font-medium text-error/80 leading-relaxed max-w-3xl">
                {@remote_config_error}
              </p>
            </div>
          </div>
        <% end %>

        <%!-- No LLM Model Warning (gated off while a remote config load error is
           shown — otherwise "No LLM Model Configured" would render on top of
           the real problem) --%>
        <%= if @remote_config_error == nil and
              (is_nil(get_in(@file_config, [:llm, :models])) or
                 Enum.empty?(get_in(@file_config, [:llm, :models]) || [])) do %>
          <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
            <div>
              <h3 class="font-bold text-sm text-error mb-2">{gettext("No LLM Model Configured")}</h3>
              <p class="text-sm font-medium text-error/80 mb-3 leading-relaxed max-w-3xl">
                {gettext(
                  "Agents cannot run until you set a model. Go to the LLM category and fill in the Model field."
                )}
              </p>
              <div class="flex items-center gap-3 flex-wrap">
                <span class="text-xs font-bold uppercase tracking-wider text-base-content/70">{gettext(
                  "Example model names:"
                )}</span>
                <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">anthropic:claude-opus-4-7</span>
                <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">openai:gpt-5.5</span>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Settings card: two-column sidebar + content layout.
           Note: `gap-8` generates correctly in Tailwind v4 via
           `calc(var(--spacing) * N)` (with `--spacing: 0.25rem` at `:root`).
           The cards ARE direct children (HEEx comments emit no DOM nodes).
           The earlier spacing fixes (commits 08c3ec35 and 6a48e9e2) appeared to
           fail only because the gitignored CSS build (`priv/static/assets/css/`)
           was never regenerated after the HEEx edits, so the app served a stale
           bundle lacking the new utility classes. After editing Tailwind classes
           here, rebuild assets with `mix tailwind evo_dash` (dev) or
           `mix assets.deploy` (prod) so the new utilities are emitted. --%>
        <div class="flex flex-col gap-8">
          <%!-- Two-column sidebar + content layout --%>
          <div class="flex flex-col md:flex-row bg-base-100">
            <%!-- Sidebar --%>
            <EvoDashWeb.SettingsComponents.settings_sidebar
              categories={@schemas_by_category}
              active_category={@active_category}
              search_text={@search_text}
            />

            <%!-- Content area --%>
            <%= if @search_text != "" do %>
              <.form
                for={%{}}
                phx-submit="save_search"
                class="flex-1 flex flex-col min-w-0 relative"
                id="settings-form-search"
              >
                <EvoDashWeb.SettingsComponents.search_results
                  categories={@schemas_by_category}
                  search_text={@search_text}
                  file_config={@file_config}
                  errors={ConfigIO.all_errors(@per_category_errors)}
                />
              </.form>
            <% else %>
              <%= if @active_category == :remote_connections do %>
                <%!-- Remote Connections UI — same design as category_section but
                   for the special :remote_connections pseudo-category --%>
                <div class="flex-1 flex flex-col min-w-0">
                  <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md px-6 py-4 border-b border-base-300/70">
                    <div class="flex items-center gap-3 mb-1">
                      <.icon name="hero-globe-alt" class="size-5 text-base-content/70" />
                      <h2 class="text-lg font-bold text-base-content">
                        {gettext("Remote Connections")}
                      </h2>
                    </div>
                    <p class="text-sm text-base-content/60">
                      {gettext("Manage SSH connections to remote Genesis daemons.")}
                    </p>
                  </div>

                  <div class="p-6 space-y-5">
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
                            class="btn btn-xs btn-ghost gap-1"
                            phx-click="edit_remote_target"
                            phx-value-id={target.id}
                          >
                            <.icon name="hero-pencil-square" class="size-3.5" />
                            {gettext("Edit")}
                          </button>
                          <button
                            class="btn btn-xs btn-ghost gap-1"
                            phx-click="delete_remote_target"
                            phx-value-id={target.id}
                          >
                            <.icon name="hero-trash" class="size-3.5" />
                            {gettext("Delete")}
                          </button>
                          <div class="flex-1"></div>
                          <%= if remote_connected?(target.id, @remote_statuses) do %>
                            <button
                              class="btn btn-xs btn-ghost gap-1 text-warning"
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

                                <%!-- Error-final: partial bar + error text + Bootstrap (retry) --%>
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
                                      class="btn btn-xs btn-ghost gap-1"
                                      phx-click="bootstrap_remote_target"
                                      phx-value-id={target.id}
                                    >
                                      <.icon name="hero-rocket-launch" class="size-3.5" />
                                      {gettext("Bootstrap")}
                                    </button>
                                  </div>
                                <% end %>

                                <%!-- Success-final: all-green bar + Bootstrap/Connect still visible --%>
                                <%= if bootstrap_status == :success do %>
                                  <div class="flex items-center gap-1 flex-wrap">
                                    <button
                                      class="btn btn-xs btn-ghost gap-1"
                                      phx-click="bootstrap_remote_target"
                                      phx-value-id={target.id}
                                    >
                                      <.icon name="hero-rocket-launch" class="size-3.5" />
                                      {gettext("Bootstrap")}
                                    </button>
                                    <button
                                      class="btn btn-xs btn-primary gap-1"
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
                                class="btn btn-xs btn-ghost gap-1"
                                phx-click="bootstrap_remote_target"
                                phx-value-id={target.id}
                              >
                                <.icon name="hero-rocket-launch" class="size-3.5" />
                                {gettext("Bootstrap")}
                              </button>
                              <button
                                class="btn btn-xs btn-primary gap-1"
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
                      <.icon name="hero-server-stack" class="size-12 mx-auto mb-3 text-base-content/40" />
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
                        <form phx-submit="save_remote_target" class="space-y-4">
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
                                class="btn btn-ghost btn-xs gap-1 -mt-1 text-base-content/70"
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
                                  <span class="label-text font-semibold text-xs">{gettext(
                                    "Local Release Tarball"
                                  )}</span>
                                </label>
                                <input
                                  type="text"
                                  name="local_binary_path"
                                  value={@remote_form_target[:local_binary_path]}
                                  placeholder="_build/prod/rel/genesis_remote.tar.xz"
                                  class="input input-bordered input-sm w-full rounded-lg bg-base-100 font-mono text-sm"
                                />
                                <p class="text-xs text-base-content/70 mt-1">
                                  {gettext("Leave blank to auto-download the release on the remote")}
                                </p>
                              </div>
                              <div class="form-control col-span-2">
                                <label class="label">
                                  <span class="label-text font-semibold text-xs">{gettext(
                                    "Platform (optional)"
                                  )}</span>
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
                                  <span class="label-text font-semibold text-xs">{gettext(
                                    "Remote Path"
                                  )}</span>
                                </label>
                                <input
                                  type="text"
                                  name="remote_path"
                                  value={@remote_form_target[:remote_path]}
                                  placeholder="/tmp/genesis_remote"
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

                <%!-- Daemon-already-running permission dialog — opened when a
                   bootstrap attempt is refused because the remote daemon is
                   already running ({:error, {:daemon_running, details}}).
                   Confirming stops the daemon and re-bootstraps via
                   EvoGit.RemoteConnection.bootstrap/2 with on_running: :restart
                   (core broadcasts :stopping_daemon → step 3 "Configuring",
                   then the normal stages). Driven by the @bootstrap_restart_confirm
                   assign (nil = closed, %{id:, details:} = open). --%>
                <%= if @bootstrap_restart_confirm do %>
                  <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
                    <div
                      class="fixed inset-0 bg-black/50 backdrop-blur-sm"
                      phx-click="cancel_bootstrap_restart"
                      phx-value-target_id={@bootstrap_restart_confirm.id}
                    >
                    </div>
                    <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
                      <div class="flex items-center gap-3 mb-4">
                        <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
                        <h3 class="text-lg font-bold">
                          <%!-- 远程守护进程已经在运行；重新引导会先停止它 --%>
                          {gettext("Remote daemon already running")}
                        </h3>
                      </div>

                      <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                        {gettext(
                          "The remote daemon is already running. Re-bootstrapping will stop it and any tasks running on the remote."
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
                          <%!-- 停止守护进程并重新执行引导 --%>
                          {gettext("Stop & re-bootstrap")}
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% else %>
                <%!-- Custom Agents UI — same design as category_section but for
                   the special :agents pseudo-category. Both editors contain
                   their own <form> elements (save_custom_agent,
                   save_model_selection_script), so they are NOT wrapped in a
                   save_category form (nested <form> elements are invalid
                   HTML). --%>
                <%= if @active_category == :agents do %>
                  <div class="flex-1 flex flex-col min-w-0">
                    <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md px-6 py-4 border-b border-base-300/70">
                      <div class="flex items-center gap-3 mb-1">
                        <.icon name="hero-user-group" class="size-5 text-base-content/70" />
                        <h2 class="text-lg font-bold text-base-content">
                          {gettext("Agents")}
                        </h2>
                      </div>
                      <p class="text-sm text-base-content/60">
                        {gettext(
                          "Create custom agents and configure the per-agent model selection script."
                        )}
                      </p>
                    </div>

                    <div class="p-6 space-y-5">
                      <%!-- Note about the separate TOML file --%>
                      <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
                        <.icon
                          name="hero-information-circle"
                          class="size-5 text-info shrink-0 mt-0.5"
                        />
                        <p class="text-sm text-base-content/80">
                          {gettext(
                            "Custom agents are stored in `agents.toml`, next to the main configuration file."
                          )}
                        </p>
                      </div>

                      <EvoDashWeb.SettingsComponents.CustomAgentsEditor.custom_agents_editor
                        agents={@custom_agents}
                        editing_agent_id={@editing_agent_id}
                        model_profiles={@file_config[:llm][:models] || []}
                      />

                      <EvoDashWeb.SettingsComponents.ModelSelectionEditor.model_selection_editor
                        script={@model_selection_script}
                        script_status={@script_status}
                        script_save_error={@script_save_error}
                        test_results={@script_test_results}
                      />
                    </div>
                  </div>
                <% else %>
                  <%!-- category_section renders its own <form phx-submit="save_category">
                 internally. The LLM category's Quick Setup panel and Model
                 Profiles editor contain their own nested forms (save_api_key,
                 save_custom_model, save_model_profile), so they must NOT be
                 wrapped in the outer save_category form (nested <form> elements
                 are invalid HTML — browsers ignore the inner <form> tag, causing
                 the profile editor's Save button to submit save_category instead
                 of save_model_profile, which deletes the models list). --%>
                  <EvoDashWeb.SettingsComponents.category_section
                    category={@active_category}
                    schemas={Map.get(@schemas_by_category, @active_category, [])}
                    file_config={@file_config}
                    errors={Map.get(@per_category_errors, @active_category, [])}
                    sandbox_backend={sandbox_backend(assigns)}
                    sandbox_mode={get_in(@file_config, [:sandbox, :mode])}
                    llm_providers={@llm_providers}
                    selected_provider_id={@selected_provider_id}
                    selected_provider_models={@selected_provider_models}
                    selected_variant_id={@selected_variant_id}
                    selected_model_string={@selected_model_string}
                    llm_test_status={@llm_test_status}
                    model_profiles={@file_config[:llm][:models] || []}
                    editing_profile_id={@editing_profile_id}
                    profile_form_draft={@profile_form_draft}
                    appearance_accent_draft={@appearance_accent_draft}
                    test_profile_id={@test_profile_id}
                    credentials={@credentials}
                  />
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
    end

    config_status = config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = ConfigIO.load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    models = get_in(file_config, [:llm, :models]) || []
    test_profile_id = if models != [], do: ModelProfileHelpers.profile_id(hd(models))

    schemas_by_category = Map.put(schemas_by_category, :remote_connections, [])
    schemas_by_category = Map.put(schemas_by_category, :agents, [])

    # Snapshot of the UNFILTERED schemas map (all schema categories plus the
    # two pseudo-categories, BEFORE the platform-OS/nix filtering below). The
    # async node-data task (NodeData) re-filters it for the currently-viewed
    # (possibly remote) node and the result handler replaces
    # `schemas_by_category` with the filtered map — see handle_params/3.
    all_schemas_by_category = schemas_by_category

    # Platform-aware schema filtering: hide the sandbox category (or its
    # Linux-only sub-sections) on platforms where they don't apply. This is
    # BOTH the display mechanism and the save round-trip protection —
    # save_category only processes schemas present in this filtered list, so
    # hidden fields can never clobber saved sandbox config. Mount's own
    # filtering is local-only/cheap (current_node is nil/local at mount time);
    # the per-node filtering for navigations runs in the async task.
    platform_os = EvoDashWeb.PlatformInfo.os_for_node(socket.assigns[:current_node])

    schemas_by_category =
      EvoDashWeb.PlatformInfo.filter_schemas_by_category(schemas_by_category, platform_os)

    # Hide the Nix category when the nix binary is missing on this node AND
    # the user hasn't explicitly set `[nix] enabled` in the raw config file
    # (an explicit true OR false keeps it visible — the schema default of
    # false alone is not "configured").
    schemas_by_category =
      EvoDashWeb.PlatformInfo.filter_nix_category(
        schemas_by_category,
        socket.assigns[:current_node]
      )

    socket =
      assign(socket,
        schemas_by_category: schemas_by_category,
        all_schemas_by_category: all_schemas_by_category,
        platform_os: platform_os,
        active_category: :llm,
        search_text: "",
        per_category_errors: %{},
        scheduler_config: ConfigIO.load_scheduler_config(),
        config_status: config_status,
        file_config: file_config,
        config_path: config_path,
        config_file_exists: config_file_exists,
        credentials: EvoGit.Config.credentials(),
        llm_providers: EvoGit.Config.LLMCatalog.providers(),
        selected_provider_id: nil,
        selected_provider_models: [],
        selected_variant_id: nil,
        selected_model_string: nil,
        llm_test_status: :idle,
        editing_profile_id: nil,
        profile_form_draft: nil,
        # Pending accent-color selection for the :appearance category (nil = no
        # pending draft). Set by `select_appearance_accent`; cleared whenever
        # file_config is replaced by an authoritative load (see
        # apply_node_data_results, save paths, reset_key).
        appearance_accent_draft: nil,
        test_profile_id: test_profile_id,
        remote_config: false,
        remote_config_error: nil,
        bootstrap_progress: %{},
        bootstrap_restart_confirm: nil,
        remote_targets: EvoDash.NodeContext.list_targets(),
        remote_statuses: EvoDash.NodeContext.connection_status(),
        remote_form_target: nil,
        remote_show_advanced: false
      )
      |> load_custom_agents_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/settings")

    # Seeded shell (async platform gating): the platform-filtered schemas map
    # and the platform OS for the (possibly remote) node are computed in the
    # async node-data task below (NodeData) — never block the LiveView render
    # loop on cross-node RPCs. Until the result arrives, seed the UNFILTERED
    # schemas (all categories visible) so the page shell renders immediately;
    # the result handler re-filters and re-resolves the active category.
    socket = assign(socket, :schemas_by_category, socket.assigns.all_schemas_by_category)
    socket = assign(socket, :platform_os, socket.assigns.platform_os || :unknown)

    # Seed the active category with a flash-minimizing rule: non-gated
    # categories (`?category=agents`, `:remote_connections`, `:llm`, ...)
    # resolve against the UNFILTERED map and render their section immediately
    # with zero flash; potentially-gated ones (:nix / :sandbox — the platform
    # filter may hide them) and unresolvable params defer to the result
    # handler and seed the current stable category (or :llm) instead.
    category = seed_category(params, socket)

    socket =
      if category != socket.assigns.active_category do
        assign(socket, :active_category, category)
      else
        socket
      end

    # Kick off the ASYNC node-data load (platform gating + config + custom
    # agents) in a supervised task — never block the LiveView render loop on
    # cross-node RPCs. The page shell above (with mount's locally-loaded config
    # and the seeded category) renders immediately; the result arrives via
    # handle_info({@node_data_tag, ...}) with a stale-guard against node
    # switches. Per-save flows (save_category, persist_file_config,
    # CustomAgentEvents) remain synchronous and reload fresh data themselves.
    EvoDashWeb.SettingsLive.NodeData.start(socket, @node_data_tag, params["category"])

    {:noreply, socket}
  end

  # Seeds the active category for the shell render BEFORE the async node-data
  # result arrives. Resolves `params["category"]` against the UNFILTERED
  # schemas map (whitelist via ConfigIO.category_str_to_atom, with the
  # "remote_connections"/"agents" pseudo-categories special-cased exactly like
  # the pre-async code). `:nix`/`:sandbox` (potentially hidden by the platform
  # filter) and unresolvable params (nil/unknown) seed the current
  # active_category when it is a stable non-gated value, else the safe `:llm`
  # default — so non-gated navigations render their section immediately, while
  # gated ones defer to the result handler's re-resolution.
  defp seed_category(params, socket) do
    category_str_to_atom = ConfigIO.category_str_to_atom(socket.assigns.all_schemas_by_category)

    requested =
      case params["category"] do
        "remote_connections" -> :remote_connections
        "agents" -> :agents
        cat when is_binary(cat) -> Map.get(category_str_to_atom, cat)
        _ -> nil
      end

    if requested in [nil, :nix, :sandbox] do
      if socket.assigns.active_category in [nil, :nix, :sandbox] do
        :llm
      else
        socket.assigns.active_category
      end
    else
      requested
    end
  end

  @impl true
  def handle_info({@node_data_tag, requested_node, category_param, results}, socket) do
    # Stale-guard: the load was requested for `requested_node` at spawn time;
    # if the user has since switched nodes (current_node differs), a newer
    # load is already in flight for the new node — drop this result rather
    # than flashing the wrong node's config/agents on screen.
    if requested_node != socket.assigns.current_node do
      {:noreply, socket}
    else
      {:noreply, apply_node_data_results(socket, category_param, results)}
    end
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)

    socket =
      if socket.assigns.active_category == :remote_connections do
        socket
        |> assign(:remote_targets, EvoDash.NodeContext.list_targets())
        |> assign(:remote_statuses, EvoDash.NodeContext.connection_status())
      else
        socket
      end

    # A node switch changes the config domain — a draft picked on the previous
    # node's config must not leak onto the new node's appearance card.
    {:noreply, assign(socket, :appearance_accent_draft, nil)}
  end

  @impl true
  def handle_info({:remote_connection_status, target_id, status} = msg, socket) do
    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)

    socket =
      if socket.assigns.active_category == :remote_connections do
        assign(socket, :remote_statuses, EvoDash.NodeContext.connection_status())
      else
        socket
      end

    bootstrap_progress =
      update_bootstrap_progress(socket.assigns.bootstrap_progress, target_id, status)

    {:noreply, assign(socket, :bootstrap_progress, bootstrap_progress)}
  end

  @impl true
  def handle_info({:bootstrap_complete, id, result}, socket) do
    socket =
      case result do
        {:error, {:daemon_running, details}} ->
          # Daemon already running (refused bootstrap) — no staging happened.
          # Drop the transient active entry (the bar would otherwise sit on a
          # stage-less "active" state forever) and ask the user for permission
          # to stop it and re-bootstrap (see confirm_bootstrap_restart). No
          # generic error flash — the dialog IS the feedback.
          socket
          |> reload_remote_statuses()
          |> clear_bootstrap_progress(id)
          |> assign(:bootstrap_restart_confirm, %{id: id, details: details})

        {:ok, _} ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :success)
          |> flash_remote_lifecycle_result(result, gettext("Bootstrap"))

        :ok ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :success)
          |> flash_remote_lifecycle_result(result, gettext("Bootstrap"))

        {:error, reason} ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :error, bootstrap_error_text(reason))
          |> flash_remote_lifecycle_result(result, gettext("Bootstrap"))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:scheduler_config_updated, node}, socket) do
    # Node filter first: foreign-node events are ignored (socket unchanged).
    #
    # NOTE — pre-existing gap, deliberately NOT fixed in the push-refactor:
    # the reload still reads the LOCAL scheduler config
    # (ConfigIO.load_scheduler_config() → AgentScheduler.get_config()) even
    # while viewing a remote node — remote viewers never get a remote-refresh
    # path for this assign today. Behavior kept exactly as before.
    if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, assign(socket, :scheduler_config, ConfigIO.load_scheduler_config())}
    else
      # Foreign-node event — dropped, socket unchanged.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:llm_test_result, result}, socket) do
    status =
      case result do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :llm_test_status, status)}
  end

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = msg, socket) do
    # Node-identity task broadcast — node-filtered (foreign-node events are
    # dropped BEFORE the debounce is scheduled) and debounced (300ms trailing
    # edge) inside NodeAware.handle_task_info/2, which already returns
    # {:noreply, socket}.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired — reload the sidebar's running/pending tasks.
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}
  end

  @impl true
  def handle_event("select_category", %{"category" => cat_str}, socket) do
    # Whitelist lookup: validate the client-supplied category string against the
    # known schema category atoms. Unknown value → nil → keep current category.
    cat =
      Map.get(ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category), cat_str) ||
        if(cat_str == "remote_connections", do: :remote_connections) ||
        socket.assigns.active_category

    socket =
      assign(socket,
        active_category: cat,
        search_text: "",
        per_category_errors: %{}
      )

    socket =
      if cat == :remote_connections do
        socket
        |> assign(:remote_targets, EvoDash.NodeContext.list_targets())
        |> assign(:remote_statuses, EvoDash.NodeContext.connection_status())
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDash.NodeContext.connect(socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("search", params, socket), do: SearchEvents.handle_search(socket, params)

  # Prevents page reload when pressing Enter in the search form
  @impl true
  def handle_event("noop", params, socket), do: SearchEvents.handle_noop(socket, params)

  @impl true
  def handle_event("save_category", params, socket) do
    # Whitelist lookup: validate the category string against known schema atoms.
    # Unknown value → nil → fall back to the current active_category.
    category =
      case params["category"] do
        cat_str when is_binary(cat_str) ->
          Map.get(ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category), cat_str)

        _ ->
          nil
      end

    category = category || socket.assigns.active_category

    schemas = Map.get(socket.assigns.schemas_by_category, category, [])

    # Build config from params and merge into full file_config
    config =
      ConfigIO.build_config_from_category_params(
        params,
        category,
        schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        node = socket.assigns.current_node

        case EvoDash.NodeContext.save_user_config(node, config) do
          :ok ->
            {file_config, socket} =
              if node == node() do
                # Local save — reload from disk
                fc = ConfigIO.load_file_config()
                {fc, assign(socket, :config_status, config_status())}
              else
                # Remote save — reload the remote scheduler config and re-fetch
                EvoDash.NodeContext.reload_remote_config(node)
                remote_cfg = EvoDash.NodeContext.get_remote_config(node)
                fc = remote_config_to_file_config(remote_cfg)

                {fc,
                 assign(
                   socket,
                   :config_status,
                   EvoDash.NodeContext.get_remote_config_status(node)
                 )}
              end

            config_file_exists = File.exists?(socket.assigns.config_path)

            socket =
              socket
              |> assign(:file_config, file_config)
              |> assign(:config_file_exists, config_file_exists)
              |> assign(:per_category_errors, %{})
              # The reloaded file_config is authoritative — clear any pending
              # appearance accent draft (its value, if the appearance form was
              # submitted, is already persisted via the hidden input).
              |> assign(:appearance_accent_draft, nil)
              |> put_flash(:info, gettext("Configuration saved successfully."))

            # Update runtime scheduler when LLM or scheduler categories change
            socket =
              if category in [:scheduler, :llm] do
                if node == node() do
                  ConfigIO.update_runtime_from_file_config(file_config, socket)
                else
                  # Remote scheduler was already reloaded above
                  socket
                end
              else
                socket
              end

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, errors} ->
        category_errors = Enum.filter(errors, fn e -> List.first(e.key_path) == category end)

        {:noreply,
         socket
         |> assign(
           :per_category_errors,
           Map.put(socket.assigns.per_category_errors, category, category_errors)
         )
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  @impl true
  def handle_event("save_search", params, socket) do
    search_text = socket.assigns.search_text

    all_matching_schemas =
      socket.assigns.schemas_by_category
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.filter(&EvoDashWeb.SettingsComponents.schema_matches?(&1, search_text))

    config =
      ConfigIO.build_config_from_category_params(
        params,
        nil,
        all_matching_schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        node = socket.assigns.current_node

        case EvoDash.NodeContext.save_user_config(node, config) do
          :ok ->
            {file_config, socket} =
              if node == node() do
                # Local save — reload from disk
                fc = ConfigIO.load_file_config()
                {fc, assign(socket, :config_status, config_status())}
              else
                # Remote save — reload the remote scheduler config and re-fetch
                EvoDash.NodeContext.reload_remote_config(node)
                remote_cfg = EvoDash.NodeContext.get_remote_config(node)
                fc = remote_config_to_file_config(remote_cfg)

                {fc,
                 assign(
                   socket,
                   :config_status,
                   EvoDash.NodeContext.get_remote_config_status(node)
                 )}
              end

            config_file_exists = File.exists?(socket.assigns.config_path)

            socket =
              socket
              |> assign(:file_config, file_config)
              |> assign(:config_file_exists, config_file_exists)
              |> assign(:per_category_errors, %{})
              # The reloaded file_config is authoritative — clear any pending
              # appearance accent draft (its value, if the appearance form was
              # submitted, is already persisted via the hidden input).
              |> assign(:appearance_accent_draft, nil)
              |> put_flash(:info, gettext("Configuration saved successfully."))

            # Update runtime scheduler when LLM or scheduler keys change
            socket =
              if Enum.any?(
                   all_matching_schemas,
                   &(List.first(&1.key_path) in [:scheduler, :llm])
                 ) do
                if node == node() do
                  ConfigIO.update_runtime_from_file_config(file_config, socket)
                else
                  # Remote scheduler was already reloaded above
                  socket
                end
              else
                socket
              end

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, errors} ->
        # Group errors by category for display
        per_category_errors =
          Enum.reduce(errors, %{}, fn e, acc ->
            cat = List.first(e.key_path)
            Map.update(acc, cat, [e], fn existing -> existing ++ [e] end)
          end)

        {:noreply,
         socket
         |> assign(:per_category_errors, per_category_errors)
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  @impl true
  def handle_event("reset_key", params, socket) do
    {:noreply, socket} = SearchEvents.handle_reset_key(socket, params)
    # A successful reset persists + reloads file_config (authoritative) — clear
    # any pending appearance accent draft so the stale draft can never override
    # the reset value on re-render. Harmless on the invalid-key error branch.
    {:noreply, assign(socket, :appearance_accent_draft, nil)}
  end

  # ── Appearance category: accent-color swatch picker ───────────────────────
  #
  # `select_appearance_accent` updates ONLY the pending `:appearance_accent_draft`
  # assign (NOT file_config). The swatch buttons in SettingCard are type="button"
  # so the enclosing save_category form is never submitted and unsaved edits in
  # sibling cards of the same category are never wiped. The draft is threaded
  # into the accent card's value by category_section (via
  # `card_value/3` in components/settings_components.ex) so the active ring +
  # hidden input re-render immediately. The draft is cleared whenever file_config
  # is replaced by an authoritative load (mount, save/reset success, node-data
  # reload) so the card always reflects the persisted state after any reload.

  @impl true
  def handle_event("select_appearance_accent", %{"accent" => accent}, socket) do
    # Whitelist: accept only the ten palette names from
    # SettingCard.accent_palette/0 (untrusted client payload — never trust it
    # blindly, never String.to_atom on it).
    if EvoDashWeb.SettingsComponents.SettingCard.accent_name?(accent) do
      {:noreply, assign(socket, :appearance_accent_draft, accent)}
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown accent color."))}
    end
  end

  # ── :list_of_strings list editor (e.g. [sandbox] write_paths) ─────────────
  #
  # add_list_entry / remove_list_entry mutate the IN-MEMORY file_config only —
  # nothing is persisted until the enclosing save_category / save_search form
  # is submitted (the existing save path). The key_path arrives as a
  # dot-separated string and is whitelist-validated via parse_key_path (never
  # String.to_existing_atom on untrusted input); only :list_of_strings schemas
  # are accepted.

  @impl true
  def handle_event("add_list_entry", %{"key_path" => key_path_str}, socket) do
    key_path = ConfigIO.parse_key_path(key_path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    if is_nil(key_path) or is_nil(schema) or schema.type != :list_of_strings do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      entries = get_in(socket.assigns.file_config, key_path)
      entries = if is_list(entries), do: entries, else: []
      file_config = SettingsUtils.deep_put(socket.assigns.file_config, key_path, entries ++ [""])
      {:noreply, assign(socket, :file_config, file_config)}
    end
  end

  @impl true
  def handle_event(
        "remove_list_entry",
        %{"key_path" => key_path_str, "index" => index_str},
        socket
      ) do
    key_path = ConfigIO.parse_key_path(key_path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    if is_nil(key_path) or is_nil(schema) or schema.type != :list_of_strings do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      entries = get_in(socket.assigns.file_config, key_path)
      entries = if is_list(entries), do: entries, else: []

      # phx-value-* arrives as a string; Integer.parse (not a bare
      # String.to_integer) so a malformed index can never crash the LiveView.
      index =
        case Integer.parse(index_str) do
          {int, ""} -> int
          _ -> -1
        end

      if index >= 0 and index < length(entries) do
        file_config =
          SettingsUtils.deep_put(
            socket.assigns.file_config,
            key_path,
            List.delete_at(entries, index)
          )

        {:noreply, assign(socket, :file_config, file_config)}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("select_llm_provider", %{"provider_id" => id_str}, socket) do
    # Whitelist lookup: validate the client-supplied provider id against the
    # known LLMCatalog providers. Unknown value → nil → clear selection and
    # surface a friendly flash error instead of crashing.
    provider = Map.get(ConfigIO.provider_by_id_str(), id_str)

    if provider do
      provider_id = provider.id
      models = provider.models
      _variants = provider[:variants]

      socket =
        socket
        |> assign(:selected_provider_id, provider_id)
        |> assign(:selected_provider_models, models)
        |> assign(:selected_variant_id, nil)
        # Changing provider invalidates any previously chosen model.
        |> assign(:selected_model_string, nil)

      {:noreply, socket}
    else
      # Unknown provider id — keep existing state, show an error flash.
      {:noreply,
       socket
       |> assign(:selected_provider_id, nil)
       |> assign(:selected_provider_models, [])
       |> assign(:selected_variant_id, nil)
       |> assign(:selected_model_string, nil)
       |> put_flash(:error, gettext("Unknown provider."))}
    end
  end

  @impl true
  def handle_event("select_llm_variant", %{"variant_id" => variant_id_str}, socket) do
    # Whitelist lookup: validate the client-supplied variant id against the
    # variants of the currently selected provider. Unknown value (or no
    # provider selected) → nil → no selection change.
    variant_id =
      case socket.assigns.selected_provider_id do
        nil -> nil
        provider_atom -> Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
      end

    # Changing variant invalidates any previously chosen model.
    {:noreply,
     socket
     |> assign(:selected_variant_id, variant_id)
     |> assign(:selected_model_string, nil)}
  end

  @impl true
  def handle_event("select_llm_model", %{"model_string" => model_string}, socket) do
    # Whitelist validation: accept only model strings that match one of the
    # model shortcut buttons currently rendered for the selected provider
    # (same provider/variant resolution and render gate as the template).
    # Unknown or out-of-context values clear the selection instead of crashing.
    selected_model_string =
      if llm_model_string_known?(socket, model_string), do: model_string, else: nil

    {:noreply, assign(socket, :selected_model_string, selected_model_string)}
  end

  @impl true
  def handle_event("select_llm_model_shortcut", params, socket) do
    ModelProfileEvents.select_llm_model_shortcut(socket, params)
  end

  @impl true
  def handle_event("save_custom_model", params, socket) do
    ModelProfileEvents.save_custom_model(socket, params)
  end

  @impl true
  def handle_event("save_quick_setup", params, socket) do
    ModelProfileEvents.save_quick_setup(socket, params)
  end

  @impl true
  def handle_event("add_model_profile", params, socket) do
    ModelProfileEvents.add_model_profile(socket, params)
  end

  @impl true
  def handle_event("edit_model_profile", params, socket) do
    ModelProfileEvents.edit_model_profile(socket, params)
  end

  @impl true
  def handle_event("cancel_edit_model_profile", params, socket) do
    ModelProfileEvents.cancel_edit_model_profile(socket, params)
  end

  @impl true
  def handle_event("save_model_profile", params, socket) do
    ModelProfileEvents.save_model_profile(socket, params)
  end

  @impl true
  def handle_event("model_profile_form_change", params, socket) do
    # phx-change draft-tracking: stores the whole edit-form params so
    # add/remove_peak_hours_row (phx-click, which does NOT send the form data)
    # can re-render the form with every typed value preserved.
    ModelProfileEvents.model_profile_form_change(socket, params)
  end

  @impl true
  def handle_event("delete_model_profile", params, socket) do
    ModelProfileEvents.delete_model_profile(socket, params)
  end

  @impl true
  def handle_event("move_model_profile", params, socket) do
    ModelProfileEvents.move_model_profile(socket, params)
  end

  @impl true
  def handle_event("add_peak_hours_row", params, socket) do
    # Peak-hours row editor is only meaningful while a profile is being edited
    # (the rows live in the editing profile's in-memory peak_hours).
    if socket.assigns[:editing_profile_id] do
      ModelProfileEvents.add_peak_hours_row(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_peak_hours_row", %{"index" => _idx} = params, socket) do
    if socket.assigns[:editing_profile_id] do
      ModelProfileEvents.remove_peak_hours_row(socket, params)
    else
      {:noreply, socket}
    end
  end

  # ── Custom Agents category events (delegated to CustomAgentEvents) ──

  @impl true
  def handle_event("add_custom_agent", params, socket) do
    CustomAgentEvents.add_custom_agent(socket, params)
  end

  @impl true
  def handle_event("edit_custom_agent", params, socket) do
    CustomAgentEvents.edit_custom_agent(socket, params)
  end

  @impl true
  def handle_event("cancel_edit_custom_agent", params, socket) do
    CustomAgentEvents.cancel_edit_custom_agent(socket, params)
  end

  @impl true
  def handle_event("save_custom_agent", params, socket) do
    CustomAgentEvents.save_custom_agent(socket, params)
  end

  @impl true
  def handle_event("delete_custom_agent", params, socket) do
    CustomAgentEvents.delete_custom_agent(socket, params)
  end

  @impl true
  def handle_event("save_model_selection_script", params, socket) do
    CustomAgentEvents.save_model_selection_script(socket, params)
  end

  @impl true
  def handle_event("test_model_selection_script", params, socket) do
    CustomAgentEvents.test_model_selection_script(socket, params)
  end

  @impl true
  def handle_event(
        "save_api_key",
        %{"credential_key" => credential_key, "api_key" => api_key},
        socket
      ) do
    if String.trim(api_key) == "" do
      {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
    else
      node = socket.assigns.current_node

      case EvoDash.NodeContext.save_credentials(node, %{credential_key => String.trim(api_key)}) do
        :ok ->
          # For remote nodes, reload the remote config so the new key takes
          # effect on the remote scheduler immediately. Re-fetch credentials
          # from the appropriate node.
          if node != node() do
            EvoDash.NodeContext.reload_remote_config(node)
          end

          config_status =
            if node == node() do
              config_status()
            else
              EvoDash.NodeContext.get_remote_config_status(node)
            end

          credentials =
            case EvoDash.NodeContext.call_remote(node, EvoGit.Config, :credentials, []) do
              {:ok, creds} when is_map(creds) -> creds
              _ -> socket.assigns.credentials
            end

          {:noreply,
           socket
           |> assign(:config_status, config_status)
           |> assign(:credentials, credentials)
           |> put_flash(:info, gettext("API key saved successfully."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to save API key: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  @impl true
  def handle_event("test_llm", params, socket) do
    # The connection test button renders outside the disabled form, so it
    # remains clickable on a remote node. When viewing a remote node, route
    # the test through the remote node's LLM instead of testing the local LLM
    # (which would return a misleading result).
    profile_id = params["profile_id"]
    models = get_in(socket.assigns.file_config, [:llm, :models]) || []

    profile = Enum.find(models, fn p -> ModelProfileHelpers.profile_id(p) == profile_id end)

    # Extract the raw model value as-is (map spec with base_url, or binary string).
    model = if profile, do: Map.get(profile, :model) || Map.get(profile, "model")

    if model do
      # Collect profile-specific generation params to pass alongside the model spec.
      gen_opts =
        []
        |> ModelProfileEvents.maybe_put_gen_opt(:temperature, profile)
        |> ModelProfileEvents.maybe_put_gen_opt(:max_tokens, profile)
        |> ModelProfileEvents.maybe_put_gen_opt(:top_p, profile)
        |> ModelProfileEvents.maybe_put_gen_opt(:top_k, profile)
        |> ModelProfileEvents.maybe_put_gen_opt(:frequency_penalty, profile)
        |> ModelProfileEvents.maybe_put_gen_opt(:presence_penalty, profile)

      parent = self()
      remote? = socket.assigns.current_node != node()
      node = socket.assigns.current_node

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        result =
          if remote? do
            EvoGit.RemoteNode.llm_test(node, model, gen_opts)
          else
            EvoGit.SystemCheck.llm_test(model, gen_opts)
          end

        send(parent, {:llm_test_result, result})
      end)

      {:noreply, assign(socket, :llm_test_status, :testing)}
    else
      {:noreply, put_flash(socket, :error, gettext("Selected profile has no model configured."))}
    end
  end

  @impl true
  def handle_event("select_test_profile", %{"profile_id" => profile_id}, socket) do
    {:noreply, assign(socket, :test_profile_id, profile_id)}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Remote Connections event handlers
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_remote_target", _params, socket) do
    {:noreply,
     assign(socket,
       remote_form_target: %{
         dist_port: 9000,
         remote_path: "/tmp/genesis_remote",
         platform: nil
       },
       remote_show_advanced: false
     )}
  end

  @impl true
  def handle_event("cancel_edit_remote", _params, socket) do
    {:noreply, assign(socket, remote_form_target: nil, remote_show_advanced: false)}
  end

  @impl true
  def handle_event("edit_remote_target", %{"id" => id}, socket) do
    form_target =
      case EvoDash.NodeContext.get_target(id) do
        {:ok, target} ->
          target
          |> Map.put_new(:dist_port, 9000)
          |> Map.put_new(:remote_path, "/tmp/genesis_remote")

        {:error, :not_found} ->
          nil
      end

    {:noreply, assign(socket, remote_form_target: form_target, remote_show_advanced: false)}
  end

  @impl true
  def handle_event("toggle_remote_advanced", _params, socket) do
    {:noreply, update(socket, :remote_show_advanced, &(!&1))}
  end

  @impl true
  def handle_event("save_remote_target", params, socket) do
    target = build_remote_target_from_params(params)

    case EvoDash.NodeContext.save_target(target) do
      {:ok, _saved} ->
        socket =
          socket
          |> assign(:remote_form_target, nil)
          |> put_flash(:info, gettext("Connection saved."))
          |> reload_remote_targets()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to save: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("delete_remote_target", %{"id" => id}, socket) do
    case EvoDash.NodeContext.delete_target(id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Connection deleted."))
          |> reload_remote_targets()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Connection not found."))}
    end
  end

  @impl true
  def handle_event("bootstrap_remote_target", %{"id" => id}, socket) do
    # Double-click guard — already bootstrapping
    if get_in(socket.assigns.bootstrap_progress, [id, :active]) do
      {:noreply, socket}
    else
      # Immediately show the progress bar so the user sees feedback right away
      bootstrap_progress =
        Map.put(socket.assigns.bootstrap_progress, id, %{
          stage: nil,
          active: true,
          status: :active
        })

      socket = assign(socket, :bootstrap_progress, bootstrap_progress)

      lv_pid = self()

      Task.start(fn ->
        result = EvoDash.NodeContext.bootstrap(id)
        send(lv_pid, {:bootstrap_complete, id, result})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_bootstrap_restart", %{"target_id" => id}, socket) do
    # Permission granted — close the dialog and re-bootstrap with
    # on_running: :restart (the core stops the running daemon — broadcasting
    # :stopping_daemon, mapped to step 3 "Configuring" — then bootstraps fresh).
    socket = assign(socket, :bootstrap_restart_confirm, nil)

    bootstrap_progress =
      Map.put(socket.assigns.bootstrap_progress, id, %{stage: nil, active: true, status: :active})

    socket = assign(socket, :bootstrap_progress, bootstrap_progress)

    lv_pid = self()

    Task.start(fn ->
      result = EvoDash.NodeContext.bootstrap(id, on_running: :restart)
      send(lv_pid, {:bootstrap_complete, id, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_bootstrap_restart", %{"target_id" => _id}, socket) do
    {:noreply, assign(socket, :bootstrap_restart_confirm, nil)}
  end

  @impl true
  def handle_event("connect_remote_target", %{"id" => id}, socket) do
    result = EvoDash.NodeContext.connect(id)

    socket =
      socket
      |> reload_remote_statuses()
      |> flash_remote_lifecycle_result(result, gettext("Connect"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("disconnect_remote_target", %{"id" => id}, socket) do
    result = EvoDash.NodeContext.disconnect(id)

    socket =
      socket
      |> reload_remote_statuses()
      |> flash_remote_lifecycle_result(result, gettext("Disconnect"))

    {:noreply, socket}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  @doc false
  def persist_file_config(file_config, socket, success_msg) do
    # Always update in-memory state so the UI reflects the change immediately
    socket = assign(socket, :file_config, file_config)
    node = socket.assigns.current_node

    case EvoDash.NodeContext.save_user_config(node, file_config) do
      :ok ->
        if node == node() do
          # Local save — reload from disk and update the local scheduler
          file_config = ConfigIO.load_file_config()
          config_status = config_status()
          config_file_exists = File.exists?(socket.assigns.config_path)

          socket =
            socket
            |> assign(:file_config, file_config)
            |> assign(:config_status, config_status)
            |> assign(:config_file_exists, config_file_exists)
            |> assign(:per_category_errors, %{})
            |> put_flash(:info, success_msg)

          {:noreply, ConfigIO.update_runtime_from_file_config(file_config, socket)}
        else
          # Remote save — reload the remote scheduler config and re-fetch the
          # FULL resolved config (same shape as the local path), so the editor
          # keeps showing every section after a save.
          EvoDash.NodeContext.reload_remote_config(node)
          config_file_exists = File.exists?(socket.assigns.config_path)

          socket =
            case EvoDash.NodeContext.get_resolved_config(node) do
              {:ok, resolved} ->
                socket
                |> assign(:file_config, resolved)
                |> assign(:remote_config_error, nil)

              {:error, reason} ->
                # The save itself succeeded (save_user_config returned :ok) —
                # only the re-fetch failed. Keep the just-saved in-memory
                # config and surface the fetch failure so the UI does not
                # silently fall back to a stale/empty config.
                assign(
                  socket,
                  :remote_config_error,
                  gettext(
                    "Could not load configuration from the remote node: %{reason} — the node may be unreachable.",
                    reason: inspect(reason)
                  )
                )
            end

          {:noreply,
           socket
           |> assign(:config_status, EvoDash.NodeContext.get_remote_config_status(node))
           |> assign(:config_file_exists, config_file_exists)
           |> assign(:per_category_errors, %{})
           |> put_flash(:info, success_msg)}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware custom agents loading
  # ───────────────────────────────────────────────────────────────────────────

  # Loads the custom-agents data (agent definitions, model-selection script,
  # script compile status) for the currently-viewed node into the socket.
  #
  # `EvoDash.NodeContext.list_custom_agents/1` degrades to an empty result on
  # RPC failure, so an unreachable remote node reads as "no custom agents"
  # instead of crashing. Public because CustomAgentEvents reloads through it
  # after every mutation.
  @doc false
  def load_custom_agents_data(socket) do
    node = socket.assigns.current_node

    {:ok, %{agents: agents, model_selection_script: script, script_status: script_status}} =
      EvoDash.NodeContext.list_custom_agents(node)

    assign(socket,
      custom_agents: agents,
      model_selection_script: script || "",
      script_status: script_status,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: []
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware config loading
  # ───────────────────────────────────────────────────────────────────────────

  # The sandbox backend banner to show for the currently-viewed node.
  #
  # Local node: `scheduler_config[:sandbox_backend]` is accurate (it reflects
  # the actual binary availability on this VM). Remote node: `scheduler_config`
  # is loaded from the LOCAL scheduler only (`ConfigIO.load_scheduler_config()`
  # in mount/1), so it would show the wrong platform's banner — derive the
  # backend from the remote node's detected OS instead.
  defp sandbox_backend(assigns) do
    if assigns.current_node in [nil, node()] do
      assigns.scheduler_config[:sandbox_backend]
    else
      EvoDashWeb.PlatformInfo.sandbox_backend_for(assigns.platform_os)
    end
  end

  # Applies the results of the async node-data load (see
  # EvoDashWeb.SettingsLive.NodeData) to the socket: the platform assigns
  # (platform_os + the platform-filtered schemas map), the re-resolved active
  # category, and the config/agents assigns. Mirrors the assigns that the
  # pre-async `handle_params/3` + `load_custom_agents_data/1` produced
  # synchronously. A `:remote_config_error` reason is gettext'd into the same
  # user-facing message the old synchronous path showed, so a remote fetch
  # failure still renders the error banner instead of a misleading "No LLM
  # Model Configured" box.
  defp apply_node_data_results(socket, category_param, results) do
    socket =
      socket
      |> assign(:platform_os, results.platform_os)
      |> assign(:schemas_by_category, results.filtered_schemas_by_category)
      |> assign(:file_config, results.file_config)
      |> assign(:config_status, results.config_status)
      |> assign(:remote_config, false)
      # Node-data loads replace file_config with an authoritative snapshot
      # (navigation + node switches) — clear any pending appearance accent draft
      # so the accent card always reflects the loaded config.
      |> assign(:appearance_accent_draft, nil)

    socket =
      case results.remote_config_error do
        nil ->
          assign(socket, :remote_config_error, nil)

        reason ->
          assign(
            socket,
            :remote_config_error,
            gettext(
              "Could not load configuration from the remote node: %{reason} — the node may be unreachable.",
              reason: inspect(reason)
            )
          )
      end

    # Re-resolve the active category against the FILTERED schemas map — the
    # category the shell seeded against the UNFILTERED map may now be hidden
    # (e.g. `?category=sandbox` on Windows/unknown, or `:nix` when the nix
    # category is hidden).
    category = resolve_category(category_param, socket)

    socket =
      if category != socket.assigns.active_category do
        assign(socket, :active_category, category)
      else
        socket
      end

    assign(socket,
      custom_agents: results.custom_agents.agents,
      model_selection_script: results.custom_agents.model_selection_script,
      script_status: results.custom_agents.script_status,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: []
    )
  end

  # Re-resolves the active category from the captured `?category=` param
  # against the platform-FILTERED schemas map (mirrors the pre-async
  # handle_params logic exactly): whitelist lookup via
  # ConfigIO.category_str_to_atom (with the "remote_connections"/"agents"
  # pseudo-categories special-cased) → fallback to the current active_category
  # → `:llm` when the resolved category is missing from the filtered map
  # (preserves the `:sandbox`-on-Windows fallback and the hidden-nix fallback
  # exactly as before).
  defp resolve_category(category_param, socket) do
    category_str_to_atom = ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category)

    category =
      case category_param do
        "remote_connections" -> :remote_connections
        "agents" -> :agents
        cat when is_binary(cat) -> Map.get(category_str_to_atom, cat)
        _ -> nil
      end

    category = category || socket.assigns.active_category

    if not Map.has_key?(socket.assigns.schemas_by_category, category) do
      :llm
    else
      category
    end
  end

  # Maps the flat scheduler config map (from get_remote_config/1) into the nested
  # %{scheduler: ..., llm: ...} structure the schema-driven setting cards expect.
  # Only the keys present in the scheduler config are populated; the rest fall
  # back to schema defaults when rendered. This is best-effort display data for
  # the remote config view.
  #
  # LEGACY — the navigation load path now fetches the FULL resolved config via
  # `EvoDash.NodeContext.get_resolved_config/1` (which includes `llm.models`,
  # tools, evolution, truncation, nix, ...) and so do the persist paths. This
  # converter remains ONLY for the remaining remote re-fetch callers that still
  # use the flat scheduler-map shape: `save_category`/`save_search`
  # (settings_live.ex) and `SearchEvents.handle_reset_key/2`.
  def remote_config_to_file_config(remote_cfg) when is_map(remote_cfg) do
    scheduler =
      %{}
      |> maybe_put(:default_llm_max_concurrency, remote_cfg[:default_llm_max_concurrency])
      |> maybe_put(:max_tool_concurrency, remote_cfg[:max_tool_concurrency])
      |> maybe_put(:agent_max_retries, remote_cfg[:agent_max_retries])
      |> maybe_put(:max_agent_depth, remote_cfg[:max_agent_depth])
      |> maybe_put(:max_retries, remote_cfg[:max_retries])
      |> maybe_put(:max_turns, remote_cfg[:max_turns])
      |> maybe_put(:max_turns_root, remote_cfg[:max_turns_root])

    llm =
      %{}
      |> maybe_put(:model, remote_cfg[:llm_model])

    # Model profiles come as a list of maps; surface them for display.
    llm =
      case remote_cfg[:model_profiles] do
        nil -> llm
        [] -> llm
        profiles -> Map.put(llm, :models, profiles)
      end

    %{}
    |> Map.put(:scheduler, scheduler)
    |> Map.put(:llm, llm)
  end

  def remote_config_to_file_config(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Remote Connections
  # ───────────────────────────────────────────────────────────────────────────

  defp reload_remote_targets(socket) do
    assign(socket, :remote_targets, EvoDash.NodeContext.list_targets())
  end

  defp reload_remote_statuses(socket) do
    assign(socket, :remote_statuses, EvoDash.NodeContext.connection_status())
  end

  # ── Bootstrap progress helpers ───────────────────────────────────────────────
  #
  # `@bootstrap_progress[target_id]` entry shape:
  #   %{stage: nil | 0..4, active: boolean, status: :active | :success | :error,
  #     error: String.t() | nil}
  # `:stage` is the MAPPED 0-4 step index (see bootstrap_stage_idx/1), NOT the
  # raw core atom — the template uses it directly (do not re-map). `:active`
  # mirrors `status == :active` and keeps the double-click guard + template
  # condition working. `:error` is set only when status == :error.
  #
  # 5-step mapping (daisyUI steps in the Settings target card):
  #   step 0 "Probing / preparing" ← :probing_platform, :uploading, :detecting_os
  #   step 1 "Downloading"         ← :downloading, :downloading_locally
  #   step 2 "Extracting"          ← :extracting
  #   step 3 "Configuring"         ← :setting_permissions, :copying_config,
  #                                   :generating_cookie, :patching_binaries,
  #                                   :stopping_daemon
  #   step 4 "Starting daemon"     ← :starting_daemon
  # Unknown atoms → -1 (no step highlighted).

  defp bootstrap_stage_idx(stage) do
    case stage do
      :probing_platform -> 0
      :uploading -> 0
      :detecting_os -> 0
      :downloading -> 1
      :downloading_locally -> 1
      :extracting -> 2
      :setting_permissions -> 3
      :copying_config -> 3
      :generating_cookie -> 3
      :patching_binaries -> 3
      :stopping_daemon -> 3
      :starting_daemon -> 4
      _ -> -1
    end
  end

  # Step <li> classes: completed steps are primary-highlighted; in the error
  # final state the step where the failure occurred is shown as step-error;
  # the success final state colors all five steps green. A nil stage (freshly
  # started bootstrap, or an error before any stage was broadcast) leaves all
  # steps unhighlighted.
  defp bootstrap_step_class(stage_idx, step_index, status) do
    cond do
      status == :success -> ["step", "step-primary"]
      status == :error and stage_idx == step_index -> ["step", "step-error"]
      is_integer(stage_idx) and stage_idx >= step_index -> ["step", "step-primary"]
      true -> ["step"]
    end
  end

  # Progress entry transitions driven by {:remote_connection_status, ...}
  # broadcasts. A :bootstrapping stage broadcast always advances the entry to
  # :active. While the entry is :active, a phase that ended the bootstrap is
  # FROZEN (:error keeps the last-known stage + message; any other end phase —
  # :connected/:disconnected/... — freezes :success). Every other broadcast
  # (different target, plain connect/disconnect, or a target with a frozen
  # :success/:error entry) PRESERVES the entry — the frozen bar must survive
  # unrelated traffic. The definitive terminal signals still come from
  # {:bootstrap_complete, id, result} (the Task result), which re-freezes.
  defp update_bootstrap_progress(progress, target_id, status) do
    case status do
      %{phase: :bootstrapping, bootstrap_stage: stage} when not is_nil(stage) ->
        Map.put(progress, target_id, %{
          stage: bootstrap_stage_idx(stage),
          active: true,
          status: :active
        })

      status when is_map(status) ->
        case Map.get(progress, target_id) do
          %{status: :active} = entry ->
            cond do
              bootstrap_error?(status) ->
                Map.put(progress, target_id, %{
                  stage: entry.stage,
                  active: false,
                  status: :error,
                  error: bootstrap_error_message(status)
                })

              bootstrap_ended?(status) ->
                Map.put(progress, target_id, %{stage: 4, active: false, status: :success})

              true ->
                progress
            end

          _frozen_or_absent ->
            progress
        end

      _non_map ->
        progress
    end
  end

  # An error phase, or any map carrying a non-nil last_error, ends the
  # bootstrap in failure.
  defp bootstrap_error?(%{phase: :error}), do: true

  defp bootstrap_error?(status) when is_map(status) do
    case Map.get(status, :last_error) do
      nil -> false
      _ -> true
    end
  end

  defp bootstrap_error_message(status) do
    case Map.get(status, :last_error) do
      nil -> nil
      msg when is_binary(msg) -> msg
      msg -> inspect(msg)
    end
  end

  # Any phase other than :bootstrapping/:error while the entry is active means
  # the bootstrap ended. The core sets phase: :disconnected with
  # bootstrap_stage: nil right after a successful bootstrap, so :disconnected
  # MUST count as ended here.
  defp bootstrap_ended?(%{phase: phase}) when phase not in [:bootstrapping, :error],
    do: true

  defp bootstrap_ended?(_), do: false

  # Human-readable error text for a frozen :error bar, derived from a
  # {:bootstrap_complete, id, {:error, reason}} result.
  defp bootstrap_error_text(reason) do
    cond do
      is_binary(reason) -> reason
      is_map(reason) and Map.has_key?(reason, :last_error) -> bootstrap_error_message(reason)
      true -> inspect(reason)
    end
  end

  # Freeze the target's progress entry in a terminal state (keeps the last
  # known stage; success always freezes at step 4).
  defp freeze_bootstrap_progress(socket, id, status, error \\ nil) do
    progress = socket.assigns.bootstrap_progress
    last_stage = Map.get(Map.get(progress, id, %{}), :stage)

    frozen =
      case status do
        :success -> %{stage: 4, active: false, status: :success}
        :error -> %{stage: last_stage, active: false, status: :error, error: error}
      end

    assign(socket, :bootstrap_progress, Map.put(progress, id, frozen))
  end

  defp clear_bootstrap_progress(socket, id) do
    assign(socket, :bootstrap_progress, Map.delete(socket.assigns.bootstrap_progress, id))
  end

  defp build_remote_target_from_params(params) do
    id = params["_id"]
    id = if id && id != "", do: id, else: generate_remote_id(params["name"])

    %{
      id: id,
      name: params["name"] || "",
      ssh_target: params["ssh_target"] || "",
      local_binary_path: params["local_binary_path"] || "",
      platform: params["platform"] || "",
      dist_port: parse_remote_port(params["dist_port"]),
      remote_path: params["remote_path"] || "/tmp/genesis_remote"
    }
  end

  defp parse_remote_port(nil), do: nil
  defp parse_remote_port(""), do: nil

  defp parse_remote_port(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_remote_port(num) when is_integer(num), do: num

  defp generate_remote_id(nil), do: generate_remote_id("")

  defp generate_remote_id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      "target-#{System.system_time(:second)}"
    else
      slug
    end
  end

  defp flash_remote_lifecycle_result(socket, result, action) do
    case result do
      {:error, :remote_connection_unavailable} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} unavailable — the remote connection subsystem is not running.",
            action: action
          )
        )

      :ok ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:ok, _} ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:error, reason} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
        )

      _other ->
        put_flash(socket, :info, gettext("%{action} completed.", action: action))
    end
  end

  # Phase → color mapping is owned by `EvoDashWeb.Helpers.connection_status_dot_class/1`;
  # this wrapper resolves the target's phase from the statuses map and keeps the
  # pulse animation for connecting phases (shape classes live at the call site).
  defp remote_target_dot_color(target_id, statuses) do
    phase = remote_target_phase(target_id, statuses)
    pulse = if phase in [:connecting, :disconnecting], do: " animate-pulse", else: ""
    connection_status_dot_class(phase) <> pulse
  end

  defp remote_target_phase(target_id, statuses) do
    statuses |> Map.get(target_id, %{}) |> Map.get(:phase, :disconnected)
  end

  defp remote_connected?(target_id, statuses) do
    remote_target_phase(target_id, statuses) == :connected
  end

  # Composes the `badge badge-sm` base with the shared phase modifier
  # (`EvoDashWeb.Helpers.connection_status_badge_class/1` owns the mapping).
  defp remote_status_badge_class(target_id, statuses) do
    "badge badge-sm " <> connection_status_badge_class(remote_target_phase(target_id, statuses))
  end

  defp remote_status_label(target_id, statuses) do
    case remote_target_phase(target_id, statuses) do
      :connected -> gettext("Connected")
      :connecting -> gettext("Connecting...")
      :disconnecting -> gettext("Disconnecting...")
      :error -> gettext("Error")
      :disconnected -> gettext("Disconnected")
      _ -> gettext("Unknown")
    end
  end

  # Whitelist validation for the select_llm_model event: the model_string must
  # match a model shortcut button that is actually rendered for the currently
  # selected provider (same provider/variant resolution and render gate as the
  # template in settings_components.ex). Malformed or out-of-context values
  # return false so the handler clears the selection instead of crashing.
  defp llm_model_string_known?(socket, model_string) when is_binary(model_string) do
    provider_id = socket.assigns.selected_provider_id
    variant_id = socket.assigns.selected_variant_id
    models = socket.assigns.selected_provider_models

    provider = Enum.find(EvoGit.Config.LLMCatalog.providers(), &(&1.id == provider_id))
    variants = provider && provider[:variants]
    has_variants = is_list(variants) and length(variants) > 0
    custom_model = provider && provider[:custom_model] == true

    # Model shortcut buttons only render when no variants are needed (or a
    # variant is selected) and the provider is not a custom-model provider.
    provider != nil and (not has_variants or variant_id != nil) and not custom_model and
      Enum.any?(models, fn model ->
        resolved_atom =
          EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_id, variant_id)

        "#{resolved_atom}:#{model.id}" == model_string
      end)
  end

  defp llm_model_string_known?(_socket, _model_string), do: false
end
