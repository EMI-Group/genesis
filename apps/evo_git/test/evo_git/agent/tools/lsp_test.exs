defmodule EvoGit.Agent.Tools.LspTest do
  @moduledoc """
  `async: false` — every execute-level test here spawns real OS processes (an
  `elixir` fake language server) and the unconfigured cases read the resolved user
  config, so keeping the module serial keeps process/pid accounting honest.

  No real language server, no network, no compilation: the fixture at
  `test/support/fake_lsp_server.exs` speaks the LSP base protocol over stdio with
  canned answers, so these tests cover the WHOLE pipeline (spawn → initialize →
  didOpen → request → teardown → SIGKILL).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools.Lsp
  alias EvoGit.Config.Schema

  @exact_unconfigured "Error: no language server configured — set [lsp] command in config.toml"

  @fixture Path.expand("../../../support/fake_lsp_server.exs", __DIR__)

  setup do
    repo = tmp_dir!("repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    source = Path.join(repo, "lib/sample.ex")
    File.write!(source, "defmodule Sample do\n  def hi, do: foo()\nend\n")

    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, repo: repo, source: source}
  end

  defp tmp_dir!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_lsp_#{label}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(path)
    File.mkdir_p!(path)
    path
  end

  # Config for the fake language server: `command` must be an executable, so the
  # `elixir` binary itself is the command and the fixture script is its argument.
  defp fake_server(mode, opts \\ []) do
    elixir = System.find_executable("elixir") || flunk("the `elixir` binary is not on PATH")

    args = [@fixture] ++ if(mode, do: [mode], else: [])

    Keyword.merge(
      [
        enabled: true,
        command: elixir,
        args: args,
        timeout: 60_000,
        diagnostics_timeout: 20_000,
        # Short quiet window after a diagnostics batch keeps the suite fast; the
        # production default is 500 ms.
        settle_ms: 50
      ],
      opts
    )
  end

  defp diagnostics_args(source), do: %{"action" => "diagnostics", "path" => source}

  defp position_args(action, source, line, column),
    do: %{"action" => action, "path" => source, "line" => line, "column" => column}

  # ── Schema ────────────────────────────────────────────────────────────────

  describe "schema/0" do
    test "is the model-facing `lsp` tool with the three supported actions" do
      schema = Lsp.schema()

      assert schema.name == "lsp"
      assert is_binary(schema.description)

      assert schema.description =~ "language server"
      assert schema.description =~ "diagnostics"
      assert schema.description =~ "hover"
      assert schema.description =~ "definition"

      parameters = schema.parameter_schema
      assert parameters["type"] == "object"
      assert parameters["properties"]["action"]["enum"] == ["diagnostics", "hover", "definition"]
      assert parameters["properties"]["path"]["type"] == "string"
      assert parameters["properties"]["line"]["type"] == "integer"
      assert parameters["properties"]["column"]["type"] == "integer"
      # line/column are required only for hover/definition — enforced in execute/4.
      assert parameters["required"] == ["action", "path"]
    end
  end

  # ── Configuration ─────────────────────────────────────────────────────────

  describe "configuration defaults" do
    test "the [lsp] schema section defaults to disabled with no command" do
      assert Schema.defaults()[:lsp] == %{
               enabled: false,
               command: nil,
               args: [],
               timeout: 30_000,
               diagnostics_timeout: 10_000
             }
    end

    test "each [lsp] key is described in the schema" do
      paths = Enum.map(Schema.all_schemas(), & &1.key_path)

      assert [:lsp, :enabled] in paths
      assert [:lsp, :command] in paths
      assert [:lsp, :args] in paths
      assert [:lsp, :timeout] in paths
      assert [:lsp, :diagnostics_timeout] in paths
    end
  end

  describe "unconfigured server" do
    test "returns the exact error when the tool is not enabled", %{repo: repo, source: source} do
      assert Lsp.execute(diagnostics_args(source), repo, repo, enabled: false) ==
               @exact_unconfigured
    end

    test "returns the exact error when no command is configured",
         %{repo: repo, source: source} do
      assert Lsp.execute(diagnostics_args(source), repo, repo, enabled: true, command: "") ==
               @exact_unconfigured
    end

    test "returns the exact error before validating anything else", %{repo: repo} do
      # A nonsense action + a path outside the repo still yield the config error:
      # the tool short-circuits on configuration first.
      assert Lsp.execute(
               %{"action" => "nonsense", "path" => "/definitely/not/here.ex"},
               repo,
               repo,
               enabled: false
             ) == @exact_unconfigured
    end
  end

  describe "missing executable" do
    test "reports a clear error instead of crashing", %{repo: repo, source: source} do
      output =
        Lsp.execute(diagnostics_args(source), repo, repo,
          enabled: true,
          command: "evogit-definitely-not-a-language-server"
        )

      assert output ==
               "Error: language server executable not found or not executable: " <>
                 "evogit-definitely-not-a-language-server"
    end
  end

  # ── Argument validation ───────────────────────────────────────────────────

  describe "argument validation" do
    test "rejects an unknown action", %{repo: repo, source: source} do
      output =
        Lsp.execute(%{"action" => "rename", "path" => source}, repo, repo, fake_server(nil))

      assert output =~ "Error: argument 'action' must be one of diagnostics, hover, definition"
    end

    test "requires line and column for hover", %{repo: repo, source: source} do
      output =
        Lsp.execute(%{"action" => "hover", "path" => source}, repo, repo, fake_server(nil))

      assert output =~ "Error: argument 'line' must be a 1-based integer"
    end

    test "rejects a path outside the repository", %{repo: repo} do
      outside = tmp_dir!("outside")
      File.write!(Path.join(outside, "other.ex"), "defmodule Other, do: nil\n")
      on_exit(fn -> File.rm_rf(outside) end)

      output =
        Lsp.execute(
          diagnostics_args(Path.join(outside, "other.ex")),
          repo,
          repo,
          fake_server(nil)
        )

      assert output =~ "Error: path"
      assert output =~ "is outside the repository"
    end

    test "reports a missing file clearly", %{repo: repo} do
      output =
        Lsp.execute(diagnostics_args("lib/nope.ex"), repo, repo, fake_server(nil))

      assert output =~ "Error: could not open lib/nope.ex"
    end

    test "rejects a file above the 2 MB analysis limit", %{repo: repo} do
      big = Path.join(repo, "lib/big.ex")
      File.write!(big, String.duplicate("x", 2 * 1024 * 1024 + 1))

      output = Lsp.execute(diagnostics_args(big), repo, repo, fake_server(nil))

      assert output =~ "Error: file is too large to analyse"
    end
  end

  # ── Live handshake against the fake server ────────────────────────────────

  describe "diagnostics" do
    test "runs the full handshake and renders one line per diagnostic",
         %{repo: repo, source: source} do
      output = Lsp.execute(diagnostics_args(source), repo, repo, fake_server(nil))

      assert output =~ "lib/sample.ex"
      assert output =~ "2 diagnostic(s)"

      # 0-based LSP positions 2:4 / 6:0 render as 1-based 3:5 / 7:1.
      assert output =~
               "lib/sample.ex:3:5 error undefined function foo/0 (fake diagnostic from the fixture)"

      assert output =~ "lib/sample.ex:7:1 warning unused variable"
    end

    test "renders `No diagnostics` for a clean file", %{repo: repo, source: source} do
      output = Lsp.execute(diagnostics_args(source), repo, repo, fake_server("clean"))

      assert output == "No diagnostics for lib/sample.ex."
    end
  end

  describe "hover" do
    test "renders the server's markup contents", %{repo: repo, source: source} do
      output = Lsp.execute(position_args("hover", source, 2, 3), repo, repo, fake_server(nil))

      assert output =~ "Hover at lib/sample.ex:2:3"
      assert output =~ "fake hover from the fixture"
    end
  end

  describe "definition" do
    test "renders one <path>:<line>:<col> line per location", %{repo: repo, source: source} do
      output =
        Lsp.execute(position_args("definition", source, 2, 3), repo, repo, fake_server(nil))

      # The fixture answers with a Location at 0-based 9:2 in a percent-clean
      # file:// URI; it must come back as a filesystem path at 1-based 10:3.
      assert output == "/fake/lib/definition.ex:10:3"
    end

    test "renders the empty-result message when the server returns null",
         %{repo: repo, source: source} do
      output =
        Lsp.execute(position_args("definition", source, 1, 1), repo, repo, fake_server(nil))

      assert output == "No definition found at lib/sample.ex:1:1."
    end
  end

  # ── Failure paths ─────────────────────────────────────────────────────────

  describe "failing servers" do
    test "reports an immediate exit with the captured stderr excerpt",
         %{repo: repo, source: source} do
      {micros, output} =
        :timer.tc(fn ->
          Lsp.execute(diagnostics_args(source), repo, repo, fake_server("crash"))
        end)

      assert output =~ "Error: the language server exited unexpectedly"
      assert output =~ "exit status 3"
      assert output =~ "fake-lsp: deliberate startup failure"

      # It must fail fast (bounded), not sit on a multi-second wait.
      assert div(micros, 1000) < 60_000
    end

    test "times out when the server never answers initialize", %{repo: repo, source: source} do
      output =
        Lsp.execute(
          diagnostics_args(source),
          repo,
          repo,
          fake_server("silent", timeout: 1_500)
        )

      assert output =~ "Error: the language server did not answer initialize within 1500 ms"
    end

    test "reports a malformed frame", %{repo: repo, source: source} do
      output =
        Lsp.execute(
          diagnostics_args(source),
          repo,
          repo,
          fake_server("malformed", timeout: 20_000)
        )

      assert output =~ "Error: malformed LSP frame"
      assert output =~ "no Content-Length header"
    end
  end

  # ── Process hygiene ───────────────────────────────────────────────────────

  describe "orphan prevention" do
    @tag :slow
    test "leaves no fake language server process behind", %{repo: repo, source: source} do
      Lsp.execute(diagnostics_args(source), repo, repo, fake_server(nil))

      case System.find_executable("pgrep") do
        nil ->
          # No pgrep on this host: the bounded-return assertion above still holds.
          :ok

        pgrep ->
          {out, _status} = System.cmd(pgrep, ["-f", @fixture], stderr_to_stdout: true)
          assert String.trim(out) == ""
      end
    end
  end
end
