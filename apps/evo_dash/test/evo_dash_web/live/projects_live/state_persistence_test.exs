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

    test "local socket round-trips writable and base_sha (ForeignRepo.new/3 equality)" do
      socket = socket(%{remote?: false, current_node: node()})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{
            "id" => "local",
            "path" => "/abs/repo",
            "description" => "d",
            "writable" => true,
            "base_sha" => "abc123"
          }
        ])
        |> Map.fetch!(:assigns)

      assert [repo] = restored.foreign_repos

      assert repo ==
               ForeignRepo.new("local", "/abs/repo",
                 writable: true,
                 base_sha: "abc123",
                 description: "d"
               )
    end

    test "remote socket round-trips writable and base_sha with the raw root" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{
            "id" => "remote",
            "path" => "/home/u/r",
            "description" => "d",
            "writable" => true,
            "base_sha" => "abc123"
          }
        ])
        |> Map.fetch!(:assigns)

      assert [
               %{
                 id: "remote",
                 root: "/home/u/r",
                 description: "d",
                 writable: true,
                 base_sha: "abc123"
               }
             ] = restored.foreign_repos
    end

    test "writable accepts boolean and string true/false forms (local socket)" do
      socket = socket(%{remote?: false, current_node: node()})

      for {writable, expected} <- [{"true", true}, {true, true}, {"false", false}, {false, false}] do
        restored =
          socket
          |> StatePersistence.maybe_restore_foreign_repos([
            %{"id" => "w", "path" => "/abs/r", "writable" => writable}
          ])
          |> Map.fetch!(:assigns)

        assert [%{writable: ^expected}] = restored.foreign_repos
      end
    end

    test "missing writable key restores as false (local socket)" do
      socket = socket(%{remote?: false, current_node: node()})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([%{"id" => "w", "path" => "/abs/r"}])
        |> Map.fetch!(:assigns)

      assert [%{writable: false}] = restored.foreign_repos
    end

    test "remote socket restores a string true writable" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "w", "path" => "/home/u/r", "writable" => "true"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{writable: true}] = restored.foreign_repos
    end

    test "base_sha empty string or missing key restores as nil" do
      socket = socket(%{remote?: false, current_node: node()})

      for input <- [
            %{"id" => "e", "path" => "/abs/r", "base_sha" => ""},
            %{"id" => "m", "path" => "/abs/r"}
          ] do
        restored =
          socket
          |> StatePersistence.maybe_restore_foreign_repos([input])
          |> Map.fetch!(:assigns)

        assert [%{base_sha: nil}] = restored.foreign_repos
      end
    end

    test "non-empty base_sha is carried through (local socket)" do
      socket = socket(%{remote?: false, current_node: node()})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "b", "path" => "/abs/r", "base_sha" => "abc123"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{base_sha: "abc123"}] = restored.foreign_repos
    end

    test "remote base_sha is stored verbatim, never locally rewritten" do
      socket = socket(%{remote?: true, current_node: @remote_node})

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos([
          %{"id" => "r", "path" => "/home/u/r", "base_sha" => "abc123"}
        ])
        |> Map.fetch!(:assigns)

      assert [%{base_sha: "abc123"}] = restored.foreign_repos
    end
  end

  describe "serialize_foreign_repos/1" do
    test "emits exactly the five persisted keys per repo with correct values" do
      path_a = Path.join(System.tmp_dir!(), "repo-a")
      path_b = Path.join(System.tmp_dir!(), "repo-b")

      repos = [
        ForeignRepo.new("a", path_a, writable: true, base_sha: "abc123"),
        ForeignRepo.new("b", path_b)
      ]

      assert StatePersistence.serialize_foreign_repos(repos) == [
               %{
                 "id" => "a",
                 "path" => Path.expand(path_a),
                 "description" => nil,
                 "writable" => true,
                 "base_sha" => "abc123"
               },
               %{
                 "id" => "b",
                 "path" => Path.expand(path_b),
                 "description" => nil,
                 "writable" => false,
                 "base_sha" => nil
               }
             ]
    end

    test "nil input serializes to an empty list" do
      assert StatePersistence.serialize_foreign_repos(nil) == []
    end

    test "serialize then restore round-trips writable and base_sha (local socket)" do
      socket = socket(%{remote?: false, current_node: node()})
      path = Path.join(System.tmp_dir!(), "repo")

      repos = [ForeignRepo.new("primary", path, writable: true, base_sha: "abc123")]

      serialized = StatePersistence.serialize_foreign_repos(repos)

      restored =
        socket
        |> StatePersistence.maybe_restore_foreign_repos(serialized)
        |> Map.fetch!(:assigns)

      assert restored.foreign_repos == repos
    end
  end
end
