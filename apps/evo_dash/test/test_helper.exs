# Redirect data directory to a temp location so tests don't pollute real user data
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

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
  # Clean up test data directory
  test_data_dir = Path.join(System.tmp_dir!(), "evogit_test_data")
  File.rm_rf(test_data_dir)
end)
