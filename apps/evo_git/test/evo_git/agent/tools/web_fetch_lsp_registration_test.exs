defmodule EvoGit.Agent.Tools.WebFetchLspRegistrationTest do
  @moduledoc """
  Registration contract for the two read-only network / language-intelligence
  readers: `web_fetch` (`EvoGit.Agent.Tools.WebFetch`) and `lsp`
  (`EvoGit.Agent.Tools.Lsp`).

  The two are wired DIFFERENTLY:

    * `web_fetch` is ALWAYS offered — it appears in `Tools.schemas/0`
      (ordinary agents) and `Tools.read_only_schemas/0` (read-only agents)
      under every configuration;
    * `lsp` is SCHEMA-GATED — `EvoGit.Config.lsp_enabled?/0` is true only when
      `config.toml` sets `[lsp] enabled = true` together with a non-empty
      `[lsp] command`, and only then is the schema appended to both lists.
      Stock config (`enabled = false` by default) offers it to no agent at all.

  The dispatch clause is NOT gated: `Tools.execute/5` still routes `"lsp"` into
  `EvoGit.Agent.Tools.Lsp` regardless of the schema lists, so an enabled server
  works and an unconfigured one self-explains with an `Error:`.

  What this module pins (behaviour of the tools themselves is covered by their
  own suites):

    * the schema-list membership on a default config (`web_fetch` only) and on
      an enabled config (`lsp` too), plus the read-only subset invariant;
    * neither name is classified as a serial (read-modify-write) tool;
    * neither is a WRITE tool — proven indirectly (the write classification is
      private) by driving the repo-less write guard: a genuine write tool IS
      blocked there while both readers are NOT;
    * `Tools.execute/5` really dispatches each name into its tool module — the
      returned string comes from the TOOL (an `Error: …` produced by its own
      argument/gate validation), never from the unknown-tool fallback.

  `async: false` — the schema-list assertions redirect the process-wide
  `XDG_CONFIG_HOME` at a fresh temp config dir so they are independent of the
  developer's real `~/.config/genesis/config.toml` (which may enable `[lsp]`).
  The repo-less process dictionary key is per-test-process and cleared in
  `on_exit`.

  No network and no language server is touched: `web_fetch` is handed a
  `file://` URL (refused by its scheme gate before any socket) and the `lsp`
  configure-out uses an empty config dir, so both fail fast with a
  self-explaining `Error:`. The enabled case only inspects the SCHEMA lists —
  it never spawns the configured command.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools

  # `web_fetch` is offered unconditionally; `lsp` only joins it on an enabled
  # `[lsp]` config, so the default-config schema assertions iterate this list.
  @always_offered_tools ["web_fetch"]
  # Both names are relevant for the classification / dispatch assertions, which
  # are independent of the schema gate.
  @all_tool_names ["web_fetch", "lsp"]

  setup do
    repo = tmp_dir!("repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    on_exit(fn -> File.rm_rf(repo) end)

    # Empty isolated config dir (no config.toml) = the stock default config, no
    # matter what the developer's real ~/.config/genesis/config.toml says.
    config_dir = isolate_config!()

    {:ok, repo: repo, config_dir: config_dir}
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

  # Redirects the process-wide `XDG_CONFIG_HOME` at a fresh temp dir and returns
  # the genesis config directory the runtime then resolves. Restores the env var
  # and removes the temp tree in `on_exit` (the module is `async: false`).
  defp isolate_config! do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(
        System.tmp_dir!(),
        "evogit-tool-registration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      case original_xdg do
        nil -> System.delete_env("XDG_CONFIG_HOME")
        value -> System.put_env("XDG_CONFIG_HOME", value)
      end

      File.rm_rf!(tmp_xdg)
    end)

    config_dir = EvoGit.Config.config_dir()
    File.mkdir_p!(config_dir)
    config_dir
  end

  defp write_config!(config_dir, contents) do
    File.write!(Path.join(config_dir, "config.toml"), contents)
  end

  describe "schema registration (default config)" do
    test "web_fetch is offered to ordinary agents via schemas/0" do
      names = Tools.schemas() |> Enum.map(& &1.name)

      for name <- @always_offered_tools do
        assert name in names, "expected #{inspect(name)} to be in Tools.schemas/0"
      end
    end

    test "web_fetch is offered to read-only agents via read_only_schemas/0" do
      names = Tools.read_only_schemas() |> Enum.map(& &1.name)

      for name <- @always_offered_tools do
        assert name in names, "expected #{inspect(name)} to be in Tools.read_only_schemas/0"
      end
    end

    test "lsp is NOT offered by schemas/0 while no language server is configured" do
      refute EvoGit.Config.lsp_enabled?()

      names = Tools.schemas() |> Enum.map(& &1.name)

      refute "lsp" in names,
             "expected the config-gated `lsp` tool to be absent from Tools.schemas/0"
    end

    test "lsp is NOT offered by read_only_schemas/0 while no language server is configured" do
      refute EvoGit.Config.lsp_enabled?()

      names = Tools.read_only_schemas() |> Enum.map(& &1.name)

      refute "lsp" in names,
             "expected the config-gated `lsp` tool to be absent from Tools.read_only_schemas/0"
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

  describe "schema registration (configured language server)" do
    test "lsp IS offered to ordinary and read-only agents once [lsp] is enabled",
         %{config_dir: config_dir} do
      # Any non-empty command is enough to open the schema gate — nothing here
      # spawns it (only the schema lists are inspected).
      write_config!(config_dir, """
      [lsp]
      enabled = true
      command = "/bin/false"
      """)

      assert EvoGit.Config.lsp_enabled?()

      full_names = Tools.schemas() |> Enum.map(& &1.name)
      read_only_names = Tools.read_only_schemas() |> Enum.map(& &1.name)

      assert "lsp" in full_names,
             "expected the `lsp` tool to be in Tools.schemas/0 once [lsp] is enabled"

      assert "lsp" in read_only_names,
             "expected the `lsp` tool to be in Tools.read_only_schemas/0 once [lsp] is enabled"

      # `web_fetch` stays unconditional.
      assert "web_fetch" in full_names
      assert "web_fetch" in read_only_names
    end
  end

  describe "write/serial classification" do
    test "neither tool is a serial tool" do
      for name <- @all_tool_names do
        refute Tools.serial_tool?(name),
               "expected #{inspect(name)} NOT to be classified as a serial (read-modify-write) tool"
      end
    end

    test "neither tool is a WRITE tool (repo-less guard lets both through)", %{repo: repo} do
      # `write_tool?/1` is private, so the write classification is asserted
      # through its only observable effect: the repo-less dispatch guard. A real
      # write tool must be blocked, both readers must reach their own module.
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      blocked =
        Tools.execute("write_file", %{"file_path" => "x.txt", "content" => "x"}, repo, repo)

      assert is_binary(blocked)
      assert blocked =~ "read-only access to the system"

      for name <- @all_tool_names do
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

    test "lsp reaches EvoGit.Agent.Tools.Lsp even while the schema gate is closed", %{repo: repo} do
      # Dispatch is deliberately NOT schema-gated: with the isolated default
      # config `[lsp]` is unconfigured, so the tool itself returns its
      # exact configuration error. The message comes from `Lsp`, never from the
      # unknown-tool fallback (whose text is the only other possible shape for
      # a name that did not dispatch).
      refute EvoGit.Config.lsp_enabled?()

      result =
        Tools.execute("lsp", %{"action" => "diagnostics", "path" => "lib/x.ex"}, repo, repo)

      assert is_binary(result)

      assert String.starts_with?(result, "Error:"),
             "expected an \"Error: …\" string from the lsp tool, got: #{inspect(result)}"

      assert result =~ "no language server configured"
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
