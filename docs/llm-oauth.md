# Subscription (OAuth) LLM Support

Use a ChatGPT/Codex or Claude Pro/Max subscription login instead of an API key.
Log in once with the vendor's CLI; Genesis runs **no OAuth flow of its own**.
Genesis imports the login into a managed file that the LLM client (`ReqLLM`) reads and, when refresh credentials are available, refreshes.

## 1. Log in with the vendor CLI

### ChatGPT / Codex

```bash
codex login
```

The CLI writes `~/.codex/auth.json`, or `$CODEX_HOME/auth.json` when `CODEX_HOME` is set.
Configure the account with `provider = "openai_codex"`.
This provider is **OAuth-only**: subscription authentication is detected automatically, and it cannot use an API key.

### Claude Pro/Max

Run `claude` and log in; its refreshable login is stored in `~/.claude/.credentials.json`.
Configure the account with `provider = "anthropic"` and `auth_mode = "oauth"`.

Alternatively, run `claude setup-token` and export the printed token:

```bash
export CLAUDE_CODE_OAUTH_TOKEN="<token>"
# Alternatively:
export ANTHROPIC_OAUTH_TOKEN="<token>"
```

Only when no managed Anthropic entry is available does Genesis fall back to `CLAUDE_CODE_OAUTH_TOKEN`, then `ANTHROPIC_OAUTH_TOKEN`.
Environment tokens are **never persisted and cannot be refreshed**; the token must be available to every Genesis process using it.
Re-run the vendor login when it expires or when changing accounts.

## 2. Configure provider profiles and model inventory

Accounts are `[[llm.providers]]` profiles: the account `id` and `provider` are separate from the **bare model IDs** in nested `[[llm.providers.models]]` entries.
The following IDs are **placeholders, not model recommendations**: replace them with models advertised by your provider/setup and available to your subscription plan.
An explicit nested model inventory is required for backend resolution; `default_model` alone does not register a model.
See [LLM provider profiles](llm-profiles.md) for full configuration and selection rules.

```toml
[llm]
default_provider_profile = "codex-subscription"

[[llm.providers]]
id = "codex-subscription"
provider = "openai_codex"
default_model = "REPLACE_WITH_CODEX_MODEL_ID"
concurrency = 2

[[llm.providers.models]]
model = "REPLACE_WITH_CODEX_MODEL_ID"

[[llm.providers]]
id = "claude-subscription"
provider = "anthropic"
auth_mode = "oauth"
default_model = "REPLACE_WITH_CLAUDE_MODEL_ID"
concurrency = 2
# Optional account-level override; blank/omitted uses <config_dir>/auth.json:
# oauth_file = "/absolute/writable/path/auth.json"

[[llm.providers.models]]
model = "REPLACE_WITH_CLAUDE_MODEL_ID"
```

Authentication, `oauth_file`, endpoint, concurrency and peak/off-peak scheduling belong to the **provider profile** and are shared by its models.
Nested model entries carry generation, context-window and reasoning-effort overrides.
OAuth does not change these settings or create separate capacity for each model/effort.

## 3. Where credentials live

The default managed file is `<config_dir>/auth.json`, next to `config.toml`:

| Platform | Default path |
|---|---|
| Linux | `~/.config/genesis/auth.json` (`$XDG_CONFIG_HOME/genesis/auth.json`) |
| macOS | `~/Library/Application Support/genesis/auth.json` |
| Windows | `%APPDATA%\genesis\auth.json` |

A provider profile's `oauth_file` overrides this path; there is **no global `[llm] oauth_file`** key.
Leave the override blank to use the managed default, or choose a writable private path.

Import is lazy (when assembling a request), key-wise and atomic.
Importing Anthropic leaves the Codex entry untouched, and vice versa.
Genesis imports when the managed entry is missing or the vendor file is newer than the managed file; this mtime guard avoids overwriting ReqLLM's newer token rotations.
A new managed file gets mode `0600`; an existing file keeps its mode.
Missing, unreadable or broken credentials produce diagnostic health messages rather than crashing a run.

The managed file holds **one entry per provider** (`openai-codex`, `anthropic`), not one per profile ID.
Distinct account IDs do not isolate OAuth credentials.
A separate `oauth_file` changes the managed destination, but does **not** automatically provide a multi-account vendor-login workflow.
Treat these files as private secrets; do not share them with a team or hand-edit their client-specific format.

## 4. Setup and dashboard

### CLI wizard

```bash
genesis setup
# From a source checkout:
mix run -e 'EvoGit.CLI.main(System.argv())' -- setup
```

The wizard writes canonical provider profiles and nested model inventory.
For Anthropic it offers **API key** or **Subscription (OAuth)**; OAuth writes `auth_mode = "oauth"` without storing an API key in `credentials.toml`.
For OAuth-only `openai_codex`, there is no API-key choice.
It checks for the vendor login, prints login guidance when needed, and can save the OAuth profile before login is available.
The CLI wizard does not prompt for reasoning effort.

### Dashboard

**Settings → LLM → Provider profiles** edits account authentication, the optional `oauth_file` path and model inventory on the node you are viewing.
Choose **Subscription (OAuth)** for Anthropic; Codex shows a static **Subscription** badge rather than an auth toggle.
Login status includes vendor login guidance and the managed path; manual refresh re-checks it.
Status is resolved on the viewed node (remote via RPC), and becomes unknown if that node cannot be reached.

Quick Setup and Welcome show OAuth login guidance instead of requesting an API key for subscription authentication.
Welcome is local-only and supports multiple models, a default model and a per-model default-effort dropdown.
Its blank **Provider default** effort choice leaves the override unset.

## 5. Troubleshooting

| Symptom | Meaning / remedy |
|---|---|
| No usable subscription login found | Run `codex login` or `claude` on the node using the account, then retry setup or the run. |
| `OAuth file not found: <path>` | Check the provider profile's `oauth_file` and vendor login; Genesis must be able to import into the resolved managed path. |
| Login found, but managed credential file not writable (for example `:erofs`) | The vendor login is fine; point the provider profile's `oauth_file` at a writable private location. Logging in again does not fix a read-only destination. |
| `401` / expired credentials | Refresh is automatic when a refresh token exists; if it fails, repeat the vendor login. Environment-only tokens must be replaced manually. |
| `403`, not entitled, unsupported plan or quota error | Check plan access and the selected model. Anthropic can use `auth_mode = "api_key"` with an API key; Codex cannot. For API billing instead of Codex OAuth, configure a different API provider profile. |
| No API key found despite a Claude login | Set `provider = "anthropic"` and `auth_mode = "oauth"` on that provider profile, then reload configuration. For Codex, set `provider = "openai_codex"`; do not encode the provider in the nested model ID. |
| Model cannot be resolved | Add its bare ID to `[[llm.providers.models]]` under the intended account; `default_model` alone is insufficient. Use a provider-advertised model available to your plan. |
| Dashboard cost is zero or looks like token-only billing | Subscription usage is metered by the vendor; Genesis cost figures remain best-effort estimates, not your subscription bill. |

Tokens are never logged; diagnostics include only provider, reason and path.
Managed writes are atomic, with `0600` for new files and existing permissions preserved for existing files—check those permissions yourself.
Environment-provided OAuth tokens are never persisted.
