defmodule EvoDashWeb.HomeLive.Delta do
  @moduledoc """
  Pure reducer for the PUSH-ONLY agent-delta stream
  (`EvoGit.Agent.Stream`) on the Genesis Assistant chat page.

  The page keeps one `%Delta{}` per subscribed agent and feeds every
  `{:agent_delta, agent_id, seq, batch}` payload through
  `apply_batch/5`, which folds the batch's events into the whole chat
  surface at once:

    * `{:activity, projection}` — replaces the current call's text/thinking,
      keyed by its fresh attempt id; retry removes the failed attempt's output;
    * `{:text, chunk}` — appends to the current call and its assistant bubble
      (`EvoDashWeb.HomeLive.Transcript.append_streaming_text/2`) and recorded as
      this turn's streamed text;
    * `{:thinking, chunk}` — accumulated in `thinking` and mirrored into ONE
      upserted thought-process entry for the current turn (the bubble text
      excludes reasoning by design, see
      `EvoDashWeb.HomeLive.Messages.message_text/1`);
    * `{:tool_call, id, name}` — a `:tool` transcript entry appears (`:running`)
      while the streaming bubble stays OPEN, so text arriving after a tool call
      keeps accumulating into the SAME bubble (one bubble per turn);
    * `{:tool_result, id, status}` — that entry's status is updated;
    * `{:turn, info}` — turn meta/token accounting is recorded, the bubble is
      CLOSED (`EvoDashWeb.HomeLive.Transcript.close_streaming/1`, which drops a
      bubble that never received text), the thinking bucket starts over and the
      streamed-text flag moves to the closed turn;
    * `{:yield, text}` / `{:finished, status}` — the authoritative text is
      finalized / the bubble closed, and the batch reports `outcome` so the page
      can stop the stream and reconcile with the terminal task status.

  A turn therefore renders exactly ONE assistant bubble, closed only at a turn
  or terminal boundary, and a thinking/tool-only turn renders NO bubble at all.

  Everything here is PURE and TOTAL: no processes, no ETS, no side effects,
  and an unknown/malformed event (or a malformed batch) is ignored instead of
  raising — the delta payload crosses a `Phoenix.PubSub`/RPC boundary whose
  shape is owned by the `:evo_git` core.

  `seq` is the session's monotonic event sequence: reconciliation is
  `EvoGit.Agent.Stream.stale?/2` applied by the CALLER before `apply_batch/5`,
  and `seed/3` records the snapshot's seq/turn when the page attaches.
  """

  alias EvoDashWeb.HomeLive.{LiveCall, Transcript}

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
          thinking: String.t(),
          text_in_turn: boolean(),
          text_in_closed_turn: boolean(),
          activity: map() | nil,
          call_entry_id: String.t() | nil
        }

  defstruct agent_id: nil,
            node: nil,
            seq: 0,
            turn: 0,
            thinking: "",
            text_in_turn: false,
            text_in_closed_turn: false,
            activity: nil,
            call_entry_id: nil

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
  Whether this stream has produced assistant TEXT for the open turn, or for the
  turn that was closed last.

  The flag includes text hydrated from snapshot activity, not just chunks seen
  after attachment. A text-less finish can still request one checkpoint-history
  reconciliation. Total: a non-struct answers `false`.
  """
  @spec streamed_text?(term()) :: boolean()
  def streamed_text?(%__MODULE__{text_in_turn: in_turn, text_in_closed_turn: in_closed_turn}),
    do: in_turn == true or in_closed_turn == true

  def streamed_text?(_delta), do: false

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

  defp apply_event({:activity, projection}, acc), do: LiveCall.replace(acc, projection)

  defp apply_event({kind, chunk}, %{delta: %{activity: activity}} = acc)
       when kind in [:text, :thinking] and is_map(activity) and is_binary(chunk) do
    LiveCall.append(acc, kind, chunk)
  end

  defp apply_event({:text, chunk}, acc) when is_binary(chunk) and chunk != "" do
    transcript = Transcript.append_streaming_text(acc.transcript, chunk)
    id = streaming_id(transcript)

    %{
      acc
      | delta: %{acc.delta | text_in_turn: true, call_entry_id: id},
        transcript: transcript
    }
    |> retain_thinking()
  end

  defp apply_event({:thinking, chunk}, acc) when is_binary(chunk) and chunk != "" do
    thinking = acc.delta.thinking <> chunk
    delta = %{acc.delta | thinking: thinking}

    %{
      acc
      | delta: delta,
        thought_process: upsert_thinking(acc.thought_process, delta.turn, thinking)
    }
    |> retain_thinking()
  end

  # The bubble stays OPEN here: text arriving after a tool call belongs to the
  # SAME turn and keeps accumulating into it (one bubble per turn).
  defp apply_event({:tool_call, id, name}, acc) do
    entry = Transcript.tool_entry(name, id, :running, acc.delta.turn)

    %{acc | transcript: Transcript.append(acc.transcript, entry)}
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
        call_entry_id:
          streaming_id(acc.transcript) ||
            if(acc.delta.text_in_turn, do: acc.delta.call_entry_id),
        thinking: "",
        text_in_closed_turn: acc.delta.text_in_turn == true,
        text_in_turn: false
    }

    %{
      acc
      | delta: delta,
        meta: update_meta(acc.meta, info),
        transcript: Transcript.close_streaming(acc.transcript)
    }
  end

  defp apply_event({:yield, text}, acc) do
    transcript =
      if is_binary(text) and text != "" do
        case acc.delta.call_entry_id do
          nil ->
            Transcript.finalize_assistant(acc.transcript, text)

          id ->
            acc.transcript
            |> Enum.map(fn entry ->
              if entry.id == id, do: %{entry | text: text, streaming: false}, else: entry
            end)
            |> Transcript.normalize()
        end
      else
        Transcript.close_streaming(acc.transcript)
      end

    %{acc | transcript: transcript, outcome: :yield}
  end

  defp apply_event({:finished, status}, acc) do
    %{
      acc
      | transcript: Transcript.close_streaming(acc.transcript),
        outcome: {:finished, status}
    }
  end

  defp apply_event(_event, acc), do: acc

  defp streaming_id(transcript) do
    transcript
    |> Transcript.normalize()
    |> Enum.reverse()
    |> Enum.find_value(fn entry -> if entry.streaming and entry.text != "", do: entry.id end)
  end

  # --- thinking ---

  defp retain_thinking(%{delta: %{text_in_turn: false}} = acc), do: acc

  defp retain_thinking(acc) do
    thoughts =
      if acc.delta.thinking == "",
        do: [],
        else: [LiveCall.thinking_entry(acc.delta.turn, acc.delta.thinking)]

    %{
      acc
      | transcript: Transcript.put_reasoning(acc.transcript, acc.delta.call_entry_id, thoughts)
    }
  end

  defp upsert_thinking(thought_process, turn, text) do
    entries = if is_list(thought_process), do: thought_process, else: []
    entry = LiveCall.thinking_entry(turn, text)

    if thinking_thought?(List.last(entries), turn) do
      Enum.drop(entries, -1) ++ [entry]
    else
      Enum.take(entries ++ [entry], -@max_thought_entries)
    end
  end

  defp thinking_thought?(%{turn: turn, data: %{metadata: %{thinking: true}}}, turn), do: true
  defp thinking_thought?(_entry, _turn), do: false

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
