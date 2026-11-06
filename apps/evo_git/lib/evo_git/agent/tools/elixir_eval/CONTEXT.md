# Assistant Elixir Evaluation Internals

## Intent
This directory implements fresh, local, tiered assistant evaluation with fail-closed runtime authority, narrow capability facades, bounded output and monitored BEAM-process cleanup.
The public tool wrapper, schema, argument validation and manual approval integration live in the sibling `../elixir_eval.ex`, not here.
Read/write use Dune interpretation; sudo is explicitly approved unrestricted native evaluation, not a security sandbox.

## Routing Table
There are no child directory nodes.
`../CONTEXT.md` owns tool exposure and dispatch integration, and `../../CONTEXT.md` owns tool-task identity propagation and approval-aware outer timeouts.
Tests belong to `apps/evo_git/test/evo_git/agent/tools/` and its parent agent suites; see their CONTEXT.md files rather than placing tests beside these modules.
Related existing suites include `reflect_tools_test.exs` in the tools test directory and the parent tool-dispatch tests; these integration suites are not evidence of exhaustive evaluator coverage.
No filename containing `eval` is present under `apps/evo_git/test/` in this checkout, so evaluator-specific regression coverage must be verified when adding or merging tests.

## API Surface
| File / modules | Contract |
|---|---|
| `authorization.ex` / `Authorization` | `authorize/0,1`, `assistant_owner?/0`, `revalidate/1` bind permission to the original assistant owner and tool process. |
| `ancestry.ex` / `Ancestry` | `includes?/2` and `broker/1` inspect bounded local Task/proc_lib ancestry. |
| `engine.ex` / `Engine` | `run(code, tier, context, limits)` returns `{:ok, binary}` or `{:error, binary}`; `max_code_bytes/0` exposes the engine ceiling. |
| `worker_tree.ex` / `WorkerTree` | `run(context, tier, limits, fun)` creates a guardian, authorized broker and independently owned traced evaluation subtree, with bounded execution, cleanup and caller waits. |
| `custodian.ex` / `Custodian` | Internal independent trace owner; `start/4`, `finish/2` and `cleanup_ms/0` support bounded reaping even after abrupt guardian/tool death. |
| `broker.ex` / `Broker` | `start/2,3,4`, `attach/2,3`, `call/2`, `output/1,2`, `stop/1,2` implement one unregistered capability broker per evaluation, with optional lifecycle-call timeout overrides. |
| `allowlist.ex` | `ReadAllowlist` extends Dune defaults with Read; `WriteAllowlist` additionally admits Write, with explicit IO shims and dbg rejection. |
| `read.ex` / `Read`, `Write` | Fixed broker-backed runtime inspection and mutation APIs, not direct access to runtime structs or configuration. |
| `projection.ex` / `Projection` | Scalar runtime projections, paginated task options, task-id validation and scalar normalization. |
| `validation.ex` / `Validation` | `start_options/2` and `guide/2` validate mutation arguments using literal keys and enums. |
| `render.ex` / `Render`, `IOShim` | UTF-8-safe byte-capped rendering and Dune stdout shims. |
| `bounded_io.ex` / `BoundedIO` | `start/1`, `output/1`, `stop/1` supply a bounded monitored group leader for native character output. |

## Authorization and Trusted Handoff
Authorization ignores tool-task role flags and captures `agent_id`, `task_id`, `owner_pid`, original `tool_pid`, current `target_node` and the call-time TaskRegistry server.
`authorize/1` requires the original tool to descend from the owner, and `revalidate/1` preserves those original identities even when called by trusted guardian/broker processes.
Internal target selection accepts nil/current/local spellings or the exact current node name; no remote target or input-derived node atom is created.
Both original processes must be alive and local, the scheduler registered, and the captured task must be a running `:reflect` task fetched with `{:get_task_lite, id}` under a one-second deadline.
SchedMeta must describe a depth-zero, nil-parent, unsent-result SelfReflective agent in `:running` or `:blocked`, with its Task pid equal to the owner.
Its spec must be primary, repo-less, without foreign repos, phylo node or custom-agent identity, and its task-id option must match.
A projected ETS AgentState check requires primary/nil-parent/no-foreign-repos state and cancellation false or nil, without copying conversation or generation parameters.
Revalidation checks owner/tool liveness and unchanged SchedMeta again after the task lookup, but is not an atomic transaction with a subsequent mutation.
Missing tables, stale state, registry timeout/exit and exceptions return the same generic authorization refusal.
`Ancestry` follows at most 32 queued process entries, reading at most eight pid entries from each `$callers` and `$ancestors` list, with local-only cycle-safe traversal.
These dictionaries are runtime-maintained authority assumptions, not cryptographic credentials; Dune must not expose Process dictionary APIs.
Only the original tool may call `Broker.start`, explicitly nominating its live local guardian as controller while leaving `context.tool_pid` and `context.owner_pid` unchanged.
Only the controller may attach one worker or collect output, and only controller or creator may stop the broker.
The worker is raw-spawned without links and seeds exactly `$ancestors = [guardian]` plus `:evogit_eval_broker` in trusted code before its readiness handshake.
Attach requires that exact immediate ancestor list, not a mutable native link or merely transitive ancestry; evaluated code cannot run before trace setup, readiness and attach all succeed.
Dune's nested Task/proc_lib processes discover the broker through ancestry, and each capability request must descend from the attached worker.

