# Assistant Elixir Evaluation Internals

## Intent
This directory implements fresh, local, tiered assistant evaluation with fail-closed runtime authority, exact-MFA direct API admission and compatible narrow facades, bounded output and monitored BEAM-process cleanup.
The public tool wrapper, schema, argument validation and manual approval integration live in the sibling `../elixir_eval.ex`, not here.
Read/write use Dune interpretation; sudo is explicitly approved unrestricted native evaluation, not a security sandbox.

## Routing Table
There are no child directory nodes.
`../CONTEXT.md` owns tool exposure and dispatch integration, and `../../CONTEXT.md` owns tool-task identity propagation and approval-aware outer timeouts.
Tests belong to `apps/evo_git/test/evo_git/agent/tools/` and its parent agent suites; see their CONTEXT.md files rather than placing tests beside these modules.
Evaluator-specific suites in the tools test directory cover authorization, engine execution, traced engine cleanup, worker-tree lifecycle, public wrapper approval, projections, validation and rendering (`elixir_eval_*_test.exs`), with shared genuine assistant fixtures in `elixir_eval_fixture_helper.exs`.
`elixir_eval_engine_cleanup_test.exs:26` is the cold-start fully qualified Read facade regression and must also pass alone in a fresh BEAM, without preloading the facade or generated Base allowlist.
Related integration suites include `reflect_tools_test.exs` and the parent tool-dispatch tests; direct Engine write/sudo tests do not establish public-wrapper approval enforcement.

## API Surface
| File / modules | Contract |
|---|---|
| `authorization.ex` / `Authorization` | `authorize/0,1`, `assistant_owner?/0`, `revalidate/1` bind permission to the original assistant owner and tool process. |
| `ancestry.ex` / `Ancestry` | `includes?/2` and `broker/1` inspect bounded local Task/proc_lib ancestry. |
| `engine.ex` / `Engine` | `run(code, tier, context, limits)` returns `{:ok, binary}` or `{:error, binary}`; `max_code_bytes/0` exposes the engine ceiling. |
| `worker_tree.ex` / `WorkerTree` | `run(context, tier, limits, fun)` creates a guardian, authorized broker and independently owned traced evaluation subtree, with bounded execution, cleanup and caller waits. |
| `custodian.ex` / `Custodian` | Internal independent trace owner; `start/4`, `finish/2` and `cleanup_ms/0` support bounded reaping even after abrupt guardian/tool death. |
| `broker.ex` / `Broker` | `start/2,3,4`, `attach/2,3`, `call/2`, `output/1,2`, `stop/1,2` implement one unregistered capability broker per evaluation, with optional lifecycle-call timeout overrides. |
| `allowlist.ex` | Read/write wrappers enforce exact EvoGit MFA/tier admission before Dune default fallback, with explicit IO shims and dbg rejection. |
| `direct_api.ex` / `DirectAPI` | Literal exact-MFA/tier registry, generated fixed real-function invocations and shared direct-API help. |
| `read.ex` / `Read`, `Write` | Fixed broker-backed runtime inspection and mutation APIs, not direct access to runtime structs or configuration. |
| `projection.ex` / `Projection` | Scalar runtime projections, paginated task options, task-id validation and scalar normalization. |
| `validation.ex` / `Validation` | `start_options/2`, `guide/2` and `scheduler_options/1` validate mutation arguments using literal keys and enums. |
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
Both public allowlist wrappers load their generated Base allowlist in an `@on_load` callback, so Dune's generated alias-atom initialization runs before safe parsing, including when read or write is the first tier used in a fresh BEAM.
Deferring Base loading until `fun_status/3` is too late: Dune 0.3.18 encodes unknown alias segments before function authorization, preventing fully qualified facades from resolving on cold first use.
Unqualified dbg AST nodes are rejected before interpretation because sanitizer-generated debug IO can bypass normal allowlist shims; Kernel.dbg is also restricted by the allowlist.
Default Dune pure operations remain available, but every EvoGit module is intercepted before Base fallback and denied unless its exact MFA and tier appear in `DirectAPI`'s literal registry or compatible facade list.
Dune's generated `allow(..., only: [...])` entries select names rather than arities and initialize aliases only; the outer `fun_status/3` wrappers enforce exact arities and route admitted real APIs to fixed broker-backed shims, never arbitrary apply or namespace grants.
Both tiers initialize all admitted module aliases at Base load time, but write MFAs remain restricted in read tier.
`DirectAPI.help/0` generates the exact admitted signature lists plus examples, limits and deviations.
Public `ElixirEval.help/0` includes `DirectAPI.help/0` exactly once.
`Read.help/0` delegates to `Broker.call(:help, [])`, whose `execute(:help, [], _)` returns public `ElixirEval.help/0` without appending another direct-API section.
The restricted-operation hint names admitted TaskRegistry/AgentScheduler APIs and directs callers to `Read.help/0`, while retaining facade compatibility and explicit write approval without automatic escalation.
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

