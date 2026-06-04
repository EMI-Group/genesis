defmodule EvoGit.Sandbox.None do
  @moduledoc """
  No-op sandbox backend for Windows and other unsupported platforms.

  All commands run directly without any sandboxing.
  """

  @doc "Always returns false — no sandbox available."
  @spec enabled?() :: false
  def enabled?, do: false

  @doc "No initialization needed."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command directly."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], _repo_root \\ nil) do
    System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
  end
end
