# LLM subscriptions

Genesis supports OpenAI API keys and ChatGPT subscriptions as separate OpenAI provider profiles. Choose **OpenAI** for an API key or **ChatGPT Subscription** to use the eligible models and usage of your ChatGPT plan.

## ChatGPT Subscription

In **Welcome** or **Settings → LLM → Provider accounts**, choose **ChatGPT Subscription** and select **Sign in with ChatGPT** on the account you are creating or editing (the wizard auth step, an expanded account, and an account's auth row all offer it). Genesis starts a loopback listener on the execution host, shows an authorization link that opens in a new browser tab, and waits for you to grant permission. When the tab reports success the account turns connected: pick your registration, select from its available models, and finish.
The waiting panel can be cancelled; closing the panel, the wizard or the settings window cancels it too, and an attempt expires after ten minutes.

The redirect goes to `http://127.0.0.1:<port>/auth/callback` on the execution host, so a browser on another machine lands on its own loopback and reports a connection error. The grant has still been made, and the failed tab's address bar holds the full redirected URL. Paste that URL, or just the authorization `code`, into the waiting panel's **Can't reach this page?** disclosure — into the field with the placeholder **Paste the full redirect address or the code** — and press **Submit pasted link** to complete the sign-in exactly as the loopback callback would. `state` is validated; a wrong or foreign value leaves the attempt pending so it can be retried. The same field works for a purely local setup and when no loopback listener could be opened.

The same sign-in is available from the command line, which prints the URL to open and can list the models for an account:

```sh
genesis chatgpt login
genesis chatgpt status
genesis chatgpt models
```

While it waits for the result, `genesis chatgpt login` invites you to paste the redirected address (or the code) and press Enter, so the same manual route works there. With no interactive stdin it prints the URL and waits as before. From a source checkout, run `mix genesis.chatgpt login`. A release without the `genesis` CLI can run its launcher with `eval 'EvoDash.ChatGPTCLI.main(System.argv())' login`.

In Settings, save the account before running **Connection Test**. In Welcome, test the selected model before finishing setup. Both the dashboard button and the CLI drive the same loopback flow and the same credential store, so either can be used for reauthorization.

The dashboard button signs in on the node the dashboard is connected to, and it binds a loopback address on that host — so it is offered only in a local node context. When the dashboard runs on the remote host itself, the in-browser sign-in is still the better route, because the waiting panel accepts the pasted redirect your own browser cannot deliver. When the page views another node, run the CLI there (then either forward the port or paste the redirected address, see below) and press **Check connection**.

```toml
[[llm.providers]]
id = "chatgpt-subscription"
provider = "openai_codex"
auth_mode = "oauth"
siwc_account = "default"
default_model = "MODEL_ID_FROM_GENESIS_CHATGPT_MODELS"
models = ["MODEL_ID_FROM_GENESIS_CHATGPT_MODELS"]
```

The provider identifier `openai_codex` is retained so existing profiles and task references can be loaded. On upgrade, sign in through Genesis and select an available model if the previously configured model is missing. Credentials imported from Codex in older versions are not used by this connection. The subscription uses [OpenAI's public Responses endpoint](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).
Every inference request also identifies the calling app, which is what lets ChatGPT's Settings → Usage page attribute the traffic instead of bucketing it as surface "unknown": the `originator` header carries the same stable app name Genesis sends as its registration `agent_name_hint`, and `User-Agent` carries `<app name>/<version>`; `EvoGit.Auth.ChatGPT.agent_name/0` is the single source for both.
The Codex `backend-api` headers (`chatgpt-account-id`, `openai-beta`) stay omitted, because this flow targets the public Responses endpoint rather than `chatgpt.com/backend-api`.

For a separate account or workspace, use `genesis chatgpt login --account work` and set `siwc_account = "work"` on its provider profile. Run `genesis chatgpt logout --account work` to disconnect it. The default alias is `default`. The pasted-address route works the same way for a named account.

### Self-hosted Genesis

The sign-in redirects to a loopback address on the execution host, so a browser running elsewhere must hand the result back to Genesis. Two options:

**Option A — SSH port forwarding.** Forward the same port on both sides, then start login under the account and configuration directory that run Genesis:

```sh
ssh -t -L 1455:127.0.0.1:1455 user@genesis-host 'genesis chatgpt login'
```

Open the displayed URL on the computer running SSH. You can select another port with `--port` if both ends use the same number. Use the normal dashboard address for setup.

**Option B — paste the redirected address.** No forwarding is needed. Approve in the browser on your own machine; the tab then fails to reach `http://127.0.0.1:<port>/auth/callback`, which is expected. Copy that address from the tab's address bar and paste it into the field under the dashboard waiting panel's **Can't reach this page?** disclosure (placeholder **Paste the full redirect address or the code**) and press **Submit pasted link**, or at the `genesis chatgpt login` prompt, or pass just the `code`. `state` is validated and a wrong or foreign value leaves the attempt pending, so you can retry. This is the option for hosts without forwarding, containers, jump hosts, and tunnels. A bare code is accepted because the authorization code is bound to the flow's PKCE verifier, which never leaves the Genesis host.

If the login command reports that no local listener could be bound, only the pasted address or code can complete the attempt.

If the execution host requires an HTTP CONNECT proxy, set `GENESIS_SIWC_HTTPS_PROXY=http://HOST:PORT` for both the Genesis service and the login command. Authorization, model discovery, and subscription inference use that proxy.

As an offline alternative, for a protected credential transfer, complete Genesis login on the browser machine and transfer the selected file from `<config_dir>/chatgpt/account-<alias>.json` using SSH. Keep the staging file private, then run `genesis chatgpt import /path/to/file --account <alias>` on the destination. The destination keeps its own host ID and takes over refresh. Clear the staging copy when the import finishes and use the transferred session only on the destination. [OpenAI self-hosted VM guide](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)

## Claude Pro/Max

Run `claude` and sign in. Configure a provider profile with `provider = "anthropic"` and `auth_mode = "oauth"`. Genesis lazily imports the login from `~/.claude/.credentials.json` into the ReqLLM-managed `<config_dir>/auth.json`. Set `oauth_file` on the provider profile if you need a different managed path. Keep it writable and private. Genesis imports when the managed entry is missing or the CLI login file is newer, which preserves newer tokens rotated by ReqLLM.

If there is no usable managed entry, Genesis also supports the result of `claude setup-token` through `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_OAUTH_TOKEN`. These environment tokens are used without persistence or refresh.

See [LLM provider profiles](llm-profiles.md) for configuration and selection rules.