## Exact Direct API Admission
`DirectAPI` is the shared literal four-field MFA/tier registry, fixed native-call generator and help source; both allowlists consult it before any EvoGit fallback.
Read and write tiers admit exactly `EvoGit.TaskRegistry.list_tasks_page/0,1`, `get_task_lite/1`, `get_task/1`, `EvoGit.AgentScheduler.RemoteAPI.list_agents/0`, `EvoGit.AgentScheduler.get_config/1`, `paused?/0`, `get_llm_slot_status/0` and `EvoGit.Config.resolve/0,1` in addition to the compatible facades.
Only write tier additionally admits `EvoGit.TaskRegistry.start_task/2`, `cancel_task/1`, `force_kill_task/1`, `delete_task/1`, `EvoGit.AgentScheduler.update_config/1`, `pause/0`, `resume/0`, `EvoGit.Config.save_user_config/1` and `EvoGit.AgentScheduler.RemoteAPI.reload_config/0`.
Unlisted functions and wrong arities on listed modules are denied in both tiers, as are arbitrary EvoGit modules and direct access to broker/adapter internals; refusal never auto-escalates.
Generated Dune shims send literal MFA tokens to the authenticated broker, which independently checks exact admission, tier and arity before invoking the actual public function with unchanged arguments.
The trusted runtime task installs the captured TaskRegistry routing seam so actual TaskRegistry clients use the authenticated registry, not an evaluator-supplied destination.
No direct call uses facade projection, option validators, scalar normalization, self-target/status policies or substituted GenServer messages.
Direct get_task/get_task_lite return actual TaskInfo structs or nil, task pages retain real rows/totals, list_agents returns the actual full summary list and slot/configuration reads retain actual nested values without redaction.
Direct start returns the actual `{:ok, TaskInfo}` or API error, while enqueue is not execution success and delete's `:ok` still acknowledges only a queued cast, not persistence.
`get_config/1` preserves all actual key semantics, including nonscalar values and nil for unknown keys; `Config.resolve/1` accepts the real atom key or key-path list without a direct-specific key restriction.
`Config.resolve/0` returns normalized defaults plus user configuration, not live scheduler runtime overrides, and resolve/1 reads that same resolved configuration.
Direct `update_config/1` uses the actual option and return contract and remains runtime-only; pause/resume retain their separate scheduler transitions and turn caps affect future agent registrations.
`Config.save_user_config/1` validates, replaces the whole config.toml rather than patching, invalidates the read cache and returns actual `:ok` or `{:error, reason}`, without reloading the scheduler.
Preserve other settings by reading the full configuration, modifying only intended fields and saving the full map in the same approved call; saving a resolved map also materializes defaults.
Avoid concurrent editing because read-modify-save is not atomic and can overwrite another writer's changes.
Explicitly call `RemoteAPI.reload_config/0` after a successful save to apply reloadable scheduler settings and inspect its actual result; save success does not imply reload success.
Boot-only settings such as node/distribution configuration require a restart, not just reload.
Direct operations retain broker authorization/lifecycle checks, request/read/write/four-start quotas and engine execution/output limits, but use the actual API's own deadlines rather than facade one-second deadlines.
Direct reads charge one read and one accounting row per invocation, without facade collection-size bounds; task/configuration return values may contain sensitive data, and output caps are not redaction.
Unexpected raised/thrown/exited failures still pass through the broker's generic error boundary, and neither timeout nor lost authority rolls back committed side effects.
Compatible Read/Write facades retain their existing projections, validators, self-target policies, quota accounting and one-second runtime calls unchanged.
`RemoteAPI.save_user_config/1`, Config.user_config/0, schema/defaults APIs and all other unlisted MFAs remain excluded.

