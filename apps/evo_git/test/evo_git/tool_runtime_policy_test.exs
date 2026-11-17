defmodule EvoGit.ToolRuntime.PolicyTest do
  use ExUnit.Case, async: true

  alias EvoGit.ToolRuntime.Policy

  test "explicit cheap local and control-plane inventory bypasses tool permits" do
    for name <- ~w(
      read_file create_files write_file edit_file make_dir
      read_context write_context edit_context list_dir glob
      skill_list skill_read skill_add skill_edit skill_remove
      skill_enable skill_disable skill_where
      job_output job_list job_kill elixir_eval
      genesis_check genesis_reload_config genesis_start_task genesis_get_task
      genesis_list_tasks genesis_list_models genesis_get_result
      genesis_send_message genesis_cancel_task genesis_pause_task genesis_resume_task
      genesis_follow_task run_command
    ) do
      refute Policy.limited?(name), "expected #{name} to bypass resource admission"
    end
  end

  test "cheap model-facing aliases normalize before admission" do
    for name <- ~w(read Read READ write Write edit Edit
      bash_output background_output job_status jobs background_jobs
      kill_job job_stop stop_job) do
      refute Policy.limited?(name), "expected alias #{name} to bypass resource admission"
    end
  end

  test "expensive shell, search, network and delegation calls require permits" do
    for name <- ~w(bash Bash shell sh execute_bash bash_command run_shell shell_command
      run_bash run_powershell rg grep ripgrep web_search WebSearch search_web
      web_fetch lsp subagent_manager task subagent genesis_source) do
      assert Policy.limited?(name), "expected #{name} to require resource admission"
    end
  end

  test "unknown custom tools and dynamic skills default to expensive" do
    for name <- [
          "custom_build",
          "skill_deploy",
          "read_custom",
          "job_custom",
          "",
          nil,
          :read_file,
          42,
          %{},
          []
        ] do
      assert Policy.limited?(name), "expected unknown #{inspect(name)} to require admission"
    end
  end
end
