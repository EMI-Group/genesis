# Genesis Assistant

The `/assistant` page is a conversational operator for Genesis. `/help` redirects there. It uses interactive sessions, the shared sidebar conversation list, atomic streaming watches, and the existing provider/model picker.

## Project context

A conversation may have no project. System questions and global task reads work without one. Use the project control below the header to choose a recent project or enter an existing absolute directory on the selected host. Opening or clearing a project preserves the message draft. The choice is conversation- and node-scoped, restored on remount, and inherited by a new conversation on the same node.

Project switching is locked while a reply is running. At an input boundary, the next message updates the session's authoritative project metadata. The selected project supplies omitted paths for project-scoped task operations. An explicit different path remains the actual target shown for approval. Selecting a project does not mean the Assistant has read its files or started development.

## Task tools and approvals

Ordinary development uses the same nine task-control definitions as MCP:

- `genesis_check`, `genesis_reload_config`, `genesis_list_models`
- `genesis_start_task`, `genesis_get_task`, `genesis_list_tasks`
- `genesis_get_result`, `genesis_send_message`, `genesis_cancel_task`

`EvoGit.TaskControl.Tools` owns schemas, validation and dispatch. MCP owns its HTTP envelope and links; `Agent.Tools.GenesisTools` owns model-facing output and Assistant authorization. Model arguments cannot choose the runtime node or conversation identity. Both come from the actual assistant owner and its server-owned session metadata.

Read-only task queries run directly. Assistant mutations require the existing approval broker. The dialog shows the action, target node, project/task, and exact structured parameters. Approval binds that request, rather than reading a mutable composer after approval. Denial or timeout does not execute the action. After an uncertain submission, inspect current task state before retrying; starting a task is not completing it.

Advanced system inspection, scheduler changes and configuration operations may still use `elixir_eval`. Its read/write/sudo tiers and exact-code approval remain in effect. Structured task tools do not expand evaluator privileges or alter external MCP authorization.

## Following development tasks

A successful Assistant task start is automatically linked to that conversation. The composer's Tasks menu lists task names, statuses and projects on the selected node, supports search and pagination, and follows a task when selected. Already followed tasks are marked. Manual ID entry remains in a secondary disclosure; `genesis_follow_task` is also available to the Assistant. Listing or reading tasks does not automatically follow every returned task.

Task cards show saved status, project, observed agent counts, refresh time and an entry to the task's review/results page. Missing stage data is not converted into an invented percentage. Cards refresh asynchronously from the task-control boundary; stale results from another node or conversation are ignored. A refresh failure retains the last known facts.

Task references are held separately from the live Assistant session, so the task remains accessible when the Assistant session finishes. They have the same volatile lifetime as the dashboard's in-memory conversation store. This does not provide full conversation recovery after a server restart. Tasks and results remain in the existing persistent task store and can be found and followed again.

## Reply, message and cancellation controls

- **Stop reply** stops the current Assistant generation and keeps the interactive session available for another message. Background development continues. An executing tool batch is allowed to settle before the reply stops; stopping generation does not undo an external action.
- **Send requirements** on a task card sends to that specific task through the shared tool and approval boundary. Acceptance means queued/accepted, not that an agent has already adopted the instruction.
- **Request task cancellation** targets the selected development task. The card follows the backend's state; a cancellation request is not an immediate process-cleanup guarantee and does not undo Git changes.
- Sending from the ordinary composer while the Assistant is running queues a message for a later turn boundary. The explicit queue button has the same boundary semantics; it does not immediately halt an LLM chunk.

## Attachments

The plus menu opens the browser's native file chooser on the user's current device. Selected files upload to the dashboard and are staged for the current conversation; deploying Genesis on another machine does not make that chooser browse the server. Text, PDF, DOCX, supported images and audio share one upload action, with up to four files per message and 15 MiB per file. Classification uses the original filename rather than the extensionless upload temporary path. Text documents join the message body; media uses the existing session attachment format.

The secondary server-path entry reads an existing absolute path on the selected Genesis host. The current path reader supports the dashboard's local node; an unsupported remote node reports that limitation and directs the user to browser upload. It never reads the dashboard host as a substitute. Switching conversation or node cancels pending uploads. Sending waits for upload completion; a completed attachment can be sent without extra text.

## Optional source reference

Chat and task control need no Genesis checkout. The Assistant starts with minimal repo-less context and does not load the launch directory's CONTEXT tree or project skills.

For implementation questions, `genesis_source` can inspect reference availability, read bounded root context, or prepare a missing checkout after approval. The reference is separate from the execution working directory and user project. The tool reports reference and runtime versions so a mismatched checkout cannot be described as the exact running implementation. Source management remains available in System settings. A missing or failed source download does not block normal chat.

## Storage and remote nodes

Conversation state remains in the existing in-memory ChatHistory store. Page navigation and remount can restore it; BEAM restart is not durable chat recovery. Model selection, project identity, task references and async results must stay scoped to the selected node/conversation. Unresolved remote connections never fall back to the dashboard host for project or task actions.
