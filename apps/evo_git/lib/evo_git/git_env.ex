defmodule EvoGit.GitEnv do
  @moduledoc """
  Shared git environment helpers — single source of truth for the `GIT_EDITOR`
  and `LC_ALL` env vars injected into every git invocation.

  Both git execution paths in the codebase delegate to this module:

    * the internal adapter (`EvoGit.Adapters.Git`), and
    * the agent sandbox tool path (`EvoGit.sandbox_run/4` → `EvoGit.Sandbox.*`
      backends).

  Setting `GIT_EDITOR` to the `true` executable ensures automated git operations
  that may open an interactive editor (e.g. `git merge --continue`, rebase, am,
  commit) never block waiting on user input. `LC_ALL=C` forces locale-independent
  (English) output so git output can be parsed reliably.
  """

  # :persistent_term key caching the resolved path to the `true` executable.
  # Resolving it scans PATH, so we memoize once for the VM's lifetime.
  @true_path_key {__MODULE__, :true_path}

  @doc """
  Returns the environment map shared by every git invocation.

  Always sets:

    * `LC_ALL` => `C` — locale-independent (English) output for reliable parsing.
    * `GIT_EDITOR` => resolved `true` path — a no-op editor so automated
      operations that may open an interactive editor (e.g. `merge --continue`,
      rebase, am, commit) never block.
  """
  @spec git_env() :: %{String.t() => String.t()}
  def git_env do
    %{
      "LC_ALL" => "C",
      "GIT_EDITOR" => resolve_true_executable(),
      "GIT_AUTHOR_NAME" => "Genesis Test",
      "GIT_AUTHOR_EMAIL" => "test@genesis.local",
      "GIT_COMMITTER_NAME" => "Genesis Test",
      "GIT_COMMITTER_EMAIL" => "test@genesis.local"
    }
  end

  @doc """
  Returns `git_env/0` as a list of `{String.t(), String.t()}` tuples.

  Convenient for `System.cmd`'s `:env` option (which accepts a list of
  `{string, string}` tuples and MERGES them into the inherited environment)
  and for building systemd-run `--setenv=KEY=VALUE` args.
  """
  @spec git_env_list() :: [{String.t(), String.t()}]
  def git_env_list do
    Map.to_list(git_env())
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
