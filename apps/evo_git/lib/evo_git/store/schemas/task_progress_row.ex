defmodule EvoGit.Store.Schemas.TaskProgressRow do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:task_id, :string, autogenerate: false}
  schema "task_progress" do
    field(:payload, :string)
    field(:summary, :string)
    field(:updated_at, :string)
  end
end
