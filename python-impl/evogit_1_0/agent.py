"""This module defines the Agent class used in EvoGit."""


class Agent:
    def __init__(self, repository, commit_id, node_id):
        self.repository = repository
        self.commit_id = commit_id
        self.node_id = node_id
        self.node = self.repository.get_node(node_id)

    def _info_fn(self, metadata):
        """Helper to format metadata for context."""
        if not metadata:
            return ""
        return f"\nMetadata: {metadata}"

    def gather_context(self):
        """
        Constructs a context based on the current node and all the ancestor nodes
        up to the root.
        """
        # Recursive step: if not root, gather parent context first
        if self.node.is_root():
            return self.node.context + self._info_fn(self.node.metadata)
        else:
            # Create a temporary agent for the parent to reuse logic
            parent_agent = Agent(self.repository, self.commit_id, self.node.parent_id)
            parent_context = parent_agent.gather_context()
            return (
                parent_context
                + "\n---\n"
                + self.node.context
                + self._info_fn(self.node.metadata)
            )

    def _leaf_run(self):
        """
        Specialized run method for leaf nodes (files).
        """
        context = self.gather_context()

        # Placeholder for LLM call
        task_prompt = "Do XYZ"
        # llm_output = LLM.generate(task_prompt + context)
        file_content = f"[LLM Placeholder Output for context length {len(context)}]"

        # Return new state (tuple) and action
        # In a functional style, we return the state for the next step
        new_state = (self.commit_id, self.node_id)
        return new_state, action

    def _node_run(self):
        """
        Specialized run method for non-leaf nodes (directories).
        """
        pass

    def run(self):
        """
        Runs the agent: gathers context, calls LLM, and determines action.
        Returns a tuple of (new_state, action).
        """
        if self.node.node_type == "file":
            return self._leaf_run()
        else:
            return self._node_run()
