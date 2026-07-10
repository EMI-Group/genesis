defmodule EvoGit.Agent.ContextCompression do
  @moduledoc """
  Context compression for the agent loop.

  When the conversation context exceeds the token threshold, this module
  compresses the interaction history into a dense summary using an LLM call.
  This prevents context window overflow while preserving essential progress
  information.

  ## Cache Reuse

  The original message list is preserved and the compression instruction is
  appended as a new user message. This allows the LLM provider to reuse its
  cached prefix from previous turns, significantly improving cache hit rate
  and reducing latency/cost.

  ## Token Reset

  After a successful compression, `total_tokens` is reset to 0. This prevents
  the stale high token count from triggering redundant compressions before
  the next LLM call updates the count.

  ## Usage

  Called from the agent loop after each turn to check if compression is needed:

      state = EvoGit.Agent.ContextCompression.compress_if_needed(state,
        default_tool_timeout: @default_tool_timeout,
        agent_id: state.agent_id
      )
  """

  require Logger

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler

  @doc """
  Attempts to compress the agent's chat context if it exceeds the token threshold.

  The threshold is read from `EvoGit.Defaults.compression_threshold_tokens()` which resolves from user config.

  ## Options

    * `:agent_id` — the agent's ID (required, used for logging and LLM slot acquisition)
    * `:llm_model` — the model to use for the compression LLM call (required)
    * `:llm_generation_params` — keyword list of LLM generation params (temperature, max_tokens, etc.) passed to ReqLLM (optional, defaults to [])

  ## Returns

  The updated state map (either compressed or unchanged).
  """
  @spec compress_if_needed(LoopState.t(), keyword()) :: LoopState.t()
  def compress_if_needed(%LoopState{} = state, opts \\ []) do
    threshold = EvoGit.Defaults.compression_threshold_tokens()
    agent_id = Keyword.fetch!(opts, :agent_id)
    llm_model = Keyword.fetch!(opts, :llm_model)
    llm_gen_opts = Keyword.get(opts, :llm_generation_params, [])

    if state.total_tokens > threshold do
      Logger.info(
        "Agent #{agent_id}: Context length (#{state.total_tokens} tokens) exceeded compression threshold (#{threshold} tokens). Attempting compression..."
      )

      messages = ReqLLM.Context.to_list(state.context)

      case messages do
        [system_msg, initial_user_msg | _rest] ->
          compression_instruction = compression_instruction()

          compression_context =
            state.context
            |> ReqLLM.Context.append(ReqLLM.Context.user(compression_instruction))

          # Let exceptions and error tuples propagate — the agent loop's
          # restart logic (AgentScheduler retry) handles recovery, same as
          # any other LLM failure. No silent degradation to uncompressed state.
          AgentScheduler.with_llm_slot(agent_id, fn ->
            {:ok, stream_response} =
              ReqLLM.stream_text(llm_model, compression_context, llm_gen_opts)

            {:ok, response} = ReqLLM.StreamResponse.process_stream(stream_response)
            text = ReqLLM.Response.text(response)
            summary_msg = ReqLLM.Context.user("Summary of previous events:\n" <> text)
            new_context = ReqLLM.Context.new([system_msg, initial_user_msg, summary_msg])
            AgentScheduler.increment_compression_count(agent_id)

            %{
              state
              | context: new_context,
                total_tokens: 0,
                usage:
                  Usage.add(
                    state.usage,
                    Usage.from_response_usage(ReqLLM.Response.usage(response))
                  )
            }
          end)

        _ ->
          state
      end
    else
      state
    end
  end

  @doc false
  @spec compression_instruction() :: String.t()
  def compression_instruction do
    """
    <context_compression>
    Review the conversation above and create a dense, comprehensive summary that preserves all information needed to continue the work without loss.

    PRESERVE THESE EXACTLY (never paraphrase):
    - Necessary File paths, module names, function names, variable names
    - Necessary Configuration values and settings
    - Critical Error messages and stack traces at hand
    - Architectural decisions and their reasoning

    SUMMARIZE THESE:
    - Tool call results (preserve conclusions, drop raw output)
    - Code explorations (preserve findings, drop search syntax)
    - Multi-step reasoning (preserve conclusions, drop intermediate steps)
    - Conversational exchanges (preserve decisions, drop pleasantries)

    DISCARD COMPLETELY:
    - Acknowledgments, greetings, filler phrases
    - Repeated or redundant information
    - Raw tool syntax/JSON that isn't essential

    The original objective is preserved verbatim in the first user message above. Do NOT reproduce, restate, or paraphrase it in your summary. Reference it directly when needed.

    First, silently identify the most critical information. Then output a structured summary using EXACTLY this format:

    ## Current State
    [Your current state within the overall objective: what major milestones/parts are complete, what remains to be done, and what you should focus on next. This MUST reflect ALL work done across the entire session — not just recent work.]

    ## Completed
    [Bulleted list of what has been done. If possible, include the node paths or file paths where work was completed.]

    ## Key Findings
    [Important discoveries, constraints, dependencies found. Include exact names and paths.]

    ## Decisions Made
    [Architectural or design decisions with their rationale.]

    ## SubAgents Dispatched
    [Which subagents were spawned, their objectives, and their outcomes.]

    ## Errors Encountered
    [Failed approaches, bugs found, blockers. Include exact error messages and what was tried.]

    ## Next Steps
    [Precise, actionable next steps. Reference specific files and functions.]

    CRITICAL: You are working on the SAME original objective as when you started — it is preserved verbatim in the first user message above. Do NOT drift, redefine, narrow, or expand the objective. If your current work seems disconnected from the original objective, STOP and realign to it.

    IMPORTANT: When you eventually call complete_task, your final report MUST summarize the status of the ORIGINAL objective as a whole (refer to the first user message and "Current State" above) — NOT just the most recent sub-task you worked on.
    </context_compression>
    """
  end

  @doc """
  Formats a list of messages into a readable string for compression.
  """
  @spec format_messages_for_compression([map()]) :: String.t()
  def format_messages_for_compression(messages) when is_list(messages) do
    messages
    |> Enum.map(&format_single_message/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Formats a single message into a readable string for the compression prompt.
  """
  @spec format_single_message(map()) :: String.t()
  def format_single_message(%{role: :tool, name: tool_name} = msg)
      when is_binary(tool_name) do
    header = "[TOOL: #{tool_name}]"
    content = extract_message_content(msg)

    if String.trim(content) == "" do
      "#{header} <empty>"
    else
      "#{header}\n#{content}"
    end
  end

  def format_single_message(%{role: role} = msg) do
    header = "[#{role |> to_string() |> String.upcase()}]"
    content = extract_message_content(msg)

    if String.trim(content) == "" do
      "#{header} <empty>"
    else
      "#{header}\n#{content}"
    end
  end

  @doc """
  Extracts text content from a message's content parts.
  """
  @spec extract_message_content(map()) :: String.t()
  def extract_message_content(%{content: content} = _msg) do
    content
    |> Enum.reduce([], fn part, acc ->
      text =
        case part do
          %{type: :text, text: text} when is_binary(text) -> text
          %{type: :thinking, text: text} when is_binary(text) -> "[THINKING]\n#{text}"
          %{type: :image_url} -> "[IMAGE]"
          %{type: :video_url} -> "[VIDEO]"
          %{type: :image} -> "[IMAGE]"
          %{type: :file, filename: filename} -> "[FILE: #{filename}]"
          _ -> ""
        end

      if String.trim(text) == "", do: acc, else: [text | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
