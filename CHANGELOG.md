# Changelog

All notable changes to this project will be documented in this file.

## [0.12.5] - 2026-09-08

### Added

- Add GPT-6 Astra to the predefined OpenAI model catalog.
- Freshly bootstrapped remote nodes now receive a distinct accent color in their copied config so they are visually distinguishable in the dashboard.

### Changed

- Split accent color roles into a new standalone "primary-standalone" token and made the accent picker and all text/outline accent styling CSS-driven, improving contrast for several accent/theme combinations.
- Unify the Settings save-bar into a compact bar using the form attribute and pin the LLM category save bar at the pane bottom.
- Change built-in config defaults: max scheduler turns reduced to 100 (root to 1000) and LLM compression threshold raised to 180,000 tokens.
- Rename the remote-connection 'Bootstrap' UI to 'Install' with a two-step explainer, auto-fill the connection Name from the SSH Target, and add the missing id to the connection form.
- Remove the legacy inline running-agents display from the Projects remote view; running agents now appear only in the sidebar Active Tasks list.
- Omit foreign-repo structure from the subagent objective schema.

### Fixed

- Fix remote URL-driven project activation and resume-aware foreign-repo restore when resuming tasks from connected targets.
- Suppress the task-launch placeholder text when no project is open and the task form is disabled, removing the duplicated hint state.

## [0.12.4] - 2026-09-07

### Added

- Redesigned the task form with a ChatGPT/Gemini-style bottom toolbar, moving attach, mode, agent, and model controls into one row and replacing the Launch button with a compact circular send button.
- Added a per-agent delegation-authority statement to the first user prompt that informs each agent whether it is the root or a nested agent and the foreign-repo spawn authority that role carries.

### Changed

- Right-aligned the task-form toolbar cluster and removed its divider, moving the auto margin to the mode select.

### Fixed

- Fixed the Active Tasks sidebar showing a stale snapshot indefinitely by making the local connected-mount fetch unconditional, so a warm-but-stale hub is refreshed when a terminal task broadcast was missed.
- Closed sidebar dropdowns on outside click and when the sidebar collapses.
- Fixed the review-page repo selector so repo-switching works on both the Files-changed and Commits tabs for multi-repo reviews, adding a repo selector to the Commits tab.
- Increased top padding so typed text clears the attach-file button and doubled the compact-to-expanded layout thresholds for the task objective box.
- Stabilized the nix dev-environment TMPDIR across calls by sanitizing the built environment output.

## [0.12.3] - 2026-09-06

### Added

- Add a data directory config key to relocate the runtime data directory, with a corresponding Settings page category.

### Fixed

- Fix config_status reporting valid map-form LLM models (custom-endpoint provider/id models) as missing, so custom-endpoint profiles stored as map model specs no longer incorrectly trigger the "LLM model is not configured" warning.
- Improve error messages for invalid starting-commit references so failures return human-readable errors instead of raw git output.

## [0.12.2] - 2026-09-06

### Added

