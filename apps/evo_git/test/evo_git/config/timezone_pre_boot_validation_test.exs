defmodule EvoGit.Config.TimezonePreBootValidationTest do
  @moduledoc """
  Regression pin: schema validation of an IANA provider `timezone` must not
  depend on the AMBIENT `Calendar` time zone database.

  `config/runtime.exs` builds a config snapshot through
  `EvoGit.Config.resolve/0` → `EvoGit.Config.build_snapshot/1` BEFORE
  `EvoGit.Application.start/2` reaches
  `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)`, so at that moment the
  ambient database is Elixir's `Calendar.UTCOnlyTimeZoneDatabase`. Validation
  therefore resolves IANA names against the bundled `Tz.TimeZoneDatabase`
  explicitly (`EvoGit.PeakHours.config_time_zone_database/0`).

  `async: false` because `Calendar.put_time_zone_database/1` writes
  process-wide `:persistent_term` state that every concurrently running module
  observes.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Config
  alias EvoGit.Config.Cache
  alias EvoGit.Config.Schema.ValidationError
  alias EvoGit.TestSupport.ConfigDir

  @credential "GENESIS_TZ_PREBOOT_TEST_TOKEN"

  setup do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Calendar.UTCOnlyTimeZoneDatabase)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)

    ConfigDir.isolate!("config_timezone_preboot")
    File.mkdir_p!(Config.config_dir())
    on_exit(fn -> Cache.invalidate(Config.config_dir()) end)

    :ok
  end

  defp config(timezone) do
    """
    [llm]
    default_provider_profile = "acct"

    [[llm.providers]]
    id = "acct"
    provider = "openai"
    auth_mode = "api_key"
    api_key_env_var = "#{@credential}"
    timezone = "#{timezone}"
    models = ["genesis-tz-pre-boot-test-model"]

    [tools.search]
    enabled = false
    """
  end

  defp write_config!(timezone) do
    File.write!(Config.config_path(), config(timezone))
    File.write!(Config.credentials_path(), ~s(#{@credential} = "test-account-secret"\n))
  end

  test "a pre-boot snapshot keeps the ambient UTC-only database" do
    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
  end

  test "an IANA timezone is valid while the ambient database is UTC-only" do
    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase

    for timezone <- ["UTC", "Asia/Shanghai"] do
      write_config!(timezone)
      Cache.invalidate(Config.config_dir())

      snapshot = Config.build_snapshot(Config.config_dir())

      assert snapshot.validation_errors == [],
             "pre-boot snapshot for #{timezone} reported #{inspect(snapshot.validation_errors)}"
    end
  end

  test "a genuinely unknown timezone still fails with the ambient database UTC-only" do
    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase

    write_config!("Not/AZone")
    Cache.invalidate(Config.config_dir())

    snapshot = Config.build_snapshot(Config.config_dir())

    assert [error] = snapshot.validation_errors

    assert %ValidationError{
             key_path: [:llm, :providers, 0, :timezone],
             rule: :timezone,
             value: "Not/AZone"
           } = error
  end
end
