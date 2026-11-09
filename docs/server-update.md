# Server Self-Update (`genesis update`)

**Status:** Implemented in the `genesis_server` release CLI (`rel/overlays/bin/genesis` → `<release>/bin/genesis`): `genesis update` (alias `genesis upgrade`) fetches the release feed, checks the version, gates on an idle server through `GET /server/status`, verifies a published sha256, stages the new tree beside the install, stops → swaps → restarts, verifies `/health`, and rolls back to the previous tree when the new version does not come up.
**Scope:** The headless `genesis_server` release — the dashboard server that is also the SSH remote-development target, installed by `scripts/install.sh` (by default into `~/.local/share/genesis/server`).
The desktop app's in-process updater is a different component with a different design record: see [Auto-Update / Push-Update](auto-update.md).
**Out of scope (deferred):** dashboard-initiated upgrades and upgrade orchestration of a remote node over SSH — see §7 and `auto-update.md` §6.

---

## 1. Intent and architecture

There is exactly one way to upgrade a headless install: run the release's own shell CLI.
That choice is structural, not cosmetic — three properties are required and only the CLI has all three:

- **It works when the BEAM cannot boot.** A server whose config is broken, whose port is taken, or whose release is half-written must still be upgradable, so the updater cannot be a `mix` task, a Phoenix endpoint, or an `elixir_eval` command inside the application it is replacing.
- **It is outside the process being replaced.** The upgrade is a `stop → swap → start` of a whole release tree; a component running inside that tree cannot replace the files it is executing from (the same reason `genesis stop`/`genesis status`/`genesis logs` avoid the BEAM).
- **It is the only component that knows how to stop and start this host's instance.** The CLI already owns the service backends (`systemd-run --user`, launchd, pidfile fallback), the persisted `ip`/`port`, the linger policy and the `/health` probe, so the updater reuses them instead of re-deriving them.

Why not the Tauri updater plugin: `tauri-plugin-updater` installs a signed *desktop bundle* through platform installers (NSIS passive, AppImage self-replace, `.app` swap), it is driven from a WebView that must already be running, and its trust model is the minisign key embedded in the shipped binary.
A headless server has no bundle, no WebView and no launcher: it needs a tarball extracted over a directory plus a supervised restart, verified by a per-release sha256 rather than a signature embedded in the previous build.
Sharing one updater would mean shipping the Tauri shell (and its update key) onto database servers that deliberately run no desktop components at all.

The implementation is a single POSIX `sh` file with `set -eu` and no BEAM boot.
It deliberately depends only on coreutils (`sed`, `awk`, `mktemp`, `mv`, `tar` with xz support), plus `curl` or `wget`, plus `sha256sum` (or `shasum -a 256`) for verification — no `jq`, no `python`, no `git`.
The manifest is therefore read line-oriented out of the JSON text: the scalar fields (`version`, `notes`, `pub_date`) parse from a pretty-printed OR a compact body, while the per-platform `sha256` is located line-wise inside the `server` object and therefore expects the pretty-printed manifest CI writes — a compact one-line body finds no digest there and falls through to the published `.sha256`, then to the warn-and-skip path.

The CLI lives at `<install>/bin/genesis`, resolves `$GENESIS_HOME` from its own (symlink-resolved) path, and replaces that release tree in place.
Because it resolves `$0` through symlinks, the `~/.local/bin/genesis` symlink created by the installer keeps working across an upgrade — the symlink points at the path, not at an inode.

---

## 2. The feed

`latest.json` served at `https://genesis.evox.group/dl/latest.json` is the primary feed; the GitHub release asset is the fallback (`https://github.com/EMI-Group/genesis/releases/latest/download/latest.json`).
Both are read through the two env overrides (`GENESIS_DOWNLOAD_BASE`, `GENESIS_DOWNLOAD_FALLBACK_BASE`, §3) and their trailing slashes are trimmed.

The file is produced by the `publish-release` job's "Generate updater manifest (latest.json)" step in `.github/workflows/build-desktop.yml`, and it is the SAME file the desktop updater consumes.
The server payloads live in a separate `server` map so neither consumer has to understand the other's schema:

