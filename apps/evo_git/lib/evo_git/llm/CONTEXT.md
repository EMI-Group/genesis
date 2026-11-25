# EvoGit LLM Adapters — `lib/evo_git/llm/`

## Intent

Holds the ReqLLM providers Genesis registers itself, replacing the vendored ones for a given provider id.
`EvoGit.LLM.ChatGPTResponses` serves ChatGPT-subscription (SIWC, provider id `:openai_codex`) traffic against the public OpenAI Responses endpoint; it is registered by `EvoGit.Application` via `ReqLLM.Providers.register!/1`, so it — not the vendored `ReqLLM.Providers.OpenAICodex` — builds every codex request.

## API Surface

| Module | Role |
|---|---|
| `EvoGit.LLM.ChatGPTResponses` | `:openai_codex` streaming provider: `attach_stream/4` resolves the registration token through `EvoGit.Auth.ChatGPT.Store`, `build_request/4` builds the `Finch` request, `decode_stream_event/2,3` / `flush_stream_state/2` delegate to `ResponsesAPI` and add a terminal error for a truncated stream. |

## Wire Contract (one request per agent turn)

`attach_stream/4` reads `provider_options[:siwc_account]` (else `Store.default_account/0`) and resolves that registration's token on the execution node.
`build_request/4` renames `:system` roles to `:developer`, forces `stream: true`, and drops the unsupported Responses fields plus `:responses_transport`.
The body carries EXACTLY one identity field: `prompt_cache_key`, set from `provider_options[:prompt_cache_key]` with `provider_options[:session_id]` as its fallback alias.
The SAME identity is sent as the `session-id` request header, which falls back to the resolved cache key when only `prompt_cache_key` is present, so body and header always agree for one agent run.
`thread-id` and `x-client-request-id` are emitted ONLY when `provider_options[:thread_id]` is supplied; Genesis never invents a request or thread id.
The request carries the SIWC usage-attribution headers `originator: <app name>` and `user-agent: <app name>/<version>`.
The app name has ONE source, `EvoGit.Auth.ChatGPT.agent_name/0`, which is also the `agent_name_hint` sent at registration, so hint and header cannot drift.
They ride every inference request because ChatGPT's plan usage surface buckets a request without them as the surface `unknown`.
The only other headers are `authorization: Bearer <token>`, `content-type: application/json` and `accept: text/event-stream`.
The Codex `backend-api` headers (`chatgpt-account-id`, `openai-beta`) are omitted on purpose: the SIWC plan flow uses the public Responses endpoint, and OpenAI's token-sharing docs forbid pointing that flow at `backend-api`.
The vendored `ReqLLM.Providers.OpenAICodex` sends them only because it targets `chatgpt.com/backend-api/codex/responses`.
Do not add those `backend-api` headers as a cache-affinity or "Codex parity" tweak; prompt-cache routing on this endpoint is the body `prompt_cache_key`.
`originator` is not one of them: it is the documented attribution header, never a cache or parity signal.
The `provider_options` handed to `ResponsesAPI.build_request_body/5` is rebuilt to `[store: false, prompt_cache_key: cache_key]`, so Genesis-only keys (`siwc_account` above all) never reach the OpenAI body builder.
Everything identity-related is resolved from the ORIGINAL call options BEFORE that rebuild, because the original list is what the headers read.
Genesis tool schemas are wrapped into one `namespace` tool named `genesis`; only `namespace`, `web_search` and `web_search_preview` tools are accepted and any other tool type is an invalid-parameter error.
Auth/token error mapping, model mapping (`provider` rewritten to `:openai`), tool adaptation and stream decoding stay as implemented; this module adds no new provider options beyond `siwc_account`, `prompt_cache_key` and `session_id`.

## Constraints

- `./deps/` is vendored and read-only: read `ReqLLM.Providers.OpenAICodex` / `ResponsesAPI` for reference, never edit them.
- The module is a thin adapter around `ResponsesAPI`; keep it cohesive and do not add a second module for header assembly.
- No hardcoded model, account id or invented request id — identity comes from the caller's `provider_options`.
