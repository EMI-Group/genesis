# Redirect data directory to temp so tests NEVER touch the production database
# (~/.local/share/genesis/tasks.sqlite). This is a belt-and-suspenders fallback;
# the canonical guard is config :evo_git, :data_dir in config/test.exs.
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

ExUnit.start(capture_log: true)
