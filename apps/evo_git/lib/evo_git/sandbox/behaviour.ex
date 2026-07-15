defmodule EvoGit.Sandbox.Behaviour do
  @moduledoc """
  Formal behaviour contract for sandbox backends.

  Every platform sandbox backend (`EvoGit.Sandbox.Linux`, `EvoGit.Sandbox.MacOS`,
  `EvoGit.Sandbox.None`) implements this behaviour. The dispatch module
  `EvoGit.Sandbox` routes to the active backend (selected by
  `EvoGit.Platform.sandbox_backend/0`) and calls these callbacks uniformly.

  ## Callbacks

    * `enabled?/0` — whether sandboxing is available on this platform/mode.
    * `ensure_initialized/0` — lazily initialize backend resources (e.g. create
      the systemd slice on Linux). No-op for backends that need no setup.
    * `run/4` — run a command synchronously and return `{output, exit_code}`.
    * `run_with_partial/6` — run a command with a timeout, recovering partial
      output via temp-file redirection. Returns `{:ok, output, exit_code}` or
      `{:timeout, partial_output}`.
  """

  @doc "Returns true when the sandbox backend is enabled for this platform/mode."
  @callback enabled?() :: boolean()

  @doc """
  Ensures the backend is initialized (e.g. creates the systemd slice on Linux).

  No-op for backends that require no setup. Returns `:ok` on success or
  `{:error, reason}` on failure.
  """
  @callback ensure_initialized() :: :ok | {:error, term()}

  @doc """
  Runs a command synchronously through the sandbox backend.

  ## Parameters

    * `cwd` — working directory for the command
    * `executable` — executable to run
    * `args` — list of arguments (default: `[]`)
    * `repo_root` — optional path to the git repository root

  ## Returns

  `{output :: String.t(), exit_code :: non_neg_integer()}`
  """
  @callback run(
              cwd :: String.t(),
              executable :: String.t(),
              args :: [String.t()],
              repo_root :: String.t() | nil
            ) :: {String.t(), non_neg_integer()}

  @doc """
  Runs a command with a timeout, recovering partial output on timeout.

  Unlike `run/4` (which blocks and loses all output on timeout), this redirects
  stdout/stderr to a temp file so partial output can be recovered.

  ## Parameters

    * `cwd` — working directory for the command
    * `executable` — executable to run
    * `args` — list of arguments (default: `[]`)
    * `repo_root` — optional path to the git repository root
    * `timeout` — timeout in milliseconds (positive integer)
    * `max_bytes` — maximum output size in bytes before truncation (`nil` = no
      limit)

  ## Returns

    * `{:ok, output, exit_code}` — command completed within timeout
    * `{:timeout, partial_output}` — command timed out; partial_output may be empty
  """
  @callback run_with_partial(
              cwd :: String.t(),
              executable :: String.t(),
              args :: [String.t()],
              repo_root :: String.t() | nil,
              timeout :: pos_integer(),
              max_bytes :: integer() | nil
            ) :: {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
end
