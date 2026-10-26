defmodule EvoDashWeb.ArchiveTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ArchiveHelpers

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

      # It renders without error. Both records sit in a cycle with no root, so
      # neither is reachable from a root — orphan promotion renders each of them
      # exactly once as its own top-level node (the key assertion is
      # termination, not the shape).
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

  # A paged archive page: entries carry NO "result" key (the paged read omits it
  # unless results are explicitly requested) and may reference a parent that sits
  # on a page which is not loaded.
  @paged_entries [
    %{"agent_id" => "page-root", "parent_id" => nil, "depth" => 0, "objective" => "paged root"},
    %{
      "agent_id" => "page-orphan",
      "parent_id" => "not-loaded",
      "depth" => 2,
      "objective" => "paged orphan"
    }
  ]

  describe "ArchiveComponents.archive_details/1 — paged archive envelope" do
    test "labels the loaded page against the TRUE total" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 7_149,
          task_id: "t1"
        )

      text = Floki.text(Floki.parse_document!(html))

      # 1–2 of 7,149 — one-based inclusive bounds of what is loaded.
      assert text =~ "7,149 agents — showing 1–2"
    end

    test "labels the archive with its total once everything is loaded" do
      text =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          task_id: "t1"
        )
        |> rendered_text()

      assert text =~ "2 agents"
      refute text =~ "showing"
    end

    test "falls back to the loaded count when no total is supplied" do
      text =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          task_id: "t1"
        )
        |> rendered_text()

      assert text =~ "2 agents"
    end

    test "renders a Load more button only while more pages exist, wired to the task" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 7_149,
          task_id: "task-42"
        )

      assert html =~ ~s(phx-click="load_more_task_archive")
      assert html =~ ~s(phx-value-task-id="task-42")
      assert html =~ "Load more"
      refute html =~ "Loading…"

      # Once everything is loaded there is nothing left to fetch.
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          task_id: "task-42"
        )

      refute html =~ ~s(phx-click="load_more_task_archive")
      refute html =~ "Load more"
    end

    test "the Load more button is disabled and shows a spinner while a page is in flight" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 7_149,
          loading_more?: true,
          task_id: "task-42"
        )

      [button] =
        Floki.find(Floki.parse_document!(html), ~s(button[phx-click="load_more_task_archive"]))

      assert Floki.attribute(button, "disabled") == ["disabled"]
      assert Floki.text(button) =~ "Loading…"
    end

    test "an append failure keeps the page and offers the same event as Retry" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 7_149,
          more_error: :boom,
          task_id: "task-42"
        )

      text = Floki.text(Floki.parse_document!(html))

      assert text =~ "Could not load more archive pages."
      assert text =~ "Retry"
      assert text =~ "page-root"

      assert length(
               Floki.find(Floki.parse_document!(html), ~s([phx-click="load_more_task_archive"]))
             ) == 2
    end

    test "a paged entry without a result offers Show result instead of an empty block" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          task_id: "task-42"
        )

      doc = Floki.parse_document!(html)

      assert html =~ ~s(phx-click="load_task_archive_agent_result")
      assert html =~ ~s(phx-value-agent-id="page-root")
      assert html =~ "Show result"
      # No Result header is rendered while nothing was fetched.
      refute Floki.text(doc) =~ "Result"
    end

    test "a per-agent result load renders its spinner, then its capped result" do
      loading =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          agent_results: %{"page-root" => %{state: :loading, entry: nil, error: nil}},
          task_id: "task-42"
        )
        |> rendered_text()

      assert loading =~ "Loading result…"
      # Only the requested agent is loading; the other still offers the button.
      assert loading =~ "Show result"

      tail = "ZZ_LAZY_RESULT_TAIL_ZZ"
      big = String.duplicate("lazy-result-line ", 1_000) <> tail
      assert byte_size(big) > 8_192

      loaded =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          agent_results: %{
            "page-root" => %{
              state: :ok,
              entry: %{"agent_id" => "page-root", "result" => big},
              error: nil
            }
          },
          task_id: "task-42"
        )
        |> rendered_text()

      assert loaded =~ "lazy-result-line"
      refute loaded =~ tail
      assert loaded =~ "Showing 8,192 of"
    end

    test "a failed per-agent result load renders the retry-able error line" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          agent_results: %{"page-root" => %{state: :error, entry: nil, error: :boom}},
          task_id: "task-42"
        )

      assert html =~ "Could not load this agent&#39;s result."
      assert html =~ ~s(phx-click="load_task_archive_agent_result")
      assert html =~ "Retry"
    end

    test "an entry that already carries its result renders it without a button" do
      text =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: [
            %{"agent_id" => "with-result", "parent_id" => nil, "result" => "inline result body"}
          ],
          total: 1,
          task_id: "task-42"
        )
        |> rendered_text()

      assert text =~ "inline result body"
      refute text =~ "Show result"
    end

    test "renders a record whose parent lives on an unloaded page (orphan promotion)" do
      text =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @paged_entries,
          total: 2,
          task_id: "task-42"
        )
        |> rendered_text()

      assert text =~ "page-root"
      assert text =~ "page-orphan"
      assert text =~ "paged orphan"
    end
  end

  # The archive "Export JSON" link is node-aware: callers hand in an
  # `export_url` that already carries `?node=<target_id>` on a remote node, and
  # a nil `export_url` keeps the bare task export path (local node).
  describe "archive export link (node-aware)" do
    test "archive_details/1 uses an explicit export_url" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @string_key_archive,
          task_id: "task-42",
          export_url: "/tasks/task-42/export?node=remote-1"
        )

      [link] = export_links(html)
      assert Floki.attribute(link, "href") == ["/tasks/task-42/export?node=remote-1"]
      # The download affordance is untouched by the node-aware href.
      assert Floki.attribute(link, "download") == ["download"]
    end

    test "archive_details/1 falls back to the bare task export path" do
      html =
        render_component(&EvoDashWeb.ArchiveComponents.archive_details/1,
          archive_metadata: @string_key_archive,
          task_id: "task-42"
        )

      assert export_hrefs(html) == ["/tasks/task-42/export"]
    end

    test "archive_review_section/1 uses an explicit export_url" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @string_key_archive,
          task_id: "task-42",
          export_url: "/tasks/task-42/export?node=remote-1"
        )

      [link] = export_links(html)
      assert Floki.attribute(link, "href") == ["/tasks/task-42/export?node=remote-1"]
      assert Floki.attribute(link, "download") == ["download"]
    end

    test "archive_review_section/1 falls back to the bare task export path" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.archive_review_section/1,
          archive_metadata: @string_key_archive,
          task_id: "task-42"
        )

      assert export_hrefs(html) == ["/tasks/task-42/export"]
    end
  end

  # Render a component and extract only its VISIBLE text (raw HTML would also
  # carry attribute payloads). `render_component/2` already returns the rendered
  # HTML string, so no `rendered_to_string/1` is needed here.
  defp rendered_text(html) when is_binary(html),
    do: html |> Floki.parse_document!() |> Floki.text()

  # Every archive export anchor of a rendered component.
  defp export_links(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(a[href*="/export"]))
  end

  defp export_hrefs(html), do: html |> export_links() |> Floki.attribute("href")

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
      %{tree: [node]} = EvoDashWeb.ArchiveHelpers.build_tree_capped(@string_key_usage_archive)
      assert node.agent[:usage][:total_tokens] == 1500
      assert node.agent[:usage][:total_cost] == 0.003

      %{tree: [{agent, _children}]} =
        EvoDashWeb.ArchiveHelpers.build_review_tree_capped(@string_key_usage_archive)

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
      # Best-effort cost caveat renders at the cost site.
      assert html =~ "best-effort estimate"
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
      # Best-effort cost caveat renders at the cost site.
      assert html =~ "best-effort estimate"
    end
  end

  # ---------------------------------------------------------------------------
  # PARTIAL (paged) archive support
  #
  # The dashboard now receives ONE page of the per-agent archive at a time
  # (`%{entries: [...], total: n}`, entries STRING-keyed, ordered by
  # `depth, agent_id`) and each entry's heavy "result" is absent until it is
  # fetched on demand. A page therefore routinely contains records whose parent
  # lives on a page that has not been loaded.
  # ---------------------------------------------------------------------------

  describe "build_tree_capped/2 — orphan-parent promotion" do
    test "renders a record whose parent is not in the slice as a top-level node" do
      capped =
        ArchiveHelpers.build_tree_capped([
          %{"agent_id" => "root", "parent_id" => nil},
          %{"agent_id" => "orphan", "parent_id" => "missing-page"}
        ])

      # The orphan is NOT silently dropped: it renders and it counts as shown.
      assert %{total: 2, shown: 2, truncated?: false} = capped
      assert [root_node, orphan_node] = capped.tree
      assert root_node.agent[:agent_id] == "root"
      assert orphan_node.agent[:agent_id] == "orphan"
      assert orphan_node.children == []
    end

    test "a promoted orphan whose children ARE loaded still renders its subtree" do
      capped =
        ArchiveHelpers.build_tree_capped([
          %{"agent_id" => "orphan", "parent_id" => "missing-page"},
          %{"agent_id" => "kid", "parent_id" => "orphan"},
          %{"agent_id" => "grandkid", "parent_id" => "kid"}
        ])

      assert %{total: 3, shown: 3, truncated?: false} = capped

      assert [
               %{
                 agent: %{agent_id: "orphan"},
                 children: [
                   %{
                     agent: %{agent_id: "kid"},
                     children: [%{agent: %{agent_id: "grandkid"}, children: []}]
                   }
                 ]
               }
             ] = capped.tree
    end

    test "a page where EVERY record is an orphan renders each record exactly once" do
      records =
        for i <- 1..5 do
          %{"agent_id" => "orphan-#{i}", "parent_id" => "page-not-loaded-#{i}"}
        end

      capped = ArchiveHelpers.build_tree_capped(records)

      assert %{total: 5, shown: 5, truncated?: false} = capped

      assert Enum.map(capped.tree, & &1.agent[:agent_id]) ==
               ~w(orphan-1 orphan-2 orphan-3 orphan-4 orphan-5)

      assert Enum.all?(capped.tree, &(&1.children == []))
    end

    test "real roots come first in input order, then promoted orphans in input order" do
      records = [
        %{"agent_id" => "orphan-a", "parent_id" => "gone"},
        %{"agent_id" => "root-b", "parent_id" => nil},
        %{"agent_id" => "root-c", "parent_id" => ""},
        %{"agent_id" => "orphan-d", "parent_id" => "gone"}
      ]

      capped = ArchiveHelpers.build_tree_capped(records)

      # Deterministic: the same page always builds the same tree.
      assert capped == ArchiveHelpers.build_tree_capped(records)

      assert Enum.map(capped.tree, & &1.agent[:agent_id]) ==
               ~w(root-b root-c orphan-a orphan-d)

      # Orphans are top-level peers of the roots, not children of them.
      assert Enum.all?(capped.tree, &(&1.children == []))
    end

    test "a self-parenting record renders exactly once" do
      capped = ArchiveHelpers.build_tree_capped([%{"agent_id" => "self", "parent_id" => "self"}])

      assert %{total: 1, shown: 1, truncated?: false} = capped
      assert [%{agent: %{agent_id: "self"}, children: []}] = capped.tree
    end

    test "a 2-cycle renders each record exactly once, without infinite recursion" do
      capped =
        ArchiveHelpers.build_tree_capped([
          %{"agent_id" => "loop-a", "parent_id" => "loop-b"},
          %{"agent_id" => "loop-b", "parent_id" => "loop-a"}
        ])

      assert %{total: 2, shown: 2, truncated?: false} = capped

      # loop-a is promoted first (input order) and owns loop-b as its child; the
      # back-edge to loop-a is cut by the visited guard.
      assert [
               %{
                 agent: %{agent_id: "loop-a"},
                 children: [%{agent: %{agent_id: "loop-b"}, children: []}]
               }
             ] = capped.tree
    end

    test "promotion never grows the capped slice" do
      records =
        for i <- 1..5 do
          %{"agent_id" => "orphan-#{i}", "parent_id" => "page-not-loaded"}
        end

      capped = ArchiveHelpers.build_tree_capped(records, 2)

      assert %{total: 5, shown: 2, truncated?: true} = capped
      assert length(capped.tree) == 2
      assert Enum.map(capped.tree, & &1.agent[:agent_id]) == ~w(orphan-1 orphan-2)
    end

    test "a page whose parent is in the list is still nested, not promoted" do
      capped =
        ArchiveHelpers.build_tree_capped([
          %{"agent_id" => "root", "parent_id" => nil},
          %{"agent_id" => "child", "parent_id" => "root"}
        ])

      assert %{total: 2, shown: 2, truncated?: false} = capped

      assert [
               %{
                 agent: %{agent_id: "root"},
                 children: [%{agent: %{agent_id: "child"}, children: []}]
               }
             ] = capped.tree
    end
  end

  describe "build_review_tree_capped/2 — orphan-parent promotion" do
    test "promotes orphans into tuple-shaped nodes with the same envelope" do
      capped =
        ArchiveHelpers.build_review_tree_capped([
          %{"agent_id" => "orphan", "parent_id" => "missing-page"},
          %{"agent_id" => "kid", "parent_id" => "orphan"}
        ])

      assert %{total: 2, shown: 2, truncated?: false} = capped
      assert [{%{agent_id: "orphan"}, [{%{agent_id: "kid"}, []}]}] = capped.tree
    end

    test "a cycle renders exactly once as tuple nodes" do
      capped =
        ArchiveHelpers.build_review_tree_capped([
          %{"agent_id" => "loop-a", "parent_id" => "loop-b"},
          %{"agent_id" => "loop-b", "parent_id" => "loop-a"}
        ])

      assert %{total: 2, shown: 2} = capped
      assert [{%{agent_id: "loop-a"}, [{%{agent_id: "loop-b"}, []}]}] = capped.tree
    end
  end

  describe "result_loaded?/1" do
    test "false when the result key is ABSENT (not fetched yet)" do
      refute ArchiveHelpers.result_loaded?(%{"agent_id" => "a", "objective" => "o"})
      refute ArchiveHelpers.result_loaded?(%{agent_id: "a", objective: "o"})
    end

    test "true when the result key is PRESENT, even when the value is empty" do
      # present-but-nil / present-but-empty means "fetched and genuinely empty".
      assert ArchiveHelpers.result_loaded?(%{"result" => nil})
      assert ArchiveHelpers.result_loaded?(%{result: ""})
      assert ArchiveHelpers.result_loaded?(%{"result" => "done"})
      assert ArchiveHelpers.result_loaded?(%{"agent_id" => "a", "result" => nil})
    end

    test "false for non-map input" do
      for bad <- [nil, "result", 42, [:result], []] do
        refute ArchiveHelpers.result_loaded?(bad)
      end
    end
  end

  describe "merge_entry/2" do
    test "replaces the matching entry in place, preserving list order" do
      page = [
        %{"agent_id" => "a", "depth" => 0},
        %{"agent_id" => "b", "depth" => 1},
        %{"agent_id" => "c", "depth" => 1}
      ]

      full = %{"agent_id" => "b", "depth" => 1, "result" => "child done"}
      merged = ArchiveHelpers.merge_entry(page, full)

      assert Enum.map(merged, & &1["agent_id"]) == ~w(a b c)
      assert Enum.at(merged, 0) == Enum.at(page, 0)
      assert Enum.at(merged, 1) == full
      assert Enum.at(merged, 2) == Enum.at(page, 2)
      refute ArchiveHelpers.result_loaded?(Enum.at(page, 1))
      assert ArchiveHelpers.result_loaded?(Enum.at(merged, 1))
    end

    test "folds an atom-keyed full entry into a string-keyed page" do
      page = [%{"agent_id" => "a"}, %{"agent_id" => "b"}]
      full = %{agent_id: "b", result: "done"}

      merged = ArchiveHelpers.merge_entry(page, full)

      assert length(merged) == 2
      assert Enum.at(merged, 1) == full
      assert ArchiveHelpers.result_loaded?(Enum.at(merged, 1))
      refute ArchiveHelpers.result_loaded?(Enum.at(merged, 0))
    end

    test "no-ops on an unknown agent_id" do
      page = [%{"agent_id" => "a"}, %{"agent_id" => "b"}]

      assert ArchiveHelpers.merge_entry(page, %{"agent_id" => "zzz", "result" => "x"}) == page
    end

    test "no-ops on a full entry without a usable agent_id" do
      page = [%{"agent_id" => "a"}, %{"agent_id" => nil}]

      assert ArchiveHelpers.merge_entry(page, %{"agent_id" => nil, "result" => "x"}) == page
      assert ArchiveHelpers.merge_entry(page, %{"result" => "x"}) == page
    end

    test "leaves non-map page entries untouched" do
      page = ["junk", 42, %{"agent_id" => "a"}]
      full = %{"agent_id" => "a", "result" => "r"}

      merged = ArchiveHelpers.merge_entry(page, full)

      assert [junk, forty_two, last] = merged
      assert junk == "junk"
      assert forty_two == 42
      assert last == full
    end

    test "returns the first argument unchanged when it is not a list or the full entry is not a map" do
      assert ArchiveHelpers.merge_entry(nil, %{"agent_id" => "a"}) == nil
      assert ArchiveHelpers.merge_entry(%{}, %{"agent_id" => "a"}) == %{}

      page = [%{"agent_id" => "a"}]
      assert ArchiveHelpers.merge_entry(page, nil) == page
      assert ArchiveHelpers.merge_entry(page, "junk") == page
    end
  end

  describe "page_bounds/2" do
    test "nothing loaded reports {0, 0}" do
      assert ArchiveHelpers.page_bounds(0, 7149) == {0, 0}
      assert ArchiveHelpers.page_bounds(0, 0) == {0, 0}
    end

    test "a loaded page reports the 1-based inclusive bounds" do
      assert ArchiveHelpers.page_bounds(100, 7149) == {1, 100}
      assert ArchiveHelpers.page_bounds(200, 7149) == {1, 200}
    end

    test "the last bound is clamped to the total" do
      assert ArchiveHelpers.page_bounds(200, 150) == {1, 150}
      assert ArchiveHelpers.page_bounds(150, 150) == {1, 150}
    end

    test "negative or garbage input reports {0, 0}" do
      for {loaded, total} <- [
            {-1, 7149},
            {100, -1},
            {-1, -1},
            {nil, 7149},
            {100, nil},
            {"100", 7149},
            {100, "7149"},
            {:nope, :nope}
          ] do
        assert ArchiveHelpers.page_bounds(loaded, total) == {0, 0}
      end
    end
  end
end
