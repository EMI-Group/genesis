defmodule EvoGit.AgentStateTest do
  @moduledoc """
  Core data-plane coverage for the durable agent-state subsystem
  (`EvoGit.AgentState` + `EvoGit.AgentState.Store` + `EvoGit.AgentState.Record`).

  Every test starts its OWN unnamed `EvoGit.AgentState` server on its own temp
  SQLite file and addresses it explicitly through the `store:` option, so the
  app-global `EvoGit.AgentState.Server` is never touched — hence `async: true`.

  Checkpoints are CASTS, so every read-backed assertion is preceded by
  `EvoGit.AgentState.flush/1` (the read-your-writes barrier). There is no
  `Process.sleep` anywhere: the flush reply is the synchronization point.

  Faults, retention, deletes and `server/0` seam behaviour are covered by the
  sibling suites in this directory.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.Store.RepoScope
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  ## Isolation helpers

  defp start_store!(tmp_dir, opts \\ []) do
    start_supervised!(
      {AgentState,
       Keyword.merge(
         [
           database: Path.join(tmp_dir, "agent_state.sqlite"),
           name: nil,
           prune_interval: 3_600_000
         ],
         opts
       )}
    )
  end

  defp checkpoint!(pid, task_id, agent_id, entry) do
    :ok = AgentState.checkpoint(task_id, agent_id, entry, store: pid)
    :ok = AgentState.flush(store: pid)
    :ok
  end

  defp load!(pid, task_id, agent_id) do
    assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
    record
  end

  defp sql!(pid, sql, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp chunks!(pid, task_id, agent_id) do
    sql!(
      pid,
      "SELECT seq, message_count, payload FROM agent_state_chunks " <>
        "WHERE task_id = ? AND agent_id = ? ORDER BY seq ASC",
      [task_id, agent_id]
    ).rows
  end

  defp counts!(pid, task_id, agent_id) do
    sql!(
      pid,
      "SELECT message_count, chunk_count FROM agent_states WHERE task_id = ? AND agent_id = ?",
      [task_id, agent_id]
    ).rows
  end

  ## Message fixtures

  defp msg(role, text), do: %Message{role: role, content: [ContentPart.text(text)]}

  defp tool_call_message(text, call_id \\ "call_1") do
    %Message{
      role: :assistant,
      content: [ContentPart.text(text)],
      tool_calls: [ReqLLM.ToolCall.new(call_id, "read", ~s({"path":"a.txt"}))]
    }
  end

  defp tool_result_message(text, call_id \\ "call_1") do
    %Message{role: :tool, tool_call_id: call_id, content: [ContentPart.text(text)]}
  end

  defp multimodal_message do
    %Message{
      role: :user,
      content: [
        ContentPart.text("look"),
        ContentPart.image(<<137, 80, 78, 71>>, "image/png"),
        ContentPart.file(<<1, 2, 3, 4>>, "clip.mp3", "audio/mpeg")
      ]
    }
  end

  ## 1. Append + load round-trip exactness

  describe "append + load round-trip" do
    test "a rewrite and an append round-trip every message struct EXACTLY", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_roundtrip"
      agent_id = 1

      initial = [
        msg(:system, "you are an agent"),
        msg(:user, "please read a.txt"),
        multimodal_message(),
        tool_call_message("calling read"),
        tool_result_message("a.txt contents")
      ]

      checkpoint!(pid, task_id, agent_id, %{
        kind: :rewrite,
        messages: initial,
        fields: %{phase: "init"}
      })

      record = load!(pid, task_id, agent_id)

      assert record.messages == initial
      assert record.message_count == length(initial)
      assert record.chunk_count == 1
      assert Enum.all?(record.messages, &is_struct(&1, Message))

      # The media parts survive the blob codec unchanged, not just the text.
      assert [%ContentPart{type: :text, text: "look"}, image, audio] =
               Enum.at(record.messages, 2).content

      assert %ContentPart{type: :image} = image
      assert image.data == <<137, 80, 78, 71>>
      assert image.media_type == "image/png"
      assert %ContentPart{type: :file} = audio
      assert audio.data == <<1, 2, 3, 4>>
      assert audio.media_type == "audio/mpeg"

      # Tool-call identity survives too.
      call = Enum.at(record.messages, 3)
      assert [%ReqLLM.ToolCall{id: "call_1", function: %{name: "read"}}] = call.tool_calls
      assert Enum.at(record.messages, 4).tool_call_id == "call_1"

      tail = [
        tool_call_message("calling again", "call_2"),
        tool_result_message("second", "call_2")
      ]

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: length(initial),
        messages: tail,
        fields: %{}
      })

      record = load!(pid, task_id, agent_id)

      assert record.messages == initial ++ tail
      assert record.message_count == length(initial) + length(tail)
      assert record.chunk_count == 2
      assert Enum.all?(record.messages, &is_struct(&1, Message))
      assert Enum.at(record.messages, -1) == tool_result_message("second", "call_2")
    end
  end

  ## 2. Write amplification: an append stores ONLY its tail

  describe "write amplification" do
    test "N appends store N tail-only chunks with contiguous seqs", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_amplification"
      agent_id = 7
      appends = 5

      first = msg(:system, "system prompt")
      tails = for index <- 1..appends, do: [msg(:user, "turn #{index}")]

      checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: [first], fields: %{}})
      assert counts!(pid, task_id, agent_id) == [[1, 1]]

      tails
      |> Enum.with_index(1)
      |> Enum.reduce(1, fn {tail, index}, accumulated ->
        checkpoint!(pid, task_id, agent_id, %{
          kind: :append,
          base_seq: accumulated,
          messages: tail,
          fields: %{}
        })

        assert [[message_count, chunk_count]] = counts!(pid, task_id, agent_id)
        assert message_count == accumulated + length(tail)
        # ONE rewrite chunk (seq 0) plus one chunk per completed append.
        assert chunk_count == 1 + index

        accumulated + length(tail)
      end)

      rows = chunks!(pid, task_id, agent_id)
      assert length(rows) == appends + 1
      assert Enum.map(rows, fn [seq, _count, _payload] -> seq end) == Enum.to_list(0..appends)

      assert [[_seq, 1, initial_payload]] = Enum.take(rows, 1)
      assert Record.decode_messages(initial_payload) == {:ok, [first]}

      append_sizes =
        rows
        |> Enum.drop(1)
        |> Enum.zip(tails)
        |> Enum.map(fn {[_seq, count, payload], tail} ->
          # The chunk's message_count is its TAIL length, never the accumulated one.
          assert count == 1
          assert count == length(tail)
          assert Record.decode_messages(payload) == {:ok, tail}
          # The blob is byte-identical to encoding just this tail in Elixir
          # (`term_to_binary` is deterministic for the same term).
          assert byte_size(payload) == byte_size(Record.encode_messages(tail))

          byte_size(payload)
        end)

      max_tail_size =
        tails
        |> Enum.map(&byte_size(Record.encode_messages(&1)))
        |> Enum.max()

      # Bytes are O(delta), never O(N²): no append ever re-stores an earlier tail.
      assert Enum.sum(append_sizes) <= 2 * appends * max_tail_size
    end
  end

  ## 3. Compression ⇒ rewrite

  describe "rewrite after compression" do
    test "replaces every chunk with one and restarts seq/count consistently", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_compression"
      agent_id = 3

      m1 = msg(:system, "system")
      m2 = msg(:user, "objective")
      m3 = msg(:assistant, "ack")
      m4 = msg(:user, "follow-up")
      m5 = msg(:user, "after compression")

      checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: [m1, m2, m3], fields: %{}})

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 3,
        messages: [m4],
        fields: %{}
      })

      pre = load!(pid, task_id, agent_id)
      assert pre.messages == [m1, m2, m3, m4]
      assert pre.chunk_count == 2
      assert pre.message_count == 4

      # A compression checkpoint shrinks the conversation back to two messages.
      checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: [m1, m2], fields: %{}})

      record = load!(pid, task_id, agent_id)
      assert record.messages == [m1, m2]
      assert record.message_count == 2
      assert record.chunk_count == 1

      assert chunks!(pid, task_id, agent_id)
             |> Enum.map(fn [seq, count, _payload] -> {seq, count} end) ==
               [{0, 2}]

      assert counts!(pid, task_id, agent_id) == [[2, 1]]

      # The rewritten counts are the new baseline: an append at base_seq 2 works.
      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 2,
        messages: [m5],
        fields: %{}
      })

      record = load!(pid, task_id, agent_id)
      assert record.messages == [m1, m2, m5]
      assert record.message_count == 3
      assert record.chunk_count == 2

      assert chunks!(pid, task_id, agent_id) |> Enum.map(fn [seq, _count, _payload] -> seq end) ==
               [0, 1]
    end
  end

  ## 4. Gap detection / resync

  describe "continuity gaps" do
    test "a divergent base_seq writes nothing and notifies the owner", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_gap"
      agent_id = 1

      messages = [msg(:system, "system"), msg(:user, "one"), msg(:user, "two")]
      checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: messages, fields: %{}})

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 1,
        messages: [msg(:user, "divergent tail")],
        fields: %{},
        owner: self()
      })

      # The server notifies BEFORE answering the flush, so the barrier makes
      # this mailbox assertion deterministic.
      assert_receive {:agent_state_resync, ^task_id, ^agent_id}

      record = load!(pid, task_id, agent_id)
      assert record.messages == messages
      assert record.message_count == 3
      assert record.chunk_count == 1
      assert length(chunks!(pid, task_id, agent_id)) == 1
    end

    test "base_seq > 0 against a missing row notifies and creates nothing", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_missing_row"
      agent_id = 2

      assert {:error, :not_found} = AgentState.load(task_id, agent_id, store: pid)

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 3,
        messages: [msg(:user, "orphan tail")],
        fields: %{},
        owner: self()
      })

      assert_receive {:agent_state_resync, ^task_id, 2}

      assert {:error, :not_found} = AgentState.load(task_id, agent_id, store: pid)
      assert counts!(pid, task_id, agent_id) == []
      assert chunks!(pid, task_id, agent_id) == []

      # A rewrite heals the run, then an append at the new base_seq succeeds.
      healed = [msg(:system, "healed system"), msg(:user, "healed user")]
      checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: healed, fields: %{}})
      next = msg(:user, "after heal")

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 2,
        messages: [next],
        fields: %{}
      })

      record = load!(pid, task_id, agent_id)
      assert record.messages == healed ++ [next]
      assert record.chunk_count == 2
      refute_received {:agent_state_resync, _task, _agent}
    end
  end

  ## 5. Empty append tail

  describe "empty append tails" do
    test "an empty tail on a fresh store creates the row with fields and no chunk", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      task_id = "task_empty_append"
      agent_id = 4

      assert {:error, :not_found} = AgentState.load(task_id, agent_id, store: pid)

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 0,
        messages: [],
        fields: %{phase: "start"}
      })

      record = load!(pid, task_id, agent_id)
      assert record.messages == []
      assert record.message_count == 0
      assert record.chunk_count == 0
      assert record.fields[:phase] == "start"
      assert chunks!(pid, task_id, agent_id) == []
      assert counts!(pid, task_id, agent_id) == [[0, 0]]

      # A non-empty append at base_seq 0 then inserts chunk seq 0.
      message = msg(:user, "first real message")

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 0,
        messages: [message],
        fields: %{}
      })

      record = load!(pid, task_id, agent_id)
      assert record.messages == [message]
      assert record.chunk_count == 1

      assert chunks!(pid, task_id, agent_id)
             |> Enum.map(fn [seq, count, _payload] -> {seq, count} end) == [{0, 1}]
    end

    test "an empty tail on an existing row inserts no chunk but still upserts fields", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      task_id = "task_empty_append_existing"
      agent_id = 5

      message = msg(:system, "system")

      checkpoint!(pid, task_id, agent_id, %{
        kind: :rewrite,
        messages: [message],
        fields: %{phase: "init"}
      })

      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 1,
        messages: [],
        fields: %{phase: "mid", turn: 2}
      })

      record = load!(pid, task_id, agent_id)
      assert record.messages == [message]
      assert record.message_count == 1
      assert record.chunk_count == 1
      assert record.fields[:phase] == "mid"
      assert record.fields[:turn] == 2
      assert length(chunks!(pid, task_id, agent_id)) == 1
    end
  end

  ## 6. Field mapping

  describe "field mapping" do
    test "supplied fields map to columns and round-trip through the record", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_fields"
      agent_id = 6

      checkpoint!(pid, task_id, agent_id, %{
        kind: :rewrite,
        messages: [msg(:user, "do it")],
        fields: %{
          agent_module: __MODULE__,
          depth: 2,
          repo_less: true,
          archive: false,
          objective: "do it",
          model_spec: %{"provider_profile_id" => "acct", "model" => "m1"},
          usage: %{"input_tokens" => 5},
          pending_inputs: [%{"text" => "hi"}],
          totally_unknown_key: "ignored"
        }
      })

      record = load!(pid, task_id, agent_id)
      fields = record.fields

      assert fields.agent_module == __MODULE__
      assert fields.depth == 2
      assert fields.repo_less == true
      assert fields.archive == false
      assert fields.objective == "do it"
      # JSON columns decode to Jason's native STRING-keyed shape.
      assert fields.model_spec == %{"provider_profile_id" => "acct", "model" => "m1"}
      assert fields.usage == %{"input_tokens" => 5}
      assert fields.pending_inputs == [%{"text" => "hi"}]
      refute Map.has_key?(fields, :totally_unknown_key)

      # Never-written nullable columns stay nil; the NOT NULL columns answer
      # their migration defaults instead.
      assert fields.node_path == nil
      assert fields.parent_id == nil
      assert fields.provider_profile_id == nil
      assert fields.repo_root == nil
      assert record.completed_at == nil
      assert fields.status == "running"
      assert fields.turn == 0
      assert fields.total_tokens == 0
      assert fields.compression_count == 0
      assert fields.model_id_locked == false

      # Booleans are stored as 0/1 and the module as its string form.
      assert sql!(
               pid,
               "SELECT repo_less, archive, model_id_locked FROM agent_states " <>
                 "WHERE task_id = ? AND agent_id = ?",
               [task_id, agent_id]
             ).rows == [[1, 0, 0]]

      assert sql!(
               pid,
               "SELECT agent_module, depth, objective FROM agent_states WHERE task_id = ? AND agent_id = ?",
               [task_id, agent_id]
             ).rows == [[Atom.to_string(__MODULE__), 2, "do it"]]

      # An UPSERT writes ONLY the supplied columns: omitted keys keep their
      # earlier value rather than being reset to a default.
      checkpoint!(pid, task_id, agent_id, %{
        kind: :append,
        base_seq: 1,
        messages: [],
        fields: %{turn: 3}
      })

      fields = load!(pid, task_id, agent_id).fields

      assert fields.turn == 3
      assert fields.objective == "do it"
      assert fields.agent_module == __MODULE__
      assert fields.depth == 2
      assert fields.repo_less == true
      assert fields.model_spec == %{"provider_profile_id" => "acct", "model" => "m1"}
      assert fields.pending_inputs == [%{"text" => "hi"}]
    end
  end
end
