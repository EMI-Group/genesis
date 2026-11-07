# Genesis Assistant

Genesis Assistant is the dashboard's operator chat, opened from the sidebar entry **Assistant** (route `/help` unchanged).
It is not just a help page: it understands Genesis itself — the context tree, task lifecycle, agents and scheduler, models and configuration, the dashboard — and it operates the running system on your behalf while it explains it.
It answers as Genesis in the first person (“I can …”), in your language, and its final chat reply is the answer you read.

If the Genesis source has not been downloaded yet, a banner blocks the composer until you press **Download source**; the Assistant reads that checkout, so source-backed answers need it.
The gate is local-only: on a remote node it stays hidden instead of blocking the chat.

## What it can do

- Read the Genesis source and documentation: `read`, `read_context`, `list_dir`, `rg`, `glob`, `search_context`, and git history via `search_history`.
- Read a pasted URL or documentation page as Markdown (`web_fetch`), and search the web when web search is enabled in your configuration.
- Evaluate Elixir against the live runtime through one tiered `elixir_eval` tool: **read**, **write**, **sudo**.
- Inspect and drive tasks: list pages, inspect one task, start `genesis`/`evolve`/`reflect`/`extract_skills` work, resume an earlier task, gracefully cancel, force-kill, or delete.
- Read live scheduler state and resolved configuration, change runtime settings, or persist configuration.
- Drive the guide overlay to a standard dashboard page (`/projects`, `/tasks`, `/agents`, `/settings`, `/system`, `/help`), optionally highlighting one element, with a **Go** button that opens it.

`elixir_eval` always runs on the node you are currently viewing, never on an arbitrary node.

## Things to ask it

- “Show my running tasks, newest first.”
- “Why did that task fail? Check its status, error and result.”
- “Start an evolve task in this repository.”
- “Pause scheduling until I finish this merge.”
- “What is my live capacity right now — queues, LLM slots and tool concurrency?”
- “Raise the turn limit to 200 for the next agents.”
- “Take me to this task's review page.”

For a specific review page, the Assistant reads the task and gives you its `/review/<task_id>` path; the guide overlay itself opens standard dashboard pages.

## Choose a model and reasoning effort

The Assistant uses the same **Provider profile**, **Model** dropdowns and supported **Reasoning effort** slider as Projects.
Models come from the selected account's explicit inventory; see [LLM provider profiles](llm-profiles.md) for configuration and selection rules.
The effort slider appears only when the selected model advertises a nonempty supported-effort inventory; with one effort it is disabled.
It selects the model's configured default effort when available, otherwise the first supported item—this UI fallback does not set a configuration default.
An explicit `none` effort is a concrete choice, not an omitted value that inherits configured/provider defaults.

**Auto (by rules)** leaves model selection to the existing rules; choosing a concrete provider profile/model locks that choice for the Assistant task you send.
This does not change saved defaults or other tasks, including tasks the Assistant later starts on your behalf.
Selection is scoped to the node you are viewing; check the target after switching nodes, and resolve unavailable profiles/models/efforts before sending rather than assuming an automatic fallback.

## Execution tiers and approval

The Assistant uses one `elixir_eval` tool with three tiers:

| Tier | Execution | Approval |
| --- | --- | --- |
| **read** | Dune interpreter with an explicit module/function/arity whitelist for inspection. | None. |
| **write** | The same interpreter, adding known write APIs. | **Allow once** for the exact code on every call. |
| **sudo** | Ordinary, unrestricted native Elixir—not the Dune interpreter. | A separate, prominent **red sudo approval card**. |

A public API found in source is **not automatically available** in read/write: its module, function, and arity must be whitelisted.
Ask the Assistant to read source/API help first rather than guess a name or escalate after a rejection.
An optional safe `Read`/`Write` convenience facade exists, but is not required; the examples below use actual fully-qualified APIs.
Each evaluation starts with fresh bindings: variables do not carry over to the next call.
There is no automatic escalation between tiers.
The tool blocks for approval of the exact code, so a conversational “OK” is not approval; a denied or timed-out call is explained, never retried at a higher tier.

**Sudo is powerful, not OS root.** It runs under the Genesis server's OS identity in the live, shared BEAM, with access to its filesystem and configuration.
It can affect other running work; it provides neither isolation nor rollback.
Execution-time and output bounds are operational limits, **not a security boundary**.
A timeout does not undo effects or prove that an operation failed: inspect current state before retrying any write.

### Reviewing a request

- Check the **exact original code and execution target** on the approval card, not only the Assistant's explanation.
- Choose **Allow once** to run that call, or **Deny** to reject it; sudo has its own red card so it cannot be mistaken for a normal write.
- The Assistant submits code through the tool instead of asking you to confirm in prose: a reply with no tool calls ends its run and its text is your answer.
- Pending cards are restored while the request is still pending; this is not a promise of durable storage across server restarts.
- If approval submission fails, the card stays visible with guidance; do not assume the code ran or submit a replacement write blindly.
- Failed-task responses are retained when available; inspect the response and current state rather than treating a failed task as proof that nothing happened.

