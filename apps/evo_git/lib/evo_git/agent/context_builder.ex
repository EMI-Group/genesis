defmodule EvoGit.Agent.ContextBuilder do
  @moduledoc """
  Dynamic context building helpers extracted from `EvoGit.Agent.__using__/1`.

  Builds the context tree and foreign repos sections for the first user prompt,
  provides XML-like block wrappers for the context/objective framing, and
  handles syncing agent state (context, usage, turn, tokens) to ETS.
  Also provides turn-tagging and creation-time timestamp stamping utilities
  for messages in the chat context (timestamps are Unix seconds).
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.AgentScheduler

  # --- Dynamic Context Building ---

  @doc """
  Builds the context tree string for a given node path and repo path.
  """
  def build_dynamic_context(state) do
    case ContextNode.build_context(state.node_path, state.repo_path) do
      {:ok, context} -> context
      {:error, _} -> "Current Path: '#{state.node_path}'."
    end
  end

  @doc """
  Builds the foreign repositories markdown section for the first user prompt.
  Returns an empty string when there are no non-primary foreign repos.
  """
  def build_foreign_repos_section(foreign_repos) do
    repos =
      foreign_repos
      |> Enum.reject(&ForeignRepo.primary?(&1.id))

    if repos == [] do
      ""
    else
      rows =
        repos
        |> Enum.map(fn repo ->
          desc = repo.description || "(no description)"
          "| :#{repo.id} | #{repo.root} | #{desc} |"
        end)
        |> Enum.join("\n")

      "# Foreign Repositories\n\n" <>
        "| ID | Path | Description |\n|------|------|-------------|\n#{rows}\n\n" <>
        "Use absolute paths (e.g., `#{hd(repos).root}`) when delegating to foreign repositories."
    end
  end

  @doc """
  Builds the git-submodules note section for the first user prompt.

  `repo_notes` is the ALREADY-RENDERED markdown block (produced by
  `EvoGit.Runtime.Helpers.load_repo_notes/2` at root spec build) or `nil` when
  the repo has no gitlink/submodule entries (or detection failed). Returns the
  text as-is (trimmed), or `""` when nil/blank — mirroring
  `build_foreign_repos_section/1`'s "empty string when absent" convention so
  the runner's existing blank-filter drops it and no noise reaches prompts for
  repos without submodules.
  """
  def build_repo_notes_section(repo_notes) do
    if blank?(repo_notes), do: "", else: String.trim(repo_notes)
  end

  # --- Blank Detection ---

  @doc """
  Treats `nil` or whitespace-only strings/binaries as blank.
  """
  def blank?(nil), do: true

  def blank?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  def blank?(_), do: false

  # --- XML-like Block Wrappers ---

  @doc """
  Wraps the environment/context body in an XML-like block. Returns \"\" when
  the body is blank so the caller can drop it without leaving an empty
  `<context></context>` block.
  """
  def context_block(body) do
    if blank?(body), do: "", else: "<context>\n#{body}\n</context>"
  end

  @doc """
  Wraps the objective body in an XML-like block. Returns \"\" when the body
  is blank so the caller can drop it without leaving an empty
  `<objective></objective>` block.
  """
  def objective_block(body) do
    if blank?(body), do: "", else: "<objective>\n#{body}\n</objective>"
  end

  # --- ETS Sync Helpers ---

  def sync_context_to_ets(agent_id, context) do
    AgentScheduler.update_agent_context(agent_id, context)
  end

  def sync_turn_to_ets(agent_id, turn) do
    AgentScheduler.update_agent_turn(agent_id, turn)
  end

  def sync_total_tokens_to_ets(agent_id, total_tokens) do
    AgentScheduler.update_total_tokens(agent_id, total_tokens)
  end

  # --- Turn Tagging ---

  @doc """
  Tags a single message struct with the given turn number via its metadata.
  Also stamps a creation-time timestamp (Unix seconds) on the metadata,
  idempotently — an already-present timestamp is preserved.
  """
  def tag_message_turn(%ReqLLM.Message{} = msg, turn) when is_integer(turn) do
    metadata = Map.put(msg.metadata || %{}, :turn, turn)
    metadata = Map.put_new(metadata, :timestamp, System.system_time(:second))
    %{msg | metadata: metadata}
  end

  @doc """
  Stamps a single message struct with a creation-time timestamp (Unix seconds)
  via its metadata, idempotently — an already-present timestamp is preserved.
  Tolerates `metadata: nil`. For append sites that are NOT turn-tagged.
  """
  def tag_message_timestamp(%ReqLLM.Message{} = msg) do
    metadata = msg.metadata || %{}
    %{msg | metadata: Map.put_new(metadata, :timestamp, System.system_time(:second))}
  end

  @doc """
  Tags the last message in a context with the given turn number.
  """
  def tag_context_tail_with_turn(%ReqLLM.Context{} = context, turn)
      when is_integer(turn) do
    case context.messages do
      [] ->
        context

      msgs ->
        last = List.last(msgs)
        tagged = tag_message_turn(last, turn)
        %{context | messages: List.replace_at(msgs, length(msgs) - 1, tagged)}
    end
  end

  @doc """
  Tags ALL messages in a context with the given turn number (for initial setup).
  """
  def tag_context_messages_with_turn(%ReqLLM.Context{} = context, turn)
      when is_integer(turn) do
    tagged_msgs = Enum.map(context.messages, &tag_message_turn(&1, turn))
    %{context | messages: tagged_msgs}
  end
end
