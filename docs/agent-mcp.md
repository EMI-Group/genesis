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

Register the endpoint and authorization using the host's documented configuration format. MCP does not standardize where a host stores its configuration or how it expands environment variables; do not assume a Codex manifest, `mcpServers` wrapper or placeholder syntax is accepted everywhere. Reload the host connection, discover the eleven tools, and call `genesis_check`. This is the point where a small host adapter differs; it does not need another copy of the complete Genesis tutorial.

## Delegate from a calling agent

Supply a self-contained objective: the relevant background, absolute project path, intended behavior, constraints and acceptance checks. Genesis uses its own configured models; it does not inherit the caller's conversation or model. Keep the returned task ID, report meaningful progress changes, and inspect the resulting commits and test evidence before presenting the work as verified.

## Verify the connection

Discover `genesis_check`, `genesis_start_task`, `genesis_get_task`, `genesis_list_tasks`, `genesis_cancel_task`, `genesis_pause_task`, `genesis_resume_task`, `genesis_list_models`, `genesis_get_result`, `genesis_send_message` and `genesis_reload_config`. Confirm that a fresh host session can call `genesis_check` with the persisted credential. Model readiness is a separate configuration result, not proof of provider connectivity. For missing provider/model or authentication, use the provider profile and OAuth guides above together with `genesis_check.config_files` and `genesis_reload_config`. Test task submission only for a user-authorized development objective.

## Tasks and results

- **Start:** `genesis_start_task` takes an absolute `path` and `objective`. `evolve`/`simple` develops an existing project; `genesis`/`new` builds a new one. `genesis`/`existing` is also available. Optional `model_id` selects a configured profile. Optional boolean `persistent_state` (default `true`) enables per-agent durable checkpoints so a crash retry resumes from its last turn; `false` disables them for that task.
- **Track:** retain the returned ID and query `genesis_get_task`. `running`, `pausing`, `cancelling` and `finalizing` are not completion, and `paused` is a resumable resting state, not a result. The backend owns task execution independently of HTTP requests.
- **Reconnect:** `genesis_list_tasks` can filter by project and page through recent tasks. Inspect existing tasks after an uncertain submission before submitting again.
- **Continue:** use an `evolve` task with `resume_from` identifying a finished task in the same project. It starts a new task using the prior result context; it does not revive a process.
- **Stop:** `genesis_cancel_task` requests graceful cancellation. It does not undo Git changes.
- **Pause/Resume:** `genesis_pause_task` drains a running task to `paused` (the agent finishes its current tool call first) and `genesis_resume_task` continues the SAME task from its durable checkpoint; the paused task's `pause_kind` is `clean` (user pause — nothing interrupted) or `dirty` (recovered after a restart — the last tool call may be incomplete, which the resumed agents are told).
- **Inspect:** task details include status, error, saved result and available commit/branch fields. The result envelope preserves the backend's `__result_tag__` (`ok`, `error`, `exit` or `string`). It does not establish independent test verification; The calling agent should inspect evidence and run relevant checks.

This connector adds no snapshot of uncommitted files, automatic application to the user's working tree, new task queue or undo mechanism. Existing project configuration, including any configured foreign repositories, still applies. A new non-Git directory is initialized by the existing runtime. An existing repository needs an initial commit. Linked worktree and submodule roots are rejected by this entry point because the current runtime expects a primary checkout with a `.git` directory. The readiness check reports these conditions without modifying files.


## Observing and controlling work

`genesis_get_task.progress` is a bounded, read-only projection of existing scheduler summaries and saved task state. It reports registered agents, status counts and recorded counters, without prompts, histories, tool arguments or private notes. It does not create a durable progress report or infer completion percentages, stalls or cleanup. Agent output is capped at 20 entries; `agents_omitted` reports the remainder. Objectives in agent summaries are capped at 240 characters.

For routine polling, pass `include_result=false`. The full task objective is opt-in with `include_objective=true`; a short preview is returned by default. Pass `progress.change_token` as `since` and `wait_seconds` from 0 to 20 for a bounded wait. Clock-only changes do not advance the token; saved outcomes and observed agent content do. No model call is made by polling. An empty agent snapshot does not establish that the scheduler or all background processes have stopped.

`genesis_send_message` uses the existing user-message queue. It defaults to a runnable task root; optional `agent_id` selects a runnable agent in that task. The response `queued_for_next_turn` with `acknowledged=false` describes API acceptance only. It carries no persistent delivery receipt and does not establish delivery or adoption by a model.

`genesis_cancel_task` calls the existing registry cancellation API; `force=true` selects its existing force-kill operation. The result includes the saved task state and `cancel_requested`, indicating whether this call was accepted. Repeating cancellation on a terminal task returns its saved state with `cancel_requested=false`. It does not confirm that every process or cleanup action has ended and does not undo Git changes. Execution limits, worktree cleanup, persistence and configuration reload behavior remain those of the existing service.

`genesis_pause_task` and `genesis_resume_task` call the same registry pause/resume API the dashboard uses. Acceptance returns the saved task state (`pausing`/`paused` for a pause, `running` for a resume), not proof that every agent has stopped. A pause is refused for an interactive session (`not_pausable`) and for a task whose durable agent state is disabled (`not_resumable`); a task resumed after a restart rebuilds the whole dangling subagent batch from the durable roster — an already-finished child contributes its stored result without being re-spawned, a still-running child is re-spawned on its own commit and branch with its restored conversation, and a child with no rebuildable row is reported lost — so only subagent work that was never checkpointed is gone. Resuming keeps the same task id and does not undo Git changes.

## Protocol details

The stateless HTTP implementation negotiates MCP `2025-11-25` or `2025-06-18`, returns JSON tool responses and accepts notifications with HTTP 202. GET and DELETE return 405 because there is no SSE stream or connection-bound session. Long work uses existing Genesis task IDs.
