defmodule EvoGit.FakeGh do
  @moduledoc """
  Shared helper that puts a fake `gh` executable on `PATH`.

  The fake `gh` logs its argv (one element per line) to the file pointed to by
  `GH_FAKE_LOG` and returns canned GitHub issue JSON. `GH_FAKE_MODE` drives
  failure modes: `fail` → stderr message + exit 7, `badjson` → invalid JSON on
  stdout, anything else → canned responses.

  **Only usable from `async: false` test modules** — `PATH` is BEAM-global,
  so parallel modules would see the fake binary and interfere with each
  other. Tests using this helper must also be POSIX-gated
  (`if not match?({:win32, _}, :os.type()) do`), because the fake binary is a
  shell script that cannot emulate `gh.exe` on Windows.
  """

  @doc """
  Creates a fake `gh` executable in a fresh temp dir, puts it first on
  `PATH`, points `GH_FAKE_LOG` at a log file in that dir, and calls
  `fun.(%{dir: tmp_dir, log_path: log_path})`.

  `PATH`, `GH_FAKE_LOG` and `GH_FAKE_MODE` are saved and restored on exit
  (or deleted if originally unset), and the temp dir is removed.
  """
  def with_fake_gh(fun) when is_function(fun, 1) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "evogit-test-gh-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    gh_path = Path.join(tmp, "gh")

    # ~S keeps every backslash literal — the `\n` sequences below are
    # interpreted by the shell's printf, not by Elixir.
    File.write!(
      gh_path,
      ~S"""
      #!/bin/sh
      if [ -n "${GH_FAKE_LOG:-}" ]; then
        printf '%s\n' "$@" >> "$GH_FAKE_LOG"
      fi
      case "${GH_FAKE_MODE:-}" in
        fail)
          printf 'gh: simulated failure (stderr)\n' >&2
          exit 7
          ;;
        badjson)
          printf 'this is not valid json {\n'
          exit 0
          ;;
      esac
      if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
        printf '%s' '[{"number":1,"title":"Fix login bug","state":"open","labels":[{"name":"bug"},{"name":"frontend"}],"url":"https://github.com/octocat/hello-world/issues/1","author":{"login":"alice"},"createdAt":"2024-01-15T10:00:00Z"},{"number":2,"title":"Add dark mode","state":"closed","labels":[],"url":"https://github.com/octocat/hello-world/issues/2","author":{},"createdAt":"2024-02-20T12:30:00Z"},{"number":3,"title":"Fix docs typo","state":"open","labels":[{"name":"docs"}],"url":"https://github.com/octocat/hello-world/issues/3","author":{"login":"bob"},"createdAt":"2024-03-01T08:00:00Z"}]'
      elif [ "$1" = "issue" ] && [ "$2" = "view" ]; then
        case "${3:-}" in
          43)
            printf '%s' '{"number":43,"title":"Nothing to see here","state":"closed","labels":[],"url":"https://github.com/octocat/hello-world/issues/43","author":{"login":"dave"},"body":"No labels on this one."}'
            ;;
          999)
            printf 'gh: issue not found (stderr)\n' >&2
            exit 7
            ;;
          *)
            printf '%s' '{"number":42,"title":"Refactor scheduler core","state":"open","labels":[{"name":"core"},{"name":"refactor"}],"url":"https://github.com/octocat/hello-world/issues/42","author":{"login":"carol"},"body":"First line.\n\nSecond paragraph."}'
            ;;
        esac
      fi
      exit 0
      """
    )

    File.chmod!(gh_path, 0o755)

    log_path = Path.join(tmp, "gh-argv.log")

    original_path = System.get_env("PATH")
    original_log = System.get_env("GH_FAKE_LOG")
    original_mode = System.get_env("GH_FAKE_MODE")

    new_path = if original_path, do: tmp <> ":" <> original_path, else: tmp
    System.put_env("PATH", new_path)
    System.put_env("GH_FAKE_LOG", log_path)

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("GH_FAKE_LOG", original_log)
      restore_env("GH_FAKE_MODE", original_mode)

      File.rm_rf!(tmp)
    end)

    fun.(%{dir: tmp, log_path: log_path})
  end

  @doc """
  Reads the argv log produced by the fake `gh` (`GH_FAKE_LOG`), returning one
  argv element per line.
  """
  def read_argv_log(log_path) do
    log_path
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
