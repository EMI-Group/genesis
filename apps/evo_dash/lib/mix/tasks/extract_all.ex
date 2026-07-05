defmodule Mix.Tasks.Gettext.ExtractAll do
  use Mix.Task

  @shortdoc "Runs standard gettext.extract followed by extract_schema_descriptions"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Running mix gettext.extract...")
    Mix.Task.rerun("gettext.extract", [])

    Mix.shell().info("Running mix gettext.extract_schema_descriptions...")
    Mix.Task.rerun("gettext.extract_schema_descriptions", [])

    Mix.shell().info("All extractions complete.")
    :ok
  end
end
