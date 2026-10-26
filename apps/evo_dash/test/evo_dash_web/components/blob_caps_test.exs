defmodule EvoDashWeb.BlobCapsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ArchiveComponents
  alias EvoDashWeb.ArchiveHelpers
  alias EvoDashWeb.Helpers
  alias EvoDashWeb.ReviewComponents
  alias EvoDashWeb.TaskCardComponents

  # ---------------------------------------------------------------------------
  # Rendering caps that keep the dashboard from rendering unbounded blobs.
  #
  # A single live task carried a 108 MB `result` / `archive_metadata` blob;
  # interpolating it froze the browser on every rerender. Every in-card render
  # site therefore shows a BYTE/ENTRY-bounded preview (with a dim visible note)
  # while the complete text stays reachable only through an explicit action
  # (Full Result modal, copy payload, JSON export).
  #
  # These tests pin the CAPS themselves: the head renders, a tail marker past
  # the cap does NOT reach the visible text, and the note reports the true
  # total. Assertions read `Floki.text/1` (visible text nodes only) rather than
  # the raw HTML, because the 1 MiB copy payload legitimately materializes the
  # whole 100 KB blob inside a `data-content` ATTRIBUTE.
  # ---------------------------------------------------------------------------

  @task_preview_bytes 16_384
  @archive_result_preview_bytes 8_192
  @archive_objective_preview_bytes 4_096
  @review_preview_bytes 16_384
  @review_archive_result_bytes 8_192
  @review_archive_objective_bytes 4_096
  @copy_payload_bytes 1_048_576

  describe "TaskCardComponents.task_card/1 — in-card payload caps" do
    test "expanded card renders only the capped result preview with a byte-count note" do
      tail = "ZZ_RESULT_TAIL_MARKER_ZZ"
      big = String.duplicate("head-line ", 10_000) <> tail
      assert byte_size(big) > 100_000

      # The result lives on the lazily-fetched FULL TaskInfo (`detail.task`),
      # never on the summary map.
      full = task(result: {:ok, %{result: big, commit_sha: "abcdef1234"}})

      text =
        render_component(&TaskCardComponents.task_card/1,
          task: full,
          show_details: true,
          detail: %{state: :ok, task: full}
        )
        |> rendered_text()

      assert text =~ "head-line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@task_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big))} bytes"
    end

    test "expanded card caps the objective preview and notes the true size" do
      tail = "ZZ_OBJECTIVE_TAIL_MARKER_ZZ"
      big = String.duplicate("objective-line ", 8_000) <> tail
      assert byte_size(big) > 100_000

      text =
        render_component(&TaskCardComponents.task_card/1,
          task: task(opts: [prompt: big, mode: "simple"]),
          show_details: true
        )
        |> rendered_text()

      assert text =~ "objective-line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@task_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big))} bytes"
    end

    test "collapsed card never renders the result body" do
      tail = "ZZ_RESULT_TAIL_MARKER_ZZ"
      big = String.duplicate("head-line ", 10_000) <> tail

      text =
        render_component(&TaskCardComponents.task_card/1,
          task: task(result: {:ok, %{result: big, commit_sha: "abcdef1234"}})
        )
        |> rendered_text()

      refute text =~ "head-line"
      refute text =~ tail
      refute text =~ "Agent Message"
    end

    test "render_result_full/1 renders the complete text (explicit Full Result modal path)" do
      tail = "ZZ_RESULT_TAIL_MARKER_ZZ"
      big = String.duplicate("head-line ", 10_000) <> tail

      text =
        {:ok, %{result: big, commit_sha: "abcdef1234"}}
        |> TaskCardComponents.render_result_full()
        |> rendered_text()

      assert text =~ "head-line"
      assert text =~ tail
      # The uncapped modal path renders no truncation note at all.
      refute text =~ "Showing"
    end

    test "the in-card copy payload is capped at 1 MiB and says so in its title" do
      # Just over the 1 MiB cap: the render cost is dominated by the HTML
      # materialization of the copy payload, so keep the source minimal.
      big = String.duplicate("copy-me ", div(@copy_payload_bytes, 8) + 1)
      assert byte_size(big) > @copy_payload_bytes

      full = task(result: {:ok, %{result: big, commit_sha: "abcdef1234"}})

      html =
        render_component(&TaskCardComponents.task_card/1,
          task: full,
          show_details: true,
          detail: %{state: :ok, task: full}
        )

      copy_button = tag_attrs(html, "task-t_blob-result-copy")

      assert byte_size(copy_button["data-content"]) == @copy_payload_bytes

      assert copy_button["title"] =~
               "Copy is limited to the first 1 MB"
    end
  end

  describe "ArchiveComponents.archive_details/1 — record + payload caps" do
    test "renders at most 300 records with the true total and truncates a huge result" do
      tail = "ZZ_ARCHIVE_RESULT_TAIL_MARKER_ZZ"
      big_result = String.duplicate("archive-result-line ", 2_850) <> tail
      assert byte_size(big_result) > 50_000

      records = archive_records(400, big_result: {1, big_result})

      html =
        render_component(&ArchiveComponents.archive_details/1,
          archive_metadata: records,
          task_id: nil
        )

      text = html |> parse() |> Floki.text()

      # Paging is the real bound; the render cap (300) is the second safety net
      # and its note reports the TRUE loaded total (400), not the rendered slice.
      assert text =~ "Showing 300 of 400 agent records"

      # Exactly one record container per rendered record — nothing beyond the cap.
      assert length(Regex.scan(~r/rounded-xl bg-base-100\/60 overflow-hidden/, html)) == 300
      assert text =~ "agent-300"
      refute text =~ "agent-301"

      # The 50 KB result renders its capped prefix plus the note; the tail is gone.
      assert text =~ "archive-result-line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@archive_result_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big_result))} bytes"
    end

    test "caps the per-record objective at 4 KiB" do
      tail = "ZZ_ARCHIVE_OBJECTIVE_TAIL_MARKER_ZZ"
      big_objective = String.duplicate("archive-objective-line ", 2_000) <> tail
      assert byte_size(big_objective) > 40_000

      records = [
        %{
          "agent_id" => "agent-big-objective",
          "parent_id" => nil,
          "objective" => big_objective,
          "result" => "done"
        }
      ]

      text =
        render_component(&ArchiveComponents.archive_details/1,
          archive_metadata: records,
          task_id: nil
        )
        |> rendered_text()

      assert text =~ "archive-objective-line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@archive_objective_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big_objective))} bytes"
    end
  end

  describe "ArchiveHelpers.build_tree_capped/2" do
    test "caps at the default 100 records and reports the true total" do
      capped = ArchiveHelpers.build_tree_capped(flat_archive(300))

      assert capped.total == 300
      assert capped.shown == 100
      assert capped.truncated? == true
      assert length(capped.tree) == 100
      assert hd(capped.tree).agent[:agent_id] == "agent-1"
      assert List.last(capped.tree).agent[:agent_id] == "agent-100"
    end

    test "a list at or below the cap reports no truncation" do
      capped = ArchiveHelpers.build_tree_capped(flat_archive(3))

      assert %{total: 3, shown: 3, truncated?: false} = capped
      assert length(capped.tree) == 3
    end

    test "an explicit max caps the record slice" do
      capped = ArchiveHelpers.build_tree_capped(flat_archive(5), 2)

      assert %{total: 5, shown: 2, truncated?: true} = capped
      assert length(capped.tree) == 2
    end

    test "a zero cap renders no records but still reports the total" do
      capped = ArchiveHelpers.build_tree_capped(flat_archive(3), 0)

      assert %{tree: [], total: 3, shown: 0, truncated?: true} = capped
    end

    test "a negative or garbage max falls back to the default cap" do
      for bad <- [-1, "nope", nil] do
        capped = ArchiveHelpers.build_tree_capped(flat_archive(150), bad)
        assert capped.total == 150
        assert capped.shown == 100
        assert capped.truncated? == true
      end
    end

    test "a non-list input is total: an empty, untruncated result" do
      for bad <- [nil, %{}, "nope", 42] do
        assert ArchiveHelpers.build_tree_capped(bad) ==
                 %{tree: [], total: 0, shown: 0, truncated?: false}
      end
    end

    test "non-map entries are skipped and never counted in the total" do
      capped = ArchiveHelpers.build_tree_capped([record("solo", nil), "junk", 42])

      assert %{total: 1, shown: 1, truncated?: false} = capped
      assert [%{agent: %{agent_id: "solo"}, children: []}] = capped.tree
    end

    test "a parent/child hierarchy is nested under its root" do
      capped = ArchiveHelpers.build_tree_capped([record("root", nil), record("child", "root")])

      assert %{total: 2, shown: 2, truncated?: false} = capped
      assert [%{agent: root, children: [%{agent: child, children: []}]}] = capped.tree
      assert root[:agent_id] == "root"
      assert child[:agent_id] == "child"
    end

    test "parent-less records are PROMOTED to top level and count as shown" do
      capped =
        ArchiveHelpers.build_tree_capped([record("root", nil), record("orphan", "missing")])

      # A paged archive routinely holds records whose parent is on another page:
      # they render as their own top-level node (never silently dropped) and the
      # promotion is not a truncation.
      assert %{total: 2, shown: 2, truncated?: false} = capped

      assert [
               %{agent: %{agent_id: "root"}, children: []},
               %{agent: %{agent_id: "orphan"}, children: []}
             ] = capped.tree
    end

    test "root records fill the slice before their children" do
      # The child appears FIRST in the list; the cap must still keep the root.
      capped = ArchiveHelpers.build_tree_capped([record("child", "root"), record("root", nil)], 1)

      assert %{total: 2, shown: 1, truncated?: true} = capped
      assert [%{agent: %{agent_id: "root"}, children: []}] = capped.tree
    end

    test "a deep chain beyond the cap is bounded to the slice" do
      records =
        [record("a0", nil)] ++
          for(i <- 1..149, do: record("a#{i}", "a#{i - 1}"))

      capped = ArchiveHelpers.build_tree_capped(records)

      assert %{total: 150, shown: 100, truncated?: true} = capped
      assert hd(capped.tree).agent[:agent_id] == "a0"
    end
  end

  describe "ArchiveHelpers.build_review_tree_capped/2" do
    test "returns tuple-shaped nodes and the same cap/total contract" do
      capped = ArchiveHelpers.build_review_tree_capped(flat_archive(3), 2)

      assert %{total: 3, shown: 2, truncated?: true} = capped
      assert [{agent, []}, {_second, []}] = capped.tree
      assert agent[:agent_id] == "agent-1"
    end

    test "nests tuples for a parent/child hierarchy" do
      capped =
        ArchiveHelpers.build_review_tree_capped([record("root", nil), record("child", "root")])

      assert %{total: 2, shown: 2, truncated?: false} = capped
      assert [{%{agent_id: "root"}, [{%{agent_id: "child"}, []}]}] = capped.tree
    end

    test "a non-list input is total: an empty, untruncated result" do
      assert ArchiveHelpers.build_review_tree_capped(nil) ==
               %{tree: [], total: 0, shown: 0, truncated?: false}
    end
  end

  describe "ReviewComponents.agent_summary/1 — report caps" do
    test "markdown view renders the capped prefix plus the byte-count note" do
      tail = "ZZ_SUMMARY_TAIL_MARKER_ZZ"
      big = String.duplicate("summary body line\n", 6_000) <> tail
      assert byte_size(big) > 100_000

      text =
        render_component(&ReviewComponents.agent_summary/1, summary: big, summary_raw: false)
        |> rendered_text()

      assert text =~ "summary body line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@review_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big))} bytes"
    end

    test "raw view shares the same cap and note" do
      tail = "ZZ_SUMMARY_RAW_TAIL_MARKER_ZZ"
      big = String.duplicate("raw summary body line\n", 5_000) <> tail

      text =
        render_component(&ReviewComponents.agent_summary/1, summary: big, summary_raw: true)
        |> rendered_text()

      assert text =~ "raw summary body line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@review_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big))} bytes"
    end

    test "the copy payload is capped at 1 MiB and hints at the cap" do
      # Just over the 1 MiB cap (see the sibling in-card test).
      big = String.duplicate("copy-me ", div(@copy_payload_bytes, 8) + 1)
      assert byte_size(big) > @copy_payload_bytes

      html =
        render_component(&ReviewComponents.agent_summary/1, summary: big, summary_raw: true)

      copy_button = tag_attrs(html, "summary-copy-btn")

      assert byte_size(copy_button["data-content"]) == @copy_payload_bytes

      assert copy_button["title"] =~
               "Copy is limited to the first 1 MB"
    end
  end

  describe "ReviewComponents.objective_section/1 — objective caps" do
    test "caps the objective preview and notes the true size" do
      tail = "ZZ_OBJECTIVE_SECTION_TAIL_MARKER_ZZ"
      big = String.duplicate("objective body line\n", 6_000) <> tail

      text =
        render_component(&ReviewComponents.objective_section/1,
          objective: big,
          objective_raw: true
        )
        |> rendered_text()

      assert text =~ "objective body line"
      refute text =~ tail

      assert text =~
               "Showing #{Helpers.format_number(@review_preview_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big))} bytes"
    end
  end

  describe "ReviewComponents.archive_review_section/1 — record caps" do
    test "renders at most 300 records with the true loaded total and truncates huge payloads" do
      result_tail = "ZZ_REVIEW_ARCHIVE_RESULT_TAIL_ZZ"
      objective_tail = "ZZ_REVIEW_ARCHIVE_OBJECTIVE_TAIL_ZZ"
      big_result = String.duplicate("review-archive-result ", 2_500) <> result_tail
      big_objective = String.duplicate("review-archive-objective ", 2_000) <> objective_tail

      records =
        archive_records(400,
          big_result: {1, big_result},
          big_objective: {1, big_objective}
        )

      text =
        render_component(&ReviewComponents.archive_review_section/1,
          archive_metadata: records,
          task_id: "test-task"
        )
        |> rendered_text()

      # No :total is passed, so the header falls back to the loaded count.
      assert text =~ "400 agents"

      # Paging is the real bound; the render cap (300) is the second safety net
      # and its note reports the TRUE loaded total (400), not the rendered slice.
      assert text =~ "Showing 300 of 400 agent records"
      assert text =~ "agent-300"
      refute text =~ "agent-301"

      assert text =~ "review-archive-result"
      refute text =~ result_tail
      refute text =~ objective_tail

      assert text =~
               "Showing #{Helpers.format_number(@review_archive_result_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big_result))} bytes"

      assert text =~
               "Showing #{Helpers.format_number(@review_archive_objective_bytes)} of " <>
                 "#{Helpers.format_number(byte_size(big_objective))} bytes"
    end
  end

  # --- fixtures & helpers ---

  # Completed-task map in the post-Codec-decoded shape (ATOM keys).
  defp task(overrides) do
    Map.merge(
      %{
        id: "t_blob",
        type: :evolve,
        status: :completed,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        agent_count: 1,
        model_id: nil,
        opts: [prompt: "Big blob task", mode: "simple"],
        result: {:ok, %{result: "small result", commit_sha: "abcdef1234"}}
      },
      Map.new(overrides)
    )
  end

  # One archive record map (STRING keys — the post-JSON round-trip shape).
  defp record(agent_id, parent_id) do
    %{
      "agent_id" => agent_id,
      "parent_id" => parent_id,
      "objective" => "objective of #{agent_id}",
      "result" => "result of #{agent_id}",
      "depth" => if(parent_id, do: 1, else: 0)
    }
  end

  defp flat_archive(count), do: for(i <- 1..count, do: record("agent-#{i}", nil))

  # N root records with optional per-index overrides:
  # `big_result: {index, text}` / `big_objective: {index, text}`.
  defp archive_records(count, opts) do
    Enum.map(1..count, fn i ->
      rec = record("agent-#{i}", nil)

      rec
      |> maybe_override("result", Keyword.get(opts, :big_result), i)
      |> maybe_override("objective", Keyword.get(opts, :big_objective), i)
    end)
  end

  defp maybe_override(rec, _key, nil, _index), do: rec

  defp maybe_override(rec, key, {index, text}, index), do: Map.put(rec, key, text)
  defp maybe_override(rec, _key, {_index, _text}, _other), do: rec

  # Render a function component and extract its VISIBLE text nodes. Raw HTML
  # would also include the (legitimately uncapped-up-to-1-MiB) copy payload in
  # a `data-content` attribute, which is not part of the rendered body.
  defp rendered_text(rendered) when is_binary(rendered),
    do: rendered |> parse() |> Floki.text()

  defp rendered_text(rendered),
    do: rendered |> rendered_to_string() |> parse() |> Floki.text()

  # Floki's mochiweb parser takes ~250 ms on a document that carries a 1 MiB
  # attribute (super-linear attribute parsing), and two tests below legitimately
  # materialize a 1 MiB `data-content` payload. Read that ONE element's
  # attributes straight off the REAL rendered HTML instead of parsing the whole
  # document: Phoenix escapes `"`/`>` inside attribute values, so the opening
  # tag ends at the first raw `>` and each value at the first raw `"`.
  defp tag_attrs(html, id) do
    {id_pos, _} = :binary.match(html, ~s(id="#{id}"))
    {tag_len, _} = :binary.match(html, ">", scope: {id_pos, byte_size(html) - id_pos})
    tag = binary_part(html, id_pos, tag_len)

    for attr <- ["data-content", "title"], into: %{} do
      case :binary.match(tag, attr <> "=\"") do
        {pos, len} ->
          start = pos + len
          {stop, _} = :binary.match(tag, "\"", scope: {start, byte_size(tag) - start})
          {attr, binary_part(tag, start, stop - start)}

        :nomatch ->
          {attr, nil}
      end
    end
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
