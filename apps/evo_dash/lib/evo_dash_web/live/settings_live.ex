defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).
  """
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema
  alias EvoDash.SettingsUtils
  alias EvoDashWeb.SettingsLive.AuthStatus
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.CustomAgentEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.NodeData
  alias EvoDashWeb.SettingsLive.SearchEvents

  # This deliberately long page keeps the Settings shell/HEEx and node-aware
  # transport boundary together; detached editors, parsing and loaders live in
  # settings_live/. Canonical UI event aliases belong here, not in those helpers.

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
        <div class="flex flex-col md:h-full">
          <%!-- ConfigSave runs local and remote writes outside the LiveView.
           Keep feedback visible until the owned settings_config_saved result
           settles, rather than relying on the Save button's pending state. --%>
          <%= if @config_saving do %>
            <div
              id="settings-config-saving"
              class="mb-4 shrink-0 rounded-lg border border-base-300 bg-base-100 p-3 flex items-center gap-3"
            >
              <span class="loading loading-spinner loading-sm text-primary-standalone"></span>
              <span class="text-sm font-medium text-base-content/80">
                {gettext("Saving configuration…")}
              </span>
            </div>
          <% end %>

          <%!-- Config Status Warning --%>
          <%= if @config_status && not @config_status.ok? do %>
            <div class="mb-4 shrink-0 rounded-lg border border-warning/30 bg-warning/5 p-3 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
              <div>
                <h3 class="font-bold text-sm text-warning mb-2">
                  {gettext("Missing Configuration")}
                </h3>
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
            <div class="mb-4 shrink-0 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
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
          <%= if @remote_config_error == nil and ConfigIO.model_selections(@file_config) == [] do %>
            <div class="mb-4 shrink-0 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
              <div>
                <h3 class="font-bold text-sm text-error mb-2">
                  {gettext("No LLM Model Configured")}
                </h3>
                <p class="text-sm font-medium text-error/80 mb-3 leading-relaxed max-w-3xl">
                  {gettext(
                    "Agents cannot run until you set a model. Go to the LLM category and fill in the Model field."
                  )}
                </p>
                <div class="flex items-center gap-3 flex-wrap">
                  <span class="text-xs font-bold uppercase tracking-wider text-base-content/70">{gettext(
                    "Example model names:"
                  )}</span>
                  <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">anthropic:claude-opus-5-5</span>
                  <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">openai:gpt-5.6-terra</span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Settings card: two-column sidebar + content layout.

             md+ INDEPENDENT-SCROLL HEIGHT CHAIN: `#main-content` (layouts.ex)
             is `flex-1 min-h-0` inside the `h-dvh` app shell, so this
             wrapper's `md:h-full` is bounded to viewport-minus-chrome; the
             two-column row below is `md:flex-1 md:min-h-0`. The sidebar
             (sidebar.ex — `md:h-full` bounded column whose `flex-1
             overflow-y-auto min-h-0` nav scrolls on its own) and each
             content column are bounded by that row and scroll independently
             of the outer page. TWO height rules govern the content columns
             (full detail: `components/CONTEXT.md` → "Settings two-column
             layout"):

             (1) A content-column root must NEVER carry `h-full` — the row
             has no definite `height` property (it is flex-sized), so a
             percentage `h-full` resolves to auto → the column grows to its
             content → the whole page inflates past the viewport → the BODY
             scrolls and the two panes scroll LINKED instead of
             independently. Content columns are sized by `flex-1` ALONE
             (+ `overflow-y-auto` on the column or its inner scroll div).

             (2) Every main-axis (column-direction) NON-scroll flex item
             between the bounded column and the inner scroll container MUST
             carry `min-h-0` — a non-scroll flex item defaults to
             `min-height: auto` (the content-based automatic minimum, which
             INCLUDES the overflow content of a nested `overflow-y-auto`
             body), so it cannot shrink below its content and the inner
             scroll body never engages; content spills to `#main-scroll`
             and the panes scroll LINKED.

             Every category column now has ONE unified shape
             (components/settings_components.ex `category_section/1`): a
             root `<div class="flex-1 flex flex-col min-w-0 min-h-0
             bg-base-100" id="category-<cat>">` → `.section_header` top
             sibling → a scroll body `<div class="flex-1 overflow-y-auto
             px-8 py-8 relative">` that owns the pane scroll and holds all
             config content → ONE minimal pinned bottom-right save bar
             (`.save_bar`: `shrink-0 sticky bottom-0 z-10` container,
             `btn btn-primary rounded-md min-w-32 font-bold` +
             document-check icon) as a NON-scrolling flex sibling of that
             scroll body. How the rules land on the actual shapes:

             The GENERIC categories' `save_category` `<.form>` (class
             `flex-1 flex flex-col min-w-0 min-h-0 relative`, id
             `settings-form-<cat>`) wraps the scroll body AND a nested
             `<.save_bar>` — the form is the main-axis non-scroll flex item
             between the `category_section` root and the inner scroll body,
             so BOTH the form and the section root carry `min-h-0`. The
             `:llm` category instead keeps its flat `<.form
             id="settings-form-llm">` (hidden category input + flat setting
             cards such as compression_threshold_tokens) INSIDE the scroll
             body (its old in-form save bar is gone); its pinned `<.save_bar
             form={"settings-form-#{@category}"} ...>` is a direct child of
             the column root AFTER the scroll body — OUTSIDE the form,
             submitting it via the HTML `form` association attribute (safe
             because LiveView binds window-level submit listeners on the
             form target). LLM's scroll body is still a DIRECT child of the
             column root, so it needs no intermediate `min-h-0` (a scroll
             container's own automatic min size is 0) — that part of the
             old reasoning stays true. search (the `<.form
             id="settings-form-search">`, whose class string
             `flex-1 flex flex-col min-w-0 overflow-y-auto relative` is
             TEST-PINNED) and the `:remote_connections`/`:agents`
             pseudo-category shells (both `<div class="flex-1 flex flex-col
             min-w-0 overflow-y-auto">`) work because the column/form ITSELF
             is the scroll container — no intermediate `min-h-0` needed
             there, and they deliberately carry NO category-wide save bar
             (their actions are per-item inline form actions).

             The `.section_header` (`sticky top-0`) is the top non-scroll
             sibling: in the self-scrolling search/
             `:remote_connections`/`:agents` columns it sticks within that
             column's own scroll, and in the category_section shape it never
             scrolls away because the inner scroll body scrolls beneath it.
             The save bar's own `sticky bottom-0 z-10` is load-bearing only
             where the bar sits INSIDE a scrolling container (the
             SearchResults bar lives inside `settings-form-search`); it is
             inert-but-harmless elsewhere. Below md the row stacks naturally
             and the whole page scrolls via `#main-scroll`. Warning banners
             above are direct children of the wrapper (shrink-0 so they
             never squish). Note: after editing Tailwind classes here,
             rebuild assets with `mix tailwind evo_dash` (dev) or
             `mix assets.deploy` (prod) — the CSS build
             (`priv/static/assets/css/`) is gitignored, so a stale bundle
             silently no-ops new utility classes. --%>
          <%!-- Two-column sidebar + content layout --%>
          <div class="flex flex-col md:flex-row md:flex-1 md:min-h-0 bg-base-100">
            <%!-- Sidebar --%>
            <EvoDashWeb.SettingsComponents.settings_sidebar
              categories={@schemas_by_category}
              active_category={@active_category}
              search_text={@search_text}
              config_path={@config_path}
              config_file_exists={@config_file_exists}
            />

            <%!-- Content area --%>
            <%= if @search_text != "" do %>
              <.form
                for={%{}}
                phx-submit="save_search"
                class="flex-1 flex flex-col min-w-0 overflow-y-auto relative"
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
                   for the special :remote_connections pseudo-category. Carries
                   `overflow-y-auto` (md+ bounded column) so the sticky header
                   below sticks within this column's own scroll. --%>
                <div class="flex-1 flex flex-col min-w-0 overflow-y-auto">
                  <EvoDashWeb.SettingsComponents.SectionHeader.section_header
                    icon="hero-globe-alt"
                    title={gettext("Remote Connections")}
                    description={gettext("Manage SSH connections to remote Genesis daemons.")}
                  />

                  <div class="px-8 py-8 space-y-5">
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
                                      class="btn btn-xs btn-ghost gap-1"
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
                                      class="btn btn-xs btn-ghost gap-1"
                                      phx-click="bootstrap_remote_target"
                                      phx-value-id={target.id}
                                    >
                                      <.icon name="hero-rocket-launch" class="size-3.5" />
                                      {gettext("Install")}
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
                                {gettext("Install")}
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
                                  placeholder="_build/prod/rel/genesis_server.tar.xz"
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
                    <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
                      <div class="flex items-center gap-3 mb-4">
                        <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
                        <h3 class="text-lg font-bold">
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
              <% else %>
                <%!-- Custom Agents UI — same design as category_section but for
                   the special :agents pseudo-category. Both editors contain
                   their own <form> elements (save_custom_agent,
                   save_model_selection_script), so they are NOT wrapped in a
                   save_category form (nested <form> elements are invalid
                   HTML). --%>
                <%= if @active_category == :agents do %>
                  <div class="flex-1 flex flex-col min-w-0 overflow-y-auto">
                    <EvoDashWeb.SettingsComponents.SectionHeader.section_header
                      icon="hero-user-group"
                      title={gettext("Agents")}
                      description={
                        gettext(
                          "Create custom agents and configure the per-agent model selection script."
                        )
                      }
                    />

                    <div class="px-8 py-8 space-y-5">
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
                        model_profiles={custom_agent_model_choices(@file_config)}
                        custom_tool_names={
                          EvoDashWeb.SettingsComponents.CustomToolsPanel.custom_tool_names(
                            @custom_tools_status
                          )
                        }
                      />

                      <EvoDashWeb.SettingsComponents.CustomToolsPanel.custom_tools_panel
                        status={@custom_tools_status}
                        loading={@custom_tools_loading}
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
                    provider_profiles={Schema.provider_profiles(@file_config)}
                    model_selections={ConfigIO.model_selections(@file_config)}
                    editing_profile_id={@editing_profile_id}
                    profile_form_draft={@profile_form_draft}
                    provider_profile_errors={@profile_form_errors}
                    profile_advanced_open={@profile_advanced_open}
                    appearance_accent_draft={@appearance_accent_draft}
                    test_profile_id={@test_profile_id}
                    credentials={@credentials}
                    auth_statuses={@auth_statuses}
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

    config_status = safe_config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = ConfigIO.load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    selections = ConfigIO.model_selections(file_config)

    test_profile_id =
      case selections do
        [selection | _] -> EvoDashWeb.SettingsComponents.model_selection_value(selection)
        [] -> nil
      end

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
        # ConfigSave owns these across scope changes, including live workers.
        config_saving: false,
        config_save_request: nil,
        config_save_owner: nil,
        config_load_wait_ref: nil,
        settings_load_seq: 0,
        settings_scope: {nil, node()},
        settings_connection_phase: nil,
        config_loaded_scope: {nil, node()},
        config_status_token: nil,
        credentials: EvoGit.Config.credentials(),
        llm_providers: EvoGit.Config.LLMCatalog.providers(),
        selected_provider_id: nil,
        selected_provider_models: [],
        selected_variant_id: nil,
        selected_model_string: nil,
        llm_test_status: :idle,
        llm_test_seq: 0,
        # Mount's config is local; a remote test waits for its own async snapshot.
        test_config_scope: {nil, node()},
        # Per-profile OAuth/subscription credential status (see
        # EvoDashWeb.SettingsLive.AuthStatus): `%{profile_id => %{state:, expires:,
        # account_id:, login_instructions:, oauth_file:}}`. Loaded
        # asynchronously for the viewed node and stale-guarded by node + seq.
        auth_statuses: %{},
        auth_status_seq: 0,
        editing_profile_id: nil,
        profile_form_draft: nil,
        profile_form_errors: %{},
        profile_save_token: nil,
        # User-authoritative open state of the profile edit form's "Advanced
        # settings" disclosure (nil = follow the auto rule). Reset to nil by
        # every edit-session identity change in ModelProfileEvents.
        profile_advanced_open: nil,
        # Pending accent-color selection for the :appearance category (nil = no
        # pending draft). Set by `select_appearance_accent`; cleared whenever
        # file_config is replaced by an authoritative load (see
        # apply_node_data_results, save paths, reset_key).
        appearance_accent_draft: nil,
        test_profile_id: test_profile_id,
        # Custom-tools panel state (tool modules discovered in the node's
        # `<config_dir>/tools/`). Seeded from a LOCAL fetch below (mount runs
        # with the local default node) and refreshed asynchronously on demand
        # (refresh_custom_tools/1). `loading` drives the panel's spinner.
        custom_tools_status: %{ok: [], errors: []},
        custom_tools_loading: false,
        remote_config: false,
        remote_config_error: nil,
        bootstrap_progress: %{},
        # Per-target pending-connect markers (id → true) set by
        # connect_remote_target while the async connect is in flight. Cleared
        # by the terminal "remote_connections" broadcast handler (or the
        # {:remote_connect_result, ...} sync-error fallback); doubles as the
        # duplicate-click guard.
        remote_connect_pending: %{},
        bootstrap_restart_confirm: nil,
        remote_targets: safe_list_targets(),
        remote_statuses: safe_connection_statuses(),
        remote_form_target: nil,
        remote_show_advanced: false
      )
      |> load_custom_agents_data()
      |> load_custom_tools_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Detach save ownership BEFORE replacing the selected target, including
    # aliases that resolve to the same BEAM. NodeAware refreshes remote_status.
    requested_target = if params["node"] in [nil, "local"], do: nil, else: params["node"]

    socket =
      if requested_target != socket.assigns[:current_node_id],
        do: reset_config_scope(socket),
        else: socket

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/settings")
      |> reconcile_config_scope()

    # Seeded shell (async platform gating): the platform-filtered schemas map
    # and the platform OS for the (possibly remote) node are computed in the
    # async node-data task below (NodeData) — never block the LiveView render
    # loop on cross-node RPCs. Until the result arrives, seed the UNFILTERED
    # schemas (all categories visible) so the page shell renders immediately;
    # the result handler re-filters and re-resolves the active category.
    socket = assign(socket, :schemas_by_category, socket.assigns.all_schemas_by_category)
    socket = assign(socket, :platform_os, socket.assigns.platform_os || :unknown)

    # The OAuth auth-status assigns must SURVIVE navigation (category switch,
    # push_patch): seed them only when missing, never overwrite a loaded map.
    socket =
      if Map.has_key?(socket.assigns, :auth_statuses) do
        socket
      else
        assign(socket, auth_statuses: %{}, auth_status_seq: 0)
      end

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

    # Tag every load with a generation and full target identity. A save
    # invalidates older snapshots, and category navigation during a write must
    # not race its authoritative receipt.
    socket =
      if ConfigSave.busy?(socket),
        do: socket,
        else: start_node_data_load(socket, params["category"])

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
  def handle_info({{@node_data_tag, seq, scope}, requested_node, category_param, result}, socket) do
    if seq == socket.assigns.settings_load_seq and scope == ConfigSave.scope(socket) and
         requested_node == socket.assigns.current_node and not pending_remote_target?(socket) do
      {:noreply,
       apply_node_data_results(
         socket,
         category_param,
         node_data_results(result, requested_node, socket)
       )}
    else
      {:noreply, socket}
    end
  end

  # Old node-only responses cannot prove target or generation ownership.
  def handle_info({@node_data_tag, _node, _category, _result}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({{:settings_config_saved, _token, _scope}, _result} = message, socket) do
    case ConfigSave.complete(socket, message) do
      {:saved, receipt, socket} -> {:noreply, apply_config_receipt(socket, receipt)}
      {:failed, receipt, socket} -> {:noreply, save_failed_flash(socket, receipt.reason)}
      {:stale, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({{:settings_saved_status, token, scope}, result}, socket) do
    if token == socket.assigns.config_status_token and scope == ConfigSave.scope(socket) do
      case result do
        {:ok, %{} = status} ->
          {:noreply, assign(socket, :config_status, status)}

        failed ->
          {:noreply,
           socket
           |> assign(:config_status, NodeData.degraded_config_status())
           |> saved_warning_flash({:config_status, failed})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({{:credentials_saved, saved_node, _credential_key}, result}, socket) do
    # Result of an ASYNC (remote-node) credential save started by
    # save_api_key_remote/4 — the SafeCall result envelope is nested:
    # `EvoDash.SafeCall.start/4` sends `{tag, SafeCall.run(fun)}`, so the
    # task's own `{:ok, map}` / `{:error, reason}` arrives one level deeper.
    # `config_saving` (the shared in-page "Saving configuration…" indicator) is
    # cleared on EVERY branch, including the stale one. A stale save belongs to
    # a node the user has since left and is dropped.
    socket = assign(socket, :config_saving, false)

    if saved_node != socket.assigns.current_node do
      {:noreply, socket}
    else
      case result do
        {:ok, {:ok, %{} = saved}} ->
          # A nil credentials value means the re-fetch failed — keep the current
          # assign instead of blanking the API-key card.
          {:noreply,
           socket
           |> apply_saved_credentials(saved)
           |> put_flash(:info, gettext("API key saved successfully."))}

        {:ok, {:error, reason}} ->
          # Keep the previously rendered state — nothing was persisted.
          {:noreply, credentials_failed_flash(socket, reason)}

        # The task itself exited / raised — SafeCall reports it here.
        {:error, reason} ->
          {:noreply, credentials_failed_flash(socket, reason)}

        other ->
          {:noreply, credentials_failed_flash(socket, {:unexpected_save_result, other})}
      end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when ref == socket.assigns.config_load_wait_ref do
    # An invalidated writer is now finished. Only now fetch the next scope's
    # candidate, so a reconnect cannot retain a pre-write snapshot.
    socket = assign(socket, :config_load_wait_ref, nil)
    {:noreply, start_node_data_load(socket, Atom.to_string(socket.assigns.active_category))}
  end

  @impl true
  def handle_info({:custom_tools_loaded, requested_node, result}, socket) do
    # Stale-guard (same convention as the node-data load): the async refresh
    # was spawned for `requested_node`; if the user has since switched nodes a
    # newer load services the new node — drop this value. Always clear the
    # loading flag so the panel's spinner never sticks.
    if requested_node == socket.assigns.current_node do
      {:noreply, assign(socket, custom_tools_status: result, custom_tools_loading: false)}
    else
      {:noreply, assign(socket, :custom_tools_loading, false)}
    end
  end

  @impl true
  def handle_info({:settings_auth_status_loaded, requested_node, seq, statuses}, socket) do
    # Two stale guards, no polling: the load was requested for `requested_node`
    # at spawn time (a node switch makes it describe another node's credentials)
    # and carries the `:auth_status_seq` it was spawned with (a newer load is
    # already in flight and will deliver fresher values). Either mismatch drops
    # the result — the map stays `:unknown` until the newer load lands.
    if requested_node != socket.assigns.current_node or seq != socket.assigns.auth_status_seq do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :auth_statuses, statuses)}
    end
  end

  @impl true
  def handle_info({{:llm_test_result, seq, scope}, result}, socket) do
    # SafeCall's tag stays nested. Only the latest test of this exact persisted
    # account/model on this target/BEAM node may settle the visible status.
    if seq == socket.assigns[:llm_test_seq] and scope == llm_test_scope(socket) and
         socket.assigns.llm_test_status == :testing and not pending_remote_target?(socket) do
      {:noreply, assign(socket, :llm_test_status, normalize_llm_test_result(result))}
    else
      {:noreply, socket}
    end
  end

  # Old/unscoped responses cannot establish which account or node was tested.
  def handle_info({:llm_test_result, _result}, socket), do: {:noreply, socket}

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
  def handle_info({:node_selected, node_id}, socket) do
    socket =
      if node_id != (socket.assigns[:current_node_id] || "local"),
        do: reset_config_scope(socket),
        else: socket

    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
    socket = reconcile_config_scope(socket)

    socket =
      if socket.assigns.active_category == :remote_connections do
        socket
        |> assign(:remote_targets, safe_list_targets())
        |> assign(:remote_statuses, safe_connection_statuses())
      else
        socket
      end

    # A node switch changes the config domain — a draft picked on the previous
    # node's config must not leak onto the new node's appearance card.
    {:noreply, socket |> assign(:appearance_accent_draft, nil) |> invalidate_llm_test()}
  end

  @impl true
  def handle_info({:remote_connection_status, target_id, status} = msg, socket) do
    # Reconnects can keep both target id and BEAM identity. A phase transition
    # still invalidates drafts, pending writes and pre-disconnect snapshots.
    phase = if is_map(status), do: status[:phase], else: status

    socket =
      if target_id == socket.assigns[:current_node_id] and
           phase != socket.assigns[:settings_connection_phase],
         do: reset_config_scope(socket),
         else: socket

    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)

    socket =
      if target_id == socket.assigns[:current_node_id] do
        EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, %{"node" => target_id})
      else
        socket
      end

    socket = reconcile_config_scope(socket)

    socket =
      if socket.assigns.active_category == :remote_connections do
        assign(socket, :remote_statuses, safe_connection_statuses())
      else
        socket
      end

    bootstrap_progress =
      update_bootstrap_progress(socket.assigns.bootstrap_progress, target_id, status)

    socket = assign(socket, :bootstrap_progress, bootstrap_progress)

    socket =
      if target_id == socket.assigns[:current_node_id] and phase == :connected and
           is_nil(socket.assigns[:config_loaded_scope]) and not ConfigSave.busy?(socket),
         do: start_node_data_load(socket, Atom.to_string(socket.assigns.active_category)),
         else: socket

    {:noreply, consume_remote_connect_pending(socket, target_id, status)}
  end

  # Sync-error fallback for an async connect initiated via
  # connect_remote_target/retry_remote_connection: connect/1 returned an error
  # on an arm that never broadcasts (e.g. the remote-connection subsystem is
  # unavailable) — the flash is the surfacing mechanism. The pending marker is
  # also cleared so the Connect button is not wedged by the duplicate guard
  # (no terminal broadcast will ever arrive for this attempt).
  @impl true
  def handle_info({:remote_connect_result, target_id, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(
        :remote_connect_pending,
        Map.delete(Map.get(socket.assigns, :remote_connect_pending, %{}), target_id)
      )
      |> flash_remote_lifecycle_result({:error, reason}, gettext("Connect"))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bootstrap_complete, id, result}, socket) do
    socket =
      case result do
        {:error, {:daemon_running, details}} ->
          # The remote host already serves Erlang distribution to another
          # connection (refused bootstrap) — no staging happened. Drop the
          # transient active entry (the bar would otherwise sit on a
          # stage-less "active" state forever) and ask the user for permission
          # to detach that node and re-enable distribution with this
          # connection's identity (see confirm_bootstrap_restart). No generic
          # error flash — the dialog IS the feedback.
          socket
          |> reload_remote_statuses()
          |> clear_bootstrap_progress(id)
          |> assign(:bootstrap_restart_confirm, %{id: id, details: details})

        {:ok, _} ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :success)
          |> flash_remote_lifecycle_result(result, gettext("Install"))

        :ok ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :success)
          |> flash_remote_lifecycle_result(result, gettext("Install"))

        {:error, reason} ->
          socket
          |> reload_remote_statuses()
          |> freeze_bootstrap_progress(id, :error, bootstrap_error_text(reason))
          |> flash_remote_lifecycle_result(result, gettext("Install"))
      end

    {:noreply, socket}
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

  # Normalizes the three result shapes the async node-data load can deliver:
  #
  #   * `{:ok, results}` — the normal success map (NodeData.start/3);
  #   * `{:error, reason}` — the load EXITED or raised (e.g. a dead scheduler
  #     or an unreachable remote node). Degrade through NodeData.error_results/3
  #     so the page shows the "Remote Configuration Unavailable" banner and an
  #     empty config instead of crashing;
  #   * a BARE results map — the pre-`{:ok, _}` message shape, still delivered
  #     by tests that inject a hand-built results map.
  defp node_data_results({:ok, results}, _requested_node, _socket) when is_map(results),
    do: results

  defp node_data_results({:error, reason}, requested_node, socket) do
    EvoDashWeb.SettingsLive.NodeData.error_results(
      requested_node,
      socket.assigns.all_schemas_by_category,
      reason
    )
  end

  defp node_data_results(results, _requested_node, _socket) when is_map(results), do: results

  defp saved_config_status(%{config_status: %{} = config_status}), do: config_status
  defp saved_config_status(_saved), do: NodeData.degraded_config_status()

  # Applies the config-status / credentials re-fetch of a saved credential write:
  # the status always (a nil value degrades to the conservative "degraded"
  # status), the credentials map only when the re-fetch produced one.
  defp apply_saved_credentials(socket, %{} = saved) do
    socket
    |> assign(:config_status, saved_config_status(saved))
    |> maybe_assign_credentials(Map.get(saved, :credentials))
  end

  defp maybe_assign_credentials(socket, %{} = credentials),
    do: assign(socket, :credentials, credentials)

  defp maybe_assign_credentials(socket, _credentials), do: socket

  # Normalizes the exit-safe `EvoDash.SafeCall.run/1` envelope around an LLM
  # connection test into the `{:ok, data} | {:error, reason}` shape the
  # `llm_test_result` handler renders: the test functions themselves already
  # return that shape, so a successful guarded call nests it one level deeper.
  defp normalize_llm_test_result({:ok, {:ok, data}}), do: {:ok, data}
  defp normalize_llm_test_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_llm_test_result({:ok, other}), do: {:error, {:unexpected_result, other}}
  defp normalize_llm_test_result({:error, reason}), do: {:error, reason}

  defp llm_test_scope(socket) do
    {target_id, target_node} = test_config_scope(socket)
    {target_id, target_node, socket.assigns[:test_profile_id]}
  end

  defp test_config_scope(socket) do
    {socket.assigns[:current_node_id], socket.assigns[:current_node] || node()}
  end

  defp pending_remote_target?(socket) do
    not is_nil(socket.assigns[:current_node_id]) and
      (socket.assigns[:current_node] || node()) == node() and
      not match?(%{phase: :connected}, socket.assigns[:remote_status])
  end

  defp invalidate_llm_test(socket) do
    assign(socket, llm_test_seq: (socket.assigns[:llm_test_seq] || 0) + 1, llm_test_status: :idle)
  end

  defp invalidate_config_load(socket) do
    assign(socket,
      settings_load_seq: (socket.assigns[:settings_load_seq] || 0) + 1,
      config_status_token: nil
    )
  end

  defp reset_config_scope(socket) do
    # Retain ConfigSave's live-worker guard and wait event-driven for an
    # invalidated writer before loading another whole-file candidate.
    socket =
      case {socket.assigns[:config_save_owner], socket.assigns[:config_load_wait_ref]} do
        {pid, nil} when is_pid(pid) -> assign(socket, :config_load_wait_ref, Process.monitor(pid))
        _ -> socket
      end

    socket = ConfigSave.invalidate(socket)
    {:noreply, socket} = ModelProfileEvents.cancel_edit_model_profile(socket, %{})

    socket
    |> invalidate_config_load()
    |> invalidate_llm_test()
    |> assign(
      config_loaded_scope: nil,
      file_config: %{},
      test_config_scope: nil,
      test_profile_id: nil,
      config_status: NodeData.degraded_config_status(),
      per_category_errors: %{},
      appearance_accent_draft: nil,
      selected_provider_id: nil,
      selected_provider_models: [],
      selected_variant_id: nil,
      selected_model_string: nil,
      auth_statuses: %{},
      auth_status_seq: (socket.assigns[:auth_status_seq] || 0) + 1
    )
  end

  defp reconcile_config_scope(socket) do
    scope = ConfigSave.scope(socket)

    phase =
      if socket.assigns[:current_node_id], do: get_in(socket.assigns, [:remote_status, :phase])

    socket =
      if scope != socket.assigns[:settings_scope] or
           phase != socket.assigns[:settings_connection_phase],
         do: reset_config_scope(socket),
         else: socket

    assign(socket, settings_scope: scope, settings_connection_phase: phase)
  end

  defp start_node_data_load(socket, category_param) do
    socket = invalidate_config_load(socket)

    unless pending_remote_target?(socket) do
      NodeData.start(
        socket,
        {@node_data_tag, socket.assigns.settings_load_seq, ConfigSave.scope(socket)},
        category_param
      )
    end

    socket
  end

  defp assign_test_config(socket, file_config) do
    socket
    |> assign(:file_config, file_config)
    |> assign(:test_config_scope, test_config_scope(socket))
    |> reconcile_test_profile()
    # Even an unchanged account/model can now have different credentials or
    # generation defaults. A pre-reload result must not describe the new config.
    |> invalidate_llm_test()
  end

  defp reconcile_test_profile(socket) do
    values =
      socket.assigns.file_config
      |> ConfigIO.model_selections()
      |> Enum.map(&EvoDashWeb.SettingsComponents.model_selection_value/1)

    selected = socket.assigns[:test_profile_id]
    selected = if selected in values, do: selected, else: List.first(values)
    assign(socket, :test_profile_id, selected)
  end

  defp start_llm_test(params, socket) do
    socket = reconcile_test_profile(socket)
    profile_id = params["profile_id"] || socket.assigns.test_profile_id

    selection =
      Enum.find(ConfigIO.model_selections(socket.assigns.file_config), fn selection ->
        EvoDashWeb.SettingsComponents.model_selection_value(selection) == profile_id
      end)

    if selection do
      socket = socket |> assign(:test_profile_id, profile_id) |> invalidate_llm_test()
      seq = socket.assigns.llm_test_seq
      scope = llm_test_scope(socket)
      config = socket.assigns.file_config
      target_node = socket.assigns.current_node || node()
      spec = Map.take(selection, [:provider_profile_id, :model])

      # Capture the destination and persisted selection now, not from a later
      # socket. Resolved credentials/options stay inside this server-side task.
      case EvoDash.SafeCall.start(self(), {:llm_test_result, seq, scope}, fn ->
             run_llm_test(target_node, config, spec)
           end) do
        {:ok, _pid} ->
          {:noreply, assign(socket, :llm_test_status, :testing)}

        {:error, reason} ->
          {:noreply, assign(socket, :llm_test_status, {:error, reason})}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Selected profile has no model configured."))}
    end
  end

  defp run_llm_test(target_node, config, spec) do
    # Resolve on the VIEWED node: OAuth import, named API-key environment vars,
    # inherited reasoning/generation defaults and provider options belong there.
    resolved =
      if target_node == node() do
        ConfigIO.resolve_model_spec(config, spec)
      else
        case EvoDash.NodeContext.call_remote(target_node, Schema, :resolve_model_spec, [
               config,
               spec
             ]) do
          {:ok, result} -> result
          {:error, _} = error -> error
        end
      end

    with {:ok, resolved} <- resolved do
      # model_spec is the ReqLLM-ready identifier, NOT the canonical picker map.
      # Pass the full core-composed auth/generation options without rebuilding a
      # partial option list or ever putting the resolved object into DOM state.
      if target_node == node() do
        EvoGit.SystemCheck.llm_test(resolved.model_spec, resolved.generation_params)
      else
        EvoGit.RemoteNode.llm_test(target_node, resolved.model_spec, resolved.generation_params)
      end
    end
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
        |> assign(:remote_targets, safe_list_targets())
        |> assign(:remote_statuses, safe_connection_statuses())
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    # Async connect — connect/1 returns promptly; terminal outcomes arrive via
    # the "remote_connections" PubSub broadcast, and sync errors (subsystem
    # unavailable etc.) via {:remote_connect_result, ...}.
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(
      socket,
      socket.assigns.current_node_id
    )

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

    schemas =
      socket.assigns.schemas_by_category
      |> Map.get(category, [])
      |> Enum.filter(&ConfigIO.generic_schema?/1)

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
        # ConfigSave owns asynchronous writes for both local and remote nodes.
        # Apply config only after its token/scope-matched receipt arrives;
        # runtime? also pushes changed local LLM / scheduler keys.
        persist_config(
          socket,
          config,
          gettext("Configuration saved successfully."),
          category in [:scheduler, :llm]
        )

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
      |> Enum.filter(&ConfigIO.generic_schema?/1)
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
        # Same persistence path as save_category/2 (see persist_config/4).
        persist_config(
          socket,
          config,
          gettext("Configuration saved successfully."),
          Enum.any?(all_matching_schemas, &(List.first(&1.key_path) in [:scheduler, :llm]))
        )

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

  # The provider editor uses canonical UI names; the detached event module
  # retains its legacy public names for existing callers.
  @impl true
  def handle_event("add_provider_profile", params, socket),
    do: ModelProfileEvents.add_model_profile(socket, params)

  @impl true
  def handle_event("edit_provider_profile", params, socket),
    do: ModelProfileEvents.edit_model_profile(socket, params)

  @impl true
  def handle_event("delete_provider_profile", params, socket),
    do: ModelProfileEvents.delete_model_profile(socket, params)

  @impl true
  def handle_event("set_default_provider_profile", params, socket),
    do: ModelProfileEvents.set_default_provider_profile(socket, params)

  @impl true
  def handle_event("cancel_edit_provider_profile", params, socket),
    do: ModelProfileEvents.cancel_edit_model_profile(socket, params)

  @impl true
  def handle_event("provider_profile_form_change", params, socket),
    do: ModelProfileEvents.model_profile_form_change(socket, params)

  @impl true
  def handle_event("save_provider_profile", params, socket) do
    # Preserve the nested UI draft for rerenders, adapting only at parse time.
    submitted_draft =
      EvoDashWeb.SettingsLive.ProviderProfiles.submission(
        params,
        socket.assigns[:profile_form_draft]
      )

    ModelProfileEvents.save_model_profile(
      socket,
      provider_form_params(submitted_draft),
      submitted_draft
    )
  end

  @impl true
  def handle_event(event, params, socket)
      when event in ["add_provider_model", "add_profile_model"],
      do: ModelProfileEvents.add_profile_model(socket, params)

  @impl true
  def handle_event(event, params, socket)
      when event in ["remove_provider_model", "remove_profile_model"],
      do: ModelProfileEvents.remove_profile_model(socket, params)

  @impl true
  def handle_event("add_provider_peak_hours_row", params, socket),
    do: ModelProfileEvents.add_peak_hours_row(socket, params)

  @impl true
  def handle_event("remove_provider_peak_hours_row", params, socket),
    do: ModelProfileEvents.remove_peak_hours_row(socket, params)

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

  # Refresh button on the model-profiles editor's auth-status badges — re-reads
  # the viewed node's OAuth credential state ASYNCHRONOUSLY (a cross-node RPC on
  # remote nodes). Result arrives as
  # `{:settings_auth_status_loaded, node, seq, statuses}`.
  @impl true
  def handle_event("refresh_auth_status", _params, socket) do
    {:noreply, start_auth_status_load(socket)}
  end

  @impl true
  def handle_event("toggle_profile_advanced", params, socket) do
    ModelProfileEvents.toggle_profile_advanced(socket, params)
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

  # Refresh button on the Custom Tools panel — re-fetch the custom-tools status
  # for the currently-viewed node ASYNCHRONOUSLY (a cross-node RPC on remote
  # nodes). Result arrives as `{:custom_tools_loaded, node, result}`.
  @impl true
  def handle_event("reload_custom_tools", _params, socket) do
    {:noreply, refresh_custom_tools(socket)}
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
      socket = invalidate_llm_test(socket)
      node = socket.assigns.current_node
      credentials = %{credential_key => String.trim(api_key)}

      if node == node() do
        save_api_key_local(socket, credentials)
      else
        save_api_key_remote(socket, node, credential_key, credentials)
      end
    end
  end

  @impl true
  def handle_event("test_llm", params, socket) do
    cond do
      pending_remote_target?(socket) ->
        # NodeAware falls back to the local BEAM until a requested remote target
        # connects. Reject BEFORE resolving anything that could import OAuth or
        # read local credentials; a local test would be dangerously misleading.
        {:noreply,
         socket
         |> invalidate_llm_test()
         |> put_flash(
           :error,
           gettext("Connect to the remote node before testing its configuration.")
         )}

      socket.assigns[:test_config_scope] != test_config_scope(socket) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Wait for this node's configuration to load before testing.")
         )}

      socket.assigns[:config_saving] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Wait for the configuration save to finish before testing.")
         )}

      true ->
        start_llm_test(params, socket)
    end
  end

  @impl true
  def handle_event("select_test_profile", %{"profile_id" => profile_id}, socket) do
    {:noreply,
     socket
     |> assign(:test_profile_id, profile_id)
     |> reconcile_test_profile()
     |> invalidate_llm_test()}
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
         remote_path: "/tmp/genesis_server",
         platform: nil,
         # Internal marker: while true, the Name field auto-tracks the SSH
         # Target (see remote_connections_form_change). Never persisted.
         auto_name: true
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
    # Exit-safe lookup: the target registry is a local GenServer whose call can
    # EXIT (dead/hung process) — `EvoDash.SafeCall` turns that into an error
    # value, which reads exactly like an unknown target (no edit form).
    form_target =
      case EvoDash.SafeCall.run(
             fn -> EvoDash.NodeContext.get_target(id) end,
             {:error, :not_found}
           ) do
        {:ok, target} ->
          target
          |> Map.put_new(:dist_port, 9000)
          |> Map.put_new(:remote_path, "/tmp/genesis_server")
          # Editing starts with the saved name shown verbatim — never
          # auto-track the SSH Target (internal marker, never persisted).
          |> Map.put(:auto_name, false)

        {:error, _reason} ->
          nil
      end

    {:noreply, assign(socket, remote_form_target: form_target, remote_show_advanced: false)}
  end

  @impl true
  def handle_event("toggle_remote_advanced", _params, socket) do
    {:noreply, update(socket, :remote_show_advanced, &(!&1))}
  end

  # Form change (every keystroke in the add/edit remote-connection form). The
  # Name field auto-fills from the SSH Target while the user has not typed a
  # custom name: the whole form-target assign is rebuilt from the submitted
  # params so the re-render shows the current values (name == full ssh_target
  # as it is typed). Once the user types into the Name field, that value is
  # kept verbatim and never clobbered by later SSH Target edits.
  @impl true
  def handle_event("remote_connections_form_change", params, socket) do
    current = socket.assigns.remote_form_target

    if is_nil(current) do
      {:noreply, socket}
    else
      rendered = current[:name] || ""
      submitted = params["name"] || ""
      tracking = Map.get(current, :auto_name, false)

      {name, tracking} =
        cond do
          tracking and submitted == rendered ->
            # Name untouched (its submitted value is the previous render's
            # auto-filled value) — keep tracking the SSH Target as it is typed.
            {params["ssh_target"] || "", true}

          tracking and submitted != rendered ->
            # The user took over the Name field — keep their value verbatim.
            {submitted, false}

          true ->
            {submitted, false}
        end

      form_target = %{
        name: name,
        ssh_target: params["ssh_target"] || "",
        local_binary_path: params["local_binary_path"] || "",
        platform: params["platform"] || "",
        dist_port: parse_remote_port(params["dist_port"]),
        remote_path: params["remote_path"] || "/tmp/genesis_server",
        auto_name: tracking
      }

      # Editing keeps the existing id; adding must NOT generate one here (the
      # hidden _id input would otherwise carry a frozen "target-<ts>" id into
      # save_remote_target instead of a slug from the effective name).
      form_target =
        case params["_id"] do
          id when is_binary(id) and id != "" -> Map.put(form_target, :id, id)
          _ -> form_target
        end

      {:noreply, assign(socket, remote_form_target: form_target)}
    end
  end

  @impl true
  def handle_event("save_remote_target", params, socket) do
    target = build_remote_target_from_params(params)

    # Exit-safe write: the registry call can EXIT the LiveView (dead/hung
    # process); the fallback lands on the existing "Failed to save" flash.
    case EvoDash.SafeCall.run(
           fn -> EvoDash.NodeContext.save_target(target) end,
           {:error, :unavailable}
         ) do
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
    # Exit-safe delete (see save_remote_target/3).
    case EvoDash.SafeCall.run(
           fn -> EvoDash.NodeContext.delete_target(id) end,
           {:error, :unavailable}
         ) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Connection deleted."))
          |> reload_remote_targets()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Connection not found."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to delete: %{reason}", reason: inspect(reason))
         )}
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
    # on_running: :restart (the core runs `<launcher> remote stop`, which only
    # DETACHES Erlang distribution — the remote server and its tasks keep
    # running — broadcasting :stopping_daemon, mapped to step 3 "Configuring",
    # then re-enables distribution with this connection's identity).
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
    # Duplicate guard — a connect is already in flight for this target; its
    # terminal outcome (:connected | :error | :disconnected) will arrive via
    # the "remote_connections" PubSub broadcast and be flashed by
    # consume_remote_connect_pending (which clears the marker).
    pending = Map.get(socket.assigns, :remote_connect_pending, %{})

    if Map.get(pending, id) == true do
      {:noreply, socket}
    else
      socket =
        assign(socket, :remote_connect_pending, Map.put(pending, id, true))

      # Async connect: connect/1 returns promptly ({:ok, :connecting} |
      # {:ok, :connected}); terminal outcomes arrive ONLY via broadcast.
      # Synchronous errors (subsystem unavailable — never broadcast) are
      # surfaced via {:remote_connect_result, ...}. No premature flash, no
      # status reload here — the broadcast handler re-reads statuses.
      {:noreply, EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, id)}
    end
  end

  @impl true
  def handle_event("disconnect_remote_target", %{"id" => id}, socket) do
    # Deliberately SYNCHRONOUS: disconnect is a fast GenServer.call (normally
    # <5s) and the Disconnect button renders only when the phase is :connected
    # (no bootstrap can be queued on that manager), so it cannot block the
    # LiveView meaningfully. Its terminal outcome is the sync result below.
    # EXIT-SAFE: the manager call can still EXIT this LiveView (dead/hung
    # process), so it runs through `EvoDash.SafeCall`; a failure reads as an
    # unavailable subsystem for `flash_remote_lifecycle_result/3`.
    result =
      EvoDash.SafeCall.run(
        fn -> EvoDash.NodeContext.disconnect(id) end,
        {:error, :remote_connection_unavailable}
      )

    socket =
      socket
      |> reload_remote_statuses()
      |> flash_remote_lifecycle_result(result, gettext("Disconnect"))

    {:noreply, socket}
  end

  # The custom-agent store still accepts only a provider/legacy id, selecting
  # that account's default model. Deduplicate the canonical model inventory by
  # account rather than manufacturing unsupported per-model model_id strings.
  defp custom_agent_model_choices(config) do
    config
    |> ConfigIO.model_selections()
    |> Enum.uniq_by(& &1.provider_profile_id)
    |> Enum.map(&%{id: &1.provider_profile_id})
  end

  # The new presentation nests generation inputs while the canonical parser
  # deliberately accepts flat request fields. Keep UI sentinels out of storage.
  defp provider_form_params(params) do
    params
    |> flatten_generation_params()
    |> Map.update("models", [], fn rows ->
      rows
      |> EvoDashWeb.SettingsLive.ProviderProfiles.rows()
      |> Enum.map(fn row ->
        row = flatten_generation_params(row)

        row =
          case row["override_reasoning"] do
            value when value in [false, "false"] ->
              # Absence means inherit; [] would explicitly override inventory.
              Map.delete(row, "reasoning_efforts")

            value when value in [true, "true"] ->
              if EvoDashWeb.SettingsLive.ProviderProfiles.string_list(row["reasoning_efforts"]) ==
                   [] do
                row
                |> Map.put("reasoning_efforts", [])
                |> Map.delete("default_reasoning_effort")
              else
                row
              end

            _ ->
              row
          end

        Map.delete(row, "override_reasoning")
      end)
    end)
  end

  defp flatten_generation_params(params) do
    generation = Map.get(params, "generation", %{})

    keys =
      ~w(temperature max_tokens top_p top_k frequency_penalty presence_penalty provider_options extra)

    params
    |> Map.delete("generation")
    |> Map.merge(Map.take(generation, keys))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  @doc false
  def persist_file_config(file_config, socket, success_msg),
    do: persist_file_config(file_config, socket, success_msg, [])

  @doc false
  def persist_file_config(file_config, socket, success_msg, opts) when is_list(opts) do
    # Never construct a new target's whole-file write from another scope's
    # snapshot. ConfigSave additionally guards pending targets and live writers.
    if socket.assigns[:config_loaded_scope] == ConfigSave.scope(socket) do
      case ConfigSave.start(socket, file_config, success_msg, opts) do
        {:started, socket} ->
          {:noreply, invalidate_config_load(socket)}

        {:rejected, reason, socket} ->
          {:noreply, save_failed_flash(socket, reason)}

        {:failed, reason, socket} ->
          {:noreply, save_failed_flash(socket, reason)}
      end
    else
      socket = ModelProfileEvents.persistence_failed(socket, Keyword.get(opts, :editor_token))
      {:noreply, save_failed_flash(socket, :configuration_not_loaded)}
    end
  end

  defp persist_config(socket, config, success_msg, runtime?),
    do: persist_file_config(config, socket, success_msg, runtime?: runtime?)

  defp apply_config_receipt(socket, receipt) do
    reload_warning = Keyword.get(receipt.warnings, :config_reload)

    socket =
      socket
      |> assign_test_config(receipt.file_config)
      |> assign(
        config_loaded_scope: receipt.scope,
        config_file_exists: true,
        per_category_errors: %{},
        appearance_accent_draft: nil,
        remote_config_error: remote_config_error_message(reload_warning)
      )
      |> put_flash(:info, receipt.success_msg)

    socket =
      if receipt.runtime? and socket.assigns.current_node == node(),
        do: ConfigIO.update_runtime_from_file_config(receipt.file_config, socket),
        else: socket

    socket = Enum.reduce(receipt.warnings, socket, &saved_warning_flash(&2, &1))
    socket |> refresh_saved_config_status() |> start_auth_status_load()
  end

  defp refresh_saved_config_status(socket) do
    target_node = socket.assigns.current_node

    if target_node == node() do
      assign(socket, :config_status, safe_config_status())
    else
      token = make_ref()
      scope = ConfigSave.scope(socket)

      socket =
        assign(socket,
          config_status_token: token,
          config_status: NodeData.degraded_config_status()
        )

      case EvoDash.SafeCall.start(self(), {:settings_saved_status, token, scope}, fn ->
             EvoDash.NodeContext.get_remote_config_status(target_node)
           end) do
        {:ok, _pid} -> socket
        {:error, reason} -> saved_warning_flash(socket, {:config_status, reason})
      end
    end
  end

  defp saved_warning_flash(socket, warning) do
    put_flash(
      socket,
      :warning,
      gettext("Configuration saved, but refresh failed: %{reason}", reason: inspect(warning))
    )
  end

  # LOCAL credential save — deliberately SYNCHRONOUS (a plain file write, so the
  # success flash renders in the submit reply) but exit-safe: a dead config
  # store / scheduler surfaces as a value instead of crashing the page.
  defp save_api_key_local(socket, credentials) do
    case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.save_credentials(node(), credentials) end) do
      {:ok, :ok} ->
        {:noreply,
         socket
         |> assign(:config_status, safe_config_status())
         |> assign(
           :credentials,
           EvoDash.SafeCall.run(fn -> EvoGit.Config.credentials() end, socket.assigns.credentials)
         )
         |> put_flash(:info, gettext("API key saved successfully."))}

      {:ok, {:error, reason}} ->
        {:noreply, credentials_failed_flash(socket, reason)}

      {:error, reason} ->
        {:noreply, credentials_failed_flash(socket, reason)}

      {:ok, other} ->
        {:noreply, credentials_failed_flash(socket, {:unexpected_save_result, other})}
    end
  end

  # REMOTE credential save in a supervised task — the write, the scheduler
  # reload and the config-status / credentials re-fetch all cross the node
  # boundary, so the LiveView process never blocks on them. `config_saving`
  # drives the shared in-page indicator and the result handler
  # ({:credentials_saved, ...}) clears it on EVERY branch.
  defp save_api_key_remote(socket, node, credential_key, credentials) do
    case EvoDash.SafeCall.start(self(), {:credentials_saved, node, credential_key}, fn ->
           remote_credentials_save(node, credentials)
         end) do
      {:ok, _pid} ->
        {:noreply, assign(socket, :config_saving, true)}

      # The supervisor is gone — no result will ever arrive, so the indicator
      # must stay off and the user gets the failure right away.
      {:error, _reason} ->
        {:noreply, credentials_failed_flash(socket, :task_supervisor_unavailable)}
    end
  end

  # The remote credential-save body (runs in the supervised task). Returns
  # `{:ok, %{config_status: map | nil, credentials: map | nil}}` or
  # `{:error, reason}`.
  #
  # Only the WRITE failure is an error: once the credentials file is written, a
  # failing reload/re-fetch degrades (nil config status → the conservative
  # degraded status; nil credentials → the handler keeps the current assign) so
  # a saved key is never misreported as a failed save.
  defp remote_credentials_save(node, credentials) do
    case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.save_credentials(node, credentials) end) do
      {:ok, :ok} ->
        # Make the new key take effect on the remote scheduler immediately.
        # Best-effort — the re-fetch below surfaces a reload problem.
        EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.reload_remote_config(node) end)

        config_status =
          EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.get_remote_config_status(node) end, nil)

        credentials =
          case EvoDash.SafeCall.run(fn ->
                 EvoDash.NodeContext.call_remote(node, EvoGit.Config, :credentials, [])
               end) do
            {:ok, %{} = creds} -> creds
            _failed_or_unexpected -> nil
          end

        {:ok, %{config_status: config_status, credentials: credentials}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_save_result, other}}
    end
  end

  defp credentials_failed_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to save API key: %{reason}", reason: inspect(reason))
    )
  end

  defp save_failed_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
    )
  end

  # The user-facing banner text for a failed remote config re-fetch (the save
  # itself succeeded) — same message/shape the synchronous path always used.
  defp remote_config_error_message(nil), do: nil

  defp remote_config_error_message(reason) do
    gettext(
      "Could not load configuration from the remote node: %{reason} — the node may be unreachable.",
      reason: inspect(reason)
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware custom agents + custom tools loading
  # ───────────────────────────────────────────────────────────────────────────

  # Loads the custom-agents data (agent definitions, model-selection script,
  # script compile status) for the currently-viewed node into the socket.
  #
  # `EvoDash.NodeContext.list_custom_agents/1` degrades to an empty result on
  # RPC failure, so an unreachable remote node reads as "no custom agents"
  # instead of crashing; `EvoDash.SafeCall` additionally covers an EXIT (a dead
  # remote-registry GenServer call exits its caller, which a rescue cannot
  # catch) — the same empty shape is used so the editor still renders. Public
  # because CustomAgentEvents reloads through it after every mutation.
  @doc false
  def load_custom_agents_data(socket) do
    node = socket.assigns.current_node

    {agents, script, script_status} =
      case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.list_custom_agents(node) end) do
        {:ok, {:ok, %{agents: agents, model_selection_script: script, script_status: status}}} ->
          {agents, script, status}

        _error_or_unexpected ->
          {[], "", :ok}
      end

    assign(socket,
      custom_agents: agents,
      model_selection_script: script || "",
      script_status: script_status,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: []
    )
  end

  # Loads the custom-tools status (tool modules discovered in the node's
  # `<config_dir>/tools/`) synchronously into the socket, mirroring
  # `load_custom_agents_data/1`'s mount-time local seed.
  #
  # `EvoDashWeb.SettingsLive.NodeData.fetch_custom_tools_status/1` is TOTAL: a
  # remote RPC failure reads as `{:error, reason}` (the panel renders its
  # degraded state) instead of crashing. Public because the custom-agent
  # mutation flows refresh through it.
  @doc false
  def load_custom_tools_data(socket) do
    assign(socket,
      custom_tools_status:
        EvoDashWeb.SettingsLive.NodeData.fetch_custom_tools_status(socket.assigns.current_node),
      custom_tools_loading: false
    )
  end

  # Re-fetches the custom-tools status for the currently-viewed node in a
  # SUPERVISED task — never inline in the LiveView process (a cross-node RPC on
  # remote nodes) — then reports back `{:custom_tools_loaded, node, result}`.
  # Non-blocking: the panel renders with `@custom_tools_loading` true until the
  # result lands. The result handler stale-guards on the node. Called by the
  # panel's Refresh button and by the custom-agent mutation flows.
  @doc false
  def refresh_custom_tools(socket) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoDashWeb.SettingsLive.NodeData.fetch_custom_tools_status(node)
      send(parent, {:custom_tools_loaded, node, result})
    end)

    assign(socket, :custom_tools_loading, true)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware config loading
  # ───────────────────────────────────────────────────────────────────────────

  # Local config-completeness status (mount + local saves). Exit-safe: the
  # core reads the resolved config / scheduler state, so a dead core process
  # would EXIT the caller. The degraded shape (`ok?: false`, no warnings) is the
  # conservative fallback — it renders the same "Missing Configuration" box the
  # page shows for an unconfigured install, never a false "all configured".
  defp safe_config_status do
    EvoDash.SafeCall.run(
      fn -> EvoDashWeb.Helpers.config_status() end,
      EvoDashWeb.SettingsLive.NodeData.degraded_config_status()
    )
  end

  # Saved remote-connection targets (mount + the remote-connections category
  # switch). A failing registry read degrades to "no targets".
  defp safe_list_targets do
    EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.list_targets() end, [])
  end

  # Per-target connection-status map (mount + the remote-connections category
  # switch). A failing read degrades to an empty map (every target renders as
  # unknown, the pre-existing "no status" rendering).
  defp safe_connection_statuses do
    EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.connection_status() end, %{})
  end

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
      |> assign_test_config(results.file_config)
      |> assign(:config_status, results.config_status)
      |> assign(
        :config_loaded_scope,
        if(is_nil(results.remote_config_error), do: ConfigSave.scope(socket))
      )
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
      # Tolerant: results maps built before the custom-tools panel lack this key
      # (several tests build them without it) — default to the empty status.
      custom_tools_status: Map.get(results, :custom_tools_status, %{ok: [], errors: []}),
      custom_tools_loading: false,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: []
    )
    |> start_auth_status_load()
  end

  # Fires the ASYNC OAuth/subscription credential-status load for the currently
  # viewed node (see EvoDashWeb.SettingsLive.AuthStatus). Fire-and-forget: the
  # result arrives as `{:settings_auth_status_loaded, node, seq, statuses}` and
  # is stale-guarded by node + seq. `AuthStatus.start/2` is total — it returns
  # `:ok` even when the task supervisor is unavailable — so `:ok =` is a
  # deliberate assertion, not a case.
  defp start_auth_status_load(socket) do
    seq = socket.assigns.auth_status_seq + 1
    socket = assign(socket, :auth_status_seq, seq)
    profiles = Schema.provider_profiles(socket.assigns.file_config || %{})
    :ok = AuthStatus.start(socket, profiles)
    socket
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

  # Compatibility adapter for callers holding a legacy FLAT scheduler map.
  # Normal navigation and save reconciliation use the FULL resolved file config;
  # runtime :model_profiles are converted here, never used as editor rows.
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

    # Feed legacy runtime rows through the migration boundary, not the editor.
    llm =
      case remote_cfg[:model_profiles] do
        nil -> llm
        [] -> llm
        profiles -> Map.put(llm, :models, profiles)
      end

    %{}
    |> Map.put(:scheduler, scheduler)
    |> Map.put(:llm, llm)
    |> ConfigIO.canonicalize_file_config()
  end

  def remote_config_to_file_config(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Remote Connections
  # ───────────────────────────────────────────────────────────────────────────

  defp reload_remote_targets(socket) do
    assign(socket, :remote_targets, safe_list_targets())
  end

  defp reload_remote_statuses(socket) do
    assign(socket, :remote_statuses, safe_connection_statuses())
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
      msg -> format_remote_reason(msg)
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
      true -> format_remote_reason(reason)
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
    # A blank/absent name falls back to the SSH Target (the Name field
    # auto-fills from it while untouched) so a new target always persists
    # name == ssh_target even on a direct submit with no change event.
    name = params["name"]

    name =
      if is_binary(name) and name != "" do
        name
      else
        params["ssh_target"] || ""
      end

    id = params["_id"]
    id = if id && id != "", do: id, else: generate_remote_id(name)

    %{
      id: id,
      name: name,
      ssh_target: params["ssh_target"] || "",
      local_binary_path: params["local_binary_path"] || "",
      platform: params["platform"] || "",
      dist_port: parse_remote_port(params["dist_port"]),
      remote_path: params["remote_path"] || "/tmp/genesis_server"
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

  # Consumes the per-target pending-connect marker (set by
  # connect_remote_target) and flashes the FIRST terminal outcome broadcast of
  # an initiation made from THIS page. NodeAware.handle_connection_status has
  # already recomputed @connection_statuses/@remote_status by the time this
  # runs, so the gate reconciles automatically. Broadcasts for connects
  # initiated elsewhere (node selector, another page) never set the marker →
  # no flash. `:connecting` (non-terminal) neither clears nor flashes.
  defp consume_remote_connect_pending(socket, target_id, status) do
    phase = if is_map(status), do: Map.get(status, :phase), else: nil

    # Read the pending marker defensively: broadcasts for connects initiated
    # elsewhere (bootstrap, node selector, another page) never set the marker,
    # so the map may legitimately lack the key — bare dot-access would KeyError
    # only if the assign itself were missing, and a nil marker must not crash
    # `and` with a BadBooleanError.
    pending = Map.get(socket.assigns, :remote_connect_pending, %{})

    if Map.get(pending, target_id) == true and
         phase in [:connected, :error, :disconnected] do
      socket =
        assign(socket, :remote_connect_pending, Map.delete(pending, target_id))

      case phase do
        :connected ->
          flash_remote_lifecycle_result(socket, :ok, gettext("Connect"))

        :error ->
          reason =
            case Map.get(status, :last_error) do
              nil -> gettext("Unknown error")
              msg when is_binary(msg) -> msg
              msg -> format_remote_reason(msg)
            end

          put_flash(socket, :error, gettext("Connect failed: %{reason}", reason: reason))

        :disconnected ->
          # Some other flow disconnected the target — nothing useful to flash.
          socket
      end
    else
      socket
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
          gettext("%{action} failed: %{reason}",
            action: action,
            reason: format_remote_reason(reason)
          )
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
