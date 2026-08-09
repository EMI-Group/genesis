defmodule EvoDashWeb.SystemLive.Status do
  @moduledoc """
  Status-checking helpers for the SystemLive page.

  Pure functions that derive overall status (`:ok` / `:error` / `:info` /
  `:warning` / `:loading`) from the system-check result maps, plus backend
  name and config item label formatting. These have no LiveView state.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  @doc """
  Nil-safe config check (assigns are nil during loading).
  """
  def config_ok?(nil), do: false
  def config_ok?(%{ok?: ok?}), do: ok?

  @doc """
  Determines the overall tools status from the tool-check map.
  """
  def tools_status(%{git: %{available: true}, rg: %{available: true}}), do: :ok
  def tools_status(%{git: %{available: false}}), do: :error
  def tools_status(%{rg: %{available: false}}), do: :error
  def tools_status(_), do: :warning

  @doc """
  Nil-safe supervisor health check.
  """
  def supervisor_healthy?(nil), do: false
  def supervisor_healthy?(%{healthy: healthy}), do: healthy

  @doc """
  Determines the nix environment overall status.
  Green/OK when enabled & flake valid; warning when enabled but flake invalid;
  neutral/info when nix is not available or not enabled.
  """
  def nix_status(%{enabled: true, dev_env_built: true}), do: :ok
  def nix_status(%{enabled: true}), do: :warning
  def nix_status(%{available: true}), do: :info
  def nix_status(_), do: :info

  @doc """
  Determines the sandbox overall status from the sandbox-check map.
  """
  def sandbox_status(%{backend: :systemd_run} = check) do
    if check.systemd_available && check.capabilities.filesystem_isolation &&
         check.capabilities.resource_limits do
      :ok
    else
      :error
    end
  end

  def sandbox_status(%{backend: :sandbox_exec} = check) do
    if check.sandbox_exec_available && check.capabilities.filesystem_isolation do
      :ok
    else
      :error
    end
  end

  def sandbox_status(%{backend: :none}), do: :info
  def sandbox_status(_), do: :error

  @doc """
  Formats the sandbox backend name for display.
  """
  def format_backend(:systemd_run), do: "systemd-run (Linux)"
  def format_backend(:sandbox_exec), do: "sandbox-exec (macOS)"
  def format_backend(:none), do: gettext("None")

  @doc """
  Formats a config item name for display.
  """
  def format_config_item(:llm_model), do: gettext("LLM Model")
  def format_config_item(:api_key), do: gettext("API Key")
  def format_config_item(:github_username), do: gettext("GitHub Username")

  def format_config_item(item) do
    item |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Merged overall system-health derivation for the self-check health banner.

  Takes the individual check maps plus `sandbox_shown` / `nix_shown` flags
  (a check only counts when its grid cell is actually rendered) and returns
  `%{status: :ok | :warning | :error | :loading, reasons: [String.t()]}`.

  - `:loading` while the checks are still running (any of the always-critical
    assigns — supervisor, config, tools — is nil). Never reported as an error.
  - `:ok` when every critical check passes and there are no warnings.
  - `:warning` when only non-critical issues exist (e.g. the nix dev
    environment is enabled but not built).
  - `:error` when any critical check fails: process tree, configuration,
    required tools, or sandbox (when its cell is shown).

  The returned `reasons` are human-readable, gettext-wrapped explanations of
  exactly what is wrong, used by the banner to tell the user what to fix.
  """
  def overall_health(checks) do
    cond do
      checks.supervisor == nil or checks.config == nil or checks.tools == nil ->
        %{status: :loading, reasons: []}

      true ->
        hard = hard_failures(checks)
        warnings = warnings(checks)

        cond do
          hard != [] -> %{status: :error, reasons: hard}
          warnings != [] -> %{status: :warning, reasons: warnings}
          true -> %{status: :ok, reasons: []}
        end
    end
  end

  # Critical failures — make the health light non-green.
  defp hard_failures(checks) do
    []
    |> maybe_push(
      not supervisor_healthy?(checks.supervisor),
      gettext("System processes are not running correctly")
    )
    |> maybe_push(
      not config_ok?(checks.config),
      gettext("Required settings are missing or invalid")
    )
    |> maybe_push(
      tools_status(checks.tools) != :ok,
      gettext("A required tool (git or ripgrep) is missing")
    )
    |> maybe_push(
      checks.sandbox_shown and sandbox_status(checks.sandbox) != :ok,
      gettext("Sandbox is unavailable")
    )
  end

  # Non-critical warnings — flagged in the banner but do not hard-fail the
  # health light (the nix dev environment is optional).
  defp warnings(checks) do
    []
    |> maybe_push(
      checks.nix_shown and nix_status(checks.nix) != :ok,
      gettext("Nix environment is enabled but not built")
    )
  end

  defp maybe_push(list, true, reason), do: [reason | list]
  defp maybe_push(list, _false, _reason), do: list
end
