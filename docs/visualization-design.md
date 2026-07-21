# Genesis Visualization Design: "The Bloom"

## Problem

Genesis's core innovation — **recursive hierarchical delegation with parallel isolated execution** — is invisible. When a genesis run completes, all we have is a flat JSON list of agent records and a commit history. Neither captures the recursive process that makes Genesis unique.

Existing visualization tools (Gource, Code City, Sunburst trees) all fail for the same fundamental reason: **Genesis has TWO trees, and these tools can only show one.**

| Tool | Shows | Misses |
|------|-------|--------|
| **Gource** | Flat actor→file changes over time | The recursive agent hierarchy; cannot express "Manager A spawned Executor B who spawned Executor C" |
| **Code City** | Static directory/file structure | The process — who built what, through what delegation chain, in what order |
| **Sunburst / Radial Tree** | Directory hierarchy | The agent delegation tree is a *different* tree from the directory tree |
| **Git graph tools** | Commit DAG (temporal) | Agent hierarchy, directory structure, parallelism |

The two trees are:

1. **The Agent Delegation Tree** (process): Root agent → managers → sub-managers → executors. This is recursive, hierarchical, and transient.
2. **The Directory Tree** (artifact): `src/` → `src/auth/` → `src/auth/oauth/`. This is spatial, persistent, and the output.

The visualization must show BOTH trees, their interaction, and their evolution over time. No existing tool does this — because no other system HAS the agent delegation tree as a first-class concept.

## Core Insight: Recursive Parallelism as Visual Narrative

Genesis's defining characteristic is not that "code was written" — it's HOW the code was written:

1. A root agent plans the architecture
2. It spawns child agents for subdirectories
3. Each child can spawn its own children
4. Siblings run in PARALLEL in isolated worktrees
5. This recurses to arbitrary depth

This is a **fractal process** — the same pattern repeats at every level. The visualization should make this fractal nature immediately visible.

## The Bloom: Animated Organic Fractal Tree

### Metaphor

A **plant growing in fast-forward**. The "plant" is the agent delegation tree. The "leaves" are files created. The growth pattern reveals the recursive structure.

### Visual Elements

**Agent Nodes** (circles/hexagons):
- **Size** ∝ contribution (tokens × files created)
- **Color** encodes agent type: CodebaseLead (gold), Manager (blue), Executor (green), Investigator (purple), TaskScheduler (teal)
- **Inner glow** = agent is currently active (bright pulsing = working, dim = waiting, solid = complete)
- **Halo ring thickness** ∝ depth level

**Delegation Edges** (curved bezier lines):
- Connect parent → child agent
- Pulse along the edge when the child is spawned
- Thickness ∝ child's contribution

**File Leaves** (small colored dots/particles):
- Appear at agent nodes when files are created
- Color by file type: `.ex` (green), `.exs` (blue), `.md` (gold), `.html` (orange), `.json` (silver)
- A "bloom" particle burst when an agent completes
- Leaves cluster around the agent that created them

**Layout**:
- Root agent at bottom-center
- Children radiate upward and outward in a force-directed layout
- Agents working in the same directory cluster together spatially
- Depth loosely maps to vertical position (deeper = higher in the tree)

### Animation: The Narrative Arc

The visualization replays the entire genesis run as an accelerated time-lapse. Key moments:

1. **"The Seed"** (t=0): A single glowing gold node appears — the root CodebaseLead. It pulses as it plans. Label overlay: "Architecture Phase."

2. **"The Roots"** (architecture): The root spawns child CodebaseLeads for subdirectories. Skeleton branches form. Gold `.md` leaves appear — CONTEXT.md files are being created. This phase has fewer agents, deeper thinking, longer pulses.

3. **"The Branch"** (first Manager delegation): A blue Manager node appears, spawned by a CodebaseLead. This is the moment the recursive pattern becomes visible — a branch point that will itself spawn sub-branches.

4. **"The Bloom"** (implementation explosion): A SUDDEN burst of activity. Multiple green Executor nodes appear simultaneously across different branches. The tree lights up with parallel activity — 10, 15, 20+ agents pulsing at once. Files bloom as colored leaves in rapid succession. This is the "aha" moment. Label overlay: "Implementation Phase — Parallel Execution."

