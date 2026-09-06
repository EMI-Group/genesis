defmodule EvoDashWeb.LiveHooks.Appearance do
  @moduledoc """
  Global on-mount hook that applies the user-configured accent color to the
  app shell — the accent of the node being VIEWED (local or a connected
  remote `genesis_remote` target), so a remote page whose accent differs from
  the local one never flashes the local/default color.

  Reads `EvoGit.Config.resolve([:appearance, :accent_color])` (schema default
  `"blue"`, validated to one of the ten CSS-known names) and seeds the
  `@accent_color` assign on EVERY LiveView (registered globally via `on_mount`
  in the `live_view/0` macro, after `NodeAware`, before `DesktopQuit` — Guide
  stays LAST). The shared app layout (`EvoDashWeb.Layouts.app`) declares
  `attr(:accent_color, :string, default: "blue")` and sets
  `data-accent-color={@accent_color}` on the `#app-layout` shell div, which
  activates the ten `[data-accent-color="<name>"]` override rules in app.css
  (un-layered author CSS placed after the daisyUI theme `@plugin` blocks) that
  retarget `--color-primary`/`--color-accent` within the shell subtree.

  Resolution is NODE-AWARE, mirroring `NodeAware`'s `params["node"]`
  resolution (known+connected target → the remote node; known-but-not-
  connected → pending with the target id preserved; nil/"local"/unknown id →
  local):

  * **Per-node accent cache (`EvoDash.AccentCache`)** — a small ETS cache (no
    process) keyed by connection-target id alone (`nil` = local) holds the
    last-known accent per node. Every mount seed (`on_mount/4`) and every
    `:handle_params` re-resolution reads it SYNCHRONOUSLY — a local ETS read,
    never an RPC — so a page whose node's accent was seen before paints that
    accent on the very first render: dead render, connected mount, and every
    cross-LiveView `push_navigate` (a new process re-runs mount +
    handle_params), with no interim local/default color. Keying by the target
    id alone (NOT `{node_id, node}` like the ActiveTasks hub) makes the same
    target hit the same entry across the pending→connected BEAM-node-atom
    flip — the accent is a per-target config value and does not change when
    the connection completes.
  * **Local node** (no `?node=`, `"local"`, or an unknown id): the value is
    resolved SYNCHRONOUSLY inside the attached `:handle_params` interceptor
    via a direct `EvoGit.Config.resolve([:appearance, :accent_color])` call —
    a local file read, cheap on every mount and page push, so the accent is
    correct on the very first paint (dead render and connected mount both run
    `handle_params` after `on_mount`).
  * **Remote node** (`params["node"]` naming a connected `genesis_remote`
    target): the cache is read synchronously first — warm → the remote accent
    is assigned before the first paint; a cold first visit keeps the seed
    (`"blue"` via `assign_new`) until the ASYNC result lands. The async fetch
    (supervised on `EvoDash.TaskSupervisor`, never an RPC on the render path)
    calls `EvoDash.NodeContext.get_resolved_config/1` (the remote node's full
    resolved config — the same RPC SettingsLive uses) and extracts the
    `appearance.accent_color` key. It is spawned on EVERY connected remote
    re-resolution: it heals a cold cache AND refreshes a warm one, so a remote
    accent change propagates on the next page load. Every SUCCESSFUL result
    writes the cache (one fetch serves all later loads); a FAILED fetch is a
    no-op — it must never regress a known warm accent to the default. Results
    land through the attached `:handle_info` interceptor, applied only when
    both the fetch seq AND the node context still match (stale-guard); stale
    results are dropped WITHOUT a cache write.
  * **Pending target** (known but not yet connected): the target's warm cache
    value is preferred over the local accent (no local-color flash on the
    target's page while it connects); only a genuinely cold target falls back
    to the local accent (data comes from the local node until the connection
    completes).

  Re-resolution is driven by a `:handle_params` interceptor: it re-resolves
  only when `params["node"]` OR the resolved node mode changed since the last
  run (the initial mount, node switches, and a pending→connected transition —
  which re-runs `handle_params` with the same `?node=` via NodeAware's
  `handle_connection_status/2` push_patch — all re-resolve; pagination/search
  push_patches that leave the node context untouched pass through cheaply).

  No PubSub subscription is needed: the accent is static per node until the
  config changes, and the async refresh on each connected remote
  re-resolution keeps warm cache entries honest (a config change on the
  remote propagates on the next page load). `on_mount` (seed + attach) and
  the `handle_params`/`handle_info` interceptors suffice.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  # The ten accent names the `[data-accent-color="<name>"]` override rules in
  # app.css understand. Anything else (including nil from an unset/absent key,
  # or an unknown value from an older remote config) normalizes to the schema
  # default "blue".
  @known_accents ~w(blue teal green yellow orange red pink purple brown slate)

  @doc """
  Seeds the `@accent_color` assign (via `assign_new`) and attaches the
  `:handle_params` + `:handle_info` interceptors on EVERY mount path (dead
  render AND connected — the `handle_params` interceptor needs no
  `connected?` gating and there is no desktop-mode gate; the async remote
  fetch itself is gated on `connected?` inside the interceptor).

  The seed reads the `EvoDash.AccentCache` synchronously for the page's node
  param (a local ETS read, never an RPC): a warm remote/pending target paints
  its own accent from the very first assign, while a cold page (or the local
  node — never cached) falls back to the schema default `"blue"`. The
  authoritative resolution still happens in the attached `:handle_params`
  interceptor before the first paint.
  """
  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign_new(:accent_color, fn -> seed_accent(params["node"]) end)
      |> attach_hook(:appearance_accent, :handle_params, &handle_params/3)
      |> attach_hook(:appearance_accent, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  @doc false
  # Normalizes a resolved accent value: the ten CSS-known names pass through;
  # anything else (nil from an unset/absent key, unknown values from an older
  # remote config) falls back to the schema default "blue". Pure seam for unit
  # tests.
  def resolve_accent(accent) when accent in @known_accents, do: accent
  def resolve_accent(_accent), do: "blue"

  @doc false
  # Extracts the accent from a resolved config map (`%{appearance:
  # %{accent_color: ...}}`, atom-keyed as returned by `EvoGit.Config.resolve/0`).
  # Missing key / invalid value → "blue". Pure seam for unit tests.
  def accent_from_config(config) when is_map(config) do
    resolve_accent(get_in(config, [:appearance, :accent_color]))
  end

  def accent_from_config(_config), do: "blue"

  # Attached `:handle_params` hook — runs BEFORE the LiveView's own
  # `handle_params/3` (which calls `NodeAware.assign_node/2`), on every mount
  # and every push_patch/push_navigate. Re-resolves the accent only when the
  # node param OR the resolved node mode changed since the last run; otherwise
  # passes through cheaply. Always returns `{:cont, socket}` — the view's own
  # `handle_params` must run regardless.
  def handle_params(params, _uri, socket) do
    node_param = params["node"]
    mode = resolve_mode(node_param)

    if node_param == Map.get(socket.assigns, :accent_node_param, :unset) and
         mode == Map.get(socket.assigns, :accent_node_mode, :unset) do
      {:cont, socket}
    else
      socket = apply_mode(socket, node_param, mode)

      socket =
        socket
        |> assign(:accent_node_param, node_param)
        |> assign(:accent_node_mode, mode)

      {:cont, socket}
    end
  end

  # Attached `:handle_info` hook — routes async remote-accent results through
  # the stale-guard; `{:halt, socket}` consumes the matching message, everything
  # else passes through `{:cont, socket}`.
  def handle_info(
        {:appearance_accent_result, _seq, _node_param, _result} = message,
        socket
      ) do
    {:halt, handle_accent_result(socket, message)}
  end

  def handle_info(_message, socket) do
    {:cont, socket}
  end

  # Stale-guarded application of an async remote-accent result. Drops the
  # result (socket unchanged, cache untouched) when the fetch seq no longer
  # matches (a newer fetch was spawned since — only the latest result is ever
  # applied) or the node param changed while the fetch was in flight (the user
  # switched nodes). A matching SUCCESSFUL result assigns `:accent_color` and
  # writes the `EvoDash.AccentCache` (one fetch serves all later loads); a
  # matching FAILED result is a no-op — a transient RPC failure must never
  # regress a known warm accent (or the seed) to the default.
  defp handle_accent_result(
         socket,
         {:appearance_accent_result, seq, node_param, result}
       ) do
    if seq != Map.get(socket.assigns, :accent_fetch_seq, 0) or
         node_param != Map.get(socket.assigns, :accent_node_param, :unset) do
      # Stale — a node switch or a newer fetch superseded this result.
      socket
    else
      case result do
        {:ok, accent} ->
          accent = resolve_accent(accent)
          EvoDash.AccentCache.put(node_param, accent)
          assign(socket, :accent_color, accent)

        {:error, _reason} ->
          # Fetch failed (remote unreachable / RPC error) — keep whatever is
          # currently shown (a warm cache value or the seed).
          socket
      end
    end
  end

  # Resolves a `?node=` param to the node mode whose accent should be shown.
  # Mirrors `NodeAware.assign_node/2`'s resolution:
  #   * `{:local, nil}` — nil/"local"/unknown id: the local node's accent.
  #   * `{:pending, node_param}` — a known target that is not connected yet:
  #     show the target's last-known accent when warm, else the local accent
  #     (data comes from the local node until the connection completes).
  #   * `{:remote, node_param, remote_node}` — a connected target: the
  #     target's accent, cache-first (synchronous) + async fetch (connected
  #     sockets only).
  defp resolve_mode(nil), do: {:local, nil}
  defp resolve_mode("local"), do: {:local, nil}

  defp resolve_mode(node_param) do
    case EvoDash.NodeContext.get_target(node_param) do
      {:ok, target} ->
        case EvoDash.NodeContext.connection_status(target.id) do
          %{phase: :connected, node: remote_node} when is_binary(remote_node) ->
            {:remote, node_param, String.to_atom(remote_node)}

          _ ->
            {:pending, node_param}
        end

      {:error, :not_found} ->
        {:local, nil}
    end
  end

  # Applies the resolved mode to the socket. Local, or an unknown/absent node
  # param: the local config is the best available value — read synchronously
  # (a local file read, never an RPC).
  defp apply_mode(socket, _node_param, {:local, nil}) do
    assign(socket, :accent_color, local_accent())
  end

  # Known target that is not connected yet (pending): prefer the target's
  # last-known accent (warm cache) over the local accent, so a pending remote
  # page never flashes the local color when its own accent is known. A
  # genuinely cold target falls back to the local accent (nothing is known
  # about the target's config yet).
  defp apply_mode(socket, node_param, {:pending, _node_param}) do
    case cached_accent(node_param) do
      {:ok, accent} -> assign(socket, :accent_color, accent)
      :empty -> assign(socket, :accent_color, local_accent())
    end
  end

  # Connected remote target: assign the target's accent SYNCHRONOUSLY from the
  # cache when warm (correct first paint — no interim local/default color on
  # revisit/navigation), else keep the seed for a cold first visit. On a
  # connected socket the async fetch is ALWAYS spawned — it heals a cold cache
  # AND refreshes a warm one, so a remote accent change propagates on the next
  # page load. The fetched value only ever REPLACES the current one when the
  # remote really reports a different accent: a failed fetch is a no-op (see
  # `handle_accent_result/3`), so a warm value is never regressed by a
  # transient RPC failure.
  defp apply_mode(socket, node_param, {:remote, _node_param, remote_node}) do
    socket =
      case cached_accent(node_param) do
        {:ok, accent} -> assign(socket, :accent_color, accent)
        :empty -> socket
      end

    if Phoenix.LiveView.connected?(socket) do
      request_remote_accent(socket, node_param, remote_node)
    else
      # Dead render: no RPC on the render path — the synchronous cache assign
      # above (warm) or the seed (cold) is the best available value; the
      # connected mount re-runs on_mount + handle_params and spawns the fetch.
      socket
    end
  end

  # Synchronous mount-time seed for `assign_new`: a warm cache entry for the
  # page's node param is used directly (so a dead render / connected mount
  # never starts from the default "blue" when the node's accent is known);
  # anything else falls back to the schema default. The authoritative
  # resolution still happens in the attached `:handle_params` interceptor
  # before the first paint.
  defp seed_accent(node_param) do
    case cached_accent(node_param) do
      {:ok, accent} -> accent
      :empty -> "blue"
    end
  end

  # Reads the last-known accent for a node context (nil = local) from the
  # `EvoDash.AccentCache` — a single local ETS read, safe on every render
  # path (never an RPC). `{:ok, accent}` when warm, `:empty` when cold or the
  # table does not exist.
  defp cached_accent(node_param) do
    EvoDash.AccentCache.get(node_param)
  end

  # Reads the resolved accent from the LOCAL node's config (a file read —
  # acceptable on all mounts including the dead render; avoids an accent flash).
  defp local_accent do
    resolve_accent(EvoGit.Config.resolve([:appearance, :accent_color]))
  end

  # Spawns a supervised fetch of the remote node's resolved accent and returns
  # the socket unchanged; the result arrives later via the attached
  # `:handle_info` hook. Captures the view pid, the node param, and the next
  # `:accent_fetch_seq` value BEFORE spawning and bumps the seq assign (so only
  # the latest request's result is ever applied).
  defp request_remote_accent(socket, node_param, remote_node) do
    view_pid = self()
    seq = Map.get(socket.assigns, :accent_fetch_seq, 0) + 1

    socket = assign(socket, :accent_fetch_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          case EvoDash.NodeContext.get_resolved_config(remote_node) do
            {:ok, config} -> {:ok, accent_from_config(config)}
            {:error, reason} -> {:error, reason}
          end
        rescue
          # (1) Do we expect this error? Any unexpected failure inside a
          # fire-and-forget supervised task (e.g. a crashed remote connection) —
          # the spawned fn must NEVER raise, or the result message would never
          # be sent and the accent would silently stay at its seed.
          # (2) Is try/rescue the cleanest approach? Yes — the established
          # async-boundary rescue pattern (NodeAware's request_tasks_load).
          _ -> {:error, :fetch_failed}
        end

      send(view_pid, {:appearance_accent_result, seq, node_param, result})
    end)

    socket
  end
end
