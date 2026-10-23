# Harness Alignment: Genesis agent runtime vs DeepSeek Harness (`dsh`)

Design record / comparison report. Purpose: enumerate the concrete differences between **our** agent
environment (Genesis `:evo_git` runner, tools, prompts, context management) and **DeepSeek Harness**
(`dsh`), because newer DeepSeek models are trained against `dsh`'s tool surface, result conventions and
prompt shape — behavioural alignment should transfer capability for free.

This document is a **diff + proposal record**, not a change log. It records the current state of both
runtimes and the proposals that follow from the diff.

## Method & references

| Concern | Ours | Reference |
|---|---|---|
| Tool inventory | `apps/evo_git/lib/evo_git/agent/tools.ex` (`schemas/0`, `read_only_schemas/0`) + `agent/tools/*` | `docs/tool-catalog.md` (generated, gate-verified; ~40 model-facing names / 34 tool packages) |
| Agent loop | `agent/runner.ex`, `agent/tool_dispatch.ex` | `packages/core/agent-loop/src/` |
| Prompts | `agents/*.ex` (`system_prompt/0`) + `agents/prompt_fragments.ex` | `packages/core/system-prompt/src/index.ts` + rendered snapshot `snapshots/session/deepseek-protocol-system-prompt/system-prompt.expected.md` |
| Context management | `agent/context_compression.ex`, `agent/output_sanitizer.ex` | `packages/compaction/compaction-basic/` |
| Delegation | `agent/tools/subagent_*.ex`, `agent_scheduler/` spatial contract | `packages/subagent/subagent/` |

Reference commits: ours `b562b8283`, dsh `350b8df0c`. Two independent full-map investigations staged these
findings; the specific "do we have X?" claims below were each re-verified against source (see
`apps/evo_git/lib/evo_git/agent/CONTEXT.md` for the two facts this pass added).

---

## TL;DR — the divergences that actually move model performance

Ranked by expected impact per unit of work. "Impact" = how likely a DeepSeek/Claude-family model's trained
behaviour is to be *penalised* by our current shape.

1. **Completion protocol is inverted.** `dsh` (and Claude Code, and therefore the training data) ends a turn
   when the model stops calling tools. We *require* a `complete_task` tool call and inject a nudge up to 3
   times if the model replies in text. A model that has correctly finished will narrate, get scolded, and
   burn turns. **Impact: high, cost: low.**
2. **No `todo_write` / plan affordance.** Every modern coding harness has a visible todo list state the model
   writes to; we have none, and no plan mode. Models reach for it habitually. **Impact: high, cost: medium.**
3. **Our prompts are ~10× longer than theirs and structurally unlike anything in training.** 10 role
   `system_prompt/0` callbacks totalling ~90K chars (Manager 13.9K, Architect 18.5K, ContextExtractor 10.1K,
   SelfReflective 8.7K…). `dsh`'s prompt is an assembled set of one-sentence **per-tool nudges** plus a
   short persona, with *no* tone/style/emoji rules and no mandate prose. **Impact: high, cost: medium.**
4. **Context compression is a total collapse that also destroys the prompt cache.** We keep exactly
   `[system, refreshed_first_user, summary]`; `dsh` prunes tool-result middles first (model-free), then
   summarises into a **checkpoint user-message that replaces a span** while recent turns survive.
   **Impact: high, cost: medium.**
5. **Malformed tool arguments kill the agent.** Invalid JSON args → `args_map/1` returns `nil` →
   `FunctionClauseError` inside the linked `Task.async` → agent dies (the `{:exit, reason}` arm is
   unreachable for raises). `dsh`'s three-stage parse never hard-fails: raw-string fallback → schema error
   text. **Impact: high (it is a robustness bug), cost: low.**
6. **Shell tool misses three trained-expected affordances**: `description` as the first required param, a
   `run_in_background` mode, and a **spill file** (`[output truncated; full output: <path>]`) that a follow-up
   `read` can open. We truncate head/tail 8 KB+8 KB and delete the file. **Impact: high, cost: low-medium.**
7. **Tool naming distance.** `read`/`write`/`edit`/`glob`/`grep`/`bash`/`Task`/`TodoWrite` vs our
   `read_file`/`write_file`/`edit_file`/`glob`/`rg`/`run_bash`/`subagent_manager`. `edit_file`, `glob` and the
   `old_string`/`new_string`/`replace_all` triple are already aligned; `rg` vs `grep` and `run_bash` vs `bash`
   are pure naming drift. **Impact: medium-high, cost: low** (we already have an alias precedent for shells).
8. **Agents have no clock and no context-pressure signal.** No date/time refresh (`dsh` refreshes every
   10 min), and compression is silent — the agent is never told it is at 85% of its window.
   **Impact: medium, cost: low.**
9. **Delegation is one blocking batch call.** `AgentScheduler.spawn_sub_agents/2` is a single
   `GenServer.call …, :infinity`; the parent idles until *all* children finish and cannot steer, interrupt, or
   collect partial results. `dsh` spawns non-blocking (`started subagent <id>`), delivers results as an
   ordinary user message, and adds `send_message`/`interrupt_agent`/`list_agents`. **Impact: medium-high,
   cost: high** (structural).
10. **`rg` returns raw ripgrep text with no default flags and no cap**; `dsh`'s `grep` returns a structured,
    capped (`Found N matches` + `File` + `Line N:`) result and its `glob` carries a documented footer.
    **Impact: medium, cost: low.**

---

## 1. Tool surface diff

### 1.1 Capability matrix