## Capabilities, Quotas and Mutations
Read exposes `help/0`, `system_info/0`, `list_tasks/0,1`, `get_task/1`, `list_agents/0`, `scheduler_status/0`, `model_profiles/0` and `configuration_status/0` through the broker.
Write exposes `start_task/2`, `cancel_task/1`, `force_kill_task/1`, `delete_task/1`, `guide/1,2` and `update_scheduler_config/1`, and requires a write- or sudo-tier broker.
`Read.configuration_status/0` returns exactly the live scheduler's `default_llm_max_concurrency`, `max_tool_concurrency`, `max_turns`, `max_turns_root` and `paused` scalars, using individual one-second single-key scheduler reads rather than fetching raw configuration, generation parameters or credentials.
Its five reads are not an atomic snapshot; malformed scalar values normalize to nil, and one invocation charges one read and one projected row.
`Validation.scheduler_options/1` accepts only a nonempty map of literal atom/string scheduler keys, rejects duplicate spellings and unknown keys without atom creation, and returns a normalized keyword list.
`Write.update_scheduler_config/1` accepts concurrency integers in 1..256 and turn-cap integers in 1..10000, or a standalone boolean `paused` option; numeric strings, floats, nil, empty maps and mixed paused/numeric updates are refused before mutation.
Numeric updates use the scheduler's existing `{:update_config, opts}` API, while standalone paused uses `:pause` or `:resume` so queued slot/agent transitions retain scheduler semantics.
Each call sends one mutation under a one-second deadline and revalidates original authority immediately before dispatch and after completion, charging one write from the existing sixteen-write budget.
An acknowledged update returns `%{status: :updated, scope: :runtime, persisted: false, settings: requested_settings}`; settings are the acknowledged requested values, not a per-model effective-capacity projection.
Changes never write config files, survive only until restart/reload or another runtime update, preserve scheduler concurrency floors and explicit peak hard-pause behavior, and turn caps apply to future agent registrations rather than rewriting live AgentState values.
Timeout or lost authority can occur after an effect committed, so errors do not imply rollback and a scheduler-call exit explicitly recommends inspecting configuration status before retrying.
Each evaluation permits at most 128 broker requests including IO, 32 reads, 500 charged projected rows, 16 writes and four task starts, with at most one pending runtime operation.
Facade row charging uses requested task-page limit, 100 for agent/model-profile reads and one for other reads, rather than counting actual returned rows; direct reads each charge one accounting row.
Runtime operations revalidate original authority before and after execution, and facade mutations revalidate again immediately before dispatch; facade registry calls use one-second deadlines, direct calls use their public API deadlines and broker IPC uses five seconds.
Facade task start accepts only literal genesis/evolve/reflect/extract_skills types and at most five distinct supported atom/string keys drawn from path, mode, objective, prompt, model_id and model_spec.
`Validation.start_options/2` accepts model_spec only as a map of at most three STRING keys drawn from provider_profile_id, model and reasoning_effort, with nonblank valid UTF-8 strings without NUL of at most 8,000 bytes per supplied value.
Explicit model_spec and legacy model_id selectors both validate against the FULL `EvoGit.Config.resolve/0` result through `EvoGit.Config.Schema.resolve_model_spec/2`, accepting only its tagged success and refusing its tagged error without inspecting resolved fields or exposing raw failure terms.
Accepted selectors are forwarded unchanged and add model_id_locked: true; an absent selector remains automatic and performs no model resolution.
Supplying both selectors is explicitly refused as ambiguous because this integration has no established runtime model_spec-precedence contract.
The shared Schema resolver is an integration dependency owned by the configuration node; until that API is present, explicit-selector execution cannot be verified and raises an undefined-function error rather than falling back to truncated Projection membership.
These restrictions apply only to `Write.start_task/2`; admitted direct `TaskRegistry.start_task/2` calls bypass facade validators and preserve actual arguments and API returns.
Start strings are nonblank valid UTF-8 without NUL and at most 8,000 bytes; non-reflect tasks require an absolute path of at most 1,024 bytes, existing except for genesis-new, while reflect rejects path.
Modes are genesis new/existing, evolve simple and reflect reflect; custom, merge/resume and foreign-repo options are not exposed, extraction rejects objective/prompt, and a valid explicit model selector adds `model_id_locked: true`.
Self-targeting mutations are refused; cancel permits pending/running, force-kill running/cancelling and delete completed/failed/cancelled tasks.
Deletion returns an explicit queued-cast acknowledgement, never a persisted-deletion guarantee, and submission failures instruct inspection before retrying because timeout does not prove absence of side effects.
Guides require a message of at most 2,000 bytes, an allowlisted local page, optional simple `#id` selector of at most 80 bytes and boolean dismissible flag.

