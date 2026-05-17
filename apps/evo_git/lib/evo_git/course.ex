defmodule EvoGit.Course do
  @moduledoc """
  Course management module — provides the Course struct and system-wide
  configuration accessors for course serving modes and builder node.
  """

  @typedoc "A course descriptor"
  @type t :: %__MODULE__{
          name: String.t(),
          repo_path: String.t(),
          branches: [String.t()],
          output_dir: String.t() | nil
        }

  @enforce_keys [:name, :repo_path]

  defstruct [
    :name,
    :repo_path,
    :branches,
    :output_dir
  ]

  @doc """
  Returns the current course serving mode.

  Reads from Application config `:evo_git, :course_mode`.
  Valid modes are `:git` (local development — serve from git repos)
  and `:build` (production — serve from pre-built directories).

  Defaults to `:build`.
  """
  @spec mode() :: :git | :build
  def mode do
    Application.get_env(:evo_git, :course_mode, :build)
  end

  @doc """
  Returns the configured builder node name, or nil if none is configured.

  Reads from Application config `:evo_git, :builder_node`.
  """
  @spec builder_node() :: atom() | nil
  def builder_node do
    Application.get_env(:evo_git, :builder_node)
  end

  @doc """
  Returns the local courses directory for :build mode.

  Reads from Application config `:evo_git, :courses_dir`.
  Defaults to `"/var/evogit/courses"`.
  """
  @spec courses_dir() :: String.t()
  def courses_dir do
    Application.get_env(:evo_git, :courses_dir, "/var/evogit/courses")
  end

  @doc """
  Returns the remote build artifacts directory on the builder node.

  Reads from Application config `:evo_git, :course_builds_dir`.
  Defaults to `"/tmp/evogit_builds"`.
  """
  @spec builds_dir() :: String.t()
  def builds_dir do
    Application.get_env(:evo_git, :course_builds_dir, "/tmp/evogit_builds")
  end

  @doc """
  Returns the list of configured courses.

  Reads from Application config `:evo_git, :courses`.
  Each course is a map with `:name` and `:repo_path` keys.
  """
  @spec list() :: [map()]
  def list do
    Application.get_env(:evo_git, :courses, [])
  end
end
