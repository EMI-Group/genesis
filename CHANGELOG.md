# Changelog

All notable changes to this project will be documented in this file.

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
