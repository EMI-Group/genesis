defmodule EvoGit.Config.ConfigStatusTest do
  @moduledoc """
  Public disk-backed health checks with per-process config isolation and a custom
  credential name that never populates ReqLLM's global API-key store.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Schema.ValidationError
  alias EvoGit.TestSupport.ConfigDir

  @errors_key :evo_git_config_validation_errors
  @credential "GENESIS_CONFIG_STATUS_TOKEN"

  setup do
    ConfigDir.isolate!("config_status")
    File.mkdir_p!(Config.config_dir())
    File.write!(Config.credentials_path(), credentials())
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

  # A FIFO rendezvous is POSIX-only; all paths and processes belong to this test,
  # so this real I/O requires neither global app-env changes nor serialization.
  @tag skip: match?({:win32, _}, :os.type())
  test "initial errors survive a successful nested resolve inside the same health check" do
    config_path = Config.config_path()
    credentials_path = Config.credentials_path()
    File.write!(config_path, config("missing-account"))
    File.rm!(credentials_path)
    assert {_, 0} = System.cmd("mkfifo", [credentials_path], stderr_to_stdout: true)

    caller = self()

    writer =
      Task.async(fn ->
        # Opening the writer blocks until config_status has finished its initial
        # resolve and starts reading credentials. Repair the config BEFORE EOF
        # releases that read, so tools_search_enabled?'s nested resolve must see
        # the valid selector. The changed file size also invalidates the cache.
        # Use raw I/O for BOTH writes: the shared file server is waiting for the
        # credentials read to finish and cannot service a normal File.write!.
        File.open!(credentials_path, [:raw, :write], fn pipe ->
          initial_errors = Process.info(caller, :dictionary)
          File.open!(config_path, [:raw, :write], &IO.binwrite(&1, config("work")))
          IO.binwrite(pipe, credentials())
          initial_errors
        end)
      end)

    status = Config.config_status()
    {:dictionary, during_health_check} = Task.await(writer, 30_000)

    # Prove the rendezvous really occurred after the failing initial resolve.
    assert Keyword.fetch!(during_health_check, @errors_key) == [selector_error()]
    # And the later resolve really succeeded BEFORE config_status returned,
    # clearing the caller-local error slot without clearing its saved report.
    assert Process.get(@errors_key, :cleared) == :cleared

    assert status == %{
             ok?: false,
             missing: [],
             warnings: [],
             validation_errors: [selector_error()]
           }

    # A new invocation must describe the repaired config, not retain old errors.
    # Restore an ordinary credentials file rather than relying on FIFO caching.
    File.rm!(credentials_path)
    File.write!(credentials_path, credentials())
    assert Config.config_status() == healthy_status()
  end

  test "a fresh valid canonical configuration is healthy" do
    File.write!(Config.config_path(), config("work"))
    assert Config.config_status() == healthy_status()
    assert Process.get(@errors_key, :cleared) == :cleared
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
