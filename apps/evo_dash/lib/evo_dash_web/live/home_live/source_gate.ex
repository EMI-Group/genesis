defmodule EvoDashWeb.HomeLive.SourceGate do
  @moduledoc """
  "Genesis source not downloaded yet" gate support for `EvoDashWeb.HomeLive`
  (the `/help` chat page).

  The `/help` chat runs a REPO-LESS `:reflect` task whose reference is the
  managed Genesis source checkout (`EvoGit.SelfReflectiveSource`). On a fresh
  install that source is normally NOT downloaded yet, so a send silently starts
  a task that has nothing to read. This module makes that state visible and
  actionable: one short sentence + a one-click **Download source** button
  instead of a doomed task.

  Plain function-component module (no LiveComponent) — the LiveView owns all
  socket mutations (`handle_event`/`handle_info`); this module hosts the banner
  markup, the pure predicates, and the async spawn helpers, mirroring the
  `EvoDashWeb.SystemLive.SourceCard` support-module split.

  ## Local-node only

  The source checkout lives on the host filesystem the self-reflective agent
  reads. There is no source RPC, so the gate is local-only exactly like
  `EvoDashWeb.SystemLive.SourceCard.visible?/1`: it applies when
  `@current_node in [nil, node()]`. The live banner renders only when
  `blocked?/1` is true, i.e. the availability check positively reported
  `false` FOR THE LOCAL NODE.

  ## Runner seams (resolved AT SPAWN TIME)

  Both spawn helpers read their runner from the application env INSIDE the
  spawned task so tests can stub them via `Application.put_env(:evo_dash, ...)`:

    * `:source_availability_runner` — 0-arity, returns
      `true | false | {:unavailable, reason}`; default
      `fn -> EvoDash.SourceStatus.available?() end`.
    * `:source_clone_runner` — 0-arity, returns
      `{:ok, status} | {:error, reason} | {:unavailable, reason}`; default
      `fn -> EvoDash.SourceStatus.clone() end`. Deliberately the SAME seam name
      `EvoDashWeb.SystemLive.SourceCard` uses (one conceptual action, one seam).

  `EvoDash.SourceStatus` is the total (never-raising) wrapper over the
  optionally-absent `EvoGit.SelfReflectiveSource` core backend — this module
  never calls that backend directly.

  ## Message shapes

    * `{:source_availability_loaded, seq, node, result}` — `seq` is the
      LiveView's captured `:source_check_seq`; `node` the node the check ran
      for.
    * `{:source_clone_result, node, result}`.

  Both are handled by TOTAL `handle_info` clauses in the LiveView (node +
  seq stale-guarded), so a stray result can never leak or crash the page.
  """

  use EvoDashWeb, :html

  @doc """
  Whether the gate applies to the given node context — local viewing only
  (`nil` on a fresh socket or `node()` for the dashboard's own BEAM node).
  Mirrors `EvoDashWeb.SystemLive.SourceCard.visible?/1`.
  """
  def visible?(node), do: node in [nil, node()]

  @doc """
  Whether the chat is BLOCKED because the Genesis source is not downloaded.

  Only a KNOWN `false` blocks, and only on a local node: `nil` (unknown /
  check in flight) and `{:unavailable, _}` (backend absent) must never wedge
  the user out of the chat.
  """
  def blocked?(assigns) do
    Map.get(assigns, :source_available) == false and visible?(Map.get(assigns, :current_node))
  end

  # ── Async spawn helpers ──

  @doc """
  Spawns an async availability check on `EvoDash.TaskSupervisor` and reports
  the result to `view_pid` as `{:source_availability_loaded, seq, node, result}`.
  """
  def spawn_availability_check(view_pid, seq, node) do
    runner =
      Application.get_env(:evo_dash, :source_availability_runner) ||
        (&default_availability/0)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        send(view_pid, {:source_availability_loaded, seq, node, runner.()})
      rescue
        # (1) Do we expect this error? Yes — this is the untrusted runner
        # boundary (a test stub or the guarded backend may raise); the spawned
        # fn must NEVER raise, or the result message would never be sent and
        # the LiveView would keep `:source_check_loading` set forever.
        # (2) Is try/rescue the cleanest approach? Yes — a deliberate
        # async-boundary rescue (same pattern as NodeAware's sidebar fetch and
        # SystemLive.SourceCard's spawn helpers); `{:unavailable, _}` is treated
        # as "unknown" by the LiveView, so the gate simply stays hidden.
        _ ->
          send(view_pid, {:source_availability_loaded, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  @doc """
  Spawns an async source download (clone) on `EvoDash.TaskSupervisor` and
  reports the result to `view_pid` as `{:source_clone_result, node, result}`.
  """
  def spawn_clone(view_pid, node) do
    runner = Application.get_env(:evo_dash, :source_clone_runner) || (&default_clone/0)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        send(view_pid, {:source_clone_result, node, runner.()})
      rescue
        # Same async-boundary rationale as spawn_availability_check/3: a
        # crashing runner would otherwise leave `:source_busy` set forever.
        _ -> send(view_pid, {:source_clone_result, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  # --- Default runners (delegate to the total EvoDash.SourceStatus wrapper) ---

  # The Genesis source acts on the LOCAL filesystem and the gate is local-only
  # (`visible?/1`), so no node argument is needed.
  defp default_availability, do: EvoDash.SourceStatus.available?()

  defp default_clone, do: EvoDash.SourceStatus.clone()

  # ── Banner markup ──

  attr(:source_busy, :any,
    default: nil,
    doc: "truthy while a download is in flight; disables the button + swaps its label"
  )

  attr(:current_node_id, :any,
    default: nil,
    doc: "viewed node id, threaded into the node-aware System-page link"
  )

  @doc """
  The "Genesis source not downloaded yet" banner — a `shrink-0` row pinned
  between the page header and the message scroller (so it shows for BOTH the
  empty state and a restored transcript). Pure presentation: the Download
  button sends `phx-click="download_source"` to the LiveView.
  """
  def source_gate(assigns) do
    ~H"""
    <div id="genesis-source-gate" class="shrink-0 px-4 pb-2">
      <div class="flex flex-wrap items-center gap-3 rounded-lg border border-warning/30 bg-warning/10 px-3.5 py-2.5">
        <.icon name="hero-arrow-down-tray" class="size-4 shrink-0 text-warning" />
        <p class="flex-1 min-w-0 text-sm leading-snug text-base-content/80">
          <%!-- zh_CN: "尚未下载 Genesis 源码——请先下载，助手才能阅读 Genesis 代码库" --%>{gettext(
            "The Genesis source has not been downloaded yet — download it so the assistant can read the Genesis codebase."
          )}
        </p>
        <div class="flex items-center gap-2 shrink-0">
          <button
            id="genesis-source-download"
            type="button"
            phx-click="download_source"
            disabled={@source_busy != nil}
            class="btn btn-primary btn-sm rounded-md gap-2"
          >
            <.icon
              name="hero-arrow-path"
              class={"size-4 #{if @source_busy != nil, do: "animate-spin"}"}
            />
            <%!-- zh_CN: "下载源码" --%>
            {if @source_busy != nil,
              do: gettext("Cloning…"),
              else: gettext("Download source")}
          </button>
          <%!-- zh_CN: "打开系统页面" --%>
          <.link
            navigate={with_node_param(~p"/system", @current_node_id)}
            class="btn btn-ghost btn-sm rounded-md"
          >
            {gettext("Open the System page")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