| Capability | `dsh` | Ours | Verdict |
|---|---|---|---|
| Read file | `read` — `offset`/`limit`, 2000 lines, **2000 chars/line clip**, footer `(Showing lines X-Y of N. Use offset=Z to continue.)`, offset past EOF is an error | `read_file` — `offset`/`limit`/`line_numbers`/`max_bytes`, 2000 lines, **no per-line clip**, header `File: p\nLines: a-b of n`, 256 KB gate | close; add per-line clip + footer |
| Write file | `write` (create/overwrite) | `write_file` (create/overwrite, `mkdir_p`, scope-validated) | aligned |
| String replace | `edit` — `old_string`/`new_string`/`replace_all`, uniqueness enforced, `The file <p> has been updated successfully.` | `edit_file` — **identical params and success string**; adds curly-quote normalization; silently trims trailing whitespace of `new_string` | **already aligned** (fix the silent trim) |
| Create empty files | — (empty `write`) | `create_files` (array of paths) + auto-commit + subagent-motivation text | ours has extra git semantics |
| Make directory | — (`bash mkdir`) | `make_dir` + placeholder + auto-commit | ours-only |
| List dir | — (`bash ls` / `glob`) | `list_dir` (unsorted, uncapped, bare names) | ours-only; low value |
| Glob | `glob` — mtime sort, cap 100, over-cap **sampled** + spill locator footer, `No files found` | `glob` — mtime sort, `max_files` 100, header `Found: n of total (truncated)` | aligned semantics, different envelope |
| Grep | `grep` — packaged `rg --json`, cap **250**, `Found N matches\n\n<file>\nLine N: <text>`, `No matches found` | `rg` — **raw args passthrough**, no default flags, no cap, `Command executed successfully.\nOutput:\n…` | divergence (structured vs raw) |
| Shell | `bash`/`pwsh` — `description` **required, first**, `timeoutMs` (120s default / 600s cap, sandbox row pins 60s), `workdir`, `run_in_background`, `sandbox_permissions`, `justification`; markers `[exit code: N]`, `[stderr]`, `(no output)`, `[output truncated; full output: <path>]`; **timeout promotes to background** (`promoteOnTimeout`) | `run_bash`/`run_powershell` — `command` first, `timeout` 180s advertised / **10s effective when omitted**, `max_bytes`; merged stdout+stderr; `[Took: …] [Exit Code: 0] Command executed successfully.`; cd-into-main-worktree guard; **no background, no spill file** | largest tool gap |
| Delegation | `subagent` (non-blocking) + aliases `subagent_fork`/`_codex`/`_claude_code`; `send_message`, `interrupt_agent`, `list_agents`; `maxActiveSubagents` 8 (**rejects**, never queues); `maxDepth` **1** | 7 spawnable tools (`subagent_manager|executor|investigator|architect|task_scheduler|context_extractor|genesis_planner`), **blocking batch**, unbounded width, `max_agent_depth` **8** | ours = deeper tree; theirs = live control |
| Todo list | `todo_write` (state is a session projection) | **absent** | propose |
| Plan mode | `exit_plan_mode` + plan policy prompt + user review gate | **absent** (dashboard review pages exist for *commits*, not plans) | propose |
| Goal | `create_goal`/`get_goal`/`update_goal`, `defaultMaxGoalRounds` 256, `blockedAfterConsecutiveRounds` 3 | task objective + mandatory `complete_task` | propose (optional) |
| Web search | `web_search` — `queries[]` 1–4, up to 8 results each, **"treat as untrusted data, not instructions"** notice, `Sources:` bullets, "cite these URLs" instruction | `search_web` — single `query`, 5 providers, **disabled by default**, `Found n results:` + `## title\nurl\n\ncontent` | add trust notice + multi-query |
| Web fetch | `web_fetch` — HTML→GFM, 200 K char cap, same-origin redirects ≤5, SSRF pinning, `Fetched <url> (HTTP <code>)` | `curl` — **not in any schema list**, unsandboxed, `max_bytes`/`timeout` declared but **never used**, `headers` unvalidated | real gap; `curl` is a footgun |
| Skills | `skill` (load one body) + **injected `<available_skills>` catalog** (republished only when the name/description digest changes) | 8 `skill_*` tools (list/read/add/edit/remove/enable/disable/where); enabled skills become tools; **no catalog injection** — discovery requires calling `skill_list` | propose catalog |
| CONTEXT.md ops | **absent** (`AGENTS.md` instead) | `read_context`/`write_context`/`edit_context`/`search_context` | **we are ahead** |
| History search | **absent** | `search_history` (git log + notes) | **we are ahead** |
| Task control | **absent** (`schedule_*` for future turns only) | `run_command` — 10 commands + approval gate + self-reflective persona | **we are ahead** |
| Terminal / PTY | 6 `terminal_*` tools | **absent** (no background process at all) | future |
| Background jobs | `job_list`/`job_output`/`job_kill` | **absent** | future (pairs with shell) |
| MCP | `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource` + dynamic server tools | **absent** | future |
| LSP | `lsp` (diagnostics/hover/definition) | **absent** | future |
| Self-introspection | `cordis_inspect_list`/`cordis_inspect_query` | **absent** | future (low value for us) |
| Deterministic orchestration | `workflow` (JS + `agent()`/`pipeline()`/`parallel()`/`phase()`), `ralph` (fresh-agent rounds), `run_code` (PTC mode) | **absent** — delegation is prompt-driven only | future |
| Structured user question | `ask_user_question` (options + custom answer, JSON result) | `guide_user` (one-way broadcast) + `CommandApproval` (approve/deny only) | propose |
| Finish | **none** — stop calling tools | `complete_task` (required, `check_git_status` gate, writes git note + archive refs) | key divergence |

### 1.2 Name-distance table (the cheap half of alignment)

| Concept | Claude Code (training prior) | `dsh` | Ours |
|---|---|---|---|
| read | `Read` | `read` | `read_file` |
| write | `Write` | `write` | `write_file` |
| edit | `Edit` | `edit` | `edit_file` ✅ |
| shell | `Bash` | `bash` | `run_bash` / `run_powershell` |
| glob | `Glob` | `glob` | `glob` ✅ |
| grep | `Grep` | `grep` | `rg` |
| web search | `WebSearch` | `web_search` | `search_web` |
| web fetch | `WebFetch` | `web_fetch` | (`curl`, unlisted) |
| todo | `TodoWrite` | `todo_write` | — |
| delegate | `Task` | `subagent` | `subagent_manager`/`_executor`/… |
| ask user | `AskUserQuestion` | `ask_user_question` | — |
| skill | `Skill` | `skill` | `skill_read`/`skill_list` |

`dsh` ships a bidirectional alias table (`packages/experimental/claude-code-mods/src/tool-names.ts`) precisely
because names are a compat surface. We already have exactly one alias mechanism (`@shell_tool_name` +
`normalize_tool_name/1`, 9 shell spellings, applied *before* the gates) — the precedent exists; it just covers
one tool.

### 1.3 Tool behaviour conventions

| Convention | `dsh` | Ours |
|---|---|---|
| Failure shape | **always** `content: [text: "Error: <msg>"]` + `isError: true`; structured detail rides outside model content | mostly `"Error: …"`, but also `"⚠️ …"`, `"💡 …"`, `"[NOTICE] …"`, `"[WARNING] …"`, `Command failed with exit code N` |
| Success shape | only `output.render(args, value)` — no echo of args or raw value | descriptive envelopes, often with `Command executed successfully.\nOutput:\n` prefixes |
| Empty result | no placeholder (model sees `(no output)` for shell only) | `No matches found.`, `Found: 0 of 0 files` |
| Argument validation | 3 stages: JSON parse → boundary check → schema validation → `Error: invalid arguments: missing required property "path"` | `is_map`/`is_binary` clause heads + `fetch_string_arg` → `"Missing required argument '<key>'…"`; **no JSON-Schema validation**; invalid JSON = crash |
| Duplicate calls in one response | (no specific policy) | `dedupe_tool_calls/2` — `Enum.dedup_by` on `:id` then `{name, args}`, silent drop + warning, intra-response only |
| Success-terminal | `concludesTurn?: true` opt-in by a tool | `complete_task` special-cased by name |
| Truncation | **three layers in different units**: shell capture 64 KB *bytes*, spill policy 12 500 *estimated tokens*, pruner 8 192 *code points* | one byte-based layer: ceiling 128 KB, 16 KB for `@high_output_tools`, 8 KB head + 8 KB tail, `[Output truncated: original n bytes, max m …]` + 131072 hardcoded in the hint string |
| Per-tool timeout | `ToolDefinition.timeoutMs`, wholesale result `Error: tool call timed out after <N>ms`, partial output discarded | per-call `args["timeout"]` default **10 s**, hard cap 30 min, partial output **kept** |
| Parallelism | `maxParallelToolCalls` 10; `isConcurrencySafe(args) === true` ⇒ parallel else **barrier** (fail-closed) | write-class tools **serial and first** (`create_files`, `write_file`, `edit_file`, `make_dir`, `write_context`, `edit_context`, skill mutations, custom write tools), everything else `Task.async_stream` with `max_concurrency = group size`, results re-sorted by request index |
| Tool-result attachment channel | tool results can carry multimodal blocks | `%ToolOutput{text, attachments}` wrap boundary in `ToolDispatch`; `tool_result(id, name, parts)` when media present |
| Read-before-edit | **versioned CAS** on `dev:ino:size:mtimeNs:ctimeNs`: `cannot edit "<p>": file changed since it was read — re-read the file, then retry` | **absent** — edits apply to whatever is on disk |

