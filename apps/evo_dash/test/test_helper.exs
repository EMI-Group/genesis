# Redirect data directory to a temp location so tests don't pollute real user data
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

# The wx-based directory picker must never pop a real native dialog during
# tests — a modal dialog would hang the suite on machines with a display.
# (wx is also pruned from the test code path, so the real picker would
# degrade to unavailable anyway; this flag is the explicit guarantee. The
# root config/test.exs should carry the same flag — escalated to the parent
# agent since ./config/ is outside this app's node.)
Application.put_env(:evo_dash, :directory_picker, enabled: false)

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  # Clean up test data directory
  test_data_dir = Path.join(System.tmp_dir!(), "evogit_test_data")
  File.rm_rf(test_data_dir)
end)
