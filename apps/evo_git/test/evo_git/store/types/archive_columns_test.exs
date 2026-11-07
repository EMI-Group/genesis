defmodule EvoGit.Store.Types.ArchiveColumnsTest do
  @moduledoc """
  `EvoGit.Store.Types.ArchiveColumns.dump_json/1` — the plain-JSON wire
  boundary of the `task_agent_archives` JSON TEXT columns.

  `async: true`: pure functions only — no Repo, no ETS, no application state.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Store.Types.ArchiveColumns

  describe "dump_json/1" do
    test "nil stays SQL NULL" do
      assert ArchiveColumns.dump_json(nil) == {:ok, nil}
    end

    test "normalizes a keyword-list value into a string-keyed JSON object" do
      assert {:ok, json} = ArchiveColumns.dump_json(%{provider_options: [auth_mode: :oauth]})

      assert Jason.decode!(json) == %{"provider_options" => %{"auth_mode" => "oauth"}}
    end

    test "normalizes a bare list of 2-tuples into a JSON object" do
      assert {:ok, json} = ArchiveColumns.dump_json([{:auth_mode, :oauth}, {"store", false}])

      assert Jason.decode!(json) == %{"auth_mode" => "oauth", "store" => false}
    end

    test "normalizes pair-shaped containers nested inside maps and lists" do
      value = %{
        llm_settings: %{provider_options: [auth_mode: :oauth, oauth_file: "/tmp/x.json"]},
        entries: [[{:a, 1}]]
      }

      assert {:ok, json} = ArchiveColumns.dump_json(value)

      assert Jason.decode!(json) == %{
               "llm_settings" => %{
                 "provider_options" => %{"auth_mode" => "oauth", "oauth_file" => "/tmp/x.json"}
               },
               "entries" => [%{"a" => 1}]
             }
    end

    test "a plain list stays a JSON array" do
      assert {:ok, json} = ArchiveColumns.dump_json(%{tags: ["a", "b"]})
      assert Jason.decode!(json) == %{"tags" => ["a", "b"]}
    end

    test "genuinely unencodable terms still return :error" do
      assert ArchiveColumns.dump_json(%{x: self()}) == :error
      assert ArchiveColumns.dump_json(%{x: make_ref()}) == :error
      assert ArchiveColumns.dump_json(%{x: fn -> :ok end}) == :error
      assert ArchiveColumns.dump_json(%{pairs: [{:x, self()}]}) == :error
    end

    test "non-map/non-list values return :error" do
      assert ArchiveColumns.dump_json(:an_atom) == :error
      assert ArchiveColumns.dump_json(42) == :error
    end
  end
end
