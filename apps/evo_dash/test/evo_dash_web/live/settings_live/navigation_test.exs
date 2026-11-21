# `/settings` category-NAVIGATION contract.
#
# Two modules on purpose (the suite's async policy, `test/CONTEXT.md`):
#
#   * `EvoDashWeb.SettingsLive.NavigationTest` — ASYNC, pure: every assertion is
#     a plain function call on `EvoDashWeb.SettingsLive.Navigation` (no
#     LiveView, no config dir, no app-env).
#   * `EvoDashWeb.SettingsLive.NavigationLiveTest` — SYNC (`async: false`)
#     because it drives the platform/nix gating through the BEAM-GLOBAL app-env
#     seams `:platform_os_override` and `:nix_available_override`, which the
#     `async: true` `EvoDashWeb.PlatformInfoTest` / `system_live_test` also read
#     (and which `EvoDashWeb.SettingsLiveGlobalStateTest` mutates too). ExUnit
#     drains every async module before any sync one, so the flip can never
#     overlap another test.
#
# A minimal connection manager (below the async module) stands in for a real
# remote target in the one node-context test; same pattern as
# `settings_live_test.exs` / `projects_live_test.exs`.
defmodule EvoDashWeb.SettingsLive.NavigationTest do
  @moduledoc """
  Pure unit pins for the category-navigation helpers extracted out of
  `EvoDashWeb.SettingsLive`.

  The invariants under test are the ones the `/settings` sidebar depends on:
  no resolution may ever yield a category absent from the map it was resolved
  against (that is what made the sidebar advertise platform-gated categories
  and then snap the highlight back), and the URL built for a category click
  must carry the category and the current `?node=`.
  """
  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsLive.Navigation

  # A local-context nav: the `:llm` default plus two ordinary categories.
  defp nav, do: %{llm: [], scheduler: [], tools: []}

  # A nav WITHOUT `:llm` — the fallback must then be the first available
  # category, never `nil` and never `:llm`.
  defp nav_without_llm, do: %{agents: [], remote_connections: []}

  describe "resolve/3" do
    test "returns the requested category when the map has it" do
      assert Navigation.resolve("scheduler", :llm, nav()) == :scheduler
      assert Navigation.resolve("agents", :llm, nav_without_llm()) == :agents
      # The two dashboard-only pseudo-categories are ordinary map keys.
      assert Navigation.resolve("remote_connections", :llm, nav_without_llm()) ==
               :remote_connections
    end

    test "falls back to :llm for a gated or unknown category" do
      # `:sandbox`/`:nix` are the platform-gated categories: when the filter
      # dropped them they are simply absent, and so is any forged value.
      assert Navigation.resolve("sandbox", :llm, nav()) == :llm
      assert Navigation.resolve("nix", :llm, nav()) == :llm
      assert Navigation.resolve("totally_fake_category", :llm, nav()) == :llm
      assert Navigation.resolve(nil, :llm, nav()) == :llm
      assert Navigation.resolve(:not_a_binary, :llm, nav()) == :llm
    end

    test "falls back to the fallback category while it is displayable" do
      assert Navigation.resolve(nil, :scheduler, nav()) == :scheduler
      assert Navigation.resolve("sandbox", :scheduler, nav()) == :scheduler
      # ... but never to a category the map does not have.
      assert Navigation.resolve(nil, :sandbox, nav()) == :llm
    end

    test "never returns a key absent from the map" do
      for schemas <- [nav(), nav_without_llm(), %{sandbox: []}],
          param <- [nil, "", "llm", "sandbox", "nix", "agents", "bogus", :llm, 42],
          fallback <- [nil, :llm, :sandbox, :scheduler, :agents] do
        resolved = Navigation.resolve(param, fallback, schemas)

        assert Map.has_key?(schemas, resolved),
               "resolve/3 returned #{inspect(resolved)} for #{inspect(schemas)}"
      end
    end

    test "an empty map degrades to :llm instead of returning nil" do
      assert Navigation.resolve("scheduler", :scheduler, %{}) == :llm
      assert Navigation.resolve(nil, nil, %{}) == :llm
    end

    test "total on garbage schemas" do
      for schemas <- [nil, :nope, "x", [], 42] do
        assert Navigation.resolve("llm", :llm, schemas) == :llm
        assert Navigation.category_from_param("llm", schemas) == nil
        assert Navigation.seed(%{"category" => "llm"}, :llm, schemas) == :llm
      end
    end
  end

  describe "seed/3" do
    test "opens an explicit displayable ?category= with no fallback involved" do
      assert Navigation.seed(%{"category" => "scheduler"}, :llm, nav()) == :scheduler
      assert Navigation.seed(%{"category" => "tools"}, :llm, nav()) == :tools
    end

    test "never returns a gated category, even when the shell asks for one" do
      assert Navigation.seed(%{"category" => "sandbox"}, :llm, nav()) == :llm
      assert Navigation.seed(%{"category" => "nix"}, :llm, nav()) == :llm
      assert Navigation.seed(%{"category" => "sandbox"}, :scheduler, nav()) == :scheduler
    end

    test "keeps the current category when the params carry none" do
      assert Navigation.seed(%{}, :scheduler, nav()) == :scheduler
      assert Navigation.seed(%{"node" => "abc"}, :tools, nav()) == :tools
      assert Navigation.seed(%{"category" => nil}, :scheduler, nav()) == :scheduler
    end

    test "drops a current category that is no longer displayable" do
      # A node switch to a platform that has no sandbox: the seeded render must
      # fall back instead of opening a section that no longer exists.
      assert Navigation.seed(%{}, :sandbox, nav()) == :llm
      assert Navigation.seed(%{}, :sandbox, nav_without_llm()) == :agents
    end

    test "total on garbage params" do
      for params <- [nil, :nope, "x", [], %{}, %{category: "scheduler"}] do
        assert Navigation.seed(params, :llm, nav()) in [:llm, :scheduler]
      end
    end
  end

  describe "category_from_param/2" do
    test "whitelists strings against the map and rejects everything else" do
      assert Navigation.category_from_param("scheduler", nav()) == :scheduler
      assert Navigation.category_from_param("sandbox", nav()) == nil
      assert Navigation.category_from_param("", nav()) == nil
      assert Navigation.category_from_param(nil, nav()) == nil
      assert Navigation.category_from_param(:scheduler, nav()) == :scheduler
      assert Navigation.category_from_param(:sandbox, nav()) == nil
      assert Navigation.category_from_param(%{}, nav()) == nil
    end
  end

  describe "path/2" do
    test "carries the category" do
      assert Navigation.path(:llm, %{}) == "/settings?category=llm"
      assert Navigation.path(:remote_connections, %{}) == "/settings?category=remote_connections"
      assert Navigation.path(:appearance, nil) == "/settings?category=appearance"
    end

    test "preserves ?node= and URL-encodes both parts" do
      assert Navigation.path(:scheduler, %{"node" => "target-1"}) ==
               "/settings?category=scheduler&node=target-1"

      assert Navigation.path(:"a b", %{"node" => "a b"}) ==
               "/settings?category=a+b&node=a+b"

      # A blank/absent node is not appended.
      assert Navigation.path(:llm, %{"node" => nil}) == "/settings?category=llm"
      assert Navigation.path(:llm, %{"node" => ""}) == "/settings?category=llm"
      # Atom-keyed params (the handle_params map narrowed for a push_patch).
      assert Navigation.path(:llm, %{node: "target-1"}) ==
               "/settings?category=llm&node=target-1"
    end

    test "returns the bare page for a nil category" do
      assert Navigation.path(nil, %{"node" => "target-1"}) == "/settings"
      assert Navigation.path(nil, %{}) == "/settings"
    end
  end

  describe "visible?/2 and available_categories/1" do
    test "visibility is map membership only" do
      assert Navigation.visible?(:llm, nav())
      refute Navigation.visible?(:sandbox, nav())
      refute Navigation.visible?(nil, nav())
      refute Navigation.visible?("llm", nav())
      refute Navigation.visible?(:llm, nil)
    end

    test "available categories are stable and sorted" do
      assert Navigation.available_categories(nav()) == [:llm, :scheduler, :tools]
      assert Navigation.available_categories(nil) == []
    end
  end
