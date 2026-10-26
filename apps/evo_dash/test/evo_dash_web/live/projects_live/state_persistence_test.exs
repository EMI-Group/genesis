defmodule EvoDashWeb.ProjectsLive.StatePersistenceTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.ProjectsLive.StatePersistence` — the
  node-aware persist/restore round-trip for foreign repos.

  A remote context (remote `remote?` assign or a `current_node` differing from
  `node()`) must rebuild the persisted repos with the RAW root via
  `ProjectFlow.build_foreign_repo/4` (no local `Path.expand` — the persisted
  path belongs to the remote node). Local sockets keep the legacy
  `ForeignRepo.new/3` semantics. The tests run on Linux CI but pin the REMOTE
  behavior regardless of host OS via a fake non-local node atom.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProjectsLive.StatePersistence
  alias EvoGit.Core.ForeignRepo

  # Differs from `node()` (:nonode@nohost) so the remote branches run; the
  # tests never connect to it.
  @remote_node :"genesis_remote@127.0.0.1"

  # Minimal LiveView socket with the assigns the function reads.
  # `__changed__: nil` keeps Phoenix's assign/3 on the simple Map.put path.
  defp socket(overrides) do
    assigns =
      %{__changed__: nil, remote?: false, current_node: node()}
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  # Restores `repos` on `socket` and returns the resulting assigns map.
  defp restore!(socket, repos) do
    socket |> StatePersistence.maybe_restore_foreign_repos(repos) |> Map.fetch!(:assigns)
  end

  describe "maybe_restore_foreign_repos/2 — remote sockets" do
    test "restore raw POSIX/Windows roots verbatim (remote? assign or current_node alone)" do
      # `==` equality proves the EXACT input round-tripped: no local
      # Path.expand (which would mangle it on a Windows dashboard).
      for remote_socket <- [
            socket(%{remote?: true, current_node: @remote_node}),
            socket(%{remote?: false, current_node: @remote_node})
          ] do
        restored =
          restore!(remote_socket, [
            %{"id" => "original", "path" => "/Source/original-proj", "description" => "legacy"},
            %{"id" => "win", "path" => "D:\\stuff\\repo"}
          ])

        assert [
                 %{id: "original", root: "/Source/original-proj", description: "legacy"},
                 %{id: "win", root: "D:\\stuff\\repo", description: nil}
               ] = restored.foreign_repos
      end
    end

    test "carry writable and base_sha raw, including a string true" do
      restored =
        restore!(socket(%{remote?: true, current_node: @remote_node}), [
          %{
            "id" => "remote",
            "path" => "/home/u/r",
            "description" => "d",
            "writable" => "true",
            "base_sha" => "abc123"
          },
          %{"id" => "bool", "path" => "/home/u/r2", "writable" => true},
          %{"id" => "plain", "path" => "/home/u/r3"}
        ])

      # No local coercion: "true" is normalized by StatePersistence before the
      # remote build, and the sha is stored verbatim.
      # Sorted primary-first-then-id: bool < plain < remote.
      assert [
               %{id: "bool", writable: true, base_sha: nil},
               %{id: "plain", writable: false, base_sha: nil},
               %{
                 id: "remote",
                 root: "/home/u/r",
                 description: "d",
                 writable: true,
                 base_sha: "abc123"
               }
             ] = restored.foreign_repos
    end
  end

  describe "maybe_restore_foreign_repos/2 — local sockets" do
    test "keep ForeignRepo.new/3 semantics (description, writable, base_sha coercion)" do
      local = socket(%{remote?: false, current_node: node()})

      assert [%{id: "local", root: "/tmp/repo", description: "d"}] =
               restore!(local, [%{"id" => "local", "path" => "/tmp/repo", "description" => "d"}]).foreign_repos

      assert restore!(local, [
               %{
                 "id" => "local",
                 "path" => "/abs/repo",
                 "description" => "d",
                 "writable" => true,
                 "base_sha" => "abc123"
               }
             ]).foreign_repos == [
               ForeignRepo.new("local", "/abs/repo",
                 writable: true,
                 base_sha: "abc123",
                 description: "d"
               )
             ]

      # Boolean and string true/false forms all normalize.
      for {writable, expected} <- [{"true", true}, {true, true}, {"false", false}, {false, false}] do
        assert [%{writable: ^expected}] =
                 restore!(local, [
                   %{"id" => "w", "path" => "/abs/r", "writable" => writable}
                 ]).foreign_repos,
               "expected writable #{inspect(writable)} to restore as #{inspect(expected)}"
      end

      # Missing writable → false; empty/missing base_sha → nil; a real sha is
      # carried through.
      assert [%{id: "w", writable: false}] =
               restore!(local, [%{"id" => "w", "path" => "/abs/r"}]).foreign_repos

      for input <- [
            %{"id" => "e", "path" => "/abs/r", "base_sha" => ""},
            %{"id" => "m", "path" => "/abs/r"}
          ] do
        assert [%{base_sha: nil}] = restore!(local, [input]).foreign_repos
      end

      assert [%{base_sha: "abc123"}] =
               restore!(local, [%{"id" => "b", "path" => "/abs/r", "base_sha" => "abc123"}]).foreign_repos
    end
  end

  describe "maybe_restore_foreign_repos/2 — degenerate input" do
    test "nil, empty, all-invalid lists leave the socket unchanged; bad entries dropped" do
      socket = socket(%{})
      assert StatePersistence.maybe_restore_foreign_repos(socket, nil) == socket
      assert StatePersistence.maybe_restore_foreign_repos(socket, []) == socket

      remote_socket = socket(%{remote?: true, current_node: @remote_node})

      assert StatePersistence.maybe_restore_foreign_repos(remote_socket, [
               %{"id" => "x", "path" => ""}
             ]) == remote_socket

      # A mixed list keeps only the valid entry.
      assert [%{id: "good", root: "/home/u/r"}] =
               restore!(remote_socket, [
                 %{"id" => "bad", "path" => ""},
                 %{"id" => "good", "path" => "/home/u/r"}
               ]).foreign_repos
    end
  end

  describe "serialize_foreign_repos/1" do
    test "emits exactly the five persisted keys; nil input is []; local round-trip holds" do
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

      assert StatePersistence.serialize_foreign_repos(nil) == []

      # serialize → restore round-trips writable and base_sha on a local socket.
      local = socket(%{remote?: false, current_node: node()})
      path = Path.join(System.tmp_dir!(), "repo")
      primary = [ForeignRepo.new("primary", path, writable: true, base_sha: "abc123")]

      assert restore!(local, StatePersistence.serialize_foreign_repos(primary)).foreign_repos ==
               primary
    end
  end
end
