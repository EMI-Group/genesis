# Agent Persona and Callback Tests

## Intent
This directory tests built-in role delegation contracts and custom-agent callbacks with async-safe ExUnit suites.

## API Surface
- `executor_test.exs` pins the Executor's Investigator-only delegation set and its externally available subagent tool name.
- `custom_test.exs` covers custom definition lookup, prompt and role callbacks, subagent resolution, alias-aware tool whitelists and absence of a completion tool.
- `prompt_subagent_names_test.exs` audits concrete `subagent_*` names in built-in system prompts, including SelfReflective, against actual delegation schemas and explicit planning-reference exceptions.

## Constraints
All three suites use `async: true`, and custom-agent tests isolate configuration through the per-process ConfigDir helper.
This directory has no Assistant evaluator or direct-runtime-API authorization assertions, and its SelfReflective coverage is limited to prompt/subagent-name consistency.
Assistant persona and public evaluation contracts are covered by the parent directory's `self_reflective_tools_test.exs`, while evaluator execution coverage belongs to the sibling `agent/tools/` subtree.

## Routing Table
There are no child subdirectories.
