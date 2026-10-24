defmodule EvoGit.Agent.BackgroundJobNoticeTest do
  @moduledoc """
  `async: true` — pure text rendering over in-memory job maps. No registry, no
  IO, no process dictionary, no scheduler.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.BackgroundJobNotice

  defp job(overrides \\ []) do
    Map.merge(
      %{
        id: "bash-0123456789abcdef",
        kind: "bash",
        label: "mix test",
        status: :running,
        detail: nil,
        exit_code: nil
      },
      Map.new(overrides)
    )
  end

  describe "section/1" do
    test "renders nothing for nil or an empty list" do
      assert BackgroundJobNotice.section(nil) == ""
      assert BackgroundJobNotice.section([]) == ""
    end

    test "renders nothing for a non-list value" do
      assert BackgroundJobNotice.section(%{id: "bash-1"}) == ""
      assert BackgroundJobNotice.section("bash-1") == ""
    end

    test "renders the header, the orientation line and one line per job" do
      section = BackgroundJobNotice.section([job()])

      assert section =~ "## Background Jobs"
      assert section =~ "`job_output`"
      assert section =~ "`job_list`"
      assert section =~ "bash-0123456789abcdef"
      assert section =~ "running"
      assert section =~ "mix test"
    end

    test "renders a single job on exactly one line" do
      lines = BackgroundJobNotice.section([job()]) |> String.split("\n")

      assert Enum.count(lines, &String.starts_with?(&1, "- ")) == 1
    end

    test "renders every job of a multi-job list (newest first, as handed in)" do
      jobs = [
        job(id: "bash-newer", label: "mix test"),
        job(
          id: "bash-older",
          label: "mix format --check-formatted",
          status: :completed,
          detail: "exit code: 0"
        )
      ]

      section = BackgroundJobNotice.section(jobs)

      assert section =~ "bash-newer"
      assert section =~ "bash-older"
      assert section =~ "mix format --check-formatted"

      assert elem(:binary.match(section, "bash-newer"), 0) <
               elem(:binary.match(section, "bash-older"), 0)
    end

    test "renders the terminal status with its detail in parentheses" do
      section = BackgroundJobNotice.section([job(status: :completed, detail: "exit code: 0")])

      assert section =~ "completed (exit code: 0)"
    end

    test "omits the parenthesised detail when it is absent or blank" do
      for detail <- [nil, "", "   "] do
        section = BackgroundJobNotice.section([job(status: :killed, detail: detail)])

        assert section =~ "killed"
        refute section =~ "killed ()"
      end
    end

    test "flattens newlines in the label to single spaces" do
      section = BackgroundJobNotice.section([job(label: "make\n test\r\n\tplease")])

      assert section =~ "make test please"
      refute section =~ "make\n"
    end

    test "truncates a long label to ~80 characters" do
      long = String.duplicate("x", 200)

      section = BackgroundJobNotice.section([job(label: long)])

      assert section =~ String.duplicate("x", 80) <> "..."
      refute section =~ long
    end

    test "caps the whole rendered text defensively" do
      jobs =
        for n <- 1..100 do
          job(id: "bash-#{n}", label: String.duplicate("y", 120))
        end

      section = BackgroundJobNotice.section(jobs)

      assert section =~ "[... more background jobs omitted]"
      # ~2000-char cap plus the truncation marker.
      assert String.length(section) < 2_100
    end

    test "tolerates malformed and missing keys" do
      assert BackgroundJobNotice.section(%{}) == ""

      empty = BackgroundJobNotice.section([%{}])
      assert empty =~ "(unknown id)"
      assert empty =~ "unknown"

      odd_status = BackgroundJobNotice.section([%{id: "bash-1", status: :weird, detail: 42}])
      assert odd_status =~ "bash-1"
      assert odd_status =~ ":weird"

      non_binary_label = BackgroundJobNotice.section([job(label: 123)])
      refute non_binary_label =~ " — 123"

      non_map = BackgroundJobNotice.section([:not_a_job])
      assert non_map =~ "(unrecognized background job record)"
    end
  end

  describe "notice/1" do
    test "renders nothing for nil or an empty list" do
      assert BackgroundJobNotice.notice(nil) == nil
      assert BackgroundJobNotice.notice([]) == nil
    end

    test "renders nothing for a non-list value" do
      assert BackgroundJobNotice.notice(%{id: "bash-1"}) == nil
    end

    test "renders ONE [NOTICE]-prefixed message with the job id, label and status" do
      notice = BackgroundJobNotice.notice([job(status: :completed, detail: "exit code: 0")])

      assert String.starts_with?(notice, "[NOTICE]")
      assert notice =~ "1 background shell job finished"
      assert notice =~ "bash-0123456789abcdef"
      assert notice =~ "mix test"
      assert notice =~ "completed (exit code: 0)"
      assert notice =~ "`job_output`"
      assert notice =~ "`job_list`"
    end

    test "lists multiple finished jobs and pluralizes the header" do
      notice =
        BackgroundJobNotice.notice([
          job(id: "bash-a", label: "mix test", status: :completed, detail: "exit code: 0"),
          job(id: "bash-b", label: "mix credo", status: :failed, detail: "exit code: 1")
        ])

      assert notice =~ "2 background shell jobs finished"
      assert notice =~ "bash-a"
      assert notice =~ "bash-b"
      assert notice =~ "failed (exit code: 1)"
    end

    test "tolerates malformed job maps" do
      notice = BackgroundJobNotice.notice([%{}, :not_a_job])

      assert is_binary(notice)
      assert notice =~ "(unknown id)"
      assert notice =~ "(unrecognized background job record)"
    end
  end
end
