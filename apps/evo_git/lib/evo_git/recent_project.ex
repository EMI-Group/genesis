defmodule EvoGit.RecentProject do
  @moduledoc """
  A recently opened project entry.

  `path` is the project's OS path, while `vct_path` is its canonical VCT URL
  (`vct:///projects/<name>`) — the mount point in the Virtual Context Tree, or
  `nil` when the project is not mounted. `name` is the display name and
  `last_opened_at` the most recent open timestamp (`nil` sorts last).
  """

  defstruct [:path, :name, :last_opened_at, :vct_path]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          last_opened_at: DateTime.t() | nil,
          vct_path: String.t() | nil
        }
end
