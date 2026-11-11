defmodule EvoGit.TaskControlConfigurationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias EvoGit.{Config, TaskControl}
  alias EvoGit.AgentScheduler.RemoteAPI

  setup do
    EvoGit.TestSupport.ConfigDir.isolate!("mcp_configuration")
    File.mkdir_p!(Config.config_dir())
    scheduler = :sys.get_state(EvoGit.AgentScheduler)
    key = Application.get_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      :sys.replace_state(EvoGit.AgentScheduler, fn _ -> scheduler end)

      if key,
        do: Application.put_env(:req_llm, :openai_api_key, key),
        else: Application.delete_env(:req_llm, :openai_api_key)
    end)

    :ok
  end

  test "check reports actual server paths without credential contents" do
    File.write!(Config.credentials_path(), ~s(OPENAI_API_KEY = "private-fixture-key"))
    assert {:ok, check} = TaskControl.check(%{})

    assert check.config_files == %{
             config: Config.config_path(),
             credentials: Config.credentials_path()
           }

    refute check.provider_connection_tested
    refute Jason.encode!(check) =~ "private-fixture-key"
  end

  test "reload applies file edits to the live scheduler without a browser or provider request" do
    write_model("before")
    assert :ok = RemoteAPI.reload_config()
    assert [%{model: "openai:before"}] = RemoteAPI.get_config().model_profiles

    # Same-second, same-size edits must bypass the ordinary stat cache.
    stat = File.stat!(Config.config_path())
    write_model("after_")
    File.touch!(Config.config_path(), stat.mtime)
    File.write!(Config.credentials_path(), ~s(OPENAI_API_KEY = "private-fixture-key"))

    assert {:ok, result} = TaskControl.reload_config(%{})
    assert result.configuration_reloaded
    assert result.model_ready
    refute result.provider_connection_tested
    assert [%{model: "openai:after_"}] = RemoteAPI.get_config().model_profiles
    assert ReqLLM.get_key(:openai_api_key) == "private-fixture-key"
    refute Jason.encode!(result) =~ "private-fixture-key"
  end

  test "malformed configuration or credentials leave the live model unchanged without echoing secrets" do
    write_model("before")
    assert :ok = RemoteAPI.reload_config()

    for path <- [Config.config_path(), Config.credentials_path()] do
      write_model("after_")
      File.write!(path, ~s(OPENAI_API_KEY = "private-fixture-key))

      assert {:error, %{code: "configuration_not_applied", message: message}} =
               TaskControl.reload_config(%{})

      assert message =~ path
      refute message =~ "private-fixture-key"
      assert [%{model: "openai:before"}] = RemoteAPI.get_config().model_profiles
      File.rm!(path)
    end
  end

  test "schema errors do not replace the running configuration" do
    write_model("before")
    assert :ok = RemoteAPI.reload_config()
    File.write!(Config.config_path(), "[scheduler]\nmax_turns = -1\n")
    assert {:error, %{code: "configuration_not_applied"}} = TaskControl.reload_config(%{})
    assert [%{model: "openai:before"}] = RemoteAPI.get_config().model_profiles
    assert {:ok, %{model_ready: false}} = TaskControl.check(%{})
  end

  test "reload rejects invalid table and profile shapes before tolerant normalization" do
    write_model("before")
    assert :ok = RemoteAPI.reload_config()

    for invalid <- [
          ~s(scheduler = "oops"),
          ~s([llm]\nmodels = ["oops"]),
          ~s([llm]\nmodels = "oops")
        ] do
      File.write!(Config.config_path(), invalid)
      assert {:error, %{code: "configuration_not_applied"}} = TaskControl.reload_config(%{})
      assert [%{model: "openai:before"}] = RemoteAPI.get_config().model_profiles
    end
  end

  test "reload errors never log invalid configuration values" do
    File.write!(Config.config_path(), ~s([scheduler]\nmax_turns = "private-review-fixture"))

    log =
      capture_log(fn ->
        assert {:error, %{code: "configuration_not_applied"}} = TaskControl.reload_config(%{})
      end)

    refute log =~ "private-review-fixture"
  end

  test "reload accepts no configuration or credential arguments" do
    assert {:error, %{code: "invalid_arguments"}} =
             TaskControl.reload_config(%{"api_key" => "private-fixture-key"})
  end

  test "existing save API reports when a saved file could not be applied" do
    write_model("before")
    assert :ok = RemoteAPI.reload_config()
    File.write!(Config.credentials_path(), "invalid = [")

    assert {:error, message} = RemoteAPI.save_user_config(%{scheduler: %{max_turns: 42}})
    assert message =~ "saved"
    assert message =~ Config.credentials_path()
    assert Config.user_config()["scheduler"]["max_turns"] == 42
    assert [%{model: "openai:before"}] = RemoteAPI.get_config().model_profiles
  end

  defp write_model(model) do
    File.write!(
      Config.config_path(),
      "[[llm.models]]\nid = \"default\"\nmodel = \"openai:#{model}\"\n"
    )
  end
end
