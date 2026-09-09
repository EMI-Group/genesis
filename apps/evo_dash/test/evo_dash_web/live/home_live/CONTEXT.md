# Test Directory — HomeLive Support-Module Unit Tests

## Intent

Pure, `async: true` unit tests for the HomeLive (`GET /help` chat page) support modules that sit BELOW the LiveView: `Transcript` (chat-transcript normalization), `Messages` (message → entry conversion), `AssistantMessage` (assistant mini task-card rendering), `ChatState` (persisted chat-state build/restore). No LiveView is mounted here, no `EvoDash.ActiveTasks`/`ChatHistory` reset needed — these suites never touch the shared store/registry/hubs.

## Routing Table

- `./transcript_test.exs` → `EvoDashWeb.HomeLive.Transcript.normalize/1` (mount-direction guard: non-lists, non-map entries, non-binary/nil ids, unknown roles, missing keys, non-boolean streaming all degrade)
- `./messages_test.exs` → `EvoDashWeb.HomeLive.Messages` (`assistant_text/1`, `message_text/1`, `to_entries/1`) — total conversion of `%ReqLLM.Message{}`-shaped history payloads (atom `:role` key only; thinking parts contribute text; nil metadata degrades)
- `./assistant_message_test.exs` → `EvoDashWeb.HomeLive.AssistantMessage.assistant_message/1` rendered-HTML contract (text/markdown/streaming states, task-status badge labels, thought-process rows via ToolCallDisplay, raw-toggle + copy action group)
- `./chat_state_test.exs` → `EvoDashWeb.HomeLive.ChatState` (`build/1`, `restore/1`, `normalize_model_id/1`) + `Transcript.entry/2` — persisted chat-state shape round-trip + per-key degradation

## Notes for Agents

- **ZERO coupling to the `EvoGit.Config` subsystem** (verified exhaustively, 2026 audit for the Ecto config refactor): no `EvoGit.Config`/`Config.Schema`/`LLMCatalog`/`VersionState`/`config_path`/`config.toml`/`XDG_CONFIG_HOME`/`model_profiles`/`onboarding`/`accent` references anywhere in these four files.
- `chat_state_test.exs` is the closest-adjacent file: it round-trips `selected_model_id` as an OPAQUE STRING (`"profile-a"`/`"p1"`) — no validation against resolved `[[llm.models]]` profile ids — and pins `normalize_model_id/1` semantics (nil/""/non-binary → nil = Auto; non-empty binary incl. whitespace kept verbatim, not trimmed).
- The config-touching code in this lib area is `EvoDashWeb.HomeLive.ModelSelect` (`apps/evo_dash/lib/evo_dash_web/live/home_live/model_select.ex`, aliases `EvoGit.Config`/`Config.Schema`, calls `Schema.model_profiles(Config.resolve())`) — but it has NO test file here; its coverage lives in `../home_live_test.exs` (parent node), which writes a `[[llm.models]]` config to `EvoGit.Config.config_path()` before mounting (`write_model_profile_config/0` pattern).
- `assistant_message_test.exs` pins the gettext task-status labels in ENGLISH (test default locale): pending/running/finalizing/cancelling "Cancelling…"/completed/failed/cancelled — statuses are runtime values, not config-driven.
- `messages_test.exs:8` comment "shape is owned by the :evo_git core" refers to agent-state history payloads (`%ReqLLM.Message{}` structs across the async/RPC boundary) — NOT the config subsystem.

## Constraints

- All four suites `use ExUnit.Case, async: true` and never mount a LiveView, so they need no store isolation and no hub/registry resets.
- Fixtures are hand-built maps/structs inline (`%ReqLLM.Message{}`, `%ReqLLM.ToolCall{}`, `%ReqLLM.Message.ContentPart{}`, `%ReqLLM.Message.ReasoningDetails{}`) — no factories, no shared support.
