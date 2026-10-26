# EvoGit — Root

## Intent

EvoGit is an evolutionary software development framework built in Elixir.
It models a codebase as a hierarchical **Context Tree** (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension); AI agents recursively build and optimize software, guided by spatial contracts in per-directory CONTEXT.md files.
This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `./apps/evo_git/` | Core runtime — agent execution, Git interactions, CLI |
| `:evo_dash` | `./apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization and task management |

The full design specification is documented across the CONTEXT.md tree.

## Routing Table

- `./apps/evo_git/` → Core runtime (agents, scheduler, git adapter, runtime phases)
- Task-store read path & per-agent archive — one relational row per archived agent in `task_agent_archives` (written from the completing agent's own process, so the registry GenServer never blocks on a commit; the task row never carries archive data), read as a paged roster (`ORDER BY depth, agent_id`; lean by default — `:include_results`/`:include_settings` opt IN a heavier projection, `:include_total: false` skips the `COUNT(*)`) plus a lazily fetched single-agent `result`, plain-JSON TEXT columns (no compression anywhere), paged summary projection + lazy detail, fault-isolated reads that degrade rather than kill a GenServer, `mix store.maintenance --vacuum` → `./apps/evo_git/` (`store/`, `task_registry/`, `priv/repo/migrations/`) — detail: `apps/evo_git/lib/evo_git/store/CONTEXT.md`
- Multi-modal content parts at ANY agent step (images/audio on tool results + injected user messages; the task-start `:attachments` opt on the ROOT's first message) → `./apps/evo_git/` (`attachments.ex`, `agent/tool_output.ex`, `agent/tool_dispatch.ex` wrap boundary) — detail: `apps/evo_git/CONTEXT.md` ("Multi-Modal Content")
- LLM request/retry policy — a non-retryable provider error (400-class, `retryable=false`, e.g. a rejected parameter) fails fast with ONE request and a self-diagnosing terminal message (no agent crash) instead of a retry storm; generation parameters are filtered per model/provider (Z.AI/GLM rejects `top_k`/penalties, `temperature > 1.0`, out-of-set `reasoning_effort`, over-limit `max_tokens`) → `./apps/evo_git/` (`agent/llm_error.ex`, `config/schema/llm_constraints.ex` via `Config.Schema.LLM.profile_generation_params/1`)
- LLM token/cost accounting — counts come from ReqLLM, but COST is recomputed from raw tokens + the `llm_db` catalog (`LLMDB.Pricing.components_for/2`: only `kind: "token"` components minus `pricing.excluded_cost_components`, period from `EvoGit.PeakHours`) rather than ReqLLM's reported cost, which prices a period-gated catalog only from a `pricing_context` EvoGit never passes; nil recompute → reported value → `./apps/evo_git/` (`agent/cost.ex`, `agent/usage.ex`), with a "cost is best-effort" notice at every dashboard cost display (`Helpers.cost_estimate_notice/1`)
- Reasoning/thinking vs response text in the vendored LLM stack — `./deps/` is git-ignored vendored code (read it, never edit); ReqLLM **1.29.0** (`deps/req_llm/mix.exs:4`) decodes DeepSeek's `reasoning_content` to a `:thinking` `StreamChunk` (`deps/req_llm/lib/req_llm/provider/defaults.ex:1458`) and `content` to `:text` (`:1435`), read via `ReqLLM.Response.thinking/1` (`lib/req_llm/response.ex:197`) vs `.text/1` (`:100`), with per-field streaming deltas (`decode_openai_delta/1`, `defaults.ex:1609`); thinking can surface as "response" ONLY when a consumer joins ALL `Message.content` parts — a streamed reply assembles `[text, thinking]` (`defaults/response_builder.ex:228-244`) and the same text is also materialized into `message.reasoning_details` (`materialize_reasoning_details/4`, `:365-376`)
- `./apps/evo_dash/` → Web dashboard (LiveView pages, components, task registry) — the task-archive views (review page Archive tab + task-card archive) read the paged per-agent roster and fetch one agent's `result` on demand, with a paged streaming export
- `/agents` page — dual-view inspector (spatial **agent tree** + temporal **commit-history graph** switched by a segmented control in the left panel header; one shared agent-detail panel) → `./apps/evo_dash/` (`live/agents_live/` + `components/agents_components/`), backed by the core commit-graph RPC (`EvoGit.CommitGraph` in `./apps/evo_git/`)
- Self-reflective agent / Home chat / guide overlay → `./apps/evo_git/` (agent + repo-less runtime + task-control tools) + `./apps/evo_dash/` (Home chat page `EvoDashWeb.HomeLive` at `GET /help`, reachable via the sidebar **Help** entry; root `/` maps to Projects at `/projects`; global guide hook/panel) — see "Self-Reflective Agent (repo-less, chatbot-style)" below
- **Agent-harness alignment** — before changing tool schemas/names, tool-result formatting, role `system_prompt` text, context compression, or the completion protocol, read `./docs/harness-alignment.md` first (verified diff vs the DeepSeek Harness `dsh`, `/home/bill/Source/deepseek-harness`, tiered proposals, §9 shipped). Implementation in `./apps/evo_git/` (`agent/` — tool names/aliases, completion protocol + invocation, tool schemas incl. `web_fetch` and the default-OFF `lsp` (schema appended only when `[lsp] enabled = true` + a `command`; `EvoGit.Config.lsp_enabled?/0`), background-job tools, context compression + `compression/`, context_builder, output_sanitizer, tool_dispatch; plus `agents/*.ex`)
- Completion protocol — a reply with NO tool calls ends the run and its text IS the report (`complete_task` stays supported and optional; the implicit route commits the worktree before capturing the commit sha) → `./apps/evo_git/` (`agent/completion_protocol.ex`, `agent/tool_dispatch.ex`)
- Tool names/aliases (`read`/`write`/`edit`/`bash`/`web_search` model-facing, internal dispatch keys unchanged, `rg` keeps its name) → `./apps/evo_git/` (`agent/tool_names.ex`) — normalization runs BEFORE the repo-less / read-only-foreign-repo write guards (load-bearing: the shell is a write tool)
- Background jobs (`bash` `run_in_background` + `job_output`/`job_list`/`job_kill`; no PTY) — lifetime owned by the AGENT pid (`Process.monitor`), containment via `EvoGit.Sandbox.spawn_detached/kill_detached`, jobs whose cwd sits in a worktree reaped before it is removed; a terminal job the agent has NOT already observed is announced ONCE at the next turn boundary as ONE combined notification-only `[NOTICE]` user message (batched, exactly-once via `announced`, ids/statuses only; `job_output`/`job_list` — including an awaited `wait: true` read — and a successful `job_kill` mark a job announced, so the agent is never told about an outcome it already saw, while a failed kill stays unannounced), and jobs are re-injected ONLY by the summarising (stage-2) compression refresh as a single `## Background Jobs` snapshot (stage 1 injects none) → `./apps/evo_git/` (`background_jobs.ex`, `sandbox/background.ex`, `agent/tools/job_*.ex`, `agent/background_job_notice.ex`)
- Context compression — two stages, window-relative from each `[[llm.models]]` profile's `context_window` (default 200_000; NEVER the catalog metadata), optional `[llm] compression_threshold_tokens` override: stage 1 prunes old tool results model-free and is adopted ONLY when it projects down to `min(threshold, tool_result_pruning_target_fraction × window)` (default 0.5), else stage 2 runs over the ORIGINAL context; stage 2 is a span-replacing checkpoint user message keeping the system + first user message byte-identical and the last K=4 turns verbatim; `[llm] tool_result_pruning` toggles stage 1 → `./apps/evo_git/` (`agent/context_compression.ex`, `agent/compression/`)
- CONTEXT.md conflict handling — writes are node-scope-enforced (own node + descendants; `nil` = allow-all; root `./` = anywhere); on subagent conflicts `EvoGit.Agent.ContextMerge` aborts the octopus merge and re-merges children sequentially in spawn order, resolving ONLY `CONTEXT.md` conflicts by node-path ownership (own `CONTEXT.md` outranks an ancestor's edit; out-of-scope edits are dropped and reported with their diff; equal-ownership and non-CONTEXT conflicts are never auto-picked) and returns a per-child report (node path, agent type, branch, final commit, status) with unmerged branches preserved → `./apps/evo_git/` (`agent/context_merge.ex`, `agent/subagent_processing.ex`, `agent/tools/context.ex`, `task_registry/merge_context.ex`)
- `./docs/` → Long-form design records & reference documentation (`auto-update.md` — desktop auto-update design record; `experiments.md` — per-regime experimental results + figures, linked from the README; `harness-alignment.md` — Genesis-vs-DeepSeek-Harness diff + alignment proposals)
- `./config/` → Environment-based Elixir configuration
- `./rel/` → Mix release overlays (`rel/genesis/`, `rel/genesis_remote/` — vm.args + env scripts per release; distribution config for SSH remote dev)
- `./desktop/` → Tauri desktop shell (native WebView wrapper, sidecar lifecycle management)
- `./nix/` → NixOS build support (vendor bundling helper for local desktop builds)
- `./.github/workflows/` → CI/CD pipelines (desktop app build on release)

## API Surface

### Top-Level Files

| File | Purpose |
|------|---------|
| `mix.exs` | Umbrella Mix project — apps_path, three releases: `genesis` (both apps), `genesis_desktop` (standard mix release with `include_erts`, bundled as a Tauri resource), `genesis_remote` (headless evo_git-only daemon tarball for SSH remote dev). Reads the version from `VERSION`. |
| `VERSION` | Single source of truth for the project version; all umbrella `mix.exs` files read it, the desktop manifests are synced by `mix bump.version`. |
| `flake.nix` | Nix flake — `devShells.default` (Erlang/OTP 29, Elixir 1.20, Rust, Tauri v2 native deps), `packages.default` via `genesis.nix` (`nix build`), `apps.default` (`nix run`). |
| `genesis.nix` | Nix derivation — builds the Genesis Mix release with `beamPackages.mixRelease`, pre-fetched Rustler NIFs and vendored ripgrep/git. |
| `genesis-desktop.nix` | Nix derivation — builds the `genesis_desktop` Mix release, then the Tauri Rust binary via `rustPlatform.buildRustPackage`, wrapped together; `packages.desktop`. |
| `README.md` | User-facing documentation: installation, CLI usage, architecture overview |
| `.formatter.exs` | Code format configuration (umbrella-aware; see Development Notes) |
| `LICENSE` | Project license |

### CLI Interface

```bash
# Setup — guided LLM configuration wizard
mix run -e 'EvoGit.CLI.main(System.argv())' -- setup

# Genesis — create a codebase from a prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<prompt>" [-f file] [-p path] [-R <id:>path] [-m <model>]

# Evolution — modify an existing codebase
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<objective>" [-p path] [-R <id:>path] [-m <model>]

# Reflect — repo-less self-reflective Q&A (no repo, no merge)
mix run -e 'EvoGit.CLI.main(System.argv())' -- reflect "<objective>" [-m <model>]

# Run — execute command-shell commands (terminal access to the shared task-control data plane)
mix run -e 'EvoGit.CLI.main(System.argv())' -- run 'ListTasks.list_tasks'
mix run -e 'EvoGit.CLI.main(System.argv())' -- run 'StartTask.start_task evolve "Fix the bug"'
```

**Task data plane — NO config overrides.** The CLI never mutates scheduler/config state: the session-level override flags (`-c/--concurrency`, `--tool-concurrency`, `-r/--retries`, `-t/--max-turns`, `--max-turns-root`) are removed (concurrency/retries/turn caps are set persistently in config.toml; passing a removed flag prints a pointer).
`genesis`/`evolve`/`reflect` submit REGISTERED background tasks through the SAME data plane the dashboard (`NodeContext.start_task`) and the self-reflective shell's `StartTask.start_task` use — `EvoGit.TaskRegistry.start_task/2` → TaskExecutor → runtime phases — then wait on PubSub for the terminal status (foreground semantics; the CLI BEAM hosts the scheduler), printing `Task <id> started` / `Task <id> <status>.`; opts use the data-plane key contract (`:path` resolved absolute pre-enqueue, `:mode` STRING — `new`/`existing` genesis, `simple`/`custom` evolve; RuntimeOpts raises on atoms — `:prompt`/`:objective`).
Task-level flags: `-f/--file`, `-p/--path`, `-d/--mode`, `-b/--build-system` (genesis new), `--agent <id>` (custom root agent from `<config_dir>/agents.toml`), `-R <id:>path` foreign repos (repeatable, read-only), `-n/--node` + `--starting-commit` (evolve), `--archive`; `-m/--model` is pure TASK-LEVEL model selection (never a scheduler override), resolved pre-enqueue against configured `[[llm.models]]` profiles (exact profile id → `id:provider:model` id segment → a profile's `model` string; unknown → error listing profile ids) and passed as `model_id` + `model_id_locked: true`.
`run '<command>'` executes the self-reflective agent's shell command language via `EvoGit.CommandShell.execute/2` with `approval: :auto` (the terminal user IS the human; the /help-chat approval gate applies only to agent-initiated commands); `evogit setup` remains the persistent-config wizard (file writes, not a session override).
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_git/lib/evo_git/CONTEXT.md`.

### Custom Agents & Custom Task Mode

Users define custom agents declaratively in `<config_dir>/agents.toml` (pure TOML: `name`, `description`, `prompt` system prompt, `agent_type` read/read_write, `delegation_level`, `model_id`, `max_turns`, `tools`, `subagents`; ids auto-derived from slugified names).
An optional `[model_selection] script` is a short user Elixir body evaluated per agent spawn (an `agent` map in scope: `agent_type`, `custom_agent_id`, `depth`, `parent_id`, `task_id`, `objective`; last expression = model profile id, `nil`/`""`/`false` → default) via `EvoGit.CustomAgents` / `EvoGit.Agents.Custom` / `EvoGit.CustomAgents.ModelSelector` (compile-once stat-validated cache, never raises user-code errors).
Model priority per spawn: user-locked (`-m` / explicit dashboard pick) → script → per-agent default → scheduler default.

**Custom tools** — users add LLM-callable tools by dropping Elixir source (`.ex`/`.exs`) or compiled BEAM (`.beam`) into `<config_dir>/tools/`: each file implements the `EvoGit.CustomTools.Tool` behaviour (`schema/0`, `execute/2`, optional `read_only?/0` defaulting to `false` → WRITE).
They load lazily + cached by file fingerprint, are opt-in via a custom agent's `tools` whitelist (an absent `tools` yields only the built-in set), and dispatch through the SAME tool-dispatch + write-gating path as built-ins (repo-less / read-only-foreign-repo guards apply); dashboard Settings → Agents shows a "Custom Tools" panel (read-only/write badge + broken-file errors) alongside the custom-agents list editor + model-selection script editor.
Detail: `apps/evo_git/lib/evo_git/custom_tools/CONTEXT.md` + `apps/evo_git/lib/evo_git/custom_agents/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

**Custom task mode** (entry point for custom root agents): a 4th dashboard task mode **"Custom Agent"** (combined-mode string `"custom_agent"`) maps to `{:evolve, mode: "custom", agent: <custom_agent_id>}` — task type stays `:evolve`, mode opt value `"custom"` (a STRING from every entry point; RuntimeOpts normalizes); `EvoGit.Runtime.Evolution.run/2` routes `"custom"` to a custom-root path with evolve semantics (reviewable `merge_and_report`), and a missing/empty `:agent` raises a descriptive ArgumentError before any repo I/O.
CLI: `evolve --mode custom --agent <id>`; genesis rejects custom mode ("evolve-only"); custom agents are root-only this version (not spawnable as subagents), `delegation_level` default `:low`; the task form has an Agent select plus a model "Auto (by rules)" option.
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

## Constraints

- Umbrella structure: all deps, build artifacts, lockfile at root (`./deps/`, `./_build/`, `mix.lock`)
- Elixir ~> 1.18 required
- Git CLI only — no libgit2 bindings
- No source code at root — all code under `./apps/`
- Agents commit before delegating subagents (auto-commit fallback enforced)
- Genesis stores its runtime artifacts (agent worktrees, state) under a `.genesis/` directory at each repo root; that directory must be git-ignored everywhere (root `.gitignore` and the `.gitignore` Genesis auto-writes into new repos)
- LLM-generated code runs under platform-appropriate sandboxing (systemd-run on Linux, bwrap/bubblewrap on Linux without systemd — e.g. Docker — filesystem isolation only, sandbox-exec on macOS, direct on Windows); backend preference via `[sandbox] backend = "auto" | "systemd" | "bwrap"` (`auto` tries systemd-run first, then bwrap, then no sandbox). The bwrap backend runtime-probes its environment (`EvoGit.Sandbox.Bwrap.capability/0`; override via app env `:bwrap_capability`): in rootless podman containers (container root without CAP_SYS_ADMIN) it runs `:degraded` — `--unshare-pid` dropped (the kernel blocks fresh-procfs-in-nested-pid-ns), filesystem isolation retained; an environment where even the degraded shape fails is `:unusable` and `:auto` falls back to no sandbox. Details: `apps/evo_git/lib/evo_git/sandbox/CONTEXT.md`
- No hardcoded model or username — users configure via `~/.config/genesis/config.toml`
- Dependency security floors — `mix hex.audit` must stay clean; `req_llm >= 1.29.0` (EEF-CVE-2026-107685) is pinned by the explicit `{:req_llm, "~> 1.29"}` dep in `apps/evo_git/mix.exs`, `bandit >= 1.14.0` (the HTTP/2 flow-control, HPACK/header-list, chunked-body and WebSocket-close advisory batch EEF-CVE-2026-108525 … 115269) is pinned by the explicit `{:bandit, "~> 1.14"}` dep in `apps/evo_dash/mix.exs`, while `plug_crypto >= 2.2.1` (EEF-CVE-2026-105963) is only guaranteed by the committed `mix.lock` (purely transitive via phoenix/plug — re-check after any `mix deps.update` of that stack); any `mix.lock` change requires recomputing the `mixFodDeps.hash` in `genesis.nix` (set `lib.fakeHash`, build, copy the reported hash — `precompiled_nifs` hashes move only when a pinned NIF package version changes)
- User config follows XDG conventions

## Architecture Summary

EvoGit has two OTP applications under an umbrella:

- **`:evo_git`** (Core Runtime): AgentScheduler GenServer managing worktree pools, LLM/tool slot management with global backoff, agent implementations (Manager, Executor, Investigator, etc.), Git adapter, and two-phase execution (Genesis → Evolution). Uses a 3-level configuration system: built-in defaults → user TOML config → session-level runtime overrides.
- **`:evo_dash`** (Web Dashboard): Phoenix LiveView interface with project-based task management, agent tree inspector, runtime settings panel, and in-browser config editor. Uses Bandit adapter, Tailwind CSS 4 + DaisyUI, SQLite-based persistence (xqlite via Ecto / `xqlite_ecto3`).

Key design: spatial context tree for routing, phylogenetic graph for temporal evolution, transient agents in isolated worktrees, multi-repo support via absolute path resolution, slot-based concurrency with LLM rate-limit backoff, multi-platform sandboxing, and a dynamic skills system.

## Development Notes

- `mix precommit` — format code and run tests before committing
- **Umbrella-aware formatting** — the root `.formatter.exs` declares `subdirectories: ["apps/*"]` and its own `inputs` cover only root-level files; each app carries its own `.formatter.exs` (`apps/evo_dash` with `import_deps: [:phoenix]` + `plugins: [Phoenix.LiveView.HTMLFormatter]` covering `.heex` and `~H`, `apps/evo_git` a plain default), so `mix format` / the CI gate `mix format --check-formatted` from the root cover the whole umbrella.
- `mix test` — execute the test suite
- `mix deps.get` — fetch dependencies
- `mix compile` — compile and check for errors
- `mix bump.version <new-version>` — bump the version from `VERSION` and sync it to the Tauri/Cargo desktop manifests in one step
- `mix store.maintenance [--data-dir <path>] [--vacuum]` — task-store upkeep: `PRAGMA optimize`, and `--vacuum` to reclaim freed pages (`VACUUM`, switches `auto_vacuum` to incremental); never runs automatically
- `mix migrate.store` — report/apply task-store Ecto migrations manually (normally a no-op; boot applies them)

### Internationalization (i18n) Development Policy

The web dashboard (`:evo_dash`) is internationalized with Gettext — all user-facing strings in LiveViews, components, helpers and templates are wrapped with `gettext/1,2`; the CLI / `:evo_git` core is deliberately NOT internationalized (English-only).
**During development, agents do NOT need to care about PO files or translations.**
- **Never** run `mix gettext.extract`, `mix gettext.merge`, or `mix translate` during feature work: POT/PO and translations are maintained centrally and updated once per release (`mix gettext.extract` → `mix gettext.merge` → `mix translate apps/evo_dash/priv/gettext/default.pot all`, AI-powered via `deepseek-v4-flash`).
- Just write `gettext`-wrapped strings; when a meaning needs anchoring for the release-time AI translator (ambiguous short labels, domain jargon), add a **Chinese comment** next to the `gettext` call — the ONLY i18n work expected during development.
- Full details: `apps/evo_dash/CONTEXT.md` → "Internationalization (i18n)".

### Versioning

The project version has a **single source of truth**: the root `VERSION` file.
The three umbrella `mix.exs` files read it dynamically via a shared `version/0` helper; the desktop manifests (`desktop/src-tauri/tauri.conf.json` and `Cargo.toml`) carry a literal copy that must stay in sync.

`mix bump.version 0.2.0` updates `VERSION`, `tauri.conf.json`, `Cargo.toml`, `Cargo.lock`, and `README.md` (shields.io badge), asks whether to commit the touched files (never `git add -A`), then offers to generate the changelog (delegating to `mix changelog`); the CLI also supports `--version` / `-v`.

**AI changelog generation** — `mix changelog <version> [--from <ref>] [--to <ref>] [--model <id>] [--file <path>]` (`Mix.Tasks.Changelog`, `apps/evo_git/lib/mix/tasks/changelog.ex`): PR/merge-aware first-parent collection, docs-only suppression via the `__NO_USER_FACING_CHANGES__` marker, two-stage map-reduce summarization into a Keep-a-Changelog section, and `CHANGELOG.md` maintenance — a release-time tool, like `mix translate`; full design detail (collection rules, commit filters, prompts, file-update rules, test seams `:changelog_summarizer`/`:changelog_pr_summarizer`/`:changelog_aggregator`): `apps/evo_git/lib/mix/tasks/CONTEXT.md`.

## Subsystem Overviews

The sections below are condensed summaries of major subsystems. Each carries routing pointers to the child CONTEXT.md file that holds the full detail.

### Runtime Data Directory (`tasks.sqlite`)

The SQLite task database (`tasks.sqlite`) lives in the platform data directory, resolved at runtime by `EvoGit.Platform.data_dir/0` (`apps/evo_git/lib/evo_git/platform.ex`) — NOT via Tauri's `path_resolver`/`app_data_dir`: macOS `~/Library/Application Support/genesis/tasks.sqlite`, Linux `$XDG_DATA_HOME/genesis/tasks.sqlite` (default `~/.local/share/genesis/tasks.sqlite`), Windows `%APPDATA%\genesis\tasks.sqlite`.
`EvoGit.Application.start/2` computes it and passes it to `EvoGit.Store` (SQLite WAL mode, sidecars beside it); `EvoGit.TaskRegistry.init/1` mirrors the same resolution.
Overrides, highest → lowest: the app env `config :evo_git, :data_dir` (only `config/test.exs:29` sets it — test isolation must stay above any file config) → the config.toml `[data] dir` key (absolute or `~`-relative; invalid value → `Logger.warning` + fall back; boot-time only, no migration of an existing DB) → the platform default, indirectly influenced via `HOME`/`XDG_DATA_HOME`/`APPDATA`.
The `[data] dir` override relocates the whole data dir coherently (Store sqlite + WAL sidecars, TaskRegistry mkdir, `mix migrate.store`, `logs/backend.log`, nix/sandbox caches, remote-bootstrap cache, self-reflective `genesis-source`), since all consumers resolve through `EvoGit.Platform.data_dir/0`; per-repo `.genesis/` worktree artifacts are repo-root-fixed and unaffected; logs are `<data_dir>/logs/backend.log` (Elixir backend) and `<data_dir>/logs/shell.log` (Tauri shell lifecycle/panic log), also used by the `genesis_remote` daemon.

Persistence runs on Ecto 3.x via the `xqlite_ecto3` adapter (`EvoGit.Repo`, dynamic-repo capable so named test Stores own their DB); `EvoGit.Store.Boot.run_migrations/1` (`Ecto.Migrator`, up-all) migrates `apps/evo_git/priv/repo/migrations/` BEFORE any read/write.
`EvoGit.Store` is a thin GenServer facade over Ecto operation modules (`store/operations/`, `store/schemas/`, `store/types/`, whose custom `Ecto.Type`s preserve the exact on-disk wire format); reads use 6 WAL readers (`EvoGit.Store.Boot.default_pool_size/0`, 8 MiB page cache each), writes serialize through `EvoGit.Store.Writer`, and every read (incl. `get_task`, counts, id/lease projections) runs on a failure-isolated offload worker that logs and replies its documented degraded value on raise/exit/timeout — a slow read can never kill `EvoGit.Store` or `EvoGit.TaskRegistry` (whose sync store calls are `:exit`-guarded).
DB `timeout`/`queue_target`/`queue_interval`/`cache_size`/`temp_store` come from `EvoGit.Repo.start_opts/0` (repo start opts, so Ecto's 15 s default cannot apply), and `mix migrate.store` starts its repo through the same `start_opts/0`; `EvoGit.Store.Maintenance` runs `PRAGMA optimize` once per boot and hourly.
The six migrations are `000001` baseline adoption (the ONE schema-creating step: `tasks` at its final 19 columns with no `archive_metadata`, `projects`, the final six indexes, plus pre-Ecto legacy adoption), `000002` data normalization, `000003` composite indexes, `000004` covering indexes, `000005` `task_agent_archives` create + legacy `archive_metadata` fan-out + column drop (probe-guarded, O(1) on a fresh DB; undecodable payloads are dumped to `<data_dir>/migration_dumps/` before the drop), `000006` redundant-index prune (no-op on a fresh DB) — a fresh database performs a single real DDL step, every later migration is a probe-guarded no-op; versions are a synthetic fixed epoch and a shipped version number is an identity that is never renumbered (detail: `apps/evo_git/priv/repo/migrations/CONTEXT.md`).
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_git/lib/evo_git/store/CONTEXT.md` + `config/CONTEXT.md`.

### Desktop Backend Port & Orphan Prevention (dynamic port)

The `genesis_desktop` backend port is **never fixed**: the Rust shell resolves it once at startup (`desktop/src-tauri/src/main.rs` `resolve_backend_port`) — an explicitly-set `PORT` is honored **only while that port is free** (bind probe), else a random free ephemeral port is picked, so a stale `PORT=9999` from a zombie cannot wedge the app; that port drives the sidecar env, the readiness probe, the watchdog URLs and the WebView URL, and the `9999` fallback in `config/runtime.exs` is only a safety net for manually-launched releases.
Shell-generated client URLs use the literal loopback IPv4 `127.0.0.1` (`BACKEND_HOST`/`backend_url`, never `localhost`) because the endpoint binds IPv4 loopback only while macOS/Windows resolve `localhost` through `::1` first (the "browser works, Tauri window cannot connect" bug); `config/runtime.exs` derives its endpoint host from the same bind address.
Boot and crash recovery share ONE latch-gated navigation driver (`BackendManager::load_dashboard`, `DASHBOARD_NAVIGATE_ATTEMPTS` 6 × 10s) running on a dedicated bootstrap thread (NOT the Tauri `setup` hook, so `on_page_load` callbacks are delivered and tray/Cmd+Q stay responsive); success is a LOAD, never an accepted `navigate` — the `dashboard_loaded` latch is set only by `PageLoadEvent::Finished` for the backend URL, and the gate aborts on a quit/update intent or a dead child.
Budgets: 90s first-boot readiness (`BACKEND_READY_TIMEOUT_SECS`) vs 30s per watchdog restart; gate exhaustion routes by backend health (healthy → neutral "Genesis — Starting up…" page with "Open the dashboard"; unhealthy/dead → the red page the watchdog restarts and reloads on), and there is deliberately no dashboard-liveness heartbeat (a freshness window cannot tell a dead page from a sleeping machine).
**Quit** (tray Quit and macOS Cmd+Q `RunEvent::ExitRequested`) waits for dashboard confirmation (`quit_needs_confirmation/2`, `quit-requested` re-emitted +500..+8000ms) only when the backend is healthy AND the dashboard is loaded; otherwise `kill_for_quit()` + `app.exit(0)` immediately.
**Orphan prevention (TCP lifetime pipe — zero polling)**: the shell binds `TcpListener` on `127.0.0.1:0` and passes `EVOGIT_LIFETIME_PORT`; `EvoDash.DesktopLifetime` (`apps/evo_dash/lib/evo_dash/desktop_lifetime.ex`, wired only when `EVOGIT_DESKTOP=1` AND set) blocks on `:gen_tcp.recv(sock, 0, :infinity)` and stops the BEAM only on a GENUINE peer close (`{:error, :closed}` → `System.stop(0)`), retrying transient errors boundedly (test seams `:parent_stop_fun`, `:recv_fun`/`:recv_retries`); the Rust hold thread likewise ends only on a real peer EOF, because a spurious close would self-stop with exit 0 and `classify_exit` reads a clean `Some(0)` as intentional shutdown.
Diagnostics: port/navigation/latch events go to `<data_dir>/logs/shell.log`, and `EvoDash.ConnectionDiagnostics` tags connection lines with `remote_ip`/`remote_port`.
Details: `desktop/CONTEXT.md` + `desktop/src-tauri/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

### Task Cancellation Model (graceful cancel vs force kill)

Task cancellation has **two distinct actions** (both node-aware via the RemoteNode RPC chain): **graceful cancel** — `EvoGit.TaskRegistry.cancel_task/1` (also RemoteAPI/RemoteNode/NodeContext) sets the task to **`:cancelling`**, sends each running agent a save-work user message + sets `AgentState.cancel_requested`; the wrapper is NOT killed — the phase finishes normally (3-turn grace budget in `Runner.loop/1`) and the final-status mapping force-persists **`:cancelled`** with result/usage preserved (the per-agent archive lives in its own table and survives) (reviewable like a completed task). `:pending` tasks cancel immediately; `:cancelling` is idempotent; new root spawns are blocked while cancelling; escalation via `force_kill_task/1` works from `:cancelling`.
**Force kill** — `TaskRegistry.force_kill_task/1` kills all agents + the wrapper and persists **`:failed`** with result nil'd (works from `:running` and `:cancelling`); `:cancelled` therefore means ONLY gracefully-cancelled tasks.
Dashboard UI (`apps/evo_dash` Tasks page): visible **Cancel** button (`[:pending, :running]`) with a warning modal; **force kill** in the task card's three-dot dropdown (`[:running, :cancelling]`, "Danger zone"); `:cancelling` renders as violet badge/label/accent and appears in sidebar active-tasks lists and the status filter.
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

### Self-Reflective Agent (repo-less, chatbot-style)

A special agent with **no repository of its own** — the user talks to it about the Genesis system itself; it investigates the Genesis source read-only, controls tasks, and guides the user through the dashboard.
It runs through the EXISTING agent machinery (Runner loop, ToolDispatch, `AgentScheduler.run_agent`, LLM retries/slots/compression) marked repo-less via `spec.opts[:repo_less] = true` — no worktree, no git ops, no subagent spawning; `Tools.execute/5` blocks write tools (defense-in-depth: its repo_path points at the REAL Genesis source).
Core: `EvoGit.Agents.SelfReflective` (`agent_type :read`, `delegation_level :low`, read-only + gated `WebSearch` + control/guide tools + `CompleteTask`; NO shell/write tools) + `EvoGit.Runtime.SelfReflective` (`run/1,2`; `source_root/0` env chain `:self_reflective_source_root` → `GENESIS_SOURCE_ROOT` → `File.cwd!()`); task type `:reflect` (mode `"reflect"`, NO `:path` — `TaskExecutor.execute_task(:reflect)` bypasses `RuntimeOpts.build_common_runtime_opts`, which KeyErrors without `:path`), CLI `reflect`.
Task-control tools (`apps/evo_git/lib/evo_git/agent/tools/`): `list_tasks`, `get_task`, `start_task` (types from a fixed map — never `String.to_atom` on LLM input), `cancel_task`, `force_kill_task`, `delete_task`, `spawn_investigator` (deterministic read-only repo probe, no LLM spawn), `guide_user` (best-effort PubSub broadcast).
Dashboard: the **Home chat page** (`EvoDashWeb.HomeLive` at `GET /help`) starts `:reflect` tasks via `EvoDash.NodeContext.start_task(node, :reflect, mode: "reflect", objective: ...)` with NO `:path`; replies render as **mini task-card chat messages** reusing agents/tasks-page code (live `EvoDashWeb.Helpers.task_status_badge`, streamed text, collapsible zero-JS "Thought process" via `EvoDashWeb.AgentsLive.ToolCallDisplay`), chat state persists across sessions via `EvoDash.ChatHistory` (ETS-backed, shape-agnostic) + `EvoDashWeb.HomeLive.ChatState` (shape owner), and the guide overlay uses the `EvoDashWeb.LiveHooks.Guide` hook + JS `Guide` hook.
Details + test coverage: `apps/evo_git/CONTEXT.md` ("Self-Reflective Agent (repo-less)") + `apps/evo_dash/CONTEXT.md`.

### Merge Conflict Check & Auto-Resolution (Review Page)

The review page checks merge cleanliness **asynchronously** and offers agent-driven auto-resolution.
**Async merge check**: on review page load (and when the merge-target selector changes), `ReviewLive` spawns a supervised Task (`EvoDash.TaskSupervisor`) calling `EvoDash.NodeContext.check_merge/4` → `EvoGit.Review.check_merge/3` — a **non-mutating dry-run**: resolves both refs (identical SHAs → `:clean`), then runs `git merge-tree --write-tree --name-only --no-messages <branch_sha> <target_sha>` (git ≥ 2.38); no worktree, nothing under `<repo>/.genesis/`, refs untouched. Exit 0 → `:clean`; exit 1 → `{:conflict, files}`; exit 128 → error.
**UI** (`ReviewComponents.Actions.action_buttons/1` + `ReviewLive.MergeCheck`): a merge-status block above the Merge button — checking → clean (green) → conflict (amber, conflicted-file list + **Auto-resolve conflict** button with phx-confirm) → error (renders nothing).
**Default merge target** (selector preselection, also the per-repo merge / merge-all fallback): `EvoGit.Review.default_merge_target/1` — the branch HEAD is on (detached HEAD skipped), else the first existing of `main`/`master`/`dev`/`prod`, else the first local branch (`{:ok, name}` | `{:error, :no_branch_found}`); mirrored by all three RPC layers (RemoteAPI/RemoteNode/NodeContext).
**Auto-resolve** (counts as resumed): marks the original task `review_status: :continued`, then starts a new `:evolve` task with opts `[path:, mode: "simple", objective:, starting_commit:, merge_from: <task_id>, merge_target: <branch>]`; `EvoGit.TaskRegistry.MergeContext.apply_merge_context/4` strips the merge keys, loads the previous task, overrides `starting_commit` with prev `commit_sha`, carries over `foreign_repos`, and prepends a resolution-hints context block (commit before delegating; inspect `git log/diff base..end` and `base..target`; incremental milestone merges for hard conflicts). The merge agent runs `git merge <target>`, resolves, commits; `merge_and_report` produces a reviewable `genesis/agent_*` branch whose merge is clean (`genesis/agent_*`).
**Test seam**: `Application.get_env(:evo_dash, :merge_check_runner)`; the spawned task rescues exceptions → `{:error, :check_failed}` so the status never wedges at `:checking`.
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

### Native Directory Picker (wx backend)

The dashboard's directory picker (Browse buttons on the project/new-project/foreign-repo pickers) is implemented **on the Elixir backend with Erlang's `:wx`** (`wxDirDialog`), NOT via Tauri: the JS `DirectoryPicker` hook pushes `"directory_pick"` → `ProjectsLive` (current node local only) → `EvoDash.DirectoryPicker` (a GenServer in `apps/evo_dash` serializing wx dialog usage) runs the modal → result pushed back as `"picker_result:<picker_id>"`; wx picks are absolute paths and auto-submit the forms.
Tauri's `pick_directory` command is not used (unstable: Windows invoke fails after picking, macOS NSOpenPanel never presents); when wx is unavailable (headless server, remote node, OTP built without wx) the hook shows the manual-entry fallback.
Because `wx` is not a dependency of any umbrella app it is listed explicitly in the `applications:` list of the `genesis` and `genesis_desktop` releases in `./mix.exs` (`wx: :load`) — `genesis_remote` intentionally stays wx-free; the wx NIFs link against wxWidgets 3.2 sonames, so AppImage bundling installs the wx 3.2 runtime via plain apt on ubuntu-24.04 (`libwxbase3.2-1t64` etc., x64-gated — no PPA).
Details: `desktop/src-tauri/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

### ReqLLM Finch Connection Pool (LLM HTTP concurrency)

The ReqLLM Finch pool is **sized at boot** (`config/runtime.exs:23-72`): pool `count = EvoGit.ReqLLMPool.desired_count(total_concurrency)` — the `max(total + 2, 8)` formula lives ONLY in `desired_count/1` (`apps/evo_git/lib/evo_git/req_llm_pool.ex`, single source of truth; do NOT inline it); `total_concurrency = max(Σ per-profile concurrency, scheduler.default_llm_max_concurrency)` from `EvoGit.Config.resolve()` (per-profile default 3, scheduler default alone when no profiles exist).
Configured via the full `finch:` override form (`name: ReqLLM.Finch`, `pools: %{default: [protocols: [:http1], size: 2, count: stream_pool_count, start_pool_metrics?: true]}`) with `stream_pool_timeout: 300_000` and `stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}` top-level (both read at CALL time).
**Pools are PER ORIGIN** — Finch materializes one pool per origin from the `:default` template, lazily, so capacity = `count × 2` concurrent HTTP/1 streams per origin (`size: 2`), NOT global; sum-based sizing is the provably safe upper bound (any single origin's demand ≤ total concurrency).
**Runtime reconciliation is grow-only** (`EvoGit.ReqLLMPool`): resized on config changes (`AgentScheduler.update_config`, `RemoteAPI.reload_config`, per-task `-m`) and on Finch "excess queuing" errors (`bump_for_excess_queuing` → `max(ceil(effective * 1.5), 8)`); it NEVER shrinks (`Finch.set_pool_count` kills in-flight streams on shrink).
`start_pool_metrics?: true` is REQUIRED for `Finch.get_pool_status(ReqLLM.Finch, :default)` to enumerate origins (else reconciliation is a silent no-op); pools are lazy, so `set_pool_count` returns `{:error, :not_found}` until an origin is used — reconcile/bump no-op gracefully.
A runtime `default_llm_max_concurrency` override ALSO raises the scheduler's live per-model LLM slot pools (floor semantics, never lowering explicit profile concurrencies).
Details: `apps/evo_git/CONTEXT.md` + `apps/evo_git/lib/evo_git/agent_scheduler/CONTEXT.md`.

### Peak/Off-Peak Hour Concurrency Scheduling (LLM models)

Each `[[llm.models]]` profile may declare five **optional** peak/off-peak fields: `peak_concurrency` (**`0` = hard pause** — zero LLM slots, never raised by the `default_llm_max_concurrency` floor), `peak_hours` (half-open daily `%{start: "HH:MM", end: "HH:MM"}` windows, `start > end` = overnight wrap, each optionally scoped by `days` — `"mon".."sun"` and/or `"weekdays"`/`"weekends"`), `off_peak_days` (the profile is off-peak the ENTIRE day: normal `concurrency` 24/7, every window and `peak_concurrency` suppressed, wins over window `days`), and `timezone` (IANA name, DST-aware; absent/blank → server local wall clock, never UTC).
`EvoGit.PeakHours` (`apps/evo_git/lib/evo_git/peak_hours.ex`) is the **pure** single source of truth for parsing/validation and runtime math (`validate_days/1`, `in_peak?/2,3`, `next_transition/2,3` — midnight day-boundary flips ARE transitions, `effective_concurrency/2,3`, `wall_clock_in/2`); the config schema delegates to it — do NOT re-implement window logic (needs `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)` at boot).
`EvoGit.PeakHourEngine` (supervised after the scheduler) flips scheduler concurrency on start/timer/`"scheduler_config"` PubSub with the **floored** map (`max(effective, default)` per model, explicit `0` stays `0`), applied only when it differs; 0-capacity ENQUEUES slot requests instead of failing fast (granted on resume by `Slots.grant_pending_on_resume/1`; in-flight holders never evicted; force-kill purges queued agents), with clock seams `:peak_hours_now_fun`/`:peak_hours_utc_now_fun`.
Dashboard: Settings → model profile editor edits the fields (absent/empty peak fields serialize to TOML as absent; `off_peak_days` + window `days` render as chip selectors).
Details: `apps/evo_git/CONTEXT.md` (full contract, wake triggers, +100ms transition epsilon, 6h safety-net cap) + `apps/evo_dash` settings CONTEXT.md.

### SSH Remote Development

A VSCode Remote-SSH-like workflow: a lightweight headless daemon on a remote server is controlled by the local Phoenix dashboard over an SSH tunnel via Erlang distribution — the **remote daemon** (`genesis_remote` release — `evo_git`-only, `include_erts`, launched via `systemd-run --user` on Linux / `launchctl` + launchd plist on macOS, survives dashboard disconnection) uses EPMD-less distribution on a pinned port (default 9000) via `EvoGit.EpmdDist` (`-epmd_module Elixir.EvoGit.EpmdDist` in `rel/vm.args.eex`), while the **local dashboard** opens an SSH port-forwarding tunnel (`ssh -L <local_port>:127.0.0.1:<remote_port> -N`), auto-enables local distribution on demand (`EvoGit.Distribution.enable_for_remote/1`) and `Node.connect/1`s over it (`EvoGit.RemoteConnection` owns the lifecycle).
**Data access**: `:erpc.call/5` to `EvoGit.AgentScheduler.RemoteAPI` (native BEAM terms, no serialization); PubSub uses the cluster-aware PG2 adapter (`:pg`).
**Dashboard RPC UX**: ALL node-aware data loads run OUTSIDE the LiveView process via `EvoDash.TaskSupervisor` + self-message + stale-guards — **no LiveView ever blocks on a cross-node `:erpc` call, and there is NO periodic polling anywhere** (push-based PubSub; per-page consumers: `apps/evo_dash/lib/evo_dash_web/live/CONTEXT.md`).
**Bootstrap vs Connect** are separate: bootstrap SCPs the release tarball, extracts it and launches the daemon (first-time setup); connect only establishes the tunnel + distribution link; all SSH ops use CLI `ssh`/`scp` via `Port.open` (no Erlang `:ssh`), with remote commands as **argv arrays** via `run_ssh_command/3` (never quote-wrapped spawn strings), bash-wrapped (`/usr/bin/env bash -c`, `EvoGit.RemoteBootstrap.bash_wrap/1`).
**Multiple simultaneous connections**: each target gets a unique node name (`genesis_remote_<id>@127.0.0.1`) + per-target systemd unit/launchd plist label; the tunnel's dynamic local port is **polled for readiness** (`wait_for_tunnel/4`, 10s budget) BEFORE `Node.connect/1`.
**Remote asset download** is deterministic and network-free: `EvoGit.RemoteBootstrap.download_url/1` returns `https://genesis.evox.group/dl/genesis_remote_<platform>.tar.xz`; **glibc is the default and ONLY published Linux variant — asset names are NEVER suffixed** (musl disabled; do NOT reintroduce asset listing/matching or suffix checks — the desktop `.tar.gz` and remote `.tar.xz` share the `_<os>_<arch>` shape).
Key modules: `EvoGit.EpmdDist` (`erl_epmd` impl; `:persistent_term` node→port registry), `EvoGit.Distribution`, `EvoGit.RemoteConnections` (TOML `~/.config/genesis/remote_connections.toml`), `EvoGit.RemoteConnection`, `EvoGit.AgentScheduler.RemoteAPI`, `EvoDash.NodeContext`, `EvoDashWeb.LiveHooks.NodeAware`, `EvoDashWeb.NodeSelectorComponent`.
Details: `apps/evo_git/CONTEXT.md`.

### Desktop App Build Pipeline

`.github/workflows/build-desktop.yml` builds native desktop installers on every release (version tag push `v*` or manual `workflow_dispatch`) and creates the release itself: all platform builds finish first, then `publish-release` creates a **draft** release with every artifact attached and flips it public with `gh release edit --draft=false` as its FINAL step — so `releases/latest` never points at a release whose assets are still uploading.
Each platform job runs `mix release genesis_desktop` (native, `include_erts` bundles host ERTS) → copies the release dir to `desktop/src-tauri/resources/genesis-backend/` → `tauri build`; the headless `genesis_remote` release is also built and uploaded as a `.tar.xz`.
**Five job groups** on native runners: `build-linux` (desktop, ubuntu-24.04 x64/arm64 → `.deb`/`.rpm`/AppImage/`.tar.gz`; AppImage excluded on ARM64 — linuxdeploy is x86_64-only; Flatpak not built), `build-linux-remote` (dedicated glibc `genesis_remote` on ubuntu-22.04 x64/arm64 — glibc 2.35 = wider host compatibility; **musl build disabled**), `build-macos-arm64` (`macos-15` → `.dmg`/`.app`), `build-windows-x64` (`windows-2022` → `.msi`/`.exe` NSIS), `publish-release`.
Toolchains pinned via `OTP_VERSION`/`ELIXIR_VERSION` (OTP 29, Elixir 1.20.4); the Tauri CLI comes from npm `@tauri-apps/cli` (never `cargo install`); ARM partner runners get an `ImageOS` fix before `erlef/setup-beam`; ripgrep/git (MinGit on Windows) are vendored into `apps/evo_git/priv/vendor/{platform}/`; caches: Mix deps, Mix build, Rust target, Tauri CLI.
Details (incl. musl revival notes): `.github/workflows/CONTEXT.md`.

### Auto-Update / Push-Update (tauri-plugin-updater v2 — implemented)

The desktop auto-update system is **implemented** (full design record: `docs/auto-update.md`): official `tauri-plugin-updater` v2 in the Rust shell (NOT custom, NOT Sparkle), **two-phase** — check/download/verify anytime, **apply is manual-click only and gated on task idle**.
Feed = static `latest.json` via the **genesis.evox.group `/dl/` Cloudflare proxy** (mainland-China reachable; payload `url`s and the inline `.sig` ride the proxied manifest), with GitHub Releases as the upstream upload target; `/dl/<asset>`, `/dl/latest/<asset>` and tag-scoped `/dl/<tag>/<asset>` resolve against releases while `/dl` redirects to the docs site's `/#download`, and shipped artifacts deliberately use the unversioned form only (the tag-scoped route goes live in the external `genesis-doc` worker only after a manual `pnpm deploy`, so switching early would 404 installed apps).
**Rust shell**: plugin 2.14.0, `bundle.createUpdaterArtifacts: true`, `plugins.updater` endpoints (proxy `latest.json` primary + GitHub fallback, real minisign public key baked), commands `check_update` (→ `up_to_date|available|not_configured|not_available|error`), `download_update` and `begin_update` (sets the watchdog update-intent flag; on backend exit 0 the watchdog installs the staged payload and relaunches).
**Dashboard**: `EvoDash.UpdateStatus` hub (broadcasts `{:update_status, state}` on topic `"updates"`), a global on-mount hook + JS bridge (checks ~30s after startup then ~6h, **auto-downloads after a successful check**, sidebar dot on System), and `SystemLive`'s "Software Update" card (checking/up_to_date/available/ready/error/applying).
**Apply**: "Restart & Update" → idle gate `TaskRegistry.list_task_ids([:running, :pending, :cancelling, :finalizing]) == []` (node-aware); busy → Defer / "Apply & gracefully stop tasks" (results preserved as `:cancelled`) / user-warned `force_kill_task/1`; then `begin_update` → `System.stop/0` inside the BEAM. Gated to desktop mode + local node; Linux non-AppImage installs (deb/rpm/portable) are **notify-only**.
**Activation state — keypair done, signed payloads + CI secrets remain**: builds never return `"not_configured"`; the blocker is per-platform signed payloads reaching the release (the two repo secrets — without them no platform entries appear, so Linux desktop reports "No auto update on this platform"), and `publish-release` writes `dist/latest.json` for darwin-aarch64 / linux-x86_64 / windows-x86_64 only (linux-arm64 excluded — AppImage-only updater support on Linux). Deferred: Windows Authenticode cert, Linux apt/dnf repos + GPG, remote-daemon update flow, staged rollout/beta channels.
Details: `desktop/src-tauri/CONTEXT.md` + `.github/workflows/CONTEXT.md` + `apps/evo_dash/CONTEXT.md`.

### NixOS Local Build

A `flake.nix` at the repository root supports NixOS local builds: `nix develop` (dev shell with Erlang/OTP 29, Elixir 1.20, Rust, webkitgtk-4.1) and `nix build .#desktop` (store app: the Tauri binary resolves the backend release via `sidecar_path::resolve_launcher` from `<exe_dir>/resources/genesis-backend`, the wrapper puts the GTK/WebKit/tray runtime stack on `LD_LIBRARY_PATH`, and `genesis.nix` bakes a deterministic `releases/COOKIE`).
**Design decisions**: no `cargoHash` (Rust deps vendored from `desktop/src-tauri/Cargo.lock` via `cargoLock.lockFile`); both derivations read the version from the repo-root `VERSION`; the manual hashes live in `genesis.nix` (`mixFodDeps.hash` keyed to the Hex dep set, `precompiled_nifs` asset hashes keyed to each NIF package version); the flake extends the `packagesWith erlang_29` BEAM set to Elixir 1.20 so the release builds and the dev shell share ONE toolchain (the set's default Elixir 1.18 cannot compile the app).
**Build gotchas** (tauri-build `bundle.resources` validation + the `preBuild` symlink, the `checkPhase`/`postBuild` chmod workaround that must not be replaced by `doCheck = false`, and the tray icon's writable `XDG_RUNTIME_DIR`): `nix/CONTEXT.md` → "Known Issues".
Details: `nix/CONTEXT.md` + `desktop/CONTEXT.md`.

### Research Notes: PDF/DOCX → Plain Text Extraction (for LLM objective prompts)

**Status: plain-text, `.docx`, AND `.pdf` are IMPLEMENTED** — as a FRONTEND feature in `EvoDash.AttachedFile` (`apps/evo_dash/lib/evo_dash/attached_file.ex`, `ex_pdf` as a plain Hex dep of `:evo_dash`; password-protected → `{:invalid, ...}`, scanned/image-only → `{:empty, ...}`, no OCR).
**The core `:evo_git` stays clean by design**: `EvoGit.PromptFile` reads plain text only and rejects non-UTF-8/PDF/DOCX with `{:error, {:not_text, ext}}`, so `genesis_remote` ships no `ex_pdf`; the objective stays a plain `String.t()` end-to-end and conversion happens only in the dashboard's objective-editor attach flow.
ReqLLM-native `:file` attachments are deliberately NOT used (uneven provider matrix); the optional `pdftotext` upgrade path via `EvoGit.Executable.resolve` remains future.
Details: `apps/evo_dash/CONTEXT.md`.
