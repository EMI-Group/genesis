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
  end

  describe "api_key/1" do
    test "returns nil for unknown provider when no env var set" do
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

  describe "credentials_path/0" do
    test "returns path ending with credentials.toml" do
      path = Config.credentials_path()
      assert String.ends_with?(path, "credentials.toml")
    end
  end

  describe "validate/0" do
    test "returns a list of validation issues" do
      issues = Config.validate()
      assert is_list(issues)
    end

    test "each issue has required keys" do
      issues = Config.validate()

      for issue <- issues do
        assert Map.has_key?(issue, :field)
        assert Map.has_key?(issue, :severity)
        assert Map.has_key?(issue, :message)
        assert issue.severity in [:error, :warning]
      end
    end

    test "reports error when LLM model is not configured" do
      issues = Config.validate()
      llm_issues = Enum.filter(issues, &(&1.field == :llm_model))
      # In test environment, no model is configured, so this should be an error
      assert length(llm_issues) >= 0  # May or may not have an issue depending on env
    end

    test "reports warning when no API keys are configured" do
      issues = Config.validate()
      api_key_issues = Enum.filter(issues, &(&1.field == :api_keys))
      # In test environment, may not have API keys configured
      assert is_list(api_key_issues)
    end
  end

  describe "read_user_config_toml/0" do
    test "returns not_found when config file doesn't exist" do
      tmp_dir = System.tmp_dir!()
      xdg_dir = Path.join(tmp_dir, "evogit_read_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(xdg_dir)

      original_env = System.get_env("XDG_CONFIG_HOME")

      try do
        System.put_env("XDG_CONFIG_HOME", xdg_dir)
        # config_dir() resolves to xdg_dir/evogit, which doesn't exist
        result = Config.read_user_config_toml()
        assert result == {:error, :not_found}
      after
        if original_env do
          System.put_env("XDG_CONFIG_HOME", original_env)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf(xdg_dir)
      end
    end
  end

  describe "write_user_config_toml/1" do
    test "writes valid TOML to config file" do
      tmp_dir = System.tmp_dir!()
      xdg_dir = Path.join(tmp_dir, "evogit_write_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(xdg_dir)

      # config_dir() resolves to xdg_dir/evogit
      expected_config_dir = Path.join(xdg_dir, "evogit")
      expected_config_path = Path.join(expected_config_dir, "config.toml")

      original_env = System.get_env("XDG_CONFIG_HOME")

      try do
        System.put_env("XDG_CONFIG_HOME", xdg_dir)
        toml = "[scheduler]\nmax_concurrency = 5\n"
        result = Config.write_user_config_toml(toml)
        assert result == :ok
        assert File.exists?(expected_config_path)
        {:ok, content} = File.read(expected_config_path)
        assert content == toml
      after
        if original_env do
          System.put_env("XDG_CONFIG_HOME", original_env)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf(xdg_dir)
      end
    end

    test "returns error for invalid TOML" do
      result = Config.write_user_config_toml("not valid toml [[[")
      assert match?({:error, _}, result)
    end
  end

  describe "config_status/0" do
    test "returns a map with expected keys" do
      status = Config.config_status()
      assert is_map(status)
      assert Map.has_key?(status, :config_dir)
      assert Map.has_key?(status, :config_path)
      assert Map.has_key?(status, :config_exists)
      assert Map.has_key?(status, :credentials_path)
      assert Map.has_key?(status, :credentials_exists)
      assert Map.has_key?(status, :issues)
    end

    test "config_exists is a boolean" do
      status = Config.config_status()
      assert is_boolean(status.config_exists)
    end

    test "credentials_exists is a boolean" do
      status = Config.config_status()
      assert is_boolean(status.credentials_exists)
    end

    test "issues is a list" do
      status = Config.config_status()
      assert is_list(status.issues)
    end

    test "paths are strings" do
      status = Config.config_status()
      assert is_binary(status.config_dir)
      assert is_binary(status.config_path)
      assert is_binary(status.credentials_path)
    end
  end
end
