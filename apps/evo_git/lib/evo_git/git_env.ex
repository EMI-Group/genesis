defmodule EvoGit.GitEnv do
  @moduledoc """
  Shared git environment helpers — single source of truth for the `GIT_EDITOR`,
  `LC_ALL`, and commit-identity env vars injected into every git invocation.

  Both git execution paths in the codebase delegate to this module:

    * the internal adapter (`EvoGit.Adapters.Git`), and
    * the agent sandbox tool path (`EvoGit.sandbox_run/4` → `EvoGit.Sandbox.*`
      backends).

  Setting `GIT_EDITOR` to the `true` executable ensures automated git operations
  that may open an interactive editor (e.g. `git merge --continue`, rebase, am,
  commit) never block waiting on user input. `LC_ALL=C` forces locale-independent
  (English) output so git output can be parsed reliably.

  ## Commit identity resolution

  The four identity env vars (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL`) are resolved per key with the
  following priority:

    1. A value already present in the INHERITED environment (`System.get_env/1`)
       — never clobbered.
    2. The repository's effective configured identity (`git config user.name` /
       `git config user.email`, no scope flag → repo → global → system, exactly
       what git itself would use).
    3. The fallback placeholder (`"Genesis"` / `"noreply@evogit.ai"`) so
       automated commits never fail when no identity is configured anywhere.

  Each key is resolved independently, so e.g. a `GIT_COMMITTER_NAME` env var is
  honored while the email still comes from git config.

  The `git config` lookup runs in the PARENT process via raw `System.cmd` (config
  reads don't commit, so there is no recursion through `EvoGit.Adapters.Git`,
  which injects this same env map). It is memoized per repo path in
  `:persistent_term` (and once for the no-repo/global case): two process spawns
  per unique path on first use, then served from the cache. A user changing their
  git config mid-run may observe the stale identity until the VM restarts —
  accepted trade-off for avoiding two extra process spawns per git invocation.
  """

  # :persistent_term key caching the resolved path to the `true` executable.
  # Resolving it scans PATH, so we memoize once for the VM's lifetime.
  @true_path_key {__MODULE__, :true_path}

  # Fallback identity used ONLY when neither the inherited environment nor git
  # config provides a value. Kept so automated commits never fail with
  # "Please tell me who you are".
  @fallback_name "Genesis"
  @fallback_email "noreply@evogit.ai"

  @doc """
  Returns the environment map shared by every git invocation.

  Always sets:

    * `LC_ALL` => `C` — locale-independent (English) output for reliable parsing.
    * `GIT_EDITOR` => resolved `true` path — a no-op editor so automated
      operations that may open an interactive editor (e.g. `merge --continue`,
      rebase, am, commit) never block.
    * `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/
      `GIT_COMMITTER_EMAIL` — the effective commit identity (see moduledoc for
      the resolution priority).
  """
  @spec git_env() :: %{String.t() => String.t()}
  def git_env, do: git_env(nil)

  @doc """
  Like `git_env/0`, but resolves the commit identity from `repo_path`'s
  repository (repo-local → global → system `git config`). Pass `nil` for the
  global-only resolution.
  """
  @spec git_env(String.t() | nil) :: %{String.t() => String.t()}
  def git_env(repo_path) when is_binary(repo_path) or is_nil(repo_path) do
    identity = resolve_identity(repo_path)

    %{
      "LC_ALL" => "C",
      "GIT_EDITOR" => resolve_true_executable(),
      "GIT_AUTHOR_NAME" => identity.author_name,
      "GIT_AUTHOR_EMAIL" => identity.author_email,
      "GIT_COMMITTER_NAME" => identity.committer_name,
      "GIT_COMMITTER_EMAIL" => identity.committer_email
    }
  end

  @doc """
  Returns `git_env/1` as a list of `{String.t(), String.t()}` tuples.

  Convenient for `System.cmd`'s `:env` option (which accepts a list of
  `{string, string}` tuples and MERGES them into the inherited environment)
  and for building systemd-run `--setenv=KEY=VALUE` args. Note that
  `systemd-run --user` does NOT inherit the caller's full environment, so the
  resolved identity is explicitly re-exported here for sandboxed processes.
  """
  @spec git_env_list() :: [{String.t(), String.t()}]
  def git_env_list, do: git_env_list(nil)

  @doc "Like `git_env_list/0`, but resolves the identity from `repo_path`."
  @spec git_env_list(String.t() | nil) :: [{String.t(), String.t()}]
  def git_env_list(repo_path), do: Map.to_list(git_env(repo_path))

  # Test helper: clears the memoized `git config` identity for `repo_path`
  # (or the global resolution when `repo_path` is `nil`). The runtime
  # intentionally accepts a stale identity after the first resolution per repo.
  @doc false
  @spec clear_config_identity_cache(String.t() | nil) :: :ok
  def clear_config_identity_cache(repo_path \\ nil) do
    :persistent_term.erase({__MODULE__, :config_identity, repo_path})
    :ok
  end

  @doc """
  Returns true when the given executable is a git command.

  The executable may be a bare name (`"git"`) or an absolute/relative path
  (e.g. `"/usr/bin/git"` or a bundled `".../vendor/.../git.exe"`). The basename
  is checked against `["git", "git.exe"]`.

  Detect git on the ORIGINAL executable parameter (the value passed to the
  sandbox `run/4`/`args/4` functions), NOT on a nix-wrapped executable — the
  nix wrapper produces `{"bash", ["-c", ...]}` whose basename is `"bash"`.
  """
  @spec git_command?(String.t()) :: boolean()
  def git_command?(executable) when is_binary(executable) do
    Path.basename(executable) in ["git", "git.exe"]
  end

  @doc """
  Resolves the `true` executable path, memoized via :persistent_term.

  `System.find_executable/1` does NOT raise (returns `nil`), so no try/rescue.
  """
  @spec resolve_true_executable() :: String.t()
  def resolve_true_executable do
    case :persistent_term.get(@true_path_key, nil) do
      nil ->
        path = do_resolve_true_executable()
        :persistent_term.put(@true_path_key, path)
        path

      path ->
        path
    end
  end

  # ── Commit identity resolution ────────────────────────────────────────────

  # Resolves the four identity values with per-key priority:
  # inherited env → repo/global git config (memoized) → fallback.
  defp resolve_identity(repo_path) do
    {config_name, config_email} = memoized_config_identity(repo_path)

    %{
      author_name: resolve_key("GIT_AUTHOR_NAME", config_name, @fallback_name),
      author_email: resolve_key("GIT_AUTHOR_EMAIL", config_email, @fallback_email),
      committer_name: resolve_key("GIT_COMMITTER_NAME", config_name, @fallback_name),
      committer_email: resolve_key("GIT_COMMITTER_EMAIL", config_email, @fallback_email)
    }
  end

  # Inherited env wins; an empty-string value is treated as unset (git itself
  # treats empty GIT_AUTHOR_*/GIT_COMMITTER_* as unset).
  defp resolve_key(env_key, config_value, fallback) do
    case System.get_env(env_key) do
      value when is_binary(value) and value != "" -> value
      _ -> config_value || fallback
    end
  end

  # Memoizes the {name, email} pair resolved from `git config` for a repo path
  # (or the global scope when repo_path is nil). Stale-if-config-changed is
  # accepted and documented in the moduledoc.
  defp memoized_config_identity(repo_path) do
    key = {__MODULE__, :config_identity, repo_path}

    case :persistent_term.get(key, nil) do
      nil ->
        identity = read_config_identity(repo_path)
        :persistent_term.put(key, identity)
        identity

      identity ->
        identity
    end
  end

  # Reads the effective user.name/user.email via `git config` (no scope flag →
  # repo → global → system). Returns {name, email} where either may be nil.
  # Deliberately does NOT go through EvoGit.Adapters.Git — that adapter injects
  # this same env map, and config reads don't commit, so raw System.cmd has no
  # recursion risk.
  defp read_config_identity(repo_path) do
    git = EvoGit.Executable.resolve("git")
    cd = if is_binary(repo_path) and File.dir?(repo_path), do: repo_path, else: nil
    {read_config(git, "user.name", cd), read_config(git, "user.email", cd)}
  end

  defp read_config(git, key, cd) do
    opts =
      case cd do
        nil -> [stderr_to_stdout: true]
        dir -> [cd: dir, stderr_to_stdout: true]
      end

    # JUSTIFIED try/rescue: System.cmd raises ErlangError (:enoent) when the
    # executable is missing (e.g. git not installed). A missing git is treated
    # as "no config value" — callers fall through to the fallback identity.
    case System.cmd(git, ["config", key], opts) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          value -> value
        end

      {_output, _code} ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp do_resolve_true_executable do
    case System.find_executable("true") do
      path when is_binary(path) ->
        path

      nil ->
        # Windows: `true` is bundled with git-for-windows in its usr/bin dir.
        # Try to derive it from the git installation root; otherwise fall back
        # to the bare name "true" (git will still find it on PATH in most shells).
        case :os.type() do
          {:win32, _} ->
            case derive_windows_true_exe() do
              nil -> "true"
              path -> path
            end

          _ ->
            "true"
        end
    end
  end

  # Derives true.exe relative to the resolved git executable on Windows.
  # git-for-windows layout: <git_root>/cmd/git.exe and <git_root>/usr/bin/true.exe.
  defp derive_windows_true_exe do
    case System.find_executable("git") do
      git_path when is_binary(git_path) ->
        true_path =
          git_path
          |> Path.dirname()
          |> Path.dirname()
          |> Path.join(Path.join(["usr", "bin", "true.exe"]))

        if File.exists?(true_path), do: true_path, else: nil

      nil ->
        nil
    end
  end
end
