defmodule EvoGit.SystemCheck do
  @moduledoc """
  System self-check functions for the Help page in the dashboard.

  Provides safe, structured diagnostic data about configuration, tool availability,
  sandbox capabilities, supervisor health, and LLM connectivity. All public functions
  are wrapped in try/rescue so they never crash the LiveView caller process.
  `run_all_checks/0` delegates to individually-protected functions and does not
  have its own rescue — each called function is already crash-safe.
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
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
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
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
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
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
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
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
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
    llm_test(model)
  end

  @doc """
  Tests LLM connectivity for a specific model string.

  Returns `{:ok, %{model: String.t(), response: String.t()}}` on success,
  or `{:error, String.t()}` on failure.
  """
  @spec llm_test(String.t() | map()) :: {:ok, map()} | {:error, String.t()}
  def llm_test(model) when is_binary(model) or is_map(model) do
    if model == "" or model == %{} do
      {:error, "No LLM model configured"}
    else
      do_llm_test(model)
    end
  rescue
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
    e ->
      Logger.warning("SystemCheck llm_test/1 failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Tests LLM connectivity for a specific model string with extra generation params
  (e.g., `max_tokens`, `temperature`).

  Returns `{:ok, %{model: String.t(), response: String.t()}}` on success,
  or `{:error, String.t()}` on failure.
  """
  @spec llm_test(String.t() | map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def llm_test(model, opts) when (is_binary(model) or is_map(model)) and is_list(opts) do
    if model == "" or model == %{} do
      {:error, "No LLM model configured"}
    else
      do_llm_test(model, opts)
    end
  rescue
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
    e ->
      Logger.warning("SystemCheck llm_test/2 failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Checks Nix dev-environment integration.

  When nix is enabled (config + binary + flake), validates that the flake
  actually evaluates by running `Nix.ensure_dev_env/0`, which uses the
  SHA-256-keyed cache so repeated checks don't re-evaluate the flake.

  Returns:

      %{
        available: boolean(),
        enabled: boolean(),
        flake_present: boolean(),
        dev_env_built: boolean(),
        error: String.t() | nil
      }

  When nix is not enabled, all boolean fields are `false` and `error` is `nil`.
  """
  @spec nix_check() :: map()
  def nix_check do
    available = EvoGit.Platform.nix_available?()
    enabled = EvoGit.Nix.enabled?()
    flake_present = File.exists?(EvoGit.Nix.flake_path())

    if enabled and flake_present do
      case EvoGit.Nix.ensure_dev_env() do
        {:ok, _path} ->
          %{
            available: available,
            enabled: enabled,
            flake_present: flake_present,
            dev_env_built: true,
            error: nil
          }

        {:error, reason} ->
          %{
            available: available,
            enabled: enabled,
            flake_present: flake_present,
            dev_env_built: false,
            error: reason
          }
      end
    else
      %{
        available: available,
        enabled: enabled,
        flake_present: flake_present,
        dev_env_built: false,
        error: nil
      }
    end
  rescue
    # Justified: diagnostics for the dashboard UI — must never crash the LiveView caller process.
    e ->
      Logger.warning("SystemCheck nix_check failed: #{Exception.message(e)}")

      %{
        available: false,
        enabled: false,
        flake_present: false,
        dev_env_built: false,
        error: Exception.message(e)
      }
  end

  @doc """
  Runs all non-destructive system checks (config, tools, sandbox, supervisor, nix).

  Does **not** run `llm_test/0` since that makes an actual LLM API call.

  Returns `%{config: map(), tools: map(), sandbox: map(), supervisor: map(), nix: map()}`.
  """
  @spec run_all_checks() :: map()
  # No try/rescue needed here: each called function (config_check/0, tool_check/0,
  # sandbox_check/0, supervisor_check/0, nix_check/0) is individually crash-safe
  # with its own rescue at the centralized exception boundary. A second layer
  # would only mask bugs in the rescue blocks themselves.
  def run_all_checks do
    %{
      config: config_check(),
      tools: tool_check(),
      sandbox: sandbox_check(),
      supervisor: supervisor_check(),
      nix: nix_check()
    }
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
  end

  defp classify_pid(:restarting), do: {:restarting, nil}
  defp classify_pid(:undefined), do: {:undefined, nil}
  defp classify_pid(pid) when is_pid(pid), do: {:running, pid}
  defp classify_pid(_other), do: {:error, nil}

  defp do_llm_test(model, opts \\ []) do
    # Ensure API keys from credentials.toml are loaded into env vars before
    # the test request. This is a defensive measure so the test connection
    # is self-sufficient (doesn't rely on AgentScheduler.init having
    # previously loaded credentials).
    EvoGit.Config.credentials()

    context = ReqLLM.Context.new([ReqLLM.Context.user("Say hello in one word.")])
    stream_opts = Keyword.merge([max_tokens: 10], opts)

    with {:ok, stream_response} <- ReqLLM.stream_text(model, context, stream_opts),
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
