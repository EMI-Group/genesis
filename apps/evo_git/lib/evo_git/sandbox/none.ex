defmodule EvoGit.Sandbox.None do
  @moduledoc """
  No-op sandbox backend for Windows and other unsupported platforms.

  All commands run directly without any sandboxing. When Nix develop wrapping
  is enabled (via config + available `nix` binary + `flake.nix`), commands
  are wrapped in `nix develop` so that LLM-generated tool calls have access
  to the tools and environment defined in the user's Nix flake.
  """

  alias EvoGit.Nix

  @doc "Always returns false — no sandbox available."
  @spec enabled?() :: false
  def enabled?, do: false

  @doc "No initialization needed."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command directly, optionally wrapped in nix develop when enabled."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], _repo_root \\ nil) do
    {exec, exec_args} =
      if Nix.enabled?() do
        Nix.wrap_command(executable, args)
      else
        {executable, args}
      end

    System.cmd(exec, exec_args, cd: cwd, stderr_to_stdout: true)
  end
end
