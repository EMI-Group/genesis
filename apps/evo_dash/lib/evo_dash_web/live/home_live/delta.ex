defmodule EvoDashWeb.HomeLive.Delta do
  @moduledoc """
  Pure reducer for the PUSH-ONLY agent-delta stream
  (`EvoGit.Agent.Stream`) on the Genesis Assistant chat page.

  The page keeps one `%Delta{}` per subscribed agent and feeds every
  `{:agent_delta, agent_id, seq, batch}` payload through
  `apply_batch/5`, which folds the batch's events into the whole chat
  surface at once:

    * `{:text, chunk}` — appended to the last streaming assistant bubble
      (`EvoDashWeb.HomeLive.Transcript.append_streaming_text/2`);
    * `{:thinking, chunk}` — accumulated in `thinking` and mirrored into ONE
      upserted thought-process entry for the current turn (the bubble text
      excludes reasoning by design, see
      `EvoDashWeb.HomeLive.Messages.message_text/1`);
    * `{:tool_call, id, name}` — the streaming bubble is finalized and a
      `:tool` transcript entry appears (`:running`);
    * `{:tool_result, id, status}` — that entry's status is updated;
    * `{:turn, info}` — turn meta/token accounting is recorded, the bubble is
      finalized and the thinking bucket starts over;
    * `{:yield, text}` / `{:finished, status}` — the authoritative text is
      finalized and the batch reports `outcome` so the page can stop the
      stream and reconcile with the terminal task status.

  Everything here is PURE and TOTAL: no processes, no ETS, no side effects,
  and an unknown/malformed event (or a malformed batch) is ignored instead of
  raising — the delta payload crosses a `Phoenix.PubSub`/RPC boundary whose
  shape is owned by the `:evo_git` core.

  `seq` is the session's monotonic event sequence: reconciliation is
  `EvoGit.Agent.Stream.stale?/2` applied by the CALLER before `apply_batch/5`,
  and `seed/3` records the snapshot's seq/turn when the page attaches.
  """

  alias EvoDashWeb.HomeLive.Transcript

  # Mirrors `EvoDashWeb.HomeLive.Transcript`'s per-turn reasoning cap so the
  # streamed thinking entries can never outgrow the history-derived ones.
  @max_thought_entries 40

  @typedoc "The outcome a batch reported, if any (the LAST one wins)."
  @type outcome :: nil | :yield | {:finished, term()}

  @type t :: %__MODULE__{
          agent_id: term(),
          node: atom() | nil,
          seq: non_neg_integer(),
          turn: non_neg_integer(),
          thinking: String.t()
        }

  defstruct agent_id: nil, node: nil, seq: 0, turn: 0, thinking: ""

  @doc """
  Builds the stream state for one agent on one node.

  `seq` must be a non-negative integer; anything else degrades to `0` so a
  malformed seed can never make every later delta look stale.
  """
  @spec new(term(), atom() | nil, term()) :: t
  def new(agent_id, node, seq) do
    %__MODULE__{agent_id: agent_id, node: node, seq: normalize_seq(seq)}
  end

  @doc """
  Records the attach snapshot's `seq` and `turn` on the stream state.

  `snapshot_seq` is the sequence `EvoGit.Agent.Stream.watch/1` (or
  `snapshot/1`) answered alongside the snapshot; a non-integer degrades to the
  snapshot's own `seq`, then to `0`. Total: a non-struct snapshot yields no
  turn.
  """
  @spec seed(t(), term(), non_neg_integer()) :: t
  def seed(%__MODULE__{} = delta, snapshot, snapshot_seq) do
    seq =
      if is_integer(snapshot_seq) and snapshot_seq >= 0 do
        snapshot_seq
      else
        normalize_seq(snapshot_field(snapshot, :seq))
      end

    turn =
      case snapshot_field(snapshot, :turn) do
        turn when is_integer(turn) and turn >= 0 -> turn
        _turn -> delta.turn
      end

    %{delta | seq: seq, turn: turn}
  end

  def seed(delta, _snapshot, _snapshot_seq), do: delta

  @doc """
  The empty turn-meta map the page renders under the assistant bubble.

  `:turn`, `:total_tokens`, `:duration_ms` and `:usage` stay `nil` until a
  `{:turn, info}` event fills them in.
  """
  @spec meta() :: map()
  def meta, do: %{turn: nil, total_tokens: nil, duration_ms: nil, usage: nil}

  @doc """
  Folds one coalesced delta batch (a list of events, or a single event) into
  the chat surface.

  Returns `%{delta, transcript, thought_process, meta, outcome}` — every input
  is returned unchanged when the batch carries nothing actionable, so a
  malformed payload is a no-op rather than a crash.
  """
  @spec apply_batch(t(), list(), list(), map(), term()) :: %{
          delta: t(),
          transcript: list(),
          thought_process: list(),
          meta: map(),
          outcome: outcome()
        }
  def apply_batch(%__MODULE__{} = delta, transcript, thought_process, meta, batch) do
    batch
    |> EvoGit.Agent.Stream.normalize_batch()
    |> Enum.reduce(
      %{
        delta: delta,
        transcript: transcript,
        thought_process: thought_process,
        meta: meta,
        outcome: nil
      },
      &apply_event/2
    )
  end

  def apply_batch(delta, transcript, thought_process, meta, _batch) do
    %{
      delta: delta,
      transcript: transcript,
      thought_process: thought_process,
      meta: meta,
      outcome: nil
    }
  end

  # --- events ---

  defp apply_event({:text, chunk}, acc) when is_binary(chunk) and chunk != "" do
    %{acc | transcript: Transcript.append_streaming_text(acc.transcript, chunk)}
  end

  defp apply_event({:thinking, chunk}, acc) when is_binary(chunk) and chunk != "" do
    thinking = acc.delta.thinking <> chunk
    delta = %{acc.delta | thinking: thinking}

    %{
      acc
      | delta: delta,
        thought_process: upsert_thinking(acc.thought_process, delta.turn, thinking)
    }
  end

  defp apply_event({:tool_call, id, name}, acc) do
    entry = Transcript.tool_entry(name, id, :running, acc.delta.turn)

    %{acc | transcript: Transcript.append(Transcript.finalize_streaming(acc.transcript), entry)}
  end

  defp apply_event({:tool_result, id, status}, acc) do
    %{
      acc
      | transcript: Transcript.put_tool_status(acc.transcript, id, tool_result_status(status))
    }
  end

  defp apply_event({:turn, info}, acc) do
    delta = %{
      acc.delta
      | turn: turn_number(info, acc.delta.turn),
        thinking: ""
    }

    %{
      acc
      | delta: delta,
        meta: update_meta(acc.meta, info),
        transcript: Transcript.finalize_streaming(acc.transcript)
    }
  end

  defp apply_event({:yield, text}, acc) do
    transcript =
      if is_binary(text) and text != "" do
        Transcript.finalize_assistant(acc.transcript, text)
      else
        Transcript.finalize_streaming(acc.transcript)
      end

    %{acc | transcript: transcript, outcome: :yield}
  end

  defp apply_event({:finished, status}, acc) do
    %{
      acc
      | transcript: Transcript.finalize_streaming(acc.transcript),
        outcome: {:finished, status}
    }
  end

  defp apply_event(_event, acc), do: acc

  # --- thinking ---

  defp upsert_thinking(thought_process, turn, text) do
    entries = if is_list(thought_process), do: thought_process, else: []
    entry = thinking_thought(turn, text)

    if thinking_thought?(List.last(entries), turn) do
      Enum.drop(entries, -1) ++ [entry]
    else
      Enum.take(entries ++ [entry], -@max_thought_entries)
    end
  end

  defp thinking_thought?(%{turn: turn, data: %{metadata: %{thinking: true}}}, turn), do: true
  defp thinking_thought?(_entry, _turn), do: false

  defp thinking_thought(turn, text) do
    %{
      turn: turn,
      timestamp: System.system_time(:second),
      type: "assistant",
      data: %{
        content: "",
        tool_calls: [],
        reasoning_details: [%{text: text, type: "thinking"}],
        tool_name: nil,
        metadata: %{thinking: true}
      }
    }
  end

  # --- turn meta ---

  defp turn_number(info, current) when is_map(info) do
    case meta_value(info, :turn, current) do
      turn when is_integer(turn) and turn >= 0 -> turn
      _turn -> current
    end
  end

  defp turn_number(_info, current), do: current

  defp update_meta(meta, info) do
    meta = if is_map(meta), do: Map.merge(meta(), meta), else: meta()

    %{
      turn: meta_value(info, :turn, Map.get(meta, :turn)),
      total_tokens: meta_value(info, :total_tokens, Map.get(meta, :total_tokens)),
      duration_ms: meta_value(info, :duration_ms, Map.get(meta, :duration_ms)),
      usage: meta_value(info, :usage, Map.get(meta, :usage))
    }
  end

  # Atom-keyed first, then the string-keyed variant (the payload may cross a
  # JSON/RPC boundary), else the previous value.
  defp meta_value(info, key, default) when is_map(info) do
    cond do
      Map.has_key?(info, key) -> Map.get(info, key)
      Map.has_key?(info, Atom.to_string(key)) -> Map.get(info, Atom.to_string(key))
      true -> default
    end
  end

  defp meta_value(_info, _key, default), do: default

  defp tool_result_status(:ok), do: :ok
  defp tool_result_status("ok"), do: :ok
  defp tool_result_status(:timeout), do: :timeout
  defp tool_result_status("timeout"), do: :timeout
  defp tool_result_status(_status), do: :error

  defp normalize_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp normalize_seq(_seq), do: 0

  defp snapshot_field(snapshot, key) do
    if is_map(snapshot), do: Map.get(snapshot, key)
  end
end
