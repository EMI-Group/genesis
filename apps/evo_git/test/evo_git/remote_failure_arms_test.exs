defmodule EvoGit.RemoteNodeFailureArmsTest do
  @moduledoc """
  Failure-arm coverage for the `EvoGit.RemoteNode` RPC wrappers — the arms that
  decide what a caller sees when the local API (or the transport) does not
  simply succeed:

    * `send_agent_message/3` and `respond_approval/3` fold the local API reply
      through `unwrap_api_reply/1`: a plain success value keeps this module's
      historical `{:ok, value}` shape, while an API `{:error, reason}` is
      returned AS an error instead of being buried inside `{:ok, _}`.
    * `ls/2` propagates the transport failure unchanged (it never degrades to a
      default, unlike `file_exists?/2` / `dir?/2` / `read_project_config/2`).
    * `branch_exists?/3` is a total BOOLEAN predicate: any `{:error, _}` — an
      unreachable node, a dead transport, a non-boolean answer — reads `false`,
      so a dead node can never look like an existing branch and no caller ever
      has to handle an error tuple.

  The unreachable-node halves reuse `remote_node_test.exs`'s established fake
  node: on a non-distributed BEAM, `:erpc.call/5` to a foreign node fails
  immediately (no TCP timeout), so those cases are fast and deterministic.

  Async safety (`async: true`): the only shared state touched is ONE
  per-test-unique `:evogit_agent_summary` row (id base `9_910_000`, deleted in
  `on_exit`) and the `respond_approval/3` miss below, which is a READ-ONLY
  lookup on the app-global `EvoGit.CommandApproval` (an unknown request id pops
  nothing, broadcasts nothing). The registration/resolution round trip that
  actually mutates that service — the success fold — lives in
  `EvoGit.RemoteNodeApprovalFoldTest` (`async: false`, see its reason there).
  """
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.RemoteNode

  # A node name that definitely does not exist on this machine (the same fake
  # `remote_node_test.exs` uses): `:erpc.call/5` answers
  # `{:error, {:erpc, :noconnection}}` immediately on a non-distributed BEAM.
  @fake_remote :"nonexistent@127.0.0.1"

  # ── send_agent_message/3 — API reply folding ─────────────────────────

  describe "send_agent_message/3 — API reply folding" do
    test "a plain success value keeps the historical {:ok, value} shape" do
      agent_id = live_agent_row!()

      # A live agent row is what licenses an append, so this is a REAL success
      # from `RemoteAPI.send_agent_message/2` (`:ok`), not a stub.
      assert RemoteNode.send_agent_message(node(), agent_id, "hello from the dashboard") ==
               {:ok, :ok}

      # ...and the message really landed in the agent's inbox exactly once.
      assert ControlPlane.pending_messages(agent_id) == ["hello from the dashboard"]
    end

    test "an ended agent's {:error, :not_found} is returned as an ERROR, never nested" do
      # No live row for this id — the agent has ended, so the queue refuses the
      # append. The wrapper must surface that as `{:error, :not_found}` rather
      # than `{:ok, {:error, :not_found}}` (which would read as "delivered").
      assert RemoteNode.send_agent_message(node(), 9_910_999, "hello") == {:error, :not_found}
    end

    test "any other error tag travels through unchanged" do
      # The transport failure is NOT folded and NOT flattened: the exact term
      # `call_remote/4` produced is what the caller receives.
      assert {:error, rpc_reason} =
               RemoteNode.call_remote(
                 @fake_remote,
                 EvoGit.AgentScheduler.RemoteAPI,
                 :send_agent_message,
                 [
                   1,
                   "hello"
                 ]
               )

      assert RemoteNode.send_agent_message(@fake_remote, 1, "hello") == {:error, rpc_reason}

      # `call_remote/4` normalizes every erpc failure into `{kind, reason}`.
      assert {kind, _reason} = rpc_reason
      assert is_atom(kind)
    end
  end

  # ── respond_approval/3 — API reply folding ───────────────────────────

  describe "respond_approval/3 — API reply folding" do
    test "an unknown or already-resolved request is {:error, :not_found}, never nested" do
      assert RemoteNode.respond_approval(node(), "no-such-request-id", :approve) ==
               {:error, :not_found}

      # `:deny` takes the same fold (only the decision differs).
      assert RemoteNode.respond_approval(node(), "no-such-request-id", :deny) ==
               {:error, :not_found}
    end

    test "any other error tag travels through unchanged" do
      assert {:error, rpc_reason} =
               RemoteNode.call_remote(
                 @fake_remote,
                 EvoGit.AgentScheduler.RemoteAPI,
                 :respond_approval,
                 ["req-1", :approve]
               )

      assert RemoteNode.respond_approval(@fake_remote, "req-1", :approve) == {:error, rpc_reason}
      assert {kind, _reason} = rpc_reason
      assert is_atom(kind)
    end
  end

  # ── ls/2 — transport failures are propagated, never degraded ─────────

  describe "ls/2 — error propagation" do
    test "a local success passes straight through" do
      assert {:ok, names} = RemoteNode.ls(node(), System.tmp_dir!())
      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
    end

    test "a local API error is NOT wrapped into {:ok, _}" do
      # `RemoteAPI.ls/1` is `File.ls/1`; the local-direct branch returns its
      # envelope verbatim.
      assert RemoteNode.ls(
               node(),
               "/definitely/not/a/real/dir/#{System.unique_integer([:positive])}"
             ) ==
               {:error, :enoent}
    end

    test "an unreachable node's transport error is propagated unchanged" do
      assert {:error, rpc_reason} =
               RemoteNode.call_remote(@fake_remote, EvoGit.AgentScheduler.RemoteAPI, :ls, ["/tmp"])

      # Byte-identical to what `call_remote/4` produced: `ls/2` neither
      # degrades to `{:ok, []}` nor re-wraps the reason.
      assert RemoteNode.ls(@fake_remote, "/tmp") == {:error, rpc_reason}

      # The documented `{kind, reason}` shape of a normalized RPC failure.
      assert {kind, _reason} = rpc_reason
      assert is_atom(kind)
    end
  end

  # ── branch_exists?/3 — total boolean predicate ───────────────────────

  describe "branch_exists?/3 — false on ANY error" do
    test "an unreachable node is false (the error tuple is never leaked)" do
      answer = RemoteNode.branch_exists?(@fake_remote, "/tmp", "evogit-agent-T1-A1")

      # Not an error tuple, not a raise: callers branch on a boolean.
      assert is_boolean(answer)
      assert answer == false
    end

    test "a missing repo path is false, never a raise" do
      missing =
        Path.join(System.tmp_dir!(), "evogit-missing-repo-#{System.unique_integer([:positive])}")

      assert RemoteNode.branch_exists?(node(), missing, "main") == false
    end

    test "a real repo without the branch is false (control: the same call answers true for a real branch)" do
      repo = init_repo_with_branch!("main")

      assert RemoteNode.branch_exists?(node(), repo, "main") == true
      assert RemoteNode.branch_exists?(node(), repo, "evogit-agent-T1-A1") == false
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Registers ONE per-test-unique scheduler agent row (the summary-table shape
  # production matches on — never a plain map) so an append is licensed, and
  # removes it again in `on_exit` (`delete_agent_state/1` also clears the
  # inbox/control-plane entry, so no pending message leaks).
  defp live_agent_row! do
    agent_id = 9_910_000 + System.unique_integer([:positive])

    :ok =
      Store.put_agent_state(agent_id, %AgentState{
        context_node: %ContextNode{path: "./", repo: File.cwd!()},
        llm_model: "test:model",
        max_retries: 1,
        max_depth: 1,
        repo_root: File.cwd!(),
        task_local_id: 1
      })

    on_exit(fn -> Store.delete_agent_state(agent_id) end)

    agent_id
  end

  # A throw-away git repo whose initial branch is `branch` — one `git init` plus
  # one `git branch -m`, with the shas/identity facts only what the test needs.
  defp init_repo_with_branch!(branch) do
    repo =
      Path.join(System.tmp_dir!(), "evogit-branch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: repo)
    # `branch -m` also renames an UNBORN branch, so no
    # `init.defaultBranch` setting can decide the name; the commit materializes
    # `refs/heads/<branch>` so `show-ref --verify` can actually find it.
    {_, 0} = System.cmd("git", ["branch", "-m", branch], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "--allow-empty", "-q", "-m", "init"], cd: repo)

    repo
  end
end

defmodule EvoGit.RemoteNodeApprovalFoldTest do
  @moduledoc """
  The SUCCESS half of `EvoGit.RemoteNode.respond_approval/3`'s
  `unwrap_api_reply/1` fold: a real pending approval request resolved through
  the node wrapper must come back as `{:ok, :ok}` — the historical
  `{:ok, value}` shape wrapping the API's plain `:ok` — and the blocked
  requester must observe `:approved`.

  `async: false` because it DRIVES the app-global `EvoGit.CommandApproval`
  singleton (registration + resolution mutates its pending map) and therefore
  publishes `{:approval_requested, …}` / `{:approval_resolved, …}` on the
  shared `"approvals"` PubSub topic. Those are the two forcing globals; the
  request's `command`/`request_id` are per-test unique so the messages this
  module asserts on are its own.
  """
  use ExUnit.Case, async: false

  alias EvoGit.RemoteNode

  test "a resolved pending request folds to {:ok, :ok} and unblocks the requester" do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, EvoGit.CommandApproval.topic())

    command = "remote_failure_arms.probe.#{System.unique_integer([:positive])}"
    test_pid = self()

    # `request/5` BLOCKS its caller until the decision lands, so it runs in its
    # own process (the level-2 shell path does exactly this in production).
    # `task_id: nil` means no task lifecycle can resolve it behind our back.
    requester =
      Task.async(fn ->
        result = EvoGit.CommandApproval.request(command, "args", 2, nil, nil)
        send(test_pid, {:requester_unblocked, result})
        result
      end)

    assert_receive {:approval_requested, %{command: ^command, request_id: request_id}}, 5_000

    # The wrapper returns the API's plain `:ok` as `{:ok, :ok}` (the
    # `unwrap_api_reply(other) -> {:ok, other}` clause) — never `{:ok, {:ok, _}}`.
    assert RemoteNode.respond_approval(node(), request_id, :approve) == {:ok, :ok}

    # The waiting caller was really released with that decision.
    assert_receive {:requester_unblocked, :approved}, 2_000
    assert Task.await(requester, 2_000) == :approved

    # Idempotence of the API side: the same id is gone, so a second respond is
    # the `:not_found` fold rather than a second success.
    assert RemoteNode.respond_approval(node(), request_id, :approve) ==
             {:error, :not_found}
  end
end
