"""This module defines the Hierarchy (a tree structure) used in EvoGit."""

from pygit2 import Repository, Signature
import os


class Node:
    def __init__(
        self,
        node_id,
        node_type,
        name,
        context="",
        metadata=None,
        parent_id=None,
        level=None,
    ):
        self.node_id = node_id  # unique identifier for the node
        self.node_type = node_type  # "directory" or "file"
        assert node_type in ("directory", "file"), (
            "node_type must be 'directory' or 'file'"
        )
        self.name = name  # i.e., filename or directory name
        self.context = context
        self.metadata = metadata if metadata is not None else {}
        self.parent_id = parent_id  # id pointer to parent node
        if level is None:
            self.level = self.calc_level()
        else:
            self.level = level  # depth in the tree
        self.children = []  # List of child node_ids

    def is_root(self):
        return self.parent_id is None

    def calc_level(self):
        """Calculate the level of the node based on its parent."""
        if self.is_root():
            return 0
        else:
            # This method assumes that the parent node's level is already set
            return self.parent.level + 1


class Action:
    """Represents an action taken by the agent that modifies the repository."""

    def __init__(self, action_type, path, data):
        self.action_type = action_type
        assert action_type in ("mkdir", "newfile", "addcontent"), "Invalid action_type"
        self.path = path  # file or directory path
        self.data = data  # e.g., file content, etc

    def commit(self, repository, commit_message):
        """Commit the action: 1. apply changes to the repository 2. create a git commit."""
        # Placeholder for actual git commit logic
        if self.action_type == "mkdir":
            self._mkdir(self.path, self.data)
        elif self.action_type == "newfile":
            self._newfile(self.path, self.data)
        elif self.action_type == "addcontent":
            self._addcontent(self.path, self.data)


class Project:
    """A collection of nodes representing a repository hierarchy.
    Provide methods to add and retrieve nodes by their IDs,
    so we don't have to traverse the entire tree each time.
    It also manages the on-disk git repository, mapping the file structure to nodes.
    """

    def __init__(self, path, name, email):
        self.path = path
        self.name = name
        self.email = email
        self.author = Signature(name, email)
        self.committer = Signature(
            name, email
        )  # for simplicity, use the same as author
        self._nodes = {}
        self.repo = Repository(path)

    def _commit(self, message):
        """Create a git commit with the given message.
        Currently it does not support signatures.
        """
        ref = self.repo.head.name
        parents = [self.repo.head.target]
        tree = self.repo.index.write_tree()
        self.repo.create_commit(
            ref, self.author, self.committer, message, tree, parents
        )

    def _mkdir(self, path, doc):
        """Create a directory at the specified path.
        The doc is a high-level description of the directory's purpose.
        For example, a README.md file describing the directory's contents placed inside the directory.
        """
        # create the directory
        os.makedirs(path, exist_ok=True)
        # create a README.md file with the doc content
        readme_path = os.path.join(path, "README.md")
        with open(readme_path, "w") as f:
            f.write(doc)

        # add and commit the changes to git via pygit2
        self.repo.index.add(readme_path)
        self.repo.index.write()

    def _newfile(self, path, abstract):
        """Add a file with the specified abstract about its content.
        The abstract is a high-level description of what the file should contain.
        For example, a module docstring in Python, a comment before DOCTYPE in HTML, a file header comment in C, etc.
        """

    def _addcontent(self, path, content):
        """Append content to an existing file at the given path.
        This will actually write the main content to the file.
        """

    def add_node(self, node):
        self._nodes[node.node_id] = node

    def get_node(self, node_id):
        return self._nodes.get(node_id)
