defmodule Mix.Tasks.Translate do
  use Mix.Task

  @shortdoc "Translates a POT file to multiple target languages using LLM"

  @requirements ["app.config"]

  @languages %{
    "ar" => "Arabic العربية",
    "de" => "German Deutsch",
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

  @model "deepseek:deepseek-v4-flash"

  @glossary %{
    # ===== Arabic =====
    "ar" => %{
      # TODO: verify
      "Agent" => "وكيل",
      # TODO: verify
      "Base commit" => "الإيداع الأساسي",
      # TODO: verify
      "Branch" => "فرع",
      # TODO: verify
      "Commit" => "إيداع",
      # TODO: verify
      "Concurrency" => "تزامن",
      # TODO: verify
      "Context Tree" => "شجرة السياق",
      # TODO: verify
      "Context window" => "نافذة السياق",
      # TODO: verify
      "Evolve" => "تطوّر",
      # TODO: verify
      "Genesis" => "جينيسيس",
      # TODO: verify
      "Genesis (command)" => "إنشاء",
      # TODO: verify
      "Graceful restart" => "إعادة تشغيل سلسة",
      # TODO: verify
      "Prompt" => "موجّه",
      # TODO: verify
      "Provider" => "مزوّد",
      # TODO: verify
      "Runtime" => "وقت التشغيل",
      # TODO: verify
      "Sandbox" => "صندوق الرمل",
      # TODO: verify
      "Scheduler" => "مجدول",
      # TODO: verify
      "Token" => "وحدة",
      # TODO: verify
      "Tool call" => "استدعاء الأداة",
      # TODO: verify
      "Worktree" => "شجرة العمل"
    },
    # ===== German =====
    "de" => %{
      "Agent" => "Agent",
      "Base commit" => "Basis-Commit",
      "Branch" => "Branch",
      "Commit" => "Commit",
      "Concurrency" => "Nebenläufigkeit",
      "Context Tree" => "Kontextbaum",
      "Context window" => "Kontextfenster",
      # TODO: verify
      "Evolve" => "Evolution",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "Genesis",
      "Graceful restart" => "sanfter Neustart",
      "Prompt" => "Prompt",
      "Provider" => "Anbieter",
      "Runtime" => "Laufzeitumgebung",
      "Sandbox" => "Sandbox",
      "Scheduler" => "Scheduler",
      "Token" => "Token",
      "Tool call" => "Werkzeugaufruf",
      "Worktree" => "Worktree"
    },
    # ===== Spanish =====
    "es" => %{
      "Agent" => "Agente",
      "Base commit" => "commit base",
      "Branch" => "rama",
      "Commit" => "commit",
      "Concurrency" => "concurrencia",
      "Context Tree" => "árbol de contexto",
      "Context window" => "ventana de contexto",
      # TODO: verify
      "Evolve" => "evolucionar",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "génesis",
      "Graceful restart" => "reinicio controlado",
      "Prompt" => "prompt",
      "Provider" => "proveedor",
      "Runtime" => "entorno de ejecución",
      "Sandbox" => "entorno aislado",
      "Scheduler" => "planificador",
      "Token" => "Token",
      "Tool call" => "llamada a herramienta",
      "Worktree" => "árbol de trabajo"
    },
    # ===== French =====
    "fr" => %{
      "Agent" => "Agent",
      "Base commit" => "commit de base",
      "Branch" => "branche",
      "Commit" => "commit",
      "Concurrency" => "concurrence",
      "Context Tree" => "arbre de contexte",
      "Context window" => "fenêtre de contexte",
      # TODO: verify
      "Evolve" => "évolution",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "genèse",
      "Graceful restart" => "redémarrage en douceur",
      "Prompt" => "prompt",
      "Provider" => "fournisseur",
      "Runtime" => "environnement d'exécution",
      "Sandbox" => "bac à sable",
      "Scheduler" => "planificateur",
      "Token" => "jeton",
      "Tool call" => "appel d'outil",
      "Worktree" => "arbre de travail"
    },
    # ===== Indonesian =====
    "id" => %{
      # TODO: verify
      "Agent" => "Agen",
      # TODO: verify
      "Base commit" => "commit dasar",
      # TODO: verify
      "Branch" => "cabang",
      # TODO: verify
      "Commit" => "commit",
      # TODO: verify
      "Concurrency" => "konkurensi",
      # TODO: verify
      "Context Tree" => "pohon konteks",
      # TODO: verify
      "Context window" => "jendela konteks",
      # TODO: verify
      "Evolve" => "evolusi",
      # TODO: verify
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "genesis",
      # TODO: verify
      "Graceful restart" => "mulai ulang halus",
      # TODO: verify
      "Prompt" => "prompt",
      # TODO: verify
      "Provider" => "penyedia",
      # TODO: verify
      "Runtime" => "runtime",
      # TODO: verify
      "Sandbox" => "kotak pasir",
      # TODO: verify
      "Scheduler" => "penjadwal",
      # TODO: verify
      "Token" => "Token",
      # TODO: verify
      "Tool call" => "panggilan alat",
      # TODO: verify
      "Worktree" => "pohon kerja"
    },
    # ===== Italian =====
    "it" => %{
      "Agent" => "Agente",
      "Base commit" => "commit di base",
      "Branch" => "ramo",
      "Commit" => "commit",
      "Concurrency" => "concorrenza",
      "Context Tree" => "albero di contesto",
      "Context window" => "finestra di contesto",
      # TODO: verify
      "Evolve" => "evoluzione",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "genesi",
      "Graceful restart" => "riavvio controllato",
      "Prompt" => "prompt",
      "Provider" => "fornitore",
      "Runtime" => "runtime",
      "Sandbox" => "sandbox",
      "Scheduler" => "pianificatore",
      "Token" => "Token",
      "Tool call" => "chiamata strumento",
      "Worktree" => "albero di lavoro"
    },
    # ===== Japanese =====
    "ja" => %{
      "Agent" => "エージェント",
      "Base commit" => "ベースコミット",
      "Branch" => "ブランチ",
      "Commit" => "コミット",
      "Concurrency" => "並行性",
      "Context Tree" => "コンテキストツリー",
      "Context window" => "コンテキストウィンドウ",
      # TODO: verify
      "Evolve" => "進化",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "生成",
      "Graceful restart" => "グレースフルリスタート",
      "Prompt" => "プロンプト",
      "Provider" => "プロバイダー",
      "Runtime" => "ランタイム",
      "Sandbox" => "サンドボックス",
      "Scheduler" => "スケジューラー",
      "Token" => "トークン",
      "Tool call" => "ツール呼び出し",
      "Worktree" => "ワークツリー"
    },
    # ===== Korean =====
    "ko" => %{
      "Agent" => "에이전트",
      "Base commit" => "베이스 커밋",
      "Branch" => "브랜치",
      "Commit" => "커밋",
      "Concurrency" => "동시성",
      "Context Tree" => "컨텍스트 트리",
      "Context window" => "컨텍스트 윈도우",
      # TODO: verify
      "Evolve" => "진화",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "생성",
      # TODO: verify
      "Graceful restart" => "정상 재시작",
      "Prompt" => "프롬프트",
      "Provider" => "제공자",
      "Runtime" => "런타임",
      "Sandbox" => "샌드박스",
      "Scheduler" => "스케줄러",
      "Token" => "토큰",
      "Tool call" => "도구 호출",
      "Worktree" => "작업 트리"
    },
    # ===== Portuguese =====
    "pt" => %{
      "Agent" => "Agente",
      "Base commit" => "commit base",
      "Branch" => "ramo",
      "Commit" => "commit",
      "Concurrency" => "concorrência",
      "Context Tree" => "árvore de contexto",
      "Context window" => "janela de contexto",
      # TODO: verify
      "Evolve" => "evoluir",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "gênese",
      "Graceful restart" => "reinicialização controlada",
      "Prompt" => "prompt",
      "Provider" => "provedor",
      "Runtime" => "ambiente de execução",
      "Sandbox" => "sandbox",
      "Scheduler" => "agendador",
      "Token" => "Token",
      "Tool call" => "chamada de ferramenta",
      "Worktree" => "árvore de trabalho"
    },
    # ===== Russian =====
    "ru" => %{
      "Agent" => "агент",
      "Base commit" => "базовый коммит",
      "Branch" => "ветка",
      "Commit" => "коммит",
      "Concurrency" => "конкурентность",
      "Context Tree" => "дерево контекста",
      "Context window" => "контекстное окно",
      # TODO: verify
      "Evolve" => "развитие",
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "создание",
      "Graceful restart" => "плавный перезапуск",
      "Prompt" => "промпт",
      "Provider" => "провайдер",
      "Runtime" => "среда выполнения",
      "Sandbox" => "песочница",
      "Scheduler" => "планировщик",
      "Token" => "токен",
      "Tool call" => "вызов инструмента",
      "Worktree" => "рабочее дерево"
    },
    # ===== Thai =====
    "th" => %{
      # TODO: verify
      "Agent" => "เอเจนต์",
      # TODO: verify
      "Base commit" => "คอมมิตพื้นฐาน",
      # TODO: verify
      "Branch" => "แบรนช์",
      # TODO: verify
      "Commit" => "คอมมิต",
      # TODO: verify
      "Concurrency" => "ภาวะพร้อมกัน",
      # TODO: verify
      "Context Tree" => "ต้นไม้บริบท",
      # TODO: verify
      "Context window" => "หน้าต่างบริบท",
      # TODO: verify
      "Evolve" => "วิวัฒนาการ",
      # TODO: verify
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "การสร้าง",
      # TODO: verify
      "Graceful restart" => "การรีสตาร์ทแบบนุ่มนวล",
      # TODO: verify
      "Prompt" => "พรอมต์",
      # TODO: verify
      "Provider" => "ผู้ให้บริการ",
      # TODO: verify
      "Runtime" => "รันไทม์",
      # TODO: verify
      "Sandbox" => "แซนด์บ็อกซ์",
      # TODO: verify
      "Scheduler" => "ตัวจัดตาราง",
      # TODO: verify
      "Token" => "โทเค็น",
      # TODO: verify
      "Tool call" => "การเรียกใช้เครื่องมือ",
      # TODO: verify
      "Worktree" => "เวิร์กทรี"
    },
    # ===== Vietnamese =====
    "vi" => %{
      # TODO: verify
      "Agent" => "Tác tử",
      # TODO: verify
      "Base commit" => "commit cơ sở",
      # TODO: verify
      "Branch" => "nhánh",
      # TODO: verify
      "Commit" => "commit",
      # TODO: verify
      "Concurrency" => "đồng thời",
      # TODO: verify
      "Context Tree" => "cây ngữ cảnh",
      # TODO: verify
      "Context window" => "cửa sổ ngữ cảnh",
      # TODO: verify
      "Evolve" => "tiến hóa",
      # TODO: verify
      "Genesis" => "Genesis",
      # TODO: verify
      "Genesis (command)" => "khởi tạo",
      # TODO: verify
      "Graceful restart" => "khởi động lại nhẹ nhàng",
      # TODO: verify
      "Prompt" => "lời nhắc",
      # TODO: verify
      "Provider" => "nhà cung cấp",
      # TODO: verify
      "Runtime" => "thời gian chạy",
      # TODO: verify
      "Sandbox" => "hộp cát",
      # TODO: verify
      "Scheduler" => "bộ lập lịch",
      # TODO: verify
      "Token" => "Token",
      # TODO: verify
      "Tool call" => "gọi công cụ",
      # TODO: verify
      "Worktree" => "cây làm việc"
    },
    # ===== Chinese (Simplified) =====
    "zh_CN" => %{
      # Brand
      "Genesis" => "启元",
      # AI/Agent
      "Agent" => "智能体",
      "Token" => "词元",
      "Tool call" => "工具调用",
      "Provider" => "服务商",
      "Context window" => "上下文窗口",
      "Prompt" => "提示词",
      # Git/Version control
      "Commit" => "提交",
      "Base commit" => "起始提交",
      "Worktree" => "工作树",
      "Branch" => "分支",
      # Computing/Systems
      "Graceful restart" => "平滑重启",
      "Scheduler" => "调度器",
      "Sandbox" => "沙箱",
      "Runtime" => "运行时",
      "Concurrency" => "并发",
      # EvoGit-specific
      "Evolve" => "演进",
      "Genesis (command)" => "生成",
      "Context Tree" => "上下文树"
    },
    # ===== Chinese (Traditional) =====
    "zh_HK" => %{
      # Brand
      "Genesis" => "啟元",
      # AI/Agent
      "Agent" => "智能體",
      "Token" => "詞元",
      "Tool call" => "工具調用",
      "Provider" => "服務商",
      "Context window" => "上下文窗口",
      "Prompt" => "提示詞",
      # Git/Version control
      "Commit" => "提交",
      "Base commit" => "起始提交",
      "Worktree" => "工作樹",
      "Branch" => "分支",
      # Computing/Systems
      "Graceful restart" => "平滑重啟",
      "Scheduler" => "調度器",
      "Sandbox" => "沙箱",
      "Runtime" => "運行時",
      "Concurrency" => "並發",
      # EvoGit-specific
      "Evolve" => "演進",
      "Genesis (command)" => "生成",
      "Context Tree" => "上下文樹"
    }
  }

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
          Mix.shell().info(
            "No messages found#{if prefix, do: " matching prefix '#{prefix}'", else: ""}."
          )

          :ok
        else
          Mix.shell().info("Found messages in #{map_size(messages_by_file)} file group(s).")

          # Pre-load existing translations for all languages upfront.
          # We maintain: %{ "zh_CN" => %{ "msgid" => "msgstr" } }
          initial_acc =
            Map.new(target_langs, fn target_lang ->
              output_path = build_output_path(target_lang)

              existing =
                if not force and File.exists?(output_path) do
                  load_existing_entries(output_path)
                else
                  %{}
                end

              {target_lang, existing}
            end)

          # File-first, then Language-second — maximizes LLM KV cache hits.
          # When translating the same file to different languages, the input
          # context is identical; only the target language changes.
          total_files = map_size(messages_by_file)

          final_translation_maps =
            messages_by_file
            |> Enum.with_index(1)
            |> Enum.reduce(initial_acc, fn {{file, file_messages}, file_idx}, lang_maps_acc ->
              context = get_file_context(file)
              Mix.shell().info("\n[#{file_idx}/#{total_files}] Context: #{file}")

              Enum.reduce(target_langs, lang_maps_acc, fn target_lang, acc ->
                current_lang_map = acc[target_lang]

                untranslated =
                  Enum.filter(file_messages, fn msg ->
                    key = IO.iodata_to_binary(msg.msgid)
                    force or not Map.has_key?(current_lang_map, key)
                  end)

                if untranslated == [] do
                  Mix.shell().info(
                    "  ✅ #{Map.get(@languages, target_lang, target_lang)} — all up to date"
                  )

                  acc
                else
                  Mix.shell().info(
                    "  📝 #{Map.get(@languages, target_lang, target_lang)} — #{length(untranslated)} entries to translate"
                  )

                  case translate_batch(context, untranslated, target_lang) do
                    {:ok, translations} ->
                      updated_lang_map =
                        Enum.reduce(translations, current_lang_map, fn t, m_acc ->
                          Map.put(m_acc, t["msgid"], t["msgstr"])
                        end)

                      Map.put(acc, target_lang, updated_lang_map)

                    {:error, error} ->
                      Mix.shell().error("  ❌ Failed to translate #{file}: #{inspect(error)}")
                      acc
                  end
                end
              end)
            end)

          # Write output PO files for each language
          header = pot.headers || [""]

          Enum.each(target_langs, fn target_lang ->
            translation_map = final_translation_maps[target_lang]
            updated_messages = apply_translations(messages, translation_map)

            output_path = build_output_path(target_lang)
            ensure_directory_exists(output_path)

            output_po = %Expo.Messages{messages: updated_messages, headers: header}
            File.write!(output_path, Expo.PO.compose(output_po))

            Mix.shell().info("  💾 Written to #{output_path}")
          end)

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

    glossary_entries = glossary_for_lang(target_lang)

    glossary_section =
      if glossary_entries != [] do
        entries_text =
          glossary_entries
          |> Enum.map(fn {en, tr} -> ~s(- "#{en}" → "#{tr}") end)
          |> Enum.join("\n")

        """

        GLOSSARY — MUST FOLLOW:
        The following terms have pre-approved translations in the target language.
        ALWAYS use these translations when these terms appear. Do NOT substitute alternatives.

        #{entries_text}
        """
      else
        ""
      end

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
    1. Meaning-First Translation (for full sentences and long phrases):
      - Translate the MEANING, not individual words. Use natural, idiomatic expressions in the target language.
      - Think about what the user needs to understand, not the literal English words.
      - Word-for-word translation produces unnatural, hard-to-read text — avoid it unless translating short labels or technical terms.
    2. UI Context Awareness:
      - Is this a button label? Be concise — often a single verb or noun.
      - Is this a help message or description? Be clear and helpful.
      - Is this a heading or title? Be descriptive and scannable.
      - Match the tone and length to the UI context. Consider space constraints of UI elements.
    3. Short Standalone Terms (single words or 2-3 word labels):
      - Consult the GLOSSARY section below for pre-approved translations of common technical terms.
      - If no glossary entry exists, use the most natural equivalent in the target language.
    4. Technical Correctness:
      - Preserve all placeholders exactly: %{name}, %{count}, Q1, Q2, etc. must remain as-is.
      - Do not translate code snippets, math expressions, special symbols, or indices.
      - All interpolations like %{name} in the source must appear in the translated string, positioned according to the grammar of the target language.
    5. Consistency: Maintain terminology consistency within the provided source code context.
    6. Format: Return valid JSON matching the requested schema.#{glossary_section}

    Source Language: English
    Target Language: #{target_lang_name}
    """

    opts = [
      max_tokens: 10_000,
      provider_options: [thinking: %{type: "disabled"}]
    ]

    case ReqLLM.stream_object(@model, prompt, schema, opts) do
      {:ok, stream_resp} ->
        case ReqLLM.StreamResponse.process_stream(stream_resp) do
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

          {:error, reason} ->
            Mix.shell().error("LLM Stream Error: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, error} ->
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

  defp glossary_for_lang(lang_code) do
    case Map.get(@glossary, lang_code) do
      nil -> []
      entries -> Enum.to_list(entries)
    end
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
