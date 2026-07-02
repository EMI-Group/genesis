defmodule EvoDash.RecentProject do
  @moduledoc "A recently opened project entry."
  defstruct [:path, :name, :last_opened_at]
  @type t :: %__MODULE__{path: String.t(), name: String.t(), last_opened_at: DateTime.t() | nil}
end
