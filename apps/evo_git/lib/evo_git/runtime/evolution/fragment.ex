defmodule EvoGit.Runtime.Evolution.Fragment do
  @moduledoc """
  A code fragment used as genetic material in the evolution entropy pool.
  
  Each fragment represents a self-contained piece of code with metadata
  about its domain, source, and language.
  """

  @type source :: :builtin | :generated | :extracted

  @type t :: %__MODULE__{
          content: String.t(),
          language: String.t(),
          domain: atom(),
          source: source(),
          metadata: map()
        }

  @enforce_keys [:content, :language, :domain]
  defstruct [:content, :language, :domain, source: :builtin, metadata: %{}]

  @doc """
  Creates a new Fragment struct.
  
  ## Options
  
    * `:language` — the programming language (default: `"elixir"`)
    * `:domain` — the domain atom (required)
    * `:source` — `:builtin`, `:generated`, or `:extracted` (default: `:builtin`)
    * `:metadata` — additional metadata map (default: `%{}`)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      content: content,
      language: Keyword.get(opts, :language, "elixir"),
      domain: Keyword.fetch!(opts, :domain),
      source: Keyword.get(opts, :source, :builtin),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
