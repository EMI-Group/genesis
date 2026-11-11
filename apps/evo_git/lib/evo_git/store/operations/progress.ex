defmodule EvoGit.Store.Operations.Progress do
  @moduledoc false
  import Ecto.Query
  alias EvoGit.{Repo, TaskProgress}
  alias EvoGit.Store.{RepoScope, Schemas.TaskProgressRow, Schemas.TaskRow}

  def get(repo, id) do
    RepoScope.with_repo(repo, fn ->
      TaskProgress.public(load(id))
    end)
  end

  def publish(repo, id, agent, attrs, meta) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(from(t in TaskRow, where: t.id == ^id, select: t.status)) do
        status when status in [:pending, :running, :cancelling, :finalizing] ->
          case TaskProgress.merge(load(id) || %{}, agent, attrs, meta) do
            {:changed, next} ->
              Repo.insert!(
                %TaskProgressRow{
                  task_id: id,
                  payload: Jason.encode!(next),
                  summary: next["summary"],
                  updated_at: next["updated_at"]
                },
                on_conflict: :replace_all,
                conflict_target: :task_id
              )

              Phoenix.PubSub.broadcast(
                EvoGit.PubSub,
                "tasks",
                {:task_updated, id, status, node()}
              )

              {:ok, TaskProgress.public(next)}

            {:metadata_only, next} ->
              Repo.insert!(
                %TaskProgressRow{
                  task_id: id,
                  payload: Jason.encode!(next),
                  summary: next["summary"],
                  updated_at: next["updated_at"]
                },
                on_conflict: :replace_all,
                conflict_target: :task_id
              )

              {:ok, TaskProgress.public(next)}

            {:unchanged, old} ->
              {:ok, TaskProgress.public(old)}

            error ->
              error
          end

        _ ->
          {:error, :task_not_active}
      end
    end)
  end

  def message(repo, id, message_id, agent, status) do
    RepoScope.with_repo(repo, fn ->
      task_status = Repo.one(from(t in TaskRow, where: t.id == ^id, select: t.status))

      if is_nil(task_status) do
        {:error, :not_found}
      else
        old = load(id) || %{}
        messages = Map.get(old, "messages", [])
        previous = Enum.find(messages, &(&1["id"] == message_id))

        if previous && (previous["state"] == status || previous["state"] == "delivered") do
          :ok
        else
          entry = %{
            "id" => message_id,
            "agent_id" => agent,
            "state" => status,
            "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          messages = Enum.reject(messages, &(&1["id"] == message_id)) ++ [entry]

          next =
            old
            |> Map.put("messages", Enum.take(messages, -32))
            |> Map.put("revision", Map.get(old, "revision", 0) + 1)

          Repo.insert!(
            %TaskProgressRow{
              task_id: id,
              payload: Jason.encode!(next),
              summary: next["summary"],
              updated_at: next["updated_at"]
            },
            on_conflict: :replace_all,
            conflict_target: :task_id
          )

          Phoenix.PubSub.broadcast(
            EvoGit.PubSub,
            "tasks",
            {:task_updated, id, task_status, node()}
          )

          :ok
        end
      end
    end)
  end

  defp load(id) do
    case Repo.get(TaskProgressRow, id) do
      nil -> nil
      row -> Jason.decode!(row.payload)
    end
  end
end
