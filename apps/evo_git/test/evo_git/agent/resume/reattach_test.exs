defmodule EvoGit.Agent.Resume.ReattachTest.StubSubagent do
  @moduledoc "A stub subagent module, so a `task` call classifies as `:subagent`."

  @doc "The subagent tool name the model calls."
  def subagent_tool_name, do: "task"

  @doc "The subagent tool description."
  def subagent_tool_description, do: "stub subagent"
end

defmodule EvoGit.Agent.Resume.ReattachTest.StubAgent do
  @moduledoc "The role the resumed parent runs as (it declares one subagent module)."

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the reattach stub agent."

  @doc "The role declares ONE subagent module."
  def subagent_modules, do: [EvoGit.Agent.Resume.ReattachTest.StubSubagent]

  @doc "No model-facing tools are needed: the repair never dispatches."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Resume.ReattachTest do
  @moduledoc """
  Pins the DURABLE REBUILD path of a resumed parent's subagent batch.

  `EvoGit.Agent.Resume.Reattach.resolve/3` first asks the scheduler for the
  batch that lives on the parent's `%SchedMeta{}` row (ETS, wiped by a restart).
  When that answers `{:error, :no_pending_batch}` the worker REBUILDS the batch
  from the children's durable rows — in ITS OWN process, never in the scheduler:

    * `EvoGit.Agent.Resume.RosterBatch` turns `agent_state.sqlite` rows into one
      slot per expected subagent call (finished children contribute their stored
      result, still-running ones a rebuilt spec + resume opts);
    * ONE `EvoGit.AgentScheduler.rebuild_subagent_batch/3` call installs it;
    * the answered batch is adopted through the SAME formatting and merge path a
      live batch uses.

  Contract pinned here:

    * the rebuild runs only on `:no_pending_batch` (a surviving batch is used as
      before, byte-identically);
    * a finished child's stored result answers its call — no re-spawn;
    * a still-running child arrives as a re-spawn plan (persisted id + resume
      opts);
    * a rebuilt same-repo commit is merged into the parent worktree;
    * `persistent_state: false` is fully inert — the roster is never read;
    * the rebuilt path is RECURSIVE: a re-spawned child runs the same steps for
      its own dangling batch;
    * a refusing rebuild degrades to the honest fallback text.

  ## Why `async: true`

  Every seam is an explicit option (`:reattach_fun`, `:rebuild_fun`,
  `:roster_fun`), so no scheduler, ETS row or app-env global is touched. The one
  worktree test keeps its own `:tmp_dir` git repo.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Resume
  alias EvoGit.Agent.Resume.Reattach
  alias EvoGit.Agent.Resume.ReattachTest.StubAgent
  alias EvoGit.Agent.Resume.ReattachTest.StubSubagent
  alias EvoGit.Agent.State
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentSpec

  @parent 9600
  @child_a 9601
  @child_b 9602
  @grandchild 9603
  @turn 4
  @task_id "reattach-rebuild-task"

  # --- The rebuild is the FALLBACK, never the first choice ---

  test "a surviving in-memory batch is used as before; no durable read happens" do
    kept = %Result{result: "kept", commit_sha: nil}

    reattach = fn agent_id, count ->
      send(self(), {:reattached, agent_id, count})
      {:ok, [{:ok, kept}]}
    end

    roster = fn task_id ->
      send(self(), {:roster_read, task_id})
      []
    end

    assert %{texts: texts, merge_note: nil} =
             Reattach.resolve(state(context: conversation([subagent_call("c0")])), [{0, call()}],
               reattach_fun: reattach,
               roster_fun: roster,
               turn: @turn
             )

    assert_received {:reattached, @parent, 1}
    refute_received {:roster_read, _task_id}
    assert texts == %{0 => formatted(kept)}
  end

  # --- A restart: the batch is rebuilt from the durable rows ---

  test "a finished child's durable result answers its call without a re-spawn" do
    stored = %Result{result: "durable child work", commit_sha: nil}
    running = %Result{result: "re-spawned child finished", commit_sha: nil}

    roster = roster_fun([
      done_row(@child_a, 0, stored),
      running_row(@child_b, 1)
    ])

    rebuild = fn agent_id, plan, opts ->
      send(self(), {:rebuilt, agent_id, plan, opts[:turn]})
      {:ok, [{:ok, stored}, {:ok, running}]}
    end

    slots = [{0, call()}, {1, call()}]

    assert %{texts: texts, merge_note: nil} =
             Reattach.resolve(state(context: conversation([subagent_call("c0"), subagent_call("c1")])), slots,
               reattach_fun: deny_reattach(),
               rebuild_fun: rebuild,
               roster_fun: roster,
               turn: @turn
             )

    assert_received {:rebuilt, @parent, plan, @turn}

    # ONE slot per expected call, in model call order, classified from the rows.
    assert plan.turn == @turn
    assert plan.expected_count == 2

    assert [done_entry, running_entry] = plan.entries
    assert done_entry.index == 0
    assert done_entry.status == :done
    assert done_entry.agent_id == @child_a
    assert {:ok, rebuilt_result} = done_entry.result
    assert rebuilt_result.result == stored.result
    assert rebuilt_result.commit_sha == "commit-9601"
    assert rebuilt_result.branch == "genesis/agent_9601"
    assert rebuilt_result.repo_id == "primary"

    assert running_entry.index == 1
    assert running_entry.status == :running
    assert running_entry.agent_id == @child_b
    assert %AgentSpec{} = running_entry.spec
    assert running_entry.spec.opts[:resume_agent_id] == @child_b
    assert running_entry.spec.opts[:restore_agent_state] == true

    assert texts == %{0 => formatted(stored), 1 => formatted(running)}
  end

  test "a slot with no durable row degrades only that call to the fallback text" do
    stored = %Result{result: "only child", commit_sha: nil}
    roster = roster_fun([done_row(@child_a, 0, stored)])

    rebuild = fn _agent_id, plan, _opts ->
      assert [%{status: :done}, %{status: :missing}] = plan.entries
      {:ok, [{:ok, stored}, {:error, :subagent_result_lost}]}
    end

    slots = [{0, call()}, {1, call()}]

    assert %{texts: texts} =
             Reattach.resolve(state(context: conversation([subagent_call("c0"), subagent_call("c1")])), slots,
               reattach_fun: deny_reattach(),
               rebuild_fun: rebuild,
               roster_fun: roster,
               turn: @turn
             )

    assert texts == %{0 => formatted(stored)}
  end

  # --- A rebuilt commit is MERGED, through the ordinary merge path ---

  test "a rebuilt child's commit is merged into the parent worktree", %{tmp_dir: tmp_dir} do
    fixture = subagent_fixture!(tmp_dir)

    roster =
      roster_fun([done_row(@child_a, 0, hd(fixture.results), current_commit: fixture.child_sha)])

    rebuild = fn _agent_id, _plan, _opts -> {:ok, [{:ok, hd(fixture.results)}]} end

    slots = [{0, subagent_call("c0")}]

    parent =
      state(
        context: conversation([subagent_call("c0")]),
        repo_path: fixture.repo,
        node_path: "./"
      )

    assert %{texts: texts} =
             Reattach.resolve(parent, slots,
               reattach_fun: deny_reattach(),
               rebuild_fun: rebuild,
               roster_fun: roster,
               turn: @turn
             )

    assert texts == %{0 => formatted(hd(fixture.results))}

    # The child's work is really IN the parent worktree, not merely reported.
    assert File.exists?(Path.join(fixture.repo, "src/b.ex"))
    refute File.exists?(Path.join(fixture.repo, "doc/x.md"))
  end

  # --- persistent_state: false stays fully inert ---

  test "persistent_state: false never reads the roster and never rebuilds" do
    roster = fn task_id ->
      send(self(), {:roster_read, task_id})
      []
    end

    rebuild = fn agent_id, plan, _opts ->
      send(self(), {:rebuilt, agent_id, plan})
      {:ok, []}
    end

    parent =
      state(context: conversation([subagent_call("c0")]), persistent_state: false)

    assert Reattach.resolve(parent, [{0, call()}],
             reattach_fun: deny_reattach(),
             rebuild_fun: rebuild,
             roster_fun: roster,
             turn: @turn
           ) == Reattach.empty()

    refute_received {:roster_read, _task_id}
    refute_received {:rebuilt, _agent_id, _plan}
  end

  # --- a refusing rebuild degrades honestly ---

  test "a rebuild that itself declines answers the honest fallback text" do
    roster = roster_fun([running_row(@child_b, 0)])

    rebuild = fn _agent_id, _plan, _opts -> {:error, :batch_in_flight} end

    assert Reattach.resolve(state(context: conversation([subagent_call("c0")])), [{0, call()}],
             reattach_fun: deny_reattach(),
             rebuild_fun: rebuild,
             roster_fun: roster,
             turn: @turn
           ) == Reattach.empty()
  end

  test "no :turn means the durable rebuild declines instead of guessing the batch" do
    roster = fn task_id ->
      send(self(), {:roster_read, task_id})
      []
    end

    assert Reattach.resolve(state(context: conversation([subagent_call("c0")])), [{0, call()}],
             reattach_fun: deny_reattach(),
             roster_fun: roster
           ) == Reattach.empty()

    refute_received {:roster_read, _task_id}
  end

  # --- RECURSION: a re-spawned child rebuilds ITS own batch ---

  test "a re-spawned child rebuilds its own dangling batch from its children's rows" do
    grandchild_result = %Result{result: "grandchild work", commit_sha: nil}

    child =
      state(
        agent_id: @child_a,
        context: conversation([subagent_call("gc0")], 7),
        turn: 7
      )

    roster =
      roster_fun([
        %Record{
          task_id: @task_id,
          agent_id: @grandchild,
          fields: %{
            status: "done",
            parent_id: @child_a,
            spawn_turn: 7,
            spawn_index: 0,
            robot: :irrelevant,
            result: %{"text" => grandchild_result.result}
          }
        }
      ])

    rebuild = fn agent_id, plan, _opts ->
      send(self(), {:rebuilt, agent_id, plan})
      {:ok, [{:ok, grandchild_result}]}
    end

    repaired =
      Resume.apply(child,
        reattach_fun: deny_reattach(),
        rebuild_fun: rebuild,
        roster_fun: roster
      )

    assert_received {:rebuilt, @child_a, plan}
    assert plan.turn == 7
    assert [%{index: 0, status: :done, agent_id: @grandchild}] = plan.entries

    # The grandchild's real answer is in the child's transcript, at its call.
    assert tool_text(repaired, "gc0") == formatted(grandchild_result)
    assert repaired.pending_tool_batch == nil
    # ONE notice, and the prompt prefix untouched.
    assert Resume.notice_present?(repaired.context)
    assert [system, first_user | _rest] = repaired.context.messages
    assert system.role == :system
    assert first_user.role == :user
  end

  # --- Fixtures ---

  defp state(attrs) do
    struct!(
      %State{
        agent_id: @parent,
        agent_module: StubAgent,
        depth: 0,
        node_path: "./",
        repo_id: "primary",
        task_id: @task_id,
        persistent_state: true,
        turn: @turn,
        context: ReqLLM.Context.new([]),
        resume_info: %{
          restore_agent_state: true,
          restored: true,
          retries: 2,
          retry_reason: :crash,
          worktree_resume_from: "abc1234"
        }
      },
      attrs
      |> Keyword.put_new(:pending_tool_batch, batch(attrs))
      |> Keyword.update(:context, nil, &context/1)
    )
  end

  defp context(%ReqLLM.Context{} = context), do: context
  defp context(messages) when is_list(messages), do: ReqLLM.Context.new(messages)
  defp context(other), do: other

  defp batch(attrs) do
    ToolBatch.build(dangling_calls(attrs[:context]), attrs[:turn] || @turn, [StubSubagent])
  end

  defp dangling_calls(%ReqLLM.Context{messages: messages}) when is_list(messages) do
    case List.last(messages) do
      %ReqLLM.Message{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
      _other -> []
    end
  end

  defp dangling_calls(_context), do: []

  defp conversation(calls, turn \\ @turn) do
    [
      %ReqLLM.Message{role: :system, content: [text_part("sys prompt")]},
      %ReqLLM.Message{role: :user, content: [text_part("the objective")]},
      %ReqLLM.Message{
        role: :assistant,
        content: [text_part("running tools")],
        tool_calls: calls,
        metadata: %{turn: turn}
      }
    ]
  end

  defp text_part(text), do: ReqLLM.Message.ContentPart.text(text)

  defp subagent_call(id) do
    %ReqLLM.ToolCall{
      id: id,
      type: "function",
      function: %{name: "task", arguments: Jason.encode!(%{"objective" => "child objective"})}
    }
  end

  defp call, do: subagent_call("ignored")

  defp tool_text(%State{context: %ReqLLM.Context{messages: messages}}, id) do
    Enum.find_value(messages, fn
      %ReqLLM.Message{role: :tool, tool_call_id: ^id} = message ->
        message.content
        |> Enum.map(fn
          %{text: text} when is_binary(text) -> text
          other -> inspect(other)
        end)
        |> Enum.join()

      _other ->
        nil
    end)
  end

  defp formatted(%Result{} = result), do: SubagentProcessing.format_subagent_result({:ok, result})

  defp deny_reattach do
    fn agent_id, count ->
      send(self(), {:reattached, agent_id, count})
      {:error, :no_pending_batch}
    end
  end

  defp roster_fun(records) do
    fn task_id ->
      send(self(), {:roster_read, task_id, records})
      records
    end
  end

  defp done_row(agent_id, index, %Result{} = result, opts \\ []) do
    %Record{
      task_id: @task_id,
      agent_id: agent_id,
      fields: %{
        status: "done",
        parent_id: @parent,
        spawn_turn: @turn,
        spawn_index: index,
        agent_module: EvoGit.Agents.Executor,
        objective: "child objective",
        node_path: "./",
        repo_id: "primary",
        base_commit: Keyword.get(opts, :current_commit, "base-#{agent_id}"),
        current_commit: Keyword.get(opts, :current_commit, "commit-#{agent_id}"),
        branch: "genesis/agent_#{agent_id}",
        anchor_ref: "refs/genesis/agent-state/#{@task_id}/#{agent_id}",
        result: %{"text" => result.result, "commit" => result.commit_sha}
      }
    }
  end

  defp running_row(agent_id, index) do
    %Record{
      task_id: @task_id,
      agent_id: agent_id,
      fields: %{
        status: "running",
        parent_id: @parent,
        spawn_turn: @turn,
        spawn_index: index,
        agent_module: EvoGit.Agents.Executor,
        objective: "child objective",
        node_path: "./",
        repo_id: "primary",
        base_commit: "base-#{agent_id}",
        current_commit: "commit-#{agent_id}",
        branch: "genesis/agent_#{agent_id}",
        anchor_ref: "refs/genesis/agent-state/#{@task_id}/#{agent_id}"
      }
    }
  end

  # A parent repo at a base commit plus ONE child branch carrying one commit —
  # exactly the shape a rebuilt (finished) subagent leaves behind.
  defp subagent_fixture!(tmp_dir) do
    repo = Path.join(tmp_dir, "parent")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"}
        ] do
      git!(repo, ["config", key, value])
    end

    base = commit_file!(repo, "src/a.ex", "defmodule A do\nend\n", "base")
    main = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    git!(repo, ["checkout", "-q", "-b", "child-src"])
    child_sha = commit_file!(repo, "src/b.ex", "defmodule B do\nend\n", "child")
    git!(repo, ["checkout", "-q", main])

    assert git!(repo, ["rev-parse", "HEAD"]) == base
    refute File.exists?(Path.join(repo, "src/b.ex"))

    %{
      repo: repo,
      results: [Result.new("child did the src work", child_sha, branch: "child-src")],
      child_sha: child_sha
    }
  end

  defp commit_file!(repo, path, content, message) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
