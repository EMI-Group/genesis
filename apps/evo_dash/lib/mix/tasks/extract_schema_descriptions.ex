defmodule Mix.Tasks.Gettext.ExtractSchemaDescriptions do
  use Mix.Task

  @shortdoc "Extracts config schema description strings into the gettext POT file"

  @requirements ["app.config"]

  @pot_file Path.join([__DIR__, "..", "..", "..", "priv", "gettext", "default.pot"])
            |> Path.expand()
  @schema_source "lib/evo_git/config/schema.ex"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:evo_git)

    schemas = EvoGit.Config.Schema.all_schemas()

    # Read existing POT file; start from an empty pot if it does not exist yet
    # (e.g. on a first run before `gettext.extract` has created it).
    pot =
      case Expo.PO.parse_file(@pot_file) do
        {:ok, parsed} ->
          parsed

        {:error, _reason} ->
          Mix.shell().info(
            "No existing POT file found at #{@pot_file}; creating a new one with schema descriptions."
          )

          %Expo.Messages{messages: [], headers: []}
      end

    # Build set of existing msgids for idempotency
    existing_msgids =
      MapSet.new(pot.messages, fn
        %Expo.Message.Singular{msgid: msgid} -> IO.iodata_to_binary(msgid)
        %Expo.Message.Plural{msgid: msgid} -> IO.iodata_to_binary(msgid)
        _ -> nil
      end)
      |> MapSet.delete(nil)

    # Extract unique descriptions from schemas, skipping already-present ones
    {new_messages, _seen} =
      Enum.reduce(schemas, {[], MapSet.new()}, fn schema, {msgs, seen_acc} ->
        desc = schema.description

        if MapSet.member?(existing_msgids, desc) or MapSet.member?(seen_acc, desc) do
          {msgs, seen_acc}
        else
          key_path_str = Enum.join(schema.key_path, ".")

          msg = %Expo.Message.Singular{
            msgid: [desc],
            msgstr: [""],
            references: [[@schema_source]],
            extracted_comments: ["key_path: #{key_path_str}"]
          }

          {[msg | msgs], MapSet.put(seen_acc, desc)}
        end
      end)

    new_count = length(new_messages)

    if new_count > 0 do
      updated_messages = pot.messages ++ Enum.reverse(new_messages)
      updated_pot = %{pot | messages: updated_messages}

      File.write!(@pot_file, Expo.PO.compose(updated_pot))

      Mix.shell().info("Added #{new_count} new schema description(s) to #{@pot_file}")
    else
      Mix.shell().info("No new schema descriptions to add — all already present in #{@pot_file}")
    end

    :ok
  end
end
