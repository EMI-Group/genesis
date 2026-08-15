defmodule EvoDashWeb.ProjectsLive.StatePersistenceTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.ProjectsLive.StatePersistence.maybe_restore_foreign_repos/2`
  — the node-aware persist/restore round-trip for foreign repos.

  A remote context (remote `remote?` assign or a `current_node` differing from
  `node()`) must rebuild the persisted repos with the RAW root via
  `ProjectFlow.build_foreign_repo/4` (no local `Path.expand` — the persisted
  path belongs to the remote node). Local sockets keep the legacy
  `ForeignRepo.new/3` semantics.

  No LiveView harness is required — a minimal `%Phoenix.LiveView.Socket{}` is
  built directly (same pattern as `node_aware_test.exs`).

  NOTE: the tests run on Linux CI but must pin the NEW remote behavior
  regardless of host OS. The remote branches are therefore exercised with a
  fake non-local node atom so the dashboard's host-OS semantics never leak in.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.StatePersistence
  alias EvoGit.Core.ForeignRepo

  # A fake remote BEAM node name. The tests never connect to it — it only has
  # to differ from `node()` so the remote branches run (the test VM node is
  # `:nonode@nohost`).
  @remote_node :"genesis_remote@127.0.0.1"

  # Builds a minimal LiveView socket with the assigns the function reads.
  # `__changed__: nil` keeps Phoenix's assign/3 on the simple Map.put path.
  defp socket(overrides) do
    assigns =
      %{
        __changed__: nil,
        remote?: false,
        current_node: node()
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  describe "maybe_restore_foreign_repos/2" do
    test "remote socket (remote?: true) restores the raw POSIX path verbatim" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "original", "path" => "/Source/original-proj", "description" => "legacy"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{id: "original", root: "/Source/original-proj", description: "legacy"}] =
               restored.foreign_repos

      # `==` equality proves the EXACT input round-tripped: no local
      # Path.expand (which would mangle it on a Windows dashboard).
      assert hd(restored.foreign_repos).root == "/Source/original-proj"
    end

    test "remote socket restores a Windows root verbatim (never cwd-joined)" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "win", "path" => "D:\\stuff\\repo"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{id: "win", root: "D:\\stuff\\repo", description: nil}] =
               restored.foreign_repos

      # Pre-fix, a POSIX dashboard's ForeignRepo.new/3 cwd-joined this path.
      assert hd(restored.foreign_repos).root == "D:\\stuff\\repo"
    end

    test "remote context via current_node alone (remote?: false) restores raw" do
      socket = socket(%{remote?: false, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([%{"id" => "x", "path" => "/home/u/r"}])
        |> Map.fetch!(:assigns)

      assert [%{id: "x", root: "/home/u/r"}] = restored.foreign_repos
    end

    test "local socket keeps ForeignRepo.new/3 semantics (description carried through)" do
      socket = socket(%{remote?: false, current_node: node()})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "local", "path" => "/tmp/repo", "description" => "d"}
        ])
        |> Map.fetch!(:assigns)

      assert [repo] = restored.foreign_repos
      assert repo == ForeignRepo.new("local", "/tmp/repo", description: "d")
    end

    test "nil and empty lists leave the socket unchanged" do
      socket = socket(%{})

      assert StatePersistence.maybe_restore_foreign_repos(socket, nil) == socket
      assert StatePersistence.maybe_restore_foreign_repos(socket, []) == socket
    end

    test "entries with empty paths are dropped" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "bad", "path" => ""},
          %{"id" => "good", "path" => "/home/u/r"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{id: "good", root: "/home/u/r"}] = restored.foreign_repos
    end

    test "when all entries are invalid the socket is returned unchanged" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      assert StatePersistence.maybe_restore_foreign_repos(socket, [
               %{"id" => "x", "path" => ""}
             ]) == socket
    end
  end
end
