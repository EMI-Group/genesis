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
end
