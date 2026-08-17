defmodule EvoDashWeb.ProjectsLive.ProjectTest do
  @moduledoc """
  Unit tests for `EvoDashWeb.ProjectsLive.Project.load_model_profiles/0,1` —
  the node-aware model-profile resolution for the remote-development dashboard.

  The profiles come from the config of the node being viewed (the node that
  will actually run the launched task): the local node uses
  `EvoGit.Config.resolve/0` (with the mount-set `:memo_config_resolve`
  Process-dict memo), while a remote node resolves via
  `EvoDash.NodeContext.get_resolved_config/1` and degrades to `{[], nil}` on
  RPC failure. A fake test node can never answer `:erpc` (it fails
  immediately with `{:erpc, :noconnection}` on the non-distributed test VM),
  so the degradation branch is the only remote path testable end-to-end — the
  selection logic itself is pinned through the public pure
  `load_model_profiles_from_config/2` seam (its moduledoc explicitly exposes
  it for unit testing with an injected config map).

  NOTE: `async: false` — every test isolates `XDG_CONFIG_HOME` (same rationale
  as `node_aware_test.exs`).
  """

  use ExUnit.Case, async: false

  alias EvoDashWeb.ProjectsLive.Project
  alias EvoGit.Config

  # A fake remote BEAM node name. The tests never connect to it — it only has
  # to differ from `node()` (the test VM node is `:nonode@nohost`) so the
  # remote branch runs; `:erpc.call` to it fails fast (no TCP timeout wait).
  @remote_node :"genesis_remote@127.0.0.1"

  # Resolved-config-shaped map with a single profile, matching the shape
  # `EvoGit.Config.resolve/0` produces (atom-keyed `:llm.models` list).
  defp config_with_profiles do
    %{llm: %{models: [%{id: "profile-a", model: "anthropic:claude-sonnet-5"}]}}
  end

  # Isolates XDG_CONFIG_HOME per test: the config.toml (and agents.toml) that
  # Config.resolve/0 and EvoGit.CustomAgents read resolve into a fresh temp
  # dir, so the tests are deterministic regardless of the host's real config.
  defp isolate_config_dir do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_project_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    :ok
  end

  # Writes a config.toml with a single model profile into the isolated
  # XDG_CONFIG_HOME so Config.resolve/0 has a profile to expose. Mirrors the
  # same-named helper in projects_live_test.exs.
  defp write_model_profile_config do
    config_path = Config.config_path()
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(config_path, """
    [[llm.models]]
    id = "profile-a"
    model = {provider = "anthropic", id = "claude-sonnet-5"}
    concurrency = 3
    """)
  end

  setup do
    isolate_config_dir()
    :ok
  end

  describe "load_model_profiles_from_config/2 (pure selection logic)" do
    test "returns the first profile's id as the default selection without a script" do
      assert {[%{id: "profile-a"}], "profile-a"} =
               Project.load_model_profiles_from_config(config_with_profiles(), false)
    end

    test "returns the \"\" sentinel (Auto by rules) when the model-selection script is enabled" do
      assert {[%{id: "profile-a"}], ""} =
               Project.load_model_profiles_from_config(config_with_profiles(), true)
    end

    test "returns {[], nil} when no profiles exist and no script is enabled" do
      assert {[], nil} = Project.load_model_profiles_from_config(%{llm: %{models: []}}, false)

      # A config without an :llm section is treated the same — never raises.
      assert {[], nil} = Project.load_model_profiles_from_config(%{}, false)
    end

    test "returns {[], \"\"} when no profiles exist but the script is enabled" do
      assert {[], ""} = Project.load_model_profiles_from_config(%{llm: %{models: []}}, true)
    end
  end

  describe "load_model_profiles/0,1 (local node)" do
    test "reads the resolved config from the isolated XDG_CONFIG_HOME and selects the first profile" do
      write_model_profile_config()

      assert {profiles, "profile-a"} = Project.load_model_profiles()
      assert [%{id: "profile-a"} | _] = profiles
    end

    test "a configured model-selection script yields the \"\" sentinel (Auto by rules)" do
      write_model_profile_config()
      :ok = EvoGit.CustomAgents.save_model_selection_script(~s("profile-a"))
      EvoGit.CustomAgents.reload()

      assert {[_profile], ""} = Project.load_model_profiles()
    end

    test "load_model_profiles(nil) delegates to the local node" do
      write_model_profile_config()

      assert Project.load_model_profiles(nil) == Project.load_model_profiles(node())
      assert {[_profile], "profile-a"} = Project.load_model_profiles(nil)
    end

    test "the :memo_config_resolve Process-dict memo is honored on the local node" do
      Process.put(:memo_config_resolve, config_with_profiles())

      # The memo replaces the Config.resolve() call entirely.
      assert {[%{id: "profile-a"}], "profile-a"} = Project.load_model_profiles(node())

      Process.delete(:memo_config_resolve)
    end
  end

  describe "load_model_profiles/1 (remote node degradation)" do
    test "an unreachable remote node degrades to {[], nil} without raising" do
      # No real BEAM node answers :erpc (fails immediately with
      # {:erpc, :noconnection}) — get_resolved_config returns {:error, _} and
      # the documented degradation branch returns {[], nil}.
      assert {[], nil} = Project.load_model_profiles(@remote_node)
    end

    test "the local memo is LOCAL-only — never consulted for remote nodes" do
      Process.put(:memo_config_resolve, config_with_profiles())

      # Even with a rich local memo, the remote branch must NOT use it — it
      # goes through NodeContext and degrades on the failed RPC.
      assert {[], nil} = Project.load_model_profiles(@remote_node)

      Process.delete(:memo_config_resolve)
    end
  end
end
