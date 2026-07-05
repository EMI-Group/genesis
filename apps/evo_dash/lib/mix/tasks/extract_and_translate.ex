defmodule Mix.Tasks.Gettext.ExtractAndTranslate do
  use Mix.Task

  @shortdoc "Full i18n pipeline: extract_all + translate to all languages"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("=== Step 1/2: Extracting all gettext messages ===")
    Mix.Task.rerun("gettext.extract_all", [])

    Mix.shell().info("\n=== Step 2/2: Translating to all languages ===")

    translate_args = ["apps/evo_dash/priv/gettext/default.pot", "all" | args]
    Mix.Task.rerun("translate", translate_args)

    Mix.shell().info("\nFull i18n pipeline complete.")
    :ok
  end
end
