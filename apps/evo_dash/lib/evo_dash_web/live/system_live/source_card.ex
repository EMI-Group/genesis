defmodule EvoDashWeb.SystemLive.SourceCard do
  @moduledoc """
  Genesis Source card support for `EvoDashWeb.SystemLive`.

  Mirrors the `update_card.ex` support-module pattern: the single-page
  LiveView stays lean while this module hosts the status/clone/update flows
  backed by the `EvoGit.SelfReflectiveSource` backend module. That module is
  built by a parallel workstream and may be absent at compile time, so every
  default runner is guarded with `Code.ensure_loaded?/1` and degrades
  gracefully to `{:unavailable, :module_missing}` when it is not compiled in.

  The card is local-only by design: a remote `genesis_remote` daemon's
  self-reflective agent reads the REMOTE host's filesystem, so clone/update
  must never act on a remote node (`visible?/1`).

  ## Runner seam contract

  Each spawn function resolves its runner from the application env INSIDE the
  spawned task (at spawn/execution time, never stored in LiveView assigns) so
  tests can stub it via `Application.put_env(:evo_dash, ...)`. Runners are
  1-arity functions receiving the node the request was spawned for (always the
  local node in practice — the card is local-only):

  - `:source_status_runner` — returns the raw status map (backend `status/0`
    shape: `%{dir:, exists:, is_git_repo:, valid:, commit:, branch:, version:,
    remote_url:, reference:, is_reference:}`) or `{:unavailable, reason}`.
  - `:source_clone_runner` / `:source_update_runner` — return
    `{:ok, status_map} | {:error, reason} | {:unavailable, reason}`.

  Every spawn rescues at the async boundary and reports
  `{:unavailable, :runner_error}` so a crashing runner can never wedge the
  card's loading/busy state.

  ## Merged section markup

  The Genesis Source UI is rendered as a sub-section of the System Self-Check
  section (`source_section/1` component) rather than a standalone card: it
  shows only the minimal useful info — the checkout directory (`dir`), the
  checked-out commit + version when cloned, and the reference line — plus the
  clone/update buttons. The branch and remote-URL displays were dropped (they
  were always the constants `main` / the repo path).
  """

  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext
  import EvoDashWeb.CoreComponents, only: [icon: 1]

  @doc "Whether the Genesis Source section should render for the given node context."
  def visible?(node), do: node in [nil, node()]

  # ── Merged section markup (rendered inside the System Self-Check) ─────────

  attr(:source_status, :any)
  attr(:source_status_loading, :boolean, default: false)
  attr(:source_busy, :any)

  @doc """
  The Genesis Source sub-section of the System Self-Check section: minimal
  checkout info (directory, commit + version when cloned) and the clone/update
  buttons. The always-constant branch (`main`) and remote-URL displays were
  deliberately dropped when this was merged into the self-check section.

  Button visibility mirrors the old standalone card: only a map status renders
  buttons (loading / `nil` / `{:unavailable, _}` states show no buttons), and
  clone-vs-update is chosen by `status.exists`.
  """
  def source_section(assigns) do
    ~H"""
    <div id="genesis-source-card" class="mt-6 pt-5 border-t border-base-200/60">
      <div class="flex items-center justify-between gap-4 mb-3">
        <div class="flex items-center gap-3">
          <.icon name="hero-code-bracket-square" class="size-5 text-info shrink-0" />
          <div>
            <h3 class="font-bold text-sm">{gettext("Genesis Source")} <% # zh_CN: "本地 Genesis 源码" %></h3>
            <p class="text-xs text-base-content/60 mt-0.5">
              {gettext("Genesis source checkout used by the self-reflective agent.")} <% # zh_CN: "自省智能体使用的 Genesis 源码检出目录" %>
            </p>
          </div>
        </div>
        <%= if not @source_status_loading and is_map(@source_status) do %>
          <%= if @source_status.exists do %>
            <button
              id="update-source"
              type="button"
              phx-click="update_source"
              class="btn btn-primary btn-sm rounded-md gap-2 shrink-0"
              disabled={@source_busy != nil}
            >
              <.icon
                name="hero-arrow-path"
                class={"size-4 #{if @source_busy == :update, do: "animate-spin"}"}
              />
              {if @source_busy == :update,
                do: gettext("Updating…"),
                else: gettext("Update")} <% # zh_CN: "更新" %>
            </button>
          <% else %>
            <button
              id="clone-source"
              type="button"
              phx-click="clone_source"
              class="btn btn-primary btn-sm rounded-md gap-2 shrink-0"
              disabled={@source_busy != nil}
            >
              <.icon
                name="hero-arrow-path"
                class={"size-4 #{if @source_busy == :clone, do: "animate-spin"}"}
              />
              {if @source_busy == :clone,
                do: gettext("Cloning…"),
                else: gettext("Clone")} <% # zh_CN: "克隆" %>
            </button>
          <% end %>
        <% end %>
      </div>

      <div>
        <%= if @source_status_loading do %>
          <div class="flex items-center gap-3 py-1">
            <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/50" />
            <span class="text-sm text-base-content/60">{gettext("Loading…")} <% # zh_CN: "正在加载" %></span>
          </div>
        <% else %>
          <%= case @source_status do %>
            <% {:unavailable, _reason} -> %>
              <div class="flex items-center gap-2 py-1">
                <.icon name="hero-information-circle" class="size-4 text-info shrink-0" />
                <span class="text-sm text-info">
                  {gettext("Genesis source is not available in this version")} <% # zh_CN: "当前版本不提供 Genesis 源码功能" %>
                </span>
              </div>
            <% nil -> %>
              <!-- No status yet — the async load assigns it shortly. -->
            <% status when is_map(status) -> %>
              <div class="space-y-1.5 text-sm">
                <div class="flex items-baseline gap-2 min-w-0">
                  <span class="text-base-content/50 shrink-0 font-medium w-24">{gettext("Directory")} <% # zh_CN: "目录" %></span>
                  <span class="font-mono text-xs text-base-content/80 break-all min-w-0">
                    {status.dir || ""}
                  </span>
                </div>
                <%= if status.exists do %>
                  <%= if status.commit do %>
                    <div class="flex items-baseline gap-2 min-w-0">
                      <span class="text-base-content/50 shrink-0 font-medium w-24">{gettext("Commit")} <% # zh_CN: "提交" %></span>
                      <span class="font-mono text-xs text-base-content/80">{status.commit}</span>
                    </div>
                  <% end %>
                  <%= if status.version do %>
                    <div class="flex items-baseline gap-2 min-w-0">
                      <span class="text-base-content/50 shrink-0 font-medium w-24">{gettext("Version")} <% # zh_CN: "版本" %></span>
                      <span class="font-mono text-xs text-base-content/80">{status.version}</span>
                    </div>
                  <% end %>
                <% else %>
                  <p class="text-sm text-base-content/60 pt-1">
                    {gettext("The Genesis source has not been cloned yet.")} <% # zh_CN: "尚未克隆 Genesis 源码" %>
                  </p>
                <% end %>
              </div>

              <div class="mt-3 pt-3 border-t border-base-200/60">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="text-sm text-base-content/70">
                    {gettext("The self-reflective agent reads: %{path}",
                      path: reference_path(status)
                    )} <% # zh_CN: "自省智能体读取的源码路径" %>
                  </span>
                  <%= if status.is_reference do %>
                    <span class="badge badge-info badge-sm gap-1">
                      {gettext("in use")} <% # zh_CN: "使用中" %>
                    </span>
                  <% end %>
                </div>
                <%= if override_in_effect?(status) do %>
                  <p class="text-xs text-base-content/40 mt-1">
                    {gettext("An explicit override is in effect")} <% # zh_CN: "已设置显式覆盖（GENESIS_SOURCE_ROOT 环境变量或应用配置）" %>
                  </p>
                <% end %>
              </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The path the self-reflective agent actually reads: the explicit reference
  (GENESIS_SOURCE_ROOT / app-env override) when set, else the managed checkout
  dir. Rendered on the section's reference line.
  """
  def reference_path(status) do
    status.reference || status.dir || ""
  end

  @doc """
  An explicit reference override (reference != the managed dir) is in effect —
  the section must not imply that clone/update act on what the agent reads.
  """
  def override_in_effect?(status) do
    status.reference != nil and status.reference != status.dir
  end

  @doc """
  Spawns an async status load on `EvoDash.TaskSupervisor` and reports the
  result to `view_pid` as `{:source_status_loaded, seq, node, result}`.
  """
  def spawn_status_load(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_status_runner) || (&default_status/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_status_loaded, seq, node, result})
      rescue
        # A crashing runner must not wedge the loading state.
        _ -> send(view_pid, {:source_status_loaded, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  @doc """
  Spawns an async clone on `EvoDash.TaskSupervisor` and reports the result to
  `view_pid` as `{:source_clone_result, seq, node, result}`.
  """
  def spawn_clone(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_clone_runner) || (&default_clone/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_clone_result, seq, node, result})
      rescue
        # A crashing runner must not wedge the busy state.
        _ -> send(view_pid, {:source_clone_result, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  @doc """
  Spawns an async update on `EvoDash.TaskSupervisor` and reports the result to
  `view_pid` as `{:source_update_result, seq, node, result}`.
  """
  def spawn_update(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_update_runner) || (&default_update/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_update_result, seq, node, result})
      rescue
        # A crashing runner must not wedge the busy state.
        _ -> send(view_pid, {:source_update_result, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  # --- Default runners (guarded against the optionally-absent backend) ---

  # The `node` argument is ignored: `EvoGit.SelfReflectiveSource` acts on the
  # LOCAL filesystem and the card is local-only (`visible?/1`). The backend is
  # invoked via `apply/3` (not a direct call) so a build without the module
  # compiles warning-free — a direct call to a missing module's function emits
  # an "undefined function" compile warning even inside an ensure_loaded branch.
  defp default_status(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :status, [])
    else
      {:unavailable, :module_missing}
    end
  end

  defp default_clone(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :clone, [])
    else
      {:unavailable, :module_missing}
    end
  end

  defp default_update(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :update, [])
    else
      {:unavailable, :module_missing}
    end
  end
end
