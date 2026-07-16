defmodule EvoGit.Agent.Tools.SharedTest do
  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.Shared

  describe "normalize_relpath/1" do
    test "normalizes bare path to ./ prefix" do
      assert Shared.normalize_relpath("foo/bar") == "./foo/bar"
    end

    test "keeps ./-prefixed path as-is" do
      assert Shared.normalize_relpath("./foo/bar") == "./foo/bar"
    end

    test "normalizes empty string to ./" do
      assert Shared.normalize_relpath("") == "./"
    end

    test "normalizes dot to ./" do
      assert Shared.normalize_relpath(".") == "./"
    end

    test "returns error tuple on absolute paths (does not raise)" do
      assert {:error, message} = Shared.normalize_relpath("/etc/passwd")
      assert message =~ "absolute"
      assert message =~ "relative to the repository root"
    end

    test "returns error tuple on Windows absolute paths" do
      assert {:error, message} = Shared.normalize_relpath("C:\\Users\\file.txt")
      assert message =~ "absolute"
      assert message =~ "relative to the repository root"
    end

    test "strips trailing slashes" do
      assert Shared.normalize_relpath("foo/") == "./foo"
    end

    test "trims backslash separators in relative paths" do
      assert Shared.normalize_relpath("foo\\bar") == "./foo/bar"
    end

    test "trims leading and trailing backslashes" do
      assert Shared.normalize_relpath("\\foo\\bar\\") == "./foo/bar"
    end

    test "handles single segment" do
      assert Shared.normalize_relpath("lib") == "./lib"
    end

    test "handles root path ./" do
      assert Shared.normalize_relpath("./") == "./"
    end
  end

  describe "is_child_or_same_node?/2" do
    test "root encompasses everything" do
      assert Shared.is_child_or_same_node?("./", "./foo/bar") == true
    end

    test "same path matches" do
      assert Shared.is_child_or_same_node?("./foo", "./foo") == true
    end

    test "child matches parent" do
      assert Shared.is_child_or_same_node?("./foo", "./foo/bar") == true
    end

    test "sibling does not match" do
      assert Shared.is_child_or_same_node?("./foo", "./bar") == false
    end

    test "parent does not match child" do
      assert Shared.is_child_or_same_node?("./foo/bar", "./foo") == false
    end

    test "root matches root" do
      assert Shared.is_child_or_same_node?("./", "./") == true
    end
  end

  describe "validate_file_scope/3" do
    test "allows file within node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "allows file at node root" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "rejects file outside node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/test/app_test.exs"
      result = Shared.validate_file_scope(expanded, "./lib", repo_path)
      assert {:error, _msg} = result
    end

    test "returns error (not a crash) for absolute path outside the repo" do
      repo_path = "/home/user/repo"
      expanded = "/tmp/test_simple.c"
      result = Shared.validate_file_scope(expanded, "./lib", repo_path)
      assert {:error, message} = result
      assert message =~ "outside the repository root"
      assert message =~ "relative to the repository root"
      assert message =~ "/tmp/test_simple.c"
    end

    test "returns error for absolute path even when node is root" do
      repo_path = "/home/user/repo"
      expanded = "/etc/passwd"
      result = Shared.validate_file_scope(expanded, "./", repo_path)
      assert {:error, message} = result
      assert message =~ "outside the repository root"
    end

    test "allows any file when node_path is nil" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/any/path.ex"
      assert Shared.validate_file_scope(expanded, nil, repo_path) == :ok
    end
  end

  describe "fetch_array_arg/2" do
    test "returns a real list unchanged" do
      assert Shared.fetch_array_arg(%{"args" => ["-n", "foo", "."]}, "args") ==
               {:ok, ["-n", "foo", "."]}
    end

    test "recovers a JSON-encoded string array transparently" do
      encoded = Jason.encode!(["-n", "foo", "."])
      assert Shared.fetch_array_arg(%{"args" => encoded}, "args") == {:ok, ["-n", "foo", "."]}
    end

    test "recovers a JSON-encoded array containing integers (coerced to strings)" do
      encoded = Jason.encode!(["-n", 123, "."])
      assert Shared.fetch_array_arg(%{"args" => encoded}, "args") == {:ok, ["-n", "123", "."]}
    end

    test "returns error for a non-JSON string" do
      result = Shared.fetch_array_arg(%{"args" => "not-json"}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "returns error for a JSON string that decodes to a map, not a list" do
      encoded = Jason.encode!(%{"key" => 1})
      result = Shared.fetch_array_arg(%{"args" => encoded}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "error message explains the double-encoding problem and is actionable" do
      encoded = Jason.encode!(["-n", "foo", "."])
      result = Shared.fetch_array_arg(%{"args" => encoded <> "}"}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
      assert message =~ "JSON-encoded string"
      assert message =~ "Pass a real JSON array"
    end

    test "returns error for a non-binary, non-list value" do
      result = Shared.fetch_array_arg(%{"args" => 42}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "returns error for a missing key" do
      result = Shared.fetch_array_arg(%{}, "args")
      assert {:error, message} = result
      assert message =~ "Missing required argument"
    end
  end

  describe "fetch_optional_boolean_arg/3" do
    test "returns the value when it is a boolean" do
      assert Shared.fetch_optional_boolean_arg(%{"commit" => false}, "commit", true) == {:ok, false}
      assert Shared.fetch_optional_boolean_arg(%{"commit" => true}, "commit", false) == {:ok, true}
    end

    test "returns the default when the key is absent" do
      assert Shared.fetch_optional_boolean_arg(%{}, "commit", true) == {:ok, true}
      assert Shared.fetch_optional_boolean_arg(%{}, "parents", true) == {:ok, true}
    end

    test "returns an error when the value is not a boolean" do
      assert {:error, message} = Shared.fetch_optional_boolean_arg(%{"commit" => "yes"}, "commit", true)
      assert message =~ "commit must be a boolean"
    end
  end

  describe "get_optional_string/3" do
    test "returns the value directly when it is a binary" do
      assert Shared.get_optional_string(%{"path" => "lib"}, "path", "./") == "lib"
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_string(%{}, "path", "./") == "./"
    end

    test "coerces non-binary values to string via to_string/1" do
      assert Shared.get_optional_string(%{"path" => 42}, "path", "./") == "42"
    end
  end

  describe "get_optional_integer/3" do
    test "returns the value directly when it is an integer" do
      assert Shared.get_optional_integer(%{"context" => 5}, "context", 3) == 5
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_integer(%{}, "context", 3) == 3
    end

    test "parses a valid integer binary" do
      assert Shared.get_optional_integer(%{"context" => "5"}, "context", 3) == 5
    end

    test "falls back to default on an unparseable binary (does not crash)" do
      assert Shared.get_optional_integer(%{"context" => "abc"}, "context", 3) == 3
    end

    test "falls back to default on a non-integer, non-binary value" do
      assert Shared.get_optional_integer(%{"context" => true}, "context", 3) == 3
    end
  end

  describe "get_optional_boolean/3" do
    test "returns the value directly when it is a boolean" do
      assert Shared.get_optional_boolean(%{"search_notes" => true}, "search_notes", true) == true
      assert Shared.get_optional_boolean(%{"search_notes" => false}, "search_notes", true) == false
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_boolean(%{}, "search_notes", true) == true
    end

    test "interprets truthy string variants as true" do
      for val <- ["true", "True", "TRUE", "1"] do
        assert Shared.get_optional_boolean(%{"search_notes" => val}, "search_notes", false) == true
      end
    end

    test "treats other strings as false (falls back to default)" do
      assert Shared.get_optional_boolean(%{"search_notes" => "yes"}, "search_notes", false) == false
    end
  end
end
