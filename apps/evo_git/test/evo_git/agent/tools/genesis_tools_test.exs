Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)
Code.require_file("../../../fixtures/task_control/mcp_tools_baseline.fixture", __DIR__)

defmodule EvoGit.Agent.Tools.GenesisToolsTest do
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools
  alias EvoGit.Agent.Tools.GenesisTools
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)

    Fixture.update_meta(fixture, fn meta ->
      %{
        meta
        | spec: %{
            meta.spec
            | opts:
                Keyword.put(
                  meta.spec.opts,
                  :assistant_conversation_id,
                  "tools-test-#{fixture.agent_id}"
                )
          }
      }
    end)

    on_exit(fn -> Fixture.stop(fixture) end)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")
    {:ok, fixture: fixture}
  end

  test "shared schemas preserve the nine MCP contracts exactly" do
    assert EvoGit.TaskControl.Tools.list() == EvoGit.TestSupport.MCPToolsBaseline.list()

    assert Enum.map(GenesisTools.schemas(), & &1.name) ==
             Enum.map(EvoGit.TaskControl.Tools.list(), & &1.name) ++ ["genesis_follow_task"]

    for schema <- GenesisTools.schemas(), schema.name != "genesis_follow_task" do
      original = Enum.find(EvoGit.TaskControl.Tools.list(), &(&1.name == schema.name))
      assert schema.parameter_schema == Jason.decode!(Jason.encode!(original.inputSchema))
    end
  end

  test "dispatch denies a model-forged identity and ordinary callers" do
    assert Tools.execute("genesis_list_tasks", %{}, "/", "/", nil) =~ "Error:"

    assert Tools.execute(
             "genesis_start_task",
             %{"agent_id" => 123, "task_id" => "fake"},
             "/",
             "/",
             nil
           ) =~ "Error:"

    refute_receive {:approval_requested, _}
  end

  test "a genuine assistant reads through actual dispatch without approval", %{fixture: fixture} do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_get_task", %{"task_id" => "missing"}, "/", "/", nil)
      end)

    assert Fixture.await(handle) =~ "not_found"
    refute_receive {:approval_requested, _}
  end

  test "invalid mutation parameters are rejected before approval", %{fixture: fixture} do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_cancel_task", %{"task_id" => "x", "force" => "yes"}, "/", "/", nil)
      end)

    assert Fixture.await(handle) =~ "Error:"
    refute_receive {:approval_requested, _}
  end

  test "structured approval binds immutable parameters and denies without execution", %{
    fixture: fixture
  } do
    args = %{"task_id" => "missing-target", "message" => "New requirements"}

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_send_message", args, "/", "/", nil)
      end)

    assert_receive {:approval_requested, request}, 3000
    assert request.kind == :task_control
    assert request.tool_name == "genesis_send_message"
    assert request.parameters == args
    assert request.target_task_id == "missing-target"
    assert request.conversation_id == "tools-test-#{fixture.agent_id}"
    assert request.target_node == node()
    assert request.agent_id == to_string(fixture.agent_id)
    assert EvoGit.CommandApproval.respond(request.request_id, :deny) == :ok
    assert Fixture.await(handle) =~ "denied"
    assert EvoGit.CommandApproval.respond(request.request_id, :approve) == {:error, :not_found}
  end

  test "approved structured calls use the shared backend and lifecycle is rechecked", %{
    fixture: fixture
  } do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_cancel_task", %{"task_id" => "missing-target"}, "/", "/", nil)
      end)

    assert_receive {:approval_requested, request}, 3000
    assert request.parameters == %{"task_id" => "missing-target", "force" => false}
    assert :ok == EvoGit.CommandApproval.respond(request.request_id, :approve)
    assert Fixture.await(handle) =~ "not_found"

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_cancel_task", %{"task_id" => "missing-target"}, "/", "/", nil)
      end)

    assert_receive {:approval_requested, request}, 3000
    Fixture.update_meta(fixture, &%{&1 | status: :completed})
    assert :ok == EvoGit.CommandApproval.respond(request.request_id, :approve)
    assert Fixture.await(handle) =~ "requires a live root reflective assistant"
  end

  test "approval timeout does not execute or leave a repeatable request", %{fixture: fixture} do
    previous = Application.get_env(:evo_git, :command_approval_timeout)
    Application.put_env(:evo_git, :command_approval_timeout, 20)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:evo_git, :command_approval_timeout),
        else: Application.put_env(:evo_git, :command_approval_timeout, previous)
    end)

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_cancel_task", %{"task_id" => "missing-target"}, "/", "/", nil)
      end)

    assert_receive {:approval_requested, request}, 3000
    assert Fixture.await(handle) =~ "timed out"
    assert EvoGit.CommandApproval.respond(request.request_id, :approve) == {:error, :not_found}
  end

  test "only explicit follow and successful approved starts associate tasks", %{
    fixture: fixture,
    data_dir: path
  } do
    conversation = "tools-test-#{fixture.agent_id}"

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "genesis_start_task",
          %{"path" => path, "objective" => "Build a tiny example", "task_type" => "genesis"},
          "/source",
          "/source",
          nil
        )
      end)

    assert_receive {:approval_requested, request}, 3000
    assert request.project_path == path
    assert request.parameters["mode"] == "new"
    assert :ok == EvoGit.CommandApproval.respond(request.request_id, :approve)
    data = handle |> Fixture.await() |> Jason.decode!()
    assert data["id"]
    assert [%{id: id}] = EvoGit.AssistantTaskLinks.list(node(), conversation)
    assert id == data["id"]

    other = "separate-#{fixture.agent_id}"

    Fixture.update_meta(fixture, fn meta ->
      %{
        meta
        | spec: %{
            meta.spec
            | opts: Keyword.put(meta.spec.opts, :assistant_conversation_id, other)
          }
      }
    end)

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_get_task", %{"task_id" => id}, "/", "/", nil)
      end)

    assert Fixture.await(handle) =~ id
    assert [] == EvoGit.AssistantTaskLinks.list(node(), other)

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute("genesis_follow_task", %{"task_id" => id}, "/", "/", nil)
      end)

    assert Fixture.await(handle) =~ "followed"
    assert [%{id: ^id}] = EvoGit.AssistantTaskLinks.list(node(), other)
    # This test asserts submission and linking, then stops the real background
    # runtime before its temporary project is removed by fixture teardown.
    case TaskRegistry.force_kill_task(id) do
      :ok -> :ok
      {:error, :not_running} -> :ok
    end
  end

  test "card actions survive session death and cannot borrow another conversation", %{
    fixture: fixture,
    store: store,
    registry: registry
  } do
    conversation = fixture.agent_id
    task_id = "card-task-#{fixture.agent_id}"

    task = %EvoGit.TaskInfo{
      id: task_id,
      type: :evolve,
      status: :pending,
      opts: [path: "/tmp/card-project"],
      started_at: DateTime.utc_now()
    }

    assert :ok = EvoGit.Store.put_task(store, task)

    assert :ok =
             EvoGit.AssistantTaskLinks.follow(node(), conversation, %{
               id: task_id,
               project_path: "/tmp/card-project"
             })

    Fixture.update_meta(fixture, &%{&1 | status: :completed})

    context = %{
      conversation_id: conversation,
      target_node: node(),
      operation_id: "card-operation"
    }

    assert {:error, _} =
             GenesisTools.request_action("genesis_cancel_task", %{"task_id" => task_id}, %{
               context
               | conversation_id: conversation + 1
             })

    refute_receive {:approval_requested, _}

    action =
      Task.async(fn ->
        Process.put(:evogit_task_registry_server, registry)
        GenesisTools.request_action("genesis_cancel_task", %{"task_id" => task_id}, context)
      end)

    assert_receive {:approval_requested, request}, 3000
    assert request.conversation_id == conversation
    assert request.task_id == nil
    assert request.project_path == "/tmp/card-project"
    assert request.operation_id == "card-operation"

    assert {:error, %{code: "action_pending", operation_id: "card-operation"}} =
             GenesisTools.request_action("genesis_cancel_task", %{"task_id" => task_id}, %{
               context
               | operation_id: "duplicate-operation"
             })

    refute_receive {:approval_requested, _}
    assert :ok = EvoGit.CommandApproval.respond(request.request_id, :approve)
    assert {:ok, %{id: ^task_id, cancel_requested: true}} = Task.await(action)

    assert {:ok, %{id: ^task_id, cancel_requested: true}} =
             GenesisTools.request_action("genesis_cancel_task", %{"task_id" => task_id}, context)

    refute_receive {:approval_requested, _}
  end

  test "workspace comes from the owner and explicit project paths remain exact", %{
    fixture: fixture,
    data_dir: path
  } do
    alternate = Path.join(path, "alternate")
    File.mkdir_p!(alternate)

    Fixture.update_meta(fixture, fn meta ->
      %{
        meta
        | spec: %{
            meta.spec
            | opts: Keyword.put(meta.spec.opts, :assistant_workspace, %{path: path, node: node()})
          }
      }
    end)

    for {arguments, actual_path} <- [
          {%{"objective" => "Build a tiny example"}, path},
          {%{"path" => alternate, "objective" => "Build another example"}, alternate}
        ] do
      handle =
        Fixture.call_async(fixture, fn ->
          Tools.execute(
            "genesis_start_task",
            arguments,
            "/misleading-source",
            "/misleading-source",
            nil
          )
        end)

      assert_receive {:approval_requested, request}, 3000
      assert request.project_path == actual_path
      assert request.parameters["path"] == actual_path
      assert :ok = EvoGit.CommandApproval.respond(request.request_id, :deny)
      assert Fixture.await(handle) =~ "denied"
    end

    Fixture.update_meta(fixture, fn meta ->
      %{
        meta
        | spec: %{
            meta.spec
            | opts:
                Keyword.put(meta.spec.opts, :assistant_workspace, %{path: path, node: :other@host})
          }
      }
    end)

    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "genesis_start_task",
          %{"objective" => "No local fallback"},
          path,
          path,
          nil
        )
      end)

    assert Fixture.await(handle) =~ "Error:"
    refute_receive {:approval_requested, _}
  end

  test "backend uncertainty keeps the original operation identity and never repeats it" do
    conversation = "uncertain-#{System.unique_integer([:positive])}"
    task_id = "uncertain-target"

    assert :ok =
             EvoGit.AssistantTaskLinks.follow(node(), conversation, %{
               id: task_id,
               project_path: "/tmp/unavailable-project"
             })

    context = %{
      conversation_id: conversation,
      target_node: node(),
      operation_id: "original-operation"
    }

    args = %{"task_id" => task_id}

    action =
      Task.async(fn ->
        Process.put(:evogit_task_registry_server, :unavailable_action_registry)
        GenesisTools.request_action("genesis_cancel_task", args, context)
      end)

    assert_receive {:approval_requested, request}, 3000
    assert :ok = EvoGit.CommandApproval.respond(request.request_id, :approve)

    assert {:error, %{code: "action_uncertain", operation_id: "original-operation"}} =
             Task.await(action)

    assert :unknown = EvoGit.AssistantTaskLinks.action_status(conversation, "original-operation")

    assert {:error, %{code: "action_uncertain", operation_id: "original-operation"}} =
             GenesisTools.request_action("genesis_cancel_task", args, %{
               context
               | operation_id: "new-operation"
             })

    refute_receive {:approval_requested, _}
  end
end