## Engine and Cleanup Boundaries
Engine accepts validated limits and an authorized context, adds only the requested output cap to that context, and relies on the wrapper for lifecycle revalidation before and after evaluation and approval.
Every evaluation has fresh bindings; there is no persistent REPL state.
The engine rejects invalid UTF-8 or code over 16,384 bytes independently of any stricter public-tool validation.
Read/write use Dune's safe string parser for preflight and interpretation, with a 1,000-atom pool, 1,000,000-word heap budget, 5,000,000 reductions and supplied execution/parse timeouts.
Unqualified dbg AST nodes are rejected before interpretation because sanitizer-generated debug IO can bypass normal allowlist shims; Kernel.dbg is also restricted by the allowlist.
Default Dune pure operations remain available, but raw TaskRegistry, AgentScheduler, CommandShell, Broker and arbitrary native APIs are not added to the allowlist.
Sudo runs `Code.eval_string(code, [])` with full VM authority only after the external approval gate; it can access secrets, mutate the VM, spawn OS children or interfere with tracing.
WorkerTree uses an unlinked monitored guardian, monitors caller and optional owner/agent pids, and monitors the broker separately.
An independent unlinked Custodian owns inherited spawn tracing, installed on the waiting guardian before it may spawn the root, and monitors both guardian and caller.
The custodian forwards spawn events to the guardian for resource accounting but retains its own monitored worker set, so abrupt guardian death cannot abandon unlinked root/child/grandchild processes.
Tracing covers Dune's unlinked helper descendants before execution begins.
The root worker has a 2,000,000-word killing heap limit including shared binaries; the guardian samples tree memory and cumulative observed reductions every five milliseconds.
Tree budgets are 64 MiB of sampled process/binary memory, 20,000,000 sampled reductions and 64 total observed spawned processes including the root.
These are best-effort BEAM limits rather than OS isolation; native BIFs can overshoot and full-authority sudo cannot be contained against deliberate interference.
On normal completion, failure, timeout or owner loss, custody kills known descendants, drains further spawn events and waits for a trace-delivery barrier before acknowledging cleanup.
Cleanup has its own 1,000 ms monotonic budget, independent of the execution deadline; budget checks run even under a continuously nonempty mailbox.
Successful cleanup requires every known descendant's DOWN plus a trace-delivery barrier, so normal success leaves no known descendant alive.
On cleanup expiry every known pid receives another kill, the custodian exits and the result is an explicit generic cleanup error, never a successful evaluation with unconfirmed cleanup.
Guardian cleanup-ack waits are capped at 1,100 ms; caller result waits and the independent custody watchdog share an absolute deadline of run-entry time plus the requested execution timeout plus 5,000 ms.
WorkerTree broker initialization/attach/output calls use 1,200 ms IPC deadlines (initial authorization separately has its existing one-second deadline), and broker shutdown waits at most 250 ms before a kill; existing Broker callers retain their five-second defaults.
Caller finalization kills the guardian but deliberately leaves custody alive to finish reaping, then waits at most another 1,100 ms for custody DOWN.
The caller's maximum scheduled waiting budget is therefore execution timeout plus 6,350 ms (5,000 ms result overhead, 250 ms broker stop, 1,100 ms final custody wait), excluding scheduler starvation or non-preemptible native work; this is not a hard real-time guarantee.
A suspended custodian may finish after the caller has returned an error, and a stuck native BIF may defer death after kill; cleanup expiry, deliberate tracer/custodian tampering and OS children cannot guarantee no survivors.
Unexpected custodian exceptions also kill the guardian and all pids in its last known worker snapshot without leaking exception terms.
The broker independently monitors original owner, tool, controller and attached worker; trusted runtime operations run in a separate pending Task so lifecycle messages remain serviceable.
Worker loss cancels a pending operation, and broker termination cancels its pending Task and kills its attached worker; committed side effects cannot be rolled back.

