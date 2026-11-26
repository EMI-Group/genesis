# CONTEXT.md Scopes — Shared vs Local

Design record for the two-scope `CONTEXT.md`: one git-tracked file per directory whose body is split into a **Shared** part that the whole subtree inherits and a **Local** part that loads only for agents assigned to that directory.
This describes the feature as implemented.
Read this before changing `EvoGit.Core.ContextScope`, `EvoGit.Core.ContextNode.build_context/2`, the `read_context`/`edit_context`/`write_context` tool schemas, or `EvoGit.Agent.ContextMerge`.

## The problem

Ancestor inheritance has no depth bound: every agent is given the `CONTEXT.md` of every ancestor of its assigned node, so prompt size grows with how DEEP the agent sits rather than with what the agent actually needs.

This repository is the extreme case.
The root `./CONTEXT.md` is ~96 KB, and most of it — release and CI mechanics, the desktop updater, the measured test-parallelism policy, dependency security floors, the changelog tooling — is pure noise for an agent assigned to `./apps/evo_git/lib/evo_git/sandbox/`.
An agent either pays that cost on every turn or authors less useful context so the file stays small.

Splitting the tree more finely to shorten inheritance would be worse: the routing table is the point of the Context Tree, and a repository structure that exists to satisfy prompt assembly is a bad structure.

Two scopes keep ONE file per node — one git object to review, one place to author, no new file to discover — while decoupling "what any descendant must know" from "what an agent working HERE needs".
Nothing changes for a file that does not opt in.

## The marker and the split rule

The divider is the single literal line `<!-- genesis:local -->` on a line of its own; leading and trailing whitespace on that line is tolerated, and the FIRST occurrence in the file wins (a later identical line is ordinary text).

* Everything BEFORE the divider line is **Shared**: it applies to this node and to every descendant.
* Everything AFTER the divider line is **Local**: it is rendered only for an agent whose assigned node is this directory.
* The divider line itself is never content and is never rendered.

Headings stay free-form; the divider is the only structural requirement.
A file with no divider is entirely Shared and its Local part is empty — such a file renders byte-identically to before the feature existed.
A file whose divider is the first line is entirely Local, which is legal but means descendants inherit nothing from that node.

## Example file

`./apps/evo_git/CONTEXT.md`:

```markdown
# ./apps/evo_git — Core Runtime

## Intent
The agent runtime, scheduler, git adapter and persistence layer.

## API Surface
- `EvoGit.AgentScheduler` — slot management and dispatch.

## Constraints
- Tests default to `async: true`.

## Routing Table
- `./apps/evo_git/lib/evo_git/agent/` — the agent loop and tools.

<!-- genesis:local -->

## Local: Release checklist

- `mix release genesis` from the repo root; the vendored `rg`/`git` binaries must
  be present under `priv/vendor/<platform>/` first.
- Full-suite runs: `mix test` (~9 min) — schedule one before a release tag.
- Benchmark runs: `mix bench.io --iterations 20`.
```

The Shared half is what a subagent spawned at `./apps/evo_git/lib/evo_git/agent/` receives.
The Local half is what an agent assigned to `./apps/evo_git/` receives on top of it.

## Prompt assembly

`EvoGit.Core.ContextNode.build_context/2` builds the `# Context Tree` block stage by stage, in this order:

| Stage | Source | Rendered |
|-------|--------|----------|
| VCT global stage (`global/CONTEXT.md`) | `<data_dir>/vct/CONTEXT.md` | Shared only |
| Ancestor stage (`./CONTEXT.md` … the parent of the assigned node) | one per ancestor directory | Shared only |
| Assigned-node stage | the agent's own `node_path` | the WHOLE file: Shared + Local |

`EvoGit.Core.ContextScope` is the single source of truth for the split and the selection; `build_context/2` consumes it and nothing else re-implements it.
Inside one stage the order of operations is fixed:

1. select the scope region (Shared-only, or the whole file for the assigned node);
2. strip YAML front matter with `EvoGit.Skills.strip_front_matter/1` — front matter therefore belongs to the Shared part and is never visible to a Local selection;
3. skip the stage entirely when what remains is blank (no empty fenced block, and no stage at all when every stage is blank);
4. truncate at `[:truncation, :context_max_bytes]` (64 KB) — **per rendered stage**, with the UTF-8-safe `String.byte_slice/3` and the `... [Content Truncated] ...` marker.

Because Local is additive, the assembled prompt for an agent at a leaf is smaller than before, and the prompt for an agent at a node containing Local is larger than the Shared-only view of that same node — which is the intended asymmetry.

## Tool contract

`EvoGit.Agent.Tools.Context`:

| Tool | `scope` values | Default | Behaviour |
|------|----------------|---------|-----------|
| `read_context` | `"all"`, `"shared"`, `"local"` | `"all"` | returns the selected region of the target file |
| `write_context` | none | — | writes the whole file (Shared first, divider optional); no scope parameter |
| `edit_context` | `"shared"`, `"local"`, `"all"` | `"shared"` | exact-string replacement inside the selected region only |
| `search_context` | none | — | searches WHOLE files, so a match may come from either scope |

