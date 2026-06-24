defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  Provides filesystem isolation only — no resource limits or syscall filtering.
  Uses Apple's Sandbox Policy Language (SBPL) to restrict filesystem access,
  allowing read-write on project directories and build caches while blocking
  sensitive directories like ~/.ssh, ~/.gnupg, etc.
  """

  alias EvoGit.Platform

  @doc "Returns true when sandbox mode allows sandbox-exec on macOS."
  @spec enabled?() :: boolean()
  def enabled? do
    case EvoGit.Defaults.sandbox() || :auto do
      :enabled -> true
      :disabled -> false
      :auto -> Platform.sandbox_exec_available?()
    end
  end

  @doc "No initialization needed for sandbox-exec."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command via sandbox-exec with a generated SBPL profile."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) do
    if enabled?() do
      profile = generate_profile(cwd, repo_root)

      # sandbox-exec -p <profile> -- <executable> <args...>
      System.cmd("sandbox-exec", ["-p", profile, "--", executable | args],
        cd: cwd,
        stderr_to_stdout: true
      )
    else
      System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  # Generate an SBPL (Sandbox Policy Language) profile.
  # Strategy: deny default, then allow specific paths.
  # - Allow read-write on: cwd, tmp dirs, build caches, repo_root/.git
  # - Deny write on: sensitive dirs (.ssh, .gnupg, .aws, etc.)
  # - Allow read on: everything (so tools can read system headers, libraries, etc.)
  # - Allow process execution (subprocess exec)
  @doc false
  def generate_profile(cwd, repo_root \\ nil) do
    home = System.user_home!()

    # Sensitive directories to explicitly deny write access
    sensitive_dirs = [
      ".ssh",
      ".gnupg",
      ".aws",
      ".kube",
      ".config/sops",
      ".npmrc",
      ".git-credentials",
      ".netrc"
    ]

    sensitive_rules =
      Enum.map(sensitive_dirs, fn dir ->
        path = Path.join(home, dir)
        ~s{(deny file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    # Build cache dirs to allow read-write
    build_cache_dirs = [
      ".cache",
      ".local/share",
      ".local/state",
      ".cargo",
      ".rustup",
      ".mix",
      ".hex",
      ".npm",
      ".yarn",
      ".bun",
      ".m2",
      ".gradle",
      "go"
    ]

    cache_rw_rules =
      Enum.map(build_cache_dirs, fn dir ->
        path = Path.join(home, dir)
        ~s{(allow file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    # Tmp paths
    tmp_paths = Platform.tmp_paths()

    tmp_rules =
      tmp_paths
      |> Enum.map(fn path ->
        ~s{(allow file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    # The host $TMPDIR may point outside Platform.tmp_paths/0 (e.g. macOS
    # /var/folders/...). Since the parent env is inherited verbatim, grant write
    # access to the resolved TMPDIR when it is not already covered by the
    # tmp_rules above, so LLM-generated temp-file writes don't get denied.
    resolved_tmpdir = EvoGit.Sandbox.resolve_tmpdir()

    extra_tmp_rule =
      if tmpdir_covered?(resolved_tmpdir, tmp_paths) do
        ""
      else
        ~s{(allow file-write* (subpath "#{resolved_tmpdir}"))}
      end

    # Repo .git access
    git_rule =
      if repo_root do
        git_path = Path.join(repo_root, ".git")
        ~s{(allow file-write* (subpath "#{git_path}"))}
      else
        ""
      end

    """
    (version 1)
    (deny default)
    (allow file-read*)
    (allow file-write* (subpath "#{cwd}"))
    #{tmp_rules}
    #{extra_tmp_rule}
    #{cache_rw_rules}
    #{git_rule}
    (allow process-exec)
    (allow process-fork)
    (allow network*)
    (allow mach-lookup)
    (allow signal)
    (allow ipc-posix-sem)
    (allow ipc-posix-shm)
    (allow file-write-data (literal "/dev/null"))
    (allow file-write-data (literal "/dev/dtracehelper"))
    #{sensitive_rules}
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # Returns true when `path` is equal to, or a subdirectory of, one of `prefixes`.
  # Uses `prefix <> "/"` so that `/tmpfoo` does NOT match the `/tmp` prefix.
  defp tmpdir_covered?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end
end
