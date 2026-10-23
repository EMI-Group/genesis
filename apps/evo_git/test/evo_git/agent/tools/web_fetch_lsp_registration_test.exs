defmodule EvoGit.Agent.Tools.WebFetchLspRegistrationTest do
  @moduledoc """
  Registration contract for the two read-only tools added after `curl` was
  retired: `web_fetch` (`EvoGit.Agent.Tools.WebFetch`) and `lsp`
  (`EvoGit.Agent.Tools.Lsp`).

  The point of this module is the WIRING, not the tools themselves (their own
  suites cover behaviour):

    * both schema names appear in `Tools.schemas/0` (ordinary agents) AND
      `Tools.read_only_schemas/0` (read-only agents);
    * neither is classified as a write tool — proven indirectly (the write
      classification is private) by driving the repo-less write guard: a genuine
      write tool IS blocked there while both new tools are NOT;
    * neither is a serial tool (they are not read-modify-write file operations);
    * `Tools.execute/5` really dispatches the name into the tool module — the
      returned string comes from the TOOL (an `Error: …` produced by its own
      argument/gate validation), never from the unknown-tool fallback.

  No network and no language server is touched: `web_fetch` is handed a
  `file://` URL (refused by its scheme gate before any socket) and `lsp` is
  configured-out by default, so both fail fast with a self-explaining `Error:`.
  `async: true` — nothing here mutates BEAM-global state (the repo-less process
  dictionary key is per-test-process and cleared in `on_exit`).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools

  @tool_names ["web_fetch", "lsp"]

  setup do
    repo = tmp_dir!("repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, repo: repo}
  end

  defp tmp_dir!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_tool_registration_#{label}_#{System.pid()}_" <>
          "#{System.unique_integer([:positive])}"
      )

    File.rm_rf(path)
    File.mkdir_p!(path)
    path
  end

  describe "schema registration" do
    test "both tools are offered to ordinary agents via schemas/0" do
      names = Tools.schemas() |> Enum.map(& &1.name)

      for name <- @tool_names do
        assert name in names, "expected #{inspect(name)} to be in Tools.schemas/0"
      end
    end

    test "both tools are offered to read-only agents via read_only_schemas/0" do
      names = Tools.read_only_schemas() |> Enum.map(& &1.name)

      for name <- @tool_names do
        assert name in names, "expected #{inspect(name)} to be in Tools.read_only_schemas/0"
      end
    end

    test "read_only_schemas/0 is a subset of schemas/0 (no read-only-only schema)" do
      full = Tools.schemas() |> Enum.map(& &1.name) |> MapSet.new()
      read_only = Tools.read_only_schemas() |> Enum.map(& &1.name)

      for name <- read_only do
        assert MapSet.member?(full, name),
               "expected read-only tool #{inspect(name)} to also be in Tools.schemas/0"
      end
    end

    test "the shared schema modules are the ones registered (names match the modules)" do
      assert EvoGit.Agent.Tools.WebFetch.schema().name == "web_fetch"
      assert EvoGit.Agent.Tools.Lsp.schema().name == "lsp"
    end
  end

  describe "write/serial classification" do
    test "neither tool is a serial tool" do
      for name <- @tool_names do
        refute Tools.serial_tool?(name),
               "expected #{inspect(name)} NOT to be classified as a serial (read-modify-write) tool"
      end
    end

    test "neither tool is a WRITE tool (repo-less guard lets both through)", %{repo: repo} do
      # `write_tool?/1` is private, so the write classification is asserted
      # through its only observable effect: the repo-less dispatch guard. A real
      # write tool must be blocked, both new tools must reach their own module.
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      blocked =
        Tools.execute("write_file", %{"file_path" => "x.txt", "content" => "x"}, repo, repo)

      assert is_binary(blocked)
      assert blocked =~ "read-only access to the system"

      for name <- @tool_names do
        result = Tools.execute(name, dispatch_args(name), repo, repo)

        assert is_binary(result)

        refute result =~ "read-only access to the system",
               "expected #{inspect(name)} to be allowed for a repo-less agent, got: #{inspect(result)}"
      end
    end
  end

  describe "dispatch routing (Tools.execute/5 → tool module)" do
    test "web_fetch reaches EvoGit.Agent.Tools.WebFetch (scheme gate, no network)", %{repo: repo} do
      result = Tools.execute("web_fetch", %{"url" => "file:///etc/passwd"}, repo, repo)

      assert is_binary(result)
      assert String.starts_with?(result, "Error:")
      # The `file:` scheme is refused by WebFetch itself — proving the name was
      # dispatched to the tool rather than to the unknown-tool fallback.
      assert result =~ "not supported"
      assert result =~ "web_fetch"
      refute result =~ "Unknown tool"
    end

    test "lsp reaches EvoGit.Agent.Tools.Lsp (no language server needed)", %{repo: repo} do
      result =
        Tools.execute("lsp", %{"action" => "diagnostics", "path" => "lib/x.ex"}, repo, repo)

      # Environment-independent assertions only: `[lsp]` is disabled by default,
      # so this is normally `Error: no language server configured — set [lsp]
      # command in config.toml`. On a machine that DOES configure a language
      # server the same call instead reaches `Lsp`'s executable/file gates (the
      # target file does not exist here) — still an `Error:` rendered by `Lsp`,
      # and no server is spawned. Either way the message comes from `Lsp`, never
      # from the unknown-tool fallback (whose text is the only other possible
      # shape for a name that did not dispatch).
      assert is_binary(result)

      assert String.starts_with?(result, "Error:"),
             "expected an \"Error: …\" string from the lsp tool, got: #{inspect(result)}"

      refute result =~ "Unknown tool"
    end

    test "an unknown name still falls through to the unknown-tool error (control)", %{
      repo: repo
    } do
      # Control for the two `refute result =~ "Unknown tool"` assertions above:
      # the fallback IS reachable, so those refutations are meaningful.
      result = Tools.execute("no_such_tool", %{"a" => 1}, repo, repo)

      assert is_binary(result)
      assert result =~ "Unknown tool 'no_such_tool'"
    end
  end

  # Arguments that reach each tool's own validation path without any I/O: a
  # `file://` URL (refused by the scheme gate) and a nonexistent-but-in-repo
  # path with a valid action (refused by the not-configured/file gates).
  defp dispatch_args("web_fetch"), do: %{"url" => "file:///etc/passwd"}
  defp dispatch_args("lsp"), do: %{"action" => "diagnostics", "path" => "lib/x.ex"}
end
