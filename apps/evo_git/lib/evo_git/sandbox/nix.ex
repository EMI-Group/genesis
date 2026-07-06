defmodule EvoGit.Nix do
  @moduledoc """
  Shared helper for running commands inside a Nix development environment.

  Instead of re-evaluating the flake on every tool call (which `nix develop`
  would do), this module builds the dev environment **once** via
  `nix print-dev-env`, caches the resulting bash script to
  `<data_dir>/nix-dev-env.sh`, and then sources it per call via
  `bash -c "source <path>; exec <cmd>"`. This avoids the expensive per-call
  flake evaluation.

  The cache is keyed on the SHA-256 hash of `flake.nix`: when the flake
  content changes, the dev env is rebuilt automatically.

  ## Gating

  - `enabled?/0` — *static capability*: nix is enabled in config, the `nix`
    binary is available, and a `flake.nix` exists in the config directory.
  - `active?/0` — *runtime gate*: `enabled?/0` AND the dev-env build has not
    previously failed. Backends consult `active?/0` when deciding whether to
    wrap commands. On the first call (state `:not_attempted`) the build is
    triggered lazily. Once a build fails, nix is gracefully disabled for the
    rest of the session.
  """

  alias EvoGit.{Config, Platform}

  @persistent_term_key :evogit_nix_dev_env_state

  @doc """
  Returns true when ALL conditions are met (static capability check):
  - Nix is enabled in config (`[nix] enabled = true`)
  - The `nix` binary is available on the system
  - A `flake.nix` exists in the config directory

  This does NOT consider whether the dev-env build has succeeded — see
  `active?/0` for the runtime gate used by backends.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:evo_git, :nix_enabled) do
      nil -> nix_enabled_in_config?() and Platform.nix_available?() and flake_exists?()
      override -> override
    end
  end

  @doc """
  Returns true when nix wrapping should be used for the current call.

  This is `enabled?/0` AND the dev-env build has not previously failed.
  On the first call (state `:not_attempted`), this returns true if enabled,
  allowing a lazy build. Once a build fails, this returns false for the
  rest of the session (graceful disable).
  """
  @spec active?() :: boolean()
  def active? do
    case dev_env_state() do
      {:failed, _} -> false
      _ -> enabled?()
    end
  end

  @doc """
  Returns the current dev-env build state.

  - `:not_attempted` — no build has been attempted yet (default).
  - `{:built, path}` — the dev env was successfully built and cached at `path`.
  - `{:failed, reason}` — the last build attempt failed with `reason`.

  Primarily useful for testing and diagnostics.
  """
  @spec dev_env_state() :: {:built, String.t()} | {:failed, String.t()} | :not_attempted
  def dev_env_state do
    # :persistent_term.get/2 never raises — it returns the default if the key
    # is absent. No try/rescue needed.
    :persistent_term.get(@persistent_term_key, :not_attempted)
  end

  @doc """
  Resets the dev-env build state (for testing).

  Clears the persistent_term entry so that the next call starts fresh.
  """
  @spec reset_state() :: :ok
  def reset_state do
    # :persistent_term.erase/1 raises ArgumentError if the key doesn't exist.
    # Guard with get/2 first so the operation is idempotent without try/rescue.
    case :persistent_term.get(@persistent_term_key, :not_attempted) do
      :not_attempted -> :ok
      _ -> :persistent_term.erase(@persistent_term_key)
    end

    :ok
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
  Returns the Nix flake URI for `nix print-dev-env`.

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
  Builds (or rebuilds) the dev environment via `nix print-dev-env`.

  Runs `nix print-dev-env <flake-uri>`, writes the resulting bash script to
  the cache file (`<data_dir>/nix-dev-env.sh`), stores the flake hash, and
  updates the global build state. Returns `{:ok, path}` on success or
  `{:error, reason}` on failure. Never raises — all exceptions are caught
  and converted to `{:error, reason}`.
  """
  @spec build_dev_env() :: {:ok, String.t()} | {:error, String.t()}
  def build_dev_env do
    do_build_dev_env()
  rescue
    # JUSTIFIED rescue: System.cmd("nix", ...) raises ErlangError (not
    # {:error, _}) when the nix binary is missing from PATH. System.cmd
    # has no non-raising variant for "binary not found". Although
    # enabled?/0 pre-checks with System.find_executable("nix"), there is
    # a TOCTOU race between the check and the call. Converting this raise
    # to {:error, reason} satisfies this function's @spec contract (it
    # must never raise), provides a clean error that callers can inspect,
    # and gracefully disables nix for the rest of the session.
    #
    # All I/O errors (File.mkdir_p, File.write) are handled explicitly in
    # do_build_dev_env/0 via non-bang variants and a with chain.
    e ->
      reason = "nix print-dev-env failed: #{Exception.message(e)}"
      put_state({:failed, reason})
      {:error, reason}
  end

  @doc """
  Ensures the dev environment is built and cached.

  If the cache exists and the flake hash is unchanged, returns the cached
  path immediately (no rebuild). Otherwise, rebuilds via `build_dev_env/0`.
  """
  @spec ensure_dev_env() :: {:ok, String.t()} | {:error, String.t()}
  def ensure_dev_env do
    if cache_valid?() do
      {:ok, cache_path()}
    else
      build_dev_env()
    end
  end

  @doc """
  Wraps a command so it runs inside the cached Nix dev environment.

  Produces `{"bash", ["-c", "source <path>; exec <escaped-exec> <escaped-args>"]}`.
  The dev-env script is sourced first (setting up PATH and env), then the
  executable runs via `exec`.

  If the dev-env build has already succeeded (`{:built, path}`), the cached
  path is used directly. If not yet attempted, a lazy build is triggered.
  If the build fails, the command falls back to running directly (no nix
  sourcing) without crashing.

  ## Parameters

  - `executable` - The original executable (e.g. `"bash"`)
  - `args` - The original args list (e.g. `["-c", "echo hello"]`)

  ## Returns

  A `{String.t(), [String.t()]}` tuple suitable for `System.cmd/3`.
  """
  @spec wrap_command(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def wrap_command(executable, args) do
    case dev_env_state() do
      {:built, path} ->
        build_bash_command(path, executable, args)

      {:failed, _reason} ->
        # Build previously failed; run directly without nix
        {executable, args}

      :not_attempted ->
        # Lazy build on first call
        case ensure_dev_env() do
          {:ok, path} -> build_bash_command(path, executable, args)
          {:error, _reason} -> {executable, args}
        end
    end
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

  # --- Private: dev-env cache management ---

  defp do_build_dev_env do
    uri = flake_uri()

    {output, exit_code} = System.cmd("nix", ["print-dev-env", uri], stderr_to_stdout: true)

    if exit_code == 0 do
      path = cache_path()

      with :ok <- File.mkdir_p(Platform.data_dir()),
           :ok <- File.write(path, output),
           :ok <- write_flake_hash() do
        put_state({:built, path})
        {:ok, path}
      else
        {:error, reason} ->
          put_state({:failed, "I/O error: #{inspect(reason)}"})
          {:error, "I/O error: #{inspect(reason)}"}
      end
    else
      reason = "nix print-dev-env failed (exit #{exit_code}): #{String.trim(output)}"
      put_state({:failed, reason})
      {:error, reason}
    end
  end

  defp cache_path, do: Path.join(Platform.data_dir(), "nix-dev-env.sh")

  defp hash_path, do: Path.join(Platform.data_dir(), "nix-dev-env.hash")

  defp cache_valid? do
    with true <- File.exists?(cache_path()),
         {:ok, current_hash} <- flake_hash(),
         {:ok, stored_hash} <- File.read(hash_path()) do
      String.trim(stored_hash) == current_hash
    else
      _ -> false
    end
  end

  defp flake_hash do
    case File.read(flake_path()) do
      {:ok, content} ->
        {:ok, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}

      {:error, _reason} ->
        {:error, "could not read flake.nix"}
    end
  end

  defp write_flake_hash do
    case flake_hash() do
      {:ok, hash} -> File.write(hash_path(), hash)
      {:error, _} = error -> error
    end
  end

  # --- Private: bash command building & shell escaping ---

  defp build_bash_command(dev_env_path, executable, args) do
    escaped_exec = shell_escape(executable)
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    cmd = "source #{shell_escape(dev_env_path)}; exec #{escaped_exec} #{escaped_args}"
    {"bash", ["-c", cmd]}
  end

  # POSIX-safe shell escaping: wrap each argument in single quotes and
  # replace every literal single-quote with the sequence '\''.
  # e.g. `it's a test` → `'it'\''s a test'`
  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # --- Private: config helpers ---

  defp put_state(state) do
    :persistent_term.put(@persistent_term_key, state)
  end

  defp nix_enabled_in_config? do
    case nix_config_value(:enabled) do
      true -> true
      _ -> false
    end
  end

  defp nix_config_value(key) do
    # Config.resolve never raises — it returns nil for missing config paths.
    Config.resolve([:nix, key])
  end

  defp flake_exists? do
    File.exists?(flake_path())
  end
end
