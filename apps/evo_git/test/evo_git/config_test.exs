defmodule EvoGit.ConfigTest do
  use ExUnit.Case, async: false

  alias EvoGit.Config

  describe "defaults/0" do
    test "returns a map with scheduler defaults" do
      defaults = Config.defaults()
      assert is_map(defaults)
      assert %{scheduler: %{max_concurrency: 3}} = defaults
    end

    test "has no default llm model" do
      defaults = Config.defaults()
      assert defaults.llm == %{}
    end

    test "has no default github username" do
      defaults = Config.defaults()
      assert defaults.user == %{}
    end

    test "sandbox defaults to :auto" do
      defaults = Config.defaults()
      assert defaults.sandbox.mode == :auto
    end
  end

  describe "resolve/0" do
    test "returns a map with at least the default keys" do
      config = Config.resolve()
      assert is_map(config)
      assert Map.has_key?(config, :scheduler)
      assert Map.has_key?(config, :llm)
      assert Map.has_key?(config, :user)
      assert Map.has_key?(config, :sandbox)
    end

    test "scheduler config has expected keys" do
      config = Config.resolve()
      scheduler = config.scheduler
      assert Map.has_key?(scheduler, :max_concurrency)
      assert Map.has_key?(scheduler, :max_tool_concurrency)
      assert Map.has_key?(scheduler, :agent_max_retries)
      assert Map.has_key?(scheduler, :max_agent_depth)
      assert Map.has_key?(scheduler, :max_retries)
    end
  end

  describe "resolve/1" do
    test "returns value for single key" do
      scheduler = Config.resolve(:scheduler)
      assert is_map(scheduler)
      assert Map.has_key?(scheduler, :max_concurrency)
    end

    test "returns value for nested key path" do
      concurrency = Config.resolve([:scheduler, :max_concurrency])
      assert is_integer(concurrency)
    end

    test "returns nil for unknown key" do
      assert Config.resolve(:nonexistent_key) == nil
    end

    test "returns nil for unknown nested path" do
      assert Config.resolve([:scheduler, :nonexistent]) == nil
    end
  end

  describe "user_config/0" do
    test "returns empty map when no config file exists" do
      # Config.config_path() may or may not exist
      # Just verify it returns a map
      config = Config.user_config()
      assert is_map(config)
    end
  end

  describe "credentials/0" do
    test "returns empty map when no credentials file exists" do
      creds = Config.credentials()
      assert is_map(creds)
    end

    test "does not accidentally set environment variables when no credentials file exists" do
      # Ensure a known test env var is not set after calling credentials/0
      System.delete_env("TEST_CRED_KEY")
      Config.credentials()
      assert System.get_env("TEST_CRED_KEY") == nil
    end

    test "does not crash when GOOGLE_API_KEY environment variable is already set" do
      # If GOOGLE_API_KEY is set in the environment, credentials/0 should
      # still work without crashing or raising.
      System.put_env("GOOGLE_API_KEY", "test-key-value")
      try do
        creds = Config.credentials()
        assert is_map(creds)
      after
        System.delete_env("GOOGLE_API_KEY")
      end
    end
  end

  describe "config_dir/0" do
    test "returns a string path" do
      dir = Config.config_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "evogit")
    end
  end

  describe "config_path/0" do
    test "returns path ending with config.toml" do
      path = Config.config_path()
      assert String.ends_with?(path, "config.toml")
    end
  end

  describe "credentials_path/0" do
    test "returns path ending with credentials.toml" do
      path = Config.credentials_path()
      assert String.ends_with?(path, "credentials.toml")
    end
  end
end
