# Redirect data directory to temp so tests NEVER touch the production database
# (~/.local/share/genesis/tasks.sqlite). This is a belt-and-suspenders fallback;
# the canonical guard is config :evo_git, :data_dir in config/test.exs.
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

# Default nix integration OFF for the whole suite. EvoGit.Nix.enabled?/0 reads this
# app env first; when unset it falls back to the developer's REAL ~/.config/genesis
# config and shells out to real `nix print-dev-env`, leaking its inherited stderr
# progress ("evaluating derivation ..." + dots) to the test console. Nix is only
# consulted LAZILY during tests (sandbox/None paths), so setting it here — after app
# boot but before any test runs — is effective and race-free for every async module.
# Tests that specifically need nix enable it explicitly (e.g. sandbox/bwrap_test.exs).
Application.put_env(:evo_git, :nix_enabled, false)

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  # Remove ONLY this run's unique data dir (from the app env). Never remove the
  # shared parent `System.tmp_dir!()/evogit_test_data`: a concurrently running
  # `mix test` owns a sibling unique dir under it, so deleting the parent would
  # nuke that run's SQLite database mid-flight.
  test_data_dir = Application.get_env(:evo_git, :data_dir)
  if is_binary(test_data_dir), do: File.rm_rf(test_data_dir)
end)
