defmodule EvoDashWeb.ProjectsLive.WorkspaceEntriesTest do
  @moduledoc """
  The BATCHED VCT workspace read behind the two dashboard call sites:
  `EvoDashWeb.ProjectsLive.AsyncLoad.load_workspaces/3` (the Projects palette)
  and `EvoDashWeb.HomeLive.Workspace.list/2` (the Assistant's project picker).

  Both must resolve the WHOLE workspace roster (members included) in ONE call —
  `EvoGit.VCT.workspace_entries/1` — instead of a roster read plus one
  resolution call per workspace, while preserving the exact view shapes their
  components consume:
    * Projects → `%{workspace: mount, resolved: [%{point:, name:, path:}],
      missing: [ref], nested: [ref]}`;
    * Assistant → `%{workspace: mount, members: [%{point:, path:, name:}],
      missing: [%{point:, path:}]}`.

  `async: true` — the `:evogit_vct_server` seam is PROCESS-LOCAL
  (`EvoGit.VCT.server/0` reads the caller's process dictionary) and every fake
  is registered under a unique name, so nothing here mutates a BEAM-global
  another concurrently running module can observe.
  """
  use ExUnit.Case, async: true

  alias EvoDash.NodeContext
  alias EvoDashWeb.HomeLive.Workspace
  alias EvoDashWeb.ProjectsLive.AsyncLoad
  alias EvoGit.VCT.Mount

  defmodule FakeVCT do
    @moduledoc """
    A stand-in VCT server: answers the two batched list reads and reports every
    request to the test process, so a test can assert how many calls a loader
    made.
    """
    use GenServer

    def start(owner, entries, projects \\ []) do
      name = :"fake_vct_#{System.unique_integer([:positive, :monotonic])}"
      {:ok, _pid} = start_link(name, %{owner: owner, entries: entries, projects: projects})
      name
    end

    def start_link(name, state) do
      GenServer.start_link(__MODULE__, state, name: name)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(request, _from, state) do
      send(state.owner, {:vct_request, request})

      case request do
        {:workspace_entries, _opts} -> {:reply, state.entries, state}
        {:projects, _opts} -> {:reply, state.projects, state}
        _other -> {:reply, [], state}
      end
    end
  end

  describe "AsyncLoad.load_workspaces/3" do
    test "resolves the whole roster in ONE batched call" do
      workspace = workspace_mount("ws-one", [stored_ref("vct:///projects/a", "/tmp/a")])
      missing_ref = stored_ref("vct:///projects/gone", nil)

      entries = [
        %{
          workspace: workspace,
          members: [member_entry("vct:///projects/a", "a", "/tmp/a")],
          missing: [missing_ref],
          nested: []
        }
      ]

      use_fake_vct(entries)

      assert [
               %{
                 workspace: ^workspace,
                 resolved: [%{point: "vct:///projects/a", name: "a", path: "/tmp/a"}],
                 missing: [^missing_ref],
                 nested: []
               }
             ] = AsyncLoad.load_workspaces(false, nil, node())

      assert_received {:vct_request, {:workspace_entries, []}}
      # ONE call: no second roster read, and no per-workspace resolution.
      refute_received {:vct_request, {:workspace_entries, []}}
      refute_received {:vct_request, {:workspace_members, _}}
      refute_received {:vct_request, {:workspaces}}
    end

    test "an entry without resolved members reports every stored ref as missing" do
      workspace =
        workspace_mount("ws-degraded", [
          stored_ref("vct:///projects/a", "/tmp/a"),
          stored_ref(nil, "/tmp/b")
        ])

      use_fake_vct([%{workspace: workspace}])

      assert [%{workspace: ^workspace, resolved: [], missing: missing, nested: []}] =
               AsyncLoad.load_workspaces(true, nil, node())

      assert missing == ["vct:///projects/a", "/tmp/b"]
    end

    test "a pending remote context never reads another node's workspaces" do
      use_fake_vct([
        %{workspace: workspace_mount("ws-one", []), members: [], missing: [], nested: []}
      ])

      assert AsyncLoad.load_workspaces(false, "remote-target-id", node()) == []
      refute_received {:vct_request, _request}
    end
  end

  describe "HomeLive.Workspace.list/2" do
    test "keeps stored member order and resolves from ONE batched call" do
      workspace =
        workspace_mount("ws-two", [
          stored_ref("vct:///projects/b", "/tmp/b"),
          stored_ref("vct:///projects/a", "/tmp/a"),
          stored_ref("vct:///projects/gone", nil)
        ])

      entries = [
        %{
          workspace: workspace,
          members: [
            member_entry("vct:///projects/b", "b", "/tmp/b"),
            member_entry("vct:///projects/a", "a", "/tmp/a")
          ],
          missing: [stored_ref("vct:///projects/gone", nil)],
          nested: []
        }
      ]

      use_fake_vct(entries)

      assert {:ok, %{projects: [], workspaces: [view]}} = Workspace.list(nil, node())
      assert view.workspace == workspace

      assert view.members == [
               %{point: "vct:///projects/b", path: "/tmp/b", name: "b"},
               %{point: "vct:///projects/a", path: "/tmp/a", name: "a"}
             ]

      assert view.missing == [%{point: "vct:///projects/gone", path: nil}]

      assert_received {:vct_request, {:workspace_entries, []}}
      refute_received {:vct_request, {:workspace_entries, []}}
      refute_received {:vct_request, {:workspace_members, _}}
      refute_received {:vct_request, {:workspaces}}
    end

    test "the node-aware read degrades to no workspaces when the roster read fails" do
      use_fake_vct([], [])

      assert NodeContext.workspace_entries(node()) == []
    end
  end

  # The seam is established in the CALLER's process dictionary, so the local
  # `EvoGit.RemoteNode.call_remote/4` path (an in-process `apply`) reaches it.
  defp use_fake_vct(entries, projects \\ []) do
    name = FakeVCT.start(self(), entries, projects)
    Process.put(:evogit_vct_server, name)
    name
  end

  defp workspace_mount(name, members) do
    %Mount{
      point: "vct:///workspaces/#{name}",
      name: name,
      kind: "workspace",
      path: nil,
      members: members
    }
  end

  defp stored_ref(point, path), do: %{"point" => point, "path" => path}

  defp member_entry(point, name, path), do: %{point: point, name: name, path: path}
end