`edit_context` keeps its existing contract otherwise: `old_string` must be unique within the selected region, the unselected region and the divider survive untouched, `replace_all` behaves as before, and the amend-or-commit step is unchanged.
Asking for scope `"local"` on a file that has no divider is an error that tells the agent to add the divider rather than silently matching in the Shared region.

Access symmetry is deliberate:

* **Reads stay unrestricted** — an agent may read any directory's `CONTEXT.md`, and may deliberately read another node's Local guidance (`scope: "local"`) when that is what it needs.
* **Writes stay confined** to the agent's assigned subtree by `Shared.validate_file_scope/4`, with the divider introducing no exception: a Local edit is still an edit of that file, so the same node-scope check decides it.

## Authoring rules

Write Shared first, then the divider, then Local — the file reads top-down as "inherited, then mine".

* **Shared** holds what a descendant needs: intent, design principles, API surface, constraints, everyday test commands, and a short routing table.
* **Local** holds material for agents assigned to this directory only: release procedures, full-suite testing, benchmarking, node-specific operational notes, and detail from the parent-level index that would drown a leaf agent.
* **Never duplicate** a fact that belongs in Shared into Local. A fact needed by both sides is a Shared fact; duplicating it means two places to keep true.

## Edge cases and interactions

* **YAML front matter** (which also carries skill enablement, see `EvoGit.Skills`) is part of the Shared side. It is stripped AFTER scope selection, so it can never leak into a Local render and its presence never makes a Local selection error.
* **CRLF** files are handled: the divider is matched after trimming line whitespace, so a trailing `\r` does not defeat the split.
* **Divider as the first line** → empty Shared, everything Local. Descendants skip this node; the assigned agent gets the full file.
* **No divider** → whole file Shared, Local empty; byte-identical rendering to the pre-feature behavior. This is the compatibility guarantee that makes rollout safe.
* **Blank after selection** → the stage is skipped. A node that authored only Local guidance contributes nothing to its descendants, which is a legitimate choice but worth knowing when a descendant's prompt looks thin.
* **Truncation stays per stage.** A node's Local does not eat into an ancestor's budget, and a large Shared half is truncated on its own without touching the Local half of the assigned node.
* **Repo-less Assistant sessions** are assigned node `./`, so the root file's Local section IS included. That is intentional: the Assistant operates the running system, and the root Local section is exactly the release/ops detail it needs.

## Known limitation: merge resolution is still whole-file

`EvoGit.Agent.ContextMerge` resolves a `CONTEXT.md` conflict by whole-file node-path ownership: the owner of the node outranks an ancestor's edit, out-of-scope edits are dropped and reported, and equal ownership is never auto-picked.

The scopes are NOT reflected in that rule. So when a child rewrites its Local section while a parent rewrites its Shared section in the SAME file — the common case, and the very one scopes are meant to make routine — the child has an in-scope edit and the parent has an in-scope edit, and the merge either drops one side or reports a conflict that a human must resolve.
There is no structural (region-aware) merge yet.
Until there is, a wide-reaching Shared change should be coordinated rather than assumed to merge cleanly against concurrent Local edits.

## Non-goals

* No dashboard editor for scopes (the files are plain markdown; the workbench is not a context authoring surface).
* No per-section encryption or ACLs: Local is a prompt-assembly boundary, not a secrecy boundary. Any agent may read any Local section.
* No VCT-level scope: the global context level is Shared-only by construction, and `vct:///workspaces/…` has no file of its own.
* No automatic migration of existing files. Nothing rewrites a `CONTEXT.md` on boot, and no file without a divider changes behavior.

## Migrating an existing repository

1. Open the file that is doing too much — usually the root.
2. Move the paragraphs a leaf agent never needs (release, full-suite testing, benchmarking, CI, dependency policy, host-specific ops) below a `<!-- genesis:local -->` line.
3. Leave intent, principles, API surface, constraints, the everyday commands and the routing table above it.
4. Commit once. Files you do not touch keep rendering exactly as they do today.

A Local section on a parent reaches only agents assigned to that parent; descendants never see it.
So if a fact is needed by agents landing in a child directory, put it in that child's Shared section (or in the parent's Shared section when the whole subtree needs it) — not in the parent's Local section.

## Implementation map

* `apps/evo_git/lib/evo_git/core/context_scope.ex` — `EvoGit.Core.ContextScope`: the divider constant, the split, and the region selection.
* `apps/evo_git/lib/evo_git/core/context_node.ex` — `build_context/2` consuming it per stage.
* `apps/evo_git/lib/evo_git/agent/tools/context.ex` — the `scope` parameter on `read_context` / `edit_context`.
* `apps/evo_git/lib/evo_git/agent/context_merge.ex` — the whole-file conflict resolution described under Known limitation.
