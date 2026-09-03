# Auto-Update / Push-Update Design Analysis

**Status:** Design analysis (not yet implemented). Written from the state of the codebase at v0.10.5.
**Scope:** The Genesis desktop app (Tauri shell `desktop/` + Elixir backend release `genesis_desktop`). The `genesis_remote` daemon is covered briefly in §6.

---

## 1. TL;DR — Recommended approach

1. **Per-platform, convention-respecting strategy:**
   - **macOS** → in-app updater. The pipeline already signs (Developer ID) and notarizes; add `tauri-plugin-updater` (official; uses the `.app.tar.gz` updater artifact + minisign Ed25519 signatures) — or Sparkle if native macOS update UX is wanted. Both require the already-in-place signing/notarization.
   - **Windows** → in-app updater via `tauri-plugin-updater` with the **NSIS** installer (`installMode: "passive"`). Authenticode signing is a prerequisite (currently absent). The MSI target has known updater bugs — keep MSI for enterprise/IT deployment, don't auto-update it.
   - **Linux** → **package-manager-first, no self-install for deb/rpm**: publish an apt repository (and optionally dnf) so users update the way their distro expects; the app only *notifies* when a new version is available. In-app self-update is used **only for the AppImage channel** (the sole Linux target `tauri-plugin-updater` supports; x64 only — arm64 ships deb/rpm only). The portable `.tar.gz` gets a "download new version" link, never silent replacement.
2. **Two-phase update with a task-safety gate:**
   - **Phase 1 (safe anytime):** periodic + startup + manual update *check*; download and signature-verify the new bundle in the background.
   - **Phase 2 (only when safe):** apply = stop backend → install → relaunch. Applying is **gated on task idle**: no `:running`/`:pending`/`:cancelling`/`:finalizing` tasks (queried from `TaskRegistry`). If tasks are active, the UI defers and offers **"Apply & gracefully cancel tasks"** — reusing the existing graceful-cancel machinery (3-turn grace budget, worktree git-commit at grace entry, results/archive preserved, final status `:cancelled`). A new `:interrupted` status is recommended so update-induced stops are distinguishable from user cancels.
3. **Prerequisites before any of this works:** a minisign (Ed25519) keypair for the update feed, Windows Authenticode certificate, macOS `.app` stapling (currently only the DMG is stapled), and a manifest-generation step in `publish-release`.

---

### 1.1 Decision — which updater (answered)

**Use the official `tauri-plugin-updater` v2. Do NOT write a custom updater; do NOT adopt Sparkle for v1.**

- **Why not custom:** a custom updater would re-implement, per platform: manifest fetch + version compare, minisign Ed25519 signature verification, download with progress, atomic bundle replacement (NSIS passive install, AppImage self-replace, `.app` bundle swap), and relaunch — a large, security-sensitive surface where a broken install path bricks users. The official plugin already does all of it and **verifies the minisign signature before writing a single byte** (§5.1), so even a hostile/untrusted CDN is safe (only the build process that signs needs to be trusted).
- **Why not Sparkle:** Sparkle is macOS-only, arrives via a third-party plugin (`tauri-plugin-sparkle-updater` — bundles the Sparkle framework, needs a separate appcast feed + EdDSA keys), and its value is the *native* macOS update panel — which this app deliberately does not use (the dashboard is a WebView UI; the update UX is a System-page component, §11). One code path across macOS/Windows/Linux wins for v1. Revisit only if a native macOS update panel becomes a hard requirement.
- **Architecture shape (fits the codebase):** the plugin is registered in Rust (`main.rs`, AFTER single-instance — registration order is load-bearing); `tauri.conf.json` gains `plugins.updater { endpoints: [...], pubkey: <minisign pubkey>, windows: { installMode: "passive" } }` and `bundle.createUpdaterArtifacts: true`. All calls go through **two new `#[tauri::command]`s — `check_update` and `install_update`** — wrapping the Rust `UpdaterExt` API (`app.updater()`), invoked from the dashboard JS via the existing `window.__TAURI__.core.invoke` pattern (`withGlobalTauri: true` already set; the asset pipeline has no npm/package.json, so the npm `@tauri-apps/plugin-updater` package is NOT used). Custom app commands are not permission-gated, so no `updater:*` capability is needed (add `updater:default` only if the JS plugin API were used directly).
- **Artifact correction (CI must change):** with `createUpdaterArtifacts: true`, `tauri build` emits the updater payloads itself — macOS `.app.tar.gz` + `.sig`, Linux x64 `.AppImage.tar.gz` + `.sig`, Windows NSIS `.exe` + `.exe.sig` (signed automatically when `TAURI_SIGNING_PRIVATE_KEY` is set). **CI currently stages a `ditto`-made `.app.zip` (build-desktop.yml L593-595) — the updater expects a `.tar.gz` of the signed + notarized + stapled app; the macOS job must switch to producing the `.app.tar.gz`.** The `.app.zip` remains a distribution artifact but is not the updater payload.
- **Relaunch:** on Windows the plugin's install restarts the app itself; on macOS/Linux relaunch is orchestrated by the new watchdog **update-intent state** (exit code 0 + update flag → run installer → relaunch the new bundle), so `tauri-plugin-process` is NOT needed.

---

## 2. Current state (verified facts)

