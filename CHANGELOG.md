# Changelog

All notable changes to this project will be documented in this file.

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