5. **"The Harvest"**: Activity winds down. Final leaves appear. The tree solidifies. Stats overlay fades in: "47 agents, 128 files, 3.2M tokens, 4 minutes wall-clock."

### Interaction (Interactive Version)

- **Hover** any node → tooltip: agent objective, assigned directory, files created, tokens used, duration
- **Click** a node → highlight its entire subtree (show "span of control"); dim everything else
- **Trace path** from leaf to root → animated highlight showing the full delegation chain: Executor → Manager → CodebaseLead → Root
- **Time scrubber** → drag to any point in the run
- **Speed control** → 1×, 2×, 5×, 10×, 50×, "instant"
- **Filter** by agent type, directory, depth level
- **Export** current view as PNG/SVG; export full animation as WebM/GIF

### Dual-Tree Mode (Advanced)

A toggle switches between two synchronized views side by side:

**Left Panel — The Agent Tree**: The fractal delegation hierarchy described above. The PROCESS view.

**Right Panel — The Directory Tree**: A growing sunburst/treemap of the codebase. Sectors appear as directories are created; files appear as inner arcs. Color links each file back to the agent that created it. The ARTIFACT view.

**Synchronization**: Hover an agent on the left → the files it created light up on the right. Hover a directory on the right → the agents that built it highlight on the left. This directly demonstrates Genesis's core architecture: the Spatial Dimension mapped onto the recursive agent model.

### Why This Works as a World-Class Demo

1. **Reveals the invisible**: The recursive delegation pattern is Genesis's innovation. Currently it's buried in JSON. The Bloom makes it the STAR.

2. **Immediately graspable**: Everyone understands "a tree growing." In 5 seconds, a viewer understands: agents spawn subagents, files appear, parallel branches grow simultaneously.

3. **Hypnotic to watch**: A time-lapse of a complex system self-assembling is inherently compelling. The parallel bursts create a spectacular visual rhythm that holds attention.

4. **Shareable**: A 2-3 minute screen capture works perfectly for Twitter, conference talks, and demo reels. Requires zero explanation — the visual tells the story.

5. **Honest to the system**: Unlike Gource (which would misrepresent Genesis as flat peer agents), the Bloom accurately represents the recursive hierarchical delegation that actually happens.

## Data Requirements

### What We Have (from archive records)

| Field | Use |
|-------|-----|
| `agent_id`, `parent_id`, `depth` | Build the delegation tree |
| `started_at`, `completed_at` | Timeline, duration, parallelism detection |
| `base_commit`, `final_commit` | Compute file diffs post-hoc |
| `objective`, `result` | Tooltip content |
| `usage` (tokens, cost) | Node sizing, stats |
| `repo_root` | Git operations for diff computation |

### What We Need to Add (~10 lines in `complete_task.ex`)

Two fields exist in `AgentState` / `AgentSpec` at runtime but aren't threaded into archive records:

1. **`agent_type`** — derived from `spec.agent_module` (e.g., `EvoGit.Agents.Manager` → `"manager"`). Used for node color-coding.

2. **`context_node_path`** — from `agent_state.context_node.path` (e.g., `"./src/auth/"`). Used for spatial clustering and the dual-tree directory mapping.

**Code change** (in `tool_dispatch.ex` around line 627 and `complete_task.ex` around line 156):

In `tool_dispatch.ex`, add to the opts list passed to `CompleteTask.complete/4`:
```elixir
agent_type: agent_type_from_module(spec.agent_module),
context_node_path: agent_state.context_node.path
```

In `complete_task.ex`, add to the data map passed to `write_archive_refs/5`:
```elixir
agent_type: Keyword.get(opts, :agent_type),
context_node_path: Keyword.get(opts, :context_node_path)
```

And in the record map (line 295), add:
```elixir
agent_type: data[:agent_type],
context_node_path: data[:context_node_path]
```

### Post-Hoc Computation (in the visualizer)

For each archive record, compute the file list:
```bash
git -C <repo_root> diff --numstat <base_commit> <final_commit>
```
Parse into `[{path, additions, deletions}]`. Group by directory to establish agent→directory mapping.

## Implementation Plan

### Phase 1: Data Enhancement (in Genesis repo)

