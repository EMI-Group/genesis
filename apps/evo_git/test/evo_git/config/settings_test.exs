defmodule EvoGit.Config.SettingsTest do
  @moduledoc """
  Public operator settings API against real TOML files and RAM snapshots.
  Async-safe: ConfigDir gives each test a private snapshot key and filesystem;
  no scheduler, app-env, credentials or OS-env mutations are needed.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.{Cache, Schema}
  alias EvoGit.Config.Schema.ValidationError
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("operator_settings_#{:os.getpid()}")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> Cache.invalidate(dir) end)
    %{dir: dir, path: Config.config_path()}
  end

  describe "list_settings/0" do
    test "returns complete schema descriptors in schema order without persisting", %{path: path} do
      settings = Config.list_settings()
      assert settings == Schema.all_schemas()
      assert length(settings) == 106

      assert Enum.take(Enum.map(settings, & &1.key_path), 3) == [
               [:scheduler, :default_llm_max_concurrency],
               [:scheduler, :max_tool_concurrency],
               [:scheduler, :agent_max_retries]
             ]

      for descriptor <- settings do
        assert Enum.sort(Map.keys(descriptor)) ==
                 Enum.sort([
                   :key_path,
                   :type,
                   :default,
                   :validation,
                   :category,
                   :sub_category,
                   :description
                 ])

        assert is_binary(descriptor.description) and descriptor.description != ""
      end

      assert %{type: :provider_profiles, default: [], category: :llm, validation: []} =
               Enum.find(settings, &(&1.key_path == [:llm, :providers]))

      refute File.exists?(path)
    end
  end

  describe "show/0 and show/1" do
    test "shows resolved defaults on an empty config without materializing them", %{path: path} do
      assert Config.show() == Config.defaults()
      assert Config.show("scheduler.max_agent_depth") == 8
      assert Config.show("llm.model") == nil
      assert Config.user_config() == %{}
      refute File.exists?(path)
    end

    test "shows the persisted snapshot plus defaults, not a scheduler projection", %{path: path} do
      assert :ok = Config.save_user_config(%{"scheduler" => %{"max_agent_depth" => 713_457}})
      expected = put_in(Config.defaults(), [:scheduler, :max_agent_depth], 713_457)
      assert Config.show() == expected
      assert Config.show() == Config.resolve()

      # Reads stay on the same private RAM snapshot until a reload event.
      File.write!(path, "[scheduler]\nmax_agent_depth = 2\n")
      assert Config.show("scheduler.max_agent_depth") == 713_457
      Cache.reload()
      assert Config.show("scheduler.max_agent_depth") == 2
    end

    test "accepts atom, dotted and mixed list paths including sections and nil values" do
      assert :ok =
               Config.save_user_config(%{sandbox: %{mode: :disabled}, llm: %{temperature: 0.0}})

      for path <- [:scheduler, "scheduler", [:scheduler], ["scheduler"]] do
        assert Config.show(path) == Config.show().scheduler
      end

      for path <- [
            "scheduler.max_agent_depth",
            [:scheduler, :max_agent_depth],
            ["scheduler", :max_agent_depth]
          ] do
        assert Config.show(path) == 8
      end

      assert Config.show("sandbox.mode") == :disabled
      assert Config.show([:llm, "temperature"]) == 0.0
      assert Config.show([:llm, :model]) == nil
    end

    test "distinguishes missing paths from present nils and scalar traversal" do
      assert Config.show("unknown_section.value") ==
               {:error, {:unknown_setting, ["unknown_section", "value"]}}

      assert Config.show("scheduler.unknown_key") == {:error, {:unknown_setting, ["unknown_key"]}}

      assert Config.show("scheduler.max_agent_depth.child") ==
               {:error, {:unknown_setting, ["child"]}}

      assert Config.show("llm.model.child") == {:error, {:unknown_setting, ["child"]}}
      assert Config.show("llm.model") == nil
    end

    test "rejects malformed path families explicitly" do
      for path <- [
            "",
            ".scheduler",
            "scheduler.",
            "scheduler..max_turns",
            " scheduler",
            "scheduler. max_turns",
            [],
            [""],
            ["scheduler.max_turns"],
            [:scheduler, 1],
            42,
            %{}
          ] do
        assert Config.show(path) == {:error, :invalid_path}, inspect(path)
      end
    end

    test "unknown string segments never create atoms" do
      unknown = "operator_unknown_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      assert Config.show(unknown) == {:error, {:unknown_setting, [unknown]}}
      assert Config.show([:scheduler, unknown]) == {:error, {:unknown_setting, [unknown]}}
      assert Config.update(%{unknown => 1}) == {:error, {:unknown_setting, [unknown]}}
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "update/1 persistence" do
    test "a first patch persists only explicit values and immediately refreshes reads", %{
      path: path
    } do
      before = Cache.get()
      assert :ok = Config.update(%{"scheduler.max_agent_depth" => 12})
      assert Config.show("scheduler.max_agent_depth") == 12
      assert Config.show("scheduler.max_turns") == 128
      assert Config.user_config() == %{"scheduler" => %{"max_agent_depth" => 12}}
      assert TomlElixir.decode!(File.read!(path)) == Config.user_config()
      assert Cache.get().generation == before.generation + 1
      assert Cache.get().validation_errors == []
    end

    test "preserves unrelated sections and unknown persisted data", %{path: path} do
      existing = %{
        "scheduler" => %{"max_turns" => 99, "operator_note" => "retain"},
        "appearance" => %{"accent_color" => "teal"},
        "extension_settings" => %{"nested" => %{"enabled" => true, "items" => ["a", "b"]}}
      }

      assert :ok = Config.save_user_config(existing)
      assert :ok = Config.update(%{scheduler: %{max_agent_depth: 12}})
      expected = put_in(existing, ["scheduler", "max_agent_depth"], 12)
      assert Config.user_config() == expected
      assert TomlElixir.decode!(File.read!(path)) == expected
      assert Config.show("appearance.accent_color") == "teal"
    end

    test "combines nested, dotted and mixed list keys without atom/string shadows" do
      assert :ok =
               Config.update(%{
                 :scheduler => %{"max_agent_depth" => 9},
                 "scheduler.max_turns" => 88,
                 [:tools, "search", :enabled] => false,
                 "sandbox" => %{"resources.memory_max" => "2G"},
                 :tmp => %{mode: "custom", path: "settings-scratch"}
               })

      assert Config.user_config() == %{
               "scheduler" => %{"max_agent_depth" => 9, "max_turns" => 88},
               "tools" => %{"search" => %{"enabled" => false}},
               "sandbox" => %{"resources" => %{"memory_max" => "2G"}},
               "tmp" => %{"mode" => "custom", "path" => "settings-scratch"}
             }

      assert Config.show("tmp.mode") == :custom
      assert Config.show("tools.search.enabled") == false
    end

    test "recursively merges map-valued settings and treats payload dots literally" do
      initial = %{
        "provider" => "openai",
        "id" => "operator-uncatalogued",
        "base_url" => "https://api.invalid",
        "options" => %{"headers" => %{"keep" => "yes", "replace" => "old"}, "flags" => ["old"]}
      }

      assert :ok = Config.save_user_config(%{"llm" => %{"model" => initial}})

      assert :ok =
               Config.update(%{
                 "llm.model" => %{
                   options: %{
                     headers: %{"replace" => "new", "x.custom.header" => "literal"},
                     flags: ["new"]
                   }
                 }
               })

      expected =
        put_in(initial, ["options"], %{
          "headers" => %{"keep" => "yes", "replace" => "new", "x.custom.header" => "literal"},
          "flags" => ["new"]
        })

      assert Config.user_config()["llm"] == %{"model" => expected}
      assert Config.show([:llm, :model, "options", "headers", "keep"]) == "yes"
    end

    test "replaces list-valued settings wholesale, including an empty list" do
      assert :ok =
               Config.save_user_config(%{
                 sandbox: %{write_paths: ["old", "retain-no"]},
                 lsp: %{args: ["--old"]}
               })

      assert :ok = Config.update(%{"sandbox.write_paths" => ["new"], "lsp.args" => []})

      assert Config.user_config() == %{
               "sandbox" => %{"write_paths" => ["new"]},
               "lsp" => %{"args" => []}
             }

      assert Config.show("sandbox.write_paths") == ["new"]
      assert Config.show("lsp.args") == []
    end

    test "an empty patch is inert both before and after a persisted config", %{path: path} do
      before = Cache.get()
      assert :ok = Config.update(%{})
      assert Cache.get() == before
      refute File.exists?(path)
      assert :ok = Config.save_user_config(%{scheduler: %{max_turns: 55}})
      assert_unchanged(fn -> assert Config.update(%{}) == :ok end)
    end

    test "canonical inventories replace accounts, normalize nested keys and strip legacy mirrors" do
      assert :ok = Config.save_user_config(%{llm: %{model: "openai:old-model", temperature: 0.2}})

      account = %{
        id: "operator",
        provider: "openai",
        concurrency: 4,
        default_model: "operator-alpha",
        models: [%{model: "operator-alpha", context_window: 64_000}],
        provider_options: %{"custom.option" => %{headers: %{"x-test" => "yes"}}}
      }

      assert :ok =
               Config.update(%{
                 llm: %{providers: [account], default_provider_profile: "operator"}
               })

      expected = %{
        "id" => "operator",
        "provider" => "openai",
        "concurrency" => 4,
        "default_model" => "operator-alpha",
        "models" => [%{"model" => "operator-alpha", "context_window" => 64_000}],
        "provider_options" => %{"custom.option" => %{"headers" => %{"x-test" => "yes"}}}
      }

      assert Config.user_config() == %{
               "llm" => %{"providers" => [expected], "default_provider_profile" => "operator"}
             }

      assert Config.show("llm.providers") == [expected]
      replacement = %{id: "replacement", provider: "openai", models: ["operator-beta"]}

      assert :ok =
               Config.update(%{
                 "llm.providers" => [replacement],
                 "llm.default_provider_profile" => "replacement"
               })

      assert Config.user_config()["llm"]["providers"] == [
               %{"id" => "replacement", "provider" => "openai", "models" => ["operator-beta"]}
             ]

      assert Config.show("llm.default_provider_profile") == "replacement"
    end
  end

  describe "update/1 rejections and failures" do
    setup do
      assert :ok = Config.save_user_config(%{scheduler: %{max_turns: 55}})
      :ok
    end

    test "rejects non-map patches and structs without writing" do
      for patch <- [nil, [], [scheduler: [max_turns: 5]], "scheduler.max_turns", 12, MapSet.new()] do
        assert_unchanged(fn -> assert Config.update(patch) == {:error, :invalid_patch} end)
      end
    end

    test "rejects unknown paths, malformed sections and malformed keys" do
      cases = [
        {%{"scheduler.unknown" => 1}, {:unknown_setting, ["scheduler", "unknown"]}},
        {%{scheduler: %{unknown: 1}}, {:unknown_setting, ["scheduler", "unknown"]}},
        {%{scheduler: 3}, {:invalid_section, ["scheduler"]}},
        {%{scheduler: %{}}, {:invalid_section, ["scheduler"]}},
        {%{"sandbox.resources" => []}, {:invalid_section, ["sandbox", "resources"]}},
        {%{"llm.providers.operator.concurrency" => 3},
         {:unknown_setting, ["llm", "providers", "operator", "concurrency"]}},
        {%{"scheduler..max_turns" => 1}, :invalid_path},
        {%{[:scheduler, 1] => 1}, :invalid_path},
        {%{[] => 1}, :invalid_path},
        {%{42 => 1}, :invalid_path}
      ]

      for {patch, reason} <- cases do
        assert_unchanged(fn -> assert Config.update(patch) == {:error, reason} end)
      end
    end

    test "rejects duplicate aliases rather than choosing a map iteration winner" do
      patches = [
        %{"scheduler.max_turns" => 8, scheduler: %{max_turns: 7}},
        %{"scheduler.max_turns" => 7, [:scheduler, "max_turns"] => 8},
        %{scheduler: %{:max_turns => 7, "max_turns" => 8}},
        %{"llm.model" => %{:id => "one", "id" => "two"}},
        %{"llm.providers" => [%{:id => "one", "id" => "two"}]}
      ]

      for patch <- patches do
        assert_unchanged(fn ->
          assert Config.update(patch) == {:error, :colliding_patch_paths}
        end)
      end
    end

    test "rejects malformed leaf payload keys and nested structs" do
      for {value, reason} <- [
            {%{42 => "value"}, :invalid_path},
            {%{"" => "value"}, :invalid_path},
            {%{options: MapSet.new()}, :invalid_patch},
            {[%{extra: MapSet.new()}], :invalid_patch}
          ] do
        assert_unchanged(fn ->
          assert Config.update(%{"llm.model" => value}) == {:error, reason}
        end)
      end
    end

    test "validates the whole candidate before writing any part of a mixed patch" do
      for {value, rules} <- [{0, [:pos_integer, {:min, 1}]}, {"12", [:pos_integer, {:min, 1}]}] do
        assert_unchanged(fn ->
          assert {:error, errors} =
                   Config.update(%{
                     "scheduler.max_turns" => value,
                     "appearance.accent_color" => "teal"
                   })

          assert Enum.map(errors, & &1.rule) == rules

          for error <- errors do
            assert %ValidationError{key_path: [:scheduler, :max_turns], value: ^value} = error
            assert is_binary(error.message) and error.message != ""
          end
        end)
      end
    end

    test "validates normalized enums and cross-account defaults" do
      assert_unchanged(fn ->
        assert {:error, errors} = Config.update(%{sandbox: %{mode: "not-a-mode"}})

        assert Enum.any?(
                 errors,
                 &match?(%ValidationError{key_path: [:sandbox, :mode], value: "not-a-mode"}, &1)
               )
      end)

      assert_unchanged(fn ->
        assert {:error, errors} =
                 Config.update(%{
                   llm: %{
                     providers: [%{id: "work", provider: "openai", models: ["operator-alpha"]}],
                     default_provider_profile: "missing"
                   }
                 })

        assert Enum.any?(
                 errors,
                 &match?(
                   %ValidationError{
                     key_path: [:llm, :default_provider_profile],
                     value: "missing"
                   },
                   &1
                 )
               )
      end)
    end

    test "rejects invalid provider inventory members before they can be normalized away" do
      cases = [
        {[%{id: "work", provider: "openai", models: ["operator-alpha"], concurrency: -1}],
         [:llm, :providers, 0, :concurrency]},
        {[
           %{id: "work", provider: "openai", models: ["operator-alpha"]},
           %{id: "work", provider: "openai", models: ["operator-beta"]}
         ], [:llm, :providers, 1, :id]},
        {["not-an-account"], [:llm, :providers, 0]}
      ]

      for {providers, error_path} <- cases do
        assert_unchanged(fn ->
          assert {:error, errors} = Config.update(%{"llm.providers" => providers})
          assert Enum.any?(errors, &match?(%ValidationError{key_path: ^error_path}, &1))
        end)
      end
    end

    test "validates unrelated existing values and can repair them explicitly", %{path: path} do
      File.write!(path, "[scheduler]\nmax_turns = 0\n")
      Cache.reload()

      assert_unchanged(fn ->
        assert {:error, errors} = Config.update(%{"appearance.accent_color" => "teal"})

        assert Enum.all?(
                 errors,
                 &match?(%ValidationError{key_path: [:scheduler, :max_turns]}, &1)
               )

        assert errors != []
      end)

      assert :ok =
               Config.update(%{"scheduler.max_turns" => 44, "appearance.accent_color" => "teal"})

      assert Config.user_config() == %{
               "scheduler" => %{"max_turns" => 44},
               "appearance" => %{"accent_color" => "teal"}
             }

      assert Cache.get().validation_errors == []
    end

    test "returns serialization errors without refreshing the snapshot" do
      assert_unchanged(fn ->
        assert {:error, %TomlElixir.Encoder.Error{} = error} =
                 Config.update(%{
                   "llm.model" => %{
                     provider: "openai",
                     id: "operator-alpha",
                     extra: %{unsupported: self()}
                   }
                 })

        assert error.reason =~ "TomlElixir.Encoder"
      end)
    end

    test "returns the actual config-directory creation failure", %{dir: dir, path: path} do
      snapshot = Cache.get()
      File.rm!(path)
      File.rmdir!(dir)
      File.write!(dir, "directory-blocker")
      assert {:error, reason} = File.mkdir_p(dir)
      assert Config.update(%{"scheduler.max_turns" => 99}) == {:error, reason}
      assert Cache.get() == snapshot
      assert File.read!(dir) == "directory-blocker"
    end

    test "returns the actual file-write failure without refreshing", %{path: path} do
      snapshot = Cache.get()
      File.rm!(path)
      File.mkdir!(path)
      assert Config.update(%{"scheduler.max_turns" => 99}) == {:error, :eisdir}
      assert Cache.get() == snapshot
      assert File.dir?(path)
    end
  end

  defp assert_unchanged(fun) do
    bytes = File.read!(Config.config_path())
    snapshot = Cache.get()
    fun.()
    assert File.read!(Config.config_path()) == bytes
    assert Cache.get() == snapshot
  end
end
