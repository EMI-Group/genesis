defmodule Mix.Tasks.Translate do
  use Mix.Task

  @shortdoc "Translates a POT file to multiple target languages using LLM"

  @requirements ["app.config"]

  @languages %{
    "zh_CN" => "Chinese (Simplified) 中文 (简体)",
    "zh_HK" => "Chinese (Traditional) 中文 (繁體)",
    "ja" => "Japanese 日本語",
    "es" => "Spanish español",
    "ru" => "Russian русский",
    "pt" => "Portuguese português",
    "id" => "Indonesian Bahasa Indonesia",
    "ko" => "Korean 한국어",
    "th" => "Thai ภาษาไทย",
    "vi" => "Vietnamese Tiếng Việt",
    "fr" => "French Français",
    "it" => "Italian Italiano"
  }

  @model "deepseek-v4-flash"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, remaining_args, _} =
      OptionParser.parse(args,
        switches: [force: :boolean, prefix: :string],
        aliases: [f: :force, p: :prefix]
      )

    case remaining_args do
      [pot_file | target_langs] when target_langs != [] ->
        force = opts[:force] || false
        prefix = opts[:prefix]

        target_langs =
          if Enum.member?(target_langs, "all") do
            Map.keys(@languages)
          else
            target_langs
          end

        execute_translation(pot_file, target_langs, force, prefix)

      _ ->
        Mix.shell().error(
          "Usage: mix translate <pot_file> <lang1|all> <lang2> ... [--force] [--prefix <file_prefix>]"
        )
    end
  end

  defp execute_translation(pot_file, target_langs, force, prefix) do
    case Expo.PO.parse_file(pot_file) do
      {:ok, pot} ->
        messages = pot.messages
        messages_by_file = group_messages_by_file(messages)

        messages_by_file =
          if prefix do
            messages_by_file
            |> Enum.filter(fn {file, _} -> String.contains?(file, prefix) end)
            |> Map.new()
          else
            messages_by_file
          end

        if map_size(messages_by_file) == 0 do
          Mix.shell().info("No messages found#{if prefix, do: " matching prefix '#{prefix}'", else: ""}.")

          :ok
        else
          Mix.shell().info("Found messages in #{map_size(messages_by_file)} file group(s).")

          for target_lang <- target_langs do
            Mix.shell().info("\n🌐 Translating to #{Map.get(@languages, target_lang, target_lang)} (#{target_lang})...")

            output_path = build_output_path(target_lang)
            ensure_directory_exists(output_path)

            existing_translations =
              if not force and File.exists?(output_path) do
                load_existing_entries(output_path)
              else
                %{}
              end

            all_translations =
              Enum.reduce(messages_by_file, existing_translations, fn {file, file_messages}, acc ->
                context = get_file_context(file)

                untranslated =
                  Enum.filter(file_messages, fn msg ->
                    key = IO.iodata_to_binary(msg.msgid)
                    force or not Map.has_key?(acc, key)
                  end)

                if untranslated == [] do
                  Mix.shell().info("  ✅ #{file} — all up to date")
                  acc
                else
                  Mix.shell().info("  📝 #{file} — #{length(untranslated)} entries to translate")

                  case translate_batch(context, untranslated, target_lang) do
                    {:ok, translations} ->
                      new_map =
                        translations
                        |> Enum.map(fn t -> {t["msgid"], t["msgstr"]} end)
                        |> Map.new()

                      Map.merge(acc, new_map)

                    {:error, error} ->
                      Mix.shell().error("  ❌ Failed to translate #{file}: #{inspect(error)}")
                      acc
                  end
                end
              end)

            updated_messages = apply_translations(messages, all_translations)
            header = pot.headers || [""]

            output_po = %Expo.Messages{messages: updated_messages, headers: header}
            File.write!(output_path, Expo.PO.compose(output_po))

            Mix.shell().info("  💾 Written to #{output_path}")
          end

          :ok
        end

      {:error, reason} ->
        Mix.shell().error("Failed to parse POT file: #{inspect(reason)}")
    end
  end

  defp group_messages_by_file(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      references = msg.references |> List.flatten()

      if references == [] do
        [{"unknown", msg}]
      else
        Enum.map(references, fn
          # References can be tuples {"lib/file.ex", 42} or strings "lib/file.ex:42"
          {file, _line} -> {file, msg}
          ref when is_binary(ref) -> {ref |> String.split(":") |> hd(), msg}
        end)
      end
    end)
    |> Enum.group_by(fn {file, _msg} -> file end, fn {_file, msg} -> msg end)
  end

  defp get_file_context(file) do
    # Try multiple possible base paths
    possible_paths = [
      file,
      Path.join("apps/evo_dash", file),
      Path.join("apps/evo_dash/lib", file)
    ]

    content =
      possible_paths
      |> Enum.find_value(fn path ->
        if File.exists?(path), do: File.read!(path), else: nil
      end)

    case content do
      nil -> "(file not found: #{file})"
      text -> String.slice(text, 0, 3000)
    end
  end

  defp translate_batch(context, entries, target_lang) do
    target_lang_name = Map.get(@languages, target_lang, target_lang)
    ids = Enum.map(entries, fn entry -> IO.iodata_to_binary(entry.msgid) end)

    schema = [
      translations: [
        type:
          {:list,
           {:map,
            [
              msgid: [type: :string, required: true],
              msgstr: [type: :string, required: true]
            ]}},
        required: true
      ]
    ]

    prompt = """
    --- SOURCE CODE CONTEXT ---
    This code snippet provides structural and functional context for where these strings appear.
    #{context}
    ---

    --- STRINGS TO TRANSLATE ---
    #{inspect(ids, limit: :infinity)}
    ---

    Role: Expert UX Writer and Localization Specialist.
    Task: Translate UI strings for the following webpage into #{target_lang_name}.

    Translation Guidelines:
    1. Contextual Naturalness:
      - Do not translate literally. Ensure the content matches a professional web interface.
      - No need to translate language-agnostic contents, like math, code snippets, special symbols, indices.
    2. UI/UX Awareness:
      - Consider the likely layout. Use concise terms for buttons/labels and clear, helpful language for messages.
      - Consider the space constraints of UI elements; prefer translations that fit well in the original design.
    3. Consistency: Maintain terminology consistency within the context of the provided source code.
    4. Correctness: Maintain the correct format for placeholders, for example:
      - Q1, Q2 should remain as is.
      - All interpolations like `%{you}` in the source string should be preserved in the translated string. For example, if the source string is "Hello %{name}", the translated string should also contain "%{name}" in the appropriate place according to the grammar of the target language.
    5. Format: Return valid JSON matching the requested schema.

    Source Language: English
    Target Language: #{target_lang_name}
    """

    opts = [
      max_tokens: 10_000,
      provider_options: [thinking: %{type: "disabled"}]
    ]

    case ReqLLM.generate_object(@model, prompt, schema, opts) do
      {:ok, response} ->
        parsed = ReqLLM.Response.object(response)
        translations = parsed["translations"] || []

        valid_translations =
          Enum.filter(translations, fn t ->
            if validate_interpolations(t["msgid"], t["msgstr"]) do
              true
            else
              Mix.shell().info(
                "  ⚠️ Invalid translation for '#{t["msgid"]}': missing interpolations. Discarding."
              )

              false
            end
          end)

        {:ok, valid_translations}

      error ->
        Mix.shell().error("LLM Error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp validate_interpolations(msgid, msgstr) do
    # Extract all %{...} interpolations from msgid
    interpolation_pattern = ~r/%\{[^}]+\}/

    source_interpolations = Regex.scan(interpolation_pattern, msgid) |> List.flatten()
    target_interpolations = Regex.scan(interpolation_pattern, msgstr) |> List.flatten()

    # All source interpolations must be present in the target
    Enum.all?(source_interpolations, fn interp ->
      interp in target_interpolations
    end)
  end

  defp apply_translations(messages, translation_map) do
    Enum.map(messages, fn
      %Expo.Message.Singular{msgid: msgid} = msg ->
        key = IO.iodata_to_binary(msgid)

        case Map.get(translation_map, key) do
          nil -> msg
          trans when is_binary(trans) -> %{msg | msgstr: [trans]}
          trans when is_list(trans) -> %{msg | msgstr: trans}
        end

      %Expo.Message.Plural{msgid: msgid} = msg ->
        key = IO.iodata_to_binary(msgid)

        case Map.get(translation_map, key) do
          nil -> msg
          trans when is_binary(trans) -> %{msg | msgstr: %{0 => [trans], 1 => [trans]}}
          trans when is_map(trans) -> %{msg | msgstr: trans}
        end

      other ->
        other
    end)
  end

  defp build_output_path(lang) do
    Path.join(["priv", "gettext", lang, "LC_MESSAGES", "default.po"])
  end

  defp ensure_directory_exists(path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
  end

  defp load_existing_entries(po_path) do
    case Expo.PO.parse_file(po_path) do
      {:ok, po} ->
        Enum.reduce(po.messages, %{}, fn
          %Expo.Message.Singular{msgid: msgid, msgstr: [str | _] = msgstr, flags: flags}, acc ->
            if not is_fuzzy?(flags) and str != "" do
              Map.put(acc, IO.iodata_to_binary(msgid), msgstr)
            else
              acc
            end

          %Expo.Message.Plural{msgid: msgid, msgstr: msgstr, flags: flags}, acc ->
            first = Map.get(msgstr, 0, [""]) |> hd()

            if not is_fuzzy?(flags) and first != "" do
              Map.put(acc, IO.iodata_to_binary(msgid), msgstr)
            else
              acc
            end

          _, acc ->
            acc
        end)

      {:error, _} ->
        %{}
    end
  end

  defp is_fuzzy?(flags) do
    flags
    |> List.wrap()
    |> List.flatten()
    |> Enum.member?("fuzzy")
  end
end
