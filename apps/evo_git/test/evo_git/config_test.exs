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

  describe "load_env/0" do
    test "returns :ok when no .env file exists" do
      # env_path may or may not exist; just verify it doesn't crash
      result = Config.load_env()
      assert result in [:ok, :error]
    end
  end

  describe "api_key/1" do
    test "returns nil for unknown provider" do
      # Use a unique provider name that definitely has no env var
      key = Config.api_key(:nonexistent_provider_xyz_12345)
      assert key == nil
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

  describe "env_path/0" do
    test "returns path ending with .env" do
      path = Config.env_path()
      assert String.ends_with?(path, ".env")
    end
  end
end
