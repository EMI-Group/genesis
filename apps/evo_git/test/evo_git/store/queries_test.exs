defmodule EvoGit.Store.QueriesTest do
  use ExUnit.Case, async: true

  alias EvoGit.Store.Codec
  alias EvoGit.Store.Queries

  # ── SELECT SQL builders ──────────────────────────────────────────────

  describe "task_select_sql/0" do
    test "returns a SELECT statement selecting from the tasks table" do
      sql = Queries.task_select_sql()

      assert String.starts_with?(sql, "SELECT ")
      assert String.ends_with?(sql, " FROM tasks")
    end

    test "includes all task columns from Codec.task_columns/0" do
      sql = Queries.task_select_sql()

      for col <- Codec.task_columns() do
        assert String.contains?(sql, col),
               "expected SQL to contain column #{inspect(col)}"
      end
    end

    test "columns are comma-separated" do
      sql = Queries.task_select_sql()

      columns_part =
        String.replace_prefix(sql, "SELECT ", "") |> String.replace_suffix(" FROM tasks", "")

      parts = String.split(columns_part, ", ")
      assert length(parts) == length(Codec.task_columns())
    end

    test "matches the expected full SQL string" do
      expected = "SELECT #{Enum.join(Codec.task_columns(), ", ")} FROM tasks"
      assert Queries.task_select_sql() == expected
    end
  end

  describe "project_select_sql/0" do
    test "returns a SELECT statement selecting from the projects table" do
      sql = Queries.project_select_sql()

      assert String.starts_with?(sql, "SELECT ")
      assert String.ends_with?(sql, " FROM projects")
    end

    test "includes all project columns from Codec.project_columns/0" do
      sql = Queries.project_select_sql()

      for col <- Codec.project_columns() do
        assert String.contains?(sql, col),
               "expected SQL to contain column #{inspect(col)}"
      end
    end

    test "matches the expected full SQL string" do
      expected = "SELECT #{Enum.join(Codec.project_columns(), ", ")} FROM projects"
      assert Queries.project_select_sql() == expected
    end
  end

  # ── build_update_set/2 ───────────────────────────────────────────────

  describe "build_update_set/2" do
    test "builds a single-column SET clause starting at index 1" do
      {clause, values} = Queries.build_update_set([status: :running], 1)

      assert clause == "status = ?1"
      assert values == ["running"]
    end

    test "builds a multi-column SET clause with incremental indices" do
      {clause, values} =
        Queries.build_update_set([status: :completed, model_id: "gpt-4", agent_count: 3], 1)

      assert clause == "status = ?1, model_id = ?2, agent_count = ?3"
      assert values == ["completed", "gpt-4", 3]
    end

    test "respects a custom start index" do
      {clause, values} = Queries.build_update_set([branch_name: "genesis/agent_abc"], 5)

      assert clause == "branch_name = ?5"
      assert values == ["genesis/agent_abc"]
    end

    test "handles an empty column list" do
      {clause, values} = Queries.build_update_set([], 1)

      assert clause == ""
      assert values == []
    end

    test "encodes datetime columns" do
      dt = ~U[2024-06-15 10:30:00.500Z]
      {clause, values} = Queries.build_update_set([started_at: dt, finished_at: dt], 1)

      assert clause == "started_at = ?1, finished_at = ?2"
      assert values == ["2024-06-15T10:30:00.500Z", "2024-06-15T10:30:00.500Z"]
    end

    test "encodes nil values for atom columns as nil (nil guard fires first)" do
      {clause, values} = Queries.build_update_set([status: nil, model_id: "x"], 1)

      assert clause == "status = ?1, model_id = ?2"
      assert values == [nil, "x"]
    end

    test "encodes nil for logs as nil (nil guard takes precedence over encode_logs/1)" do
      {_clause, [encoded]} = Queries.build_update_set([logs: nil], 1)

      # encode_column_value(:logs, nil) → nil (not Codec.encode_logs(nil) which is "[]")
      assert encoded == nil
    end

    test "encodes logs list as JSON" do
      {_clause, [encoded]} = Queries.build_update_set([logs: ["line1", "line2"]], 1)

      assert Jason.decode!(encoded) == ["line1", "line2"]
    end

    test "encodes opts as JSON object" do
      {_clause, [encoded]} = Queries.build_update_set([opts: [path: "/repo", mode: "simple"]], 1)

      decoded = Jason.decode!(encoded)
      assert decoded["path"] == "/repo"
      assert decoded["mode"] == "simple"
    end

    test "encodes result tuple as tagged JSON" do
      {_clause, [encoded]} = Queries.build_update_set([result: {:ok, %{commit_sha: "abc"}}], 1)

      decoded = Jason.decode!(encoded)
      assert decoded["__result_tag__"] == "ok"
      assert decoded["data"]["commit_sha"] == "abc"
    end

    test "encodes result nil as nil" do
      {_clause, [encoded]} = Queries.build_update_set([result: nil], 1)
      assert encoded == nil
    end

    test "encodes archive_metadata as JSON" do
      archive = [%{"id" => "a1", "agent_count" => 2}]
      {_clause, [encoded]} = Queries.build_update_set([archive_metadata: archive], 1)

      assert Jason.decode!(encoded) == archive
    end

    test "passthrough columns return their raw values" do
      columns = [
        project_path: "/repo",
        branch_name: "genesis/agent_x",
        agent_count: 5,
        lease_expires_at: "2024-01-01T00:00:00.000Z",
        model_id: "claude-3",
        base_sha: "aaa111",
        commit_sha: "bbb222"
      ]

      {clause, values} = Queries.build_update_set(columns, 1)

      for {{col, _val}, idx} <- Enum.with_index(columns, 1) do
        assert String.contains?(clause, "#{col} = ?#{idx}")
      end

      assert values == Enum.map(columns, &elem(&1, 1))
    end

    test "encodes review_status as atom (string)" do
      {_clause, [encoded]} = Queries.build_update_set([review_status: :merged], 1)
      assert encoded == "merged"
    end
  end

  # ── encode_column_value/2 ────────────────────────────────────────────

  describe "encode_column_value/2" do
    test "returns nil for any column with a nil value" do
      assert Queries.encode_column_value(:status, nil) == nil
      assert Queries.encode_column_value(:logs, nil) == nil
      assert Queries.encode_column_value(:unknown, nil) == nil
    end

    test "encodes :status via Codec.encode_atom/1" do
      assert Queries.encode_column_value(:status, :running) == "running"
      assert Queries.encode_column_value(:status, :completed) == "completed"
      assert Queries.encode_column_value(:status, "cancelled") == "cancelled"
    end

    test "encodes :type via Codec.encode_atom/1" do
      assert Queries.encode_column_value(:type, :genesis) == "genesis"
      assert Queries.encode_column_value(:type, :evolve) == "evolve"
    end

    test "encodes :review_status via Codec.encode_atom/1" do
      assert Queries.encode_column_value(:review_status, :merged) == "merged"
      assert Queries.encode_column_value(:review_status, :rejected) == "rejected"
    end

    test "encodes :started_at, :finished_at, :updated_at via Codec.encode_datetime/1" do
      dt = ~U[2024-03-20 08:00:00.500Z]
      expected = "2024-03-20T08:00:00.500Z"

      assert Queries.encode_column_value(:started_at, dt) == expected
      assert Queries.encode_column_value(:finished_at, dt) == expected
      assert Queries.encode_column_value(:updated_at, dt) == expected
    end

    test "encodes :logs via Codec.encode_logs/1" do
      assert Queries.encode_column_value(:logs, ["a", "b"]) == ~s(["a","b"])
      assert Queries.encode_column_value(:logs, []) == "[]"
    end

    test "encodes :result via Codec.encode_result/1" do
      encoded = Queries.encode_column_value(:result, {:ok, %{commit_sha: "abc"}})
      decoded = Jason.decode!(encoded)
      assert decoded["__result_tag__"] == "ok"
    end

    test "encodes :usage via Codec.encode_usage/1" do
      usage = %EvoGit.Agent.Usage{input_tokens: 100, total_tokens: 200}
      encoded = Queries.encode_column_value(:usage, usage)
      decoded = Jason.decode!(encoded)
      assert decoded["input_tokens"] == 100
      assert decoded["total_tokens"] == 200
    end

    test "encodes :opts via Codec.encode_opts/1" do
      encoded = Queries.encode_column_value(:opts, path: "/repo")
      decoded = Jason.decode!(encoded)
      assert decoded["path"] == "/repo"
    end

    test "encodes :archive_metadata via Codec.encode_archive/1" do
      encoded = Queries.encode_column_value(:archive_metadata, [%{"id" => "a"}])
      assert Jason.decode!(encoded) == [%{"id" => "a"}]
    end

    test "passes through scalar columns as-is" do
      assert Queries.encode_column_value(:project_path, "/repo") == "/repo"
      assert Queries.encode_column_value(:branch_name, "genesis/agent_1") == "genesis/agent_1"
      assert Queries.encode_column_value(:agent_count, 5) == 5
      assert Queries.encode_column_value(:lease_expires_at, "iso-string") == "iso-string"
      assert Queries.encode_column_value(:model_id, "gpt-4") == "gpt-4"
      assert Queries.encode_column_value(:base_sha, "abc123") == "abc123"
      assert Queries.encode_column_value(:commit_sha, "def456") == "def456"
    end

    test "unknown columns pass value through as-is" do
      assert Queries.encode_column_value(:some_new_col, "value") == "value"
      assert Queries.encode_column_value(:custom, 42) == 42
    end
  end

  # ── clamp_limit/1 ────────────────────────────────────────────────────

  describe "clamp_limit/1" do
    test "defaults to 50 when nil" do
      assert Queries.clamp_limit(nil) == 50
    end

    test "returns positive integers unchanged" do
      assert Queries.clamp_limit(1) == 1
      assert Queries.clamp_limit(50) == 50
      assert Queries.clamp_limit(100) == 100
      assert Queries.clamp_limit(1_000_000) == 1_000_000
    end

    test "falls back to 50 for zero" do
      assert Queries.clamp_limit(0) == 50
    end

    test "falls back to 50 for negative integers" do
      assert Queries.clamp_limit(-1) == 50
      assert Queries.clamp_limit(-100) == 50
    end

    test "falls back to 50 for non-integer values" do
      assert Queries.clamp_limit("10") == 50
      assert Queries.clamp_limit(10.5) == 50
      assert Queries.clamp_limit(:ten) == 50
      assert Queries.clamp_limit([10]) == 50
      assert Queries.clamp_limit(%{limit: 10}) == 50
    end
  end

  # ── clamp_offset/1 ───────────────────────────────────────────────────

  describe "clamp_offset/1" do
    test "defaults to 0 when nil" do
      assert Queries.clamp_offset(nil) == 0
    end

    test "returns non-negative integers unchanged" do
      assert Queries.clamp_offset(0) == 0
      assert Queries.clamp_offset(10) == 10
      assert Queries.clamp_offset(500) == 500
    end

    test "falls back to 0 for negative integers" do
      assert Queries.clamp_offset(-1) == 0
      assert Queries.clamp_offset(-50) == 0
    end

    test "falls back to 0 for non-integer values" do
      assert Queries.clamp_offset("10") == 0
      assert Queries.clamp_offset(10.5) == 0
      assert Queries.clamp_offset(:ten) == 0
      assert Queries.clamp_offset([0]) == 0
    end
  end

  # ── build_where/1 ────────────────────────────────────────────────────

  describe "build_where/1" do
    test "returns empty clause and params with no filters" do
      assert Queries.build_where([]) == {"", []}
    end

    test "returns empty clause when status is 'all' and no other filters" do
      assert Queries.build_where(status: "all") == {"", []}
    end

    test "status 'all' is the default when key is absent" do
      assert Queries.build_where([]) == Queries.build_where(status: "all")
    end

    # -- status filter --

    test "specific status filter produces a WHERE clause" do
      {clause, params} = Queries.build_where(status: "running")

      assert clause == " WHERE status = ?1"
      assert params == ["running"]
    end

    test "status filter with a different value" do
      {clause, params} = Queries.build_where(status: "completed")

      assert clause == " WHERE status = ?1"
      assert params == ["completed"]
    end

    test "status filter accepts an atom value" do
      {clause, params} = Queries.build_where(status: :pending)

      assert clause == " WHERE status = ?1"
      assert params == [:pending]
    end

    # -- project_path filter --

    test "specific project_path filter" do
      {clause, params} = Queries.build_where(project_path: "/repo")

      assert clause == " WHERE project_path = ?1"
      assert params == ["/repo"]
    end

    test "project_path 'all' produces no clause" do
      assert Queries.build_where(project_path: "all") == {"", []}
    end

    test "status + project_path combined increments index" do
      {clause, params} = Queries.build_where(status: "running", project_path: "/repo")

      assert clause == " WHERE status = ?1 AND project_path = ?2"
      assert params == ["running", "/repo"]
    end

    # -- review_status filter --

    test "review_status 'all' produces no clause" do
      assert Queries.build_where(review_status: "all") == {"", []}
    end

    test "review_status 'pending' produces composite clause" do
      {clause, params} = Queries.build_where(review_status: "pending")

      assert clause == " WHERE status = ?1 AND review_status IS NULL AND branch_name IS NOT NULL"
      assert params == ["completed"]
    end

    test "specific review_status produces a simple clause" do
      {clause, params} = Queries.build_where(review_status: "merged")

      assert clause == " WHERE review_status = ?1"
      assert params == ["merged"]
    end

    test "review_status 'rejected'" do
      {clause, params} = Queries.build_where(review_status: "rejected")

      assert clause == " WHERE review_status = ?1"
      assert params == ["rejected"]
    end

    test "review_status 'continued'" do
      {clause, params} = Queries.build_where(review_status: "continued")

      assert clause == " WHERE review_status = ?1"
      assert params == ["continued"]
    end

    test "status + specific review_status combined" do
      {clause, params} = Queries.build_where(status: "completed", review_status: "merged")

      assert clause == " WHERE status = ?1 AND review_status = ?2"
      assert params == ["completed", "merged"]
    end

    test "status + review_status 'pending' produces both status clauses" do
      {clause, params} = Queries.build_where(status: "completed", review_status: "pending")

      # The status filter adds status=?1, then "pending" adds status=?2 + IS NULL + NOT NULL
      assert clause ==
               " WHERE status = ?1 AND status = ?2 AND review_status IS NULL AND branch_name IS NOT NULL"

      assert params == ["completed", "completed"]
    end

    # -- search filter --

    test "nil search produces no clause" do
      assert Queries.build_where(search: nil) == {"", []}
    end

    test "empty string search produces no clause" do
      assert Queries.build_where(search: "") == {"", []}
    end

    test "search produces a LIKE clause with ESCAPE for id, opts, project_path, and result" do
      {clause, params} = Queries.build_where(search: "foo")

      assert String.contains?(clause, "(id LIKE ?1 ESCAPE '\\'")
      assert String.contains?(clause, "opts LIKE ?2 ESCAPE '\\'")
      assert String.contains?(clause, "project_path LIKE ?3 ESCAPE '\\'")
      assert String.contains?(clause, "result LIKE ?4 ESCAPE '\\')")
      assert String.starts_with?(clause, " WHERE (")
      assert params == ["%foo%", "%foo%", "%foo%", "%foo%"]
    end

    test "search OR-group joins all four LIKE surfaces (id, opts, project_path, result)" do
      {clause, _params} = Queries.build_where(search: "foo")

      assert String.contains?(
               clause,
               "id LIKE ?1 ESCAPE '\\' OR opts LIKE ?2 ESCAPE '\\' OR project_path LIKE ?3 ESCAPE '\\' OR result LIKE ?4 ESCAPE '\\')"
             )
    end

    test "search escapes special LIKE characters in the pattern" do
      {_clause, params} = Queries.build_where(search: "100%")

      # % is escaped to \% so it's matched literally
      assert hd(params) == "%100\\%%"
    end

    test "search with status filter increments index correctly" do
      {clause, params} = Queries.build_where(status: "running", search: "foo")

      assert String.contains?(clause, "status = ?1")
      assert String.contains?(clause, "id LIKE ?2 ESCAPE")
      assert String.contains?(clause, "opts LIKE ?3 ESCAPE")
      assert String.contains?(clause, "project_path LIKE ?4 ESCAPE")
      assert String.contains?(clause, "result LIKE ?5 ESCAPE")
      assert params == ["running", "%foo%", "%foo%", "%foo%", "%foo%"]
    end

    # -- combined filters --

    test "all three non-pending filters combined" do
      {clause, params} =
        Queries.build_where(status: "running", project_path: "/repo", review_status: "merged")

      assert clause == " WHERE status = ?1 AND project_path = ?2 AND review_status = ?3"
      assert params == ["running", "/repo", "merged"]
    end

    test "status + project_path + search combined" do
      {clause, params} =
        Queries.build_where(status: "completed", project_path: "/repo", search: "abc")

      assert String.contains?(clause, "status = ?1")
      assert String.contains?(clause, "project_path = ?2")
      assert String.contains?(clause, "id LIKE ?3 ESCAPE")
      assert String.contains?(clause, "opts LIKE ?4 ESCAPE")
      assert String.contains?(clause, "project_path LIKE ?5 ESCAPE")
      assert String.contains?(clause, "result LIKE ?6 ESCAPE")
      assert params == ["completed", "/repo", "%abc%", "%abc%", "%abc%", "%abc%"]
    end

    test "all filters combined including search" do
      {clause, params} =
        Queries.build_where(
          status: "running",
          project_path: "/repo",
          review_status: "rejected",
          search: "test"
        )

      assert String.contains?(clause, "status = ?1")
      assert String.contains?(clause, "project_path = ?2")
      assert String.contains?(clause, "review_status = ?3")
      assert String.contains?(clause, "id LIKE ?4 ESCAPE")
      assert String.contains?(clause, "opts LIKE ?5 ESCAPE")
      assert String.contains?(clause, "project_path LIKE ?6 ESCAPE")
      assert String.contains?(clause, "result LIKE ?7 ESCAPE")
      assert params == ["running", "/repo", "rejected", "%test%", "%test%", "%test%", "%test%"]
    end
  end

  # ── escape_like/1 ────────────────────────────────────────────────────

  describe "escape_like/1" do
    test "leaves plain text unchanged" do
      assert Queries.escape_like("hello") == "hello"
      assert Queries.escape_like("plain text") == "plain text"
      assert Queries.escape_like("/home/user/project") == "/home/user/project"
    end

    test "escapes backslashes by doubling them" do
      assert Queries.escape_like("a\\b") == "a\\\\b"
      assert Queries.escape_like("\\") == "\\\\"
    end

    test "escapes percent signs" do
      assert Queries.escape_like("100%") == "100\\%"
      assert Queries.escape_like("%") == "\\%"
    end

    test "escapes underscores" do
      assert Queries.escape_like("my_var") == "my\\_var"
      assert Queries.escape_like("_") == "\\_"
    end

    test "escapes all special characters combined" do
      assert Queries.escape_like("%_\\") == "\\%\\_\\\\"
    end

    test "escapes multiple occurrences of each special character" do
      assert Queries.escape_like("a%b%c") == "a\\%b\\%c"
      assert Queries.escape_like("x_y_z") == "x\\_y\\_z"
    end

    test "returns empty string for empty input" do
      assert Queries.escape_like("") == ""
    end

    test "processes backslash-first then percent (documented order)" do
      # The function processes backslash FIRST (doubling it), then escapes %.
      # Input \% (2 chars) → \\% after backslash pass → \\\% after percent pass.
      assert Queries.escape_like("\\%") == "\\\\\\%"
    end

    test "project path with underscores is properly escaped" do
      assert Queries.escape_like("/repo/my_project_name") == "/repo/my\\_project\\_name"
    end
  end
end
