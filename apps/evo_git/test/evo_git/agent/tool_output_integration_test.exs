defmodule EvoGit.Agent.ToolOutputIntegrationTest do
  @moduledoc """
  Phase-3 END-TO-END coverage for the multimodal tool-output pipeline.

  Where `tool_output_pipeline_test.exs` pins the individual seams
  (`sanitize_tool_result/3`, `assemble_tool_result/3`,
  `apply_tool_output_tracking/3`), this suite drives a **TEST-ONLY fake tool**
  that returns an `%EvoGit.Agent.ToolOutput{}` carrying a real (1x1) PNG all the
  way through the REAL dispatch plumbing — `batch_execute_tools/4`'s serial and
  parallel phases, sanitize/truncation, the redundant-cd + delegation-hint
  appenders, and `process_regular_tool_calls/3`'s message assembly — and asserts
  the resulting tool-result message content.

  ## The fake-tool seam (app env, test-only)

  `EvoGit.Agent.Tools.execute/5` consults the app env
  `:evo_git, :tool_dispatch_test_tools` — a map of `tool_name =>
  fun.(args, repo_path, repo_root, node_path)` — AFTER the two write guards and
  BEFORE built-in dispatch, passing the fun's return value through verbatim (so a
  fake tool CAN return a `%ToolOutput{}`). The env is unset in production, so
  dispatch is byte-identical there. The registry is installed per test and
  removed in `on_exit`.

  Built-in tool NAMES are used deliberately (`write_file` — serial,
  `read_file`/`run_bash` — parallel) so the REAL name-driven behaviours under
  test (the serial/parallel partition, the write delegation hint, the
  redundant-cd warning) are exercised rather than stubbed.

  Serialized (`async: false`) — the pipeline registers agent state in the
  app-global `:evogit_agent_state` ETS table, acquires slots from the global
  `EvoGit.AgentScheduler`, and mutates a global app env (the fake-tool registry),
  exactly like the sibling `tool_output_pipeline_test.exs` /
  `tool_dispatch_serial_batch_test.exs`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.DelegationHints
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.ToolOutput
  alias EvoGit.Adapters.Git

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  # A real 1x1 transparent PNG (base64) — exercises the `image` materialization
  # path (`ContentPart.image/2`) with genuinely valid PNG bytes.
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  @png_media_type "image/png"

  # The platform shell tool name (`run_bash` / `run_powershell`) — the only names
  # `maybe_append_redundant_cd_warning/4` reacts to.
  @shell_tool_name if(EvoGit.Platform.os() == :windows, do: "run_powershell", else: "run_bash")

  setup do
    repo = new_repo!()
    {:ok, head} = Git.rev_parse(repo)
    agent_id = 9_950_000 + :erlang.unique_integer([:positive])

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

  # ---------------------------------------------------------------------------
  # 1. Text + image flow END-TO-END through BOTH batch paths
  # ---------------------------------------------------------------------------

  describe "text + image flow end-to-end through the real batch dispatch" do
    test "the SERIAL path materializes [text | image]", %{repo: repo} do
      install_fake_tools(%{"write_file" => fake_media_tool("serial output")})

      call = tool_call("write_file", %{"file_path" => "./out.txt", "content" => "x"})

      assert [msg] = run_pipeline([call], repo)

      assert %Message{} = msg
      assert msg.role == :tool
      assert msg.tool_call_id == call.id
      assert msg.name == "write_file"

      assert [text_part, image_part] = msg.content
      assert text_part == ContentPart.text("serial output")
      assert image_part == png_content_part()
    end

    test "the PARALLEL path materializes [text | image]", %{repo: repo} do
      install_fake_tools(%{"read_file" => fake_media_tool("parallel output")})

      call = tool_call("read_file", %{"file_path" => "./out.txt"})

      assert [msg] = run_pipeline([call], repo)

      assert msg.role == :tool
      assert msg.tool_call_id == call.id
      assert msg.name == "read_file"

      assert [text_part, image_part] = msg.content
      assert text_part == ContentPart.text("parallel output")
      assert image_part == png_content_part()
    end

    test "one batch carrying BOTH a serial and a parallel fake tool keeps media in both", %{
      repo: repo
    } do
      install_fake_tools(%{
        "write_file" => fake_media_tool("SERIAL_TEXT"),
        "read_file" => fake_media_tool("PARALLEL_TEXT")
      })

      calls = [
        tool_call("write_file", %{"file_path" => "./a.txt", "content" => "x"}),
        tool_call("read_file", %{"file_path" => "./a.txt"})
      ]

      assert [serial_msg, parallel_msg] = run_pipeline(calls, repo)

      # Results come back in request order (the serial call was index 0).
      assert serial_msg.name == "write_file"
      assert parallel_msg.name == "read_file"

      assert [serial_text, serial_image] = serial_msg.content
      assert serial_text == ContentPart.text("SERIAL_TEXT")
      assert serial_image == png_content_part()

      assert [parallel_text, parallel_image] = parallel_msg.content
      assert parallel_text == ContentPart.text("PARALLEL_TEXT")
      assert parallel_image == png_content_part()
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Hint appenders preserve the media while changing the text
  # ---------------------------------------------------------------------------

  describe "hint appenders preserve media (real batch pipeline)" do
    test "the write delegation hint extends the TEXT and keeps the image", %{repo: repo} do
      install_fake_tools(%{"write_file" => fake_media_tool("edited")})

      threshold = DelegationHints.delegation_hint_threshold()
      assert threshold >= 1, "the write delegation hint must be enabled for this test"

      # `threshold` write calls into the SAME child directory — the LAST one
      # crosses the threshold and receives the nudge. All of them are serial
      # (file-mutating), so the tracking accumulates deterministically in the
      # parent process, in request order.
      calls =
        for i <- 1..threshold do
          tool_call("write_file", %{
            "file_path" => "./child/thing#{i}.ex",
            "content" => "x"
          })
        end

      messages = run_pipeline(calls, repo)
      assert length(messages) == threshold

      # The first calls crossed nothing — their text is unchanged.
      assert [%Message{content: [%ContentPart{text: "edited"}, _image]} | _] = messages

      # ...and the last one carries the hint, with the image still riding along.
      assert [last_text, last_image] = List.last(messages).content
      assert last_text.text =~ "edited"
      assert last_text.text =~ "Delegation Hint"
      assert last_image == png_content_part()
    end

    test "the redundant-cd warning extends the TEXT and keeps the image", %{repo: repo} do
      install_fake_tools(%{@shell_tool_name => fake_media_tool("cmd output")})

      call = tool_call(@shell_tool_name, %{"command" => "cd #{repo} && ls"})

      assert [msg] = run_pipeline([call], repo)

      assert [text_part, image_part] = msg.content
      assert text_part.text =~ "cmd output"
      assert text_part.text =~ "don't need to `cd`"
      assert image_part == png_content_part()
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Truncation changes the text but retains the media
  # ---------------------------------------------------------------------------

  describe "truncation retains media" do
    test "an oversized text is truncated while the image survives", %{repo: repo} do
      big = String.duplicate("x", 100_000)

      install_fake_tools(%{
        "read_file" => fn _args, _repo, _root, _node ->
          ToolOutput.new(big, [png_attachment()])
        end
      })

      # A per-call `max_bytes` keeps the effective limit tiny (and config-independent).
      call = tool_call("read_file", %{"file_path" => "./big.txt", "max_bytes" => 512})

      assert [msg] = run_pipeline([call], repo)

      assert [text_part, image_part] = msg.content
      assert byte_size(text_part.text) < byte_size(big)
      assert text_part.text =~ "Output truncated"
      assert image_part == png_content_part()
    end
  end

  # ---------------------------------------------------------------------------
  # 4 + 5. Plain-string results stay byte-identical
  # ---------------------------------------------------------------------------

  describe "plain-string results stay byte-identical" do
    test "a merged SUBAGENT result string materializes as a byte-identical tool_result" do
      # Subagent results are STRINGS produced by `EvoGit.Agent.SubagentProcessing`
      # and assembled by the SAME `assemble_tool_result/3` site; they must wrap
      # cleanly with no extra metadata (never promoted to a struct).
      id = "call_subagent_1"
      bin = "Investigator report: no issues found in ./lib (3 files scanned)."

      msg = ToolDispatch.assemble_tool_result(id, "subagent_investigator", bin)

      assert msg == ReqLLM.Context.tool_result(id, "subagent_investigator", bin)
      assert %Message{} = msg
      assert msg.role == :tool
      assert msg.tool_call_id == id
      assert msg.name == "subagent_investigator"
      assert msg.content == [ContentPart.text(bin)]
    end

    test "a plain-STRING fake tool through the real batch path is byte-identical", %{repo: repo} do
      # No blank lines / ANSI / carriage returns, so the BINARY-ONLY sanitizer is
      # a no-op and the pipeline MUST equal the legacy `tool_result/3` call.
      raw = "plain tool output line one\nline two"

      install_fake_tools(%{"read_file" => fn _args, _repo, _root, _node -> raw end})

      call = tool_call("read_file", %{"file_path" => "./x.txt"})

      assert [msg] = run_pipeline([call], repo)

      assert msg == ReqLLM.Context.tool_result(call.id, "read_file", raw)
      assert %Message{} = msg
      assert msg.content == [ContentPart.text(raw)]
    end
  end

  # --- Helpers ---

  # Drives the REAL dispatch plumbing for one LLM tool-call batch and returns the
  # assembled tool-result messages: `process_regular_tool_calls/3` partitions the
  # batch (serial/parallel), executes it via `batch_execute_tools/4`, applies the
  # sanitize/truncate + hint appenders per output, and materializes every output
  # at the `assemble_tool_result/3` message-construction site.
  defp run_pipeline(calls, repo) do
    state = %LoopState{
      agent_id: Process.get(:evogit_agent_id),
      agent_module: EvoGit.Agents.Executor,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new()
    }

    assert repo == Process.get(:repo_path)

    {:continue, messages, _usage} = ToolDispatch.process_regular_tool_calls(calls, state, [])
    messages
  end

  # Installs the test-only fake-tool registry (app env) for the duration of the
  # test and restores the previous value afterwards.
  defp install_fake_tools(tools) when is_map(tools) do
    previous = Application.get_env(:evo_git, :tool_dispatch_test_tools)
    Application.put_env(:evo_git, :tool_dispatch_test_tools, tools)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_git, :tool_dispatch_test_tools)
        _ -> Application.put_env(:evo_git, :tool_dispatch_test_tools, previous)
      end
    end)
  end

  # A fake tool returning `%ToolOutput{}` (text + a real PNG image).
  defp fake_media_tool(text, attachment \\ png_attachment()) do
    fn _args, _repo_path, _repo_root, _node_path -> ToolOutput.new(text, [attachment]) end
  end

  defp png_attachment do
    %{
      "type" => "image",
      "name" => "pixel.png",
      "media_type" => @png_media_type,
      "data" => @png_base64
    }
  end

  # The exact content part the pipeline must materialize for the PNG attachment.
  defp png_content_part do
    ContentPart.image(Base.decode64!(@png_base64), @png_media_type)
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
    repo = new_temp_dir!("tool_output_integration")
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end
end