```json
{
  "version": "0.14.1",
  "notes": "…changelog section…",
  "pub_date": "2026-11-08T12:00:00Z",
  "platforms": { "darwin-aarch64": { "url": "…", "signature": "…" } },
  "server": {
    "linux_x64":    { "url": "https://genesis.evox.group/dl/genesis_server_linux_x64.tar.xz",    "sha256": "<64 hex>" },
    "linux_arm64":  { "url": "https://genesis.evox.group/dl/genesis_server_linux_arm64.tar.xz",  "sha256": "<64 hex>" },
    "darwin_arm64": { "url": "https://genesis.evox.group/dl/genesis_server_darwin_arm64.tar.xz", "sha256": "<64 hex>" }
  }
}
```

- A `server` entry exists only for a tarball actually staged in `dist/`, so a partial release (one platform job failed or was skipped) publishes a partial map rather than a broken entry.
- `latest.json` is written when EITHER `platforms` OR `server` is non-empty, so a server-only release still publishes the feed; when both are empty the step prints "no signed updater payloads or server tarballs found — latest.json not written" and exits 0.
- Every staged tarball also gets a published `genesis_server_<platform>.tar.xz.sha256` asset holding `<digest>  <filename>` (two spaces), which is the checksum shape both `scripts/install.sh` and the updater accept.
- The CLI uses the manifest for `version`, `notes`, `pub_date` and its platform's `sha256` only; it builds the tarball URL itself from the base plus the asset name, so the manifest's `url` field is documentation for humans, not an input.
- The bootstrap/install path (`scripts/install.sh`) reads the `<asset>.sha256` beside the tarball; `genesis update` prefers the manifest digest and falls back to the same `.sha256` file, so both entry points verify the same published value.

### 2.1 URL shapes

| Feed | Latest | Pinned (`--version TAG`) |
|---|---|---|
| Manifest (primary) | `<base>/latest.json` | `<base>/<tag>/latest.json` |
| Manifest (fallback) | `<fallback>/latest/download/latest.json` | `<fallback>/download/<tag>/latest.json` |
| Tarball (primary) | `<base>/genesis_server_<platform>.tar.xz` | `<base>/<tag>/genesis_server_<platform>.tar.xz` |
| Tarball (fallback) | `<fallback>/latest/download/genesis_server_<platform>.tar.xz` | `<fallback>/download/<tag>/genesis_server_<platform>.tar.xz` |
| Checksum file | `<the URL that served the tarball>.sha256` | same |

Primaries are tried before fallbacks, a URL identical to the previous attempt is skipped once, and every failed attempt prints its own `Warning: could not fetch …` / `Warning: download failed: …` line before the next candidate is tried.

`--version` accepts `0.13.0` or `v0.13.0`; the tag is normalized to `v<version>` for URLs and displayed without the prefix.

**Worker caveat (external, and load-bearing):** the `/dl/` Cloudflare worker accepts the unversioned `/dl/<asset>` and `/dl/latest/<asset>` forms, and the tag-scoped `/dl/<tag>/<asset>` form only once the `genesis-doc` worker has been deployed.
The worker source for the tag-scoped form ships in that external repo behind a manual `pnpm deploy`, so a pinned `genesis update --version <tag>` may 404 on the primary base and succeed through the GitHub fallback's `releases/download/<tag>/…` shape.
The unversioned forms used by a plain `genesis update` are live.

---

## 3. Command surface

```bash
genesis update                 # install the newest release (no-op when up to date)
genesis update --check         # report only; exit 10 when an update is available
genesis update --check --json  # one machine-readable line
genesis upgrade                # alias for `genesis update`
genesis update --version 0.13.0 # install (or downgrade to) a specific tag
genesis update --force         # reinstall, and bypass the busy/foreground guard
genesis update --wait 90       # health budget after the restart (default 30s)
genesis update --no-linger     # do not offer to enable systemd lingering on the restart
```

