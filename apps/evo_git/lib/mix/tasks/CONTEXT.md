# Mix Tasks (`lib/mix/tasks/`)

## Intent

Release-time Mix tasks for the `:evo_git` app: `mix changelog` (AI-generated Keep-a-Changelog section from git history) and `mix bump.version` (bump the single-source-of-truth `VERSION` and sync it to the desktop manifests + README badge). Both are interactive (shell `yes?` prompts) and run git/file operations. Both expose a call-time-resolved testability seam so their suites can run under `async: true`.

## API Surface

| File | Module | Summary |
|---|---|---|
| `changelog.ex` | `Mix.Tasks.Changelog` | `mix changelog <version> [--from <ref>] [--to <ref>] [--model <id>] [--file <path>]`. PR/merge-aware first-parent collection, two-stage (map-reduce) LLM summarization via `ReqLLM.stream_object`, keeps `CHANGELOG.md`. `@requirements ["app.config"]` kept. |
| `bump.version.ex` | `Mix.Tasks.Bump.Version` | `mix bump.version <version>`. Rewrites `VERSION`, `desktop/src-tauri/{tauri.conf.json,Cargo.toml,Cargo.lock}`, `README.md`; interactively commits the touched files and optionally delegates to `Mix.Tasks.Changelog.run/1`. |

### Injectable seams (call-time resolved, defaults byte-for-byte unchanged)

- `opts[:root]` — anchors every git call (`System.cmd("git", args, cd: root, …)`) and resolves every relative path under it (`Path.join(root, rel)`); default `File.cwd!()` (default reproduces today's bare relative calls exactly). Removes the need for a VM-wide `File.cd!` in tests.
- `opts[:shell]` — the `Mix.Shell` used for all `info`/`error`/`yes?`; precedence `opts[:shell]` → app env `:mix_shell` → `Mix.shell()`. Removes the need for a global `Mix.shell(Mix.Shell.Process)` swap.
- Changelog summarizer seams (changelog.ex only) — precedence `opts[key]` → app env `:evo_git, key` → real impl: `:changelog_summarizer` (whole pipeline, default `Mix.Tasks.Changelog.summarize_pipeline/3`), `:changelog_pr_summarizer` (stage 1), `:changelog_aggregator` (stage 2). `bump.version.ex` forwards `root`, `shell`, and any of the three seam keys present in its own opts into the nested `Mix.Tasks.Changelog.run/1`.

### Test call shapes (for the test-side `async: true` flip)

- `Mix.Tasks.Changelog.run(["1.2.3", root: tmp, shell: shell, changelog_summarizer: fun])`
- `Mix.Tasks.Bump.Version.run(["1.2.3", root: tmp, shell: shell])`
- Keyword-tuple entries are split out of `args` BEFORE `OptionParser.parse` (CLI argv is plain strings, so this is a no-op on the CLI path); `run/1`'s public CLI contract is unchanged and no CLI flags were added.

## Constraints

- Production behavior MUST stay byte-for-byte identical when the new opts / app env values are ABSENT — every seam is read at CALL time. Do not change any user-facing output string, prompt, or message.
- Per-call `opts` overrides are the async-safe path; the `Application.get_env(:evo_git, …)` values remain the backward-compatible fallback.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` must stay clean.
- Do NOT run `mix changelog` / `mix bump.version` against the real repo casually — they mutate files and commit.

## Routing Table

- `migrate.store.ex` (`Mix.Tasks.Migrate.Store`) → same directory, OUT of this seam's scope (not covered above).
- `mix changelog`/`Mix.Tasks.Changelog` design + CI workflow usage → root `./CONTEXT.md` ("AI changelog generation") and `.github/workflows/CONTEXT.md`.
- Versioning (`VERSION` single source of truth, `mix bump.version` sync targets) → root `./CONTEXT.md` ("Versioning").
- Existing suites that exercise these tasks → `apps/evo_git/test/mix/tasks/` (owned by the test-side workstream; not documented here).
