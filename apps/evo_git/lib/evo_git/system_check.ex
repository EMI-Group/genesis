defmodule EvoGit.SystemCheck do
  @moduledoc """
  System self-check functions for the Help page in the dashboard.

  Provides safe, structured diagnostic data about configuration, tool availability,
  sandbox capabilities, supervisor health, and LLM connectivity. All public functions
  are wrapped in try/rescue and will never crash the caller.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Checks configuration status by delegating to `EvoGit.Config.config_status/0`.

  Returns `%{missing: [atom()], warnings: [String.t()], ok?: boolean(), validation_errors: [...]}`.
  """
  @spec config_check() :: map()
  def config_check do
    EvoGit.Config.config_status()
  rescue
    e ->
      Logger.warning("SystemCheck config_check failed: #{Exception.message(e)}")

      %{
        missing: [],
        warnings: ["Config check failed: #{Exception.message(e)}"],
        ok?: false,
        validation_errors: []
      }
  end

  @doc """
  Checks availability of required CLI tools (`git` and `rg`/ripgrep).

  Returns `%{git: tool_result, rg: tool_result}` where each `tool_result` is:

      %{
        available: boolean(),
        path: String.t() | nil,
        version: String.t() | nil,
        error: String.t() | nil
      }
  """
  @spec tool_check() :: %{git: map(), rg: map()}
  def tool_check do
    %{git: check_tool("git"), rg: check_tool("rg")}
  rescue
    e ->
      Logger.warning("SystemCheck tool_check failed: #{Exception.message(e)}")

      error_msg = Exception.message(e)

      %{
        git: %{available: false, path: nil, version: nil, error: error_msg},
        rg: %{available: false, path: nil, version: nil, error: error_msg}
      }
  end

  @doc """
  Checks sandbox capabilities by querying platform and sandbox modules.

  Returns:

      %{
        backend: :systemd_run | :sandbox_exec | :none,
        enabled: boolean(),
        capabilities: %{filesystem_isolation: bool, resource_limits: bool, backend: atom},
        systemd_available: boolean(),
        sandbox_exec_available: boolean()
      }
  """
  @spec sandbox_check() :: map()
  def sandbox_check do
    %{
      backend: EvoGit.Platform.sandbox_backend(),
      enabled: EvoGit.Sandbox.enabled?(),
      capabilities: EvoGit.Sandbox.capabilities(),
      systemd_available: EvoGit.Platform.systemd_available?(),
      sandbox_exec_available: EvoGit.Platform.sandbox_exec_available?()
    }
  rescue
    e ->
      Logger.warning("SystemCheck sandbox_check failed: #{Exception.message(e)}")

      %{
        backend: :none,
        enabled: false,
        capabilities: %{filesystem_isolation: false, resource_limits: false, backend: :none},
        systemd_available: false,
        sandbox_exec_available: false,
        error: Exception.message(e)
      }
  end

  @doc """
  Checks the health of both EvoGit and EvoDash supervision trees.

  Returns:

      %{
        evo_git: [%{id: atom, status: :running | :restarting | :undefined | :error, pid: pid | nil}],
        evo_dash: [%{id: atom, status: :running | :restarting | :undefined | :error, pid: pid | nil}],
        healthy: boolean()
      }

  `healthy` is `true` only if all children across both supervisors are `:running`.
  """
  @spec supervisor_check() :: map()
  def supervisor_check do
    evo_git_children = check_supervisor(EvoGit.Supervisor)
    evo_dash_children = check_supervisor(EvoDash.Supervisor)

    all_running =
      Enum.all?(evo_git_children, &(&1.status == :running)) and
        Enum.all?(evo_dash_children, &(&1.status == :running))

    %{
      evo_git: evo_git_children,
      evo_dash: evo_dash_children,
      healthy: all_running
    }
  rescue
    e ->
      Logger.warning("SystemCheck supervisor_check failed: #{Exception.message(e)}")

      %{
        evo_git: [%{id: :evo_git, status: :error, pid: nil}],
        evo_dash: [%{id: :evo_dash, status: :error, pid: nil}],
        healthy: false
      }
  end

  @doc """
  Tests LLM connectivity by sending a minimal request to the configured model.

  Returns `{:ok, %{model: String.t(), response: String.t()}}` on success,
  or `{:error, String.t()}` on failure.
  """
  @spec llm_test() :: {:ok, map()} | {:error, String.t()}
  def llm_test do
    model = EvoGit.Config.resolve([:llm, :model])

    if is_nil(model) or model == "" do
      {:error, "No LLM model configured"}
    else
      do_llm_test(model)
    end
  rescue
    e ->
      Logger.warning("SystemCheck llm_test failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Runs all non-destructive system checks (config, tools, sandbox, supervisor).

  Does **not** run `llm_test/0` since that makes an actual LLM API call.

  Returns `%{config: map(), tools: map(), sandbox: map(), supervisor: map()}`.
  """
  @spec run_all_checks() :: map()
  def run_all_checks do
    %{
      config: config_check(),
      tools: tool_check(),
      sandbox: sandbox_check(),
      supervisor: supervisor_check()
    }
  rescue
    e ->
      Logger.warning("SystemCheck run_all_checks failed: #{Exception.message(e)}")
      %{error: Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_tool(name) do
    resolved = EvoGit.Executable.resolve(name)

    case System.cmd(resolved, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        %{
          available: true,
          path: resolved,
          version: String.trim(output),
          error: nil
        }

      {output, _exit_code} ->
        %{
          available: false,
          path: resolved,
          version: nil,
          error: String.trim(output)
        }
    end
  rescue
    e ->
      %{available: false, path: nil, version: nil, error: Exception.message(e)}
  end

  defp check_supervisor(supervisor_name) do
    case Process.whereis(supervisor_name) do
      nil ->
        [%{id: supervisor_name, status: :undefined, pid: nil}]

      _pid ->
        supervisor_name
        |> Supervisor.which_children()
        |> Enum.map(fn {id, child_pid, _type, _modules} ->
          {status, pid} = classify_pid(child_pid)
          %{id: id, status: status, pid: pid}
        end)
    end
  rescue
    e ->
      Logger.warning("SystemCheck check_supervisor(#{inspect(supervisor_name)}) failed: #{Exception.message(e)}")
      [%{id: supervisor_name, status: :error, pid: nil}]
  end

  defp classify_pid(:restarting), do: {:restarting, nil}
  defp classify_pid(:undefined), do: {:undefined, nil}
  defp classify_pid(pid) when is_pid(pid), do: {:running, pid}
  defp classify_pid(_other), do: {:error, nil}

  defp do_llm_test(model) do
    # Ensure API keys from credentials.toml are loaded into env vars before
    # the test request. This is a defensive measure so the test connection
    # is self-sufficient (doesn't rely on AgentScheduler.init having
    # previously loaded credentials).
    EvoGit.Config.credentials()

    context = ReqLLM.Context.new([ReqLLM.Context.user("Say hello in one word.")])

    with {:ok, stream_response} <- ReqLLM.stream_text(model, context, max_tokens: 10),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response) do
      text = ReqLLM.Response.text(response) || ""
      {:ok, %{model: model, response: text}}
    else
      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)
end
