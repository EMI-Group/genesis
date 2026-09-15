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
    # `EvoDash.ActiveTasks` is a boot-created (idempotent), process-wide public
    # ETS table (`:evo_dash_active_tasks`, owned by the long-lived application
    # process) shared by ALL suites in one `mix test` run. A whole-page mount
    # through ConnCase seeds the sidebar from it, so reset it here: a snapshot
    # (or junk sentinel value) leaked by an earlier suite would otherwise be
    # inherited by a later mount — `reset/0` is a no-op before the app boots.
    # Reset again in `on_exit` so this suite's own writes never leak onward.
    #
    # Safe with the `async: true` ConnCase users (error_html_test /
    # error_json_test): ExUnit runs `async: false` modules only after all
    # `async: true` ones finish (never concurrently), and those two async users
    # are pure render tests that never read the hub.
    EvoDash.ActiveTasks.reset()
    on_exit(fn -> EvoDash.ActiveTasks.reset() end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
