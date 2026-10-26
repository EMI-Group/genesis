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

  # Installs a global app-env seam value for this test and restores it in
  # `on_exit` — app env is process-wide, so the delete must always run.
  defp override(key, value) do
    Application.put_env(:evo_dash, key, value)
    on_exit(fn -> Application.delete_env(:evo_dash, key) end)
  end

  describe "platform predicates" do
    test "show_sandbox?/1 is true only for linux/macos and sandbox_backend_for/1 maps each OS" do
      for os <- [:linux, :macos] do
        assert PlatformInfo.show_sandbox?(os), "expected show_sandbox?(#{inspect(os)})"
      end

      for os <- [:windows, :unknown] do
        refute PlatformInfo.show_sandbox?(os), "expected not show_sandbox?(#{inspect(os)})"
      end

      for {os, backend} <- [
            {:linux, :systemd_run},
            {:macos, :sandbox_exec},
            {:windows, :none},
            {:unknown, :none}
          ] do
        assert PlatformInfo.sandbox_backend_for(os) == backend,
               "expected #{inspect(os)} to map to #{inspect(backend)}"
      end
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

    test ":linux returns the map unchanged; :windows and :unknown drop only the sandbox category" do
      schemas = sandbox_fixture()

      assert PlatformInfo.filter_schemas_by_category(schemas, :linux) == schemas

      for os <- [:windows, :unknown] do
        filtered = PlatformInfo.filter_schemas_by_category(schemas, os)

        refute Map.has_key?(filtered, :sandbox), "expected :sandbox dropped for #{inspect(os)}"
        assert filtered.llm == schemas.llm
      end
    end

    test ":macos keeps only sub_category-nil sandbox schemas (empty entry when the category is absent)" do
      schemas = sandbox_fixture()

      filtered = PlatformInfo.filter_schemas_by_category(schemas, :macos)

      assert filtered.sandbox == [%{key_path: [:sandbox, :mode], sub_category: nil}]
      assert filtered.llm == schemas.llm

      without_sandbox = %{llm: [%{key_path: [:llm, :model], sub_category: nil}]}
      filtered = PlatformInfo.filter_schemas_by_category(without_sandbox, :macos)

      assert filtered.sandbox == []
      assert filtered.llm == without_sandbox.llm
    end
  end

  describe "os_for_node/1" do
    test "a valid override wins even for a remote node (:unknown passes through)" do
      override(:platform_os_override, :windows)
      assert PlatformInfo.os_for_node(:anything_remote@host) == :windows

      Application.put_env(:evo_dash, :platform_os_override, :unknown)
      assert PlatformInfo.os_for_node(nil) == :unknown
    end

    test "a non-override value is ignored and falls through; a fake remote node degrades to :unknown" do
      override(:platform_os_override, :bogus)

      assert PlatformInfo.os_for_node(nil) == EvoGit.Platform.os()
      assert PlatformInfo.os_for_node(node()) == EvoGit.Platform.os()

      Application.delete_env(:evo_dash, :platform_os_override)
      assert PlatformInfo.os_for_node(:nonexistent@nohost) == :unknown
    end
  end

  describe "nix_available_for_node/1" do
    test "a boolean override wins even for a remote node (false is honored too)" do
      override(:nix_available_override, true)
      assert PlatformInfo.nix_available_for_node(:anything_remote@host)

      Application.put_env(:evo_dash, :nix_available_override, false)
      refute PlatformInfo.nix_available_for_node(nil)
    end

    test "a non-boolean override is ignored and falls through; a fake remote node degrades to false" do
      override(:nix_available_override, :bogus)

      # Falls through to EvoGit.Platform.nix_available?/0 on the local node —
      # the result is whatever the host says, but always a boolean.
      assert is_boolean(PlatformInfo.nix_available_for_node(nil))
      assert PlatformInfo.nix_available_for_node(nil) == EvoGit.Platform.nix_available?()
      assert PlatformInfo.nix_available_for_node(node()) == EvoGit.Platform.nix_available?()

      # call_remote normalizes erpc failures to {:error, _} → conservative false.
      Application.delete_env(:evo_dash, :nix_available_override)
      refute PlatformInfo.nix_available_for_node(:nonexistent@nohost)
    end
  end

  describe "nix_enabled_explicitly?/1 (pure)" do
    test "an explicit true OR false counts as configured; absent/empty is false" do
      cases = [
        # TomlElixir.decode returns string keys — the real raw-config shape.
        {%{"nix" => %{"enabled" => true}}, true},
        {%{"nix" => %{"enabled" => false}}, true},
        {%{nix: %{enabled: true}}, true},
        # present [nix] table without an :enabled key
        {%{"nix" => %{}}, false},
        {%{}, false}
      ]

      for {config, expected} <- cases do
        assert PlatformInfo.nix_enabled_explicitly?(config) == expected,
               "expected #{inspect(config)} to be #{expected}"
      end
    end
  end

  describe "show_nix_category?/1 and filter_nix_category/2" do
    defp nix_schemas do
      %{nix: [%{key_path: [:nix, :enabled]}], llm: [%{key_path: [:llm, :model]}]}
    end

    test "a false override + unresponsive remote node hides and strips :nix; a true override keeps it" do
      # The false override forces nix_available_for_node to false; the remote RPC
      # to a nonexistent node fails and nix_enabled_explicitly_for_node degrades
      # to false — deterministic, no local host config is ever read.
      override(:nix_available_override, false)
      refute PlatformInfo.show_nix_category?(:nonexistent@nohost)

      schemas = nix_schemas()
      assert PlatformInfo.filter_nix_category(schemas, :nonexistent@nohost) == %{llm: schemas.llm}

      # The true override short-circuits (no config read) → category kept.
      Application.put_env(:evo_dash, :nix_available_override, true)
      assert PlatformInfo.show_nix_category?(nil)
      assert PlatformInfo.filter_nix_category(schemas, nil) == schemas
    end
  end

  describe "round-trip safety: hidden (filtered-out) schemas are never clobbered" do
    # Mirrors the real macOS-visible sandbox schemas (:sub_category == nil) —
    # only key_path/type/sub_category (+ the :atom whitelist) matter for the logic.
    defp mode_schema do
      %{
        key_path: [:sandbox, :mode],
        type: :atom,
        sub_category: nil,
        validation: [in: [:auto, :enabled, :disabled]]
      }
    end

    defp save_sandbox(params, file_config) do
      ConfigIO.build_config_from_category_params(
        params,
        :sandbox,
        [
          mode_schema(),
          %{key_path: [:sandbox, :write_paths], type: :list_of_strings, sub_category: nil}
        ],
        file_config
      )
    end

    test "absent params for filtered-out schemas never delete their keys (a rendered one IS deleted)" do
      # The macOS-filtered list holds only :sub_category == nil fields (mode,
      # write_paths). resources/linux schemas are absent from it, so the form has
      # no keys for them — and they must NOT be deep-deleted as "emptied" on save.
      config =
        save_sandbox(%{"sandbox.mode" => "auto", "sandbox.write_paths" => ["/tmp/a"]}, %{
          sandbox: %{
            mode: :auto,
            write_paths: ["/tmp/a"],
            resources: %{max_rss: 1024},
            linux: %{no_new_privileges: true}
          }
        })

      assert get_in(config, [:sandbox, :resources, :max_rss]) == 1024
      assert get_in(config, [:sandbox, :linux, :no_new_privileges]) == true
      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a"]
      assert get_in(config, [:sandbox, :mode]) == :auto

      # Negative control: write_paths IS in the schema list (rendered) but absent
      # from the form → deep-deleted (pre-existing semantics).
      config =
        save_sandbox(%{"sandbox.mode" => "auto"}, %{
          sandbox: %{mode: :auto, write_paths: ["/tmp/a"]}
        })

      assert is_nil(get_in(config, [:sandbox, :write_paths]))
      assert get_in(config, [:sandbox, :mode]) == :auto
    end
  end
end
