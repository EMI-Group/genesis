defmodule EvoDashWeb.LiveHooks.AppearanceTest do
  # Tests for the global Appearance on-mount hook (EvoDashWeb.LiveHooks.Appearance):
  #
  # 1. Unit tests for the pure seams resolve_accent/1 + accent_from_config/1 —
  #    no LiveView needed.
  # 2. Dead-render on_mount seeding: Appearance.on_mount/4 invoked directly on a
  #    minimal boot-shaped socket (router + lifecycle private — see the helper
  #    comment) seeds @accent_color == "blue" via assign_new when no assign
  #    exists, preserves a pre-existing assign, and attaches the
  #    :handle_params/:handle_info interceptors.
  # 3. LiveView integration on pages that render through Layouts.app (the
  #    #app-layout shell div): the initial connected render carries
  #    data-accent-color; a NON-default local accent ("teal") from the user
  #    config is visible SYNCHRONOUSLY on that initial render (local resolution
  #    happens in the attached :handle_params interceptor — no async flush
  #    needed); a fresh empty config yields the schema default "blue". Mounting
  #    /welcome AND /system proves the hook is registered on every LiveView
  #    (the `live_view/0` macro registers it after NodeAware).
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

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

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

    test "seeds @accent_color \"blue\" via assign_new when no assign exists" do
      assert {:cont, socket} = Appearance.on_mount(:default, %{}, %{}, hook_socket())

      assert socket.assigns.accent_color == "blue"
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
end
