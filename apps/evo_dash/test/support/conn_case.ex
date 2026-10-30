defmodule EvoDashWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EvoDashWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint EvoDashWeb.Endpoint

      use EvoDashWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import EvoDashWeb.ConnCase
    end
  end

  setup _tags do
    # `EvoDash.ActiveTasks` is a process-less pure-ETS module (NOT a GenServer)
    # over the boot-created public table `:evo_dash_active_tasks`, which is
    # owned by the long-lived application process and shared by ALL suites in
    # one `mix test` run.
    # A whole-page mount through ConnCase seeds the sidebar from the LOCAL
    # `{nil, node()}` context, so clear exactly that one here: a snapshot (or
    # junk sentinel value) leaked by an earlier suite would otherwise be
    # inherited by a later mount.
    # Clear it again in `on_exit` so this suite's own writes never leak onward.
    #
    # This deliberately does NOT wipe the table: the suite runs dozens of
    # `async: true` ConnCase modules concurrently, so a whole-table wipe lets
    # one module's reset delete another module's per-test-unique remote-key
    # snapshot between its `put` and its `get` (the proven cause of the
    # `NodeAwareRunWideTest` "an applied result writes the hub" flake).
    # Remote/pending contexts need no clearing: the NodeAware pending guard
    # only ever writes `{[], []}`, and task-bearing remote keys are
    # per-test-unique.
    # A caller that needs a FOREIGN context cold must `invalidate/2` that
    # specific context itself.
    EvoDash.ActiveTasks.invalidate(nil, node())
    on_exit(fn -> EvoDash.ActiveTasks.invalidate(nil, node()) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