## Read: tasks, failures and live capacity

Ask: “Show ten task summaries and the total count.” Example **read** code:

```elixir
page = EvoGit.TaskRegistry.list_tasks_page(limit: 10, offset: 0)
%{
  total: page.total,
  tasks: Enum.map(page.rows, &Map.take(&1, [:id, :status, :type, :project_path]))
}
```

The page result is `%{rows: [summary], total: integer}`.
The default limit is 25, capped at 50; offset defaults to 0.
Filters include `status`, `project_path`, `review_status`, and `search`.
Use `EvoGit.TaskRegistry.get_task_lite(id)` or `EvoGit.TaskRegistry.get_task(id)` for one task (`TaskInfo` or `nil`), and `EvoGit.AgentScheduler.RemoteAPI.list_agents()` for the live agent list.
These are admitted APIs, not a promise of arbitrary remote execution.

Ask: “Why did that task fail?” Example **read** code:

```elixir
task = EvoGit.TaskRegistry.get_task("task_id")
%{
  status: task.status,
  error: task.error,
  review_status: task.review_status,
  commit_sha: task.commit_sha,
  result: task.result
}
```

`nil` means the id is unknown—check for `nil` before reading fields; select only the fields you need, because `result` can be large and sensitive.
Output caps are size limits, not redaction.

Ask: “Is scheduling paused, and what is the live tool capacity?” Example **read** code:

```elixir
%{
  paused: EvoGit.AgentScheduler.paused?(),
  tool_concurrency: EvoGit.AgentScheduler.get_config(:max_tool_concurrency),
  llm_slots: EvoGit.AgentScheduler.get_llm_slot_status()
}
```

`paused?/0` returns a boolean and `get_llm_slot_status/0` a per-provider-profile map of live pools.
Models and reasoning efforts under the same provider profile share its capacity.
Scheduler configuration uses **`get_config/1`, not `get_config/0`**.
`EvoGit.Config.resolve()` reads defaults plus saved configuration, **not live scheduler overrides**.
For a section use `EvoGit.Config.resolve(:scheduler)`; for one nested value use `EvoGit.Config.resolve([:scheduler, :max_tool_concurrency])`.
Resolved configuration can include credentials, so print only the keys you asked for.

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
Add `resume_from: "<task_id>"` to continue an earlier task instead of starting from scratch.
`{:ok, task_info}` means the task was accepted for immediate start—not that its work succeeded.
Read its status and result afterward.

Other admitted write operations:

| API | Effect and what the acknowledgement proves |
| --- | --- |
| `EvoGit.TaskRegistry.cancel_task(id)` | Graceful cancellation: the task turns `:cancelling`, agents get a save-work message and a short grace budget, and the result is preserved under a final `:cancelled`. `:ok` acknowledges the request, not that the task has stopped. |
| `EvoGit.TaskRegistry.force_kill_task(id)` | Kills the task's agents and wrapper and persists `:failed` with the result discarded. `:ok` acknowledges the kill request. |
| `EvoGit.TaskRegistry.delete_task(id)` | An asynchronous cast that removes a task's row; use it on terminal tasks. `:ok` only means the deletion was queued—re-read the task to confirm it is gone. |
| `EvoGit.AgentScheduler.pause()` / `resume()` | Return `:ok`; in-flight work continues under pause. Pause is not an absolute maintenance barrier. |

The bounded write facade also enforces statuses (cancel `:pending`/`:running`, force-kill `:running`/`:cancelling`, delete terminal only) and refuses the Assistant's own task.
Direct calls to the real APIs add no facade status or self-target policy, so check a task's current state before acting on it.

## Write: pause, resume and turn caps

Ask: “Pause scheduling until I finish this merge.” Example **write** code:

```elixir
EvoGit.AgentScheduler.pause()
EvoGit.AgentScheduler.paused?()
```

`resume/0` grants queued slots and dispatches agents blocked during the pause.
`update_config/1` ignores `:paused`, so pause and resume need their own transitions.

Ask: “Raise the turn limit to 200 for the next agents.” Example **write** code:

```elixir
EvoGit.AgentScheduler.update_config(max_turns: 200, max_turns_root: 300)
```

Turn caps apply to future agent registrations; agents already running keep theirs.
This is a runtime-only change.

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
`reload_config/0` applies selected saved settings, not every subsystem's configuration; boot-only settings such as distribution still need a restart.
This read-modify-save sequence is not atomic and materializes defaults, so coordinate with other configuration editors.
For model changes, edit the existing `llm.providers` accounts and their nested `models` inventory rather than overwriting them with an incomplete configuration.
See [LLM provider profiles](llm-profiles.md) for account defaults, model overrides and selection rules.

When uncertain, ask for a source-backed explanation and a read-only check first; review each write's exact code and target before allowing it.

The Assistant does not volunteer CLI usage by default: you are in the dashboard, so it guides with pages and in-app capabilities instead, and answers about the command line only when you explicitly ask.
