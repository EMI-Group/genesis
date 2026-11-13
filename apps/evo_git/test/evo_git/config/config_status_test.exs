defmodule EvoGit.Config.ConfigStatusTest do
  @moduledoc """
  Public health checks over the RAM-resident config snapshot: per-process config
  isolation, a custom credential name that never populates ReqLLM's global
  API-key store, and the snapshot's `validation_errors` driving `ok?` instead of
  the removed process-dictionary error slot.

  `async: true` is safe: every test writes into its OWN unique config directory
  (`EvoGit.TestSupport.ConfigDir.isolate!/1`), so neither the files nor the
  `{EvoGit.Config.Cache, dir}` snapshot keys are shared with another module.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Cache
  alias EvoGit.Config.Schema.ValidationError
  alias EvoGit.TestSupport.ConfigDir

  @credential "GENESIS_CONFIG_STATUS_TOKEN"

  setup do
    ConfigDir.isolate!("config_status")
    File.mkdir_p!(Config.config_dir())
    File.write!(Config.credentials_path(), credentials())
    on_exit(fn -> Cache.invalidate(Config.config_dir()) end)
    :ok
  end

  test "an invalid canonical default is unhealthy even with a usable account and no missing keys" do
    File.write!(Config.config_path(), config("missing-account"))

    assert Config.config_status() == %{
             ok?: false,
             missing: [],
             warnings: [],
             validation_errors: [selector_error()]
           }
  end

  test "a repaired config is healthy from a fresh snapshot, never from stale errors" do
    File.write!(Config.config_path(), config("missing-account"))

    first = Config.config_status()
    assert first.ok? == false
    assert first.validation_errors == [selector_error()]

    # Reads are snapshot-backed: an external edit is invisible until an event
    # refreshes the cache, so the error report must not silently change under a
    # caller that owns the file.
    File.write!(Config.config_path(), config("work"))
    stale = Config.config_status()
    assert stale.ok? == false
    assert stale.validation_errors == [selector_error()]

    Cache.reload()
    assert Config.config_status() == healthy_status()
  end

  test "a fresh valid canonical configuration is healthy" do
    File.write!(Config.config_path(), config("work"))
    assert Config.config_status() == healthy_status()
  end

  defp config(default) do
    """
    [llm]
    default_provider_profile = "#{default}"

    [[llm.providers]]
    id = "work"
    provider = "openai"
    auth_mode = "api_key"
    api_key_env_var = "#{@credential}"
    models = ["genesis-config-status-test-model"]

    [tools.search]
    enabled = false
    """
  end

  defp credentials, do: ~s(#{@credential} = "test-account-secret"\n)

  defp selector_error do
    %ValidationError{
      key_path: [:llm, :default_provider_profile],
      message: ~s(default_provider_profile must be one of ["work"], got "missing-account"),
      value: "missing-account",
      rule: {:in, ["work"]}
    }
  end

  defp healthy_status do
    %{ok?: true, missing: [], warnings: [], validation_errors: []}
  end
end
