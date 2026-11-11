defmodule EvoGit.Repo.Migrations.TaskProgress do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:task_progress, primary_key: false) do
      add(:task_id, :text, primary_key: true)
      add(:payload, :text, null: false)
      add(:summary, :text)
      add(:updated_at, :text)
    end
  end
end
