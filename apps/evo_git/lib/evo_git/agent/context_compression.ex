defmodule EvoGit.Agent.ContextCompression do
  @moduledoc """
  Context compression for the agent loop.

  When the conversation context exceeds the token threshold, this module
  compresses the interaction history into a dense summary using an LLM call.
  This prevents context window overflow while preserving essential progress
  information.

  ## Usage

  Called from the agent loop after each turn to check if compression is needed:

      state = EvoGit.Agent.ContextCompression.compress_if_needed(state,
        timeout_ms: @timeout_ms,
        default_tool_timeout: @default_tool_timeout,
        agent_id: state.agent_id
      )
  """

  require Logger

  alias EvoGit.AgentScheduler

  @doc """
  Attempts to compress the agent's chat context if it exceeds the token threshold.

  The threshold is read from `Application.get_env(:evo_git, :compression_threshold_tokens, 100_000)`.

  ## Options

    * `:agent_id` — the agent's ID (required, used for logging and LLM slot acquisition)
    * `:llm_model` — the model to use for the compression LLM call (required)

  ## Returns

  The updated state map (either compressed or unchanged).
  """
  @spec compress_if_needed(state :: map(), opts :: keyword()) :: map()
  def compress_if_needed(state, opts \\ []) do
    threshold = Application.get_env(:evo_git, :compression_threshold_tokens, 100_000)
    agent_id = Keyword.fetch!(opts, :agent_id)
    llm_model = Keyword.fetch!(opts, :llm_model)

    if state.total_tokens > threshold do
      Logger.info(
        "Agent #{agent_id}: Context length (#{state.total_tokens} tokens) exceeded compression threshold (#{threshold} tokens). Attempting compression..."
      )

      messages = ReqLLM.Context.to_list(state.context)

      case messages do
        [system_msg, initial_user_msg | rest_context] ->
          interaction_history = format_messages_for_compression(rest_context)

          prompt = """
          Compress the following interaction context into a dense, structured summary to be passed to the next agent iteration.

          Your goal is to preserve architectural context and progress while stripping out conversational filler, raw tool syntax, and large code blocks.

          Output your summary strictly using the following format:

          1. Current Progress:
          [1-5 sentences defining the overarching goal currently being worked on and the current state of progress.]

          2. Key Findings & Decisions:
          [Crucial context discovered, architectural decisions made, or constraints identified during the interaction.]

          3. SubAgent Ledger:
          [List previously spawned subagents and a short summary of their objectives and results, if applicable. This helps maintain a memory of delegated work.]

          4. Pending / Next Steps:
          [What specifically needs to be executed next to advance the Current Objective.]

          ---

          [INTERACTION HISTORY BEGIN]

          #{interaction_history}
          """

          compression_context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

          result =
            AgentScheduler.with_llm_slot(agent_id, fn ->
              try do
                with {:ok, stream_response} <-
                       ReqLLM.stream_text(llm_model, compression_context),
                     {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
                     text <- ReqLLM.Response.text(response),
                     summary_msg <- ReqLLM.Context.user("Summary of previous events:\n" <> text),
                     new_context <-
                       ReqLLM.Context.new([system_msg, initial_user_msg, summary_msg]) do
                  {:ok, %{state | context: new_context}}
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
