defmodule EvoGit.ToolRuntime.Policy do
  @moduledoc """
  Resource admission policy, independent of serialization and execution backend.

  Only explicitly inventoried cheap local operations and control-plane calls
  bypass the scheduler's tool permits. Unknown tools (including custom tools
  and dynamically named skills) are limited by default. Shell launches acquire
  exactly one permit, regardless of foreground/background arguments.
  """

  alias EvoGit.Agent.ToolNames

  @bypass ~w(
    read_file create_files write_file edit_file make_dir
    read_context write_context edit_context list_dir glob
    job_output job_list job_kill elixir_eval
    genesis_check genesis_reload_config genesis_start_task genesis_get_task
    genesis_list_tasks genesis_list_models genesis_get_result
    genesis_send_message genesis_cancel_task genesis_pause_task genesis_resume_task
    genesis_follow_task run_command
  )

  @doc "Whether this call consumes a scheduler tool permit (unknown names do)."
  @spec limited?(term()) :: boolean()
  def limited?(name), do: ToolNames.normalize(name) not in @bypass
end
