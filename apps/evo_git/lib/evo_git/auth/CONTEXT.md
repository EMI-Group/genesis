# OAuth Credential Import

## Intent
`EvoGit.Auth.OAuthImport` (`./oauth_import.ex`) imports a vendor CLI's existing OAuth login into the managed Genesis OAuth file that `EvoGit.Auth` (`../auth.ex`) owns and that ReqLLM reads and rotates.
Genesis deliberately runs NO OAuth device flow: the user logs in once with `codex login` / `claude`, and Genesis reuses that vendor file.
The module is pure file I/O — no network, no subprocess, no GenServer — and it never logs token contents.

## API Surface
- `sources/2` (provider, opts) → candidate vendor login paths, highest priority first (`[]` for a provider with no OAuth source).
- `import/2` (provider, opts) → `:imported | {:skipped, reason} | {:error, reason}`; never raises.
- `parse_codex_auth/1` / `parse_claude_credentials/1` → `{:ok, entry} | :error | {:error, reason}`; each accepts a decoded map OR the raw JSON string.
- `parse_env_token/1` (provider) → `{:ok, %{"type" => "oauth", "access" => token}} | :error`.
- `env_token/1` (provider) → the provider's env OAuth token or `nil`; values are read at CALL time and blanks are ignored.
- `jwt_claim/2` / `jwt_expires_at/1` → padding-tolerant base64url payload decode; malformed input → `nil`, never raises.
- `entry_field/2` / `non_empty_string/1` (both `@doc false`) → first-present-key lookup and trim-to-nil helpers shared with `EvoGit.Auth`.

## Managed File (target)
`EvoGit.Auth.oauth_file/1` decides the path; the document is ReqLLM-native JSON keyed by OAuth provider id.
Shape: `{"openai-codex": {"type": "oauth", "access": "…", "refresh": "…", "expires": 1800000000000, "accountId": "…"}, "anthropic": {…}}` — `expires` is MILLISECONDS since the Unix epoch.
`type: "oauth"` plus `access` are the minimum; nil fields are dropped from the written entry.
Entries for OTHER providers are preserved — the document is merged key-wise, never replaced.

## Source Files
- `:openai_codex` — `$CODEX_HOME/auth.json` when `CODEX_HOME` is set, else `<home>/.codex/auth.json`, written by `codex login`; accepted shape `{"auth_mode": "chatgpt", "tokens": {"access_token", "refresh_token", "account_id"}}`.
- `:anthropic` — `<home>/.claude/.credentials.json`, written by `claude`; accepted shape `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt"}}` (`expiresAt` is taken as-is).
- The Codex `auth_mode` is optional (older CLIs omit it) because a blank value is accepted, while an explicit API-key mode is `:error` (`auth_mode_not_chatgpt`).
- A missing/blank access token is `{:skipped, :no_usable_tokens}` from `import/2` (`{:error, :no_access_token}` from the parsers).

## Freshness Rule (never clobber ReqLLM's rotation)
ReqLLM refreshes expired credentials and persists the rotated tokens into the managed file, so an import happens ONLY when the managed file has no entry for the provider OR the source file's mtime is NEWER than the managed file's mtime (whole-second posix mtimes).
Otherwise the import is `{:skipped, :entry_exists_and_fresh}`; a managed file touched into the future is never re-imported over.
Order of work: read the managed document (`:enoent` → `%{}`) → skip check → read and parse the source → merge → atomic write.
Every failure is a tuple (`{:error, {:source_unreadable | :source_invalid | :managed_file_unreadable | :invalid_managed_file, reason}}`), never a raise.

## Writes / Permissions
Writes are atomic: a uniquely-named temp file in the SAME directory opened `[:exclusive]`, `File.chmod/2`, then `File.rename/2`.
A NEW file gets mode `0o600`; an EXISTING file keeps its current mode.
The managed file is the ONLY credential store this module touches — an import never writes `credentials.toml`.

## Environment Fallback (OAuth without refresh)
`:anthropic` consults `CLAUDE_CODE_OAUTH_TOKEN` then `ANTHROPIC_OAUTH_TOKEN` (`claude setup-token` emits the first); `:openai_codex` has NO env fallback.
An env token is OAuth-without-refresh — ReqLLM uses it directly and cannot rotate it — and it is NEVER written to the managed file.

## Test Seams
All seams are default-inert and read at CALL time: `opts[:home]` (user home), `opts[:codex_home]` (an explicit `nil` bypasses `$CODEX_HOME`), `opts[:oauth_file]` (managed file), and the app env `:auth_home_fun` (0-arity fun, falling back to `System.user_home/0`).
Tests are hermetic through those options (temp home + temp managed file); only the env-token coverage mutates real process env and is therefore `async: false` (`test/evo_git/auth/env_token_test.exs`).

## Constraints
- Keep this module pure file I/O: no HTTP, no `System.cmd`, no provider SDK, and no token logging (a log line carries only provider, reason and path).
- `EvoGit.Auth` (`../auth.ex`) owns path resolution, usability judgement, status reporting and login text; this module only locates, parses and merges.
- Do NOT add a re-import that ignores mtime: overwriting a fresher managed entry undoes ReqLLM's token rotation.
