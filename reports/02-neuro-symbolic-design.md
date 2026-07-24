## 1. Philosophy: The Neuro-Symbolic Design

The current AI-assisted programming landscape is rich. Tools like GitHub Copilot, Cursor, Cline, Aider, Devin (Cognition AI), and research systems like SWE-agent have moved far beyond simple "prompt → code" generation. They integrate deeply with developer workflows: file systems, LSP-based code intelligence, terminal access, browser automation, Git history, and structured tool protocols like Anthropic's Model Context Protocol (MCP). The ReAct loop (Yao et al., 2023) — reason, act, observe, repeat — is the de facto architecture: the LLM reasons about the task, invokes tools (read file, run test, search code), observes the results, and iterates. This is "vibe coding" in practice: describing intent in natural language and watching the AI manifest code. On benchmarks like SWE-bench (Jimenez et al., 2024), state-of-the-art systems now resolve a significant fraction of real-world GitHub issues.

But beneath the sophistication of these tools lies a surprisingly simple loop. The ReAct pattern — however augmented with better tools, better prompts, or better models — is fundamentally a flat, memoryless iteration: (1) serialize state into a prompt, (2) ask the LLM what to do, (3) execute the chosen tool, (4) repeat. There is no deep symbolic model of the codebase being modified. The "state" is whatever fits in the context window. There is no persistent hierarchical understanding — the agent doesn't know that `src/auth/oauth/` is a child of `src/auth/` with inherited constraints. There is no mathematical notion of progress or convergence — the agent just keeps looping until it runs out of budget or declares success. When it fails, it fails silently, often producing plausible-looking but incorrect code. The symbolic layer in these tools is shallow: a tool dispatcher, a file system, and a Git wrapper. There is no structural verification, no fixed-point check, no guarantee that the implementation matches the intent.

This shallow symbolic scaffold makes current tools brittle for autonomous, large-scale software engineering:

1. **The Context Window Bottleneck (Reframed):** Current tools pack all relevant state into a flat context window. As the codebase grows, the agent must either omit critical context (losing awareness of distant dependencies and architectural constraints) or exceed the window. The ReAct loop has no mechanism for hierarchical abstraction — every detail competes for attention at the same level.

2. **Error Compounding Without Convergence:** Without a mathematical notion of progress, errors compound. A hallucinated API call or a type mismatch breaks the build. In a flat ReAct loop, there is no structural guarantee that the system moves toward correctness — it just keeps sampling and hoping. The agent may fix one bug while introducing two more, with no way to verify that the overall state is improving.

Genesis addresses this by taking the neuro-symbolic architecture seriously — building a *deep* symbolic scaffold rather than a shallow one. Like current tools, it uses LLMs as the "neuro" component for pattern recognition, code generation, and natural language understanding. But unlike them, it embeds this within a principled symbolic framework:

- **Hierarchical decomposition (the Context Tree):** The codebase is organized as a rooted tree where each node carries a CONTEXT.md — a formal summary declaring intent, API surface, and constraints. Parent agents do not read child code; they read child summaries. This is hierarchical abstraction: each level only needs to know what its children *promise* to do, not how they do it. No flat context window can match this.

- **Temporal evolution with convergence guarantees:** The Phylogenetic Graph (Git DAG) models evolution. Each commit is a measurable improvement over its parent. The system iterates toward a fixed point where the implementation matches the specification at every level — a mathematical notion of "done" that flat ReAct loops lack.

- **Persistent spatial and temporal memory:** Memory lives in the Context Tree (spatial) and Git history (temporal) — not in a volatile context window. Agents are stateless functions that read from and write to these persistent structures.

- **Deterministic symbolic verification:** The runtime enforces invariants deterministically — spatial authority (agents can only write within their assigned node), tool budgets, sandboxing. The symbolic layer doesn't just dispatch tools; it *governs* the entire process.

The rest of this paper formalizes this architecture: the fixed-point mathematics (Section 2), the spatial and temporal dimensions (Section 3), the agent delegation model (Sections 4–5), and the implementation (Section 6).

---
