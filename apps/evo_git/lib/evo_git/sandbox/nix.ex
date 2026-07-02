defmodule EvoGit.Nix do
  @moduledoc """
  Shared helper for running commands inside a Nix develop environment.

  When enabled via config and the `nix` binary is available and a `flake.nix`
  exists in the config directory, all sandboxed tool calls are wrapped in
  `nix develop <flake-uri> --command <executable> <args...>`.

  This ensures LLM-generated tool calls have access to the tools and
  environment defined in the user's Nix flake (e.g. mix, elixir, erlang,
  ripgrep, etc.).
  """

  alias EvoGit.{Config, Platform}

  @doc """
  Returns true when ALL conditions are met:
  - Nix is enabled in config (`[nix] enabled = true`)
  - The `nix` binary is available on the system
  - A `flake.nix` exists in the config directory

  When any condition is false, commands run normally without nix wrapping.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    nix_enabled_in_config?() and Platform.nix_available?() and flake_exists?()
  end

  @doc """
  Returns the path to the user's `flake.nix` in the config directory.

  e.g. `~/.config/genesis/flake.nix`
  """
  @spec flake_path() :: String.t()
  def flake_path do
    Path.join(Config.config_dir(), "flake.nix")
  end

  @doc """
  Returns the Nix flake URI for `nix develop`.

  Uses the config directory as the flake path, optionally appending a
  flake output attribute if `[nix] flake_output` is configured.

  ## Examples

      # No flake_output configured:
      iex> EvoGit.Nix.flake_uri()
      "~/.config/genesis/#"

      # With flake_output = "devShells.x86_64-linux.default":
      iex> EvoGit.Nix.flake_uri()
      "~/.config/genesis/#devShells.x86_64-linux.default"
  """
  @spec flake_uri() :: String.t()
  def flake_uri do
    dir = Config.config_dir()
    output = nix_config_value(:flake_output)

    if output && output != "" do
      "#{dir}##{output}"
    else
      "#{dir}#"
    end
  end

  @doc """
  Wraps a command in `nix develop <flake-uri> --command <executable> <args...>`.

  Returns `{executable, args}` tuple suitable for `System.cmd/3`.

  ## Parameters

  - `executable` - The original executable (e.g. `"bash"`)
  - `args` - The original args list (e.g. `["-c", "echo hello"]`)

  ## Returns

  A `{"nix", [String.t()]}` tuple where the args list is:
  `["develop", <flake-uri>, "--command", <executable> | <args>]`
  """
  @spec wrap_command(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def wrap_command(executable, args) do
    {"nix", ["develop", flake_uri(), "--command", executable | args]}
  end

  @doc """
  Returns Nix-related environment variables from the parent process.

  This is needed for the Linux/systemd-run backend, which starts with a
  clean environment. Nix needs these variables to locate the Nix store,
  profiles, and SSL certificates.

  Collects all env vars whose key starts with `"NIX"` (e.g. `NIX_PATH`,
  `NIX_PROFILES`, `NIX_SSL_CERT_FILE`, `NIX_REMOTE`) plus `SSL_CERT_FILE`.
  Nil values are filtered out.

  ## Returns

  A list of `{key :: String.t(), value :: String.t()}` tuples.
  """
  @spec nix_env_vars() :: [{String.t(), String.t()}]
  def nix_env_vars do
    System.get_env()
    |> Enum.filter(fn {key, _value} ->
      String.starts_with?(key, "NIX") or key == "SSL_CERT_FILE"
    end)
    |> Enum.map(fn {key, value} -> {key, value} end)
  end

  # --- Private helpers ---

  defp nix_enabled_in_config? do
    case nix_config_value(:enabled) do
      true -> true
      _ -> false
    end
  end

  defp nix_config_value(key) do
    try do
      Config.resolve([:nix, key])
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp flake_exists? do
    File.exists?(flake_path())
  end
end