| Flag | Meaning |
|---|---|
| `--check` | Fetch the feed and compare versions only. Nothing is downloaded, installed, staged or stopped, and nothing is written into the data directory. |
| `--json` | With `--check`: exactly ONE stdout line, `{"current":"<v>","latest":"<v>","available":true|false}` plus `"pub_date":"…"` when the release publishes one. Ignored by an applying run. |
| `--version TAG` | Install this release tag instead of the latest. An explicit tag may be older or newer than the installed version. |
| `--force` | Reinstall even when the target version is already installed, and bypass the active-task / foreground-server guard. |
| `--wait N` | Digits only, at least 1, default 30. Seconds the post-restart `/health` probe may take; it is the same budget `genesis start` uses, overridden for this run only. |
| `--no-linger` | Forwarded to the restart path so `ensure_linger` does not offer to enable systemd lingering. |

Both `--flag value` and `--flag=value` are accepted; `-h`/`--help` prints the update help.
An unknown option is a usage error (exit 2).

Environment overrides, read at run time:

| Variable | Default |
|---|---|
| `GENESIS_DOWNLOAD_BASE` | `https://genesis.evox.group/dl` |
| `GENESIS_DOWNLOAD_FALLBACK_BASE` | `https://github.com/EMI-Group/genesis/releases` |
| `GENESIS_HOME` | the release root derived from the script's own path |
| `GENESIS_DATA_DIR` | the platform data dir (`$XDG_DATA_HOME/genesis`, `~/.local/share/genesis`, or `~/Library/Application Support/genesis`) — holds `server.env`, the logs and `update.lock` |
| `TMPDIR` | where the download temp dir is created |

Exit codes: `0` success or already up to date, `10` update available (`--check` only), `1` failure, `2` usage error.

The exact user-facing lines are:

- Check, update available (stdout): `Update available: <latest> (installed <current>)`, then `Released: <pub_date>` when known, then an optional `Notes:` block (each note line indented by two spaces), then ``Run `genesis update` to install it.``
- Up to date (stdout): `Genesis <current> is up to date.`
- Apply (stdout): the same `Update available` block, then `Downloading <asset> (<version>)`, `Checksum verified.`, `Installing Genesis <version> to <install dir>`, `Stopping the Genesis server.`, `Starting the Genesis server.`, `Genesis server starting (<backend> backend).`, `Dashboard: <url>`, `Genesis server is healthy: <url>`, and finally `Genesis updated: <old> → <new>`.
- Server was not running (stdout): `Genesis updated: <old> → <new>` and ``The server was not running; run `genesis start` to start Genesis <new>.``
- Rollback (stdout): `The new version did not become healthy; rolling back to <old>.`, then the restart lines, then `Genesis update failed; the previous version is running.`
- Rollback that also fails: `Genesis update failed and the previous version (<old>) did not start either.`, `The previous release is installed at <install dir>; see `genesis logs` for the failure.` and the dashboard URL — all on stderr.
- Interrupted (stderr): `Genesis update interrupted; cleaning up.` (exit 130 on `INT`, 143 on `TERM`).

---

## 4. End-to-end flow

