defmodule EvoGit.Agent.Session.Registry do
  @moduledoc """
  The ONE per-agent `agent_id` → session pid lookup.

  A `Registry` with `keys: :unique` registered under this module's name, i.e. the
  same pattern the remote-SSH stack already uses for
  `EvoGit.RemoteConnection.Registry`: the process is a plain `Registry`, and this
  module only exists so a supervisor (the app tree, or a test with
  `start_supervised!/1`) can start it by name.

  Exactly ONE session process may be registered per `agent_id`; a second
  registration for the same id fails, which is what makes "one session per agent"
  a structural guarantee rather than a convention. Because the registry is the
  only way to find a session from an id, every public `EvoGit.Agent.Session`
  lookup degrades to "not found" when this process is not running.
  """

  @doc """
  Starts the registry under `EvoGit.Agent.Session.Registry`.

  `opts` may override anything except the unique-key contract (for example a
  test starting the registry under its own name).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    Registry.start_link(registry_opts(opts))
  end

  @doc false
  def child_spec(opts) do
    Registry.child_spec(registry_opts(opts))
  end

  defp registry_opts(opts) do
    Keyword.merge([keys: :unique, name: __MODULE__], opts)
  end
end
