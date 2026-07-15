defmodule EvoDashWeb.SystemLive.Status do
  @moduledoc """
  Status-checking helpers for the SystemLive page.

  Pure functions that derive overall status (`:ok` / `:error` / `:info` /
  `:warning`) from the system-check result maps, and format backend names and
  config item labels for display. These have no LiveView state.
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
end