Our serial-write-first partition is genuinely better than a generic concurrency flag for our workload
(non-atomic read-modify-write on the same file), and the ordering guarantee (mutation lands before a same-batch
read) is something `dsh` does not have. Keep it; don't trade it for `isConcurrencySafe`.

---

## 2. Agent roles & prompts

### 2.1 Role taxonomy

`dsh` has **one** agent loop and no role taxonomy of the Claude-Code kind. Its role analogs:

| `dsh` role | How it differs from the base agent |
|---|---|
| Main agent | identity line + persona prefix/suffix + per-tool prompt sections |
| Subagent | **inherits the assembled prompt** + one standing instruction (permission scope fixed, do not retry denials; continuable children also get the parent id + "send your result with `send_message`"; with a schema, "you MUST report via `structured_output`") |
| Agent Preset | named bundle of model + tools + prompt (the `subagent_type` analog) |
| Plan mode | prompt-only policy; tools stay callable **on purpose** (cache stability); no read-only enforcement |
| Team lead / teammate | `TEAM_POLICY` section + `TEAM_IDENTITY` runtime context |
| Foreign child (`codex`/`claude-code`/`acp`) | runs its own harness; we only supply the task string |

We instead have 10 distinct role callbacks:

| Module | type | delegation | spawn tool | prompt size | spawns |
|---|---|---|---|---|---|
| Architect | `:read_write` | `:high` | `subagent_architect` | ~18.5 K | Architect, Manager, Executor, GenesisPlanner, Investigator |
| Manager | `:read_write` | `:high` | `subagent_manager` | ~13.9 K | Manager, Executor, TaskScheduler, Investigator |
| ContextExtractor | `:read` | `:low` | `subagent_context_extractor` | ~10.1 K | itself |
| SelfReflective | `:read` | `:low` | — | ~8.7 K | — |
| GenesisPlanner | `:read` | `:high` | `subagent_genesis_planner` | ~7.5 K | Investigator |
| TaskScheduler | `:read` | `:low` | `subagent_task_scheduler` | ~5.3 K | Investigator |
| Investigator | `:read` | `:low` | `subagent_investigator` | ~5.1 K | Investigator |
| Executor | `:read_write` | `:low` | `subagent_executor` | ~4.7 K | Investigator |
| SkillExtractor | `:read_write` | `:low` | — | ~2.8 K | — |
| Custom | agents.toml | agents.toml (default `:low`) | — (root-only) | user text | from `subagents` |

### 2.2 Prompt philosophy diff

| Dimension | `dsh` | Ours |
|---|---|---|
| Delivery | a `system/message` **session-log node at seq 0** (the provider `system` field is unused; `EpochHeader.system?: never` makes the classic shape unrepresentable) | a real `role: "system"` message in `ReqLLM.Context` |
| Assembly | ordered sections, joined with `\n\n`, **no headers/XML/markdown delimiters**; two deliberate bands (instructions 1000–5000, environment text 9000+) | one monolithic heredoc per role, concatenated from `PromptFragments` (30 fragments, "never merge two fragments") |
| Bulk | mostly one-sentence nudges contributed by tool plugins (`Use the read tool — not shell commands like cat — to inspect text files.`) | mandate prose: `## Core Principles`, `## Constraints`, `## Workflow`, `## Delegation`, `## Examples` |
| Persona | one prefix + one suffix string with `{{model}}` (`You are a coding agent powered by the {{model}} model.`) | role lecture (`You are a manager agent in Genesis's recursive hierarchy — …`) |
| Tone/style rules | **none shipped** — no "be concise", no emoji rule, no markdown contract | heavy: emoji-prefixed hints (⚠️/💡), "one sentence per line so git diffs stay granular", `⚡ FIRST ACTION:`, "STRICT CONSTRAINTS" |
| Dynamic state | a **separate user-role runtime-context snapshot** that *supersedes* its predecessor (cwd, sandbox, approval, delegation, team identity, time) | baked into the **first user message** `<context>` block (rebuilt only at compression time) |
| Environment docs | `AGENTS.md`/`CLAUDE.md` discovery via a `<system-reminder>` user message, `maxBytes` 65536; **`CONTEXT.md` is explicitly never loaded as workspace instructions** | the CONTEXT.md chain, rendered into `<context>` — our whole spatial contract |
| Skills | catalog injected as `<system-reminder><available_skills>`, republished only on digest change | no catalog; `skill_list` on demand |
| Change | `systemPromptUpdate: 'in-history'` — a changed prompt **appends after** cached history instead of rewriting node 0 | prompt is recomputed per spawn; a change is invisible mid-agent |

**Assessment.** Our prompts are not "wrong" — they encode real, hard-won framework semantics (worktree
isolation, commit-before-delegate, spatial scope, sibling read-only, delegation-imperative). But three
properties are actively hostile to a model trained on `dsh`:

1. **Length/priority inversion.** ~14–18 K chars of mandate competes with the actual objective. In training
   the harness contributes a few hundred words; we contribute a policy manual per spawn.
2. **Non-distributional register.** `⚡ FIRST ACTION`, `CRITICAL:`, `You must drive this to 100% completion`,
   emoji hints, and "delegate immediately, certainty not required" are not phrasings the model has been
   alignment-trained to follow as harness instructions — they read as *user* content.
3. **Tone/format rules the model was *not* trained under** (e.g. "one sentence per line", emoji prefixes on
   tool outputs) consume attention and teach the model that non-`Error:` prefixed text is prose.

The right move is not to delete our semantics but to **compress them into the terse, machine-facing register**
that models are trained on: short imperative bullets, no emoji, no rhetorical emphasis, and per-tool nudges
delivered where the model already looks (tool descriptions), not in a role essay.

### 2.3 Prompt-content items worth keeping verbatim versus dropping

| Item | Recommendation |
|---|---|
| Spatial scope + sibling read-only + writable-foreign gating | **keep** (unique to us; `dsh` has no analog) |
| Commit-before-delegating / worktree isolation | **keep**, shorten |
| Delegation imperative + parallel-waves guidance (Manager, TaskScheduler, GenesisPlanner) | **keep**, but move the "how to delegate" mechanics into the `subagent_*` tool descriptions (that is where `dsh` puts them) |
| CONTEXT.md current-state doctrine (1075 chars, duplicated 4×) | **keep semantics, deduplicate** into one fragment |
| `⚡ FIRST ACTION`, `CRITICAL:`, `💡/⚠️` prefixes, "STRICT CONSTRAINTS" | **drop / re-register** |
| "Delegate objectives, not patches", "Validation is high-level and cheap" | keep — they are real policies, restate tersely |
| Turn-budget contract in Executor ("Running Out of Budget") | **keep** — `dsh` has *no* turn budget at all; this is ours and it works |
| SelfReflective persona + "no shell, no write tools, answer fast" rules | keep (unique product surface) |

---

## 3. Context management & compression

### 3.1 Threshold model