- Add syntax highlighting and language stamping for 16 additional languages (Nix, Erlang, Haskell, Clojure, Scala, Julia, Nim, Crystal, Elm, Groovy, PowerShell, OCaml, F#, Lisp, Scheme, Zig) in the in-app diff viewer.
- Add a dedicated Objective tab to the code review page with Markdown/Raw toggle, copy button, and empty state.
- Add a new 'run' subcommand and an auto-approval mode for CommandShell.
- Add syntax highlighting styles for markdown grammar token classes so highlighted code and markdown are visible in the diff viewer.

### Changed

- Redesign the GitHub-PR review page into a two-page model with new page header/tabs components, a server-driven file-tree sidebar with directory collapse/expand and file filtering, a GitHub-style merge box with overflow menu, multi-repo toolbar, and short-sha chip on the header.
- Refactor the CLI to route genesis/evolve/reflect through the task data plane, make -m/--model task-level, and remove session-level scheduler overrides.
- Move the 'Ignore' action out of the Danger zone in the review overflow menu, rendering it as a plain, always-available item, and make the overflow menu open upward so it no longer clips below the browser window.
- Cache per-node remote accents in the Appearance hook to eliminate accent flashing.

### Fixed

- Fix SSH remote connections to already-distributed nodes by ensuring the epmd_module is set to EpmdDist so outbound Node.connect uses the tunnel registry instead of the real epmd daemon.

## [0.12.1] - 2026-09-05

### Added

- Add a grace-period watchdog that resolves tasks stuck in :finalizing, along with observability logging for task terminal-status persistence and per-step git operations.
- Add security levels and a human-in-the-loop approval gate for the command shell.
- Add interactive command-approval cards to the chat UI, allowing users to confirm or deny security-level 2 and 3 tool actions directly in the interface, backed by agent handling for both local and remote node approval flows.

### Changed

- Teach the SelfReflective agent to proactively guide users to relevant pages using GuideUser page-path URLs and embedded route maps.
- Update the auto-update feed and updater manifest URLs to use the genesis.evox.group proxy as the primary host for mainland-China reachability, with GitHub kept as a fallback.
- Refresh review-action flows so destinations mount cold: rework ActiveTasks snapshot storage onto a shared ETS table and invalidate cached task state when merging, rejecting, or ignoring so destinations re-fetch fresh data after review actions.
- Cache the last-known Active Tasks per node context so the sidebar renders instantly across navigations instead of blinking empty, with the initial mount fetch limited to cold local pages.
- Prevent the SelfReflective agent from suggesting CLI usage in chat answers by default, guiding users to dashboard and in-app capabilities instead (unless explicitly asked about the CLI).
- Updated translations.

### Fixed

- Fix an application startup crash in the command-approval module.

## [0.12.0] - 2026-09-03

### Added

- Add a node-aware appearance/accent-color system with GNOME/libadwaita (Adwaita) theming across the dashboard, including a configurable accent-color picker and tokenized status/connection colors.
- Add per-model LLM Slots charting with model selection, foreign-node fallback, and live ring-buffer handling in the EVO dashboard, backed by a new scheduler read API exposing real per-model slot usage and capacity.
- Render finalized assistant chat messages as Markdown with per-message hover actions to toggle raw view and copy text, and keep the pinned model across new chats and node switches.
- Add days-of-week peak/off-peak configuration to the Model Profiles editor, with parsing/serialization support and fixes for day-order reversal and cross-month wakeup-timing bugs.
- Add support for gemini-3.8-flash and claude-fable-5.1 models to the LLM catalog.

### Changed

- Redesign the System page: move Genesis Source into the System Self-Check grid, group System Dashboard, Scheduler, and System Controls into a single System Controls section, pin card action buttons to card bottoms, and re-arrange the System Live layout.
- Replace the LLM Slots model chip-set selector with a compact dropdown on the System page.
- Reframe the agent as a first-person Genesis persona that answers chat users directly without tool calls.
- Improve UI contrast and consistency across settings, review, dashboard, agents, welcome, and live pages via an Adwaita-theme polish pass, including better readability for low-alpha text, hardened borders, and refined radii.
- Rework the Agents page with a recolored layered surface system, hover-lift interactions, brighter surfaces, higher-contrast text, and plain-text styling without gradient accents on titles and headers.
- Improve settings layout by pinning the config-path footer in the sidebar, adding independent column scrolling on medium and larger screens, and making the layout consistent across all settings categories.
- Show software update changelog in a modal instead of an inline dump, and fix a Windows NSIS update install race.
- Rework remote-connection bootstrap to never kill a running daemon without permission, adding a 5-step progress bar with frozen final state and a daemon_running permission dialog to the Settings UX.
- Polished the agents page styling and refined agent spawn animations on initial load, and restyled the agents tree component with refined gray text tiers and hover/surface styling.
- Hide reflect chat tasks by default on the Tasks page with a reveal toggle, and fix the empty-state hint so fresh installs show the first-run nudge.
- Allow task search to also match agent response text, with updated placeholder.
- Updated translations.
- Update bundled ripgrep to version 15.2.0.

### Fixed

- Fix mobile layout overflows in the dashboard tree, task branch badges, and GitHub top-bar button.
- Fix icon color.
- Fix diff-viewer and input theme contrast, shadows, and skeleton shimmer for better accessibility and visual consistency.
- Fix a bottom seam appearing on scrolled pages by painting the content background across the full scroll container.
- Fix visual layering and tactile depth issues alongside polish of agents and live pages.
- Bottom-align SVG plots in scheduler chart cards so they line up consistently regardless of wrapping text.
- Remove gray background boxes from the Agents page empty states.

## [0.11.6] - 2026-09-01

### Added

- Wire the LLM model selector into the Home Live chat page, including a chat model selector in the home chat interface via a new ChatState model selection helper.
- Add public helpers for normalizing chat model IDs and model selector task options.
- Add automatic commit fallback for the agent workflow.
- Publish changelog sections as GitHub release bodies and populate latest.json notes from the changelog on releases.

### Changed

- Improve changelog generation so related pull requests and merges addressing the same feature or bug are collapsed into a single changelog entry.
- Switch dependency to a personal fork of req_llm to apply a patch that fixes the Z.ai GLM models.

### Fixed

- Fix mobile task-form controls being pinned off-screen when the keyboard opens by making layout heights aware of the dynamic viewport.

## [0.11.5] - 2026-09-01

### Added

- Added UNC/network-drive and WSL-shared path support with UNC-aware helpers and early repo-root diagnostics so repos on network-shared or WSL-shared paths work on non-Windows hosts.
- Added diagnostic logging to peak/off-peak concurrency scheduling for improved observability when troubleshooting blocked tasks.
- Added a secure command-string dispatcher (EvoGit.CommandShell) with a run_command tool that consolidates ten task-control tools into a single command-shell registry.

### Changed

- Restricted writable cross-repo subagent spawns to the root agent only and serialized them per batch, with clear rejection hints surfaced to the LLM, while keeping read-only foreign-repo spawns unrestricted for all agents.
- Redesigned the Home chat page with a ChatGPT-style layout, robust ChatHistory persistence, nil-safe message handling, improved task-card assistant bubbles, and crash/regression fixes.
- Shortened and clarified tool-output truncation messages and fixed UTF-8 safety and overlap edge cases in truncation.
- Renamed CommandShell command paths to the Module.function naming form throughout the agent and updated documentation accordingly.
- Consolidated the ten task-control tools into a single generic run_command tool that dispatches via a command-shell registry, simplifying the agent's tool surface.
- Updated translations and documentation to reflect the self-reflective run_command shell tool and its command registry.

### Fixed

- Fixed malformed delegation-hint path rendering when editing files directly in the agent's own node directory and added regression tests for suppressing delegation hints for own nodes.
- Fixed UNC/WSL path handling in project-flow path normalization, remote acceptance, and foreign-repo storage so UNC-prefixed roots round-trip intact on non-Windows nodes.
- Fixed HomeLive send_chat regression where a bare task struct was passed to task_id_from_start instead of the correct chat_task_id.

## [0.11.4] - 2026-08-30

### Added

- Add multi-repo read-write foreign repository support, including per-repo review page tabs, merge/reject orchestration, write-gating for read-only foreign repos, and per-repo commit roll-up reporting.
- Add newest model releases to the catalog (gemini-3.7-flash, glm-5.3*, grok-4.6, qwen-3.8-max, deepseek-v4-flash-vision-exp).
- Add Perplexity, Exa, Bing, and Brave web search providers to the config schema.
- Add configurable shell for run_bash/run_powershell tools with a hint when a nested shell is invoked.
- Move the Home chat page to /help and add a Help entry to the sidebar.

### Changed

- Refactor WebSearch tool into provider-aware adapters for Tavily, Perplexity, Exa, Bing, and Brave.
- Improve and document path autocomplete behavior, including filesystem suggestion handling, trailing-separator edge cases, and recents filtering semantics.
- Update translations.
- Condense and clean up CONTEXT.md documentation files, routing detailed subsystem information to child documentation files, and add auto-commit fallback for the agent.

### Fixed

- Fix PeakHours to accept canonical integer-minute peak windows so peak concurrency is correctly applied instead of falling back to off-peak values.
- Harden the web_search tool against malformed Perplexity responses with non-list citations.
- Fix project-path autocomplete to delegate filesystem suggestions to a single source of truth and match recent paths by case-insensitive substring.
- Prevent remove_leftover_worktree_dir/1 from deleting git working trees, preserving repos with a .git directory during leftover cleanup.
- Hard-block mutating git commands that cd into the repo root via relative paths, preventing accidental changes to the main working copy's HEAD.
- Fix the module reference for search_providers/0 in the web search documentation.

## [Unreleased]

## [0.11.3] - 2026-08-25

### Added

- Added guidance for the Architect to recognize and build upon pre-initialized projects rather than re-initializing them

### Changed

- Clarified in agent prompts that the default worktree lives under .genesis/ at the project root

### Fixed

- Improved WorktreeManager reliability with persistent initialization markers and re-monitoring for safer crash recovery
