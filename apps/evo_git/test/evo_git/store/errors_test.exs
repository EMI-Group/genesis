defmodule EvoGit.Store.ErrorsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Store.Errors

  describe "disk_full_error?/1" do
    # -- read_only_database (SQLITE_READONLY) --

    test "returns true for read_only_database error" do
      assert Errors.disk_full_error?(
               {:error, {:read_only_database, 8, "attempt to write a readonly database"}}
             )
    end

    test "returns true for read_only_database with nil message" do
      assert Errors.disk_full_error?({:error, {:read_only_database, 0, nil}})
    end

    # -- sqlite_failure with disk-full codes (8, 10, 13) --

    test "returns true for sqlite_failure code 8 (SQLITE_READONLY)" do
      assert Errors.disk_full_error?({:error, {:sqlite_failure, 8, 8, "readonly"}})
    end

    test "returns true for sqlite_failure code 10 (SQLITE_IOERR)" do
      assert Errors.disk_full_error?({:error, {:sqlite_failure, 10, 10, "disk I/O error"}})
    end

    test "returns true for sqlite_failure code 13 (SQLITE_FULL)" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 13, 13, "database or disk is full"}}
             )
    end

    # -- sqlite_failure with non-disk-full codes --

    test "returns false for sqlite_failure code 7 (not a disk-full code)" do
      refute Errors.disk_full_error?({:error, {:sqlite_failure, 7, 7, "some error"}})
    end

    test "returns false for sqlite_failure code 1 (SQLITE_ERROR)" do
      refute Errors.disk_full_error?({:error, {:sqlite_failure, 1, 1, "SQL logic error"}})
    end

    test "returns false for sqlite_failure code 19 (SQLITE_CONSTRAINT)" do
      refute Errors.disk_full_error?({:error, {:sqlite_failure, 19, 19, "constraint failed"}})
    end

    # -- message-text fallback --

    test "returns true for non-disk-full code but canonical SQLITE_FULL message" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 5, 5, "database or disk is full"}}
             )
    end

    test "returns true for message fallback with nil extended_code" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 5, nil, "database or disk is full"}}
             )
    end

    test "returns false for non-disk-full code with a different message" do
      refute Errors.disk_full_error?({:error, {:sqlite_failure, 5, 5, "some other error"}})
    end

    test "returns false for non-disk-full code with nil message" do
      refute Errors.disk_full_error?({:error, {:sqlite_failure, 5, 5, nil}})
    end

    # -- case-insensitive message matching --

    test "message match is case-insensitive (uppercase)" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 5, 5, "DATABASE OR DISK IS FULL"}}
             )
    end

    test "message match is case-insensitive (mixed case)" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 5, 5, "Database Or Disk Is Full"}}
             )
    end

    test "message match works when canonical text is embedded in a larger message" do
      assert Errors.disk_full_error?(
               {:error, {:sqlite_failure, 5, 5, "error: database or disk is full (code 13)"}}
             )
    end

    # -- non-error inputs --

    test "returns false for {:ok, _}" do
      refute Errors.disk_full_error?({:ok, %{rows: []}})
    end

    test "returns false for nil" do
      refute Errors.disk_full_error?(nil)
    end

    test "returns false for a plain atom" do
      refute Errors.disk_full_error?(:error)
      refute Errors.disk_full_error?(:ok)
    end

    test "returns false for a non-tuple value" do
      refute Errors.disk_full_error?("some string")
      refute Errors.disk_full_error?(42)
      refute Errors.disk_full_error?([1, 2, 3])
    end

    # -- other error shapes that are NOT disk-full --

    test "returns false for constraint_violation error" do
      refute Errors.disk_full_error?(
               {:error, {:constraint_violation, :constraint_trigger, %{message: "RAISE"}}}
             )
    end

    test "returns false for a generic error tuple not matching any arm" do
      refute Errors.disk_full_error?({:error, :something_else})
      refute Errors.disk_full_error?({:error, {:timeout, "timeout"}})
    end
  end

  describe "disk_full_exception?/1" do
    # -- sqlite_failure with disk-full primary codes (8, 10, 13) --

    test "returns true for sqlite_failure code 8 (SQLITE_READONLY)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{code: 8, extended_code: 8}
             })
    end

    test "returns true for sqlite_failure code 10 (SQLITE_IOERR)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{code: 10, extended_code: 10}
             })
    end

    test "returns true for sqlite_failure code 13 (SQLITE_FULL)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{code: 13, extended_code: 13}
             })
    end

    test "code match is decisive — a disk-full code matches even with an unrelated message" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: unrelated",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 13,
                 extended_code: 13,
                 message: "unrelated"
               }
             })
    end

    # -- sqlite_failure with non-disk-full codes --

    test "returns false for sqlite_failure code 5 (SQLITE_BUSY) with a different message" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: database is locked",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 extended_code: 5,
                 message: "database is locked"
               }
             })
    end

    test "returns false for sqlite_failure code 19 (SQLITE_CONSTRAINT)" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: constraint failed",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 19,
                 extended_code: 19,
                 message: "constraint failed"
               }
             })
    end

    test "only the PRIMARY code is matched — extended_code 13 with primary 5 is false" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: database is locked",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 extended_code: 13,
                 message: "database is locked"
               }
             })
    end

    test "returns false for plain-map details (SqliteFailure struct required)" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %{code: 7}
             })
    end

    test "plain-map details never match the code arm, even with code 13" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %{code: 13}
             })
    end

    # -- read_only_database --

    test "returns true for read_only_database with extended_code details and a message" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "attempt to write a readonly database",
               type: :read_only_database,
               details: %{extended_code: 8}
             })
    end

    test "returns true for read_only_database with a message inside details" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :read_only_database,
               details: %{extended_code: 8, message: "attempt to write a readonly database"}
             })
    end

    test "returns true for read_only_database with no message anywhere" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :read_only_database,
               details: %{extended_code: 8}
             })
    end

    test "returns true for read_only_database with nil details" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{type: :read_only_database})
    end

    # -- message-text fallback --

    test "returns true for non-disk-full code with the canonical message in details" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: database or disk is full",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 extended_code: 5,
                 message: "database or disk is full"
               }
             })
    end

    test "returns true when only the top-level message carries the canonical text" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: database or disk is full",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{code: 5, message: nil}
             })
    end

    test "returns true when only details.message carries the canonical text" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "SQLite failure: unrelated",
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 message: "database or disk is full"
               }
             })
    end

    test "returns true for details with nil code but the canonical message" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: nil,
                 message: "database or disk is full"
               }
             })
    end

    test "returns true for nil details with the canonical top-level message" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "database or disk is full",
               type: :sqlite_failure
             })
    end

    test "message match is case-insensitive (uppercase)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 message: "DATABASE OR DISK IS FULL"
               }
             })
    end

    test "message match is case-insensitive (mixed case)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 message: "Database or Disk IS FULL"
               }
             })
    end

    test "message match works when canonical text is embedded in a larger message" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               type: :sqlite_failure,
               details: %XqliteEcto3.Error.SqliteFailure{
                 code: 5,
                 message: "error: database or disk is full (code 13)"
               }
             })
    end

    test "message fallback is type-agnostic (current behavior)" do
      assert Errors.disk_full_exception?(%XqliteEcto3.Error{
               message: "database or disk is full",
               type: :connection_closed
             })
    end

    # -- {:error, exception} wrapping --

    test "returns true for {:error, exception} wrapping a disk-full sqlite_failure" do
      assert Errors.disk_full_exception?(
               {:error,
                %XqliteEcto3.Error{
                  type: :sqlite_failure,
                  details: %XqliteEcto3.Error.SqliteFailure{code: 13}
                }}
             )
    end

    test "returns true for {:error, exception} wrapping read_only_database" do
      assert Errors.disk_full_exception?(
               {:error,
                %XqliteEcto3.Error{type: :read_only_database, details: %{extended_code: 8}}}
             )
    end

    test "returns false for {:error, other_exception}" do
      refute Errors.disk_full_exception?({:error, %RuntimeError{message: "boom"}})
    end

    test "returns false for legacy NIF error tuples (disk_full_error?/1 territory)" do
      refute Errors.disk_full_exception?(
               {:error, {:sqlite_failure, 13, 13, "database or disk is full"}}
             )

      refute Errors.disk_full_exception?({:error, {:read_only_database, 8, "readonly"}})
    end

    # -- non-exception inputs / graceful negatives --

    test "returns false for nil" do
      refute Errors.disk_full_exception?(nil)
    end

    test "returns false for a plain map" do
      refute Errors.disk_full_exception?(%{})
      refute Errors.disk_full_exception?(%{type: :sqlite_failure, details: %{code: 13}})
    end

    test "returns false for a string" do
      refute Errors.disk_full_exception?("database or disk is full")
    end

    test "returns false for other exception types, even with the canonical message" do
      refute Errors.disk_full_exception?(%RuntimeError{message: "database or disk is full"})
      refute Errors.disk_full_exception?(%ArgumentError{message: "database or disk is full"})
    end

    test "returns false for an unknown type with nil details" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{type: :some_other, details: nil})
    end

    test "returns false for a default-constructed exception (all fields nil)" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{})
    end

    test "handles sqlite_failure with nil details gracefully (false, never raises)" do
      refute Errors.disk_full_exception?(%XqliteEcto3.Error{type: :sqlite_failure, details: nil})
    end

    # -- real adapter-wrapped shapes (XqliteEcto3.Error.wrap/1) --

    test "classifies a real wrapped SQLITE_FULL failure as disk-full" do
      assert Errors.disk_full_exception?(
               XqliteEcto3.Error.wrap({:sqlite_failure, 13, 13, "database or disk is full"})
             )
    end

    test "classifies a real wrapped read_only_database failure as disk-full" do
      assert Errors.disk_full_exception?(
               XqliteEcto3.Error.wrap(
                 {:read_only_database, 8, "attempt to write a readonly database"}
               )
             )
    end

    test "a real wrapped non-disk-full failure is not disk-full" do
      refute Errors.disk_full_exception?(
               XqliteEcto3.Error.wrap({:sqlite_failure, 19, 19, "constraint failed"})
             )
    end
  end
end