### 2.1 Tauri shell (`desktop/`) — zero updater machinery
- `desktop/src-tauri/Cargo.toml`: `tauri = 2.11.3`, plugins: shell, single-instance only. **No `tauri-plugin-updater`** (not even transitively in Cargo.lock). `reqwest` (blocking) is already a dep — the updater's HTTP stack is in the tree.
- `tauri.conf.json`: `productName "EvoX Genesis"`, `mainBinaryName "genesis-desktop"`, **stable `identifier "com.genesis.desktop"`**, `version "0.10.5"` (synced from root `VERSION` by `mix bump.version`), `targets: "all"` → deb/rpm/appimage/tar.gz (Linux), dmg/app (macOS), msi/nsis (Windows). No `plugins.updater` section.
- `capabilities/default.json`: only `core:default`, `shell:allow-execute`, `shell:allow-spawn`. No `updater:*` permissions.
- **Lifecycle facts that matter for update timing:**
  - The backend is spawned as a **foreground** child: `bin/genesis_desktop start` (`sidecar.rs`), PID = launcher/BEAM, clean kill semantics. The launcher path is version-independent (`releases/start_erl.data` selects the active version).
  - Rust **never** sends SIGTERM and never runs `bin/genesis_desktop stop` (which is broken anyway under `RELEASE_DISTRIBUTION=none` — see §2.3). Termination is `child.kill()` (**SIGKILL** on Unix). Graceful stop is initiated by the backend itself: tray Quit → `quit-requested` event → JS confirm → `invoke("begin_quit")` (sets an intentional-shutdown flag) → backend `System.stop()` → watchdog sees exit code 0 → `app.exit(0)`.
  - **Watchdog** (`backend_watchdog.rs`): respawns the backend on unexpected exit with backoff `[1,2,4,8,16,30]s`; exit code 0 = intentional → **whole app exits, no respawn**. This is the single most important Rust-side constraint for update apply: an "install and relaunch" flow needs a new watchdog state that treats the stop as *update-intentional* (install, then relaunch) rather than app-exit.
  - Close-to-tray: window close hides, backend keeps running. No `RunEvent::Exit` hooks.
- The backend release lives at `resources/genesis-backend` **inside the app bundle** (immutable at runtime) — a backend-only in-place update is impossible; updates replace the whole app bundle. This is by design: the backend and dashboard always ship as one unit, so there is no cross-version compatibility problem within the desktop app.

### 2.2 CI pipeline (`.github/workflows/build-desktop.yml`)
- Artifacts per job: linux x64 → `genesis_desktop_linux_x64.{deb,rpm,AppImage,tar.gz}`, linux arm64 → `{deb,rpm}` (no AppImage — appimagetool is x86_64-only); macos arm64 → `.dmg` + `.app.zip`; windows x64 → `.msi` + `.exe` (NSIS). Plus `genesis_remote_*_*.tar.xz`.
- **Signing:**
  - macOS: full Developer ID signing + notarization (`notarytool submit --wait` + stapling) — but **only the DMG is stapled**; the `.app.zip` (the natural updater artifact) relies on Apple's online ticket validation.
  - Windows: **no Authenticode signing at all**.
  - Linux: no GPG/minisign anywhere.
- **No checksums, no manifests, no update JSON, no 'latest' pointer** generated by `publish-release` (`softprops/action-gh-release@v3.0.2`, idempotent overwrite, `fail_on_unmatched_files`). Artifact names are deliberately **unversioned** so `releases/latest/download/<name>` is permanent — a versioned feed would use `releases/download/<tag>/<name>` (also permanent).
- The Cloudflare worker behind `https://genesis.evox.group/dl/` (mainland-China proxying; source **not in this repo**) is the app-facing host for updates: the updater feed endpoint and the per-platform manifest payload URLs in `tauri.conf.json` / the `publish-release` manifest now point at `/dl/` (this upgrade path has been executed — see §5.2). Worker-side serving of `latest.json` and the desktop updater payload names remains an external prerequisite; today it serves only the `genesis_remote_*` tarballs.
- Version plumbing: root `VERSION` → `mix bump.version` syncs tauri.conf.json/Cargo.toml/Cargo.lock/README. Workflows never read VERSION (baked at build time).