end

defmodule EvoDashWeb.SettingsLive.NavigationLiveTest.ConnectionManager do
  @moduledoc false
  # Stands in for a real remote connection manager in
  # `EvoGit.RemoteConnection.Registry` (same pattern as
  # `EvoDashWeb.SettingsLiveTest.ConnectionManager`): answers `:status` with a
  # `:connected` phase so `?node=<id>` resolves to the remote BEAM node atom.
  use GenServer

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end

defmodule EvoDashWeb.SettingsLive.NavigationLiveTest do
  @moduledoc """
  End-to-end pins for `/settings` category navigation:

    * the sidebar a page SEEDS (the shell render) and the sidebar it SETTLES on
      are the same, never advertise a platform-gated category, and are never
      empty;
    * clicking any rendered item opens its `#category-<cat>` pane, marks it
      active, and round-trips the choice through `?category=` in the URL;
    * a later `handle_params/3` for the SAME params cannot undo the selection,
      and an unknown/gated value is a no-op that does not rewrite the URL.
  """
  # SYNC (`async: false`): these tests flip the BEAM-GLOBAL app-env seams
  # `:platform_os_override` and `:nix_available_override`, read by the
  # `async: true` `EvoDashWeb.PlatformInfoTest` / `system_live_test` as well.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsLive.Navigation

  # Load-tolerant wait budget for the page's ASYNC node-data load (it runs on a
  # supervised task and reads config from disk). The wait stays bounded.
  @async_wait_budget_ms 30_000

  setup do
    # Per-process config isolation through the `:config_dir_fun` seam — never an
    # `XDG_CONFIG_HOME` write — so an empty config dir is guaranteed.
    EvoDash.Test.ConfigDir.isolate!("evogit_settings_nav_test_config")

    # Default: the nix category is displayable, so the nav is host-independent
    # (the gating tests below flip it off and restore it in their own on_exit).
    Application.put_env(:evo_dash, :nix_available_override, true)
    on_exit(fn -> Application.delete_env(:evo_dash, :nix_available_override) end)

    EvoDash.ActiveTasks.reset()
    :ok
  end

  describe "sidebar stability" do
    test "the seeded and settled nav agree and never advertise a gated category", %{conn: conn} do
      with_os_override(:windows)
      with_nix_available(false)

      {:ok, view, seeded_html} = live(conn, ~p"/settings")

      # The SEEDED shell (before the async node-data result) must already be
      # platform-correct: no gated category is advertised, and the nav is not
      # empty.
      seeded = nav_categories(seeded_html)
      assert seeded != []
      refute "sandbox" in seeded
      refute "nix" in seeded
      assert "llm" in seeded

      # ... and the settled page renders the SAME nav (it never shrinks, grows
      # or loses its active item once the filtered result lands).
      settled_html = await_node_data(view)
      assert nav_categories(settled_html) == seeded
      assert active_nav_category(settled_html) == "llm"
      assert settled_html =~ ~s(id="category-llm")
    end

    test "the nav never collapses when the previously active category is gated", %{conn: conn} do
      with_os_override(:windows)
      with_nix_available(false)

      {:ok, view, _html} = live(conn, ~p"/settings")
      # `?category=sandbox` cannot be honoured on this platform: the shell falls
      # back to the default instead of rendering a section-less/empty sidebar.
      html = patch_to(view, "/settings?category=sandbox")

      assert active_nav_category(html) == "llm"
      assert nav_categories(html) != []
      refute "sandbox" in nav_categories(html)
      assert html =~ ~s(id="category-llm")
    end
  end

  describe "select_category" do
    test "every rendered item opens its pane, stays active and round-trips the URL", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = await_node_data(view)
      categories = nav_categories(html)
      assert categories != []

      for category <- categories do
        html =
          view
          |> element(~s(button[phx-value-category="#{category}"]))
          |> render_click()

        # The URL now names the category (the single source of truth for a later
        # handle_params) ...
        assert_patch(view, "/settings?category=#{category}")
        # ... the clicked item is the active one ...
        assert active_nav_category(html) == category
        # ... the sidebar is intact and non-empty ...
        assert nav_categories(html) == categories
        # ... and its content pane actually rendered.
        assert html =~ ~s(id="category-#{category}")
      end
    end

    test "an unknown or gated value is a no-op (no URL rewrite, no nav change)", %{conn: conn} do
      with_os_override(:windows)

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = await_node_data(view)
      assert active_nav_category(html) == "llm"

      for value <- ["totally_fake_category", "sandbox", ""] do
        html = render_hook(view, "select_category", %{"category" => value})

        # The click was dropped: same category, same nav, same pane.
        assert active_nav_category(html) == "llm"
        assert html =~ ~s(id="category-llm")
        assert nav_categories(html) != []
      end

      # Nothing was pushed: the URL is never rewritten to a hidden category.
      refute_patched(view)
    end

    test "a later handle_params with the same params cannot undo the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      await_node_data(view)

      html =
        view
        |> element(~s(button[phx-value-category="scheduler"]))
        |> render_click()

      assert_patch(view, "/settings?category=scheduler")
      assert active_nav_category(html) == "scheduler"

      # Re-running handle_params for the SAME URL (the node-switch /
      # connection-status / retry path) must leave the selection alone.
      html = patch_to(view, "/settings?category=scheduler")
      assert active_nav_category(html) == "scheduler"
      assert html =~ ~s(id="category-scheduler")

      # Same for a params change that does NOT carry a category (the
      # connection-status patch appends only `?node=`): the visible category is
      # kept rather than silently reset.
      html = patch_to(view, "/settings")
      assert active_nav_category(html) == "scheduler"
      assert html =~ ~s(id="category-scheduler")
    end

    test "a category click preserves the ?node= context in the URL", %{conn: conn} do
      target_id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLive.NavigationLiveTest.ConnectionManager,
         {target_id, %{phase: :connected, node: "genesis_remote_nav@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/settings?node=" <> target_id)
      assert current_node(view) == :"genesis_remote_nav@127.0.0.1"

      view
      |> element(~s(button[phx-value-category="scheduler"]))
      |> render_click()

      assert_patch(view, "/settings?category=scheduler&node=#{target_id}")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp with_os_override(os) do
    Application.put_env(:evo_dash, :platform_os_override, os)
    on_exit(fn -> Application.delete_env(:evo_dash, :platform_os_override) end)
  end

  defp with_nix_available(bool) do
    Application.put_env(:evo_dash, :nix_available_override, bool)
    on_exit(fn -> Application.delete_env(:evo_dash, :nix_available_override) end)
  end

  defp save_target! do
    id = "settings-nav-test-target-#{System.unique_integer([:positive])}"

    {:ok, _target} =
      EvoGit.RemoteConnections.save(%{
        ssh_target: "user@host",
        id: id,
        name: "Settings Nav Test Target"
      })

    on_exit(fn -> EvoGit.RemoteConnections.delete(id) end)
    id
  end

  # Waits until THIS view's supervised async loads have exited, then renders —
  # `render/1` is a synchronous round-trip, so every queued result message
  # (including the node-data apply) is processed first.
  defp await_node_data(view) do
    view.pid
    |> async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @async_wait_budget_ms -> :ok
      end
    end)

    render(view)
  end

  defp async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  defp callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end

  # A `handle_params`-re-running patch (what a node switch / connection-status
  # broadcast does), identical to `render_patch/2` but readable here.
  defp patch_to(view, path), do: render_patch(view, path)

  defp current_node(view),
    do: :sys.get_state(view.pid, @async_wait_budget_ms).socket.assigns[:current_node]

  # The categories the sidebar renders, in DOM order (one button each, carrying
  # `phx-value-category`).
  defp nav_categories(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(button[phx-value-category]))
    |> Enum.map(fn button -> button |> Floki.attribute("phx-value-category") |> List.first() end)
  end

  # The category whose sidebar button carries the active styling.
  defp active_nav_category(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(button[phx-value-category]))
    |> Enum.filter(fn button ->
      button |> Floki.attribute("class") |> Enum.join(" ") =~ "bg-primary "
    end)
    |> Enum.map(fn button -> button |> Floki.attribute("phx-value-category") |> List.first() end)
    |> List.first()
  end
end