1. **Resolve the install.** `require_launcher` guarantees `$GENESIS_HOME/bin/genesis_server` exists; a wrong `GENESIS_HOME` fails before anything else ("not inside a Genesis server release").
2. **Resolve the platform key** from `uname`: `linux_x64`, `linux_arm64` or `darwin_arm64`. Anything else (including every Windows shell) fails with `no Genesis server build for <platform> (available: linux_x64, linux_arm64, darwin_arm64)` — even for `--check`.
3. **Create the temp dir** (`${TMPDIR:-/tmp}/genesis-update.XXXXXX`) for the manifest, the tarball, the checksum file and the extraction.
4. **Fetch the manifest** from the primary base, then the GitHub fallback (§2.1). Both failing aborts with ``could not fetch the Genesis release feed (<latest|tag>); check your network or set GENESIS_DOWNLOAD_BASE``.
5. **Compare versions.** The installed version comes from `<release>/bin/genesis_server version` (no BEAM boot needed), else `releases/start_erl.data`, else `unknown`. Comparison is on the numeric core with a leading `v`, `-prerelease` and `+build` stripped and missing components read as zero (`0.13` == `0.13.0`). Latest mode installs only when the feed is strictly newer, so a stale mirror can never downgrade a server; an explicit `--version` installs whenever the normalized versions differ; `--force` always installs. An undeterminable installed version only warns (`Warning: could not determine the installed Genesis version; installing <v>.`).
6. **Report or stop here.** Up to date → the up-to-date line and exit 0 (nothing was downloaded, nothing was locked). `--check` → the availability report and exit 10.
7. **Pre-flight writability.** The parent of the install directory must exist and be writable; otherwise the run dies (exit 1) with `the parent of the install directory (<parent>) is not writable; re-run the installer as the user who owns <install dir>` — before a single byte is downloaded.
8. **Take the lock.** `mkdir <data dir>/update.lock` plus a `pid` file inside it (§5).
9. **Busy/idle gate.** `service_active` decides whether a supervised instance is running; when it is, `GET <dashboard url>/server/status` supplies `active_tasks`, and a non-zero count refuses the update (exit 1) with `The Genesis server has <n> active task(s); updating now would interrupt them.` / `Wait for them to finish, or pass --force to update anyway.` When no service is active but `/health` still answers, a foreground `genesis serve` owns the port: the run refuses with `A foreground Genesis server is running at <url> (started with `genesis serve`).` unless `--force` was passed (§5).
10. **Download** `genesis_server_<platform>.tar.xz` from the same candidate list as the manifest, into the temp dir.
11. **Verify the checksum, still before any stop.** The target digest is the manifest's `server.<platform>.sha256` (searched inside the `server` object first, then the whole file for manifests without the wrapper); when absent, the published `<tarball URL>.sha256` beside the URL that actually served the download is used. `sha256sum` (or `shasum -a 256`) compares it: match → `Checksum verified.`; mismatch → abort (exit 1) with `checksum mismatch for <asset>; the download may be corrupt or tampered with (delete it and retry)`; no digest anywhere, or no sha256 tool → a warning and the run continues (the same tolerance as `scripts/install.sh`, so the first upgrade away from a release that published no checksum still works).
12. **Extract and validate the staged tree.** `tar -xJf` into the temp dir; the tarball root is `genesis_server/` (a flat archive is tolerated), and `bin/genesis_server` must exist. The staged `releases/start_erl.data` release version must match the requested target, else `the downloaded release is <staged> but <target> was requested; nothing was changed`.
13. **Stage beside the install.** A `mktemp -d <install parent>/.genesis-update.XXXXXX` directory receives the extracted tree via `cp -R`, so the swap at step 15 is a rename inside one filesystem rather than a cross-device copy.
14. **Read the current bind address** from `<data dir>/server.env` (or the defaults `127.0.0.1:9999`), then stop the service through the same backend `genesis stop` uses and wait up to 10 s for it to become inactive.
15. **Atomic swap.** Two renames: the live tree becomes `<install>.old.$$`, then the staged tree becomes `<install>`. If the second rename fails the first is undone and the run dies with "failed to move the new release into <install>". `<install>/bin/*` is `chmod +x`ed so a tarball built without exec bits still boots.
16. **If nothing was running**, the old tree is deleted immediately and the run reports the update plus the ``run `genesis start` `` hint — an update never silently starts a server that was stopped.
17. **Restart** through `start_and_wait` with the saved ip/port and `START_TIMEOUT=$UPD_WAIT`, so `--wait` is the health budget: the CLI prints `Starting the Genesis server.` and then the usual start lines (`Genesis server starting (<backend> backend).`, `Dashboard: <url>`, `Genesis server is healthy: <url>`).
18. **Success** → the old tree is deleted and `Genesis updated: <old> → <new>` is printed.
19. **Failure** → the new version is stopped, the live tree removed (guarded against an empty or `/` install path), `<install>.old.$$` moved back, and the old version restarted and health-verified. The run exits 1 and reports which of the two situations the operator is in.

Distribution needs no handling: a restarted instance re-adopts its Erlang-distribution intent from `<data dir>/remote/desired.env` at boot, so an SSH remote-dev server comes back as a remote target without a second `genesis remote start`.

### 4.1 The idle gate: `GET /server/status`

`EvoDashWeb.ServerStatusController` is mounted outside every pipeline, like `/health`: no session, no CSRF, no HTML negotiation, and no task data beyond a count.
The response is `200` with `application/json`:

```json
{"status":"ok","version":"0.14.1","active_tasks":0}
```

- `active_tasks` counts task ids in `:running`, `:pending`, `:cancelling` and `:finalizing` — `:finalizing` is included because such a task still owns its worktree and its merge-back work.
- Only the COUNT is exposed: never task ids, titles, objectives or repo paths.
- When the task read fails (raise, `:exit`/timeout, or a non-list), the value degrades to `-1` rather than `0`, because a plausible `0` would let the updater stop the server out from under running tasks.
- `version` is the `:evo_git` app version (the identity the server CLI reports) and degrades to `"unknown"` when it cannot be read.

The CLI reads it with the same 3 s probe timeout as `/health` (curl or wget), against the URL it would print — a wildcard bind is therefore probed on `127.0.0.1`, and an IPv6 bind is bracketed.
Its tolerance is deliberate, because the FIRST upgrade away from an older release must work: an unreachable endpoint, an empty body, an absent `active_tasks` field (which is also how a `-1` degraded count reaches the parser — the number reader only accepts unsigned digits) all print a `Warning: …` line and continue with the update, while only a readable positive count refuses.

---

## 5. Safety invariants

- **Never stop before a verified download.** The feed, the download, the checksum, the extraction, the staged `bin/genesis_server` and the staged release version are all validated before the service is touched.
- **The swap is two renames inside the install parent.** The staged tree is created next to the live tree, so an interrupted swap can never leave a partially copied release at `<install>`.
- **The previous tree survives until the new version is healthy.** `<install>.old.$$` is deleted only after `/health` answers; otherwise it is moved back and the old version is restarted.
- **Interruptions are cleaned up.** `EXIT`, `INT` and `TERM` traps remove the temp dir, the staging dir and the lock, and restore `<install>.old.$$` if a kill landed between the two renames.
- **One update at a time.** `<data dir>/update.lock` is an atomic `mkdir` lock containing the owner's pid: a live owner aborts the second run (`another update is in progress (pid <pid>); wait for it to finish, or remove <lock> if that pid is gone`), a dead owner's lock is recovered and retried (three attempts, one second of grace for the winner to write its pid).
- **An unwritable install fails before the download.** A root-owned install run by another user stops at step 7 with an actionable message instead of after a download.
- **Latest mode never downgrades.** Only `--version` (explicit intent) may install an older release; `--force` reinstalls the same one.
- **No task is silently killed.** A busy server is refused, not drained: the CLI has no graceful-cancel path, so the operator either waits or accepts `--force`.
- **The install path is a path, not an inode.** The CLI replaces the tree the `~/.local/bin/genesis` symlink resolves to, so the shortcut and any `PATH` entry keep working with no re-link step.
- **Minimal dependencies.** Single POSIX `sh` file, coreutils + `curl`|`wget` + `tar.xz` + `sha256sum`|`shasum`; the manifest is parsed with `sed`/`awk` and a missing checksum tool only downgrades verification to a warning instead of failing the upgrade.

---

## 6. Operator notes

- `genesis update --check` is safe to run from cron or a monitoring script: it exits `10` on availability (`0` when current) and writes nothing.
- `genesis update` is safe to re-run: an up-to-date install is a no-op, and a crashed run leaves either the old tree or a recoverable lock.
- After a rollback, read `genesis logs`: the failed start's log tail is printed by the start path, and when the OLD version fails to start too the CLI reports the install path the previous release was restored to.
- Pinning a version is the escape hatch for a bad release: `genesis update --version <previous tag>` downgrades in place through the same verified swap.
- Upgrading a server that is also an SSH remote target does not need `genesis remote stop` first; the restarted instance re-adopts distribution from `desired.env`.
- The dashboard is unavailable for the length of the stop → swap → start window (seconds), and the browser tab has to reconnect.

---

## 7. Limitations and out of scope