### 2.3 Core runtime (`apps/evo_git`) — task lifecycle facts
- **Persistence:** `tasks.sqlite` (WAL) survives process kill; git branches (`evogit-agent-*` worktrees, `genesis/agent_*` results) survive; worktree dirs linger until next `WorktreeManager` cleanup. **Lost on hard kill:** in-flight turn context, `commit_sha` (persisted only at terminal result), wrapper processes, leases (they simply expire — startup reconciliation then maps orphaned `:running`/`:pending` → `:failed`, `:cancelling` → `:cancelled`).
- **No auto-resume exists.** Resume is always a new `:evolve` task via the Review page (`review_status: :continued`), anchoring on the previous task's persisted `commit_sha`. A hard-killed task has no `commit_sha` → resume cannot anchor at real progress → **human review is structurally required**. Consequence: an update must never hard-kill tasks without expecting a `:failed` + manual-review outcome.
- **Graceful cancel** (`TaskRegistry.cancel_task/1` → `AgentScheduler.begin_graceful_cancel/1`): status `:cancelling`, each live agent gets a cancel message, 3-turn grace budget with **git-commit of all worktree changes at grace entry**, new spawns blocked; final mapping persists **`:cancelled` WITH result/archive/usage preserved**. It is **not wall-clock bounded** (LLM retry backoff can reach ~9 min, per-tool cap 30 min, subagent turns unbounded) → an update flow must wait with a generous timeout and fall back to `force_kill_task/1` (`:failed`, result nil'd) as a user-warned last resort.
- **Status set:** `:pending | :running | :finalizing | :completed | :failed | :cancelled | :cancelling`. Adding `:interrupted` is feasible (schema has no CHECK constraints; writes are unvalidated) but must be added to codec `@known_atoms` + the ~10 hardcoded status lists (store.ex select filters, TaskRegistry terminal-mapping sites, `clear_finished_tasks` exclusions, etc.).
- **Idle check API:** `TaskRegistry.list_task_ids([]) == []` (strongest — no rows at all) or `list_task_ids([:running, :pending, :cancelling, :finalizing]) == []`. Remote mirrors exist (`RemoteAPI.list_task_ids/1`). PubSub topic `"tasks"` broadcasts `{:task_status, id, status}`.
- **Shutdown:** no SIGTERM/SIGINT/restart handlers anywhere in `:evo_git`; ERTS defaults apply (graceful `init:stop`, apps stop in reverse order, `AgentGroupSupervisor`'s agent Tasks are brutal-killed — fast shutdown, no long timeouts). `bin/genesis_desktop stop` uses `rpc System.stop()` which **cannot work under the desktop env** (`RELEASE_DISTRIBUTION=none`) — the backend must stop itself from inside the BEAM (precedent: `EvoDashWeb.LiveHooks.DesktopQuit.default_stop/0`, a 150ms-delayed `System.stop/0`).

### 2.4 Dashboard (`apps/evo_dash`) — UX integration points
- Version is displayed **only** on the Welcome page footer (`Application.spec(:evo_git, :vsn)`); nothing in the sidebar/navbar.
- Settings categories come from `EvoGit.Config.Schema.schemas_by_category/0` + the **pseudo-category precedent `:remote_connections`** (`settings_live.ex:549` — injected with an empty schema list, renders its own section). An `:updates` category would mirror this exactly; `category_metadata.ex` needs display-name/icon/description/sort entries (unknown categories sort last).
- **Async-check template:** `ReviewLive.MergeCheck` (`review_live/merge_check.ex`) — gated/deduped start, `check_fun = Application.get_env(:evo_dash, :merge_check_runner) || default`, spawned on `EvoDash.TaskSupervisor`, `try/rescue` → error state so the status **can never wedge**, stale-guard on result. An `:update_check_runner` seam fits the established seam-family convention perfectly.
- Reconnect UI: only the standard LiveSocket banners (`#client-error`/`#server-error`) for local backend restarts; no dedicated restart overlay. System page restart (`System.restart()` after 150ms) is the closest precedent.
- Sidebar Active Tasks section (`layouts.ex:143-185`) is loaded on every page via `NodeAware.load_running_and_pending_tasks/1` — the natural home for an "update available / tasks running" banner.
- Desktop integration surface: `EVOGIT_DESKTOP=1` env (set by sidecar, read in `config/runtime.exs` for logging), `TauriDetect` JS hook (`window.__TAURI__` detection → `tauri_detected` assign), and exactly **one** Rust command (`begin_quit`) + one event (`quit-requested`). A new `install_update` / `check_update` command pair would follow the same pattern.

---

## 3. Platform strategy — respecting each platform's update conventions

| Platform | Distribution | Update mechanism | Rationale |
|---|---|---|---|
| **macOS** | `.dmg` / `.app.zip` | **In-app updater** — official `tauri-plugin-updater` (`.tar.gz` updater artifact, minisign Ed25519); or **Sparkle** (`tauri-plugin-sparkle-updater`, third-party) for native update UI | macOS convention is in-app update (Sparkle is the de-facto standard). Both need the Developer ID + notarization the pipeline already has. |
| **Windows** | `.exe` (NSIS) | **In-app updater** — `tauri-plugin-updater`, `installMode: "passive"`, NSIS target | Standard Tauri/Windows convention. **MSI excluded** (known updater bugs, e.g. plugins-workspace #1449; MSI stays for IT/enterprise installs). |
| **Windows** | `.msi` | No auto-update; manual/enterprise (winget or MSI redeploy) | MSI auto-update is unreliable; enterprise users prefer managed deployment. |
| **Linux** | `.deb` / `.rpm` | **Package manager** (apt/dnf). App checks version and **notifies** "update via your package manager"; no self-install | Your stated principle: Linux users update via the distro package manager. Requires hosting an apt (and optionally dnf) repository + GPG-signed metadata. |
| **Linux** | `AppImage` (x64 only) | **In-app updater** — `tauri-plugin-updater` (the only Linux target it supports) | AppImages have no package manager; self-update is the accepted convention. Self-contained (incl. wxWidgets closure — already verified). |
| **Linux** | `.tar.gz` portable | **Download link** (open releases page), never silent replacement | Portable archives can't be atomically replaced from inside a running app. |
| **Linux** | (future Flatpak) | Flatpak itself handles updates | Not built today; if revived, no in-app updater needed. |
| **Remote daemon** | `genesis_remote_*.tar.xz` | Dashboard-initiated remote update (extend `RemoteBootstrap`/`RemoteConnection` with stop → swap → start) | See §6 — current flow overwrites files under a running daemon. |

**Design principle:** the in-app updater is the *transport*, not the *policy*. On Linux, even the AppImage channel should surface a "what's new / changelog" step before applying. On macOS/Windows the platform convention is "silent-ish install with a restart prompt".

---

## 4. Update timing & task safety (the core design)

### 4.1 The threat model
- The app = Rust shell + BEAM child. An update replaces the whole bundle and relaunches. **The BEAM is where long-running agent tasks live.**
- A hard kill mid-task loses: the in-flight turn, `commit_sha` (→ resume can't anchor), and leaves the task to be reconciled to `:failed` on next boot. Worktree git-commits and `tasks.sqlite` survive, but the task is only recoverable through a human review/continue flow.
- Therefore: **the update must never kill the BEAM while tasks are mid-flight** — unless the user explicitly accepts the `:failed`+review cost (force path).

### 4.2 Two-phase model

**Phase 1 — Check & download (safe at any time, runs in the background):**
- Check triggers: app startup (delayed ~30s), every N hours (configurable, e.g. 6h; "push-like" behavior), manual "Check for updates" in Settings.
- The updater plugin fetches the static JSON manifest (see §5), compares versions, and — if the user opted into auto-download or confirmed — downloads the bundle and **verifies the minisign signature** before anything else. Downloading is inert: nothing on disk that the running app depends on is touched.
- UI: Settings → Updates category showing current version / latest version / changelog; a subtle sidebar/tray badge when an update is available. No restart is triggered from Phase 1 alone.

**Phase 2 — Apply (gated):**
- The apply gate (`EvoGit.UpdateGate` or a simple `TaskRegistry` query — the strongest form: `list_task_ids([]) == []`):
  - **Idle** (no `:running`/`:pending`/`:cancelling`/`:finalizing`): proceed immediately.
  - **Busy:** block the apply. UI shows "Update available — N task(s) running". Two choices: **"Later"** (defer; auto-retry when the sidebar reports no active tasks) or **"Apply & gracefully stop tasks"** (user-warned).
- **Graceful wind-down sequence** (the "Apply & gracefully stop tasks" path, or a timed idle-timeout variant):
  1. **Block new work:** mark the update as pending so `start_task` refuses new tasks (reuse the `:cancelling`-style guard: `run_agent` already replies `{:error, :cancelled}` for cancelling tasks).
  2. **Graceful cancel all active tasks:** `TaskRegistry.cancel_task/1` per running task (pending tasks cancel immediately). Each agent gets the 3-turn grace budget; at grace entry all worktree changes are **git-committed**; results/archive/usage are preserved and the final status is `:cancelled`.
  3. **Wait for terminal statuses** with a **generous timeout** (grace is not wall-clock bounded: LLM retry backoff ~9 min, per-tool cap 30 min). Poll `list_task_ids([:running, :pending, :cancelling, :finalizing])`.
  4. **Force-kill fallback:** if the timeout expires (or the user picks the hard path), `force_kill_task/1` all — persists `:failed` with result nil'd. The UI must clearly warn: "in-flight work of these tasks will be lost and they will need manual review".
  5. **Stop the backend:** from inside the BEAM — `System.stop/0` (the `DesktopQuit` precedent). Never `bin/genesis_desktop stop` (broken under `RELEASE_DISTRIBUTION=none`).
- **Rust side (new work):** the watchdog currently treats exit-code-0 as *intentional app exit*. The update flow needs a new path: shell requests backend stop with an **update-intent flag** → backend exits 0 → watchdog runs the **installer** (NSIS silent / AppImage replace / updater-plugin install) → **relaunches** the new bundle instead of exiting. `begin_quit`'s flag mechanism is the natural pattern to generalize.
- **Windows file-lock:** the NSIS installer cannot replace a running `genesis-desktop.exe` — the updater plugin handles exit-before-install, but only if the backend is fully down first (step 5) and the shell exits cleanly. `installMode: "passive"` keeps it non-interactive.

### 4.3 Distinguishing update stops: the `:interrupted` status
- Today, tasks cancelled by an update would persist as `:cancelled` (indistinguishable from user cancel) or `:failed` (force path). Recommend adding **`:interrupted`** to the status set (codec `@known_atoms` + ~10 hardcoded lists — verified feasible; schema has no constraints), written at the same point `:cancelled` is written today when the cancel came from the update flow.
- Benefit: the dashboard can render "interrupted by update" and offer a *resume* affordance (still a human review step, since auto-resume doesn't exist — see §2.3); metrics/audit can distinguish update-induced stops; the startup reconciliation can treat orphaned `:interrupted` predictably.
- Alternative (simpler, v1): reuse `:cancelled` and rely on a `reason` in `opts`/metadata. Acceptable if the status plumbing is deemed too invasive — but the status is the cleaner contract.

### 4.4 What the user loses on each path
| Path | Task outcome | User recovery |
|---|---|---|
| Idle apply (no tasks) | nothing to lose | — |
| Graceful cancel (3-turn grace) | `:cancelled`, results/archive/worktree commits preserved | Review page: results reviewable, `continue`/`merge` work; a resumed task anchors on persisted `commit_sha` |
| Force-kill fallback | `:failed`, result nil'd, in-flight turn lost | Review page shows failed; manual re-run required (no anchor) |
| Crash during update (power loss etc.) | orphaned `:running`/`:pending` → `:failed` at next boot (startup reconciliation) | Same as force-kill; worktrees linger but are cleaned on next run |

**Post-update state:** tasks.sqlite, `.genesis` worktrees, and git branches all survive the bundle swap (they live in the user's project repos / data dir, not inside the app bundle). The new version's startup reconciliation handles orphaned rows. There is **no auto-resume** — this is an acceptable v1 limitation (the review page is the resume surface); document it in the UX copy.

### 4.5 Safety checklist for the apply flow
- [ ] Idle gate checks *all* active statuses, conservatively (include `:finalizing`).
- [ ] New task spawns blocked while update-pending.
- [ ] Graceful wind-down with generous, user-visible timeout + force fallback.
- [ ] Backend stops from inside the BEAM (`System.stop/0`); shell treats it as update-intent.
- [ ] Installer runs only after the backend process is confirmed dead (watchdog).
- [ ] Signature verification of the downloaded bundle before install (plugin does this).
- [ ] Crash-safety: a failed install must leave the *old* version runnable (installers/AppImage replace atomically; NSIS installs to a new version dir before cleanup; never delete the old bundle before the new one is verified).
- [ ] Watchdog must not respawn the old backend *during* install (update-intent flag prevents the 30s respawn loop).

---

## 5. Update feed & infrastructure

### 5.1 Manifest format
`tauri-plugin-updater` consumes a **static JSON manifest** (served over HTTPS; `204 No Content` = no update):

```json
{
  "version": "0.11.0",
  "notes": "…changelog…",
  "pub_date": "2026-01-01T00:00:00Z",
  "platforms": {
    "linux-x86_64":   { "url": "…AppImage…",   "signature": "…minisign sig…" },
    "darwin-aarch64": { "url": "…app.tar.gz…",  "signature": "…minisign sig…" },
    "windows-x86_64": { "url": "…NSIS exe…",    "signature": "…minisign sig…" }
  }
}
```

The `signature` is generated with `tauri signer generate` (minisign Ed25519) + `tauri signer sign`; the **public key is embedded in `tauri.conf.json`** and shipped inside every build. The plugin rejects HTTP by default.

### 5.2 Hosting
Two viable options (or both — the Cloudflare worker can front either):
1. **GitHub Releases (zero new infra):** `publish-release` generates `latest.json` (per-platform entries, signatures from the build) and uploads it to the release. Unversioned names are permanent (`releases/latest/download/<name>`); versioned URLs (`releases/download/<tag>/<name>`) are also permanent and support pinning. **Adopted as the upstream/fallback baseline:** GitHub release assets remain the upstream source the Cloudflare worker proxies, and the GitHub feed URL (`https://github.com/<owner>/<repo>/releases/latest/download/latest.json`) is kept as a secondary fallback endpoint in `tauri.conf.json` (tried after the proxy primary).
2. **genesis.evox.group (China-friendly) — CHOSEN production path:** the existing Cloudflare worker (source is external to this repo — needs a separate repo/ownership decision) serves the manifest + proxied installers, reusing the mainland-China auto-detection the remote tarballs already use. Executed: the app feed endpoint (`plugins.updater.endpoints` in `tauri.conf.json`) points at `https://genesis.evox.group/dl/latest.json`, and the `publish-release` manifest's per-platform payload `url`s point at `https://genesis.evox.group/dl/<filename>` (matching the `/dl/` smart-download convention of `EvoGit.RemoteBootstrap.download_url/1`). Remaining external prerequisite: the worker must serve `latest.json` and the desktop updater payload names (darwin/linux/windows) — today only `genesis_remote_*` tarballs are served there.

**"Push" semantics:** desktop updaters are pull-based by nature. "Push-like" behavior = periodic checks (startup + interval) + a lightweight version-only endpoint (`GET https://genesis.evox.group/dl/latest-version.json` → `{"version": "0.11.0"}`) for the dashboard notification banner without downloading full manifests. A true push channel (WebSocket/APNs/WNS) is unnecessary complexity — the periodic check with a visible notification satisfies the requirement.

### 5.3 What CI must add (`build-desktop.yml`)
1. Generate minisign signatures per updater artifact (`tauri signer sign` on AppImage / NSIS exe / macOS `.tar.gz`) and the `latest.json` manifest; upload both to the release. Requires a **`TAURI_SIGNING_PRIVATE_KEY`** secret.
2. macOS: also staple the `.app.zip` (currently only the DMG is stapled) or accept online-ticket validation; if Sparkle is chosen, add the Sparkle EdDSA keypair + appcast generation.
3. Windows: **Authenticode signing** of the NSIS installer (SmartScreen trust); without it, updates trigger warnings.
4. Linux repos (deb/rpm channels): publish `Packages`/`Release` (GPG-signed) to an apt repo (e.g. `apt.genesis.evox.group`) as part of the release workflow; dnf repo if demanded.
5. Optional: staged rollout / channels via manifest variants (`latest.json` vs `beta.json`; the Cloudflare worker can do percentage-based rollout by serving different manifests).

---

## 6. The remote daemon (`genesis_remote`) — same problem, worse today

`RemoteBootstrap`/`RemoteConnection` update flow currently **overwrites release files under a running daemon** (old code in memory, new files on disk, new code only after a manual restart) and has no version comparison. If remote daemons are in scope, the same design applies: dashboard-initiated update gated on the remote node's task idle state (`RemoteAPI.list_task_ids/1` exists), then stop daemon → swap tarball → start daemon. This is follow-up work, not part of the desktop updater.

---

## 7. Prerequisites / blockers (in dependency order)

| # | Prerequisite | Effort | Blocker for |
|---|---|---|---|
| 1 | **Minisign keypair** (`tauri signer generate`) + `TAURI_SIGNING_PRIVATE_KEY`/`TAURI_SIGNING_PUBLIC_KEY` CI secrets; pubkey embedded in `tauri.conf.json` | Low | All platforms' in-app updater |
| 2 | **Manifest + signature generation** step in `publish-release` (version from the prepare job's `release_version` output — the tag minus `v`) | Low-Med | Feed existence |
| 3 | **Windows Authenticode cert** (e.g. Azure Trusted Signing or an EV cert) + signtool step | Med (cost/ownership) | Windows trust (SmartScreen) |
| 4 | **macOS `.app.zip` stapling** (extend `notarize-macos-dmg.sh` to the zip) | Low | macOS smooth UX (recommended) |
| 5 | **Linux apt/dnf repo hosting + GPG key** | Med | deb/rpm "notify, don't self-install" strategy |
| 6 | Rust: `tauri-plugin-updater` dep + config + capability + apply/relaunch watchdog state | Med | Everything client-side |
| 7 | `:interrupted` status plumbing (codec + ~10 lists) | Low-Med | Distinguishable update stops |
| 8 | Dashboard Updates category + banner + seams | Med | UX |

---

## 8. Phased implementation plan

- **Phase 0 — Keys & feed plumbing:** **DONE except the keypair/secrets (user-owned)** — `publish-release` generates and uploads `latest.json` to the GitHub release (the upstream), from which it is served to the app via the genesis.evox.group `/dl/` proxy; build jobs sign updater payloads when the key env is present, macOS staples the `.app` + repacks/re-signs the updater `.app.tar.gz`. Remaining: the minisign keypair itself, Windows Authenticode, apt/dnf repos.
- **Phase 1 — Client check (read-only):** **DONE** — `tauri-plugin-updater` dep + `plugins.updater` config + `bundle.createUpdaterArtifacts`; `check_update`/`download_update`/`begin_update` commands; System page Software Update card with `:update_check_runner` seam; background check (startup 30s + ~6h + page mount) with auto-download; sidebar notification dot (amber/blue). Note: implemented on the System page (per the §11 product decision) rather than a Settings → Updates category; no `updater:default` capability was needed (custom commands).
- **Phase 2 — Safe apply:** **DONE except `:interrupted` status** (v1 fallback = `:cancelled` + review page, §9 #7) — idle gate + graceful wind-down implemented in the dashboard (`TaskRegistry.list_task_ids` via the node-aware path, graceful-cancel all with ~35min budget + user-warned `force_kill_task/1` fallback; no `EvoGit.UpdateGate` core module — the gate lives in `SystemLive`/`EvoDash.UpdateStatus`); watchdog update-intent state (stop → install → relaunch); apply modal with Defer / "Apply & gracefully stop tasks" / force warning.
- **Phase 3 — Linux package-manager channels:** **DEFERRED** — deb/rpm installs are notify-only today (detected via `APPIMAGE` env nil; card shows "update via your package manager", no self-install). apt/dnf repo publishing + GPG not started.
- **Phase 4 — Polish:** **DEFERRED** — staged rollout/channels, update failure rollback verification, remote-daemon update flow (§6), optional Sparkle migration.

---

## 9. Open questions for decision

1. **Windows certificate:** who owns the Authenticode cert (cost ~$100–400/yr) — mandatory for a trustworthy auto-update on Windows? — **STILL OPEN (external blocker)**; the updater mechanism works without it but SmartScreen warns.
2. **Linux repos:** host official apt/dnf repos, or ship installers + notify and let distros package? — **STILL OPEN (Phase 3)**; v1 ships AppImage auto-update + notification-only for deb/rpm.
3. **Update cadence & auto-download policy:** — **DECIDED**: check on startup (delayed ~30s) + manual "Check now" + periodic ~6h; **auto-download in background** (download + verify is inert — the plugin verifies before writing) so the dot reaches "ready" without user action; a policy knob is deferred.
4. **Staged rollout:** beta/stable channel split? — **DEFERRED** (manifest variants `latest.json`/`beta.json` later; the Cloudflare worker can do percentage rollout).
5. **macOS:** official updater plugin vs Sparkle — **DECIDED: official plugin** (§1.1); Sparkle only if a native macOS update panel becomes a hard requirement.
6. **Remote daemons:** include the remote-update flow (§6) in this effort or defer? — **DEFERRED** (separate stop→swap→start flow).
7. **`:interrupted` status vs `:cancelled` + reason metadata:** — **v1 fallback CHOSEN** (`:cancelled` + the review page, results preserved; no reason metadata written); `:interrupted` remains the recommended upgrade for later polish (codec `@known_atoms` + ~10 hardcoded lists, verified feasible).

---

## 10. CI automation — the exact changes (`build-desktop.yml`)

**Prerequisite (once, outside CI):** `tauri signer generate -w ~/.tauri/genesis.key` → store the private key + password as GitHub secrets **`TAURI_SIGNING_PRIVATE_KEY`** and **`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`**; put the contents of `genesis.key.pub` into `desktop/src-tauri/tauri.conf.json` → `plugins.updater.pubkey`. Losing the key loses the ability to sign updates (rotation requires embedding a new pubkey in a shipped build).

### 10.1 Build jobs (build-linux, build-macos-arm64, build-windows-x64)
1. **`tauri.conf.json`**: set `bundle.createUpdaterArtifacts: true` (+ the `plugins.updater` block from §1.1). The pinned tauri CLI (2.11.4, workflow L40) supports it.
2. **Signing env at build time**: pass the two secrets to each `tauri build` step — with the env set, tauri signs the updater artifacts automatically (`.AppImage.tar.gz.sig`, `.app.tar.gz.sig`, NSIS `.exe.sig`) and no separate minisign step is needed. (Alternative if build-time signing proves awkward: sign the payloads in the publish job with `tauri signer sign -k <key> <file>`.)
3. **macOS job** (L503-575 signing/notarization, L593-595 zip staging): restructure the order to build → notarize → **staple the `.app`** → create the updater archive **`.app.tar.gz`** from the notarized app (replace the `ditto -c -k --keepParent` `.app.zip` staging). The `.app.zip` may remain for distribution; the tar.gz is the feed payload.
4. **Windows**: Authenticode signing of the NSIS exe remains an external blocker (§7 #3). No MSI goes into the feed.
5. **Linux x64**: the AppImage updater payload is produced automatically; **arm64 has NO AppImage** → no updater entry for arm64 (deb/rpm only, package-manager path §3).

### 10.2 publish-release job — manifest generation
- New step between the artifact download (L766-771, `actions/download-artifact`) and the upload step (L784-792, `softprops/action-gh-release` with `files: dist/*`, creating a draft that `gh release edit --draft=false` flips public at L794-801):
  - `version` = the prepare job's `release_version` output (tag minus `v`, computed in its `meta` step).
  - Collect the updater payloads present in `dist/` — `darwin-aarch64` → `.app.tar.gz`, `linux-x86_64` → AppImage `.tar.gz` (x64 only), `windows-x86_64` → NSIS exe. For each: `url` = `https://genesis.evox.group/dl/<filename>` — the unversioned `/dl/` smart-download URL the Cloudflare worker resolves against the latest GitHub release (the GitHub `releases/download/<tag>/<filename>` remains the upstream the worker proxies), `signature` = **full contents of the `.sig` file** (including the `untrusted comment:` header lines — the plugin requires the whole file content, not a URL).
  - Write `dist/latest.json`:
    ```json
    {
      "version": "0.11.0",
      "notes": "<release body / changelog>",
      "pub_date": "<ISO 8601 UTC now>",
      "platforms": {
        "darwin-aarch64":  { "url": "...app.tar.gz", "signature": "..." },
        "linux-x86_64":    { "url": "...AppImage.tar.gz", "signature": "..." },
        "windows-x86_64":  { "url": "...setup.exe", "signature": "..." }
      }
    }
    ```
  - It is then uploaded automatically by `files: dist/*`. The server must NOT 204 this file (only a "no update" response may be 204); a missing platform entry means "no update for this platform".
- **Feed URL for the app**: `https://genesis.evox.group/dl/latest.json` as the primary (mainland-China reachable) endpoint, with `https://github.com/<owner>/<repo>/releases/latest/download/latest.json` as a secondary fallback — both are configured in `tauri.conf.json` `plugins.updater.endpoints` and tried in order (the unversioned GitHub asset name stays permanent as the upstream convention).
- **Excluded from the manifest**: `.msi`, `.deb`, `.rpm`, `.dmg`, portable `.tar.gz`, and all `genesis_remote_*` tarballs (remote daemons have their own deferred stop→swap→start flow, §6).
- The workflow never reads `VERSION` today (verified — version is baked at build time; the tag-derived `release_version` output is the manifest's version source; keep it that way).

---

## 11. UX — "Check Update" component on the System page (decided)

Per the product decision: a **Check Update component on the System page** (`SystemLive`), with a **small notification dot** when an update is available or already downloaded, and a **manual click to perform the update**. No auto-apply ever.

### 11.1 Where it lives
- **System page card**: a new "Software Update" card in `apps/evo_dash/lib/evo_dash_web/live/system_live.ex`, in the System Control section (after the restart/stop controls ~L114, before System Self-Check ~L116). `SystemLive` is the flat, no-category "System page" with the established async pattern (`spawn_system_checks/1` L809 → `EvoDash.TaskSupervisor` → `{:system_checks_result, ...}` handle_info L765) that a `{:update_check_result, ...}` handler mirrors 1:1.
- **Visibility gate**: render only when local node AND desktop context — `Application.get_env(:evo_dash, :desktop_release, false) or System.get_env("EVOGIT_DESKTOP") == "1"` (`:desktop_release` is baked into the `genesis_desktop` release, mix.exs:32) and `@current_node in [nil, node()]`. Hidden on `mix` dev server and on remote `genesis_remote` nodes. Test seam: `:desktop_release` env override.
- **Notification dot**: (a) on the **System nav item** in the app sidebar (`sidebar_nav_link/1`, `components/layouts.ex:391-414` — new optional `notification` attr + dot span, reusing the existing dot classes L338-345), and (b) inside the card. Amber dot = "update available"; blue `animate-ping` dot = "downloaded & verified, ready to install". To render the dot on every page, a global `UpdateStatus` on-mount hook (registered in `lib/evo_dash_web.ex` beside NodeAware/DesktopQuit) seeds `@update_status` and subscribes to `EvoGit.PubSub` topic `"updates"`; the System page card is the interactive surface.

### 11.2 States and copy
| state | UI |
|---|---|
| `:checking` | spinner, "Checking for updates…" |
| `:up_to_date` | "Genesis \<current\> is up to date" + last-checked time |
| `:available` | "Version \<latest\> is available" + changelog notes + **Download** button + amber dot |
| `:ready` | "Update ready — version \<latest\>" + **Restart & Update** button + blue ping dot |
| `:error` | "Check failed" + Retry (MergeCheck-style: the status can never wedge) |
| `:applying` | "Installing…" (buttons disabled) |

### 11.3 Event flow (LiveView ↔ JS hook ↔ Rust ↔ watchdog)
The `begin_quit`/`DesktopQuit` precedent (JS `invoke` → Rust flag → backend `System.stop/0` → watchdog exit-code handling) generalizes to update:

1. **Check** (Phase 1, safe anytime): on app start / System page mount (+ optional ~6h timer), the JS `UpdateChecker` hook (`assets/js/app.js`, hooks map ~L830) invokes `check_update` (Rust `UpdaterExt` `app.updater().check()`) and pushes `update_check_result` (status / current / latest / notes / downloaded?) back to the LiveView; `handle_event` assigns `@update_status` and broadcasts on `EvoGit.PubSub` `"updates"` so the sidebar dot updates on any page. Browser/test path: `:update_check_runner` seam (the `:merge_check_runner` family) returns a stub; the hook no-ops outside Tauri (`if (!isTauri) return`, DesktopQuit pattern L697-702).
2. **Download** (Phase 1, safe): "Download" button → `invoke("download_update")` → progress events → `:ready`. Recommended default: **auto-download after a successful check** (download + verify is inert), so the dot goes straight to `:ready`; a policy knob is deferred (§9 #3).
3. **Apply** (Phase 2, gated — the only dangerous step):
   a. "Restart & Update" → the LiveView runs the **idle gate**: `EvoGit.TaskRegistry.list_task_ids([:running, :pending, :cancelling, :finalizing]) == []`.
   b. **Idle** → proceed. **Busy** → modal: "N task(s) still running" with **Defer** (auto-retry when the sidebar reports no active tasks) or **Apply & gracefully stop tasks** (graceful-cancel all via `TaskRegistry.cancel_task/1` — 3-turn grace, worktree auto-commit at grace entry, results preserved as `:cancelled`; generous timeout, then user-warned `force_kill_task/1` fallback → `:failed`). Recommended `:interrupted` status (codec + ~10 lists) marks update-induced stops (§4.3).
   c. Gate passed → JS `invoke("begin_update")` → Rust sets the **update-intent flag** (generalizing `intentional_shutdown`/`begin_quit`, `backend_watchdog.rs`) → the hook pushes `begin_update_confirmed` → LiveView triggers `System.stop/0` from inside the BEAM (`EvoDashWeb.LiveHooks.DesktopQuit.default_stop/0` 150ms-delayed precedent — `bin/genesis_desktop stop` is broken under `RELEASE_DISTRIBUTION=none`) → backend exits 0 → **watchdog sees update-intent and runs the installer** (plugin `install()` on the verified payload: NSIS passive on Windows — install restarts the app itself; AppImage self-replace on Linux x64; `.app` swap on macOS) **then relaunches the new bundle** instead of `app.exit(0)`.
   d. Windows file-lock note: NSIS cannot replace a running exe — the backend is fully down (c) and the shell exits before/at install; the single-instance plugin (registered first) requires the old instance fully dead before the relaunched one starts.
4. **Post-update**: `tasks.sqlite`, worktrees, and git branches survive the bundle swap (they live outside the app bundle); the new version's startup reconciliation handles orphaned rows; `EvoGit.Config.VersionState.upgraded?/0` (persisted version-state file) can drive a "What's new" hint on the Welcome page.

### 11.4 Test seams (established family)
`:update_check_runner` (MergeCheck-style function seam), `:desktop_release` app env, send-pattern injection (`send(view.pid, {:update_check_result, ...})`, system_live_test.exs:40-44 pattern), fake JS hooks in the frontend tests.

---

## 12. Appendix — key file references

- `desktop/src-tauri/tauri.conf.json`, `Cargo.toml`, `capabilities/default.json`, `src/main.rs` (`begin_quit`, tray quit, watchdog wiring), `src/backend_watchdog.rs` (classify_exit, finish_shutdown, respawn loop), `src/sidecar.rs` (spawn/env/termination).
- `.github/workflows/build-desktop.yml` (L503-575 macOS signing/notarization; L706-721 Windows; L724-758 publish), `desktop/scripts/notarize-macos-dmg.sh`, `apps/evo_git/lib/mix/tasks/bump.version.ex`.
- `apps/evo_git/lib/evo_git/task_registry.ex` (cancel/force_kill/init reconciliation), `lib/evo_git/agent/runner.ex` (`@cancel_grace_turns 3`, `maybe_enter_cancel_grace`), `lib/evo_git/store/codec.ex` (`@known_atoms`), `lib/evo_git/store.ex` (status filters, WAL, terminate), `lib/evo_git/agent_scheduler.ex` (`begin_graceful_cancel`), `lib/evo_git/agent_scheduler/remote_api.ex` (RPC mirrors).
- `apps/evo_dash/lib/evo_dash_web/live/settings_live.ex` (pseudo-category `:remote_connections` L549), `live/settings_live/review_live/merge_check.ex` (async seam template), `lib/evo_dash_web/live_hooks/desktop_quit.ex` (`System.stop/0` precedent), `lib/evo_dash_web/live_hooks/node_aware.ex` (active-tasks loader), `assets/js/app.js` (TauriDetect, `begin_quit` invoke).
- Relevant CONTEXT.md sections added during this analysis: `desktop/CONTEXT.md` + `desktop/src-tauri/CONTEXT.md` (Auto-Update Status), `.github/workflows/CONTEXT.md` (release publishing & updater readiness), `apps/evo_git/CONTEXT.md` (Update-Timing Safety), `apps/evo_dash/CONTEXT.md` (version display / onboarding note).