## Capabilities, Quotas and Mutations
Read exposes `help/0`, `system_info/0`, `list_tasks/0,1`, `get_task/1`, `list_agents/0`, `scheduler_status/0` and `model_profiles/0` through the broker.
Write exposes `start_task/2`, `cancel_task/1`, `force_kill_task/1`, `delete_task/1` and `guide/1,2`, and requires a write- or sudo-tier broker.
Each evaluation permits at most 128 broker requests including IO, 32 reads, 500 charged projected rows, 16 writes and four task starts, with at most one pending runtime operation.
Row charging uses requested task-page limit, 100 for agent/model-profile reads and one for other reads, rather than counting actual returned rows.
Runtime operations revalidate original authority before and after execution, and mutations revalidate again immediately before dispatch; registry calls use one-second deadlines and broker IPC uses five seconds.
Task start accepts only literal genesis/evolve/reflect/extract_skills types and at most five distinct supported atom/string keys: path, mode, objective, prompt and model_id.
Start strings are nonblank valid UTF-8 without NUL and at most 8,000 bytes; non-reflect tasks require an absolute path of at most 1,024 bytes, existing except for genesis-new, while reflect rejects path.
Modes are genesis new/existing, evolve simple and reflect reflect; custom, merge/resume and foreign-repo options are not exposed, extraction rejects objective/prompt, and a known model profile adds `model_id_locked: true`.
Self-targeting mutations are refused; cancel permits pending/running, force-kill running/cancelling and delete completed/failed/cancelled tasks.
Deletion returns an explicit queued-cast acknowledgement, never a persisted-deletion guarantee, and submission failures instruct inspection before retrying because timeout does not prove absence of side effects.
Guides require a message of at most 2,000 bytes, an allowlisted local page, optional simple `#id` selector of at most 80 bytes and boolean dismissible flag.

## Projection and Output Contracts
Task reads use page/lite APIs and expose only id, type, status, review_status, timestamps and agent_count, never objective, opts, result, errors, usage, histories or credentials.
Task pages default to limit 25/offset 0/status all, accept limit 1..50 and offset 0..10,000, and validate status against literal enums; task ids are 1..128 bytes of ASCII letters, digits, underscore or hyphen.
Agent listing projects five fields inside ETS, takes one unsorted page of at most 100 and reports whether a continuation exists, without copying agent contexts.
Scheduler status totals used/waiting/capacity across at most 100 model-slot entries and separately reads only paused, never the full scheduler configuration.
Model profiles return at most 100 id/model/concurrency projections; the underlying scheduler call still retrieves the profile list before projection.
System info exposes only OS enum, Elixir/OTP versions, UTC time and online scheduler count; unknown scalars normalize to nil and counts require nonnegative integers.
Render.text caps BYTES, preserves a valid UTF-8 prefix, copies short slices and includes `\n[output truncated]` inside the cap when space permits.
Render.term uses bounded inspection with limit 100, printable_limit at most 2,048, structs disabled and charlists rendered as lists.
Broker stdout accumulation honors the requested `max_output_bytes`, defaults to 16,384 and refuses caps over 65,536; the engine also caps combined stdout and result/error text to that same requested budget.
Dune IO.puts accepts arities one/two and IO.inspect one/two/three through IOShim, only for stdio; inspect options cannot request unbounded output, labels cap at 256 and each emitted item is rendered to at most 16,384 bytes plus newline before broker accounting.
BoundedIO captures native group-leader character writes up to the requested cap, rejects input/files/arbitrary IO MFA requests and returns enospc on overflow; its owner monitor and traced cleanup prevent it outliving the evaluation.
Dune internal diagnostic StringIO is not replaced; code, heap and execution limits bound that internal channel indirectly, while evaluated user IO uses the bounded broker.
Unexpected facade, IPC, guardian and evaluated exceptions/exits use generic fixed errors, withholding raw messages, stacktraces, exit/throw values and Dune failure stdio that might contain secrets.
Known validation errors remain descriptive, and sudo's deliberately returned values or printed secrets are not redacted.

## Constraints
Keep authorization, approval and execution boundaries distinct, and never infer a tier by executing code or automatically escalate a denied read/write operation.
Do not replace original tool/owner identities with guardian or Dune child identities, use links as ancestry proof, expose broker controls to Dune or add Process dictionary access to its allowlist.
Do not expose raw runtime structs, nested configuration, full histories or unbounded task collections through facades; add explicit projected fields and quota accounting instead.
Generic failure rendering is a confidentiality boundary, while truncation and resource sampling alone are not.

## Test Strategy
Persistent tests belong to the sibling test subtree and require parent coordination; do not modify tests from this node.
Real-Dune integration requires genuine scheduler owner/spec/ETS identities plus an isolated TaskRegistry/Store, not mocked authorization or stubbed Dune.
Cover nested Dune proc_lib/Task facade discovery, direct capability denial, requested cumulative IO caps, stale/cancelled authority, owner/tool death and descendant cleanup.
Direct Engine write/sudo execution does not validate the public wrapper's manual approval gate; exercise that separately through `CommandApproval.request_eval/5`.
Fully qualified facade calls are supported; Dune's default allowlist rejects `alias/1`, so short-alias examples must not rely on interpreted alias declarations.
