defmodule EvoDashWeb.LiveHooks.AppearanceTest do
  # Tests for the global Appearance on-mount hook (EvoDashWeb.LiveHooks.Appearance):
  #
  # 1. Unit tests for the pure seams resolve_accent/1 + accent_from_config/1 —
  #    no LiveView needed.
  # 2. Dead-render on_mount seeding: Appearance.on_mount/4 invoked directly on a
  #    minimal boot-shaped socket (router + lifecycle private — see the helper
  #    comment) seeds @accent_color == "blue" via assign_new when no assign
  #    exists (cold cache), preserves a pre-existing assign, and attaches the
  #    :handle_params/:handle_info interceptors.
  # 3. LiveView integration on pages that render through Layouts.app (the
  #    #app-layout shell div): the initial connected render carries
  #    data-accent-color; a NON-default local accent ("teal") from the user
  #    config is visible SYNCHRONOUSLY on that initial render (local resolution
  #    happens in the attached :handle_params interceptor — no async flush
  #    needed); a fresh empty config yields the schema default "blue". Mounting
  #    /welcome AND /system proves the hook is registered on every LiveView
  #    (the `live_view/0` macro registers it after NodeAware).
  # 4. Remote-node accent caching (the accent-flash fix): a page viewing a
  #    node renders ONLY that node's accent from the first paint. The
  #    EvoDash.AccentCache hub (keyed by connection-target id alone, nil =
  #    local) is read synchronously on every mount + handle_params
  #    re-resolution, so a WARM remote target paints its own accent on the
  #    dead render / first connected render with no async flush; a SUCCESSFUL
  #    async fetch writes the cache (one fetch serves later loads); STALE
  #    results are dropped and never write the cache; a PENDING (saved but not
  #    connected) target with a warm cache shows its own accent, never the
  #    local one. Whole-page mounts assert data-accent-color; bare-socket
  #    unit tests drive on_mount/handle_params/handle_info directly.
  #
  # async: false — every test isolates the user config via a per-test
  # XDG_CONFIG_HOME env var (the hook reads config.toml there; so does
  # NodeAware for remote_connections.toml), so the host's real config can never
  # leak in (same pattern as settings_live_test.exs / node_aware_test.exs).
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoDashWeb.LiveHooks.Appearance

  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_appearance_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    # ActiveTasks is a global hub under EvoDashboard.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    # Same discipline for the per-node accent cache (a boot-created named ETS
    # table shared across all evo_dash tests in the OS process): one test's
    # warm remote accent must never leak into the next test's cold mounts.
    EvoDash.AccentCache.reset()

    :ok
  end

  describe "resolve_accent/1 — the known-accent normalization seam" do
    test "the ten CSS-known names pass through unchanged" do
      for accent <- ~w(blue teal green yellow orange red pink purple brown slate) do
        assert Appearance.resolve_accent(accent) == accent
      end
    end

    test "nil (unset/absent key) and unknown values normalize to the schema default \"blue\"" do
      assert Appearance.resolve_accent(nil) == "blue"
      assert Appearance.resolve_accent("chartreuse") == "blue"
      assert Appearance.resolve_accent("") == "blue"
    end
  end

  describe "accent_from_config/1 — extraction from a resolved config map" do
    test "atom-keyed %{appearance: %{accent_color: accent}} extracts the accent" do
      assert Appearance.accent_from_config(%{appearance: %{accent_color: "teal"}}) == "teal"
    end

    test "missing appearance key → \"blue\"" do
      assert Appearance.accent_from_config(%{llm: %{models: []}}) == "blue"
    end

    test "invalid value inside the config → \"blue\"" do
      assert Appearance.accent_from_config(%{appearance: %{accent_color: "not-a-color"}}) ==
               "blue"
    end

    test "non-map config → \"blue\"" do
      assert Appearance.accent_from_config(nil) == "blue"
    end
  end

  describe "on_mount/4 — dead-render seeding + interceptor attachment" do
    # A minimal socket that mirrors what Appearance.on_mount/4 needs beyond a
    # bare %Phoenix.LiveView.Socket{}: on_mount attaches a :handle_params
    # interceptor, which Phoenix.LiveView.Lifecycle.attach_hook/4 refuses on a
    # socket with router: nil ("the view was not mounted at the router"), and
    # attach_hook reads the boot-time :lifecycle key from socket.private. Same
    # minimal-socket idiom as node_aware_test.exs, plus those two boot
    # internals.
    defp hook_socket(overrides \\ %{}) do
      assigns = Map.merge(%{__changed__: %{}}, overrides)

      %Phoenix.LiveView.Socket{
        assigns: assigns,
        router: EvoDashWeb.Router,
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }
    end

    # Connected (websocket) boot socket. Phoenix.LiveView.connected?/1 is
    # `transport_pid != nil` — a non-nil transport_pid fakes a connected mount
    # so the async remote fetch fires (same idiom as node_aware_test.exs).
    defp connected_mount_socket(overrides \\ %{}) do
      %{hook_socket(overrides) | transport_pid: self()}
    end

    test "seeds @accent_color \"blue\" via assign_new when no assign exists (cold cache)" do
      assert {:cont, socket} = Appearance.on_mount(:default, %{}, %{}, hook_socket())

      assert socket.assigns.accent_color == "blue"
    end

    test "seeds a warm cached remote accent via assign_new when the page carries its node param" do
      EvoDash.AccentCache.put("warm-target", "purple")

      assert {:cont, socket} =
               Appearance.on_mount(:default, %{"node" => "warm-target"}, %{}, hook_socket())

      assert socket.assigns.accent_color == "purple"
    end

    test "preserves a pre-existing accent_color assign (assign_new never overrides)" do
      assert {:cont, socket} =
               Appearance.on_mount(:default, %{}, %{}, hook_socket(%{accent_color: "purple"}))

      assert socket.assigns.accent_color == "purple"
    end

    test "attaches the :handle_params and :handle_info interceptors" do
      assert {:cont, socket} = Appearance.on_mount(:default, %{}, %{}, hook_socket())

      lifecycle = socket.private.lifecycle
      assert length(lifecycle.handle_params) == 1
      assert length(lifecycle.handle_info) == 1
    end
  end

  describe "connected render — data-accent-color on #app-layout (local node)" do
    # Seeds config.toml with the given TOML body BEFORE mounting. The file-level
    # setup has already redirected XDG_CONFIG_HOME to a per-test temp dir, so
    # EvoGit.Config.config_path() is unique to this test and resolve() picks the
    # file up via its mtime+size-validated persistent_term cache (keyed by path)
    # — no explicit cache reset is needed when the file is written before the
    # first resolve of that path (same idiom as settings_live_test.exs
    # seed_write_paths). The explicit on_exit rm is belt-and-braces (the setup
    # already rm_rf!'s the whole temp dir).
    defp seed_config(contents) do
      path = EvoGit.Config.config_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)

      on_exit(fn ->
        # Teardown cleanup must not mask test failures.
        File.rm(path)
      end)
    end

    # Extracts the data-accent-color attribute value from the #app-layout shell
    # div (the Layouts.app markup), or [] when the attribute/element is absent.
    # Floki.find operates on a parsed tree, not a raw html binary — the
    # parse_document!/1 step mirrors the component-test `parse/1` idiom.
    defp accent_on_layout(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#app-layout")
      |> List.first()
      |> then(fn
        nil -> []
        layout_div -> Floki.attribute(layout_div, "data-accent-color")
      end)
    end

    # Phoenix.LiveViewTest does not export assigns/1 — same local helper idiom
    # as settings_live_test.exs:506.
    defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

    test "the app shell carries data-accent-color on the initial connected render", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      # /welcome renders through Layouts.app, so the #app-layout shell div is
      # present and — with the empty isolated config — carries the schema
      # default accent.
      assert accent_on_layout(html) == ["blue"]
    end

    test "a non-default local accent (teal) is visible synchronously on the initial render",
         %{conn: conn} do
      # Local resolution runs in the attached :handle_params interceptor via a
      # direct EvoGit.Config.resolve call (never an RPC), so the teal accent
      # must be present on the FIRST connected render — no async flush needed.
      seed_config("[appearance]\naccent_color = \"teal\"\n")

      {:ok, view, html} = live(conn, ~p"/welcome")

      assert accent_on_layout(html) == ["teal"]
      assert assigns(view).accent_color == "teal"
    end

    test "fresh (empty) user config resolves the schema default \"blue\" on another page",
         %{conn: conn} do
      # No config.toml is written in this test (the isolated XDG dir is empty).
      # /system is a different LiveView than /welcome — proving the hook is
      # registered GLOBALLY (every live_view/0 mount) and the default flows
      # through Layouts.app unchanged.
      {:ok, _view, html} = live(conn, ~p"/system")

      assert accent_on_layout(html) == ["blue"]
    end
  end

  describe "remote node accents — the per-node accent cache (flash fix)" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under a unique target id, so
    # EvoDash.NodeContext.connection_status/1 resolves the manager's status
    # instead of the disconnected default (same idiom as node_aware_test.exs).
    # The process dies (and its Registry entry is cleaned up) at test end.
    #
    # A saved target with NO manager resolves as "pending" (known but not
    # connected) — EvoGit.RemoteConnection.status/1 returns the disconnected
    # default map.
    defp save_target!(id, ssh_target \\ "test-host") do
      {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: ssh_target, id: id})
      target
    end

    test "a warm remote accent renders synchronously on the first ?node= render (no async flush)",
         %{conn: conn} do
      # Connected fake remote whose BEAM node does not exist: any async fetch
      # fails fast (:noconnection) and is a NO-OP — it must never regress the
      # warm value. The page must therefore paint the warm remote accent on the
      # very first render (dead render + connected mount), with no interim
      # local/default color.
      target_id = "accent-remote-warm"
      save_target!(target_id)

      start_supervised!(
        {EvoDashWeb.AppearanceTest.ConnectionManager,
         {target_id, %{phase: :connected, node: "nonexistent_remote_test@127.0.0.1"}}}
      )

      EvoDash.AccentCache.put(target_id, "purple")

      {:ok, view, html} = live(conn, ~p"/welcome?node=#{target_id}")

      assert accent_on_layout(html) == ["purple"]
      assert assigns(view).accent_color == "purple"

      # The connected-mount async fetch (if it has landed) was a no-op — the
      # warm accent is still in place.
      assert assigns(view).accent_color == "purple"
    end

    test "a successful async remote fetch writes the cache (one fetch serves later loads)" do
      # The fake manager reports the LOCAL BEAM node, so the supervised fetch's
      # EvoDash.NodeContext.get_resolved_config/1 resolves the (isolated,
      # seeded) local config — a deterministic SUCCESS path with no new seam.
      seed_config("[appearance]\naccent_color = \"teal\"\n")
      target_id = "accent-fetch-ok"
      save_target!(target_id)

      start_supervised!(
        {EvoDashWeb.AppearanceTest.ConnectionManager,
         {target_id, %{phase: :connected, node: Atom.to_string(node())}}}
      )

      {:cont, socket} =
        Appearance.on_mount(:default, %{"node" => target_id}, %{}, connected_mount_socket())

      {:cont, socket} = Appearance.handle_params(%{"node" => target_id}, "/x", socket)

      # The connected remote re-resolution spawned the async fetch (seq 1) with
      # the view pid = this test process; the fetch resolves "teal".
      assert_receive {:appearance_accent_result, 1, ^target_id, {:ok, "teal"}}, 1000

      # Routing the result through the attached :handle_info interceptor (the
      # non-stale apply path) assigns the accent AND writes the cache.
      {:halt, socket} =
        Appearance.handle_info(
          {:appearance_accent_result, 1, target_id, {:ok, "teal"}},
          socket
        )

      assert socket.assigns.accent_color == "teal"
      assert EvoDash.AccentCache.get(target_id) == {:ok, "teal"}
    end

    test "a matching (non-stale) result assigns the accent and writes the cache" do
      # Direct message-level test of the apply path: preset assigns matching
      # the message (seq + node param) — the non-stale branch.
      target_id = "accent-match"
      socket = hook_socket(%{accent_fetch_seq: 7, accent_node_param: target_id})

      {:halt, socket} =
        Appearance.handle_info(
          {:appearance_accent_result, 7, target_id, {:ok, "teal"}},
          socket
        )

      assert socket.assigns.accent_color == "teal"
      assert EvoDash.AccentCache.get(target_id) == {:ok, "teal"}
    end

    test "the stale-guard drops a superseded result and never writes the cache" do
      # Preset a NEWER fetch seq + a different current node param than the
      # stale message carries — exactly the state after the user switched
      # nodes / a newer fetch was spawned while this one was in flight.
      target_id = "accent-stale"
      before = hook_socket(%{accent_fetch_seq: 5, accent_node_param: "current-target"})

      {:halt, socket} =
        Appearance.handle_info(
          {:appearance_accent_result, 1, target_id, {:ok, "teal"}},
          before
        )

      assert socket == before
      assert EvoDash.AccentCache.get(target_id) == :empty
    end

    test "a failed async remote fetch is a no-op — a warm cache value is never regressed" do
      # Warm cache + connected fake whose BEAM node does not exist: the fetch
      # fails fast (:noconnection) and the apply must keep the warm value
      # (never overwrite it with the "blue" error fallback).
      target_id = "accent-fetch-fail"
      save_target!(target_id)

      start_supervised!(
        {EvoDashWeb.AppearanceTest.ConnectionManager,
         {target_id, %{phase: :connected, node: "nonexistent_remote_test@127.0.0.1"}}}
      )

      EvoDash.AccentCache.put(target_id, "orange")

      {:cont, socket} =
        Appearance.on_mount(:default, %{"node" => target_id}, %{}, connected_mount_socket())

      {:cont, socket} = Appearance.handle_params(%{"node" => target_id}, "/x", socket)

      assert socket.assigns.accent_color == "orange"

      # The spawned fetch fails and sends an {:error, _} result — assert the
      # message arrived, then route it through the interceptor: no-op.
      assert_receive {:appearance_accent_result, 1, ^target_id, {:error, _reason}}, 1000

      {:halt, socket} =
        Appearance.handle_info(
          {:appearance_accent_result, 1, target_id, {:error, :noconnection}},
          socket
        )

      assert socket.assigns.accent_color == "orange"
      assert EvoDash.AccentCache.get(target_id) == {:ok, "orange"}
    end

    test "a pending (not-yet-connected) remote target shows its warm accent, never the local one",
         %{conn: conn} do
      # The LOCAL config accent is teal; the pending target's warm cache is
      # orange. A saved target with no manager is pending — the page must
      # prefer the target's warm accent over the local one (no local-color
      # flash while connecting).
      seed_config("[appearance]\naccent_color = \"teal\"\n")
      target_id = "accent-pending-warm"
      save_target!(target_id)
      EvoDash.AccentCache.put(target_id, "orange")

      {:ok, view, html} = live(conn, ~p"/welcome?node=#{target_id}")

      assert accent_on_layout(html) == ["orange"]
      assert assigns(view).accent_color == "orange"

      # Pending targets never spawn an async fetch (no remote node yet) — the
      # fetch-seq assign is never allocated.
      assert Map.get(assigns(view), :accent_fetch_seq, 0) == 0
    end

    test "a cold pending remote target falls back to the local accent (nothing known yet)",
         %{conn: conn} do
      seed_config("[appearance]\naccent_color = \"teal\"\n")
      target_id = "accent-pending-cold"
      save_target!(target_id)

      # No cache entry — genuinely nothing is known about the target, so the
      # local accent is the best available value.
      {:ok, view, html} = live(conn, ~p"/welcome?node=#{target_id}")

      assert accent_on_layout(html) == ["teal"]
      assert assigns(view).accent_color == "teal"
      assert Map.get(assigns(view), :accent_fetch_seq, 0) == 0
    end
  end
end

# A minimal GenServer that stands in for a real connection manager in
# `EvoGit.RemoteConnection.Registry`, so `EvoGit.RemoteConnection.status/1`
# resolves a configured status for a target id without starting any SSH
# machinery (same idiom as node_aware_test.exs's
# EvoDashWeb.NodeAwareTest.ConnectionManager — duplicated here so this suite
# compiles standalone). The process dies (and its Registry entry is
# auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.AppearanceTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end
