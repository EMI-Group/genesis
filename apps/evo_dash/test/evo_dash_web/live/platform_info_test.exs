defmodule EvoDashWeb.PlatformInfoTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.PlatformInfo`: OS detection for local/remote
  nodes (with the `:platform_os_override` injection seam), platform predicates,
  and OS-aware schema filtering — plus a round-trip safety pin proving that
  schemas filtered out of the macOS sandbox list can never be clobbered by
  absent form params on save.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.PlatformInfo
  alias EvoDashWeb.SettingsLive.ConfigIO

  describe "show_sandbox?/1" do
    test "is true for linux and macos" do
      assert PlatformInfo.show_sandbox?(:linux)
      assert PlatformInfo.show_sandbox?(:macos)
    end

    test "is false for windows and unknown" do
      refute PlatformInfo.show_sandbox?(:windows)
      refute PlatformInfo.show_sandbox?(:unknown)
    end
  end

  describe "sandbox_backend_for/1" do
    test "maps each OS to its sandbox backend" do
      assert PlatformInfo.sandbox_backend_for(:linux) == :systemd_run
      assert PlatformInfo.sandbox_backend_for(:macos) == :sandbox_exec
      assert PlatformInfo.sandbox_backend_for(:windows) == :none
      assert PlatformInfo.sandbox_backend_for(:unknown) == :none
    end
  end

  describe "filter_schemas_by_category/2" do
    defp sandbox_fixture do
      %{
        sandbox: [
          %{key_path: [:sandbox, :mode], sub_category: nil},
          %{key_path: [:sandbox, :resources, :max_rss], sub_category: :resources},
          %{key_path: [:sandbox, :process, :max_processes], sub_category: :process},
          %{key_path: [:sandbox, :linux, :no_new_privileges], sub_category: :linux}
        ],
        llm: [%{key_path: [:llm, :model], sub_category: nil}]
      }
    end

    test ":linux returns the map unchanged" do
      schemas = sandbox_fixture()

      assert PlatformInfo.filter_schemas_by_category(schemas, :linux) == schemas
    end

    test ":windows removes the sandbox category, leaving other categories untouched" do
      schemas = sandbox_fixture()

      filtered = PlatformInfo.filter_schemas_by_category(schemas, :windows)

      refute Map.has_key?(filtered, :sandbox)
      assert filtered.llm == schemas.llm
    end

    test ":unknown behaves like :windows" do
      schemas = sandbox_fixture()

      filtered = PlatformInfo.filter_schemas_by_category(schemas, :unknown)

      refute Map.has_key?(filtered, :sandbox)
      assert filtered.llm == schemas.llm
    end

    test ":macos keeps only sub_category-nil schemas in the sandbox entry" do
      schemas = sandbox_fixture()

      filtered = PlatformInfo.filter_schemas_by_category(schemas, :macos)

      assert filtered.sandbox == [%{key_path: [:sandbox, :mode], sub_category: nil}]
      assert filtered.llm == schemas.llm
    end

    test ":macos on a map without a :sandbox key produces an empty sandbox entry" do
      schemas = %{llm: [%{key_path: [:llm, :model], sub_category: nil}]}

      filtered = PlatformInfo.filter_schemas_by_category(schemas, :macos)

      assert filtered.sandbox == []
      assert filtered.llm == schemas.llm
    end
  end

  describe "os_for_node/1" do
    test "override wins even for a remote node" do
      Application.put_env(:evo_dash, :platform_os_override, :windows)
      on_exit(fn -> Application.delete_env(:evo_dash, :platform_os_override) end)

      assert PlatformInfo.os_for_node(:anything_remote@host) == :windows
    end

    test ":unknown override passes through" do
      Application.put_env(:evo_dash, :platform_os_override, :unknown)
      on_exit(fn -> Application.delete_env(:evo_dash, :platform_os_override) end)

      assert PlatformInfo.os_for_node(nil) == :unknown
    end

    test "non-override value is ignored and falls through to detection" do
      Application.put_env(:evo_dash, :platform_os_override, :bogus)
      on_exit(fn -> Application.delete_env(:evo_dash, :platform_os_override) end)

      assert PlatformInfo.os_for_node(nil) == EvoGit.Platform.os()
    end

    test "local node detection matches EvoGit.Platform.os/0" do
      assert PlatformInfo.os_for_node(nil) == EvoGit.Platform.os()
      assert PlatformInfo.os_for_node(node()) == EvoGit.Platform.os()
    end

    test "fake remote node degrades to :unknown without raising" do
      assert PlatformInfo.os_for_node(:nonexistent@nohost) == :unknown
    end
  end

  describe "round-trip safety: hidden (filtered-out) schemas are never clobbered" do
    # Mirrors the real macOS-visible sandbox schemas (:sub_category == nil),
    # like the fixtures in config_io_test.exs — only key_path/type/sub_category
    # (+ the :atom whitelist) matter for the logic.
    defp mode_schema do
      %{
        key_path: [:sandbox, :mode],
        type: :atom,
        sub_category: nil,
        validation: [in: [:auto, :enabled, :disabled]]
      }
    end

    defp write_paths_schema do
      %{
        key_path: [:sandbox, :write_paths],
        type: :list_of_strings,
        sub_category: nil
      }
    end

    test "absent params for filtered-out schemas do not delete their config keys" do
      # macOS-filtered sandbox schema list: only :sub_category == nil fields
      # (mode, write_paths). The resources/linux schemas are absent from the
      # list, so the form has no keys for them — and they must NOT be
      # deep-deleted as "emptied" on save.
      macos_sandbox_schemas = [mode_schema(), write_paths_schema()]

      file_config = %{
        sandbox: %{
          mode: :auto,
          write_paths: ["/tmp/a"],
          resources: %{max_rss: 1024},
          linux: %{no_new_privileges: true}
        }
      }

      params = %{"sandbox.mode" => "auto", "sandbox.write_paths" => ["/tmp/a"]}

      config =
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          macos_sandbox_schemas,
          file_config
        )

      assert get_in(config, [:sandbox, :resources, :max_rss]) == 1024
      assert get_in(config, [:sandbox, :linux, :no_new_privileges]) == true
      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a"]
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "negative control: absent param for a rendered schema IS the delete signal" do
      schemas = [mode_schema(), write_paths_schema()]

      file_config = %{sandbox: %{mode: :auto, write_paths: ["/tmp/a"]}}

      # write_paths is present in the schema list (rendered) but absent from
      # the form → deep-deleted (pre-existing semantics).
      config =
        ConfigIO.build_config_from_category_params(
          %{"sandbox.mode" => "auto"},
          :sandbox,
          schemas,
          file_config
        )

      assert is_nil(get_in(config, [:sandbox, :write_paths]))
      assert get_in(config, [:sandbox, :mode]) == :auto
    end
  end
end
