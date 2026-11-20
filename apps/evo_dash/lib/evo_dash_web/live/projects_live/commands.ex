defmodule EvoDashWeb.ProjectsLive.Commands do
  @moduledoc """
  Project-config-defined shell commands for `EvoDashWeb.ProjectsLive`.

  The command REGISTRY itself is parsed by the core
  (`EvoGit.ProjectConfig.commands/1`, surfaced through
  `EvoDashWeb.ProjectsLive.Project.load_project_config/1`); this module only
  owns the lookups plus the OS-branch execution that the page's
  `"run_command"` event delegates to a supervised task.
  """

  @doc """
  Resolves a command name against the page's loaded command map.

  Returns the command string, or nil when the name is unknown (or the loaded
  registry is not a map, e.g. before a genesis.toml was read).
  """
  @spec lookup(map() | nil, String.t()) :: String.t() | nil
  def lookup(commands, name) when is_map(commands), do: Map.get(commands, name)
  def lookup(_commands, _name), do: nil

  @doc """
  Runs one project command synchronously in the CALLER's process.

  This is the OS half of the `"run_command"` event and must run inside the
  supervised task the page spawns (see the event clause): a command can take
  up to 30 s and would otherwise freeze every event, render and heartbeat on
  the tab.

  Same options as before: the project root as cwd, stderr merged into stdout,
  and a 30 s timeout. Returns `{:ok, output, exit_code}`; an exception becomes
  `{:error, message}` so the continuation can render the user-facing error
  instead of crashing.
  """
  @spec run(String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def run(cmd_string, project_root) do
    # Justified try/rescue: System.cmd runs arbitrary project-config-defined shell commands.
    # A failing command should show a user-friendly error, not crash the LiveView.
    try do
      {output, exit_code} =
        case :os.type() do
          {:win32, _} ->
            System.cmd("powershell", ["-Command", cmd_string],
              cd: project_root,
              stderr_to_stdout: true,
              timeout: 30_000
            )

          _ ->
            System.cmd("bash", ["-c", cmd_string],
              cd: project_root,
              stderr_to_stdout: true,
              timeout: 30_000
            )
        end

      {:ok, output, exit_code}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Bounds a command's captured output for the result flash (2 000 bytes plus an
  ellipsis); shorter output is only trimmed.
  """
  @spec truncate_output(String.t()) :: String.t()
  def truncate_output(output) when byte_size(output) > 2000 do
    String.slice(output, 0, 2000) <> "..."
  end

  def truncate_output(output), do: String.trim(output)
end
