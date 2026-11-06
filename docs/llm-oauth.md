# Subscription (OAuth) LLM Support
**Applies to:** the `:evo_git` runtime and the `genesis setup` wizard — using a ChatGPT/Codex or a Claude Pro/Max **subscription login** instead of a pay-per-token API key.
**In short:** you log in once with the vendor's own CLI, and Genesis reuses that login; Genesis runs **no OAuth flow of its own**.

---
## 1. What this is
Genesis normally authenticates an LLM with an API key (`credentials.toml`) and is billed per token.
With OAuth you can instead point a model profile at a subscription you already pay for:

- **ChatGPT / Codex** subscription → provider `openai_codex`
- **Claude Pro / Max** subscription → provider `anthropic` with `auth_mode = "oauth"`

Genesis deliberately implements **no device flow, no browser callback and no token exchange of its own**.
The vendor CLI writes a login file; Genesis imports it into one managed file; the LLM client (`ReqLLM`) reads that file, refreshes expired tokens, and rotates the refreshed tokens back into it.
Nothing about the agent runtime changes — same tools, same scheduler, same dashboard.

---
## 2. Log in once (per provider)
Both steps are one-time. Re-run them only when a login expires or you switch accounts.

### 2.1 ChatGPT / Codex
```bash
codex login
```
This writes `~/.codex/auth.json` (or `$CODEX_HOME/auth.json` when `CODEX_HOME` is set).
Then select a Codex model with the `openai_codex:` prefix:

```toml
model = "openai_codex:gpt-5.6-terra"
```

`openai_codex` is **OAuth-only**: it never accepts an API key, and it needs no `auth_mode` key — the provider prefix alone selects the subscription login.

Current Codex models:

| Model id | Display name |
|---|---|
| `gpt-6.1-sol` | GPT-6.1 Sol |
| `gpt-6-astra` | GPT-6 Astra |
| `gpt-6.1-terra` | GPT-6.1 Terra |
| `gpt-6-sol` | GPT-6 Sol |
| `gpt-6-luna` | GPT-6 Luna |
| `gpt-5.6-sol` | GPT-5.6 Sol |
| `gpt-5.6-terra` | GPT-5.6 Terra |
| `gpt-5.6-luna` | GPT-5.6 Luna |

An explicit `openai_codex:<model>` string works for any model the endpoint serves, listed or not.

### 2.2 Anthropic (Claude Pro/Max)
Two equivalent ways to get a credential:

1. **Login file (recommended — refreshable)**
   ```bash
   claude
   ```
   Log in once; the CLI writes `~/.claude/.credentials.json`. Genesis imports it.
2. **Token without a login file (no refresh)**
   ```bash
   claude setup-token
   ```
   Export the printed token:
   ```bash
   export CLAUDE_CODE_OAUTH_TOKEN="<token>"
   # alias also accepted:
   export ANTHROPIC_OAUTH_TOKEN="<token>"
   ```
   An env token is used directly and **never written to disk**; it also cannot be refreshed, so it must be present in the environment of every Genesis process that uses the profile.

Then use the normal Anthropic model string, with the auth mode set to OAuth:

```toml
model = "anthropic:claude-opus-5-5"
auth_mode = "oauth"
```

Current Claude models include `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-5`, `claude-sonnet-5` and `claude-fable-5-1`.

---
## 3. Where credentials live
Genesis imports the vendor login into **one managed file, `auth.json`**, next to your `config.toml`:

| Platform | Default path |
|---|---|
| Linux | `~/.config/genesis/auth.json` (`$XDG_CONFIG_HOME/genesis/auth.json`) |
| macOS | `~/Library/Application Support/genesis/auth.json` |
| Windows | `%APPDATA%\genesis\auth.json` |

Resolution order for that path (highest first):

1. the profile's own `oauth_file`
2. the managed default above, `<config_dir>/auth.json` (`EvoGit.Auth.default_oauth_file/0`)

There is no global `[llm] oauth_file` key — the override lives on the model profile only.

The file is written atomically (a newly created file gets mode `0600`; an existing file keeps its mode) and holds one entry per provider (`openai-codex`, `anthropic`) in the LLM client's own format — do not hand-edit it unless you know that format; let `codex login` / `claude` fill it.

How the import behaves:

- **Lazy** — it happens when a profile is first assembled for a request, not at install time.
- **Key-wise** — importing `anthropic` never touches an existing `openai-codex` entry, and vice versa.
- **Never clobbers a refresh** — the import runs only when the managed file has no entry for that provider, or when the vendor file is *newer* than the managed file. Since the LLM client rewrites rotated tokens into the managed file, a fresh managed entry always wins.
- **Fault-isolated** — a missing, unreadable or broken vendor/managed file degrades to a clear message (config health names the login step and the managed path); it never crashes a run.

---
## 4. Configure model profiles
Both flows are ordinary `[[llm.models]]` profiles; only the model string and (for Anthropic) the auth mode differ.

**Codex subscription**

```toml
[[llm.models]]
id = "codex"
model = "openai_codex:gpt-5.6-terra"
concurrency = 2
```

**Claude Pro/Max subscription**

```toml
[[llm.models]]
id = "claude"
model = "anthropic:claude-opus-5-5"
auth_mode = "oauth"
concurrency = 2
# optional: use a different managed OAuth file for this profile only
# oauth_file = "~/.config/genesis/auth.json"
```

Notes:

- `auth_mode` accepts `"oauth"` (or `"api_key"`, the default). It is needed only for providers that also accept API keys — Claude is the one case today.
- `oauth_file` is a **per-profile override only** — leave it blank to use the managed default `<config_dir>/auth.json`; set it on the profile to use a different managed file for that profile alone (for example a path under a writable home, or a team-shared credential file).
- The same profile table carries everything else a normal profile does: `concurrency`, `context_window` (the context-compression window, default 200 000), the generation parameters (`temperature`, `max_tokens`, `reasoning_effort`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`), `provider_options`, and the peak/off-peak scheduling fields (`peak_concurrency`, `peak_hours`, `off_peak_days`, `timezone`). OAuth has no effect on any of them.
- On a config that still uses the flat `[llm] model = "…"` form, `[llm] auth_mode = "oauth"` is carried into the auto-created `default` profile, so the legacy form works too.
- In the dashboard, the path is set **per model profile** in the model-profile editor: an `oauth_file` field whose placeholder is the default managed path and where blank means the managed default. The global LLM settings category has no `oauth_file` field. The same editor carries an `auth_mode` toggle — **API key** vs **Subscription (OAuth)** — so neither the mode nor the path needs hand-editing of `config.toml`. The OAuth-only `openai_codex` provider shows a static **Subscription** badge instead of the toggle and is never asked for an API key.

---
## 5. Setup paths
### CLI wizard
```bash
genesis setup
# from a source checkout:
mix run -e 'EvoGit.CLI.main(System.argv())' -- setup
```
For an OAuth-capable provider the wizard offers **"API key"** vs **"Subscription (OAuth)"**:

- *API key* — unchanged behaviour: paste a key, it is saved to `credentials.toml`.
- *Subscription (OAuth)* — no API key is requested and nothing is written to `credentials.toml`.
  The wizard looks for an existing vendor login, prints the one-time login command when none is found (and asks whether to save the OAuth profile anyway), and writes `auth_mode = "oauth"` onto the profile.
  For `openai_codex` (OAuth-only) the step only announces the subscription — there is no key option to offer.

### Dashboard
The dashboard's Settings → LLM page and the per-profile editor edit the same `config.toml`.
A Codex profile needs only the provider `openai_codex` and a model id; a Claude subscription profile additionally needs `auth_mode = "oauth"` — choose **Subscription (OAuth)** in the profile's auth-mode toggle rather than editing the file (see §4).
Next to that toggle the page reports whether a login is actually available — "Login detected (expires …)" or "No subscription login found", together with the one-time `codex login` / `claude` guidance and the managed credential file path — and a manual refresh re-checks it on demand.
The status is resolved on the machine that owns the config, so a remote node is queried over RPC and the line degrades to "unknown" when it cannot be reached.
Quick Setup swaps its API-key form for the same login guidance on an OAuth-capable provider.

---
## 6. Model catalog refresh
The shortcut lists shown by `genesis setup` and by the dashboard's model picker were refreshed to the current model generations.
Retired from the shortcuts (they are no longer offered): `gpt-5.4`, `gpt-5.5`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-sonnet-4-6`, `glm-5`, `gemini-3.1-pro-preview`, `kimi-k2.7`.

Only the *shortcut list* changed. An explicit `provider:model` string keeps working for any model the endpoint still serves, so an existing `config.toml` is not invalidated by the refresh.

---
## 7. Troubleshooting

| Symptom | What it means | Fix |
|---|---|---|
| Setup says "No local Codex CLI / Claude Code login found", or config health warns that no usable subscription credential resolves | The vendor login file is absent or holds no usable token | Run `codex login` (or `claude`), then re-run `genesis setup` or restart the run |
| Provider error `OAuth file not found: <path>` | The managed file is missing at the path the profile resolved (often a wrong per-profile `oauth_file`) | Create it by logging in again; if the profile sets `oauth_file`, check that path |
| Warning log `OAuth import for openai_codex could not write the managed file <path> ({:temp_file_failed, :erofs})`, the dashboard says "Login found, managed credential file not writable", `genesis setup` prints that remedy instead of the one-time login steps, and requests then fail with `OAuth file not found: <path>` | The vendor login was found — the login itself is fine — but Genesis could not store its managed copy, e.g. a read-only `$HOME` or a sandboxed/container filesystem, so no `auth.json` exists for the LLM client to read | Point the profile's `oauth_file` at a writable location, e.g. `oauth_file = "~/.config/genesis/auth.json"` under a writable home; logging in again does not help |
| `401` / "expired credentials" mid-run | The access token expired and the refresh did not complete | Refresh is automatic when a refresh token exists (the LLM client rotates it back into the managed file); when it fails, re-run the vendor login |
| `403`, "not entitled", "unsupported plan", or quota errors from the provider | These endpoints are the vendor's subscription backends and require the matching plan | Use a ChatGPT Plus/Pro (Codex) or Claude Pro/Max subscription, or switch the profile back to an API key |
| Config health warns "No API key found…" even though you logged in with Claude | That Anthropic profile has no `auth_mode`, so it is treated as an API-key profile | Add `auth_mode = "oauth"` to that profile (and check the model string — Codex models need the `openai_codex:` prefix) and reload the config |
| Task/dashboard cost looks wrong (zero, or a token-only figure) | Subscription usage is metered by the vendor, not billed per token here | Treat the reported cost as best-effort — **token counts are accurate**, prices for these endpoints are not; the dashboard shows its usual "cost is best-effort" notice |

Security notes: tokens are never logged (log lines carry only provider, reason and path), the managed file is written atomically with mode `0600`, and an env-provided `CLAUDE_CODE_OAUTH_TOKEN` is never persisted.