| | `dsh` | Ours |
|---|---|---|
| Measure | `tokenMeter.measure().totalTokens` = last reported usage + signed delta over the surface since then; `CHARS_PER_TOKEN = 4`, **no tokenizer**; includes generation, not just prompt | `state.total_tokens` (system + input + output + reasoning accumulated per turn) |
| Trigger | `thresholdTokens = min(W*0.8, W − reservedCompletion − 65536)`, `retainTokens = (W − O)*0.16` — **window-relative** | fixed `[:llm] :compression_threshold_tokens` = **180 000** for every model (a 1 M-context model compresses at 18%; a 128 K model would blow past the window first) |
| Trigger points | 4: `agent/pre-step` over pressure, `CONTEXT_WINDOW_EXCEEDED`, `IMAGE_OFFLOAD_REQUIRED`, `/compact` | 1: `ContextCompression.maybe_compress/1` at the top of `loop/1` |

The fixed-threshold model is a genuine correctness gap once profiles declare heterogeneous context windows:
`dsh` derives the threshold from the window; we hardcode a number that is simultaneously too eager for large
models (needless compression, needless cost) and too late for small ones.

### 3.2 Strategy diff

| | `dsh` | Ours |
|---|---|---|
| Stage 1 | **model-free tool-result pruner**: `thresholdChars` 8192, keep head 4096 + tail 1024, middle replaced by `\n\n[... tool result middle pruned ...]\n\n`; **if this alone suffices, no model call happens** | none |
| Stage 2 | model summarization | model summarization, no retry loop, no tools |
| Result shape | a **`user/message`** with `surfaceOp: {op:'replace', startSeq, endSeq}` and `kind:'compact-checkpoint'`, wrapped in "This is an automatically generated checkpoint … Continue the task directly … without acknowledging this checkpoint." + `<compacted-summary>` | the context is **replaced** by exactly `[system, refreshed_first_user, user("Summary of previous events:\n" <> text)]` |
| History retained | everything outside the replaced span — recent turns survive; compaction **shadows**, never deletes (shadowed nodes must be cited) | nothing. Every non-system message except the summary is gone |
| Cache | checkpoint is appended, prefix untouched → cache survives | first user message is **rewritten** and the tail is discarded → full cache miss every cycle |
| Summary template | 8 fixed sections: `## Primary Request and Intent`, `## Key Technical Concepts`, `## Files and Code`, `## Errors and Fixes`, `## Pending Jobs`, `## Current Work`, `## Next Step`, `## Critical Context`; rules "Do NOT mention this summarization request", "preserve exact file paths/commands/error strings", merge-into-prior-checkpoint | 5-point ordered list ("objective verbatim, completed steps, decisions, unresolved problems, next step") written as "instructions to your future self" |
| Failure | `compactionRetries` 1, `maxOverflowRetries` 1, durable in-flight lock (`compaction/start`) so a crash yields `busy`, never false success | non-retryable rejection → graceful `{:llm_request_rejected, …}`; **any other LLM error raises `MatchError` with zero retries** |
| Multi-modal | `[image omitted to fit request image limits; <identity>. …]` placeholder | attachment media stays byte-identical in the refreshed first message → **re-sent at full cost after every compression** |

### 3.3 Other context levers

| Lever | `dsh` | Ours |
|---|---|---|
| File-read caps | 2000 lines, 2000 chars/line, offset past EOF errors | 2000 lines, 256 KB gate, 5 MB streaming, **no per-line clip** |
| Repeat guard | `repeat-tool-reminder` at 3/5/8 identical consecutive calls, gentle → detailed, injected as tool-result `additionalContext` | none cross-turn (only intra-response dedupe) |
| Time context | refreshed every 600 000 ms | **none** — agents cannot know the date |
| Token pressure to the model | none (dashboard-only) | **none** (dashboard-only, `compression_pct`) |
| Pending messages | durable inbox (`inject`/`steer`/`followup`/`send`), folded by a projection; steering **revives a concluding turn** | `drain_and_inject_user_messages/1` once at the top of `loop/1` — cannot revive a concluding turn |
| Session durability | append-only JSONL, 62 event types, 5 surface-eligible, migrations v0→v4, zstd | in-memory `%ReqLLM.Context{}` + per-turn ETS snapshot; **no transcript in SQLite**; resume builds a `--- Previous Task Context ---` text block and starts fresh |

---

## 4. Loop mechanics

| Concern | `dsh` | Ours |
|---|---|---|
| Unit | **turn** = one user intent; **step** = one model call + its tools; a turn ends only when `step()` returns null **and** the inbox is empty | one flat `turn` counter (`LoopState.turn`, `max_turns` 128 / `max_turns_root` 1000); no step concept |
| Request derivation | `buildRequest` is a **pure function of the session log** (`session.deriveMessages()`); no in-memory message array; byte-equality pinned by a test | the live `ReqLLM.Context` *is* the state; every turn appends |
| Streaming | streaming only (no non-streaming path); live frames published **after** the durable append | streaming via `ReqLLM.stream_text` + `process_stream`; deltas consumed inside ReqLLM, the loop sees only the assembled response |
| Reasoning | `thinking: {type}`, `output_config: {effort: off\|low\|high\|max}` (default high), **no `budget_tokens`**; thinking blocks replayed with provider signature | `reasoning_details` merged to one entry with `index: 0`; content may also carry a `:thinking` part; dashboard renders `:thinking` **separately** from response (`ContentText.text_part?/1` guards the join, "Thought process" panel) ✅ |
| Retry | a **waterfall** — the driver loop is unbounded; `dsh-llm-retry` listeners bound it (5 retries, 500 ms → 10 s, jitter 0.1, codes `EMPTY_RESPONSE/RATE_LIMIT/SERVER/TIMEOUT/TRANSPORT`); retries **skip prompt reassembly** so the cached prefix stays identical | 3 layers: harness recursion (15 attempts, 1 s doubling capped 60 s ±10% jitter, slot released before backoff) → ReqLLM inner (3, 429 + pre-body transport only) → scheduler per-model backoff queue (`60s` doubling to 8 h, 15 entries, ≈60 h total, per-model, purgeable on cancel) |
| Error classification | by **code enum** (`AUTH, QUOTA, RATE_LIMIT, CONTEXT_WINDOW_EXCEEDED, INVALID_REQUEST, SERVER, HTTP_<n>`); `LlmFailure` has no `retryable` flag | by `LlmError.non_retryable?/1` → fail fast after ONE attempt with a self-diagnosing message (parameters sent, never values); 402/429 deliberately **never** fail fast (model-exhaustion class seeds the multi-hour backoff) |
| Failed-step recovery | `TOOL_OUTCOME_UNKNOWN` / `TOOL_NOT_STARTED` recovery messages telling the model to reason about idempotency before retrying | none — a crashed step is retried whole (`agent_max_retries` 3, fresh worktree, conversation reset) |
| Turn end | `blocked, completed, max-tokens (sticky for the turn), aborted, error` | `{:ok, %Result{}}` / `{:error, :recovery_failed}` / `{:error, {:llm_request_rejected, msg}}` / raise (transient exhausted) / raise (git) / brutal kill |
| Budget awareness | none | `TurnWarning` at 25%/15-turn/end/critical thresholds, level-aware, emoji-tagged; grace budget 1 turn after the limit |
| No-tool nudge | not applicable (text = done) | `You did not make any tool calls in your last response. You must use the provided tools…` × 3 → protocol violation |
| Cancellation | abort the turn | graceful cancel (`:cancelling` + save-work message + 3-turn grace, results preserved as `:cancelled`) and force kill (`:failed`) — **richer than `dsh`** |

