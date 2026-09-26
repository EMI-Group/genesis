defmodule EvoGit.Agent.ToolOutputPipelineTest do
  @moduledoc """
  Phase-2A pipeline coverage for MULTIMODAL tool outputs.

  A tool may return an `%EvoGit.Agent.ToolOutput{}` carrying media (images /
  audio); its tool-result message must then carry
  `[ContentPart.text(text) | media parts…]`. A plain-STRING tool return must stay
  BYTE-IDENTICAL to the legacy all-text path — that is asserted by struct
  equality against `ReqLLM.Context.tool_result/3`.

  The wrap boundary lives in `EvoGit.Agent.ToolDispatch` (see
  `EvoGit.Agent.ToolOutput`): `EvoGit.Agent.OutputSanitizer`,
  `EvoGit.Agent.TruncationFeedback` and `EvoGit.Agent.DelegationHints` stay
  BINARY-ONLY and never see a `%ToolOutput{}`.

  Serialized (`async: false`) — the batch-assembly describe below registers agent
  state in the app-global `:evogit_agent_state` ETS table and acquires slots from
  the global `EvoGit.AgentScheduler`, exactly like the sibling
  `tool_dispatch_serial_batch_test.exs`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.ToolOutput
  alias EvoGit.Adapters.Git
  alias ReqLLM.Message.ContentPart

  # A real 1x1 transparent PNG (base64) — exercises the `image` materialization
  # path (`ContentPart.image/2`).
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  # Arbitrary bytes standing in for an audio payload (`:file` part).
  @audio_base64 Base.encode64("ID3-fake-audio-bytes")

  @tool_timeout 1_800_000

  # ---------------------------------------------------------------------------
  # sanitize_tool_result/3 — the wrap boundary
  # ---------------------------------------------------------------------------

  describe "sanitize_tool_result/3 (wrap boundary)" do
    test "a plain-STRING return round-trips to the SAME binary" do
      result = ToolDispatch.sanitize_tool_result("hello world", "read_file", %{})

      assert result == "hello world"
      assert is_binary(result)
      refute is_struct(result, ToolOutput)
    end

    test "sanitization still applies and keeps an all-text return a plain binary" do
      # ANSI color codes are stripped by the BINARY-ONLY sanitizer.
      assert ToolDispatch.sanitize_tool_result("\e[31mred\e[0m text", "run_bash", %{}) ==
               "red text"
    end

    test "nil and unexpected non-binary returns pass through unchanged" do
      assert ToolDispatch.sanitize_tool_result(nil, "read_file", %{}) == nil
      assert ToolDispatch.sanitize_tool_result(:unexpected, "read_file", %{}) == :unexpected
    end

    test "a media-carrying %ToolOutput{} keeps its media and gets its text sanitized" do
      output = ToolOutput.new("\e[32mok\e[0m", [png_attachment()])

      result = ToolDispatch.sanitize_tool_result(output, "read_file", %{})

      assert %ToolOutput{} = result
      assert ToolOutput.text(result) == "ok"
      assert ToolOutput.media?(result)
      assert result.attachments == [png_attachment()]
    end

    test "truncation changes the TEXT and PRESERVES the media" do
      big = String.duplicate("x", 200_000)
      output = ToolOutput.new(big, [png_attachment()])

      result = ToolDispatch.sanitize_tool_result(output, "run_bash", %{})

      assert %ToolOutput{} = result
      text = ToolOutput.text(result)
      assert byte_size(text) < byte_size(big)
      assert text =~ "Output truncated"
      assert result.attachments == [png_attachment()]
    end

    test "a %ToolOutput{} carrying no media collapses back to a plain binary" do
      output = ToolOutput.new("just text", nil)

      result = ToolDispatch.sanitize_tool_result(output, "read_file", %{})

      assert result == "just text"
      assert is_binary(result)
    end
  end

  # ---------------------------------------------------------------------------
  # assemble_tool_result/3 — the message-construction site
  # ---------------------------------------------------------------------------

  describe "assemble_tool_result/3 (message-construction site)" do
    test "regression: a plain-STRING output is BYTE-IDENTICAL to ReqLLM.Context.tool_result/3" do
      expected = ReqLLM.Context.tool_result("call_1", "read_file", "file contents")

      msg = ToolDispatch.assemble_tool_result("call_1", "read_file", "file contents")

      assert msg == expected
      assert msg.role == :tool
      assert msg.name == "read_file"
      assert msg.tool_call_id == "call_1"
      assert msg.content == [ContentPart.text("file contents")]
    end

    test "an image attachment rides AFTER the leading text part" do
      output = ToolOutput.new("look at this", [png_attachment()])

      msg = ToolDispatch.assemble_tool_result("call_2", "read_file", output)

      assert [text_part, image_part] = msg.content
      assert text_part == ContentPart.text("look at this")
      assert image_part.type == :image
      assert image_part.media_type == "image/png"
      assert image_part.data == Base.decode64!(@png_base64)

      # ...and it is exactly what ToolOutput materializes (no extra metadata).
      assert msg.content == ToolOutput.to_content_parts(output)
      assert msg.role == :tool
      assert msg.tool_call_id == "call_2"
    end

    test "an audio attachment rides as a :file part" do
      output = ToolOutput.new("listen", [audio_attachment()])

      msg = ToolDispatch.assemble_tool_result("call_3", "read_file", output)

      assert [text_part, file_part] = msg.content
      assert text_part == ContentPart.text("listen")
      assert file_part.type == :file
      assert file_part.filename == "clip.mp3"
      assert file_part.media_type == "audio/mpeg"
      assert file_part.data == Base.decode64!(@audio_base64)
    end

    test "a media-less %ToolOutput{} still yields the legacy one-text-part message" do
      output = ToolOutput.new("plain", nil)

      msg = ToolDispatch.assemble_tool_result("call_4", "read_file", output)

      assert msg == ReqLLM.Context.tool_result("call_4", "read_file", "plain")
    end

    test "both an image and an audio attachment materialize in input order" do
      output = ToolOutput.new("both", [png_attachment(), audio_attachment()])

      assert [
               %ContentPart{type: :text} = t,
               %ContentPart{type: :image},
               %ContentPart{type: :file}
             ] =
               ToolDispatch.assemble_tool_result("call_5", "read_file", output).content

      assert t.text == "both"
    end
  end

  # ---------------------------------------------------------------------------
  # Hint appenders preserve media
  # ---------------------------------------------------------------------------

  describe "hint appenders preserve media" do
    test "the redundant-cd warning extends the TEXT and keeps the attachments" do
      repo = new_temp_dir!("tool_output_cd")
      Process.delete(:redundant_cd_warned)

      output = ToolOutput.new("command output", [png_attachment()])
      args = %{"command" => "cd #{repo} && ls"}

      result =
        ToolDispatch.maybe_append_redundant_cd_warning(output, "run_bash", args, repo, repo)

      assert %ToolOutput{} = result
      assert ToolOutput.text(result) =~ "command output"
      assert ToolOutput.text(result) =~ "don't need to `cd`"
      assert ToolOutput.text(result) =~ repo
      assert result.attachments == [png_attachment()]
      assert ToolOutput.media?(result)
    end

    test "the redundant-cd warning on a plain binary stays a plain binary" do
      repo = new_temp_dir!("tool_output_cd_plain")
      Process.delete(:redundant_cd_warned)

      args = %{"command" => "cd #{repo} && ls"}

      result =
        ToolDispatch.maybe_append_redundant_cd_warning(
          "command output",
          "run_bash",
          args,
          repo,
          repo
        )

      assert is_binary(result)
      assert result =~ "command output"
      assert result =~ "don't need to `cd`"
    end

    test "delegation-hint tracking extends the TEXT and keeps the attachments" do
      repo = new_temp_dir!("tool_output_hint")

      output = ToolOutput.new("edited", [png_attachment()])

      call =
        tool_call("edit_file", %{
          "file_path" => "./child/thing.ex",
          "old_string" => "a",
          "new_string" => "b"
        })

      ctx = %{
        repo_path: repo,
        repo_root: repo,
        node_path: "./",
        threshold: 1,
        read_threshold: 0,
        conflict_files: [],
        delegation_level: :high
      }

      {results, hints, _read_hints} =
        ToolDispatch.apply_tool_output_tracking({0, call, output}, {[], %{}, %{}}, ctx)

      assert [{0, tool_call_id, "edit_file", tracked}] = results
      assert tool_call_id == call.id
      assert hints != %{}

      assert %ToolOutput{} = tracked
      assert ToolOutput.text(tracked) =~ "edited"
      assert ToolOutput.text(tracked) =~ "Delegation Hint"
      assert tracked.attachments == [png_attachment()]
      assert ToolOutput.media?(tracked)
    end
  end

  # ---------------------------------------------------------------------------
  # Batch pipeline: all-text outputs stay plain binaries
  # ---------------------------------------------------------------------------

  describe "batch pipeline keeps all-text outputs byte-identical" do
    setup do
      repo = new_repo!()
      {:ok, head} = Git.rev_parse(repo)
      agent_id = 9_970_000 + :erlang.unique_integer([:positive])

      agent_state = %EvoGit.AgentScheduler.AgentState{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: repo},
        phylo_node: %EvoGit.Core.PhyloGraphNode{
          repo: repo,
          base_commit: head,
          current_commit: head
        },
        llm_model: "test:model",
        max_retries: 1,
        max_depth: 1
      }

      :ok = EvoGit.AgentScheduler.Store.put_agent_state(agent_id, agent_state)

      Process.put(:evogit_agent_id, agent_id)
      Process.put(:repo_path, repo)
      Process.put(:genesis_repo_root, repo)

      on_exit(fn ->
        EvoGit.AgentScheduler.Store.delete_agent_state(agent_id)
        File.rm_rf!(repo)
      end)

      %{repo: repo}
    end

    test "serial + parallel outputs are plain binaries (never %ToolOutput{})", %{repo: repo} do
      File.write!(Path.join(repo, "notes.txt"), "NOTES_BODY\n")

      calls = [
        # `write_file` is a SERIAL (file-mutating) tool; `read_file` is PARALLEL.
        {tool_call("write_file", %{"file_path" => "./notes.txt", "content" => "fresh\n"}), 0},
        {tool_call("read_file", %{"file_path" => "./notes.txt"}), 1}
      ]

      results = ToolDispatch.batch_execute_tools(calls, @tool_timeout, repo, :high)

      assert Enum.map(results, &elem(&1, 0)) == [0, 1]

      for {_index, _id, _name, output} <- results do
        assert is_binary(output), "expected a plain binary, got: #{inspect(output)}"
        refute is_struct(output, ToolOutput)
      end

      # Net effect is unchanged: the serial write landed before the read.
      assert Enum.at(results, 1) |> elem(3) =~ "fresh"
    end

    test "process_regular_tool_calls/3 yields EXACTLY ReqLLM.Context.tool_result/3", %{repo: repo} do
      call = tool_call("write_file", %{"file_path" => "./regen.txt", "content" => "REGEN_BODY\n"})
      args = ReqLLM.ToolCall.args_map(call)

      # The exact binary the tool returns (deterministic for a fixed file). A
      # clean single-line output is untouched by the BINARY-ONLY sanitizer, so
      # the pipeline MUST be byte-identical to the legacy `tool_result/3` call.
      raw = EvoGit.Agent.Tools.execute("write_file", args, repo, repo, "./")
      assert is_binary(raw)
      assert ToolDispatch.sanitize_tool_result(raw, "write_file", args) == raw

      state = %LoopState{
        agent_id: Process.get(:evogit_agent_id),
        agent_module: EvoGit.Agents.Executor,
        depth: 0,
        node_path: "./",
        context: ReqLLM.Context.new()
      }

      assert {:continue, [msg], _usage} =
               ToolDispatch.process_regular_tool_calls([call], state, [])

      assert msg == ReqLLM.Context.tool_result(call.id, "write_file", raw)
      assert msg.content == [ContentPart.text(raw)]
      assert msg.role == :tool
      assert msg.name == "write_file"
      assert msg.tool_call_id == call.id
    end
  end

  # --- Helpers ---

  defp png_attachment do
    %{
      "type" => "image",
      "name" => "pixel.png",
      "media_type" => "image/png",
      "data" => @png_base64
    }
  end

  defp audio_attachment do
    %{
      "type" => "audio",
      "name" => "clip.mp3",
      "media_type" => "audio/mpeg",
      "data" => @audio_base64
    }
  end

  # Builds a `%ReqLLM.ToolCall{}` from a name + decoded args map, encoding the
  # args as JSON exactly like a provider response does.
  defp tool_call(name, args) do
    id = "call_#{name}_#{:erlang.unique_integer([:positive])}"
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
  end

  defp new_temp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Fresh temp git repo with one committed README.md and a deterministic
  # repo-local commit identity.
  defp new_repo! do
    repo = new_temp_dir!("tool_output_pipeline")
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end
end