- Add `agent_type` and `context_node_path` to archive records
- Estimated: 1-2 hours, ~10 lines changed
- Files: `tool_dispatch.ex`, `complete_task.ex`

### Phase 2: Standalone Visualizer

Build as a **single HTML file** that loads the JSON export — no build step, no server. Can be opened directly in a browser or embedded in the dashboard via iframe.

**Technology**: D3.js (force simulation + SVG rendering) + Canvas (for particle effects if needed). Pure client-side. No backend.

**Core modules**:
1. **Data loader**: Parse JSON export, build agent tree, compute diffs (via in-browser git wasm or pre-computed)
2. **Layout engine**: Force-directed graph with depth bias (root at bottom, children above)
3. **Animation loop**: RequestAnimationFrame-based time-lapse replay with speed control
4. **Renderer**: SVG for agent nodes and edges; Canvas overlay for particle effects (file blooms)
5. **Interaction layer**: Hover, click, scrub, filter

**Fallback for diff computation**: If in-browser git is impractical, add a small Elixir script (`mix visualize.export <task_id>`) that pre-computes file lists and emits enriched JSON.

### Phase 3: Dashboard Integration (optional)

Embed the visualizer as a new "Visualization" tab on the task detail page. Since it's a standalone HTML page, integration is trivial — use an iframe or port the D3 code into a LiveView hook.

## Alternative Considered: 3D Galaxy (Three.js)

A 3D version where agents are stars, delegations are orbital paths, and the system forms a galaxy over time. New stars ignite when agents spawn, brighten when active, and cluster by directory.

**Pros**: Visually spectacular. The "galaxy forming" metaphor captures emergent complexity.  
**Cons**: Harder to read precise information. More complex implementation. Worse for static screenshots. The tree metaphor maps more directly to the recursive structure.

**Recommendation**: Build the 2D Bloom first. Add a 3D "Galaxy Mode" as a stretch goal — the same data supports both layouts.

## Demo Video Script (2-3 minutes)

```
[0:00-0:15]  TITLE CARD
             Dark background. "Genesis: Recursive Codebase Generation."
             Fade to the Bloom visualization, paused at t=0.

[0:15-0:45]  THE GROWTH (10× speed)
             Play the full genesis run. The tree grows from a single
             seed into a complex branching structure. Files bloom as
             colored particles. Multiple branches grow simultaneously.
             No narration — the visual tells the story.

[0:45-1:30]  THE INTERACTION (1× speed)
             Slow down. Hover agents to show objectives and stats.
             Click an agent to highlight its subtree — show the
             "span of control" from a Manager to its Executors.
             Trace a delegation chain from leaf to root.
             Toggle to dual-tree mode: agent tree ↔ directory tree.

[1:30-2:00]  THE STATS
             Overlay: "47 agents. 8 Managers. 32 Executors.
             4 CodebaseLeads. 3 Investigators. Max depth: 4.
             Peak parallelism: 15 agents. 128 files. 3.2M tokens.
             4 minutes wall-clock."

[2:00-2:30]  THE CONTRAST
             Side-by-side: same genesis run in Gource vs. the Bloom.
             Gource shows a flat particle cloud — who touched what file.
             The Bloom shows the recursive hierarchy — who delegated to whom,
             what ran in parallel, how the codebase self-assembled.
             "This is not just what Genesis built. It's how Genesis thinks."

[2:30-3:00]  CLOSING
             Fade to logo. "Genesis. Recursive software evolution."
```

## Summary

| Question | Answer |
|----------|--------|
| **What to visualize?** | The agent delegation tree (process) mapped to the directory tree (artifact), animated over time |
| **Why is this unique?** | No existing tool shows recursive hierarchical delegation with parallelism — because no other system HAS it |
| **What metaphor?** | Organic growth — a fractal tree that grows, branches, and blooms |
| **What tech?** | D3.js force-directed graph + Canvas, standalone HTML, consuming the JSON export |
| **What data gap?** | Add `agent_type` and `context_node_path` to archive records (~10 lines in `tool_dispatch.ex` + `complete_task.ex`) |
| **What's the "aha" moment?** | The implementation phase explosion — 15+ agents pulsing simultaneously as files bloom across the tree. Watching the recursive pattern emerge in real time reveals Genesis's architecture in a way no static diagram ever could. |
