# Redirect data directory to a temp location so tests don't pollute real user data
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

# Redirect the config directory (XDG_CONFIG_HOME) to a run-unique EMPTY dir,
# mirroring the XDG_DATA_HOME redirect above. EvoGit.Config.config_dir/0 derives
# the config path from XDG_CONFIG_HOME on Linux, so redirecting it here keeps the
# whole suite hermetic: no module reads (or writes) the developer's real
# ~/.config/genesis. The dir is UNIQUE PER BEAM (os pid + unique int) so two
# concurrently running `mix test` runs never share a config dir — the same
# cross-run isolation the data-dir guard provides.
#
# Suites that WRITE config still point XDG_CONFIG_HOME at their own per-test temp
# dir (System.put_env is process-global, which is exactly why those suites stay
# `async: false`) and restore the prior value in on_exit — System.get_env now
# returns this boot dir (never nil), so their restore lands back here.
#
# NOTE: on macOS EvoGit.Platform.base_dir/3 ignores XDG_CONFIG_HOME entirely
# (config is always ~/Library/Application Support); this redirect is therefore a
# no-op there, matching the pre-existing platform behaviour.
test_config_home =
  Path.join(
    System.tmp_dir!(),
    "evogit_test_config/genesis-#{System.pid()}-#{:erlang.unique_integer([:positive])}"
  )

File.mkdir_p!(test_config_home)
System.put_env("XDG_CONFIG_HOME", test_config_home)

# The wx-based directory picker must never pop a real native dialog during
# tests — a modal dialog would hang the suite on machines with a display.
# (wx is also pruned from the test code path, so the real picker would
# degrade to unavailable anyway; this flag is the explicit guarantee.)
# config/test.exs carries the same flag for a real `mix test` run; this line
# keeps the guarantee when the app is exercised through other entry points.
Application.put_env(:evo_dash, :directory_picker, enabled: false)

# Default nix integration OFF for the whole suite. EvoGit.Nix.enabled?/0 reads
# this app env first; when unset it falls back to the developer's REAL
# ~/.config/genesis config and shells out to real `nix print-dev-env` (which is
# slow, contends on the shared eval-cache SQLite DB, and spams the console with
# "waiting for another Nix process to finish fetching input ..." + eval-cache
# "database is busy" noise). Nix is only consulted LAZILY during tests
# (sandbox/None + system-check paths), so setting it here — after app boot but
# before any test runs — is effective and race-free for every async module.
# Tests that specifically need nix enable it explicitly.
Application.put_env(:evo_git, :nix_enabled, false)

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  # Remove ONLY this run's unique data dir (from the app env). Never remove the
  # shared parent `System.tmp_dir!()/evogit_test_data`: a concurrently running
  # `mix test` owns a sibling unique dir under it, so deleting the parent would
  # nuke that run's SQLite database mid-flight.
  test_data_dir = Application.get_env(:evo_git, :data_dir)
  if is_binary(test_data_dir), do: File.rm_rf(test_data_dir)

  # Same for the run-unique config dir seeded above — remove only this run's
  # own dir, never the shared `System.tmp_dir!()/evogit_test_config` parent.
  File.rm_rf(test_config_home)
end)