**Both harnesses retry aggressively but in opposite shapes.** `dsh` bounds the *count* and lets plugins decide
(5 × 10 s = under a minute, then fail). We bound *count* (15) **and** wall-clock (up to ~60 h for
balance/rate-limit classes) and park the wait in a per-model queue so other models keep progressing. Ours is
the right policy for long autonomous evolution tasks; it is also the one thing about our harness that most
changes model-visible timing (a 4-hour park looks like a hang from the agent's perspective — there is no
"you are rate-limited, waiting" message injected).

---

## 5. Permission, sandbox, and gating

| Concern | `dsh` | Ours |
|---|---|---|
| Model | `ApprovalOutcome = allowed-once \| rejected \| cancelled \| unavailable`; policy `ask \| never` (never resolves *inside* `decide()`, unpatchable); **no allow-always, no grant store** | approval only for `run_command` levels ≥2 (`CommandApproval`, 120 s window, fails closed, `:auto` bypass for the CLI); everything else gated by **static classification** |
| Escalation | `sandbox_permissions` + `justification` params; marker `[sandbox: escalation available — retry this exact <subject> once with …]`; `NEVER_SENTENCE` when approvals are off | none (no in-band escalation; backend chosen by config) |
| Sandbox vocabulary | `read-only \| workspace-write \| danger-full-access` — **file effects only** (no network/process dimension); Landlock launcher | `[:sandbox] :mode` auto/enabled/disabled × backend auto/systemd/bwrap/sandbox-exec/none; resource + process limits; bwrap `:degraded`; per-task TMPDIR |
| Static writes gating | none (approval is the only gate) | `@write_tools` (15) blocked repo-less and in read-only foreign repos; `Shared.validate_file_scope/3` node-scope enforcement on the 4 creating writers; shell pre-execution guard refusing `cd <main copy> && git checkout/switch/reset/merge/pull` |

Our gating is stronger and more opinionated; `dsh`'s is more *negotiable with the user*. Neither is a
performance issue for model alignment — leave as is, but note that our refusal texts are long and prose-y
(`You can still complete work within your assigned node, and remember you don't need to complete…`) where
`dsh` uses one line. Short refusals are better training-distribution matches.

---

## 6. Where we are already ahead (do not "align" these away)

1. **Spatial contract**: CONTEXT.md tree + routing tables + `read_context`/`search_context` + the
   current-state doctrine. `dsh` has only free-text `AGENTS.md`. This is our differentiator; keep the prompt
   budget for it.
2. **Worktree isolation per agent + commit DAG + reviewable branches** (`merge_and_report`,
   `genesis/agent_*`, merge-conflict auto-resolution). `dsh` offers a `create_worktree` tool and nothing else.
3. **Hard write-scope enforcement** at dispatch (node scope, foreign-repo read-only, repo-less) — `dsh` has no
   equivalent; it relies on approval prompts.
4. **Delegation depth 8 with typed roles** vs `maxDepth 1`, plus per-role delegation levels and turn budgets.
   Our recursive hierarchy is the product; `dsh`'s subagent is a helper.
5. **Budget awareness** (`TurnWarning`) and **graceful cancellation with preserved results** — `dsh` has
   neither (no turn budget, abort only).
6. **Scheduler-side concurrency control**: per-model LLM slots, peak/off-peak concurrency with hard-pause 0,
   multi-hour backoff queue, grow-only Finch pool reconciliation.
7. **Cost accounting** recomputed from the pricing catalog with peak/off-peak periods; `dsh` has no pricing
   table at all.
8. **Multi-modal in three places** (task-start attachments, tool results via `ToolOutput`, injected user
   messages); `dsh` has `read_image` + an offload placeholder.
9. **Sandbox backend matrix** (systemd-run / bwrap / sandbox-exec / none, with degradation probes) vs
   Landlock-only.
10. **Task data plane** (`run_command`, task-control commands with an approval gate, self-reflective agent) —
    `dsh` can only schedule its own future turns.

---

## 7. Proposals

Grouped into tiers by (alignment value) / (cost). "Impact" reflects likely effect on model performance for
models trained against `dsh`/Claude-Code-shaped harnesses.

### Tier 1 — cheap, high alignment value

