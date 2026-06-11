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
  def compress_if_needed(state, opts \\ []) do
    threshold = EvoGit.Defaults.compression_threshold_tokens() || 100_000
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
          compression_instruction = """
          <context_compression>
          Review the conversation above and create a dense, comprehensive summary that preserves all information needed to continue the work without loss.

          PRESERVE THESE EXACTLY (never paraphrase):
          - File paths, module names, function names, variable names
          - Error messages and stack traces
          - Configuration values and settings
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

          First, silently identify the most critical information. Then output a structured summary using EXACTLY this format:

          ## Objective
          [1-2 sentences: the current goal being worked on]

          ## Completed
          [Bulleted list of what has been done. Include exact file paths for all files created/modified/deleted.]

          ## Key Findings
          [Important discoveries, constraints, dependencies found. Include exact names and paths.]

          ## Decisions Made
          [Architectural or design decisions with their rationale.]

          ## SubAgents Dispatched
          [Each subagent: type, objective, node path, result status.]

          ## Errors Encountered
          [Failed approaches, bugs found, blockers. Include exact error messages and what was tried.]

          ## Next Steps
          [Precise, actionable next steps. Reference specific files and functions.]
          </context_compression>
          """

          compression_context =
            state.context
            |> ReqLLM.Context.append(ReqLLM.Context.user(compression_instruction))

          result =
            AgentScheduler.with_llm_slot(agent_id, fn ->
              try do
                with {:ok, stream_response} <-
                       ReqLLM.stream_text(llm_model, compression_context, llm_gen_opts),
                     {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
                     text <- ReqLLM.Response.text(response),
                     summary_msg <- ReqLLM.Context.user("Summary of previous events:\n" <> text),
                     new_context <-
                       ReqLLM.Context.new([system_msg, initial_user_msg, summary_msg]) do
                  {:ok, %{state | context: new_context, total_tokens: 0}}
                else
                  _error -> {:error, state}
                end
              rescue
                e ->
                  Logger.warning("Agent #{agent_id}: Compression LLM call failed: #{inspect(e)}")
                  {:error, state}
              end
            end)

          case result do
            {:ok, new_state} -> new_state
            {:error, original_state} -> original_state
          end

        _ ->
          state
      end
    else
      state
    end
  end

  @doc """
  Formats a list of messages into a readable string for compression.
  """
  @spec format_messages_for_compression([map()]) :: String.t()
  def format_messages_for_compression(messages) do
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
  def extract_message_content(msg) do
    msg.content
    |> Enum.map(fn
      %{type: :text, text: text} when is_binary(text) -> text
      %{type: :thinking, text: text} when is_binary(text) -> "[THINKING]\n#{text}"
      %{type: :image_url} -> "[IMAGE]"
      %{type: :video_url} -> "[VIDEO]"
      %{type: :image} -> "[IMAGE]"
      %{type: :file, filename: filename} -> "[FILE: #{filename}]"
      _ -> ""
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end
end
