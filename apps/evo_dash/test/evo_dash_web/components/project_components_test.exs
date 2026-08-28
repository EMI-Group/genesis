defmodule EvoDashWeb.ProjectComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ProjectComponents
  alias EvoGit.Core.ForeignRepo

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
        render_component(&ProjectComponents.project_omnibox/1,
          active_project: %{name: "p", path: nil}
        )

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

  # Browse buttons are gated on `tauri_detected and !remote`: the native
  # directory picker runs on the LOCAL dashboard machine (a wx dialog on the
  # local display), so the buttons must not render while viewing a remote node
  # even when the dashboard itself runs inside the Tauri desktop shell. The
  # manual path inputs stay rendered in both contexts.
  describe "browse buttons in remote contexts" do
    test "open-path palette hides the browse button on a remote node but keeps the input" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :open_path,
          tauri_detected: true,
          remote: true
        )

      assert Floki.find(parse(html), "#project-path-browse-button") == []
      assert attribute(html, "#project-path-input", "placeholder") == ["Project path"]
    end

    test "open-path palette keeps the browse button on the local node" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :open_path,
          tauri_detected: true,
          remote: false
        )

      assert attribute(html, "#project-path-browse-button", "phx-hook") == ["DirectoryPicker"]
      assert attribute(html, "#project-path-input", "placeholder") == ["Project path"]
    end

    test "new-project palette hides the browse button on a remote node but keeps the input" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :new_project,
          tauri_detected: true,
          remote: true
        )

      assert Floki.find(parse(html), "#new-project-location-browse-button") == []
      assert attribute(html, "#new-project-path-input", "placeholder") == ["Project path"]
    end

    test "new-project palette keeps the browse button on the local node" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :new_project,
          tauri_detected: true,
          remote: false
        )

      assert attribute(html, "#new-project-location-browse-button", "phx-hook") == [
               "DirectoryPicker"
             ]

      assert attribute(html, "#new-project-path-input", "placeholder") == ["Project path"]
    end

    test "foreign-repo form hides the browse button on a remote node but keeps the input" do
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
          remote: true,
          platform: "linux"
        )

      assert Floki.find(parse(html), "#foreign-repo-path-browse-button") == []
      assert attribute(html, "#foreign-repo-path-input", "phx-hook") == ["PathAutocomplete"]
    end

    test "foreign-repo form keeps the browse button on the local node" do
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
          remote: false,
          platform: "linux"
        )

      assert attribute(html, "#foreign-repo-path-browse-button", "phx-hook") == [
               "DirectoryPicker"
             ]
    end
  end

  # Foreign-repo path input autocomplete wiring: the input carries the
  # PathAutocomplete hook, the `foreign_repo_path_input` change event (debounced
  # 150ms), and a datalist fed by `@foreign_repo_path_suggestions` (local-only
  # suggestions resolved via `Project.path_suggestions/3` in the LiveView).
  describe "foreign repo path input autocomplete" do
    test "input carries hook/list/change/debounce attributes and a datalist" do
      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [],
          foreign_repo_path_suggestions: ["/tmp/alpha", "/tmp/beta"],
          show_add_foreign_repo: true,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      assert attribute(html, "#foreign-repo-path-input", "phx-hook") == ["PathAutocomplete"]

      assert attribute(html, "#foreign-repo-path-input", "list") == [
               "foreign-repo-path-suggestions"
             ]

      assert attribute(html, "#foreign-repo-path-input", "phx-change") == [
               "foreign_repo_path_input"
             ]

      assert attribute(html, "#foreign-repo-path-input", "phx-debounce") == ["150"]

      # The datalist renders one <option> per suggestion
      assert html =~ ~s(<datalist id="foreign-repo-path-suggestions">)
      assert html =~ ~s(<option value="/tmp/alpha"></option>)
      assert html =~ ~s(<option value="/tmp/beta"></option>)
    end
  end

  # Multi-repo read-write foreign repos (writable flag + starting commit):
  # the Add Foreign Repo form carries a `writable` checkbox and a `base_sha`
  # input (value seeded from `new_repo_base_sha`), the repo-list rows render a
  # "Writable" badge + base_sha `<code>` when present, and each non-primary repo
  # row has an edit-in-place flow (`edit_foreign_repo` / `save_foreign_repo` /
  # `cancel_edit_foreign_repo`). The component reads the three new assigns
  # (`new_repo_base_sha`, `editing_foreign_repo_id`, `foreign_repo_edit_form`)
  # defensively so it renders fine when they are absent.
  describe "foreign repo writable/base_sha UI" do
    test "add form renders the writable checkbox and base_sha input with the seeded value" do
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
          new_repo_base_sha: "abc123",
          tauri_detected: false,
          platform: "linux"
        )

      assert [writable_input] = Floki.find(parse(html), "input[name=writable]")
      assert Floki.attribute(writable_input, "type") == ["checkbox"]
      assert Floki.attribute(writable_input, "value") == ["true"]
      # default unchecked
      assert Floki.attribute(writable_input, "checked") == []

      assert [base_sha_input] = Floki.find(parse(html), "input[name=base_sha]")
      assert Floki.attribute(base_sha_input, "value") == ["abc123"]
    end

    test "add form renders an empty base_sha value when new_repo_base_sha is absent" do
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
          tauri_detected: false,
          platform: "linux"
        )

      assert [base_sha_input] = Floki.find(parse(html), "input[name=base_sha]")
      assert Floki.attribute(base_sha_input, "value") == [""]
    end

    test "repo list renders the writable badge and base_sha code for a writable repo" do
      repo = %ForeignRepo{
        id: "original",
        root: "/Source/original",
        description: "The original codebase",
        writable: true,
        base_sha: "abc123"
      }

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      assert [badge] = Floki.find(parse(html), ".badge-warning")
      assert Floki.text(badge) =~ "Writable"

      assert [code] = Floki.find(parse(html), "code")
      assert Floki.text(code) =~ "abc123"
      assert html =~ "/Source/original"
    end

    test "repo list omits the writable badge and base_sha code for a read-only repo" do
      repo = %ForeignRepo{
        id: "original",
        root: "/Source/original",
        writable: false,
        base_sha: nil
      }

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      assert Floki.find(parse(html), ".badge-warning") == []
      assert Floki.find(parse(html), "code") == []
    end

    test "repo rows carry the edit button with the repo id value" do
      repo = %ForeignRepo{id: "original", root: "/Source/original"}

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      assert [edit_btn] = Floki.find(parse(html), "button[phx-click=edit_foreign_repo]")
      assert Floki.attribute(edit_btn, "phx-value-repo_id") == ["original"]
      assert html =~ "hero-pencil"
    end

    test "primary repo row has no edit or remove buttons" do
      repo = %ForeignRepo{id: "primary", root: "/Source/project"}

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      assert Floki.find(parse(html), "button[phx-click=edit_foreign_repo]") == []
      assert Floki.find(parse(html), "button[phx-click=remove_foreign_repo]") == []
    end

    test "editing_foreign_repo_id renders the inline edit form with the edit-form values" do
      repo = %ForeignRepo{id: "original", root: "/Source/original", description: "old"}

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          editing_foreign_repo_id: "original",
          foreign_repo_edit_form: %{
            repo_id: "original",
            path: "/Source/original",
            description: "updated desc",
            writable: true,
            base_sha: "def456"
          },
          tauri_detected: false,
          platform: "linux"
        )

      assert html =~ ~s(phx-submit="save_foreign_repo")
      assert html =~ ~s(phx-click="cancel_edit_foreign_repo")

      # repo_id is read-only display
      assert [repo_id_input] = Floki.find(parse(html), "input[name=repo_id]")
      assert Floki.attribute(repo_id_input, "readonly") != []
      assert Floki.attribute(repo_id_input, "value") == ["original"]

      # path is editable, seeded from the edit form
      assert [path_input] = Floki.find(parse(html), "input[name=path]")
      assert Floki.attribute(path_input, "readonly") == []
      assert Floki.attribute(path_input, "value") == ["/Source/original"]

      # description seeded from the edit form
      assert [desc_input] = Floki.find(parse(html), "input[name=description]")
      assert Floki.attribute(desc_input, "value") == ["updated desc"]

      # writable checkbox checked from the edit form
      assert [writable_input] = Floki.find(parse(html), "input[name=writable]")
      assert Floki.attribute(writable_input, "checked") != []

      # base_sha seeded from the edit form
      assert [base_sha_input] = Floki.find(parse(html), "input[name=base_sha]")
      assert Floki.attribute(base_sha_input, "value") == ["def456"]

      # Save + Cancel buttons
      assert [save_btn] = Floki.find(parse(html), "button[type=submit]")
      assert Floki.text(save_btn) =~ "Save"
      assert html =~ "hero-check"
    end

    test "inline edit form falls back to repo values when the edit-form map is absent" do
      repo = %ForeignRepo{id: "original", root: "/Source/original", description: "old"}

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          editing_foreign_repo_id: "original",
          tauri_detected: false,
          platform: "linux"
        )

      assert html =~ ~s(phx-submit="save_foreign_repo")

      assert [path_input] = Floki.find(parse(html), "input[name=path]")
      assert Floki.attribute(path_input, "value") == ["/Source/original"]

      assert [desc_input] = Floki.find(parse(html), "input[name=description]")
      assert Floki.attribute(desc_input, "value") == ["old"]

      assert [writable_input] = Floki.find(parse(html), "input[name=writable]")
      assert Floki.attribute(writable_input, "checked") == []
    end

    test "nil editing_foreign_repo_id renders no inline edit form" do
      repo = %ForeignRepo{id: "original", root: "/Source/original"}

      html =
        render_component(&ProjectComponents.project_settings_tab/1,
          active_project: "/home/user/project",
          project_config: nil,
          worktree_script: nil,
          commands: %{},
          foreign_repos: [repo],
          show_add_foreign_repo: false,
          new_repo_id: "",
          new_repo_path: "",
          new_repo_description: "",
          tauri_detected: false,
          platform: "linux"
        )

      refute html =~ ~s(phx-submit="save_foreign_repo")
      refute html =~ ~s(phx-click="cancel_edit_foreign_repo")
      # the read view still renders
      assert html =~ "/Source/original"
    end
  end

  # New-project path input autocomplete wiring: the input carries the
  # PathAutocomplete hook, the `new_project_path_input` change event
  # (debounced 150ms), and a datalist fed by `@path_suggestions` — mirroring
  # the open-path palette input and the foreign-repo form.
  describe "new project path input autocomplete" do
    test "input carries hook/list/change/debounce attributes and a datalist" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :new_project,
          path_suggestions: ["/tmp/alpha", "/tmp/beta"]
        )

      assert attribute(html, "#new-project-path-input", "phx-hook") == ["PathAutocomplete"]

      assert attribute(html, "#new-project-path-input", "list") == [
               "new-project-path-suggestions"
             ]

      assert attribute(html, "#new-project-path-input", "phx-change") == [
               "new_project_path_input"
             ]

      assert attribute(html, "#new-project-path-input", "phx-debounce") == ["150"]

      # The single path input carries a neutral placeholder and label — the old
      # two-field form (Location + Project name) is gone.
      assert attribute(html, "#new-project-path-input", "placeholder") == ["Project path"]
      assert html =~ "Project path"
      refute html =~ "Project name"

      # The datalist renders one <option> per suggestion
      assert html =~ ~s(<datalist id="new-project-path-suggestions">)
      assert html =~ ~s(<option value="/tmp/alpha"></option>)
      assert html =~ ~s(<option value="/tmp/beta"></option>)
    end
  end

  # Placeholder neutrality: the palette path inputs (open-path and new-project)
  # use the neutral "Project path" placeholder — no example paths like
  # "/home/user/my-project" baked into the UI.
  describe "neutral placeholders" do
    test "open-path and new-project inputs use the neutral Project path placeholder" do
      open_html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :open_path
        )

      assert attribute(open_html, "#project-path-input", "placeholder") == ["Project path"]
      refute open_html =~ "/home/user"
      refute open_html =~ "my-project"

      new_html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :new_project
        )

      assert attribute(new_html, "#new-project-path-input", "placeholder") == ["Project path"]
      refute new_html =~ "/home/user"
      refute new_html =~ "my-project"
    end
  end

  # Remote-context palette actions: "Create New Project" is a local dashboard
  # concern (it creates directories on the local filesystem), so it is hidden in
  # remote contexts while "Open Project by Path" stays available.
  describe "palette actions in remote contexts" do
    test "remote palette hides Create New Project but keeps Open by Path" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :menu,
          remote: true
        )

      assert html =~ "Open Project by Path"
      refute html =~ "Create New Project"
    end

    test "local palette shows both actions" do
      html =
        render_component(&ProjectComponents.project_omnibox/1,
          palette_open: true,
          palette_mode: :menu
        )

      assert html =~ "Open Project by Path"
      assert html =~ "Create New Project"
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
