defmodule EvoDashWeb.ArchiveTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  # These tests guard against the infinite-recursion / OOM bug where archive
  # agent records arrive with STRING keys (after a DB round-trip through
  # Jason.decode) but the tree-building code read them with ATOM keys.
  #
  # Before the fix, `agent[:parent_id]` returned nil for every agent, so all
  # agents were grouped under the nil parent. Then `agent[:agent_id]` was also
  # nil, so `by_parent[nil]` returned ALL agents again → infinite recursion →
  # OOM/SIGKILL.
  #
  # These tests must terminate (not loop forever) and render the agent ids.

  # A small parent/child hierarchy using STRING keys — exactly as it looks
  # after `TaskStore.decode_archive/1` runs `Jason.decode/1`.
  @string_key_archive [
    %{
      "agent_id" => "agent-1",
      "parent_id" => nil,
      "objective" => "Root agent objective",
      "depth" => 0,
      "result" => "Root completed"
    },
    %{
      "agent_id" => "agent-2",
      "parent_id" => "agent-1",
      "objective" => "Child agent objective",
      "depth" => 1,
      "result" => "Child completed"
    }
  ]

  # The same hierarchy with ATOM keys (in-memory data, no DB round-trip).
  @atom_key_archive [
    %{
      agent_id: "agent-1",
      parent_id: nil,
      objective: "Root agent objective",
      depth: 0,
      result: "Root completed"
    },
    %{
      agent_id: "agent-2",
      parent_id: "agent-1",
      objective: "Child agent objective",
      depth: 1,
      result: "Child completed"
    }
  ]

  # A record whose NESTED usage sub-map is string-keyed — exactly as it looks
  # after the DB round-trip (encode_archive/decode_archive is plain
  # Jason.encode/decode, no key re-atomization). Includes a bogus legacy
  # "cost" string key that must NOT become an atom (there is no :cost in the
  # core's usage contract — cost lives in input_cost/output_cost/total_cost).
  @string_key_usage_archive [
    %{
      "agent_id" => "agent-usage",
      "parent_id" => nil,
      "objective" => "Root with usage",
      "depth" => 0,
      "usage" => %{
        "input_tokens" => 1000,
        "output_tokens" => 500,
        "total_tokens" => 1500,
        "cached_tokens" => 200,
        "cache_creation_tokens" => 50,
        "input_cost" => 0.001,
        "output_cost" => 0.002,
        "total_cost" => 0.003,
        "cache_hit_rate" => 0.2,
        "cost" => 0.999
      }
    }
  ]

  describe "ReviewComponents.archive_review_section with string keys" do
    test "renders without hanging and shows agent ids" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @string_key_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      # Both agent ids are present — proving the tree was built correctly
      # from string-keyed data (not silently dropped to nil).
      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end

    test "renders nested parent/child hierarchy correctly" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @string_key_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      # The objective text should render (proving the agent maps were read
      # correctly, not silently nil).
      assert html =~ "Root agent objective"
      assert html =~ "Child agent objective"
    end
  end

  describe "ReviewComponents.archive_review_section with atom keys" do
    test "still works (regression — atom keys must not break)" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @atom_key_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end

  describe "ReviewComponents.archive_review_section — cycle safety" do
    # A cyclic dataset: agent-1 → agent-2 → agent-1.
    # The visited-set guard must prevent infinite recursion.
    @cyclic_archive [
      %{"agent_id" => "agent-1", "parent_id" => "agent-2", "objective" => "Cyclic 1"},
      %{"agent_id" => "agent-2", "parent_id" => "agent-1", "objective" => "Cyclic 2"}
    ]

    test "terminates on cyclic data without infinite recursion" do
      # This must not hang. If the guard is broken it will OOM.
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @cyclic_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      # It renders without error (agents with cyclic parents are simply not
      # reachable from the root, so they may not appear — the key assertion is
      # termination).
      assert is_binary(html)
    end

    # A self-referencing agent: its own parent.
    @self_ref_archive [
      %{"agent_id" => "agent-1", "parent_id" => "agent-1", "objective" => "Self ref"}
    ]

    test "terminates on self-referencing data" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @self_ref_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      assert is_binary(html)
    end
  end

  describe "ArchiveComponents.archive_tree with string keys" do
    test "renders without hanging and shows agent ids" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_tree/1,
          agents: @string_key_archive
        )
        |> rendered_to_string()

      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end

  describe "ArchiveComponents.archive_tree — cycle safety" do
    test "terminates on cyclic data without infinite recursion" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_tree/1,
          agents: @cyclic_archive
        )
        |> rendered_to_string()

      assert is_binary(html)
    end
  end

  describe "ArchiveComponents.archive_details with string keys" do
    test "renders the archive section with agent ids" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @string_key_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end

  describe "normalize_agent_keys/1 with string-keyed nested usage (DB round-trip)" do
    test "atomizes the nested usage sub-map via the real core usage keys" do
      agent = EvoDashWeb.ArchiveHelpers.normalize_agent_keys(hd(@string_key_usage_archive))

      usage = agent[:usage]
      assert is_map(usage)
      # Atom keys the render tiles read are now present with the real values.
      assert usage[:input_tokens] == 1000
      assert usage[:output_tokens] == 500
      assert usage[:total_tokens] == 1500
      assert usage[:cached_tokens] == 200
      assert usage[:cache_creation_tokens] == 50
      assert usage[:input_cost] == 0.001
      assert usage[:output_cost] == 0.002
      assert usage[:total_cost] == 0.003
      assert usage[:cache_hit_rate] == 0.2
      # The bogus top-level "cost" key never becomes an atom (no :cost exists in
      # the core usage contract); unknown keys are preserved string-keyed.
      refute Map.has_key?(usage, :cost)
      assert Map.get(usage, "cost") == 0.999
    end

    test "is idempotent — atom-keyed nested usage (in-memory shape) passes through" do
      agent = EvoDashWeb.ArchiveHelpers.normalize_agent_keys(hd(@string_key_usage_archive))
      again = EvoDashWeb.ArchiveHelpers.normalize_agent_keys(agent)

      # Whitelisted keys stay atom-keyed with the real values on re-normalization.
      assert again[:usage][:total_tokens] == 1500
      assert again[:usage][:total_cost] == 0.003
      assert again[:usage][:cache_hit_rate] == 0.2
      # The preserved unknown "cost" string key also survives untouched.
      assert Map.get(again[:usage], "cost") == 0.999
    end

    test "nil and non-map usage values pass through unchanged" do
      assert EvoDashWeb.ArchiveHelpers.normalize_agent_keys(%{"agent_id" => "x", "usage" => nil})[
               :usage
             ] == nil

      agent =
        EvoDashWeb.ArchiveHelpers.normalize_agent_keys(%{
          "agent_id" => "x",
          "usage" => "not-a-map"
        })

      assert agent[:usage] == "not-a-map"
    end

    test "tree builders produce atom-keyed nested usage maps" do
      [node] = EvoDashWeb.ArchiveHelpers.build_archive_tree(@string_key_usage_archive)
      assert node.agent[:usage][:total_tokens] == 1500
      assert node.agent[:usage][:total_cost] == 0.003

      [{agent, _children}] =
        EvoDashWeb.ArchiveHelpers.build_archive_tree_for_review(@string_key_usage_archive)

      assert agent[:usage][:total_tokens] == 1500
      assert agent[:usage][:total_cost] == 0.003
    end
  end

  describe "ArchiveComponents.archive_tree renders usage tiles from string-keyed usage" do
    test "shows real token counts and total cost (not 0 / $0.000000)" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_tree/1,
          agents: @string_key_usage_archive
        )
        |> rendered_to_string()

      # Token tiles — formatted with thousands separators.
      assert html =~ "1,000"
      assert html =~ "500"
      assert html =~ "1,500"
      # Cost tile — the real total_cost flows through, formatted to 6 decimals.
      assert html =~ "0.003000"
      refute html =~ "0.000000"
    end
  end

  describe "ReviewComponents.archive_review_section renders usage tiles from string-keyed usage" do
    test "shows real token counts and total cost (not 0 / $0.000000)" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @string_key_usage_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      assert html =~ "1,000"
      assert html =~ "500"
      assert html =~ "1,500"
      assert html =~ "0.003000"
      refute html =~ "0.000000"
    end
  end
end
