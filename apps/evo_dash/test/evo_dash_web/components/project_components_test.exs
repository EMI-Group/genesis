defmodule EvoDashWeb.ProjectComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ProjectComponents

  # Component-level tests for the command-palette project selector
  # (`project_omnibox/1`): the client-side wiring that makes keyboard
  # navigation and click-outside-to-close work, plus the trigger rendering.
  #
  # Background: LiveView's keydown handler fires ONLY when the event target
  # (the focused element) itself carries `phx-keydown` — it does NOT walk
  # ancestors — so the binding must live on the search input, not the overlay
  # div. Click-outside is guaranteed by `phx-click-away` on the overlay (the
  # fixed backdrop alone is unreliable: it paints below the sidebar and was
  # trapped in the topbar's `backdrop-filter` containing block).
  describe "project_omnibox/1 rendering" do
    test "trigger renders the active project name and path" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          active_project: %{name: "my-project", path: "/home/user/my-project"}
        )

      assert html =~ "my-project"
      assert html =~ "/home/user/my-project"
    end

    test "trigger renders the placeholder when no project is active" do
      html = render_component(&ProjectComponents.project_omnibox/1, active_project: nil)

      assert html =~ "Open a project..."
    end

    test "trigger keeps the enlarged typography classes" do
      html =
        render_component(&ProjectComponents.project_omnibox/1, active_project: %{name: "p", path: nil})

      assert trigger_class(html) =~ "px-4"
      assert trigger_class(html) =~ "py-2"
      assert html =~ ~s(class="text-base font-bold text-base-content truncate leading-tight")
    end

    test "palette search input carries the palette_keydown binding" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :menu
        )

      assert attribute(html, "input#palette-search-input", "phx-keydown") == [
               "palette_keydown"
             ]

      # Keydown and search-filter change coexist on the same input.
      assert attribute(html, "input#palette-search-input", "phx-change") == ["palette_search"]
    end

    test "palette overlay carries phx-click-away with the close event" do
      html = render_component(&ProjectComponents.project_omnibox/1, palette_open: true)

      assert attribute(html, ".project-palette-overlay", "phx-click-away") == [
               "close_project_palette"
             ]

      # The backdrop uses the same close event name.
      assert attribute(html, ".project-palette-backdrop", "phx-click") == [
               "close_project_palette"
             ]
    end
  end

  # Directory picker browse buttons (Tauri desktop only).
  #
  # Regression guard: these buttons used to carry BOTH `phx-click="pick_directory"`
  # and `phx-hook="DirectoryPicker"`. The hook owns the click (opens the native
  # dialog and fills the input directly) but the leftover phx-click also fired a
  # "pick_directory" event to the server, which had no handle_event/3 clause —
  # crashing the LiveView in the desktop app. The buttons must keep the hook and
  # have NO phx-click binding.
  describe "directory picker browse buttons" do
    test "open-path browse button keeps the hook but has no phx-click binding" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :open_path,
          tauri_detected: true
        )

      assert attribute(html, "#project-path-browse-button", "phx-hook") == ["DirectoryPicker"]
      assert attribute(html, "#project-path-browse-button", "phx-click") == []
    end

    test "new-project browse button keeps the hook but has no phx-click binding" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :new_project,
          tauri_detected: true
        )

      assert attribute(html, "#new-project-location-browse-button", "phx-hook") == [
               "DirectoryPicker"
             ]

      assert attribute(html, "#new-project-location-browse-button", "phx-click") == []
    end

    test "foreign-repo browse button keeps the hook but has no phx-click binding" do
      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [],
          show_add_foreign_repo: true,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: true,
          platform: "linux"
        )

      assert attribute(html, "#foreign-repo-path-browse-button", "phx-hook") == [
               "DirectoryPicker"
             ]

      assert attribute(html, "#foreign-repo-path-browse-button", "phx-click") == []
    end
  end

  # --- helpers ---

  defp trigger_class(html) do
    [btn] = Floki.find(parse(html), ".project-palette-trigger")
    btn |> Floki.attribute("class") |> List.first() |> to_string()
  end

  defp attribute(html, selector, attr) do
    [el] = Floki.find(parse(html), selector)
    el |> Floki.attribute(attr) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
