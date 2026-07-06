defmodule Mix.Tasks.RecoverQuarantine do
  @shortdoc "Recover rows from quarantine tables back into live tables"

  @moduledoc """
  Recovers rows from the EvoDash SQLite quarantine tables
  (`tasks_quarantine`, `projects_quarantine`) back into the live tables.

  Quarantined rows are those that failed to decode (e.g. due to a codec bug
  that has since been fixed). This task attempts to re-decode each quarantined
  row. Rows that now decode successfully are moved back into the live table;
  rows that still fail are left in quarantine.

  ## Usage

      mix recover_quarantine

  Requires the EvoDash application to be running (the task starts it
  automatically if needed).
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("Starting EvoDash application...")
    {:ok, _apps} = Application.ensure_all_started(:evo_dash)

    Mix.shell().info("Running quarantine recovery...")

    case EvoDash.Store.recover_quarantine() do
      {:ok, 0} ->
        Mix.shell().info("No quarantined rows found — nothing to recover.")

      {:ok, count} ->
        Mix.shell().info("✅ Successfully recovered #{count} row(s) from quarantine.")

      {:error, reason} ->
        Mix.shell().error("❌ Recovery failed: #{inspect(reason)}")
    end
  end
end
