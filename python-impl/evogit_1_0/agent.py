"""This module defines the Agent class used in EvoGit."""

from hierarchy import Action
from pydantic import BaseModel
from typing import List
import json
import textwrap
from string import Template
from dataclasses import dataclass
from google.genai import types


class DirItem(BaseModel):
    dirname: str
    context: str


class DirStruct(BaseModel):
    items: List[DirItem]


class LeafDirItem(BaseModel):
    filename: str
    abstract: str


class LeafDirStruct(BaseModel):
    items: List[LeafDirItem]


@dataclass
class LLMRequest:
    config: types.GenerateContentConfig
    content: str  # here we only need a single string


# --- Prompts and Templates ---

common_sys_prompt = """
You are a coding agent responsible for doing one task in a large codebase.
You have access to:
1. the overall project guideline that outlines the coding standards and requirements.
2. the context of the file (or directory), including the file itself and all the parent directories to the root.
3. the level (depth) of the file in the project hierarchy.

The project guideline will describe the guide / bound / constraints you should follow for different levels of the hierarchy.
The level is 0-indexed, with 0 being the root directory matching the top-level hierarchy node in the project guideline.

You should only return the raw code or the content user requested, without any explanations or wrapper text, like ``` marks.
"""

LEAF_PROMPT_TEMPLATE = Template(
    textwrap.dedent("""
    Currently, you are working at level ${level} in the project hierarchy, directly writing a file.
    Please generate the complete content for the file based on the project guideline and the context provided.
    Please refer to the leaf file's purpose described above for detailed task information.
    Give the raw file content as the output.
""")
)

PENULTIMATE_PROMPT_TEMPLATE = Template(
    textwrap.dedent("""
    Currently, you are working at level ${level} in the project hierarchy.
    Please create the leaf file structure based on the project guideline and the context provided.
    Please refer to the guideline and context for detailed task information at this level.
    Output the filenames and their abstracts in JSON format as specified:
    {
        "items": [
            {
                "filename": "name_of_file",
                "abstract": "A brief description of the file's purpose (header comments)"
            },
            ...
        ]
    }
""")
)

NODE_PROMPT_TEMPLATE = Template(
    textwrap.dedent("""
    Currently, you are working at level ${level} in the project hierarchy.
    Please create the next level directory structure based on the project guideline and the context provided.
    Please refer to the guideline and context for detailed task information at this level.
    Output the direction names and their context in JSON format as specified:
    {
        "items": [
            {
                "dirname": "name_of_directory",
                "context": "A README.md file inside that directory describing its purpose"
            },
            ...
        ]
    }
""")
)

INIT_ROOT_TEMPLATE = Template(
    textwrap.dedent("""
    You are initializing the root of a new project based on the following project guideline:
    ${guideline}
    Please give the detailed design document for the project at the root level.
    Output the content in raw markdown format.
""")
)


# --- Agent Class ---


class Agent:
    def __init__(self, project, commit_id, path):
        self.project = project
        self.commit_id = commit_id
        self.path = (
            path  # current node path in the hierarchy, also act as the unique ID
        )
        self.node = self.project.get_node(path)

    def gather_context(self):
        """
        Constructs a context based on the current node and all the ancestor nodes
        up to the root.
        """
        # Recursive step: if not root, gather parent context first
        if self.node.is_root():
            return self.node.context

        # Create a temporary agent for the parent to reuse logic
        parent_agent = Agent(self.project, self.commit_id, self.node.parent_id)
        parent_context = parent_agent.gather_context()
        return parent_context + "\n---\n" + self.node.context

    def _leaf_step1(self):
        """
        Specialized run method for leaf nodes (files).
        """
        context = self.gather_context()
        task_prompt = LEAF_PROMPT_TEMPLATE.substitute(level=self.node.level)

        request = LLMRequest(
            config=types.GenerateContentConfig(
                system_instruction=common_sys_prompt,
            ),
            content=context + "\n---\n" + task_prompt,
        )
        return request

    def _penultimate_step1(self):
        """
        Specialized run method for penultimate nodes (directories whose children are files).
        """
        context = self.gather_context()
        task_prompt = PENULTIMATE_PROMPT_TEMPLATE.substitute(level=self.node.level)

        request = LLMRequest(
            config=types.GenerateContentConfig(
                system_instruction=common_sys_prompt,
                response_mime_type="application/json",
                response_json_schema=LeafDirStruct.model_json_schema(),
            ),
            content=context + "\n---\n" + task_prompt,
        )
        return request

    def _node_step1(self):
        """
        Specialized run method for non-leaf nodes (directories).
        """
        context = self.gather_context()
        task_prompt = NODE_PROMPT_TEMPLATE.substitute(level=self.node.level)

        request = LLMRequest(
            config=types.GenerateContentConfig(
                system_instruction=common_sys_prompt,
                response_mime_type="application/json",
                response_json_schema=DirStruct.model_json_schema(),
            ),
            content=context + "\n---\n" + task_prompt,
        )
        return request

    def step1(self):
        """
        Runs the agent: gathers context, and return the request to be made.
        """
        if self.node.level + 1 == self.project.max_depth:
            return self._leaf_step1()
        elif self.node.level + 2 == self.project.max_depth:
            return self._penultimate_step1()
        else:
            return self._node_step1()

    def _leaf_step2(self, response):
        # leaf node will not expand further
        return Action(type="addcontent", path=self.node.path, data=response)

    def _penultimate_step2(self, response):
        # penultimate node, will expand to leaf files
        items = json.loads(response).get("items", [])
        actions = []
        for item in items:
            actions.append(
                Action(
                    type="newfile",
                    path=f"{self.node.path}/{item['filename']}",
                    data=item["abstract"],
                )
            )

        return actions

    def _node_step2(self, response):
        # non-leaf node, will expand to n children
        items = json.loads(response).get("items", [])
        actions = []
        for item in items:
            actions.append(
                Action(
                    type="mkdir",
                    path=f"{self.node.path}/{item['dirname']}",
                    data=item["context"],
                )
            )

        return actions

    def step2(self, response):
        """
        Get the response from the LLM and convert it into an Action.
        """
        if self.node.level + 1 == self.project.max_depth:
            return self._leaf_step2(response)
        elif self.node.level + 2 == self.project.max_depth:
            return self._penultimate_step2(response)
        else:
            return self._node_step2(response)

    def init_step1(self):
        """Special case for initializing the root node.
        Create the root directory along side the project's README.md file.
        """
        # there is no parent context for root
        task_prompt = INIT_ROOT_TEMPLATE.substitute(guideline=self.project.guideline)

        request = LLMRequest(
            config=types.GenerateContentConfig(
                system_instruction=common_sys_prompt,
            ),
            content=task_prompt,
        )
        return request

    def init_step2(self, response):
        """Special case for initializing the root node."""
        action = Action(
            type="init",
            path="",  # root directory
            data=response,
        )
        return action
