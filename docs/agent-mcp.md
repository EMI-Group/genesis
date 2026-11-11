# Connect Genesis to a Coding Agent

Genesis is a development engine accessed through MCP. A calling agent supplies a self-contained objective, follows background work and inspects the returned changes. The same tools and collaboration workflow apply across compatible hosts. Installation, model setup, task tracking and results can stay in the calling agent; the Genesis GUI is optional.

Build and start this revision using [Run from source](../README.md#run-from-source). A development server listens at `http://127.0.0.1:4100`; a `genesis_server` release defaults to port 9999. Use the actual port of the instance you started. Configure its models using [LLM provider profiles](llm-profiles.md) and, when applicable, [OAuth authentication](llm-oauth.md).

The endpoint is part of the existing Phoenix server. It does not start a second listener or require a separate task daemon. A release must include these MCP changes; an older installed release will not acquire them from this source checkout.

## Connection contract

The host must support local Streamable HTTP MCP and a persistent bearer credential. Genesis and the writable project directory currently live on the same machine. The MCP endpoint is local-only; this connector does not make a remote project available to a cloud agent.

| Setting | Value |
| --- | --- |
| Transport | Streamable HTTP MCP |
| Endpoint | `http://127.0.0.1:9999/mcp`, or the running instance's actual local address |
| Authentication | `Authorization: Bearer <token>` |
| Credential source | `mcp-token` in the configuration directory used by the running Genesis instance |
| Credential storage | Private token file and the host's supported persistent secret/header configuration |
| Initialization | Discover the tools from the running server; the host's MCP client handles protocol initialization |

Create the credential before connecting if it is absent: generate at least 32 random URL-safe characters in that instance's `mcp-token` file, with mode `0600` on POSIX, and preserve an existing valid token. Do this locally without printing the value into chat or committing it. The MCP endpoint is disabled until a valid token exists. For example, on a POSIX source installation, run this from the checkout using the same environment as the server:

```sh
(umask 077; mix run --no-start -e '
  path = Path.join(EvoGit.Config.config_dir(), "mcp-token")
  File.mkdir_p!(Path.dirname(path))
  case File.open(path, [:write, :exclusive]) do
    {:ok, file} ->
      IO.binwrite(file, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))
      File.close(file)
      File.chmod!(path, 0o600)
    {:error, :eexist} -> :ok
    {:error, reason} -> raise File.Error, reason: reason, action: "create", path: path
  end
  IO.puts("MCP credential file: " <> path)
')
```

The command loads configuration without starting another runtime. It prints only the file path and preserves an existing credential. On Windows, create the same file in the instance's platform configuration directory with access restricted to your user. The token is read for each request, so creating it does not require restarting the server.

Register the endpoint and authorization using the host's documented configuration format. MCP does not standardize where a host stores its configuration or how it expands environment variables; do not assume a Codex manifest, `mcpServers` wrapper or placeholder syntax is accepted everywhere. Reload the host connection, discover the nine tools, and call `genesis_check`. This is the point where a small host adapter differs; it does not need another copy of the complete Genesis tutorial.

## Delegate from a calling agent

Supply a self-contained objective: the relevant background, absolute project path, intended behavior, constraints and acceptance checks. Genesis uses its own configured models; it does not inherit the caller's conversation or model. Keep the returned task ID, report meaningful progress changes, and inspect the resulting commits and test evidence before presenting the work as verified.

## Verify the connection

Discover `genesis_check`, `genesis_start_task`, `genesis_get_task`, `genesis_list_tasks`, `genesis_cancel_task`, `genesis_list_models`, `genesis_get_result`, `genesis_send_message` and `genesis_reload_config`. Confirm that a fresh host session can call `genesis_check` with the persisted credential. Model readiness is a separate configuration result, not proof of provider connectivity. For missing provider/model or authentication, use the provider profile and OAuth guides above together with `genesis_check.config_files` and `genesis_reload_config`. Test task submission only for a user-authorized development objective.

## Tasks and results

- **Start:** `genesis_start_task` takes an absolute `path` and `objective`. `evolve`/`simple` develops an existing project; `genesis`/`new` builds a new one. `genesis`/`existing` is also available. Optional `model_id` selects a configured profile.
- **Track:** retain the returned ID and query `genesis_get_task`. `running`, `cancelling` and `finalizing` are not completion. The backend owns task execution independently of HTTP requests.
- **Reconnect:** `genesis_list_tasks` can filter by project and page through recent tasks. Inspect existing tasks after an uncertain submission before submitting again.
- **Continue:** use an `evolve` task with `resume_from` identifying a finished task in the same project. It starts a new task using the prior result context; it does not revive a process.
- **Stop:** `genesis_cancel_task` requests graceful cancellation. It does not undo Git changes.
- **Inspect:** task details include status, error, saved result and available commit/branch fields. The result envelope preserves the backend's `__result_tag__` (`ok`, `error`, `exit` or `string`). It does not establish independent test verification; The calling agent should inspect evidence and run relevant checks.

This connector adds no snapshot of uncommitted files, automatic application to the user's working tree, new task queue or undo mechanism. Existing project configuration, including any configured foreign repositories, still applies. A new non-Git directory is initialized by the existing runtime. An existing repository needs an initial commit. Linked worktree and submodule roots are rejected by this entry point because the current runtime expects a primary checkout with a `.git` directory. The readiness check reports these conditions without modifying files.


## Following long tasks

Genesis exposes nine tools. `genesis_list_models` lists sanitized configured profile IDs, `genesis_get_result` reads finished task reports, and `genesis_send_message` queues instructions for a running task's root or an explicitly selected live agent. `genesis_reload_config` validates and applies local file edits through the existing scheduler reload, then returns configuration readiness. It accepts no credentials or file contents; existing agents retain their settings.

The caller reports progress and results through MCP. Tool results also include optional browser links: `links.task` opens the existing task Review page and `links.agents` opens the general Agent inspector. A localhost address must be opened on the Genesis machine; the connector does not create a remote-access tunnel. The URLs come from the configured Phoenix endpoint rather than incoming HTTP headers.

`genesis_get_task.progress.report` is the durable task-level report shared with the task page: `summary`, `current_work`, `completed`, `remaining`, `blockers`, `next_steps`, evidence origins, `revision` and `updated_at`. Workers can contribute while the root waits. Outcomes are reported claims; the task lifecycle and independent verification remain separate. A legacy task can have no report yet. Retained reports survive context compression, agent recycling and service restart; after restart they describe last known work.

Use `include_result=false` for routine reads; the full objective is omitted unless `include_objective=true`. Pass `progress.change_token` as `since` and `wait_seconds` from 0 to 20. Semantic reports and activity changes wake the bounded wait; an unchanged observation does not prove a stall. No model call is made by a progress query. Agent `tokens_since_compression` resets on compression; per-agent `cumulative_usage` has a separate meaning and must not be summed across parent/child aggregation.

`genesis_start_task.budget` accepts `max_agents` (root included, cumulative registrations), `max_depth` (root depth 0), `max_turns_root`, `max_turns` (children) and `max_duration_seconds`. MCP defaults are 6 / 2 / 96 / 64 / 2700. `effective_budget` returns the normalized limits; existing stricter service limits still apply. Registration enforces count/depth, runners enforce turns, and the task registry requests stopping at the time deadline with force escalation after 60 seconds if needed. GUI/CLI tasks without a budget retain their existing defaults.

`genesis_get_result` returns `not_ready` for active work and preserves failed/cancelled reports and partial outcomes. `recoverable_work` names retained or registered worker directories and refs across the primary and recorded foreign repositories; inspect them before resubmitting or manually cleaning. Actual foreign repository roots are recorded when the task loads them, so later configuration changes and loss of live agent state do not hide that work. A same-path retry refuses to overwrite recoverable content. Task lists also accept `status` and `search` filters.

`genesis_send_message` defaults to the root; optional `agent_id` selects a live agent belonging to the same task. The initial response is `queued_for_next_turn`, with a message ID and `acknowledged=false`. Follow `progress.report.messages`: `delivered` means the runner injected it into context; `unknown` means delivery cannot be established after losing the live agent. These states do not prove adoption. Messages are not broadcast to the entire tree.

`genesis_cancel_task` supports `wait_seconds` (0–20) and optional `force=true`. The wait limit controls the HTTP call, not the ongoing stop request. `stopped=true` requires a terminal task and no remaining agents, worktree cleanup or known background jobs; `null` means unavailable observation. Repeat the call after a disconnect or an expired wait to observe cleanup even when the task is already terminal. Force stopping uses the existing failed/force_kill outcome and preserves recoverable work. It does not undo Git changes.

`genesis_check.build` reports revision, release and platform when an installation bundles build metadata. Source builds without that metadata report `unknown`; they do not infer the running server's identity from the caller's working directory.

## Protocol details

The HTTP implementation negotiates MCP `2025-11-25` or `2025-06-18`, returns JSON tool responses, and accepts notifications with HTTP 202. GET and DELETE return 405 because there is no SSE stream or connection-bound session. Long work uses Genesis task IDs rather than the optional MCP task extension. No separate JSON REST task API is required.
