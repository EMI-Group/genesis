# Redirect data directory to a temp location so tests don't pollute real user data
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  # Clean up test data directory
  test_data_dir = Path.join(System.tmp_dir!(), "evogit_test_data")
  File.rm_rf(test_data_dir)
end)
