# EvoGit.Auth.ChatGPT.Store — Protected SIWC Registrations

## Intent
Owns this execution node's Sign in with ChatGPT (SIWC) registrations as PROTECTED FILES beside the config — one JSON document per account alias under `<Platform.config_dir("genesis")>/chatgpt/` (e.g. `~/.config/genesis/chatgpt`).
A provider profile references an alias only (`siwc_account`), so no token ever enters `config.toml`/`credentials.toml`.
The network protocol lives in `../chatgpt.ex`; this module owns storage, locking, model caching and token refresh.

## API Surface (store.ex)
- `directory/0` → `<config_dir>/chatgpt`; `path/1` (alias, default `"default"`) → `{:ok, <dir>/account-<alias>.json}` | `{:error, :invalid_account_alias}`.
- `default_account/0` → `"default"`; `valid_account?/1` → `~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/` (format only — the alias is never required to EXIST by config validation).
- `host_id/0` → `{:ok, "urn:uuid:…"}` read from `<dir>/host-id`, created on first call under the write lock.
- `registration/1` → `{:ok, %{"client_id", "subject"}}` (the non-secret reference only).
- `status/1` → `{:ok, %{expires: ms_since_epoch, account_id: email || subject, models: [%{"slug", "display_name"}]}}` | `{:error, :no_credentials | :invalid_credentials | …}`; `models` is the CACHED list from the account file — `status/1` never touches the network.
- `accounts/0` → `%{alias => status}` for every `account-*.json` in the directory (`File.ls`), `%{}` when the directory is unreadable; accounts whose `status/1` fails are silently skipped.
- `token/2` (alias, model \\ nil) → `{:ok, access_token}`; a valid access token (> 60 s `@refresh_margin`) is returned from a lock-free read, otherwise the refresh runs inside the lock; a model absent from the cached list is `{:error, :model_not_available_for_chatgpt_account}`.
- `install/2` (alias, record) → `{:ok, models}`: locks, checks alias compatibility (`:chatgpt_account_alias_in_use`) and uniqueness (`:chatgpt_registration_already_installed`), ensures `host-id`, verifies/refreshes the session, fetches `ChatGPT.models/1` from the API, then writes `Map.put(record, "models", models)`.
- `import_file/2` (protected file import, ≤ 128 KB, mode `0700`-checked outside Windows) → delegated to `install/2`; `models/1` re-fetches and persists the list; `logout/1` remotely revokes then keeps only `client_id`/`subject`/`issuer`/`email`.

## Storage & Concurrency
Registrations are FILES, not SQLite rows: `account-<alias>.json` (mode `0600`, atomic temp-file + `File.rename`) plus `host-id`, directory mode `0700`.
`registrations.sqlite3` in the same directory is ONLY a cross-VM write lock (`Xqlite.begin(conn, :immediate)`, `busy_timeout: 20_000`); it holds no credentials and does not match the `account-*.json` scan.
Lock contention answers `{:error, :chatgpt_account_busy}`; any other lock/IO failure answers `{:error, :chatgpt_store_unwritable}`.
Plain reads (`status/1`, `accounts/0`, `registration/1`, an unexpired `token/2`) take NO lock and may race a writer — the atomic rename means they see either the previous or the new document, never a partial one.

## Freshness (no cache, no event)
There is NO cache of any kind — no ETS, no `:persistent_term`, no GenServer state, no module attribute: every call re-reads the directory/file, so a freshly installed registration is visible to any process on the SAME node immediately.
A remote dashboard reads it through an RPC (`EvoDash.NodeContext.call_remote/4` → `EvoGit.RemoteNode.call_remote/4`, a generic `apply/3`), so the execution node's own files are authoritative.
An install, logout or model refresh publishes NOTHING: no `"config"`/`"scheduler_config"` PubSub broadcast, no `EvoGit.Config.Watcher.notify_change/1`, no `EvoGit.Config.Cache.reload/1`, and no write to `config.toml`/`credentials.toml`.
The config snapshot fingerprint is `:erlang.phash2({config_bytes, credentials_bytes})` only (`config/config.ex` `build_snapshot/1`), so a chatgpt-directory change can NEVER make `{:config_reloaded, node, dir, generation}` fire.

## Model List for `:openai_codex`
The model inventory is ACCOUNT metadata, not a local catalog: `EvoGit.Config.LLMCatalog` declares `models: []` for the `:openai_codex` entry (auth_modes `[:oauth]`, `oauth_source: :chatgpt`).
`EvoGit.Auth.ChatGPT.models/1` fetches `GET https://api.openai.com/v1/models` and keeps only `%{"visibility" => "list"}` entries; the result is cached ONLY under the account file's `"models"` key and rewritten by `install/2` and `models/1`.
Dashboard/account surfaces therefore read the cached list through `accounts/0` (`EvoDashWeb.LLMSetup.ChatGPT.model_entries/2`), never through `LLMCatalog`/`llm_db`.

## Constraints
- The account JSON is the ONLY secret file (mode `0600`); never log token contents.
- Keep the lock database credential-free and the registration write atomic, so lock-free readers never see a partial document.
- Aliases are names, not paths — the JSON path is derived from a validated alias only.
