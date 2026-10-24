defmodule EvoGit.Agent.ContextBuilderTest do
  @moduledoc """
  Pure-function unit tests for `EvoGit.Agent.ContextBuilder`'s turn-tagging and
  creation-time timestamp stamping helpers, plus its prompt section builders
  (foreign-repos, repo-notes, and delegation-authority sections).

  Timestamps are Unix seconds (`System.system_time(:second)`). Idempotence
  assertions use deterministic pre-stamped values so they never race with `now`.

  `async: true` — every case is a pure function over in-memory values; no
  shared/global state is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Core.ForeignRepo

  # Distinctive past Unix-seconds value — far from any real `now`.
  @old_ts 1_600_000_000

  defp message(role, overrides \\ []) do
    defaults = [role: role, content: [ReqLLM.Message.ContentPart.text("hello")]]
    struct!(ReqLLM.Message, Keyword.merge(defaults, overrides))
  end

  describe "tag_message_turn/2" do
    test "stamps metadata[:timestamp] (Unix seconds) alongside :turn" do
      before = System.system_time(:second)

      msg = ContextBuilder.tag_message_turn(message(:user), 3)
      after_ = System.system_time(:second)

      assert msg.metadata[:turn] == 3
      ts = msg.metadata[:timestamp]
      assert is_integer(ts), "expected integer timestamp, got: #{inspect(ts)}"
      assert ts >= before and ts <= after_
    end

    test "preserves an already-present timestamp (idempotent)" do
      msg = message(:user, metadata: %{timestamp: @old_ts, turn: 1})

      tagged = ContextBuilder.tag_message_turn(msg, 2)

      assert tagged.metadata[:timestamp] == @old_ts
      assert tagged.metadata[:turn] == 2
    end

    test "tolerates metadata: nil" do
      msg = ContextBuilder.tag_message_turn(message(:user, metadata: nil), 1)

      assert msg.metadata[:turn] == 1
      assert is_integer(msg.metadata[:timestamp])
    end
  end

  describe "tag_message_timestamp/1" do
    test "stamps a single message with a Unix-seconds timestamp" do
      before = System.system_time(:second)

      msg = ContextBuilder.tag_message_timestamp(message(:user))
      after_ = System.system_time(:second)

      ts = msg.metadata[:timestamp]
      assert is_integer(ts), "expected integer timestamp, got: #{inspect(ts)}"
      assert ts >= before and ts <= after_
    end

    test "is idempotent — keeps an already-present timestamp" do
      msg = message(:user, metadata: %{timestamp: @old_ts})

      assert ContextBuilder.tag_message_timestamp(msg).metadata[:timestamp] == @old_ts
    end

    test "tolerates metadata: nil" do
      msg = ContextBuilder.tag_message_timestamp(message(:user, metadata: nil))

      assert is_integer(msg.metadata[:timestamp])
    end
  end

  describe "tag_context_tail_with_turn/2" do
    test "stamps the last message only" do
      context = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts, turn: 1}),
          message(:assistant)
        ]
      }

      tagged = ContextBuilder.tag_context_tail_with_turn(context, 2)

      [m1, m2] = tagged.messages
      # Covered (tail) message: gets the new turn + a fresh timestamp.
      assert m2.metadata[:turn] == 2
      assert is_integer(m2.metadata[:timestamp])
      # Already-stamped message keeps its exact timestamp.
      assert m1.metadata[:timestamp] == @old_ts
      assert m1.metadata[:turn] == 1
    end

    test "an already-stamped tail keeps its exact timestamp" do
      context = %ReqLLM.Context{
        messages: [message(:assistant, metadata: %{timestamp: @old_ts, turn: 1})]
      }

      tagged = ContextBuilder.tag_context_tail_with_turn(context, 2)

      [msg] = tagged.messages
      assert msg.metadata[:timestamp] == @old_ts
      assert msg.metadata[:turn] == 2
    end

    test "handles an empty messages list" do
      context = %ReqLLM.Context{messages: []}

      assert ContextBuilder.tag_context_tail_with_turn(context, 1) == context
    end
  end

  describe "tag_context_messages_with_turn/2" do
    test "stamps every message with the turn and an integer timestamp" do
      context = %ReqLLM.Context{messages: [message(:user), message(:assistant), message(:user)]}

      tagged = ContextBuilder.tag_context_messages_with_turn(context, 0)

      for msg <- tagged.messages do
        assert msg.metadata[:turn] == 0
        assert is_integer(msg.metadata[:timestamp])
      end
    end

    test "already-stamped messages keep their exact timestamps" do
      context = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts}),
          message(:assistant, metadata: %{timestamp: @old_ts + 1})
        ]
      }

      tagged = ContextBuilder.tag_context_messages_with_turn(context, 4)

      [m1, m2] = tagged.messages
      assert m1.metadata[:timestamp] == @old_ts
      assert m2.metadata[:timestamp] == @old_ts + 1
      assert m1.metadata[:turn] == 4
      assert m2.metadata[:turn] == 4
    end

    test "handles an empty messages list" do
      context = %ReqLLM.Context{messages: []}

      assert ContextBuilder.tag_context_messages_with_turn(context, 1) == context
    end
  end

  describe "build_repo_notes_section/1" do
    @rendered_notes """
    ## Git Submodules

    This repository has git submodules at:
    - `vendor/Sub`

    In agent worktrees these paths arrive as **empty placeholder directories** (same as native `git worktree add`). If your task needs their content, populate them with:

        git submodule update --init [--recursive]

    (requires network; the clone is shared across worktrees in `.git/modules`). Never delete the placeholder dirs — they are tracked gitlinks (`git clean -fd` won't remove them) — and do not create files inside them to "fill in" content. Changes inside a submodule belong to the submodule repo itself, not the superproject: do not commit inside submodules as part of this task.
    """

    test "returns the rendered text as-is (trimmed) when present" do
      assert ContextBuilder.build_repo_notes_section(@rendered_notes) ==
               String.trim(@rendered_notes)
    end

    test "returns empty string for nil" do
      assert ContextBuilder.build_repo_notes_section(nil) == ""
    end

    test "returns empty string for blank/whitespace-only text" do
      assert ContextBuilder.build_repo_notes_section("   \n  ") == ""
      assert ContextBuilder.build_repo_notes_section("") == ""
    end

    test "combined context body omits the section when repo_notes is nil (blank-filter)" do
      context_tree = "Current Repository: /tmp/repo"

      body =
        [
          context_tree,
          ContextBuilder.build_foreign_repos_section([]),
          ContextBuilder.build_repo_notes_section(nil)
        ]
        |> Enum.reject(&ContextBuilder.blank?/1)
        |> Enum.join("\n\n")

      refute body =~ "## Git Submodules"
      assert body == context_tree
    end

    test "combined context body includes the section when repo_notes is present" do
      context_tree = "Current Repository: /tmp/repo"

      body =
        [
          context_tree,
          ContextBuilder.build_foreign_repos_section([]),
          ContextBuilder.build_repo_notes_section(@rendered_notes)
        ]
        |> Enum.reject(&ContextBuilder.blank?/1)
        |> Enum.join("\n\n")

      assert body =~ "## Git Submodules"
      assert body =~ "- `vendor/Sub`"
      assert body =~ "git submodule update --init"
    end
  end

  describe "build_foreign_repos_section/1" do
    test "returns an empty string when there are no non-primary foreign repos" do
      assert ContextBuilder.build_foreign_repos_section([]) == ""

      assert ContextBuilder.build_foreign_repos_section([
               ForeignRepo.new("primary", "/tmp/primary")
             ]) == ""
    end

    test "writable repo row contains BOTH its root and its persistent worktree path" do
      repo = ForeignRepo.new("orig", "/tmp/orig", writable: true, description: "The original")
      section = ContextBuilder.build_foreign_repos_section([repo])

      assert section =~
               "| :orig | /tmp/orig (worktree: /tmp/orig/.genesis/foreign_repos/orig) | The original |"
    end

    test "read-only repo row contains only the root (no worktree string)" do
      repo = ForeignRepo.new("ref", "/tmp/ref", description: "A reference")
      section = ContextBuilder.build_foreign_repos_section([repo])

      assert section =~ "| :ref | /tmp/ref | A reference |"
      refute section =~ "worktree"
    end

    test "no writable repos → output is byte-identical to the legacy form (no 'worktree' substring)" do
      repos = [
        ForeignRepo.new("primary", "/tmp/primary"),
        ForeignRepo.new("ref", "/tmp/ref", description: "A reference"),
        ForeignRepo.new("no_desc", "/tmp/no_desc")
      ]

      expected =
        "# Foreign Repositories\n\n" <>
          "| ID | Path | Description |\n|------|------|-------------|\n" <>
          "| :ref | /tmp/ref | A reference |\n| :no_desc | /tmp/no_desc | (no description) |\n\n" <>
          "Use absolute paths (e.g., `/tmp/ref`) when delegating to foreign repositories."

      assert ContextBuilder.build_foreign_repos_section(repos) == expected
      refute ContextBuilder.build_foreign_repos_section(repos) =~ "worktree"
    end

    test "writable repo also appends the root-vs-worktree clarification sentence" do
      repo = ForeignRepo.new("orig", "/tmp/orig", writable: true)
      section = ContextBuilder.build_foreign_repos_section([repo])

      assert section =~
               "For a writable foreign repo, the repo root is where delegated write work happens; " <>
                 "the worktree is a read-only checkout of the latest committed state."
    end
  end

  describe "build_authority_section/1" do
    test "repo_less: true always returns an empty string, even with a writable non-primary foreign repo" do
      foreign_repos = [ForeignRepo.new("ref", "/tmp/ref", writable: true)]

      assert ContextBuilder.build_authority_section(%{
               parent_id: nil,
               repo_less: true,
               foreign_repos: foreign_repos
             }) == ""
    end

    test "returns an empty string when there are no non-primary foreign repos" do
      assert ContextBuilder.build_authority_section(%{
               parent_id: nil,
               repo_less: false,
               foreign_repos: []
             }) == ""

      primary_only = [ForeignRepo.new("primary", "/tmp/primary")]

      assert ContextBuilder.build_authority_section(%{
               parent_id: nil,
               repo_less: false,
               foreign_repos: primary_only
             }) == ""
    end

    test "root agent (nil parent_id) with non-primary foreign repos gets the ROOT block" do
      # Primary-only + non-primary mixed list still yields the ROOT block.
      foreign_repos = [
        ForeignRepo.new("primary", "/tmp/primary"),
        ForeignRepo.new("ref", "/tmp/ref", writable: true)
      ]

      section =
        ContextBuilder.build_authority_section(%{
          parent_id: nil,
          repo_less: false,
          foreign_repos: foreign_repos
        })

      assert section != ""
      assert section =~ "ROOT agent"
      assert section =~ "You MAY spawn write-capable"
      assert section =~ "one at a time"
      refute section =~ "NESTED"
    end

    test "nested agent (integer parent_id) with a non-primary foreign repo gets the NESTED block" do
      foreign_repos = [
        ForeignRepo.new("primary", "/tmp/primary"),
        ForeignRepo.new("ref", "/tmp/ref", writable: true)
      ]

      section =
        ContextBuilder.build_authority_section(%{
          parent_id: 7,
          repo_less: false,
          foreign_repos: foreign_repos
        })

      assert section != ""
      assert section =~ "NESTED agent"
      assert section =~ "NOT the root agent"
      assert section =~ "may NOT spawn write-capable"
      assert section =~ "report the need back up to your parent agent"
      refute section =~ "You MAY spawn write-capable"
    end
  end

  describe "build_quality_guidance_section/1" do
    test "root agent (nil parent_id) + \"fast\" returns the FAST block" do
      section =
        ContextBuilder.build_quality_guidance_section(%{
          parent_id: nil,
          repo_less: false,
          quality_level: "fast"
        })

      assert section != ""
      assert section =~ "FAST"
      refute section =~ "HIGH QUALITY"
    end

    test "root agent (nil parent_id) + \"high_quality\" returns the HIGH QUALITY block" do
      section =
        ContextBuilder.build_quality_guidance_section(%{
          parent_id: nil,
          repo_less: false,
          quality_level: "high_quality"
        })

      assert section != ""
      assert section =~ "HIGH QUALITY"
      refute section =~ "FAST"
    end

    test "\"balanced\", nil and an absent key return \"\"" do
      for level <- ["balanced", nil] do
        assert ContextBuilder.build_quality_guidance_section(%{
                 parent_id: nil,
                 repo_less: false,
                 quality_level: level
               }) == ""
      end

      # Absent key (robust to a partial map).
      assert ContextBuilder.build_quality_guidance_section(%{parent_id: nil, repo_less: false}) ==
               ""
    end

    test "an unknown value returns \"\" (never raises)" do
      assert ContextBuilder.build_quality_guidance_section(%{
               parent_id: nil,
               repo_less: false,
               quality_level: "bogus"
             }) == ""
    end

    test "a nested agent (integer parent_id) is unaffected, even with \"fast\"" do
      assert ContextBuilder.build_quality_guidance_section(%{
               parent_id: 7,
               repo_less: false,
               quality_level: "fast"
             }) == ""
    end

    test "a repo-less agent is unaffected, even with \"fast\"" do
      assert ContextBuilder.build_quality_guidance_section(%{
               parent_id: nil,
               repo_less: true,
               quality_level: "fast"
             }) == ""
    end

    test "a partial map (only repo_less: false) never raises" do
      assert ContextBuilder.build_quality_guidance_section(%{repo_less: false}) == ""
      assert ContextBuilder.build_quality_guidance_section(%{}) == ""
    end
  end

  # The ONE-LINE clock of the runtime-context snapshot (agents otherwise have no
  # clock at all). Rendered at MINUTE granularity from the `:now` test seam, with
  # a trailing zone name only when the value knows one.
  describe "build_clock_section/1" do
    test "a %DateTime{} renders its wall clock + its own zone name (exact)" do
      assert ContextBuilder.build_clock_section(%{now: ~U[2025-06-14 09:32:00Z]}) ==
               "Current local time: 2025-06-14 09:32 (Etc/UTC)"
    end

    test "a non-UTC %DateTime{} renders ITS zone, not UTC (exact)" do
      # The timezone database is passed explicitly: `DateTime.from_naive!/3` (and
      # `DateTime.new!/3`) would fail under `:utc_only_time_zone_database`, i.e.
      # in a `--no-start` context where the app's boot-time
      # `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)` never ran.
      berlin = DateTime.new!(~D[2025-06-14], ~T[09:32:00], "Europe/Berlin", Tz.TimeZoneDatabase)

      assert ContextBuilder.build_clock_section(%{now: berlin}) ==
               "Current local time: 2025-06-14 09:32 (Europe/Berlin)"
    end

    test "a %NaiveDateTime{} renders the wall clock with NO zone suffix (exact)" do
      # Seconds are dropped (minute granularity).
      assert ContextBuilder.build_clock_section(%{now: ~N[2025-06-14 09:32:45]}) ==
               "Current local time: 2025-06-14 09:32"
    end

    test "the REAL-clock path renders the same shape (absent/nil/bogus :now)" do
      # Production never sets `:now`, so these are the live paths — assert the
      # SHAPE only (never a value), plus totality: the function must never raise.
      shape = ~r/^Current local time: \d{4}-\d{2}-\d{2} \d{2}:\d{2}/

      for state <- [%{}, %{now: nil}, %{now: :bogus}, %{now: "2025-06-14 09:32"}] do
        line = ContextBuilder.build_clock_section(state)

        assert is_binary(line)
        assert line =~ shape
        assert String.starts_with?(line, "Current local time: ")
      end
    end
  end

  describe "build_context_block/1" do
    # A temp repo dir with a CONTEXT.md chain at "./docs"; removed in `on_exit`.
    defp temp_repo(root_md, docs_md) do
      repo =
        Path.join(System.tmp_dir!(), "evogit_ctx_block_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(repo, "docs"))
      File.write!(Path.join(repo, "CONTEXT.md"), root_md)
      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), docs_md)
      on_exit(fn -> File.rm_rf!(repo) end)
      repo
    end

    test "reads the CURRENT CONTEXT.md chain and wraps it in <context></context>" do
      repo = temp_repo("# Root\nroot body\n", "# Docs\ndocs body\n")

      block =
        ContextBuilder.build_context_block(%{
          node_path: "./docs",
          repo_path: repo,
          parent_id: nil,
          repo_less: false,
          foreign_repos: [],
          repo_notes: nil,
          quality_level: nil
        })

      assert String.starts_with?(block, "<context>\n")
      assert String.ends_with?(block, "\n</context>")
      assert block =~ "root body"
      assert block =~ "docs body"
      # Single-repo task -> no authority / foreign-repos sections.
      refute block =~ "Delegation authority"
      refute block =~ "Foreign Repositories"
    end

    test "re-reading after an edit reflects the new content (fresh read, not cached)" do
      repo = temp_repo("# Root\n", "# Docs\nBEFORE\n")

      st = %{
        node_path: "./docs",
        repo_path: repo,
        parent_id: nil,
        repo_less: false,
        foreign_repos: [],
        repo_notes: nil,
        quality_level: nil
      }

      assert ContextBuilder.build_context_block(st) =~ "BEFORE"

      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), "# Docs\nAFTER\n")

      block = ContextBuilder.build_context_block(st)
      assert block =~ "AFTER"
      refute block =~ "BEFORE"
    end

    test "includes the repo-notes and quality-guidance sections for a root agent" do
      repo = temp_repo("# Root\n", "# Docs\n")

      block =
        ContextBuilder.build_context_block(%{
          node_path: "./docs",
          repo_path: repo,
          parent_id: nil,
          repo_less: false,
          foreign_repos: [],
          repo_notes: "## Git Submodules\n\nnote text\n",
          quality_level: "fast"
        })

      assert block =~ "## Git Submodules"
      assert block =~ "note text"
      assert block =~ "FAST"
    end

    test "repo_less agents get no authority/quality sections even when requested" do
      repo = temp_repo("# Root\n", "# Docs\n")

      block =
        ContextBuilder.build_context_block(%{
          node_path: "./docs",
          repo_path: repo,
          parent_id: nil,
          repo_less: true,
          foreign_repos: [],
          repo_notes: nil,
          quality_level: "fast"
        })

      refute block =~ "Delegation authority"
      refute block =~ "FAST"
    end

    test "keeps the block BYTE-IDENTICAL when :background_jobs is absent, nil or empty" do
      repo = temp_repo("# Root\n", "# Docs\n")

      state = %{
        node_path: "./docs",
        repo_path: repo,
        parent_id: nil,
        repo_less: false,
        foreign_repos: [],
        repo_notes: nil,
        quality_level: nil,
        now: ~U[2025-06-14 09:32:00Z]
      }

      baseline = ContextBuilder.build_context_block(state)

      assert baseline ==
               ContextBuilder.build_context_block(Map.put(state, :background_jobs, nil))

      assert baseline ==
               ContextBuilder.build_context_block(Map.put(state, :background_jobs, []))

      refute baseline =~ "Background Jobs"
    end

    test "renders the background-jobs section BEFORE the clock line" do
      repo = temp_repo("# Root\n", "# Docs\n")

      block =
        ContextBuilder.build_context_block(%{
          node_path: "./docs",
          repo_path: repo,
          parent_id: nil,
          repo_less: false,
          foreign_repos: [],
          repo_notes: nil,
          quality_level: nil,
          background_jobs: [
            %{id: "bash-abc123", label: "mix test", status: :running, detail: nil}
          ],
          now: ~U[2025-06-14 09:32:00Z]
        })

      assert block =~ "## Background Jobs"
      assert block =~ "bash-abc123"
      assert block =~ "mix test"
      assert block =~ "running"

      # The clock stays the LAST section of the block.
      assert String.ends_with?(
               block,
               "Current local time: 2025-06-14 09:32 (Etc/UTC)\n</context>"
             )
    end
  end

  # The compression-refresh message appended as the LAST message of every
  # compression event (see `EvoGit.Agent.ContextCompression`): it delivers a
  # FRESH `<context>` block WITHOUT touching message #1, so the cacheable prefix
  # (system + original first user message) stays byte-identical.
  describe "build_context_refresh_message/2" do
    # Same temp-repo shape as `build_context_block/1` above: a CONTEXT.md chain
    # at "./docs", removed in `on_exit`.
    defp refresh_repo(root_md, docs_md) do
      repo =
        Path.join(System.tmp_dir!(), "evogit_ctx_refresh_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(repo, "docs"))
      File.write!(Path.join(repo, "CONTEXT.md"), root_md)
      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), docs_md)
      on_exit(fn -> File.rm_rf!(repo) end)
      repo
    end

    # The `Current local time:` line is rendered from the `:now` CLOCK seam, so a
    # fixed value here makes every refreshed-vs-original comparison deterministic
    # instead of racing a minute boundary.
    defp refresh_state(repo) do
      %{
        node_path: "./docs",
        repo_path: repo,
        parent_id: nil,
        repo_less: false,
        foreign_repos: [],
        repo_notes: nil,
        quality_level: nil,
        objective: "Build the parser.",
        now: ~U[2025-06-14 09:32:00Z]
      }
    end

    # The `:text` parts of a message, joined (a refreshed message is built by
    # `ReqLLM.Context.user/1`, so it is exactly one text part).
    defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map(& &1.text)
      |> Enum.join("")
    end

    defp refresh_text(state, turn) do
      state |> ContextBuilder.build_context_refresh_message(turn) |> text_of()
    end

    # Mirrors how `Runner.do_run/2` assembles message #1: the `<context>` block
    # plus the `<objective>` block, joined, materialized by
    # `build_first_user_message/3` and turn-tagged like every initial message.
    defp first_user_message(state) do
      combined =
        [
          ContextBuilder.build_context_block(state),
          ContextBuilder.objective_block(state.objective)
        ]
        |> Enum.reject(&ContextBuilder.blank?/1)
        |> Enum.join("\n\n---\n\n")

      combined
      |> ContextBuilder.build_first_user_message(
        Map.get(state, :parent_id),
        Map.get(state, :attachments)
      )
      |> ContextBuilder.tag_message_turn(0)
    end

    test "message #1 stays byte-identical while the refresh carries a FRESH clock" do
      repo = refresh_repo("# Root\nroot body\n", "# Docs\ndocs body\n")
      state = refresh_state(repo)

      msg1 = first_user_message(state)
      snapshot = :erlang.term_to_binary(msg1)

      # The SAME context state, a LATER clock: the refresh re-renders the line,
      # message #1 is never rewritten (the provider's cached prefix must not move).
      later = %{state | now: ~U[2025-06-14 10:07:00Z]}
      refresh = ContextBuilder.build_context_refresh_message(later, 4)
      refresh_text = text_of(refresh)

      assert :erlang.term_to_binary(msg1) == snapshot
      assert text_of(msg1) =~ "Current local time: 2025-06-14 09:32 (Etc/UTC)"
      assert refresh_text =~ "Current local time: 2025-06-14 10:07 (Etc/UTC)"
      refute refresh_text =~ "2025-06-14 09:32"
      # The pinned notice wording is untouched and still leads the message.
      assert String.starts_with?(
               refresh_text,
               "This is an automatically generated runtime-context refresh."
             )

      # `refresh_first_user_message/2` with the SAME fixed clock reproduces the
      # original message structurally, and a different clock makes it differ.
      assert ContextBuilder.refresh_first_user_message(msg1, state) == msg1
      refute ContextBuilder.refresh_first_user_message(msg1, later) == msg1
    end

    test "is a :user message carrying the CURRENT <context> block" do
      repo = refresh_repo("# Root\nroot body\n", "# Docs\ndocs body\n")

      message = ContextBuilder.build_context_refresh_message(refresh_state(repo), nil)

      assert %ReqLLM.Message{role: :user} = message

      text = text_of(message)
      assert String.contains?(text, "<context>")
      assert String.contains?(text, "</context>")
      assert text =~ "root body"
      assert text =~ "docs body"
    end

    test "re-renders the chain: an edit made after the first build shows up" do
      repo = refresh_repo("# Root\n", "# Docs\nBEFORE\n")
      state = refresh_state(repo)

      assert refresh_text(state, nil) =~ "BEFORE"

      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), "# Docs\nAFTER\n")

      text = refresh_text(state, nil)
      assert text =~ "AFTER"
      refute text =~ "BEFORE"
    end

    test "states that it supersedes earlier snapshots, pins the objective, forbids acknowledgement" do
      repo = refresh_repo("# Root\n", "# Docs\n")
      text = refresh_text(refresh_state(repo), nil)

      # Pinned wording — the three things a compressed agent must understand.
      assert text =~ "automatically generated runtime-context refresh"
      assert text =~ "SUPERSEDES any earlier <context> snapshot"
      assert text =~ "The <objective> block is unchanged"
      assert text =~ "do NOT acknowledge this refresh"
    end

    test "never carries an <objective> block of its own" do
      repo = refresh_repo("# Root\n", "# Docs\n")

      text = refresh_text(refresh_state(repo), nil)

      # The notice MENTIONS the <objective> block ("The <objective> block is
      # unchanged") but no objective BLOCK is rendered: `objective_block/1`
      # opens with "<objective>\n" and closes with "</objective>".
      refute text =~ "<objective>\n"
      refute text =~ "</objective>"
      # The raw objective is NEVER re-rendered here — it stays verbatim in the
      # (untouched) first user message.
      refute text =~ "Build the parser."
    end

    test "turn-tags the message when a turn is given" do
      repo = refresh_repo("# Root\n", "# Docs\n")
      before = System.system_time(:second)

      message = ContextBuilder.build_context_refresh_message(refresh_state(repo), 12)

      assert message.metadata[:turn] == 12
      assert message.metadata[:timestamp] in before..System.system_time(:second)
    end

    test "leaves the message untagged for a nil turn" do
      repo = refresh_repo("# Root\n", "# Docs\n")

      message = ContextBuilder.build_context_refresh_message(refresh_state(repo), nil)

      refute message.metadata[:turn]
      refute message.metadata[:timestamp]
    end

    test "a state carrying background jobs includes the jobs section in the refresh" do
      repo = refresh_repo("# Root\n", "# Docs\n")

      state =
        Map.put(refresh_state(repo), :background_jobs, [
          %{id: "bash-refresh01", label: "sleep 30", status: :running, detail: nil}
        ])

      text = refresh_text(state, 3)

      assert text =~ "## Background Jobs"
      assert text =~ "bash-refresh01"
      assert text =~ "sleep 30"
      assert text =~ "running"
      # The pinned notice still leads the message.
      assert String.contains?(text, "SUPERSEDES any earlier <context> snapshot")
    end

    test "returns nil when the rendered context block is blank" do
      # `build_context_block/1` always renders at least the location line, so no
      # realistic state reaches the blank branch — it exists so a future
      # block-builder that CAN render nothing appends no empty message. Pin both
      # sides: the nil guard's precondition, and that a real state is never nil.
      blank = %{repo_less: false, foreign_repos: []}

      refute ContextBuilder.build_context_block(blank) == ""
      refute is_nil(ContextBuilder.build_context_refresh_message(blank, nil))

      repo = refresh_repo("# Root\n", "# Docs\n")

      assert %ReqLLM.Message{} =
               ContextBuilder.build_context_refresh_message(refresh_state(repo), 0)
    end
  end

  describe "build_initial_messages/4" do
    # Mirrors the native-struct content-part test idiom at
    # test/evo_git/agent_scheduler/remote_api_test.exs:427-447.
    @system_prompt "You are the manager."
    @objective "Build the parser."

    defp attachment(type, name, media_type, raw) do
      %{
        "type" => type,
        "name" => name,
        "media_type" => media_type,
        "data" => Base.encode64(raw)
      }
    end

    test "no attachments -> exact legacy 2-message shape [system, user(text)]" do
      [system_msg, user_msg] =
        ContextBuilder.build_initial_messages(@system_prompt, @objective, nil, nil)

      assert %ReqLLM.Message{role: :system} = system_msg
      assert system_msg.content == [ReqLLM.Message.ContentPart.text(@system_prompt)]

      # Byte-identical to the legacy `ReqLLM.Context.new([system(...), user(binary)])`
      # construction — same struct equality as the plain user/1 fast path.
      assert %ReqLLM.Message{role: :user} = user_msg
      assert user_msg == ReqLLM.Context.user(@objective)
      assert user_msg.content == [ReqLLM.Message.ContentPart.text(@objective)]
    end

    test "no attachments ([]) -> same plain-text shape" do
      [_, user_msg] = ContextBuilder.build_initial_messages(@system_prompt, @objective, nil, [])
      assert user_msg == ReqLLM.Context.user(@objective)
    end

    test "root with attachments -> text part first, then image/file parts in input order" do
      attachments = [
        attachment("image", "a.png", "image/png", <<1, 2, 3>>),
        attachment("audio", "b.mp3", "audio/mpeg", <<4, 5, 6>>),
        attachment("image", "c.png", "image/png", <<7, 8, 9>>)
      ]

      [system_msg, user_msg] =
        ContextBuilder.build_initial_messages(@system_prompt, @objective, nil, attachments)

      assert system_msg.role == :system

      assert user_msg.role == :user
      assert [text, a, b, c] = user_msg.content
      assert text == ReqLLM.Message.ContentPart.text(@objective)
      assert a == ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png")
      assert b == ReqLLM.Message.ContentPart.file(<<4, 5, 6>>, "b.mp3", "audio/mpeg")
      assert c == ReqLLM.Message.ContentPart.image(<<7, 8, 9>>, "image/png")
    end

    test "non-root (parent_id set) with attachments -> plain text (root-only gate)" do
      attachments = [
        attachment("image", "a.png", "image/png", <<1, 2, 3>>)
      ]

      [_, user_msg] =
        ContextBuilder.build_initial_messages(@system_prompt, @objective, 7, attachments)

      assert user_msg == ReqLLM.Context.user(@objective)
    end

    test "system prompt is preserved verbatim in every path" do
      [system_msg, _] =
        ContextBuilder.build_initial_messages(@system_prompt, @objective, 7, [
          attachment("image", "a.png", "image/png", <<1, 2, 3>>)
        ])

      assert system_msg.content == [ReqLLM.Message.ContentPart.text(@system_prompt)]
    end
  end

  describe "build_injected_message/2" do
    test "legacy binary + nil turn -> byte-identical plain user(text)" do
      assert ContextBuilder.build_injected_message("ping", nil) == ReqLLM.Context.user("ping")
    end

    test "legacy binary + turn -> plain user(text), turn-tagged" do
      before = System.system_time(:second)
      msg = ContextBuilder.build_injected_message("ping", 7)
      after_ = System.system_time(:second)

      assert msg.role == :user
      assert msg.content == ReqLLM.Context.user("ping").content
      assert msg.metadata[:turn] == 7
      assert msg.metadata[:timestamp] in before..after_
    end

    test "atom-keyed map with an image + nil turn -> [text | image] content parts" do
      attachments = [attachment("image", "a.png", "image/png", <<1, 2, 3>>)]

      msg = ContextBuilder.build_injected_message(%{text: "look", attachments: attachments}, nil)

      assert msg == ReqLLM.Context.user(EvoGit.Attachments.to_content_parts("look", attachments))

      assert [text, image] = msg.content
      assert text == ReqLLM.Message.ContentPart.text("look")
      assert image == ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png")
    end

    test "string-keyed map (Codec / task-data-plane shape) with audio -> file part" do
      attachments = [attachment("audio", "b.mp3", "audio/mpeg", <<4, 5, 6>>)]

      msg =
        ContextBuilder.build_injected_message(
          %{"text" => "listen", "attachments" => attachments},
          nil
        )

      assert [text, file] = msg.content
      assert text == ReqLLM.Message.ContentPart.text("listen")
      assert file == ReqLLM.Message.ContentPart.file(<<4, 5, 6>>, "b.mp3", "audio/mpeg")
    end

    test "attachments: [] -> plain-text fast path" do
      assert ContextBuilder.build_injected_message(%{text: "hi", attachments: []}, nil) ==
               ReqLLM.Context.user("hi")
    end

    test "multiple attachments keep input order (text part first)" do
      attachments = [
        attachment("image", "a.png", "image/png", <<1>>),
        attachment("audio", "b.mp3", "audio/mpeg", <<2>>),
        attachment("image", "c.png", "image/png", <<3>>)
      ]

      msg = ContextBuilder.build_injected_message(%{text: "many", attachments: attachments}, nil)

      assert [text, a, b, c] = msg.content
      assert text == ReqLLM.Message.ContentPart.text("many")
      assert a == ReqLLM.Message.ContentPart.image(<<1>>, "image/png")
      assert b == ReqLLM.Message.ContentPart.file(<<2>>, "b.mp3", "audio/mpeg")
      assert c == ReqLLM.Message.ContentPart.image(<<3>>, "image/png")
    end

    test "no root gate — the helper takes no parent/depth argument (arity is exactly 2)" do
      assert function_exported?(ContextBuilder, :build_injected_message, 2)
      refute function_exported?(ContextBuilder, :build_injected_message, 3)

      # A media-carrying injected message materializes unconditionally — there is
      # no root/non-root distinction on this path at all.
      msg =
        ContextBuilder.build_injected_message(
          %{text: "x", attachments: [attachment("image", "a.png", "image/png", <<9>>)]},
          nil
        )

      assert length(msg.content) == 2
    end

    test "malformed message map raises a descriptive ArgumentError" do
      assert_raise ArgumentError, ~r/message: text must be a string/, fn ->
        ContextBuilder.build_injected_message(%{attachments: []}, nil)
      end
    end

    test "an invalid attachment payload raises (caps validated by EvoGit.Attachments)" do
      bad = [attachment("video", "v.mp4", "video/mp4", <<1>>)]

      assert_raise ArgumentError, ~r/unknown type/, fn ->
        ContextBuilder.build_injected_message(%{text: "x", attachments: bad}, nil)
      end
    end

    test "a non-message value raises" do
      assert_raise ArgumentError, ~r/expected a string or a/, fn ->
        ContextBuilder.build_injected_message(42, nil)
      end
    end
  end
end
