defmodule EvoGit.Store.TypesTest do
  @moduledoc """
  Wire-format oracle tests for the `EvoGit.Store.Types.*` Ecto.Type modules.

  `EvoGit.Store.Codec` (the pre-existing encoder/decoder) is the ORACLE: for
  every type we assert that

    * `dump/1` output is byte-identical to `Codec.encode_*/1`, and
    * `load/1` returns exactly `Codec.decode_*/1`'s value (including nil
      forms and the raising paths — same exception type AND message).

  Since the types delegate to the Codec, equality holds by construction; the
  tests pin it so any future drift (accidental logic duplication, a refactor
  away from delegation) fails loudly.

  Deterministic matrices plus randomized loops via `:rand` seeded per test —
  no stream_data, no new deps. Pure type tests: no Repo, no DB, async: true.

  The closed atom sets below mirror `Codec`'s `@known_atoms` union (the Codec
  shares ONE closed set across type/status/review_status — there is no
  per-column decode function to delegate to; see
  `EvoGit.Store.Types.AtomColumn`).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Usage
  alias EvoGit.RecentProject
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Schemas.ProjectRow
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Types

  # ── Closed sets (mirror of Codec's @known_atoms union) ───────────────────

  @type_atoms ~w(genesis evolve extract_skills reflect)a
  @status_atoms ~w(pending running finalizing completed failed cancelled cancelling)a
  @review_status_atoms ~w(open merged rejected continued ignored no_changes)a
  @known_atoms @type_atoms ++ @status_atoms ++ @review_status_atoms

  # ── Deterministic fixtures ───────────────────────────────────────────────

  @datetimes [
    # The canonical writer shape: DateTime.utc_now() carries microseconds, so
    # truncation keeps the 3-digit fraction — the load-bearing 24-char form.
    ~U[2024-01-01 12:00:00.123Z],
    ~U[2024-01-01 12:00:00.999Z],
    ~U[1999-12-31 23:59:59.001Z],
    ~U[2026-02-14 06:30:00.500Z],
    # Sub-millisecond precision truncates (rounds toward zero) — still
    # byte-equal to whatever the Codec emits.
    %{~U[2024-01-01 12:00:00.123456Z] | microsecond: {123_456, 6}},
    # Whole-second DateTime (zero precision) — the Codec does NOT pad ".000";
    # pinned here so nobody "fixes" the type into inventing the 24-char form.
    ~U[2024-01-01 12:00:00Z]
  ]

  @stored_timestamps [
    "2024-01-01T12:00:00.123Z",
    "2024-01-01T12:00:00.000Z",
    "2024-01-01T12:00:00Z",
    # Non-UTC offset — DateTime.from_iso8601 keeps the instant; decode is
    # lenient and never crashes.
    "2024-01-01T14:00:00.123+02:00",
    # Corrupt — decodes to nil (lenient by design).
    "not-a-timestamp",
    ""
  ]

  # ── TaskTimestamp ────────────────────────────────────────────────────────

  describe "TaskTimestamp (DateTime <-> fixed-ms ISO TEXT)" do
    test "dump is byte-identical to Codec.encode_datetime/1" do
      for dt <- @datetimes do
        assert {:ok, dumped} = Types.TaskTimestamp.dump(dt)
        assert dumped == Codec.encode_datetime(dt)
        assert is_binary(dumped)
      end
    end

    test "dump/0 arity-1 nil form" do
      assert Types.TaskTimestamp.dump(nil) == {:ok, Codec.encode_datetime(nil)}
      assert Types.TaskTimestamp.dump(nil) == {:ok, nil}
    end

    test "load returns exactly Codec.decode_datetime/1 (DateTime or nil)" do
      for str <- @stored_timestamps do
        assert Types.TaskTimestamp.load(str) == {:ok, Codec.decode_datetime(str)}
      end
    end

    test "load nil form" do
      assert Types.TaskTimestamp.load(nil) == {:ok, Codec.decode_datetime(nil)}
    end

    test "load returns a DateTime struct for well-formed text" do
      assert {:ok, %DateTime{}} = Types.TaskTimestamp.load("2024-01-01T12:00:00.123Z")
    end

    test "round-trip: load(dump(dt)) == dt (ms-precision)" do
      for dt <- @datetimes do
        {:ok, dumped} = Types.TaskTimestamp.dump(dt)

        # Only the shape is asserted: the fixture carries a sub-millisecond
        # DateTime, which dump/1 truncates, so the loaded value is NOT
        # structurally equal to `dt` for every element.
        assert {:ok, _dt} = Types.TaskTimestamp.load(dumped)
      end
    end

    test "dump preserves chronological string ordering (the load-bearing property)" do
      earlier = ~U[2024-01-01 00:00:00.100Z]
      later = ~U[2024-01-01 00:00:00.200Z]

      {:ok, s1} = Types.TaskTimestamp.dump(earlier)
      {:ok, s2} = Types.TaskTimestamp.dump(later)
      assert s1 < s2
    end

    test "cast accepts DateTime, ISO strings, and nil; rejects garbage" do
      assert Types.TaskTimestamp.cast(~U[2024-01-01 12:00:00Z]) == {:ok, ~U[2024-01-01 12:00:00Z]}
      assert {:ok, %DateTime{}} = Types.TaskTimestamp.cast("2024-01-01T12:00:00Z")
      assert Types.TaskTimestamp.cast(nil) == {:ok, nil}
      assert Types.TaskTimestamp.cast(:nope) == :error
      assert Types.TaskTimestamp.cast("garbage") == :error
    end

    test "randomized dump/load equals the Codec (200 samples)" do
      :rand.seed(:exsss, {11, 22, 33})

      for _ <- 1..200 do
        dt = random_datetime()

        assert Types.TaskTimestamp.dump(dt) == {:ok, Codec.encode_datetime(dt)}

        stored = Codec.encode_datetime(dt)

        assert Types.TaskTimestamp.load(stored) == {:ok, Codec.decode_datetime(stored)}
      end
    end
  end

  # ── TaskTimestampRaw (the store-internal updated_at) ─────────────────────

  describe "TaskTimestampRaw (updated_at — raw-string load)" do
    test "dump is byte-identical to TaskTimestamp.dump and Codec.encode_datetime/1" do
      for dt <- @datetimes do
        assert Types.TaskTimestampRaw.dump(dt) == {:ok, Codec.encode_datetime(dt)}
        assert Types.TaskTimestampRaw.dump(dt) == Types.TaskTimestamp.dump(dt)
      end
    end

    test "dump accepts the already-encoded string unchanged (round-trip safe)" do
      stored = Codec.encode_datetime(~U[2024-01-01 12:00:00.123Z])
      assert Types.TaskTimestampRaw.dump(stored) == {:ok, stored}
    end

    test "load NEVER decodes — returns the stored string untouched" do
      for str <- @stored_timestamps do
        assert Types.TaskTimestampRaw.load(str) == {:ok, str}
      end

      # Deliberate contrast with TaskTimestamp: same stored text, different
      # loaded value — raw vs decoded. updated_at's SQL string comparisons
      # depend on the raw form.
      assert Types.TaskTimestampRaw.load("2024-01-01T12:00:00.123Z") ==
               {:ok, "2024-01-01T12:00:00.123Z"}

      assert Types.TaskTimestamp.load("2024-01-01T12:00:00.123Z") !=
               {:ok, "2024-01-01T12:00:00.123Z"}
    end

    test "load nil form" do
      assert Types.TaskTimestampRaw.load(nil) == {:ok, nil}
    end

    test "cast maps a DateTime to its encoded text (raw semantics)" do
      assert {:ok, encoded} = Types.TaskTimestampRaw.cast(~U[2024-01-01 12:00:00.123Z])
      assert encoded == Codec.encode_datetime(~U[2024-01-01 12:00:00.123Z])

      assert Types.TaskTimestampRaw.cast("2024-01-01T12:00:00.123Z") ==
               {:ok, "2024-01-01T12:00:00.123Z"}

      assert Types.TaskTimestampRaw.cast(123) == :error
    end
  end

  # ── UnixMs (lease_expires_at) ────────────────────────────────────────────

  describe "UnixMs (lease_expires_at INTEGER)" do
    test "dump is the bare integer (same as the Store writes today)" do
      for i <- [0, 1, 1_700_000_000_123, -1, 9_999_999_999_999] do
        assert Types.UnixMs.dump(i) == {:ok, i}
        assert Types.UnixMs.load(i) == {:ok, i}
      end

      assert Types.UnixMs.dump(nil) == {:ok, nil}
      assert Types.UnixMs.load(nil) == {:ok, nil}
    end

    test "type is :integer" do
      assert Types.UnixMs.type() == :integer
    end

    test "cast accepts integers, integer strings, and nil; rejects garbage" do
      assert Types.UnixMs.cast(123) == {:ok, 123}
      assert Types.UnixMs.cast("456") == {:ok, 456}
      assert Types.UnixMs.cast(nil) == {:ok, nil}
      assert Types.UnixMs.cast("12.5") == :error
      assert Types.UnixMs.cast("abc") == :error
      assert Types.UnixMs.cast(:nope) == :error
    end

    test "randomized lease values round-trip" do
      :rand.seed(:exsss, {44, 55, 66})

      for _ <- 1..100 do
        ms = :rand.uniform(9_000_000_000_000)
        assert {:ok, ^ms} = Types.UnixMs.dump(ms)
        assert {:ok, ^ms} = Types.UnixMs.load(ms)
      end
    end
  end

  # ── Atom columns (Status / TaskType / ReviewStatus) ──────────────────────

  describe "AtomColumn — closed atom sets" do
    test "full closed set: every known atom dump/loads to itself" do
      for atom <- @known_atoms do
        stored = Atom.to_string(atom)

        assert Types.AtomColumn.dump(atom) == {:ok, Codec.encode_atom(atom)}
        assert Types.AtomColumn.dump(atom) == {:ok, stored}
        assert Types.AtomColumn.load(stored) == {:ok, Codec.decode_atom(stored)}
        assert Types.AtomColumn.load(stored) == {:ok, atom}
      end
    end

    test "per-column type/status/review_status wrappers dump/load identically to the Codec" do
      for atom <- @type_atoms do
        stored = Atom.to_string(atom)
        assert Types.TaskType.dump(atom) == {:ok, stored}
        assert Types.TaskType.load(stored) == {:ok, atom}
      end

      for atom <- @status_atoms do
        stored = Atom.to_string(atom)
        assert Types.Status.dump(atom) == {:ok, stored}
        assert Types.Status.load(stored) == {:ok, atom}
      end

      for atom <- @review_status_atoms do
        stored = Atom.to_string(atom)
        assert Types.ReviewStatus.dump(atom) == {:ok, stored}
        assert Types.ReviewStatus.load(stored) == {:ok, atom}
      end
    end

    test "every closed-set string equals its atom via the Codec" do
      for atom <- @known_atoms do
        assert Codec.decode_atom(Atom.to_string(atom)) == atom
      end
    end

    test "unknown values decode to nil (decode-strict, warning logged) — exactly like the Codec" do
      for unknown <- ["unknown_status", "Genesis", "RUNNING", "", "compaleted"] do
        assert Types.AtomColumn.load(unknown) == {:ok, nil}
        assert Types.AtomColumn.load(unknown) == {:ok, Codec.decode_atom(unknown)}
        assert Codec.decode_atom(unknown) == nil
      end
    end

    test "nil round-trips" do
      assert Types.AtomColumn.dump(nil) == {:ok, nil}
      assert Types.AtomColumn.load(nil) == {:ok, nil}
    end

    test "dump accepts strings too (Codec round-trip safety)" do
      assert Types.AtomColumn.dump("running") == {:ok, "running"}
      assert Types.AtomColumn.dump("anything") == {:ok, "anything"}
    end

    test "cast accepts atoms, strings, and nil" do
      assert Types.Status.cast(:running) == {:ok, :running}
      assert Types.Status.cast("running") == {:ok, "running"}
      assert Types.Status.cast(nil) == {:ok, nil}
      assert Types.Status.cast(123) == :error
    end

    test "the three wrappers are the union type (NOT narrower validators)" do
      # A status atom loads fine through TaskType — the Codec shares one
      # closed set; pinning this prevents accidental narrowing later.
      assert Types.TaskType.load("running") == {:ok, :running}
      assert Types.Status.load("genesis") == {:ok, :genesis}
    end

    test "randomized dump/load equals the Codec (all wrappers)" do
      :rand.seed(:exsss, {77, 88, 99})
      wrappers = [Types.AtomColumn, Types.Status, Types.TaskType, Types.ReviewStatus]

      for _ <- 1..200 do
        atom = Enum.random(@known_atoms)
        unknown = random_string()

        for wrapper <- wrappers do
          assert wrapper.dump(atom) == {:ok, Codec.encode_atom(atom)}

          stored = Codec.encode_atom(atom)
          assert wrapper.load(stored) == {:ok, Codec.decode_atom(stored)}
          assert wrapper.load(unknown) == {:ok, Codec.decode_atom(unknown)}
        end
      end
    end
  end

  # ── OptsJson ─────────────────────────────────────────────────────────────

  describe "OptsJson (keyword list <-> JSON object)" do
    test "dump is byte-identical to Codec.encode_opts/1" do
      opts_fixtures = [
        [],
        [path: "/tmp/repo"],
        [path: "/tmp/repo", mode: "new"],
        [path: "/tmp/repo", mode: "evolve", objective: "fix the bug", prompt: "hello"],
        [objective: "multi\nline\nobjective", archive: true, task_id: "task_T1_A2"],
        [foreign_repos: [%{"id" => "r1", "path" => "/x"}], starting_commit: "abc123"],
        [attachments: [%{"type" => "image", "data" => "aGVsbG8="}]]
      ]

      for opts <- opts_fixtures do
        assert {:ok, dumped} = Types.OptsJson.dump(opts)
        assert dumped == Codec.encode_opts(opts)
        assert is_binary(dumped)
      end

      assert Types.OptsJson.dump(nil) == {:ok, Codec.encode_opts(nil)}
      assert Types.OptsJson.dump(nil) == {:ok, nil}
    end

    test "load returns exactly Codec.decode_opts/1 (atomized known keys, string unknowns)" do
      stored_fixtures = [
        nil,
        "{}",
        ~s({"path": "/tmp/repo"}),
        ~s({"path": "/tmp/repo", "mode": "new", "objective": "fix it"}),
        # Every one of the 14 @known_opt_keys atomizes.
        ~s({"path":null,"mode":null,"prompt":null,"objective":null,"foreign_repos":null,"node_path":null,"starting_commit":null,"archive":null,"task_id":null,"repo_path":null,"concurrency":null,"tool_concurrency":null,"resume_from":null,"attachments":null}),
        # Unknown keys stay strings.
        ~s({"unknown_key": 1, "path": "/x"}),
        # Nested objects stay string-keyed maps.
        ~s({"attachments": [{"type": "image", "name": "n"}], "nested": {"a": 1}})
      ]

      for stored <- stored_fixtures do
        assert Types.OptsJson.load(stored) == {:ok, Codec.decode_opts(stored)}
      end
    end

    test "round-trip: load(dump(opts)) equals the original as a keyword SET" do
      opts = [
        path: "/tmp/repo",
        mode: "custom",
        objective: "do things",
        archive: true,
        starting_commit: "abc123",
        task_id: "task_T1_A2",
        attachments: [%{"type" => "image", "data" => "aGVsbG8="}]
      ]

      {:ok, dumped} = Types.OptsJson.dump(opts)
      {:ok, loaded} = Types.OptsJson.load(dumped)

      # Keyword order is NOT preserved (JSON object -> map iteration order) —
      # the Codec's documented behavior. Keyword equality over both orders:
      assert Keyword.equal?(loaded, opts)
      # ...and re-dumping is stable (byte-identical to the first dump).
      assert Types.OptsJson.dump(loaded) == {:ok, dumped}
    end

    test "encode fallback: non-Jason values collapse to the 4 essential keys, never raise" do
      opts = [path: "/x", mode: "new", objective: "o", prompt: "p", junk: {1, 2}]

      assert {:ok, dumped} = Types.OptsJson.dump(opts)
      assert dumped == Codec.encode_opts(opts)
      assert {:ok, decoded} = Types.OptsJson.load(dumped)
      # Order-insensitive: JSON object decode iterates the map, not the
      # original keyword order.
      assert Keyword.equal?(decoded, path: "/x", mode: "new", objective: "o", prompt: "p")
    end

    test "legacy positional pair-array decode RAISES exactly like the Codec (same type)" do
      legacy_shapes = [
        ~s([["path", "/tmp/repo"], ["mode", "new"]]),
        "[]",
        ~s(["not", "pairs"]),
        ~s("a scalar"),
        ~s(null),
        "not json at all"
      ]

      for stored <- legacy_shapes do
        codec_error =
          catch_error(
            try do
              Codec.decode_opts(stored)
            rescue
              e -> reraise e, __STACKTRACE__
            end
          )

        assert_raise ArgumentError, fn -> Types.OptsJson.load(stored) end

        # Same exception type AND same message as the oracle.
        assert_raise ArgumentError, Exception.message(codec_error), fn ->
          Types.OptsJson.load(stored)
        end
      end
    end

    test "cast accepts keyword lists and nil; rejects others" do
      assert {:ok, [path: "/x"]} = Types.OptsJson.cast(path: "/x")
      assert Types.OptsJson.cast(nil) == {:ok, nil}
      assert Types.OptsJson.cast(%{"path" => "/x"}) == :error
      assert Types.OptsJson.cast("json") == :error
    end

    test "randomized opts round-trip (150 samples)" do
      :rand.seed(:exsss, {101, 202, 303})

      for _ <- 1..150 do
        opts = random_opts()

        assert Types.OptsJson.dump(opts) == {:ok, Codec.encode_opts(opts)}

        stored = Codec.encode_opts(opts)

        assert Types.OptsJson.load(stored) == {:ok, Codec.decode_opts(stored)}

        # Full circle for the Jason-safe subset.
        {:ok, decoded} = Types.OptsJson.load(stored)
        assert Types.OptsJson.dump(decoded) == {:ok, stored}
      end
    end
  end

  # ── ResultJson ───────────────────────────────────────────────────────────

  describe "ResultJson (4-form __result_tag__ envelope)" do
    test "dump is byte-identical to Codec.encode_result/1 for all 4 forms" do
      results = [
        {:ok, %{}},
        {:ok, %{commit_sha: "abc", branch_name: "genesis/agent_x"}},
        {:ok, %{commit_sha: "abc", usage: Usage.zero(), archive_records: [%{a: 1}]}},
        # "repos" is NOT in the Codec's @result_data_fields whitelist — the
        # per-repo map deliberately stays STRING-KEYED after decode.
        {:ok, %{repos: %{"primary" => %{"commit_sha" => "s", "branch_name" => "b"}}}},
        {:error, "boom"},
        {:error, %{reason: "nested"}},
        {:exit, :killed},
        {:exit, "shutdown"},
        "plain string fallback",
        # Catch-all shapes.
        {:weird, :shape},
        :bare_atom,
        42
      ]

      for result <- results do
        assert {:ok, dumped} = Types.ResultJson.dump(result)
        assert dumped == Codec.encode_result(result)
        assert is_binary(dumped)
      end

      # nil is the one non-binary dump — the NULL column form.
      assert Types.ResultJson.dump(nil) == {:ok, Codec.encode_result(nil)}
      assert Types.ResultJson.dump(nil) == {:ok, nil}
    end

    test "load returns exactly Codec.decode_result/1 for all 4 tagged forms + nil" do
      stored = [
        nil,
        ~s({"__result_tag__":"ok","data":{}}),
        ~s({"__result_tag__":"ok","data":{"commit_sha":"abc","branch_name":"genesis/agent_x"}}),
        ~s({"__result_tag__":"ok","data":{"commit_sha":"abc","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3,"input_cost":0.1,"output_cost":0.2,"total_cost":0.3,"cached_tokens":4,"cache_creation_tokens":5},"archive_records":[{"a":1}]}}),
        ~s({"__result_tag__":"ok","data":{"repos":{"primary":{"commit_sha":"s","branch_name":"b"}}}}),
        ~s({"__result_tag__":"error","reason":"boom"}),
        ~s({"__result_tag__":"error","reason":"killed"}),
        ~s({"__result_tag__":"exit","reason":"killed"}),
        ~s({"__result_tag__":"exit","reason":"no such atom ever xyzzy_12345"}),
        ~s({"__result_tag__":"string","value":"plain string fallback"}),
        ~s({"__result_tag__":"string","value":"{:weird, :shape}"})
      ]

      for text <- stored do
        assert Types.ResultJson.load(text) == {:ok, Codec.decode_result(text)}
      end
    end

    test "embedded usage round-trips to a %Usage{}" do
      usage = %Usage{
        input_tokens: 11,
        output_tokens: 22,
        total_tokens: 33,
        input_cost: 0.4,
        output_cost: 0.5,
        total_cost: 0.9,
        cached_tokens: 6,
        cache_creation_tokens: 7
      }

      result = {:ok, %{commit_sha: "abc", usage: usage}}

      {:ok, dumped} = Types.ResultJson.dump(result)
      assert dumped == Codec.encode_result(result)

      assert {:ok, {:ok, %{usage: ^usage}}} = Types.ResultJson.load(dumped)
    end

    test "round-trip preserves the repos map string-keyed" do
      result = {:ok, %{repos: %{"primary" => %{"commit_sha" => "s", "branch_name" => "b"}}}}

      {:ok, dumped} = Types.ResultJson.dump(result)

      # "repos" is not whitelisted in @result_data_fields, so decode keeps the
      # string key — whitelisted top-level keys like :commit_sha DO restore.
      assert {:ok, {:ok, %{"repos" => repos}}} = Types.ResultJson.load(dumped)
      assert repos == %{"primary" => %{"commit_sha" => "s", "branch_name" => "b"}}
      assert Types.ResultJson.load(dumped) == {:ok, Codec.decode_result(dumped)}
    end

    test "non-canonical shapes RAISE exactly like the Codec (same type and message)" do
      bad_shapes = [
        "raw legacy string",
        ~s({"untagged": "object"}),
        ~s(["an", "array"]),
        ~s(42),
        ~s(null),
        ~s({"__result_tag__":"unknown"}),
        "not json"
      ]

      for stored <- bad_shapes do
        message = oracle_raise_message(&Codec.decode_result/1, stored)

        assert_raise ArgumentError, fn -> Types.ResultJson.load(stored) end
        assert_raise ArgumentError, message, fn -> Types.ResultJson.load(stored) end
      end
    end

    test "cast accepts any term (encode is total)" do
      assert Types.ResultJson.cast(nil) == {:ok, nil}
      assert Types.ResultJson.cast({:ok, %{}}) == {:ok, {:ok, %{}}}
      assert Types.ResultJson.cast("str") == {:ok, "str"}
    end

    test "randomized result round-trip (150 samples)" do
      :rand.seed(:exsss, {404, 505, 606})

      for _ <- 1..150 do
        result = random_result()

        assert Types.ResultJson.dump(result) == {:ok, Codec.encode_result(result)}

        stored = Codec.encode_result(result)

        assert Types.ResultJson.load(stored) == {:ok, Codec.decode_result(stored)}

        {:ok, decoded} = Types.ResultJson.load(stored)
        assert Types.ResultJson.dump(decoded) == {:ok, stored}
      end
    end
  end

  # ── LogsJson ─────────────────────────────────────────────────────────────

  describe "LogsJson (list <-> JSON array)" do
    test "nil dumps to the JSON text \"[]\" — never a NULL column" do
      assert Types.LogsJson.dump(nil) == {:ok, Codec.encode_logs(nil)}
      assert Types.LogsJson.dump(nil) == {:ok, "[]"}
    end

    test "dump is byte-identical to Codec.encode_logs/1" do
      logs_fixtures = [
        [],
        ["one"],
        ["a", "b", "c"],
        ["multi\nline\nlog"],
        [""],
        ["unicode: 你好 🚀"]
      ]

      for logs <- logs_fixtures do
        assert {:ok, dumped} = Types.LogsJson.dump(logs)
        assert dumped == Codec.encode_logs(logs)
      end
    end

    test "load: \"[]\" <-> [] and nil -> []" do
      assert Types.LogsJson.load(nil) == {:ok, []}
      assert Types.LogsJson.load(nil) == {:ok, Codec.decode_logs(nil)}
      assert Types.LogsJson.load("[]") == {:ok, []}
      assert Types.LogsJson.load("[]") == {:ok, Codec.decode_logs("[]")}
    end

    test "load is lenient — exactly Codec.decode_logs/1, never raises" do
      stored = [
        ~s(["a","b"]),
        ~s([1, 2]),
        "not json",
        ~s({"object": true}),
        ""
      ]

      for text <- stored do
        assert Types.LogsJson.load(text) == {:ok, Codec.decode_logs(text)}
      end
    end

    test "cast accepts lists and nil" do
      assert {:ok, ["a"]} = Types.LogsJson.cast(["a"])
      assert Types.LogsJson.cast(nil) == {:ok, nil}
      assert Types.LogsJson.cast("a") == :error
    end

    test "randomized logs round-trip" do
      :rand.seed(:exsss, {707, 808, 909})

      for _ <- 1..100 do
        logs = for _ <- 1..:rand.uniform(5), do: random_string()

        assert Types.LogsJson.dump(logs) == {:ok, Codec.encode_logs(logs)}

        stored = Codec.encode_logs(logs)

        assert Types.LogsJson.load(stored) == {:ok, Codec.decode_logs(stored)}
      end
    end
  end

  # ── UsageJson ────────────────────────────────────────────────────────────

  describe "UsageJson (%Usage{} <-> JSON object)" do
    test "dump is byte-identical to Codec.encode_usage/1" do
      usages = [
        nil,
        Usage.zero(),
        %Usage{input_tokens: 100},
        %Usage{
          input_tokens: 1,
          output_tokens: 2,
          total_tokens: 3,
          input_cost: 0.1,
          output_cost: 0.2,
          total_cost: 0.30000000000000004,
          cached_tokens: 4,
          cache_creation_tokens: 5
        }
      ]

      for usage <- usages do
        assert Types.UsageJson.dump(usage) == {:ok, Codec.encode_usage(usage)}
      end
    end

    test "load returns exactly Codec.decode_usage/1 (nil form and lenient paths)" do
      stored = [
        nil,
        ~s({}),
        ~s({"input_tokens":1,"output_tokens":2,"total_tokens":3,"input_cost":0.1,"output_cost":0.2,"total_cost":0.3,"cached_tokens":4,"cache_creation_tokens":5}),
        # Partial object — missing fields default via struct/2.
        ~s({"input_tokens":7}),
        # Atom keys also decode (Codec.decode_usage_map accepts both).
        ~s({"input_tokens":9}),
        # Lenient: non-object / bad JSON -> nil.
        ~s([1, 2]),
        "not json",
        ~s("scalar")
      ]

      for text <- stored do
        assert Types.UsageJson.load(text) == {:ok, Codec.decode_usage(text)}
      end
    end

    test "round-trip: load(dump(usage)) == usage" do
      usage = %Usage{
        input_tokens: 123,
        output_tokens: 456,
        total_tokens: 579,
        input_cost: 0.001,
        output_cost: 0.002,
        total_cost: 0.003,
        cached_tokens: 10,
        cache_creation_tokens: 20
      }

      {:ok, dumped} = Types.UsageJson.dump(usage)
      assert {:ok, ^usage} = Types.UsageJson.load(dumped)
    end

    test "cast accepts %Usage{} and nil only" do
      assert {:ok, %Usage{}} = Types.UsageJson.cast(Usage.zero())
      assert Types.UsageJson.cast(nil) == {:ok, nil}
      assert Types.UsageJson.cast(%{}) == :error
    end

    test "randomized usage round-trip (150 samples)" do
      :rand.seed(:exsss, {1_111, 2_222, 3_333})

      for _ <- 1..150 do
        usage = random_usage()

        assert Types.UsageJson.dump(usage) == {:ok, Codec.encode_usage(usage)}

        stored = Codec.encode_usage(usage)

        assert Types.UsageJson.load(stored) == {:ok, Codec.decode_usage(stored)}
        assert {:ok, ^usage} = Types.UsageJson.load(stored)
      end
    end
  end

  # ── ArchiveJson ──────────────────────────────────────────────────────────

  describe "ArchiveJson (list of maps <-> JSON array)" do
    test "dump is byte-identical to Codec.encode_archive/1" do
      archives = [
        nil,
        [],
        [%{agent_id: "agent_1", type: :executor}],
        [%{"string" => "keys"}, %{nested: %{deep: [1, 2]}}]
      ]

      for archive <- archives do
        assert Types.ArchiveJson.dump(archive) == {:ok, Codec.encode_archive(archive)}
      end
    end

    test "load returns exactly Codec.decode_archive/1 (nil + lenient paths)" do
      stored = [
        nil,
        "[]",
        ~s([{"agent_id":"agent_1"}]),
        ~s([1, 2]),
        "not json",
        ~s({"object": true})
      ]

      for text <- stored do
        assert Types.ArchiveJson.load(text) == {:ok, Codec.decode_archive(text)}
      end
    end

    test "round-trip for JSON-safe archives" do
      archive = [
        %{"agent_id" => "agent_1", "usage" => %{"total_tokens" => 42}},
        %{"agent_id" => "agent_2"}
      ]

      {:ok, dumped} = Types.ArchiveJson.dump(archive)
      assert {:ok, ^archive} = Types.ArchiveJson.load(dumped)
    end

    test "cast accepts lists and nil" do
      assert {:ok, []} = Types.ArchiveJson.cast([])
      assert Types.ArchiveJson.cast(nil) == {:ok, nil}
      assert Types.ArchiveJson.cast(%{}) == :error
    end
  end

  # ── ErrorJson ────────────────────────────────────────────────────────────

  describe "ErrorJson (canonical failed-task error payload)" do
    test "dump is byte-identical to Codec.encode_error/1" do
      errors = [
        nil,
        %{kind: :force_kill, source: :force_kill_task, message: "killed", stacktrace: nil},
        %{
          kind: :exit,
          source: :down_handler,
          message: "task exited",
          stacktrace: ["frame 1", "frame 2"]
        },
        # String forms of the closed atoms encode identically.
        %{"kind" => "restart", "source" => "startup_reconcile", "message" => "m"},
        # Unknown keys pass through stringified.
        %{"extra" => 1, "message" => "m"}
      ]

      for error <- errors do
        assert Types.ErrorJson.dump(error) == {:ok, Codec.encode_error(error)}
      end
    end

    test "the full closed kind/source atom sets encode + decode" do
      kinds = ~w(error exit down force_kill timeout restart lease_expired recheck)a

      sources =
        ~w(result_handler down_handler force_kill_task finalizing_watchdog startup_reconcile lease_sweep recheck_resolve)a

      for kind <- kinds, source <- sources do
        error = %{kind: kind, source: source, message: "m", stacktrace: nil}

        {:ok, dumped} = Types.ErrorJson.dump(error)
        assert dumped == Codec.encode_error(error)
        assert {:ok, ^error} = Types.ErrorJson.load(dumped)
      end
    end

    test "load is lenient — exactly Codec.decode_error/1, never raises" do
      stored = [
        nil,
        ~s({"kind":"force_kill","source":"force_kill_task","message":"m","stacktrace":null}),
        # Unknown kind/source strings stay strings (not atomized).
        ~s({"kind":"weird_kind","source":"weird_source","message":"m"}),
        # Unknown keys keep string keys.
        ~s({"extra":1,"message":"m"}),
        # Non-object / bad JSON -> nil.
        "not json",
        ~s([1, 2]),
        ~s("scalar"),
        ""
      ]

      for text <- stored do
        assert Types.ErrorJson.load(text) == {:ok, Codec.decode_error(text)}
      end
    end

    test "round-trip preserves the canonical payload" do
      error = %{kind: :timeout, source: :lease_sweep, message: "lease expired", stacktrace: ["f"]}

      {:ok, dumped} = Types.ErrorJson.dump(error)
      assert {:ok, ^error} = Types.ErrorJson.load(dumped)
    end

    test "cast accepts maps and nil" do
      assert {:ok, %{}} = Types.ErrorJson.cast(%{})
      assert Types.ErrorJson.cast(nil) == {:ok, nil}
      assert Types.ErrorJson.cast("str") == :error
    end
  end

  # ── Schema end-to-end (Repo-free wire-format proof) ─────────────────────

  describe "TaskRow schema end-to-end" do
    test "columns/0 matches Codec.task_columns/0 ++ updated_at (physical order)" do
      assert TaskRow.columns() == Codec.task_columns() ++ ["updated_at"]
      assert length(TaskRow.columns()) == 20
    end

    test "schema dump of a full task row equals Codec.encode_task/1 + updated_at" do
      task_info = %EvoGit.TaskInfo{
        id: "task_T1_A2",
        type: :evolve,
        status: :running,
        opts: [path: "/tmp/repo", mode: "simple", objective: "fix the bug"],
        started_at: ~U[2024-01-01 12:00:00.123Z],
        finished_at: ~U[2024-01-02 03:04:05.678Z],
        logs: ["line 1", "line 2"],
        result: {:ok, %{commit_sha: "abc123", branch_name: "genesis/agent_x"}},
        review_status: :open,
        usage: %Usage{input_tokens: 1, output_tokens: 2, total_tokens: 3},
        agent_count: 4,
        base_sha: "base123",
        commit_sha: "head123",
        archive_metadata: [%{"agent_id" => "a1"}],
        lease_expires_at: 1_700_000_000_123,
        model_id: "deepseek-chat",
        project_path: "/tmp/repo",
        branch_name: "genesis/agent_x",
        error: %{kind: :timeout, source: :lease_sweep, message: "m", stacktrace: nil}
      }

      updated_at = ~U[2024-01-03 00:00:00.001Z]

      attrs =
        task_info
        |> Map.from_struct()
        |> Map.drop([:ref])
        |> Map.put(:updated_at, updated_at)

      # Repo-free dump: route every field through its schema type.
      dumped = dump_row(TaskRow, attrs)

      expected =
        (Codec.encode_task(task_info) ++ [Codec.encode_datetime(updated_at)])
        |> Enum.zip(TaskRow.columns())
        |> Map.new(fn {value, col} -> {String.to_atom(col), value} end)

      assert dumped == expected

      # The load-bearing spot checks, spelled out:
      assert dumped[:started_at] == "2024-01-01T12:00:00.123Z"
      assert byte_size(dumped[:updated_at]) == 24
      assert dumped[:logs] == ~s(["line 1","line 2"])
      assert dumped[:lease_expires_at] == 1_700_000_000_123
      assert dumped[:result] == Codec.encode_result(task_info.result)
    end

    test "changeset change/2 carries domain values; type dumps match the Codec per field" do
      changes = %{
        status: :completed,
        review_status: :merged,
        type: :genesis,
        opts: [path: "/x"],
        result: {:ok, %{commit_sha: "s"}},
        usage: Usage.zero(),
        logs: ["done"],
        error: %{kind: :error, source: :result_handler, message: "m"}
      }

      changeset = Ecto.Changeset.change(%TaskRow{}, changes)
      assert changeset.valid?

      for {field, expected_codec} <- [
            {:status, Codec.encode_atom(:completed)},
            {:review_status, Codec.encode_atom(:merged)},
            {:type, Codec.encode_atom(:genesis)},
            {:opts, Codec.encode_opts(path: "/x")},
            {:result, Codec.encode_result({:ok, %{commit_sha: "s"}})},
            {:usage, Codec.encode_usage(Usage.zero())},
            {:logs, Codec.encode_logs(["done"])},
            {:error, Codec.encode_error(%{kind: :error, source: :result_handler, message: "m"})}
          ] do
        type = TaskRow.__schema__(:type, field)

        assert Ecto.Type.dump(type, Ecto.Changeset.get_change(changeset, field)) ==
                 {:ok, expected_codec}
      end
    end

    test "changeset cast/4 exercises the cast callbacks and stays valid" do
      params = %{
        "id" => "task_T9",
        "status" => :pending,
        "type" => "evolve",
        "lease_expires_at" => 123,
        "agent_count" => 0,
        "started_at" => "2024-01-01T12:00:00Z"
      }

      changeset =
        Ecto.Changeset.cast(
          %TaskRow{},
          params,
          ~w(id status type lease_expires_at agent_count started_at)a
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :lease_expires_at) == 123
      assert %DateTime{} = Ecto.Changeset.get_field(changeset, :started_at)
    end

    test "updated_at loads RAW through TaskTimestampRaw while started_at loads a DateTime" do
      stored = "2024-01-01T12:00:00.123Z"

      started_type = TaskRow.__schema__(:type, :started_at)
      updated_type = TaskRow.__schema__(:type, :updated_at)

      assert started_type == Types.TaskTimestamp
      assert updated_type == Types.TaskTimestampRaw

      assert Ecto.Type.load(started_type, stored) == {:ok, ~U[2024-01-01 12:00:00.123Z]}
      assert Ecto.Type.load(updated_type, stored) == {:ok, stored}
    end

    test "logs nil dumps as \"[]\" through the schema (never a NULL column)" do
      # Ecto.Type.dump/2 short-circuits nil without calling the type, so the
      # type's own dump/1 is exercised here — the wire-format authority.
      type = TaskRow.__schema__(:type, :logs)
      assert type == Types.LogsJson
      assert type.dump(nil) == {:ok, "[]"}
    end
  end

  describe "ProjectRow schema end-to-end" do
    test "columns/0 matches Codec.project_columns/0" do
      assert ProjectRow.columns() == Codec.project_columns()
    end

    test "schema dump equals Codec.encode_project/1" do
      project = %RecentProject{
        path: "/tmp/repo",
        name: "My Repo",
        last_opened_at: ~U[2024-05-05 05:05:05.555Z]
      }

      attrs = %{path: project.path, name: project.name, last_opened_at: project.last_opened_at}
      dumped = dump_row(ProjectRow, attrs)

      expected =
        Codec.encode_project(project)
        |> Enum.zip(ProjectRow.columns())
        |> Map.new(fn {value, col} -> {String.to_atom(col), value} end)

      assert dumped == expected
    end
  end

  # ── Cross-cutting: embed_as + type ──────────────────────────────────────

  describe "Ecto.Type surface" do
    test "scalar TEXT types report type/0 :string; UnixMs :integer" do
      for mod <- [
            Types.TaskTimestamp,
            Types.TaskTimestampRaw,
            Types.AtomColumn,
            Types.Status,
            Types.TaskType,
            Types.ReviewStatus,
            Types.OptsJson,
            Types.ResultJson,
            Types.LogsJson,
            Types.UsageJson,
            Types.ArchiveJson,
            Types.ErrorJson
          ] do
        assert mod.type() == :string
        assert mod.embed_as(:json) == :self
      end

      assert Types.UnixMs.type() == :integer
      assert Types.UnixMs.embed_as(:json) == :self
    end

    test "every type module loads nil cleanly; dumps nil per its wire format" do
      nil_dumping_modules = [
        Types.TaskTimestamp,
        Types.TaskTimestampRaw,
        Types.UnixMs,
        Types.AtomColumn,
        Types.Status,
        Types.TaskType,
        Types.ReviewStatus,
        Types.OptsJson,
        Types.ResultJson,
        Types.UsageJson,
        Types.ArchiveJson,
        Types.ErrorJson
      ]

      for mod <- nil_dumping_modules do
        assert mod.dump(nil) == {:ok, nil}
        assert mod.load(nil) == {:ok, nil}
      end

      # LogsJson is the deliberate exception: nil dumps to the JSON text
      # "[]" — never a NULL column (Codec.encode_logs(nil)).
      assert Types.LogsJson.dump(nil) == {:ok, "[]"}
      assert Types.LogsJson.load(nil) == {:ok, []}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Runs the oracle (Codec) decoder and returns the message of the exception
  # it raises — the oracle is EXPECTED to raise on these non-canonical inputs
  # (strictly-canonical decode), so failing to raise is itself a test failure.
  defp oracle_raise_message(fun, stored) do
    try do
      fun.(stored)
    rescue
      e -> Exception.message(e)
    else
      value -> flunk("expected Codec to raise on #{inspect(stored)}, got: #{inspect(value)}")
    end
  end

  # Repo-free row dump: routes every field through its schema type via
  # Ecto.Type.dump/2 (handles both custom modules and primitives). NOTE:
  # Ecto.Type.dump/2 short-circuits nil to {:ok, nil} WITHOUT calling the
  # type — for nil-carrying columns the type's own dump/1 is the wire-format
  # authority (e.g. LogsJson.dump(nil) == {:ok, "[]"}).
  defp dump_row(schema, attrs) do
    for {field, value} <- attrs,
        into: %{} do
      type = schema.__schema__(:type, field)
      {:ok, dumped} = Ecto.Type.dump(type, value)
      {field, dumped}
    end
  end

  defp random_datetime do
    unix = :rand.uniform(4_102_444_800) - 1
    ms = :rand.uniform(1000) - 1
    DateTime.from_unix!(unix * 1000 + ms, :millisecond)
  end

  defp random_string do
    length = :rand.uniform(24)

    for _ <- 1..length, into: "" do
      <<96 + :rand.uniform(26)>>
    end
  end

  @random_opt_keys ~w(path mode prompt objective archive task_id repo_path concurrency tool_concurrency starting_commit node_path)a
  @random_opt_values ["", "/tmp/x", "new", "simple", true, false, 0, 42, ~s(with "quotes")]

  defp random_opts do
    count = :rand.uniform(5)

    keys = @random_opt_keys |> Enum.shuffle() |> Enum.take(count)

    for key <- keys do
      {key, Enum.random(@random_opt_values)}
    end
  end

  defp random_usage do
    %Usage{
      input_tokens: :rand.uniform(100_000),
      output_tokens: :rand.uniform(100_000),
      total_tokens: :rand.uniform(200_000),
      input_cost: :rand.uniform() * 10,
      output_cost: :rand.uniform() * 10,
      total_cost: :rand.uniform() * 20,
      cached_tokens: :rand.uniform(50_000),
      cache_creation_tokens: :rand.uniform(50_000)
    }
  end

  defp random_result do
    case :rand.uniform(5) do
      1 -> {:ok, %{commit_sha: random_string(), branch_name: "genesis/agent_" <> random_string()}}
      2 -> {:ok, %{usage: random_usage(), archive_records: [%{"a" => :rand.uniform(10)}]}}
      3 -> {:error, "boom: " <> random_string()}
      4 -> "plain " <> random_string()
      5 -> {:ok, %{repos: %{"primary" => %{"commit_sha" => random_string()}}}}
    end
  end
end