## Projection and Output Contracts
Facade task reads retain only id, type, status, review_status, timestamps and agent_count.
The following projection rules apply to convenience facades, not admitted direct APIs, which retain actual return values as described above.
Facade task reads omit objective, opts, result, attachments, errors, usage, histories and credential fields.
Task pages default to limit 25/offset 0/status all, accept limit 1..50 and offset 0..10,000, and validate status against literal enums; task ids are 1..128 bytes of ASCII letters, digits, underscore or hyphen.
Facade agent listing projects five fields inside ETS without copying agent contexts and returns one unsorted page of at most 100 plus a continuation flag; direct RemoteAPI.list_agents/0 instead returns its actual list.
Scheduler status totals used/waiting/capacity across at most 100 model-slot entries and separately reads only paused, never the full scheduler configuration.
Model profiles return at most 100 id/model/concurrency projections; the underlying scheduler call still retrieves the profile list before projection.
System info exposes only OS enum, Elixir/OTP versions, UTC time and online scheduler count; unknown scalars normalize to nil and counts require nonnegative integers.
Render.text caps BYTES, preserves a valid UTF-8 prefix, copies short slices and includes `\n[output truncated]` inside the cap when space permits.
Render.term uses bounded inspection with limit 100, printable_limit at most 2,048, structs disabled and charlists rendered as lists.
Broker stdout accumulation honors the requested `max_output_bytes`, defaults to 16,384 and refuses caps over 65,536, so total captured stdout never exceeds that budget; the engine also caps combined stdout and result/error text to that same requested budget.
The broker is the single stdout enforcement point: an item larger than the remaining budget is truncated to it with `Render.text/2` (longest valid UTF-8 prefix, `\n[output truncated]` marker inside the cap when bytes were dropped) instead of failing, and a write with no remaining budget appends nothing and is a bounded no-op, so an oversized write never turns a successful evaluation into an error.
Dune IO.puts accepts arities one/two and IO.inspect one/two/three through IOShim, only for stdio; inspect options cannot request unbounded output, labels cap at 256 and each emitted item is rendered to at most 16,384 bytes plus newline before the broker applies its remaining-budget truncation.
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
Parent-owned direct API tests must distinguish actual structs/nested config/options/acknowledgements from convenience facade projections and establish exact-MFA/tier denial, quota boundaries, whole-file save without reload and explicit reload results.
The fixture's process-local ConfigDir override does not automatically reach the broker's independent trusted runtime Task, so persistence smoke tests need an isolated fixed config-dir seam restored by a synchronous suite rather than assuming tool-process dictionary inheritance.
Fully qualified facade calls are supported; Dune's default allowlist rejects `alias/1`, so short-alias examples must not rely on interpreted alias declarations.
