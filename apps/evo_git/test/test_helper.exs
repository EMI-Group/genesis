# Create a temporary config directory for testing
tmp_config_parent = Path.join(System.tmp_dir!(), "evogit_test_config_#{System.unique_integer([:positive])}")
tmp_config_dir = Path.join(tmp_config_parent, "evogit")
File.mkdir_p!(tmp_config_dir)

# Write a minimal config.toml with a test model
File.write!(Path.join(tmp_config_dir, "config.toml"), """
[scheduler]
max_concurrency = 3
max_tool_concurrency = 2
agent_max_retries = 3
max_agent_depth = 8
max_retries = 15

[llm]
model = "test:test-model"
""")

# Point XDG_CONFIG_HOME to our temp directory
System.put_env("XDG_CONFIG_HOME", tmp_config_parent)

ExUnit.start()
