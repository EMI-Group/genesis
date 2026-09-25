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
