defmodule EvoDashWeb.LayoutHeightContractTest do
  # async: true — this module only READS rendered markup. Its config-dir
  # isolation rides the per-process `:config_dir_fun` seam
  # (`EvoDash.Test.ConfigDir.isolate!/1`, inherited through `$callers` by the
  # mounted view and its supervised load tasks), so it forces no BEAM-global.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The in-shell height contract (see assets/css/CONTEXT.md):
  # the app shell — `body` + `#app-layout` (`h-dvh`, `overflow-hidden`) +
  # `#shell-row` (`flex flex-1 min-h-0 min-w-0`) + `#sidebar` — is the ONLY
  # owner of the viewport height. `main#main-content` is a definite-height flex
  # child of that chain, and an in-shell page that has to fill it gets the
  # `.shell-fill` utility (`height: 100%; min-height: 0`) instead of computing
  # its own viewport math. In desktop mode `#app-layout`'s FIRST child is the
  # in-flow `#desktop-titlebar` strip, so `#shell-row` owns the REMAINING
  # height; a browser shell renders no strip at all and reserves no space for
  # one. This suite pins the RENDERED half of the contract; the static-source
  # half (CSS rules included) lives in assets/css/layout_contract.test.cjs,
  # which is the only place allowed to grep source text.

  # The shell's container ids this contract owns, in DOCUMENT order. The exact
  # list equality below therefore pins both "rendered exactly once" and the
  # nesting order of the whole height chain.
  @shell_ids ["app-layout", "shell-row", "sidebar", "workbench-left-resize", "main-content"]

  setup do
    # Both pages below render the full `Layouts.app` shell, and `/dashboard`
    # additionally gates on `EvoGit.Config.VersionState.onboarding_needed?/0`
    # (a first-run mount redirects to /welcome). Isolate the config dir per
    # test and mark onboarding complete, exactly like the projects suite does.
    EvoDash.Test.ConfigDir.isolate!("evogit_layout_height_contract_config")
    EvoGit.Config.VersionState.complete_onboarding()

    :ok
  end

  describe "in-shell height contract" do
    test "the shared shell owns the viewport height exactly once", %{conn: conn} do
      # The cheap page for a shell assertion: `/agents` needs no project, no
      # task-store row and no live agent — its page load runs off-process
      # behind the default runners, so the shell markup is on screen on the
      # very first render.
      {:ok, _view, html} = live(conn, ~p"/agents")
      doc = Floki.parse_document!(html)

      assert shell_ids(html) == @shell_ids,
             "the shell must render each of #{inspect(@shell_ids)} exactly ONCE, " <>
               "in that document order"

      assert html =~ ~r/<div[^>]*\bid="app-layout"[^>]*>/

      assert shell_layout_has?(html, "h-dvh", ["h-dvh", "overflow-hidden", "flex-col"]),
             "#app-layout must be the `flex h-dvh overflow-hidden flex-col` shell " <>
               "(a column: the title-bar slot above the shell row)"

      # `#shell-row` is the ONE flex row below the (desktop-only) title-bar
      # slot: `#sidebar`, `#workbench-left-resize` and `.workbench-main` are its
      # SIBLINGS, which `workbench.css` relies on (`#sidebar +
      # #workbench-left-resize`, `#sidebar ~ .workbench-main`).
      assert [shell_row] = Floki.find(doc, "#app-layout > #shell-row"),
             "#shell-row must be the one direct child of #app-layout holding the shell row"

      assert [_sidebar] = Floki.find(shell_row, "aside#sidebar"),
             "#sidebar must be a child of #shell-row"

      assert [_resize] = Floki.find(shell_row, "#workbench-left-resize"),
             "#workbench-left-resize must be a child of #shell-row"

      assert [_workbench_main] = Floki.find(shell_row, ".workbench-main"),
             ".workbench-main must be a child of #shell-row"

      assert class_has_all?(element_with_id(html, "shell-row"), "flex-1", [
               "flex",
               "flex-1",
               "min-h-0",
               "min-w-0"
             ]),
             "#shell-row must be the `flex flex-1 min-h-0 min-w-0` row that takes " <>
               "the height left under the title bar"

      # The fixed mobile drawer keeps the full VIEWPORT height; only the desktop
      # sidebar starts below the strip, so `lg:h-full` fills `#shell-row`
      # instead there.
      assert class_has_all?(element_with_id(html, "sidebar"), "h-dvh", ["h-dvh", "lg:h-full"]),
             "#sidebar must be `h-dvh lg:h-full` (mobile drawer full viewport, " <>
               "desktop sidebar under the title-bar slot)"

      assert offset_of!(html, ~s(id="app-layout")) < offset_of!(html, ~s(id="main-content")),
             "#main-content must be nested INSIDE #app-layout, not beside it"

      # Document order of the whole chain, on the rendered bytes.
      chain_offsets =
        for needle <- [
              ~s(id="app-layout"),
              ~s(id="shell-row"),
              ~s(id="sidebar"),
              ~s(id="workbench-left-resize"),
              ~s(class="workbench-main"),
              ~s(id="main-content")
            ],
            do: offset_of!(html, needle)

      assert chain_offsets == Enum.sort(chain_offsets),
             "the rendered chain must read #app-layout → #shell-row → #sidebar → " <>
               "#workbench-left-resize → .workbench-main → #main-content"

      assert html =~ ~r/<header[^>]*class="workbench-top"/
      assert html =~ ~r/<body[^>]*class="[^"]*\bh-dvh\b/
    end

    test "a browser shell renders no desktop title bar and reserves no strip space", %{
      conn: conn
    } do
      # `@desktop?` is seeded by `LiveHooks.UpdateStatus` from
      # `config :evo_dash, :desktop_release` / `EVOGIT_DESKTOP`, both false in
      # the test env. It is NEVER flipped here through app env: this module is
      # `async: true`, so a global write would leak the strip into other
      # suites' concurrent mounts. (The per-OS control matrix — which strip
      # renders minimize/maximize/close — is covered by
      # test/evo_dash_web/components/layouts_test.exs.)
      {:ok, _view, html} = live(conn, ~p"/agents")

      refute html =~ ~s(id="desktop-titlebar"),
             "a browser shell must not render the desktop title bar strip"

      refute html =~ "data-tauri-drag-region",
             "the DesktopTitlebar hook owns dragging, so no element may advertise a Tauri drag region"

      refute html =~ ~r/id="desktop-titlebar-[^"]+"/,
             "the window controls (minimize/maximize/close) must not render in a browser"

      doc = Floki.parse_document!(html)

      assert [] == Floki.attribute(doc, "#app-layout", "data-desktop"),
             "a browser shell must not mark #app-layout with data-desktop"

      # The absence above is not vacuous: the browser shell still renders the
      # one flex row, so the missing strip is an OMITTED slot, not a missing
      # shell (and therefore no height is reserved for it).
      assert [_shell_row] = Floki.find(doc, "#app-layout > #shell-row")
    end

    test "the agents page root fills main via shell-fill and carries no viewport math", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert class_has_all?(html, "agents-page-layout", ["agents-page-layout", "shell-fill"]),
             "the agents page root must be `class=\"agents-page-layout shell-fill …\"`"

      refute html =~ "100vh", "the agents page must not compute height from 100vh"
      refute html =~ "100dvh", "the agents page must not compute height from 100dvh"
    end

    test "the LiveDashboard iframe fills main via shell-fill, not calc(100vh - …)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      iframe = Regex.run(~r/<iframe\b[^>]*>/, html) |> List.first()

      assert iframe,
             "the LiveDashboard route must render an <iframe> inside the shell"

      assert iframe =~ ~r/class="[^"]*\bshell-fill\b/,
             "the LiveDashboard iframe must carry shell-fill instead of its own height math"

      refute iframe =~ "min-height: calc(100vh",
             "the LiveDashboard iframe must not size itself from the viewport"
    end
  end

  # The shell ids this contract owns, in document order.
  # `aside` is included for `#sidebar`, and `(?<![\w-])` keeps
  # `data-node-id="local"` / `aria-controls="sidebar"` from matching as `id`.
  defp shell_ids(html) do
    ~r/<(?:div|main|aside)\b[^>]*?(?<![\w-])id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.filter(&(&1 in @shell_ids))
  end

  # The opening tag of the one element carrying `id="<id>"`, so the class
  # assertions below are scoped to THAT element instead of any tag on the page.
  defp element_with_id(html, id) do
    case Regex.run(~r/<(?:div|main|aside)\b[^>]*?\bid="#{id}"[^>]*>/, html) do
      [element] -> element
      nil -> flunk("the shell must render ##{id}")
    end
  end

  # Byte offset of `needle` in the rendered markup — flunks (rather than
  # returning nil) when the shell stopped rendering it.
  defp offset_of!(html, needle) do
    case :binary.match(html, needle) do
      {at, _} -> at
      :nomatch -> flunk("the shell must render #{needle}")
    end
  end

  # The class attribute of the `#app-layout` element holds ALL of `tokens`.
  defp shell_layout_has?(html, anchor, tokens) do
    case Regex.run(~r/<div[^>]*\bid="app-layout"[^>]*>/, html) do
      [element] -> class_has_all?(element, anchor, tokens)
      nil -> flunk("the shell must render #app-layout")
    end
  end

  # `tokens` must all appear inside ONE class attribute that also holds
  # `anchor` — order-independent, so re-ordering the utilities stays green
  # while dropping a token fails.
  defp class_has_all?(html, anchor, tokens) do
    Regex.scan(~r/class="([^"]*)"/, html)
    |> Enum.map(fn [_, value] -> String.split(value) end)
    |> Enum.any?(fn classes ->
      anchor in classes and Enum.all?(tokens, &(&1 in classes))
    end)
  end
end
