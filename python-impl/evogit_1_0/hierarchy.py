"""This module defines the Hierarchy (a tree structure) used in EvoGit."""

from pygit2 import Repository, Signature
import os
from pathlib import Path

from .header_comment import format_header_comment


ATTR_FILES = ["README.md"]


def nested_level(path: Path) -> int:
    """Compute the nested level of a given path.
    Must be a relative path to the repository root."""
    # Special case: root itself → level 0
    if path == Path("."):
        return 0

    # Count parts
    return len(path.parts)


class Node:
    """A node in the repository hierarchy tree.
    It maps to a directory (with a readme file) or a file in the git repository.
    """

    def __init__(
        self,
        project,
        path,
        context=None,
        metadata=None,
        level=None,
    ):
        # pointer to the project object, which manages the whole repo
        self.project = project
        if isinstance(path, str):
            path = Path(path)
        # path of the node in the repository, also serves as unique ID
        self._path = path
        self.level = nested_level(path)

    @property
    def name(self):
        return self._path.name

    @property
    def node_type(self):
        if self._path.is_dir():
            return "directory"
        elif self._path.is_file():
            return "file"
        else:
            raise ValueError("Path is neither a file nor a directory.")

    @property
    def parent(self):
        if self.is_root():
            raise ValueError("Root node has no parent.")
        return self.project.get_node(self._path.parent)

    @property
    def children(self):
        if self.node_type != "directory":
            raise ValueError("Only directory nodes can have children.")
        children = []
        for child_path in self._path.iterdir():
            if child_path.name in ATTR_FILES:
                continue  # skip README.md files, they are considered as attributes of the directory node
            children.append(self.project.get_node(child_path))
        return children

    def is_root(self):
        return self._path == Path(".")

    def is_leaf(self):
        return self.node_type == "file"


class Action:
    """Represents an action taken by the agent that modifies the repository."""

    def __init__(self, type, path, data):
        assert type in ("init", "mkdir", "newfile", "addcontent"), "Invalid action_type"
        self.type = type
        self.path = path  # file or directory path
        self.data = data  # e.g., file content, etc


class Project:
    """A collection of nodes representing a repository hierarchy.
    Provide methods to add and retrieve nodes by their IDs,
    so we don't have to traverse the entire tree each time.
    It also manages the on-disk git repository, mapping the file structure to nodes.
    """

    def __init__(self, max_depth, path, name, email):
        self.max_depth = max_depth  # maximum depth of the hierarchy
        self.path = path  # path to the git repository
        self.name = name
        self.email = email
        self.author = Signature(name, email)
        # because we are only doing incremental commits, author and committer are the same
        self.committer = Signature(name, email)
        self._nodes = {}
        self.repo = Repository(path)
        self.add_node("")

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

    def _init(self, doc):
        """Initialize the project repository with a root directory (if needed) and a README file."""
        os.makedirs(self.path, exist_ok=True)
        readme_path = os.path.join(self.path, "README.md")
        with open(readme_path, "w") as f:
            f.write(doc)
        # add and commit the changes to git via pygit2
        self.repo.index.add(readme_path)
        self.repo.index.write()
        # set the context of the root node
        root_node = self.get_node("")
        return root_node

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

        # also add the node
        # README.md is considered as the `context` attribute of the directory node
        # so it is not added as a separate node
        return self.add_node(path)

    def _newfile(self, path, abstract):
        """Add a file with the specified abstract about its content.
        The abstract is a high-level description of what the file should contain.
        For example, a module docstring in Python, a comment before DOCTYPE in HTML, a file header comment in C, etc.
        """
        # create the file with the abstract as a comment
        header_comment = format_header_comment(abstract, path)
        with open(path, "w") as f:
            f.write(header_comment)
        # add and commit the changes to git via pygit2
        self.repo.index.add(path)
        self.repo.index.write()

        return self.add_node(path)

    def _addcontent(self, path, content):
        """Append content to an existing file at the given path.
        This will actually write the main content to the file.
        """
        with open(path, "a") as f:
            f.write(content)
        # add and commit the changes to git via pygit2
        self.repo.index.add(path)
        self.repo.index.write()
        return self.get_node(path)

    def perform(self, action):
        """Commit the action: 1. apply changes to the repository 2. create a git commit."""
        if isinstance(action, list):
            # pattern matching a list of actions
            for act in action:
                # recursively perform each action
                self.perform(act)

        if not isinstance(action, Action):
            raise ValueError(
                "Action should be a Action instance, or a list of Action instances."
            )

        # Placeholder for actual git commit logic
        if action.type == "init":
            self._init(action.data)
        elif action.type == "mkdir":
            self._mkdir(self.path, self.data)
        elif action.type == "newfile":
            self._newfile(self.path, self.data)
        elif action.type == "addcontent":
            self._addcontent(self.path, self.data)

        self._commit(f"Performed action: {action.type} on {action.path}")

    def add_node(self, path, exist_ok=True):
        if isinstance(path, str):
            path = Path(path)
        if not exist_ok and path._path in self._nodes:
            raise ValueError(f"Node at path {path} already exists.")
        node = Node(path, project=self)
        self._nodes[path._path] = node
        return node

    def get_node(self, path):
        if isinstance(path, str):
            path = Path(path)
        # the path is the unique ID
        return self._nodes.get(path._path)
