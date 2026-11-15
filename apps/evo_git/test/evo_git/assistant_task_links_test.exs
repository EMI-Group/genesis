defmodule EvoGit.AssistantTaskLinksTest do
  use ExUnit.Case, async: false

  test "conversation references are isolated, deduplicated and bounded" do
    a = make_ref()
    b = make_ref()
    assert :ok = EvoGit.AssistantTaskLinks.follow(node(), a, %{id: "one", status: "running"})
    assert [] = EvoGit.AssistantTaskLinks.list(node(), b)
    assert :ok = EvoGit.AssistantTaskLinks.follow(node(), a, %{id: "one", status: "completed"})
    assert [%{id: "one", status: "completed"}] = EvoGit.AssistantTaskLinks.list(node(), a)
    for i <- 1..25, do: EvoGit.AssistantTaskLinks.follow(node(), a, %{id: "task-#{i}"})
    assert length(EvoGit.AssistantTaskLinks.list(node(), a)) == 20

    assert {:error, :invalid_scope} =
             EvoGit.AssistantTaskLinks.follow(:unconnected, a, %{id: "one"})

    assert {:error, :invalid_task} = EvoGit.AssistantTaskLinks.follow(node(), a, %{})
  end

  test "refresh keeps task order and stores bounded card facts" do
    conversation = make_ref()

    for id <- ~w(a b c),
        do:
          :ok =
            EvoGit.AssistantTaskLinks.follow(node(), conversation, %{
              id: id,
              result: String.duplicate("large", 1000),
              objective: "private"
            })

    first = Enum.map(EvoGit.AssistantTaskLinks.list(node(), conversation), & &1.id)

    for id <- first,
        do:
          :ok =
            EvoGit.AssistantTaskLinks.follow(node(), conversation, %{
              id: id,
              status: "running",
              result: "large"
            })

    assert Enum.map(EvoGit.AssistantTaskLinks.list(node(), conversation), & &1.id) == first

    refute Enum.any?(
             EvoGit.AssistantTaskLinks.list(node(), conversation),
             &Map.has_key?(&1, :result)
           )
  end

  test "action claims bind immutable parameters and retain their terminal result" do
    conversation = make_ref()

    assert :claimed =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "op", {:cancel, "task"})

    assert :pending = EvoGit.AssistantTaskLinks.action_status(conversation, "op")

    assert :pending =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "op", {:cancel, "task"})

    assert {:pending, "op"} =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "other-id", {:cancel, "task"})

    assert {:error, :operation_mismatch} =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "op", {:cancel, "other-task"})

    stranger =
      Task.async(fn -> EvoGit.AssistantTaskLinks.finish_action(conversation, "op", :forged) end)

    assert {:error, :not_owner} = Task.await(stranger)

    assert :ok =
             EvoGit.AssistantTaskLinks.finish_action(
               conversation,
               "op",
               {:ok, %{cancel_requested: true}}
             )

    assert {:done, {:ok, %{cancel_requested: true}}} =
             EvoGit.AssistantTaskLinks.action_status(conversation, "op")

    assert {:done, {:ok, %{cancel_requested: true}}} =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "op", {:cancel, "task"})
  end

  test "a dead execution owner leaves an uncertain claim that cannot execute again" do
    conversation = make_ref()

    task =
      Task.async(fn ->
        EvoGit.AssistantTaskLinks.claim_action(conversation, "dead-owner", {:message, "task"})
      end)

    assert :claimed = Task.await(task)
    # The claim monitor DOWN precedes this barrier when sent by the same dying owner.
    eventually = fn recur, tries ->
      case EvoGit.AssistantTaskLinks.action_status(conversation, "dead-owner") do
        :unknown ->
          :ok

        _ when tries > 0 ->
          Process.sleep(1)
          recur.(recur, tries - 1)

        other ->
          flunk("expected unknown, got #{inspect(other)}")
      end
    end

    eventually.(eventually, 100)

    assert :unknown =
             EvoGit.AssistantTaskLinks.claim_action(
               conversation,
               "dead-owner",
               {:message, "task"}
             )

    assert {:unknown, "dead-owner"} =
             EvoGit.AssistantTaskLinks.claim_action(conversation, "new-owner", {:message, "task"})
  end
end