| # | Proposal | Why | Impact |
|---|---|---|---|
| 1.1 | **Accept a text-only final answer as completion.** Keep `complete_task` (the DAG needs a Result: note, archive refs, git-status gate), but when the model replies with no tool calls and no pending work, treat it as an implicit completion (wrap the text as the result) instead of nudging up to 3×. Keep exactly ONE soft nudge for the first occurrence. | Our mandatory-terminal-tool protocol is the single largest deviation from the training distribution. Models finish by *stopping*. | high |
| 1.2 | **Fix malformed-argument handling** (three-stage parse): JSON parse failure → pass the raw string to the tool → tool reports `Error: invalid arguments: …`; `args_map == nil` must never reach a clause head inside the linked task. Optionally validate against the tool schema and emit the standard error string. | Today: `FunctionClauseError` in a linked `Task.async` **kills the agent**; the `{:exit, reason}` arm is dead code for raises. | high (robustness) |
| 1.3 | **Normalise every tool failure to `Error: <message>`.** Move `⚠️`/`💡`/`[NOTICE]`/`[WARNING]` hints out of the failure text: success hints stay as a trailing block after a blank line; failures lead with `Error:`. | Models key "is this a failure" off the `Error:` prefix (both providers' training). Emoji-prefixed failures read as prose. | high |
| 1.4 | **Shell tool affordances**: (a) accept `description` as an optional first param and mention it in the description ("put description before command"); (b) honour the advertised timeout — an omitted `timeout` currently truncates at 10 s while the schema says 180 s; (c) add `run_in_background` (or at minimum a documented no-background statement consistent with behaviour). | (b) is also a straight bug: any long test run that forgets `timeout` dies at 10 s. (a)/(c) are pure distribution alignment. | high |
| 1.5 | **Spill file for truncated output.** When a shell/read result exceeds the cap, write the full output to a temp path and append `[output truncated; full output: <path>]`; keep head+tail inline. | Trained behaviour: the model expects to be able to `read` the rest instead of narrowing blindly. Also removes the hardcoded `131072` in our hint string. | high |
| 1.6 | **`read_file` polish**: per-line clip at 2000 chars (`... (line truncated to 2000 chars)`), footer sentence `(Showing lines X-Y of N. Use offset=Z to continue.)` / `(End of file - total N lines)`, make `offset` past EOF an error, and fix the description/code mismatch (description says 128 KB, code gates at 256 KB). | Three of these are trained-verbatim strings in the read tool's output. | medium-high |
| 1.7 | **Tool-name aliases.** Extend `normalize_tool_name/1` (which already maps 9 shell spellings before the gates) to accept the trained names as aliases: `Read/read→read_file`, `Write/write→write_file`, `Edit/edit→edit_file`, `Bash/bash/shell→run_bash`, `Grep/grep→rg`, `Glob→glob`, `Task→subagent_manager`, `WebSearch/web_search→search_web`, `TodoWrite→todo_write` (once 2.1 lands). Keep our canonical names in the schemas. | Zero-risk compatibility shim: models sometimes emit the name they memorised. Costs a map entry; recovers otherwise-lost calls that currently fall into the "Unknown tool … Did you mean" path. | medium-high |
| 1.8 | **`glob`/`grep` result envelopes**: give `rg` sensible defaults when the model passes bare args (`-n`, no-heading, a 250-match cap) and prefer a structured `Found N matches` render for the no-flags case; put the truncation locator in a footer, like `glob`. | Our `rg` is a raw escape hatch; models expect a capped, structured grep. Also protects against a 50 000-match `rg` flooding the context. | medium |
| 1.9 | **Inject a time context** (date/time, refreshed ~10 min, or at each compression). | Agents currently have no clock; any "how stale is this" reasoning is blind. | medium |
| 1.10 | **Silent-truncation audits**: stop silently trimming `new_string` (`String.trim_trailing/1`) — either keep whitespace verbatim or report the trim. | Silent mutation of model input is the worst kind of divergence. | medium |

### Tier 2 — moderate cost, high training-prior value

| # | Proposal | Why | Impact |
|---|---|---|---|
| 2.1 | **`todo_write` tool + durable per-agent todo state**, surfaced in the dashboard (a tasks-page/agents-page panel) and re-injected into the context when it changes. Start as a flat list (`content`, `status`: pending/in_progress/completed); no dependencies field needed. Make it available to write-capable agents (and arguably read-only ones — investigation checklists are real). | The single most-used affordance in every modern coding harness; we have *nothing*. Models reach for it habitually and will currently invent it or waste turns. | high |
| 2.2 | **Skills catalog injection** (`<system-reminder><available_skills>` user message, republished only when the name/description digest changes), keeping `skill_list` for the full listing. | We ship a skills system the model has to *guess* exists. `dsh` solves this with a republished catalog; it costs ~1 line per skill and is cache-stable when digest-gated. | high |
| 2.3 | **Two-stage compression**: (a) model-free pruner for old tool results first (head/tail keep, `[... tool result middle pruned ...]`), only call the model if still over threshold; (b) turn the result into a **appended checkpoint user-message** that replaces a *recent span* while the older prefix and the system message stay untouched, wrapped with the "continue without acknowledging" instruction; (c) keep N recent turns intact. | Fixes three problems at once: needless summarisation cost, cache destruction every cycle, and total loss of history (which is why our summaries have to be exhaustive). The checkpoint-as-user-message + "do not acknowledge" phrasing is directly from the training distribution. | high |
| 2.4 | **Window-relative compression threshold** with a floor/ceiling: derive from each profile's context window (e.g. `min(0.8·W, W − reserved − headroom)`) with the current 180 K as a fallback when the window is unknown. | A fixed 180 K is simultaneously too eager (1 M windows) and too late (128 K windows). | high |
| 2.5 | **Superseding runtime-context message** instead of refreshing the *first* user message: keep `<context>`/`<objective>` byte-stable for the whole run (cache-stable, compression-safe) and deliver CONTEXT.md/routing/authority updates as a new user-role snapshot with "This snapshot supersedes earlier runtime-context snapshots." | Today a mid-run CONTEXT.md edit is invisible until compression *and* the refresh rewrites message #1, invalidating the cache. Two birds. | medium-high |
| 2.6 | **Repeat-tool-call guard**: count identical `{name, args}` across turns (not just within a response); at 3 gentle, 5 firm, 8 hard, inject the reminder as tool-result context. | Our only loop protection is the no-tool-call nudge; a model stuck re-running a failing command burns turns silently. | medium-high |
| 2.7 | **Read-before-edit staleness check** (soft first): record `{path → mtime, size}` on `read_file`; on `edit_file`/`write_file` over a changed file, either warn inline (`file changed since it was read — re-read the file, then retry` — as an *error* so the model re-reads) or at minimum append a warning. | Prevents the classic lost-update failure and matches a trained error string. Risk: subagents legitimately edit files they never read (e.g. after a parent's report) — start with warn-only, promote to hard-fail per tool after measuring. | medium |
| 2.8 | **`ask_user_question`**: a structured question tool (header + 2–4 labelled options + free-text), answers returned as JSON; in the dashboard, render as buttons in the chat/agent panel. Complements `guide_user` (one-way) and `CommandApproval` (approve/deny). | Models trained on `AskUserQuestion` will call it; today such a call is an unknown-tool error. Also genuinely useful for the Home chat and ambiguous objectives. | medium |
| 2.9 | **Shorten and re-register role prompts.** Concretely: (a) move delegation mechanics text from Manager/Architect prompts into the `subagent_*` tool descriptions; (b) deduplicate the CONTEXT.md doctrine fragment (currently 4 copies); (c) replace `⚡`/`CRITICAL:`/`STRICT` with plain imperatives; (d) target ~4–6 K chars per role (from 14–18 K). Measure by running the same task set before/after. | Prompt-register alignment; also frees budget for Tier-2 features. This is the highest-leverage *prompt* change and the one that needs an A/B rather than a leap of faith. | high (uncertain magnitude) |
| 2.10 | **Plan affordance**: either full plan mode (`enter/exit_plan_mode` + user review gate) or, cheaper, a "produce a plan first, then implement" convention encoded in the Manager/Architect prompt + the todo list from 2.1. | `dsh`'s plan mode is prompt-only (no read-only enforcement, deliberately, for cache stability) — that makes a light version cheap for us too. | medium |

### Tier 3 — structural (do deliberately, or not at all)

| # | Proposal | Why | Impact |
|---|---|---|---|
| 3.1 | **Non-blocking delegation + live child control**: spawn returns an id immediately; results arrive as an ordinary user message ("Background subagent `<id>` finished … Its closing message:"); add `send_message`, `interrupt_agent`, `list_agents`. | Unlocks the thing our prompt *claims* ("continue useful work while they run") but cannot do — we block on `GenServer.call :infinity`. Also fixes the all-or-nothing batch: today one slow child stalls the parent's whole batch. Keep our depth 8 and unbounded width; add `dsh`'s reject-with-message semantics at a configurable ceiling (`max_active_subagents`, default high/none for us). | high (capability), high (cost) |
| 3.2 | **Durable transcript as a session log** (append-only events, derived request, `surfaceOp` span replacement). Practical scope for us: persist per-agent messages in SQLite (we already have the store), make `build_request` a pure function of `(base_commit, agent_id, message log)`, and use span-replace for compression instead of rebuild. | Enables: crash/kill **resume of the real transcript** (today a restart loses the conversation and resume starts a text block over), rewind/fork from `(commit, turn)`, and review-page replay. Pairs perfectly with our existing git DAG — this is "the temporal dimension for conversations", which is exactly our thesis. Do NOT adopt JSONL; keep SQLite. | high (capability), very high (cost) |
| 3.3 | **Deterministic orchestration tool** (`workflow` analog): an Elixir/JSON script tool exposing `agent()`, `parallel()`, `pipeline()`, `phase()` so a Manager can express a fan-out plan as data rather than prose. | Our TaskScheduler returns a *prose* execution sequence that a Manager then interprets by hand. A script tool makes that reproducible and testable. | medium (high cost) |
| 3.4 | **Goal state** (`create_goal`/`get_goal`/`update_goal` + round driver). Cheap version: expose the task objective + a `goal_complete` assertion in `complete_task` and re-inject the objective in long runs. | Our objective never decays; `dsh` needs goals because it has no task DB. Lowest priority of the three. | low-medium |
| 3.5 | **Background jobs** (`job_list`/`job_output`/`job_kill`) and/or `promoteOnTimeout`; optionally the 6 `terminal_*` PTY tools. | Dev-server/test-watcher workflows are impossible today ("background processes are not supported"). Pairs with 1.4/1.5. | medium (high cost) |
| 3.6 | **A real `web_fetch`** (HTML→GFM, 200 K cap, same-origin redirect policy, SSRF pinning) and delete/repair `curl` (currently unlisted, unsandboxed, with two dead params). | `curl` is a footgun with declared-but-unused limits; `web_fetch` is what models call. | medium |
| 3.7 | **Web search polish**: accept `queries: string[]` (1–4), prepend the untrusted-data notice, end with `Sources:` + "cite these URLs as markdown links". | Trained shaping for the same tool; also protects against prompt injection in results. | medium |
| 3.8 | **MCP resources / LSP tool / `run_code` (PTC) / self-introspection** | Each is a real capability, none is load-bearing for our thesis. Revisit when a concrete need appears. | low |
| 3.9 | **Prompt-cache discipline as a policy**: band the system prompt (stable instructions first, environment last), never rewrite message #1 (see 2.5), skip prompt reassembly on retry (we already do), and optionally opt into provider prompt caching via ReqLLM (`cache_control` is caller-opt-in — we never pass it). | We are paying full price on every turn of a 1000-turn root agent. This is a cost-and-latency win with no behavioural risk. | medium-high (cost) |

### Anti-proposals — do NOT copy these from `dsh`

| `dsh` behaviour | Why it would hurt us |
|---|---|
| No turn budget; capacity rejection instead of queuing | Our long autonomous runs need budgets + queues; we already have better machinery |
| `maxDepth = 1` | Our recursive Context Tree hierarchy is the product |
| `allowed-once` only, no grant store | Our approvals are per-command in a 1000-turn run; a grant store (or auto mode) is necessary |
| JSONL session store, no SQLite | We have a task registry, projections, and a dashboard; SQLite + Ecto is right |
| Plan mode without read-only enforcement | Fine for them (single agent), risky for us (a plan agent that edits is a scope violation) |
| Prompt as a session-log node (no provider `system` field) | Clever for their replay model, but our providers/tests assume a real system message; needs 3.2 first |
| `.agents/skills` depth-1 scan, no byte budget, no omission notice | Our skills tree is hierarchical and node-scoped; copying this would break inheritance |

---

## 8. Suggested sequencing

1. **Round 1 (correctness + conventions, no design debate)**: 1.2 (crash), 1.4b (10 s timeout), 1.3 (`Error:`
   normalisation), 1.5 (spill file), 1.6, 1.7, 1.8, 1.10. All are local, testable, and do not change agent
   behaviour policy.
2. **Round 2 (protocol alignment)**: 1.1 (text completion), 2.1 (`todo_write`), 2.2 (skills catalog), 1.9
   (clock). These change what models *reach for*; measure on a fixed task set.
3. **Round 3 (context economics)**: 2.3, 2.4, 2.5, 3.9 — compression redesign + cache discipline; measured by
   cost per completed task at equal quality.
4. **Round 4 (prompt diet)**: 2.9 A/B against the current prompts, with 2.6, 2.7, 2.8 as independent add-ons.
5. **Round 5 (structural, if justified)**: 3.1 (non-blocking delegation), then 3.2 (durable transcript).

Each round should be evaluated with the same objective suite, tracking: turns-to-completion, tool-call error
rate (parse failures, unknown tools, unique-match edit failures), compression count and cost per task, and
human review acceptance rate.

---

## 9. Implementation status — what is actually shipped

This section records, per proposal above, what landed in the codebase and the decisions taken where we
deliberately diverged from `dsh`. It is a status ledger, not a re-derivation: the diff tables above remain the
authoritative comparison.

### 9.1 Shipped — completion protocol (proposal 1.1)

- `EvoGit.Agent.CompletionProtocol.classify/1` (`apps/evo_git/lib/evo_git/agent/completion_protocol.ex`) →
  `{:tool_calls, calls}` | `{:text_reply, text}` | `:empty`. Built on `ReqLLM.Response.tool_calls/1` +
  `ReqLLM.Response.text/1`, so only `:text` content parts count — for a streamed/reasoned reply whose assembled
  content is `[text, thinking]`, the reasoning text can never be promoted into the report.
- **A reply with no tool calls ends the run, and its text is the report** — exactly `dsh`'s rule. The text is
  wrapped into the same `%Result{}` the explicit route builds, so the scheduler, `merge_and_report`, archive
  refs, usage accounting, persistence and the dashboard all stay unchanged.
- Two completion routes share one builder. The implicit route **commits the worktree before capturing
  `commit_sha`** (`AgentScheduler.Dispatch.commit_pending_in_worktree/0` first) — otherwise `merge_and_report`
  takes the no-changes path and the work dies with the worktree. The dirty-workspace gate deliberately does NOT
  apply to the implicit route: the model has already finished, and a legitimate finish must never be turned
  into a refusal.
- `complete_task` remains supported and optional.
- The no-tool-call nudge budget dropped from 3 to 1 and now fires only for `:empty` (a genuinely empty
  response); a response with usable text is not a protocol violation.

### 9.2 Shipped — tool-call robustness (proposals 1.2, 1.4b, 1.3, 1.5)

- `EvoGit.Agent.ToolInvocation` (`agent/tool_invocation.ex`): a 3-stage tolerant argument parse (map → raw
  non-blank string → explicit error) so a malformed tool-argument payload produces a normal
  `Error: invalid arguments: …` tool result instead of a `FunctionClauseError` inside a linked `Task.async`.
  `arguments_map/1` is total; `resolve_timeout/4` centralises timeout resolution.
- Tool raises are contained per call (`Error: Tool execution crashed: <banner>`), while `:kill`/`:shutdown`/
  `{:shutdown, _}` still propagate — cancellation semantics are untouched.
- Shell timeout: an omitted `timeout` on the platform shell tool now resolves to `max(120_000, configured)`
  clamped by `[:scheduler, :max_tool_timeout]` (was silently cut at the generic 10 s default). An explicit
  positive `timeout` is honoured as before.
- Truncated tool output now spills the full text to a file under `EvoGit.TaskTmpdir.current/0` and tells the
  model the path (`[output truncated; full output: <path>]`) instead of destroying it.
- One failure shape: `EvoGit.Agent.Tools.Failure.error/1,2` + `notice/1` normalise every tool failure to a
  single `Error: ` prefix (stripping the legacy `⚠️`/`💡`/`[NOTICE]`/`[WARNING]` markers).

### 9.3 Shipped — tool-surface alignment (proposal 1.2 name-distance table)

- `EvoGit.Agent.ToolNames` (`agent/tool_names.ex`) is the single alias spine: `normalize/1`, `model_name/1`,
  `shell_tool_name/0`, `matches_any?/2`, `table/0`. Model-facing canonical names are now `read`, `write`,
  `edit`, `bash`, `web_search`; internal dispatch keys (`read_file`/`write_file`/`edit_file`/`run_bash`/
  `run_powershell`/`search_web`) are unchanged, and every legacy spelling is accepted as an alias
  (case-insensitively), so `agents.toml` tool whitelists and any stale prompt keep working.
- Normalisation runs at the TOP of `Tools.execute/5`, **before** the repo-less / read-only-foreign-repo write
  guards. This ordering is load-bearing: the shell is a write tool, so normalising after the guards would let a
  repo-less agent bypass the write block by calling `Bash`.
- **`rg` deliberately keeps its name.** Decision: ripgrep is more powerful and far easier to distribute
  cross-platform than a `grep` shim; `grep`/`ripgrep` are accepted as aliases, so a model reaching for `grep`
  still lands on `rg`. This is the one name we chose not to converge.
- Output conventions aligned: `read` clips over-long lines, adds the
  `(Showing lines 1-3 of 30. Use offset=4 to continue.)` / `(End of file - total N lines)` footers and a proper
  past-EOF error; `edit` inserts `new_string` byte-for-byte (no silent trailing trim); `rg` with bare
  `PATTERN [PATH]` args injects `--line-number --no-heading` and caps at 250 matches with a narrowing footer
  while an explicit flag set passes through untouched; `glob` reports `[showing N of M files; …]`.
- Unknown tools answer with a closest-name suggestion (`String.jaro_distance/2 ≥ 0.7`) plus the current
  available-tool list, so the model can self-correct instead of repeating the call.

### 9.4 Shipped — `web_fetch`, `lsp`, and the retirement of `curl` (proposals 3.6, 3.8)

- **`curl` is gone** (unlisted, unsandboxed, two dead params, and `System.cmd("curl")` was an `:enoent` hazard).
  A `curl` call now yields `Error: Unknown tool 'curl'`.
- **`web_fetch`** (`agent/tools/web_fetch.ex` + the pure `agent/tools/html_to_markdown.ex`): one HTTP GET via
  `Req` (an existing dependency — no new service, no third-party proxy, entirely local), streamed with a raw
  byte cap so an oversized body stops at the socket, HTML→Markdown conversion, ≤5 manual redirects restricted
  to the same scheme + same host, a best-effort private-host/SSRF blocklist over every resolved address, and
  the envelope `Fetched <url> (HTTP <code>)`. IP pinning is explicitly NOT claimed — it is a guard, not a
  boundary.
- **`lsp`** (`agent/tools/lsp.ex` + the pure `agent/tools/lsp/protocol.ex`): one tool with
  `action ∈ diagnostics|hover|definition`, speaking the ASCII `Content-Length` LSP base protocol over stdio to
  a **user-configured** server (`[lsp] enabled/command/args/timeout/diagnostics_timeout`) — nothing bundled or
  downloaded, and unconfigured it returns a self-explaining `Error: no language server configured …`. Every
  wait is bounded, and the server is SIGKILLed by OS pid in `try/after` so no orphan survives.

### 9.5 Shipped — background jobs, sandbox-integrated (proposal 3.5, minus PTY)

- `bash` gained `run_in_background`; companion tools `job_output` (delta reads + optional bounded `wait`),
  `job_list`, `job_kill` mirror `dsh`'s names, job-id shape and envelopes. `job_output`/`job_list`/`job_kill`
  are control tools (in both schema lists, never write, never serial); **starting** a background process is
  classified as a write CALL (`Tools.write_call?/2`) — it can mutate anything a foreground command can, so a
  repo-less or read-only-foreign-repo agent must not start one, while it may still collect and kill its own
  jobs.
- `EvoGit.BackgroundJobs` (supervised registry) is the bookkeeping layer; `EvoGit.Sandbox` gained
  `spawn_detached/1`, `kill_detached/1`, `detached_status/1` so every backend answers consistently, with the
  per-backend containment mechanism chosen from what the backend already provides (a named systemd transient
  unit on the systemd backend, `--die-with-parent` + session-leader tree kill under bwrap, a tree kill
  elsewhere).
- **The primary leak guarantee is a `Process.monitor/1` on the OWNING AGENT pid** — one choke point that covers
  normal completion, crash, graceful cancel and force kill. Defence in depth: `terminate/2` reaps every job,
  and worktree destruction calls `reap_under/1` immediately before the directory is removed, so a job whose cwd
  lives inside `.genesis/workers/<id>` can never outlive it. Output always lands in a file under the per-task
  tmpdir, never a live pipe that could block on a dead reader.
- **PTY is deliberately not implemented**: pure pipes with file-backed output cover the real workflows
  (dev server, test watcher) and a dependency-free cross-platform PTY would not be honest. The
  block-buffering caveat is documented instead.

### 9.6 Shipped — context compression (proposals 2.3, 2.4, 2.5)

`EvoGit.Agent.ContextCompression.compress_if_needed/2` is now two stages, composed from
`agent/compression/`:

1. **`Compression.Threshold`** — the trigger is window-relative (`min(0.8·W, W − reserved − 64K)`, floored at
   `min(32_000, 0.9·W)`) instead of the fixed 180 K, using the model's real context window from the catalog;
   the old config value remains the unknown-window fallback.
2. **`Compression.ToolResultPruner`** — a model-free stage one: results older than the recency window are cut
   to head + tail with an explicit `[... tool result middle pruned ...]` marker, never splitting a
   `tool_calls` ↔ `tool_call_id` pair and never touching the system or first user message. If pruning alone
   brings the context under the threshold, **no LLM call happens at all**.
3. **`Compression.Checkpoint`** — stage two delivers the summary as a single user-role checkpoint message that
   *span-replaces* the older span, instructing the model to continue without acknowledging it, while the last
   K=4 turns stay verbatim. The system message and the first user message stay **byte-identical** (cache
   stability), and the runtime-context refresh is an APPENDED superseding user message — message #1 is never
   rewritten.
- `Compression.LlmRetry` keeps our failure model rather than `dsh`'s: bounded transient retries mirroring
  `call_llm_with_retry/5`, one slot acquisition per attempt, non-retryable provider errors fail fast, and
  exhaustion RAISES so the scheduler's crash-retry/backoff applies. A pruned-only silent fallback was rejected
  because the retained tail can itself overflow the window, which would defer a hard provider overflow with no
  operator signal.

### 9.7 Shipped — prompts and the runtime clock (proposals 1.9, 2.2-adjacent)

- One canonical finish sentence replaces the "you must call `complete_task`" mandate in every role that has a
  loop (Architect, Manager, Executor, ContextExtractor, TaskScheduler, GenesisPlanner, Investigator, SkillExtractor,
  SelfReflective) — the read-only Investigator previously had no finish statement at all.
- All prompt-side tool references were repointed to the model-facing names; `web_fetch` / `lsp` are mentioned
  where they solve a role's problem (docs lookup, Elixir diagnostics) and omitted where they would be
  catalogue padding.
- **A clock now exists**: `ContextBuilder.build_clock_section/1` renders
  `Current local time: YYYY-MM-DD HH:MM (Zone)` as the last line of the runtime-context block, re-rendered only
  into the appended compression refresh (so the cacheable prefix stays stable). A `:now` key on the state map
  is the deterministic test seam.
- Tone alignment only: emphatic mandate prose (`⚡ FIRST ACTION`, `CRITICAL:` caps, emoji bullets) was restated
  as plain sentences with every requirement preserved; per-role prompt size moved by 0–5%.

### 9.8 Deliberately NOT done

| Item | Why |
|---|---|
| `todo_write` + durable todo state | Trained for a different model family; our turn/delegation structure carries the plan |
| `send_message` / `interrupt_agent` / `list_agents` (3.1) | Same reason; our delegation is blocking by design and cancellation is task-level |
| Plan mode | Needs read-only enforcement to be safe for us, and its value overlaps our TaskScheduler prose plan |
| MCP, `run_code`/PTC, `workflow`/`ralph` script tool | No concrete need yet |
| PTY / `terminal_*` | See 9.5 |
| Skills-catalog injection, repeat-tool-call guard (3/5/8) | Both are `dsh`-specific compensations; unmeasured for us |
| Durable transcript / JSONL session log (3.2) | The largest structural proposal; needs its own round |
| Prompt diet (2.9) | Must be A/B'd, not shipped blind |
| `web_search` `queries[]` shaping + untrusted-data notice (3.7) | Still open |
| Prompt-cache `cache_control` opt-in (3.9) | Still open; the byte-identical message #1 invariant is now in place, which is the prerequisite |
