# Introduction

This project is EvoGit 1.0, a novel approach to generating large-scale code repositories using a hierarchical approach. The goal is to create a system that can efficiently produce complex codebases by breaking down the generation process into manageable components.

## Components

### File Hierarchy

EvoGit is by design hierarchical. The repository structure is represented as a tree where:

A node represents a hierarchy level in the repository (either a directory or a file), and can have child nodes (subdirectories or files) and related metadata attributes attached directly to it. Think xml/HTML tree structure.

Therefore, each node is defined by the following attributes (in pseudo json):
```json
{
    "node_type": "directory" | "file",
    "name": "string",
    "children": [ list of child nodes ],
    "metadata": { key: value pairs },
    "context": "string" // additional context information for the Agent
}
```

The node_type indicates whether the node is a directory or a file.
The name is the name of the directory or file.
The children is a list of child nodes (empty for files).
The metadata is a dictionary of key-value pairs that can store additional information about the node.
The context is a string that provides additional information for the Agent to use during generation at this level and below. Generally speaking, the context is just a README-like description of what this part of the repo is about. For example, in the root node, the context might describe the overall purpose of the repository, while in a subdirectory node, it might describe the specific functionality or API provided by that subdirectory.

### Agent

An agent is basically a LLM + state + action.

- **LLM**: the language model used to generate content and make decisions.
- **state**: a tuple (commit_id, node_id). An agent's state is characterized by the commit id it's currently on (temporal) and the node id (spatial) within the repository structure.
- **action**: depends on the node type:
  - For directory nodes: The agent can only modify its own node or calling other child nodes to perform actions.
  - For file nodes: The agent can generate or modify the content of the file, or modify its own node (update metadata, context etc).

In EvoGit, we use agents in a functional programming style, meaning we do not think of agents as living objects that move around and change state. Instead, we think of them as functions that take in a state, and as described above, the state is simply a tuple (commit_id, node_id) and can be created on the fly.

When running a agent, it will:
1. Read the current state (commit_id, node_id).
2. Construct a context based on the **current node and all the ancestor nodes** up to the root.
3. Run the LLM with the constructed context and perform an action.

The second step is the core of EvoGit's hierarchical design, where the context is built by a `gather_context(node)` function.

In python-like pseudocode, it looks like this (some details omitted for clarity):

```python
def gather_context(node):
    if node.is_root():
        return node.context + info_fn(node.metadata)
    else:
        parent_context = gather_context(node.parent)
        return parent_context + "\n" + node.context + info_fn(node.metadata)
```

Then based on the gathered context and the task at hand, the agent can decide what to do next.

```python
def run_agent(state):
    context = gather_context(state.node)
    ...
    task_prompt = "Do XYZ"
    ...
    llm_output = LLM.generate(task_prompt + context)
    ...
    return new_state, action
```

## Code Guidelines

### Programming Style

The project itself is implemented in Python.
So while we say "functional programming style", we do not mean to use a purely functional programming language, but rather to follow functional programming principles in our code design.
This means:
- The Agent is implemented as a Class, but its methods are mostly pure functions that take in state (self) and return new state without side effects.
- The repository structure is represented as a tree of Node objects, where each Node has methods to manipulate its children and metadata in a functional way (returning new nodes instead of modifying existing ones).
- Use recursion where appropriate, especially for traversing the tree structure, so the code matches with our conceptual model.

### Git usage

The EvoGit system interacts with git repositories.
To manage git operations, we use a dedicated `git.py` module that encapsulates all git-related functionalities.
This module provides functions to initialize repositories, create commits, branch management, and other git operations.
Currently the git module uses git commands via subprocess calls, therefore the behavior should be exactly the same as the git CLI and easily understandable by humans.
