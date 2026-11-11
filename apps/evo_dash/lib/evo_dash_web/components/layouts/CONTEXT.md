# Root HTML Layout

## Intent
`root.html.heex` provides the shared document shell for every dashboard route, including `/assistant` (the legacy `/help` route 302-redirects there), without page-specific chat markup.

## API Surface
The template renders `@inner_content`, a localized live title, relative tracked CSS/JS assets, CSRF and locale metadata, and favicon/mobile-web-app metadata.
Its synchronous head script resolves light/dark/system themes before paint through `html[data-theme]` and `html[data-theme-mode]`, persists `phx:theme`, handles `phx:set-theme`, and synchronizes OS and cross-tab changes.
The same script persists locale via `phx:locale` and a cookie, maintains RTL direction, and handles `phx:set-locale` and `phx:persist_locale` with distinct reload semantics.

## Constraints
Preserve `@inner_content`, CSRF metadata, tracked relative assets, `#favicon`, theme attributes/event names/storage keys, and locale metadata/event names/cookie behavior when polishing visuals.
The body uses `bg-base-200 text-base-content antialiased h-dvh overflow-hidden selection:bg-primary/30`; its fixed viewport and hidden overflow underpin the nested shell/page scroll contract.
Keep `viewport-fit=cover` and `interactive-widget=resizes-content` for mobile safe-area and keyboard-aware layout behavior.
The light/dark `theme-color` literals (`#f6f5f4` and `#242424`) match Adwaita shell chrome and should stay coordinated with theme CSS.
Page-specific simplification of `/assistant` belongs in the Home LiveView, while sidebar/navigation chrome belongs in the sibling `layouts.ex`, outside this directory.

## Routing Table
This directory has no child subdirectories.
