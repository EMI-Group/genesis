defmodule EvoGit.CustomToolsRPCTest do
  @moduledoc """
  Tests for the custom-tools RPC surface:

    * `EvoGit.AgentScheduler.RemoteAPI.custom_tools_status/0` — the direct
      per-node function (delegates to `EvoGit.CustomTools.status/0`).
    * `EvoGit.RemoteNode.custom_tools_status/1` — the node-first wrapper (local
      path delegates to RemoteAPI; the remote branch is exercised through the
      unreachable-node `call_remote/4` failure path, same pattern as
      custom_agents_rpc_test.exs).

  `async: false` — every test repoints the BEAM-global `XDG_CONFIG_HOME` so the
  per-node `<config_dir>/tools/` directory is a fresh temp dir and never touches
  the real `~/.config/genesis/`.
  """
  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.CustomTools
  alias EvoGit.CustomTools.Loader
  alias EvoGit.RemoteNode

  # A node name that definitely does not exist on this machine (same pattern
  # as custom_agents_rpc_test.exs). On a non-distributed local node, :erpc.call
  # to a foreign node fails immediately with {:erpc, :noconnection} — no TCP
  # timeout wait.
  @fake_remote :"nonexistent@127.0.0.1"

  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-ctrpc-xdg-#{uniq()}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # The loader caches in :persistent_term keyed by the tools dir (which
    # follows XDG_CONFIG_HOME) — invalidate before and after for determinism.
    Loader.invalidate(tools_dir())

    on_exit(fn ->
      Loader.invalidate(tools_dir())

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  defp tools_dir, do: CustomTools.tools_dir()

  defp module_for, do: Module.concat([:"CustomToolsRPCFixture#{uniq()}"])

  # Writes a MINIMAL valid custom-tool source module (a `.ex` file exporting
  # `schema/0` and `execute/2`) into the temp tools dir, mirroring the fixture
  # shape used by custom_tools_test.exs.
  defp write_source_tool!(tool_name, read_only) do
    module = module_for()
    dir = tools_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{tool_name}.ex")

    File.write!(path, """
    defmodule #{inspect(module)} do
      @behaviour EvoGit.CustomTools.Tool

      @impl true
      def schema do
        ReqLLM.tool(
          name: #{inspect(tool_name)},
          description: "custom tools rpc test fixture",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, nil} end
        )
      end

      @impl true
      def read_only?, do: #{read_only}

      @impl true
      def execute(_args, _ctx), do: "custom-tool-ran"
    end
    """)

    {module, path}
  end

  # ── RemoteAPI direct function ──────────────────────────────────────

  describe "RemoteAPI.custom_tools_status/0" do
    test "returns the empty shape with an empty tools dir" do
      File.mkdir_p!(tools_dir())
      CustomTools.reload()

      assert RemoteAPI.custom_tools_status() == %{ok: [], errors: []}
    end

    test "includes a valid custom tool in :ok with the expected keys" do
      tool = "ctrpc_#{uniq()}"
      {module, path} = write_source_tool!(tool, true)
      CustomTools.reload()

      assert %{ok: [entry], errors: []} = RemoteAPI.custom_tools_status()

      assert entry.name == tool
      assert entry.file == path
      assert entry.module == module
      assert entry.read_only? == true
    end
  end

  # ── RemoteNode wrapper (local node) ────────────────────────────────

  describe "RemoteNode.custom_tools_status/1 on the local node" do
    test "delegates to RemoteAPI" do
      File.mkdir_p!(tools_dir())
      CustomTools.reload()

      assert RemoteNode.custom_tools_status(node()) == RemoteAPI.custom_tools_status()
    end

    test "returns the loaded tool status verbatim" do
      tool = "ctrpc_local_#{uniq()}"
      {module, path} = write_source_tool!(tool, false)
      CustomTools.reload()

      status = RemoteNode.custom_tools_status(node())

      assert %{ok: [entry], errors: []} = status
      assert entry == %{name: tool, file: path, module: module, read_only?: false}
    end
  end

  # ── RemoteNode wrapper (unreachable remote node) ───────────────────

  describe "RemoteNode.custom_tools_status/1 on an unreachable remote node" do
    test "surfaces the RPC failure instead of swallowing it into an empty map" do
      assert {:error, _reason} = RemoteNode.custom_tools_status(@fake_remote)
    end
  end
end
