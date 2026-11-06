# Genesis Assistant

Open **Help** (`/help`) in the dashboard to ask Genesis Assistant how the system works, inspect its state, or request an operation.
It reads the Genesis source to explain behavior and verify public APIs before using them—not just to generate code from memory.
Try: “Explain how graceful cancellation works; check the source, then show my active tasks without changing anything.”

## Execution tiers and approval

The Assistant uses one `elixir_eval` tool with three tiers:

| Tier | Execution | Approval |
| --- | --- | --- |
| **read** | Dune interpreter with an explicit module/function/arity whitelist for inspection. | None. |
| **write** | The same interpreter, adding known write APIs. | **Allow once** for the exact code on every call. |
| **sudo** | Ordinary, unrestricted native Elixir—not the Dune interpreter. | A separate, prominent **red sudo approval card**. |

A public API found in source is **not automatically available** in read/write: its module, function, and arity must be whitelisted.
Ask the Assistant to read source/help first rather than guess a name or escalate after a rejection.
An optional safe `Read`/`Write` convenience facade exists, but is not required; the examples below use actual fully-qualified APIs.
Each evaluation starts with fresh bindings: variables do not carry over to the next call.
There is no automatic escalation between tiers.

**Sudo is powerful, not OS root.** It runs under the Genesis server's OS identity in the live, shared BEAM, with access to its filesystem and configuration.
It can affect other running work; it provides neither isolation nor rollback.
Execution-time and output bounds are operational limits, **not a security boundary**.
A timeout does not undo effects or prove that an operation failed: inspect current state before retrying any write.

### Reviewing a request

- Check the **exact original code and execution target** on the approval card, not only the Assistant's explanation.
- Choose **Allow once** to run that call, or **Deny** to reject it; sudo has its own red card so it cannot be mistaken for a normal write.
- Pending cards are restored while the request is still pending; this is not a promise of durable storage across server restarts.
- If approval submission fails, the card stays visible with guidance; do not assume the code ran or submit a replacement write blindly.
- Failed-task responses are retained when available; inspect the response and current state rather than treating a failed task as proof that nothing happened.

## Read: inspect tasks and live capacity

Ask: “Show ten task summaries and the total count.” Example **read** code:

```elixir
page = EvoGit.TaskRegistry.list_tasks_page(limit: 10, offset: 0)
%{
  total: page.total,
  tasks: Enum.map(page.rows, &Map.take(&1, [:id, :status, :type, :project_path]))
}
```

The result is `%{rows: [summary], total: integer}`.
The default limit is 25, capped at 50; offset defaults to 0.
Filters include `status`, `project_path`, `review_status`, and `search`.
Use `EvoGit.TaskRegistry.get_task_lite(id)` or `EvoGit.TaskRegistry.get_task(id)` for one task (`TaskInfo` or `nil`), and `EvoGit.AgentScheduler.RemoteAPI.list_agents()` for the live agent list.
These are admitted APIs, not a promise of arbitrary remote execution.

Ask: “Is scheduling paused, and what is the live tool capacity?” Example **read** code:

```elixir
%{
  paused: EvoGit.AgentScheduler.paused?(),
  tool_concurrency: EvoGit.AgentScheduler.get_config(:max_tool_concurrency),
  llm_slots: EvoGit.AgentScheduler.get_llm_slot_status()
}
```

`paused?/0` returns a boolean and `get_llm_slot_status/0` a map.
Scheduler configuration uses **`get_config/1`, not `get_config/0`**.
`EvoGit.Config.resolve()` reads defaults plus saved configuration, **not live scheduler overrides**.
For a section use `EvoGit.Config.resolve(:scheduler)`; for one nested value use `EvoGit.Config.resolve([:scheduler, :max_tool_concurrency])`.

## Write: start or manage a task

Ask: “Start a simple evolution task in this repository.” Example **write** code, requiring approval:

```elixir
EvoGit.TaskRegistry.start_task(:evolve,
  path: "/absolute/path/to/repository",
  mode: "simple",
  objective: "Add regression tests for the parser"
)
```

Replace the path and objective before approving; `mode` is the **string** `"simple"`.
`{:ok, task_info}` means the task was accepted for immediate start—not that its work succeeded.
Read its status and result afterward.

Other admitted write operations:

| API | Important effect |
| --- | --- |
| `EvoGit.TaskRegistry.cancel_task(id)` | Graceful cancellation; preserves the result. |
| `EvoGit.TaskRegistry.force_kill_task(id)` | Force kill; marks the task failed and discards its result. |
| `EvoGit.TaskRegistry.delete_task(id)` | Terminal tasks only; does **not** cancel a task. Asynchronous `:ok` is not confirmation of deletion. |
| `EvoGit.AgentScheduler.pause()` / `resume()` | Return `:ok`; in-flight work continues. Pause is not an absolute maintenance barrier. |

## Write: runtime settings versus saved configuration

For a temporary scheduler change, request **write** approval for:

```elixir
EvoGit.AgentScheduler.update_config(max_tool_concurrency: 8)
```

This changes the live scheduler only; it does not save the setting.
To persist the setting, preserve unrelated settings rather than replacing the configuration with a tiny map:

```elixir
config = EvoGit.Config.resolve()
updated = put_in(config, [:scheduler, :max_tool_concurrency], 8)

case EvoGit.Config.save_user_config(updated) do
  :ok -> EvoGit.AgentScheduler.RemoteAPI.reload_config()
  error -> error
end
```

Run the whole snippet in one **write** evaluation, then inspect both saved configuration and live scheduler state.
`save_user_config/1` validates and replaces the **whole configuration file**; it does not reload it.
This read-modify-save sequence is not atomic and materializes defaults, so coordinate with other configuration editors.
`reload_config/0` applies selected saved settings, not every subsystem's configuration.
For model changes, edit the existing `llm.models` profiles rather than overwriting them with an incomplete configuration.

When uncertain, ask for a source-backed explanation and a read-only check first; review each write's exact code and target before allowing it.
