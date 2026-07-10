defmodule EvoGit.Agent do
  @moduledoc """
  An agent session loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`

  The agent's worktree path is fixed for the agent's entire lifetime. It is set
  once by the scheduler via `Process.put(:repo_path, ...)` before the agent task
  starts, read at startup, and stored in `LoopState.repo_path`. It never changes.

  Scheduling metadata (status, worktree assignment, parent tracking) lives in
  a separate `:evogit_sched_meta` table owned by the scheduler — agents never
  read or write that table.

  ## Prompting Rules
  - **System Prompt:** Used STRICTLY to define the agent's behavior, rules, and persona.
    It must not contain the objective or the context tree.
  - **User Prompt:** The framework automatically injects the current Context Tree and
    the user's objective (the query) as user prompts.
  """

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Tools.CompleteTask
  alias EvoGit.Agent.LoopState

  @type state :: LoopState.t()

  @doc """
  Extracts the tool name from a tool schema struct.
  """
  def tool_name(%{name: name}), do: name
  def tool_name(_other), do: nil

  @doc """
  Determines whether the agent loop should trigger turn-limit recovery.

  Returns `true` when the turn limit is exceeded and the agent is NOT already
  in a grace period. The `in_grace_period` guard is critical: without it,
  `trigger_recovery/2` sets `in_grace_period: true` and re-enters `loop/1`,
  where the same condition re-fires — an infinite loop with no termination.

  ## The bug

  Previously this only checked `turn >= max_turns`. When recovery set
  `in_grace_period: true` and looped back, the condition re-fired immediately.
  The `in_grace_period` guard breaks the cycle.
  """
  @spec trigger_turn_limit_recovery?(LoopState.t()) :: boolean()
  def trigger_turn_limit_recovery?(%LoopState{in_grace_period: true}), do: false
  def trigger_turn_limit_recovery?(%LoopState{turn: turn, max_turns: max}), do: turn >= max

  @doc """
  Determines whether a `{:continue, _}` outcome during the grace period should
  fail recovery.

  During the grace period (the recovery turn), the agent gets exactly one turn
  to call `complete_task`. If it instead calls other tools, recovery has failed
  and the loop must terminate with `{:error, :recovery_failed}`.

  This bounds the grace period to exactly one turn, guaranteeing the loop can
  never run indefinitely.
  """
  @spec grace_period_continue_failed?(LoopState.t()) :: boolean()
  def grace_period_continue_failed?(%LoopState{in_grace_period: true}), do: true
  def grace_period_continue_failed?(%LoopState{in_grace_period: false}), do: false

  defmacro __using__(_opts) do
    quote do
      require Logger
      use Retry

      @complete_tool "complete_task"

      import ReqLLM.Context, only: [user: 1, assistant: 1, system: 1, tool_result: 3]

      defp current_model, do: EvoGit.Agent.ToolDispatch.current_model()

      defp current_generation_params, do: EvoGit.Agent.ToolDispatch.current_generation_params()

      # --- Public API ---

      @doc """
      Runs the agent synchronously, blocking until it completes.

      The agent's worktree path is set once at startup via
      `Process.get(:repo_path)` and stored in `LoopState.repo_path`.
      Agent state is synced to ETS every turn for dashboard visibility.
      The dashboard reads the `context` field from `evogit_agent_state` table.

      The `dispatch_ctx` keyword list is required: it drives worktree setup,
      retry handling, and process-dict initialization before the agent loop.
      """
      def run(objective, dispatch_ctx) do
        setup_dispatch_context(dispatch_ctx)

        # The agent process owns git operations. After the agent finishes
        # (any exit path), commit any pending changes as a best-effort
        # fallback so the worktree is clean before the scheduler processes
        # the result. The scheduler never touches git directly.
        try do
          do_run(objective)
        after
          EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()
        end
      end

      defp do_run(objective) do
        agent_id = EvoGit.AgentScheduler.current_agent_id()

        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)

        # Validate that the assigned node path exists
        node_path = agent_state.context_node.path
        repo_path = Process.get(:repo_path)
        full_path = Path.join(repo_path, node_path)

        unless File.exists?(full_path) do
          Logger.error(
            "Agent #{agent_id}: Assigned node path does not exist: #{full_path} (node_path=#{node_path})"
          )

          {:error, :path_not_exist}
        else
          # Build context tree and merge into first user prompt.
          # Use :repo_path (set by scheduler to worktree path).
          #
          # The first user prompt is framed as two distinct blocks so the LLM
          # can unambiguously tell where the descriptive context/environment
          # ends and the actionable objective begins:
          #
          #   <context>...</context>
          #   ---
          #   <objective>...</objective>
          #
          # Empty/blank sections are dropped so we never emit dangling rules,
          # empty blocks, or doubled delimiters.
          context_tree = build_dynamic_context(%{node_path: node_path, repo_path: repo_path})
          foreign_repos_section = build_foreign_repos_section(agent_state.foreign_repos)

          context_body =
            [context_tree, foreign_repos_section]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n\n")

          objective_body = if blank?(objective), do: "", else: to_string(objective)

          combined_prompt =
            [context_block(context_body), objective_block(objective_body)]
            |> Enum.reject(&blank?/1)
            |> Enum.join("\n\n---\n\n")

          context = ReqLLM.Context.new([system(system_prompt()), user(combined_prompt)])
          # Tag initial messages (system + user prompt) with turn 0
          context = tag_context_messages_with_turn(context, 0)

          # Load skill schemas hierarchically — only skills enabled in the
          # Context Tree (from root to this agent's node) are available.
          repo_root = Process.get(:evogit_repo_root)

          skill_schemas =
            if repo_root && is_binary(repo_root) do
              all_skills = EvoGit.Skills.load_skills(repo_root)
              skill_names = EvoGit.Skills.hierarchical_skill_names(node_path, repo_path)

              all_skills
              |> EvoGit.Skills.filter_skills(skill_names)
              |> EvoGit.Skills.to_tool_schemas()
            else
              []
            end

          max_turns = agent_state.max_turns

          state = %LoopState{
            agent_id: agent_id,
            agent_module: __MODULE__,
            depth: EvoGit.AgentScheduler.current_depth(),
            node_path: node_path,
            repo_path: repo_path,
            context: context,
            max_turns: max_turns,
            skill_schemas: skill_schemas,
            foreign_repos: agent_state.foreign_repos,
            delegation_level: __MODULE__.delegation_level()
          }

          # Sync initial context to ETS for dashboard
          EvoGit.AgentScheduler.update_agent_context(agent_id, context)
          sync_turn_to_ets(agent_id, 0)

          Process.put(:delegation_hints, %{})
          Process.put(:read_delegation_hints, %{})
          loop(state)
        end
      end

      defp setup_dispatch_context(ctx) do
        agent_id = Keyword.fetch!(ctx, :agent_id)
        depth = Keyword.fetch!(ctx, :depth)
        repo_root = Keyword.fetch!(ctx, :repo_root)
        repo_id = Keyword.fetch!(ctx, :repo_id)
        worktree_path = Keyword.fetch!(ctx, :worktree_path)
        retries = Keyword.fetch!(ctx, :retries)
        spec = Keyword.fetch!(ctx, :spec)
        meta = Keyword.fetch!(ctx, :meta)

        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, depth)
        Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())
        Process.put(:evogit_repo_root, repo_root)
        Process.put(:evogit_repo_id, repo_id)
        Process.put(:repo_path, worktree_path)

        # Create/prepare worktree and run init script (blocking I/O, runs
        # concurrently across subagents). If this fails, the task crashes
        # (caught by the :DOWN handler / crash recovery) rather than the
        # GenServer — which is the desired behaviour.
        EvoGit.AgentScheduler.Dispatch.setup_worktree(
          agent_id,
          repo_root,
          worktree_path,
          spec,
          meta
        )

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        else
          Logger.info(
            "AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}"
          )
        end
      end

      # --- Internal Execution Logic ---

      defp sync_current_commit_after_tools(state), do: EvoGit.Agent.ToolDispatch.sync_current_commit_after_tools(state)

      defp sync_and_get_current_commit(state), do: EvoGit.Agent.ToolDispatch.sync_and_get_current_commit(state)

      # Checks and sends turn-limit warnings via the adaptive TurnWarning module.
      # See EvoGit.Agent.TurnWarning for threshold logic and message generation.
      defp check_limit_warnings(%LoopState{} = state) do
        case EvoGit.Agent.TurnWarning.check_positional(
               state.turn,
               state.max_turns,
               state.last_warned_level,
               state.delegation_level
             ) do
          {:ok, warning} ->
            msg = EvoGit.Agent.TurnWarning.message(warning)
            warning_msg = tag_message_turn(user(msg), state.turn)
            new_context = ReqLLM.Context.append(state.context, warning_msg)
            %{state | context: new_context, last_warned_level: warning.level}

          :none ->
            case EvoGit.Agent.TurnWarning.check_middle(
                   state.turn,
                   state.max_turns,
                   state.turns_since_subagent,
                   state.delegation_level
                 ) do
              {:ok, warning} ->
                msg = EvoGit.Agent.TurnWarning.message(warning)
                warning_msg = tag_message_turn(user(msg), state.turn)
                new_context = ReqLLM.Context.append(state.context, warning_msg)
                %{state | context: new_context, turns_since_subagent: 0}

              :none ->
                state
            end
        end
      end

      defp loop(%LoopState{} = state) do
        context_before = state.context

        state =
          EvoGit.Agent.ContextCompression.compress_if_needed(state,
            agent_id: state.agent_id,
            llm_model: current_model(),
            llm_generation_params: current_generation_params()
          )

        state = check_limit_warnings(state)

        # Sync context to ETS after any updates (compression, warnings)
        if context_before != state.context do
          sync_context_to_ets(state.agent_id, state.context)
          sync_total_tokens_to_ets(state.agent_id, state.total_tokens)
        end

        cond do
          EvoGit.Agent.trigger_turn_limit_recovery?(state) ->
            trigger_recovery(state, "max turns (#{state.max_turns}) exceeded")

          true ->
            do_turn(state)
        end
      end

      defp trigger_recovery(%LoopState{} = state, reason) do
        objective =
          case EvoGit.AgentScheduler.get_agent_state(state.agent_id) do
            {:ok, agent_state}
            when is_binary(agent_state.objective) and
                   agent_state.objective != "" ->
              agent_state.objective

            _ ->
              nil
          end

        # Safety net: auto-commit any uncommitted work before entering the grace
        # period, so it is preserved even if the agent fails to commit during its
        # single recovery turn. We only commit when there are actually changes
        # (non-empty porcelain status); a clean workspace is a no-op. Git errors
        # are allowed to propagate (crash) — this is best-effort salvage, not
        # error-masking.
        maybe_recovery_auto_commit(state)

        warning_msg =
          if objective do
            """
            You have exceeded the execution limit (#{reason}).
            Your priority is to call `#{@complete_tool}` NOW with your best answer.

            If you have critical uncommitted changes, commit them first, then immediately call `#{@complete_tool}`. Your already-committed work is safe.

            Your original objective was:
            #{objective}

            Your report MUST summarize the status of this ENTIRE objective, not just your most recent sub-task.
            """
          else
            """
            You have exceeded the execution limit (#{reason}).
            Your priority is to call `#{@complete_tool}` NOW with your best answer explaining the situation.

            If you have critical uncommitted changes, commit them first, then immediately call `#{@complete_tool}`. Your already-committed work is safe.
            """
          end

        recovery_msg = tag_message_turn(user(warning_msg), state.turn)
        new_context = ReqLLM.Context.append(state.context, recovery_msg)

        state = %{state | context: new_context, in_grace_period: true}
        loop(state)
      end

      # Best-effort auto-commit of any uncommitted work just before the grace
      # period, as a safety net so work is not lost if the agent fails to commit
      # during its single recovery turn. Only commits when the workspace is dirty
      # (non-empty porcelain status); a clean workspace is a silent no-op. Git
      # errors propagate (crash) rather than being swallowed — this is salvage,
      # not error-masking. No try/rescue per repo conventions.
      defp maybe_recovery_auto_commit(%LoopState{} = state) do
        repo_path = Process.get(:repo_path)

        if repo_path do
          case Git.status(repo_path) do
            {:ok, ""} ->
              :ok

            {:ok, _status_output} ->
              {:ok, _} = Git.add(repo_path, ".")
              {:ok, _} = Git.commit(repo_path, "auto-commit: turn-limit recovery")
              :ok
          end
        else
          :ok
        end
      end

      defp do_turn(%LoopState{} = state) do
        EvoGit.Agent.ToolDispatch.do_turn(
          state,
          &effective_tools/1,
          subagent_modules(),
          &loop/1,
          &trigger_recovery/2
        )
      end

      defp compact_reasoning_details(context), do: EvoGit.Agent.ToolDispatch.compact_reasoning_details(context)

      defp process_tool_calls(tool_calls, state) do
        EvoGit.Agent.ToolDispatch.process_tool_calls(tool_calls, state, subagent_modules())
      end

      defp handle_complete_call(complete_call, state, tool_calls) do
        EvoGit.Agent.ToolDispatch.handle_complete_call(complete_call, state, tool_calls)
      end

      defp do_complete(complete_call, state), do: EvoGit.Agent.ToolDispatch.do_complete(complete_call, state)

      defp process_regular_tool_calls(tool_calls, state) do
        EvoGit.Agent.ToolDispatch.process_regular_tool_calls(tool_calls, state, subagent_modules())
      end

      defp process_standard_calls(indexed_calls, state) do
        EvoGit.Agent.ToolDispatch.process_standard_calls(indexed_calls, state)
      end

      defp batch_execute_tools(indexed_calls, max_timeout, repo_root) do
        EvoGit.Agent.ToolDispatch.batch_execute_tools(indexed_calls, max_timeout, repo_root, __MODULE__.delegation_level())
      end

      defp maybe_append_redundant_cd_warning(output, call, repo_path, repo_root) do
        EvoGit.Agent.ToolDispatch.maybe_append_redundant_cd_warning(output, call, repo_path, repo_root)
      end

      # --- Delegation Hint Delegates ---

      defp delegation_hint_threshold, do: EvoGit.Agent.DelegationHints.delegation_hint_threshold()
      defp max_tool_timeout, do: EvoGit.Agent.DelegationHints.max_tool_timeout()
      defp default_tool_timeout, do: EvoGit.Agent.DelegationHints.default_tool_timeout()

      defp extract_child_paths(tool_name, args, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.extract_child_paths(tool_name, args, node_path, repo_path)
      end

      defp do_extract_child_paths(tool_name, args, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.do_extract_child_paths(tool_name, args, node_path, repo_path)
      end

      defp file_path_to_child_dir(file_path, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.file_path_to_child_dir(file_path, node_path, repo_path)
      end

      defp path_to_child_dir(dir_path, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.path_to_child_dir(dir_path, node_path, repo_path)
      end

      defp extract_first_segment(path), do: EvoGit.Agent.DelegationHints.extract_first_segment(path)

      defp extract_first_segment_from_remainder(remainder, node_path) do
        EvoGit.Agent.DelegationHints.extract_first_segment_from_remainder(remainder, node_path)
      end

      defp update_delegation_hints(hints, child_paths) do
        EvoGit.Agent.DelegationHints.update_delegation_hints(hints, child_paths)
      end

      defp filter_child_paths_if_conflicts(child_paths, conflict_files) do
        EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(child_paths, conflict_files)
      end

      defp maybe_append_delegation_hint(output, hints, child_paths, threshold) do
        EvoGit.Agent.DelegationHints.maybe_append_delegation_hint(output, hints, child_paths, threshold)
      end

      defp read_delegation_hint_threshold, do: EvoGit.Agent.DelegationHints.read_delegation_hint_threshold()

      defp extract_read_child_paths(tool_name, args, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.extract_read_child_paths(tool_name, args, node_path, repo_path)
      end

      defp do_extract_read_child_paths(tool_name, args, node_path, repo_path) do
        EvoGit.Agent.DelegationHints.do_extract_read_child_paths(tool_name, args, node_path, repo_path)
      end

      defp update_read_delegation_hints(read_hints, child_paths) do
        EvoGit.Agent.DelegationHints.update_read_delegation_hints(read_hints, child_paths)
      end

      defp maybe_append_read_delegation_hint(output, read_hints, child_paths, threshold, delegation_level) do
        EvoGit.Agent.DelegationHints.maybe_append_read_delegation_hint(output, read_hints, child_paths, threshold, delegation_level)
      end

      defp entry_count(hints, child_path), do: EvoGit.Agent.DelegationHints.entry_count(hints, child_path)

      defp is_rate_limit_error?(reason), do: EvoGit.Agent.TruncationFeedback.is_rate_limit_error?(reason)

      defp append_truncation_feedback(output, truncation_info, tool_name) do
        EvoGit.Agent.TruncationFeedback.append_truncation_feedback(output, truncation_info, tool_name)
      end

      defp tool_truncation_suggestion(tool_name), do: EvoGit.Agent.TruncationFeedback.tool_truncation_suggestion(tool_name)

      defp format_truncation_reason(reason), do: EvoGit.Agent.TruncationFeedback.format_truncation_reason(reason)

      defp format_byte_size(bytes), do: EvoGit.Agent.TruncationFeedback.format_byte_size(bytes)

      # Formats git status --porcelain output for display
      # Format: "XY filename" where X = staged, Y = unstaged
      # --- Context Builder Delegates ---

      defp build_dynamic_context(state), do: EvoGit.Agent.ContextBuilder.build_dynamic_context(state)

      defp build_foreign_repos_section(foreign_repos) do
        EvoGit.Agent.ContextBuilder.build_foreign_repos_section(foreign_repos)
      end

      defp blank?(value), do: EvoGit.Agent.ContextBuilder.blank?(value)

      defp context_block(body), do: EvoGit.Agent.ContextBuilder.context_block(body)

      defp objective_block(body), do: EvoGit.Agent.ContextBuilder.objective_block(body)

      defp sync_context_to_ets(agent_id, context) do
        EvoGit.Agent.ContextBuilder.sync_context_to_ets(agent_id, context)
      end

      defp sync_usage_to_ets(agent_id, usage) do
        EvoGit.Agent.ContextBuilder.sync_usage_to_ets(agent_id, usage)
      end

      defp sync_turn_to_ets(agent_id, turn) do
        EvoGit.Agent.ContextBuilder.sync_turn_to_ets(agent_id, turn)
      end

      defp sync_total_tokens_to_ets(agent_id, total_tokens) do
        EvoGit.Agent.ContextBuilder.sync_total_tokens_to_ets(agent_id, total_tokens)
      end

      defp tag_message_turn(msg, turn), do: EvoGit.Agent.ContextBuilder.tag_message_turn(msg, turn)

      defp tag_context_tail_with_turn(context, turn) do
        EvoGit.Agent.ContextBuilder.tag_context_tail_with_turn(context, turn)
      end

      defp tag_context_messages_with_turn(context, turn) do
        EvoGit.Agent.ContextBuilder.tag_context_messages_with_turn(context, turn)
      end

      def available_tools do
        EvoGit.Agent.Tools.schemas() ++ subagent_schemas() ++ [CompleteTask.schema()]
      end

      @doc """
      Returns the tool name used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_name, do: nil

      @doc """
      Returns the tool description used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_description, do: ""

      @doc """
      Returns the agent type: `:read` or `:read_write`.

      - `:read` - Read-only agents can only read files and update CONTEXT.md files
      - `:read_write` - Read-write agents can read, write, and modify code

      Override this in your agent module to declare its type.

      ## Rules for Subagent Delegation

      - **Read agents** can only spawn other read subagents
      - **Read-write agents** can spawn both read and read-write subagents,
        but read-write subagents must operate within the same node or child nodes
        of the parent agent's assigned node (no permission escalation)

      ## Example

          def agent_type, do: :read_write
      """
      def agent_type, do: :read_write

      @doc """
      Returns the delegation level for this agent type.

      `:high` — The agent is expected to actively delegate work to subagents.
      These are orchestration/planning agents (Manager, CodebaseLead, etc.)
      that receive broad objectives and should break them down into subtasks.

      `:low` — The agent receives precise, well-scoped objectives and primarily
      does the work itself. Subagent delegation, if used at all, is occasional.
      These are worker agents (Executor, TaskScheduler, Evaluator, etc.).

      The turn-budget warning system uses this to adjust its behavior: low-level
      agents receive significantly fewer delegation reminders since they are not
      expected to actively delegate.
      """
      def delegation_level, do: :high

      @doc """
      Returns a list of agent modules that can be spawned as subagents.
      The framework automatically generates tool schemas and execution logic
      from each module's `subagent_tool_name/0` and `subagent_tool_description/0`.

      Override this in your agent module to declare subagents.

      ## Example

          def subagent_modules do
            [EvoGit.Agents.CodebaseInvestigator]
          end
      """
      def subagent_modules, do: []

      @doc false
      def subagent_tools do
        Enum.map(subagent_modules(), & &1.subagent_tool_name())
      end

      defp subagent_schemas do
        Enum.map(subagent_modules(), fn mod ->
          ReqLLM.tool(
            name: mod.subagent_tool_name(),
            description: mod.subagent_tool_description(),
            parameter_schema: %{
              "type" => "object",
              "properties" => %{
                "path" => %{
                  "type" => "string",
                  "description" =>
                    "The path to a DIRECTORY where the subagent should operate. " <>
                      "Use a RELATIVE path from the repository root for the current project (e.g., './src/auth', './lib/utils'). " <>
                      "Use an ABSOLUTE path to delegate to a FOREIGN REPOSITORY configured in genesis.toml " <>
                      "(e.g., '/Source/original-proj'). MUST be a directory node, NOT a file path.\n\n" <>
                      "IMPORTANT: Delegate at the DEEPEST correct node you know — if your routing table shows work belongs in `./src/auth/oauth/`, " <>
                      "delegate there directly, not at the higher-level `./src/auth/`. The subagent has its own routing table and will navigate further.\n\n" <>
                      "IMPORTANT: When delegating to a foreign repo, prefer using the repository ROOT path " <>
                      "(e.g., '/Source/original-proj' rather than '/Source/original-proj/src'). " <>
                      "Since you have no prior knowledge of the foreign repo's structure, starting at the root " <>
                      "allows the subagent to discover the codebase layout via its CONTEXT.md routing table. " <>
                      "Spawning at a non-root path is allowed but discouraged unless you have specific knowledge of that path.\n\n" <>
                      "IMPORTANT: Delegating work to child directories is more efficient than editing files there yourself. " <>
                      "When you find yourself repeatedly editing files in the same child directory, spawn a subagent at that path to handle the work autonomously."
                },
                "objective" => %{
                  "type" => "string",
                  "description" =>
                    "A clear, self-contained objective for the subagent. " <>
                      "Include any relevant context since it starts with a fresh context. " <>
                      "IMPORTANT: The subagent's working directory is automatically set correctly. " <>
                      "Do NOT include worktree paths or `cd` commands in the objective — just describe what to do (e.g., 'run `mix test`'). " <>
                      "Include all relevant context, findings, and file paths so the subagent can start working immediately without re-investigating."
                },
                "commit_id" => %{
                  "type" => "string",
                  "description" =>
                    "Optional: The commit SHA to spawn the subagent on. " <>
                      "Defaults to the current commit if not specified."
                }
              },
              "required" => ["path", "objective"]
            },
            callback: fn _args -> {:ok, nil} end
          )
        end)
      end

      defp subagent_module_for(tool_name) do
        EvoGit.Agent.ToolDispatch.subagent_module_for(tool_name, subagent_modules())
      end

      defp effective_tools(%LoopState{} = state) do
        skill_schemas = Map.get(state, :skill_schemas, [])
        all_tools = available_tools() ++ skill_schemas

        if at_max_depth?(state) do
          excluded = MapSet.new(subagent_tools())

          all_tools
          |> Enum.reject(fn tool ->
            name = EvoGit.Agent.tool_name(tool)
            name && MapSet.member?(excluded, name)
          end)
        else
          all_tools
        end
      end

      defp at_max_depth?(%LoopState{} = state) do
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        state.depth >= agent_state.max_depth
      end

      @doc """
      Returns the system prompt that defines the agent's core behavior, persona, and rules.

      IMPORTANT: The system prompt MUST NOT contain dynamic state, the context tree,
      or the specific objective/query. System prompts are strictly for defining
      the agent's behavior. The objective and context tree are automatically
      provided to the agent as user prompts.
      """
      def system_prompt, do: ""

      # Give adopting modules default implementations they can override
      defoverridable available_tools: 0,
                     system_prompt: 0,
                     subagent_tool_name: 0,
                     subagent_tool_description: 0,
                     subagent_modules: 0,
                     agent_type: 0,
                     delegation_level: 0
    end
  end
end