- **No dashboard-initiated upgrade.** There is no "update server" button or LiveView command: the running dashboard cannot replace its own release tree, and adding a privileged endpoint that runs the CLI would add an unauthenticated remote-execution surface for no gain over the shell.
- **No remote-node (SSH) upgrade orchestration.** The local dashboard does not drive `genesis update` on a connected remote node. The pieces that would be needed exist (`EvoGit.RemoteAPI.list_task_ids/1` for the idle gate, argv-array remote commands for the execution), but the flow is still deferred — see `auto-update.md` §6.
- **No graceful drain.** Busy tasks are not cancelled or awaited by the CLI; `--force` stops the server with them still running, so they lose their in-flight turn context and the next boot's startup reconciliation maps the orphaned rows to `:failed` (a `:cancelling` row becomes `:cancelled`).
- **`--force` cannot restart a foreground server.** When the instance was started with `genesis serve` (not as a service), a forced run swaps the files and deletes the old tree while that process keeps running from it, so the operator has to stop it (Ctrl-C in its terminal) and start the new tree by hand — which is exactly why the non-forced run refuses instead of pretending to restart it.
- **Windows is unsupported** for the headless server: no `genesis_server` Windows build is published (`scripts/install.sh` and `update_platform_key` both fail with the available-platform list), so there is nothing to update.
- **No apt/dnf channels.** Upgrades are the tarball-over-directory swap above; distro packages would be a separate channel (`auto-update.md` §3, Phase 3).
- **One shared manifest.** The server feed and the desktop feed are the same `latest.json` file: a change to the manifest schema has to keep both consumers working, and a server-only release still publishes the file.
- **No staged rollout or beta channel** for servers: `latest.json` is whatever `releases/latest` points at.

---

## 8. File references

- `rel/overlays/bin/genesis` — the whole implementation: the `Self-update (genesis update)` section (`release_version`, `version_normalize`, `version_gt`, `update_platform_key`, `update_manifest_urls`, `update_asset_urls`, `update_fetch`, `json_field`, `json_number`, `upd_manifest_sha`, `upd_verify_sha`, `upd_lock`, `upd_teardown`, `upd_check_active_tasks`, `upd_busy_check`, `upd_fetch_manifest`, `upd_fetch_asset`, `upd_read_sha_file`, `upd_print_json`, `upd_print_notes`, `parse_update_flags`, `cmd_update`), plus the reused lifecycle helpers (`service_active`, `do_stop`, `start_and_wait`, `effective_ip`/`effective_port`, `dashboard_url`, `probe_health`, `data_dir`, `state_save`).
- `rel/CONTEXT.md` — "Genesis Server CLI" (the CLI contract, including the self-update paragraph) and the design notes on why the CLI is the lifecycle/update component.
- `.github/workflows/build-desktop.yml` — the `publish-release` job: "Generate updater manifest (latest.json)" writes the `server` map and the `genesis_server_*.tar.xz.sha256` assets; "Append headless server download note to the release body" advertises `genesis update --check` / `genesis update`.
- `.github/workflows/CONTEXT.md` — release-publishing facts: the `latest.json` shape (both maps), the tarball/checksum asset names, and the external `/dl/` worker allowlist and ordering caveat.
- `apps/evo_dash/lib/evo_dash_web/controllers/server_status_controller.ex` — `GET /server/status`: the `active_tasks` count, the `-1` degradation and the version field the gate reads (mounted in `apps/evo_dash/lib/evo_dash_web/router.ex` next to `/health`).
- `scripts/install.sh` — the installer whose layout (`~/.local/share/genesis/server`, the `~/.local/bin/genesis` symlink, the `.old.<pid>` swap and the optional `<asset>.sha256` check) the updater mirrors.
- `scripts/test-genesis-cli.sh` — the CLI smoke test harness (stub launchers, shadowed service managers, temp release tree) whose `genesis update` section covers the update path end to end offline: a fake install tree swapped for real `.tar.xz` fixtures, one stub curl for the feed (primary and GitHub fallback), the asset, `/server/status` and `/health`, plus the help/flag contract, `--check`/`--json` exit codes, the busy gate and `--force`, the checksum and staged-version aborts before any stop, the staged swap, the health-failure rollback, the unsupported-platform failure, live-lock refusal with stale-lock recovery, and the pinned `--version` feed/asset URL shaping.
- `docs/auto-update.md` — the desktop updater design record; its §6 covers the headless/remote-node side (the shipped CLI updater plus the deferred dashboard-initiated flow).
