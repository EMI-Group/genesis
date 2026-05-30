defmodule EvoGit.Skills.Skill do
  @moduledoc """
  Struct representing a parsed skill definition from a `.md` file in `.agents/skills/`.
  """

  @type param :: %{
    name: String.t(),
    type: String.t(),
    description: String.t(),
    required: boolean(),
    default: term()
  }

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameters: [param()],
    body: String.t(),
    file_path: String.t()
  }

  defstruct name: nil,
            description: nil,
            parameters: [],
            body: nil,
            file_path: nil
end
