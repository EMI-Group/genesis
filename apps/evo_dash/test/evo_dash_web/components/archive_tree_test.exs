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

  describe "DashboardComponents.archive_tree with string keys" do
    test "renders without hanging and shows agent ids" do
      html =
        render_component(&EvoDashWeb.DashboardComponents.archive_tree/1,
          agents: @string_key_archive
        )
        |> rendered_to_string()

      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end

  describe "DashboardComponents.archive_tree — cycle safety" do
    test "terminates on cyclic data without infinite recursion" do
      html =
        render_component(&EvoDashWeb.DashboardComponents.archive_tree/1,
          agents: @cyclic_archive
        )
        |> rendered_to_string()

      assert is_binary(html)
    end
  end

  describe "DashboardComponents.archive_details with string keys" do
    test "renders the archive section with agent ids" do
      html =
        render_component(&EvoDashWeb.DashboardComponents.archive_details/1,
          archive_metadata: @string_key_archive,
          task_id: "test-task"
        )
        |> rendered_to_string()

      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end
end
