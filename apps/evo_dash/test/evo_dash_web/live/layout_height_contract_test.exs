defmodule EvoDashWeb.LayoutHeightContractTest do
  # async: true — this module only READS rendered markup. Its config-dir
  # isolation rides the per-process `:config_dir_fun` seam
  # (`EvoDash.Test.ConfigDir.isolate!/1`, inherited through `$callers` by the
  # mounted view and its supervised load tasks), so it forces no BEAM-global.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The in-shell height contract (see assets/css/CONTEXT.md):
  # the app shell — `body` + `#app-layout` (`h-dvh`) + `#sidebar` — is the ONLY
  # owner of the viewport height. `main#main-content` is a definite-height flex
  # child of that chain, and an in-shell page that has to fill it gets the
  # `.shell-fill` utility (`height: 100%; min-height: 0`) instead of computing
  # its own viewport math. This suite pins the RENDERED half of the contract;
  # the static-source half (CSS rules included) lives in
  # assets/css/layout_contract.test.cjs, which is the only place allowed to
  # grep source text.

  setup do
    # Both pages below render the full `Layouts.app` shell, and `/dashboard`
    # additionally gates on `EvoGit.Config.VersionState.onboarding_needed?/0`
    # (a first-run mount redirects to /welcome). Isolate the config dir per
    # test and mark onboarding complete, exactly like the projects suite does.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_layout_height_contract_config")
    EvoGit.Config.VersionState.complete_onboarding()
    on_exit(fn -> File.rm_rf!(dir) end)

    :ok
  end

  describe "in-shell height contract" do
    test "the shared shell owns the viewport height exactly once", %{conn: conn} do
      # The cheap page for a shell assertion: `/agents` needs no project, no
      # task-store row and no live agent — its page load runs off-process
      # behind the default runners, so the shell markup is on screen on the
      # very first render.
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert shell_ids(html) == ["app-layout", "main-content"],
             "#main-content must be rendered ONCE, inside the h-dvh #app-layout chain"

      app_layout_at = :binary.match(html, ~s(id="app-layout")) |> elem(0)
      main_content_at = :binary.match(html, ~s(id="main-content")) |> elem(0)

      assert app_layout_at < main_content_at,
             "#main-content must be nested INSIDE #app-layout, not beside it"

      assert html =~ ~r/<div[^>]*\bid="app-layout"[^>]*>/
      assert shell_layout_has?(html, "h-dvh", "overflow-hidden")
      assert html =~ ~r/<header[^>]*class="workbench-top"/
      assert html =~ ~r/<body[^>]*class="[^"]*\bh-dvh\b/
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
  # `(?<![\w-])` keeps `data-node-id="local"` from matching as `id`.
  defp shell_ids(html) do
    ~r/<(?:div|main)\b[^>]*?(?<![\w-])id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.filter(&(&1 in ["app-layout", "main-content"]))
  end

  # The class attribute of the `#app-layout` element holds BOTH tokens.
  defp shell_layout_has?(html, first, second) do
    case Regex.run(~r/<div[^>]*\bid="app-layout"[^>]*>/, html) do
      [element] -> class_has_all?(element, first, [first, second])
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
