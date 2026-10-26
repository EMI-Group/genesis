defmodule EvoGit.Store.CodecCompressionTest do
  @moduledoc """
  Wire-format tests for the TRANSPARENT ZLIB COMPRESSION of the large text
  columns (`result`, `archive_metadata`, `logs`).

  Format under test:

      "z1:" <> Base.encode64(:zlib.compress(json, 1))

  applied ONLY when the JSON text is larger than 4096 bytes; at or below the
  threshold the plain JSON text is emitted unchanged (byte-identical to the
  pre-compression format). Decode accepts BOTH forms forever, so legacy rows
  keep decoding with no migration.

  Strictness is preserved per function after inflation:
  `decode_result/1` raises `ArgumentError` (including for a corrupt `"z1:"`
  payload), while `decode_logs/1` / `decode_archive/1` degrade exactly like
  they do for corrupt plain JSON (`[]` / `nil`).

  Pure codec tests: no Repo, no DB, async: true.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Usage
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Types.ArchiveJson
  alias EvoGit.Store.Types.LogsJson
  alias EvoGit.Store.Types.ResultJson

  @prefix "z1:"
  @threshold 4096

  # A reason string that cannot collide with a pre-existing atom, so
  # `decode_reason/1` keeps it as a string and round-trip equality holds.
  @plain_reason "no such atom ever xyzzy_codec_98765"

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  # Repetitive text — compresses very well and carries a marker we can search
  # for in the emitted column value.
  @marker "UNCOMPRESSED_MARKER_TEXT"
  defp big_text(reps \\ 400) do
    String.duplicate(
      "#{@marker}: the agent finished the migration and verified the schema\n",
      reps
    )
  end

  defp big_result do
    {:ok,
     %{
       commit_sha: "abc123",
       branch_name: "genesis/agent_deadbeef",
       archive_records: archive_fixture(),
       result: big_text()
     }}
  end

  defp archive_fixture do
    for i <- 1..200 do
      %{
        "agent_id" => "agent_#{rem(i, 7)}",
        "type" => "executor",
        "objective" =>
          "Implement the storage layer for the task registry, including the " <>
            "Ecto migrations, the codec wire format and the boot adoption path.",
        "result" =>
          "Completed the migration work and verified the schema against the " <>
            "existing user databases with no manual steps required.",
        "usage" => %{
          "input_tokens" => 1_200 + i,
          "output_tokens" => 300,
          "total_tokens" => 1_500 + i
        }
      }
    end
  end

  defp big_logs do
    for i <- 1..400, do: "[info] step #{i}: committed worktree batch (unchanged prefix)"
  end

  # Builds a `{:error, reason}` result whose JSON text is EXACTLY `size` bytes.
  # The envelope around the reason is measured with the Codec itself, so the
  # boundary tests stay correct if the plain encoding ever changes.
  defp result_with_json_size(size) do
    base = result_plain_envelope_size()
    {:error, String.duplicate("a", size - base)}
  end

  defp result_plain_envelope_size do
    byte_size(Jason.encode!(%{"__result_tag__" => "error", "reason" => ""}))
  end

  # The PLAIN (uncompressed) JSON the codec would have written before
  # compression — `encode_result_data/1` is the codec's own documented
  # map → JSON-safe-map conversion, so this is the legacy envelope verbatim.
  defp plain_result_json({:ok, data}) do
    Jason.encode!(%{"__result_tag__" => "ok", "data" => Codec.encode_result_data(data)})
  end

  defp compressed_bytes(stored) do
    @prefix <> encoded = stored
    {:ok, compressed} = Base.decode64(encoded)
    compressed
  end

  ## ── Threshold: small values stay plain JSON (byte-identical) ─────────────

  describe "small values stay plain JSON" do
    test "result below the threshold has no z1: prefix and is the legacy JSON" do
      results = [
        {:ok, %{}},
        {:ok, %{commit_sha: "abc", branch_name: "genesis/agent_x"}},
        {:error, @plain_reason},
        {:exit, @plain_reason},
        "plain string fallback",
        {:weird, :shape},
        42
      ]

      for result <- results do
        stored = Codec.encode_result(result)

        refute String.starts_with?(stored, @prefix)

        # Byte-identical to the legacy envelope: valid JSON carrying the tag.
        assert {:ok, %{"__result_tag__" => _}} = Jason.decode(stored)
      end

      assert Codec.encode_result(nil) == nil
    end

    test "result at exactly the threshold (4096 bytes) stays plain JSON" do
      result = result_with_json_size(@threshold)
      stored = Codec.encode_result(result)

      refute String.starts_with?(stored, @prefix)
      assert byte_size(stored) == @threshold

      assert Codec.decode_result(stored) ==
               {:error, String.duplicate("a", @threshold - result_plain_envelope_size())}
    end

    test "result one byte over the threshold (4097 bytes) is compressed" do
      stored = Codec.encode_result(result_with_json_size(@threshold + 1))

      assert String.starts_with?(stored, @prefix)
    end

    test "small logs and archive_metadata stay plain JSON" do
      assert Codec.encode_logs(["a", "b"]) == ~s(["a","b"])
      assert Codec.encode_logs(nil) == "[]"
      assert Codec.encode_archive([%{"agent_id" => "agent_1"}]) == ~s([{"agent_id":"agent_1"}])
      assert Codec.encode_archive(nil) == nil
      assert Codec.encode_archive([]) == "[]"

      refute String.starts_with?(Codec.encode_logs(["x"]), @prefix)
      refute String.starts_with?(Codec.encode_archive([%{a: 1}]), @prefix)
    end

    test "opts is NEVER compressed — task search is a LIKE over the raw text" do
      opts = [path: "/tmp/repo", mode: "evolve", objective: big_text(50)]
      stored = Codec.encode_opts(opts)

      refute String.starts_with?(stored, @prefix)
      assert String.starts_with?(stored, "{")
      assert String.contains?(stored, @marker)
      assert {:objective, _} = List.keyfind(Codec.decode_opts(stored), :objective, 0)
    end
  end

  ## ── Large values compress ────────────────────────────────────────────────

  describe "large values compress transparently" do
    test "big result carries the z1: prefix and hides the inner text" do
      big = big_result()
      stored = Codec.encode_result(big)

      assert String.starts_with?(stored, @prefix)
      refute String.contains?(stored, @marker)
      refute String.contains?(stored, "__result_tag__")
      assert byte_size(compressed_bytes(stored)) < byte_size(plain_result_json(big))
    end

    test "big logs and archive_metadata carry the z1: prefix" do
      logs_stored = Codec.encode_logs(big_logs())
      archive_stored = Codec.encode_archive(archive_fixture())

      assert String.starts_with?(logs_stored, @prefix)
      assert String.starts_with?(archive_stored, @prefix)
      refute String.contains?(archive_stored, "input_tokens")
    end

    test "encoding is deterministic (identical input -> identical bytes)" do
      big = big_result()
      stored = Codec.encode_result(big)
      assert stored == Codec.encode_result(big)
      assert Codec.encode_result(Codec.decode_result(stored)) == stored

      archive = archive_fixture()
      archive_stored = Codec.encode_archive(archive)
      assert archive_stored == Codec.encode_archive(archive)
      assert Codec.encode_archive(Codec.decode_archive(archive_stored)) == archive_stored

      logs = big_logs()
      logs_stored = Codec.encode_logs(logs)
      assert logs_stored == Codec.encode_logs(logs)
      assert Codec.encode_logs(Codec.decode_logs(logs_stored)) == logs_stored
    end
  end

  ## ── Round-trips ──────────────────────────────────────────────────────────

  describe "round-trip equality" do
    test "result: all 4 tagged forms + nil + a large payload" do
      assert Codec.decode_result(Codec.encode_result(nil)) == nil

      for result <- [
            {:ok, %{commit_sha: "abc", branch_name: "genesis/agent_x"}},
            {:ok, %{commit_sha: "abc", usage: Usage.zero()}},
            {:error, @plain_reason},
            {:exit, @plain_reason},
            "plain string fallback"
          ] do
        assert Codec.decode_result(Codec.encode_result(result)) == result
      end

      # Closed-set atoms are restored by decode_reason/1.
      assert Codec.decode_result(Codec.encode_result({:exit, :killed})) == {:exit, :killed}

      # The large payload (compressed on disk) round-trips in full.
      big = big_result()
      assert Codec.decode_result(Codec.encode_result(big)) == big
    end

    test "archive_metadata: a big list of maps round-trips" do
      archive = archive_fixture()
      stored = Codec.encode_archive(archive)

      assert String.starts_with?(stored, @prefix)
      assert Codec.decode_archive(stored) == archive
      assert Codec.decode_archive(Codec.encode_archive(nil)) == nil
      assert Codec.decode_archive(Codec.encode_archive([])) == []
    end

    test "logs: a big list round-trips" do
      logs = big_logs()
      stored = Codec.encode_logs(logs)

      assert String.starts_with?(stored, @prefix)
      assert Codec.decode_logs(stored) == logs
      assert Codec.decode_logs(Codec.encode_logs(nil)) == []
    end

    test "Types.* stay pure delegations (large values included)" do
      big = big_result()

      assert {:ok, stored} = ResultJson.dump(big)
      assert {:ok, ^big} = ResultJson.load(stored)

      archive = archive_fixture()
      assert {:ok, archive_stored} = ArchiveJson.dump(archive)
      assert {:ok, ^archive} = ArchiveJson.load(archive_stored)

      logs = big_logs()
      assert {:ok, logs_stored} = LogsJson.dump(logs)
      assert {:ok, ^logs} = LogsJson.load(logs_stored)
    end
  end

  ## ── Legacy plain JSON still decodes ──────────────────────────────────────

  describe "legacy plain-JSON payloads still decode" do
    test "result: hand-written tagged JSON (no prefix)" do
      stored = [
        {~s({"__result_tag__":"ok","data":{}}), {:ok, %{}}},
        {~s({"__result_tag__":"ok","data":{"commit_sha":"abc"}}), {:ok, %{commit_sha: "abc"}}},
        {~s({"__result_tag__":"error","reason":"#{@plain_reason}"}), {:error, @plain_reason}},
        {~s({"__result_tag__":"exit","reason":"killed"}), {:exit, :killed}},
        {~s({"__result_tag__":"string","value":"plain"}), "plain"}
      ]

      for {text, expected} <- stored do
        refute String.starts_with?(text, @prefix)
        assert Codec.decode_result(text) == expected
      end
    end

    test "logs: hand-written JSON array (no prefix)" do
      assert Codec.decode_logs(~s(["a","b"])) == ["a", "b"]
      assert Codec.decode_logs("[]") == []
    end

    test "archive_metadata: hand-written JSON array (no prefix)" do
      assert Codec.decode_archive(~s([{"agent_id":"agent_1","n":1}])) == [
               %{"agent_id" => "agent_1", "n" => 1}
             ]

      assert Codec.decode_archive("[]") == []
    end
  end

  ## ── Corrupt payloads ────────────────────────────────────────────────────

  describe "corrupt compressed payloads" do
    test "result RAISES ArgumentError (invalid base64 and invalid zlib)" do
      corrupt = [
        @prefix <> "!!! not base64 !!!",
        @prefix <> Base.encode64("this is not a zlib stream"),
        @prefix,
        @prefix <> "eJw="
      ]

      for stored <- corrupt do
        assert_raise ArgumentError, ~r/compressed/, fn -> Codec.decode_result(stored) end
        assert_raise ArgumentError, ~r/z1:/, fn -> Codec.decode_result(stored) end
      end
    end

    test "result keeps raising for corrupt PLAIN payloads (unchanged messages)" do
      for stored <- ["raw legacy string", ~s({"untagged":"object"}), ~s(42), "not json"] do
        assert_raise ArgumentError, fn -> Codec.decode_result(stored) end
      end
    end

    test "logs degrade to [] exactly like corrupt plain JSON" do
      for stored <- [@prefix <> "!!! not base64 !!!", @prefix <> Base.encode64("junk")] do
        assert Codec.decode_logs(stored) == []
      end

      # Same degradation class as a corrupt PLAIN value.
      assert Codec.decode_logs("not json") == []
    end

    test "archive_metadata degrades to nil exactly like corrupt plain JSON" do
      for stored <- [@prefix <> "!!! not base64 !!!", @prefix <> Base.encode64("junk")] do
        assert Codec.decode_archive(stored) == nil
      end

      assert Codec.decode_archive("not json") == nil
    end
  end

  ## ── Compression ratio ───────────────────────────────────────────────────

  describe "compression ratio" do
    test "a realistic repetitive archive shrinks below 25% of the plain JSON" do
      archive = archive_fixture()
      plain_size = byte_size(Jason.encode!(archive))
      stored = Codec.encode_archive(archive)

      assert String.starts_with?(stored, @prefix)
      assert plain_size > @threshold * 10
      assert byte_size(compressed_bytes(stored)) < plain_size * 0.25
    end

    test "a large result shrinks below 25% of the plain JSON" do
      big = big_result()
      plain_size = byte_size(plain_result_json(big))
      stored = Codec.encode_result(big)

      assert plain_size > @threshold
      assert byte_size(compressed_bytes(stored)) < plain_size * 0.25
    end
  end
end
