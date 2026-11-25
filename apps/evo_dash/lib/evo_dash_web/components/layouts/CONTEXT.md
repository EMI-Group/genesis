# Root HTML Layout

## Intent
`root.html.heex` provides the shared document shell for every dashboard route, including `/assistant` (the legacy `/help` route 302-redirects there), without page-specific chat markup.

## API Surface
The template renders `@inner_content`, a localized live title, relative tracked CSS/JS assets, CSRF and locale metadata, and favicon/mobile-web-app metadata.
Its synchronous head script resolves light/dark/system themes before paint through `html[data-theme]` and `html[data-theme-mode]`, persists `phx:theme`, and applies `phx:set-theme`, OS and cross-tab changes immediately without a view transition.
The same script persists locale via `phx:locale` and a cookie, maintains RTL direction, and handles `phx:set-locale` and `phx:persist_locale` with distinct reload semantics.

## Constraints
Preserve `@inner_content`, CSRF metadata, tracked relative assets, `#favicon`, theme attributes/event names/storage keys, and locale metadata/event names/cookie behavior when polishing visuals.
The body uses `bg-base-200 text-base-content antialiased h-dvh overflow-hidden selection:bg-primary/30`; its fixed viewport and hidden overflow underpin the nested shell/page scroll contract.
The shell height chain below it is `#app-layout` (`flex h-dvh overflow-hidden`) → `.workbench-main` → `.workbench-center` → `<header class="workbench-top">` (`flex: 0 0 var(--shell-topbar-h)`, the top bar's one height definition in `../../../../assets/css/workbench.css`) → `.workbench-content-stack` (grid, `flex: 1; min-height: 0`) → `#main-scroll` (`flex-1 flex flex-col overflow-auto`, the only page scroller) → `#desktop-quit-hook` (`flex-1 flex flex-col min-h-0`) → `main#main-content` (`flex-1 min-h-0` plus `py-4`).
`main#main-content` therefore has a DEFINITE height (viewport − top bar − its own padding): a page that must fill it uses the `.shell-fill` utility (`height: 100%; min-height: 0`) and its children bound themselves with `flex: 1 1 0; min-height: 0`, never with a viewport unit.
`.workbench-window-page` is the exception — it is the settings window's own iframe document and sizes against that document's viewport.
Keep `viewport-fit=cover` and `interactive-widget=resizes-content` for mobile safe-area and keyboard-aware layout behavior.
The light/dark `theme-color` literals (`#f6f5f4` and `#242424`) match Adwaita shell chrome and should stay coordinated with theme CSS.
Page-specific simplification of `/assistant` belongs in the Home LiveView, while sidebar/navigation chrome belongs in the sibling `layouts.ex`, outside this directory.

## Routing Table
This directory has no child subdirectories.
