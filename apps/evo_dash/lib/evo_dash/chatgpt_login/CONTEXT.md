# ChatGPTLogin helpers — one Sign in with ChatGPT attempt

## Intent

This directory holds the internals of ONE Sign in with ChatGPT (SIWC) attempt, driven by the facade `EvoDash.ChatGPTLogin` (`../chatgpt_login.ex`).
`Flow` is one attempt per process: it mints the authorization URL, waits for the callback, exchanges the code and installs the registration, then stops.
An attempt is either `mode: :loopback` (it owns a `127.0.0.1` callback listener) or `mode: :manual` (no listener could be bound, or the browser is on another machine, so the user pastes the redirect URL back).
The pasted path always completes the SAME attempt: same PKCE verifier, same `state`, same install — the only difference is how the callback parameters arrive.

## API Surface

- `EvoDash.ChatGPTLogin.begin/2` returns `{:ok, %{id: id, url: url, port: port, mode: :loopback | :manual}}`; `port` is the port used in the redirect URI even in `:manual` mode (`1455` when the caller asked for an ephemeral port and nothing could bind).
- `EvoDash.ChatGPTLogin.submit_callback/2` acks a paste with `{:ok, %{id: id}}` or refuses it with `{:error, :unknown_flow | :already_finished | :invalid_callback | :no_code | :login_unavailable}`.
- `EvoDash.ChatGPTLogin.status/1` reports `:pending` or the one terminal result; the registered `:caller` receives `{:chatgpt_login, id, result}` exactly once.
- `Flow.info/1` reports `%{id, url, port, mode}` and stays answerable while an exchange runs.
- `Flow.submit/2` is the flow-side paste entry point (`{:ok, %{id: id}} | {:error, :already_finished | :invalid_callback | :no_code}`).
- `EvoDash.ChatGPTLogin.Paste.parse/1` answers `{:ok, params}` (string-keyed, only the present `code`/`state`/`error` keys), `{:error, :authorization_denied}` or `{:error, :no_code}`.

## Constraints

- A paste never starts a second attempt and never re-mints the PKCE verifier or `state`.
- A present `state` in a paste is compared constant-time (`same_state?/2`, the same compare the HTTP callback uses); a mismatch is `{:error, :invalid_callback}` and the attempt stays PENDING so the user can paste again.
- A bare code carries no state to check — it is bound to this attempt by the PKCE verifier — so the flow synthesizes the attempt's own `state` for the exchange call.
- An `error` parameter in a paste is a denial (it wins over a code, like the HTTP callback), acknowledged and then terminal with `{:error, :authorization_denied}`.
- The exchange plus the install run in one monitored task OFF the flow's call path, so `info/1` and a racing HTTP callback stay answerable; the task is bounded by its own timeout and killed on cancel, timeout and terminate.
- An in-flight exchange counts as terminal: further pastes answer `{:error, :already_finished}` and further callbacks get the already-finished page, so one attempt can never install twice.
- Every exit path (success, failure, denial, timeout, cancel, supersede, facade `DOWN`, a dead listener) tears the listener down and notifies the facade at most once.
- Only a store or authorization failure fails an attempt; a listener that cannot be bound degrades it to `:manual` instead.
- The success side effect is ONE call, `store.install(account, record)` (`flow.ex:279`), which writes only `<config_dir>/chatgpt/account-<account>.json` in the core store: no `config.toml`/`credentials.toml` write, no `EvoGit.Config.Watcher.notify_change/1`, no RAM-snapshot generation bump and no PubSub broadcast — a provider profile referencing the account (`siwc_account`) and every surface that displays it are refreshed by their own save/read paths, never by this flow.
- The post-install `store.status(account)` map (account label + the registration's cached `models`) reaches only the `:caller` message and `EvoDash.ChatGPTLogin.status/1` (retained `:retention_ms`), so a caller that needs the model list must consume that terminal result — nothing re-broadcasts it.

## Routing Table

- `./flow.ex` → `EvoDash.ChatGPTLogin.Flow`, the attempt GenServer (bind or degrade, authorization, callback, paste, exchange task, terminal reporting)
- `./paste.ex` → `EvoDash.ChatGPTLogin.Paste`, the total paste parser (redirect URL, `?`-query, bare query, bare code)
- `./callback.ex` → `EvoDash.ChatGPTLogin.Callback`, the loopback `GET /auth/callback` plug and its self-contained HTML pages
