defmodule EvoGit.Agent.ToolNamesTest do
  @moduledoc """
  `async: true` — `EvoGit.Agent.ToolNames` and `EvoGit.Agent.Tools.Failure` are
  pure (no global state). The guard-ordering regression uses only the
  PROCESS-local `:repo_less` process-dictionary flag (cleaned up afterwards), so
  it does not leak into concurrently running modules.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.ToolNames
  alias EvoGit.Agent.Tools
  alias EvoGit.Agent.Tools.Failure

  # The platform shell tool name (POSIX `run_bash` / Windows `run_powershell`).
  @shell_tool_name if(EvoGit.Platform.os() == :windows, do: "run_powershell", else: "run_bash")

  # Resolves the `:platform_shell` sentinel of the raw alias table the same way
  # `normalize/1` does.
  defp expected_key(:platform_shell), do: @shell_tool_name
  defp expected_key(internal_key), do: internal_key

  describe "table/0 — the alias spine data" do
    test "is a non-empty map of down-cased spellings to internal keys" do
      table = ToolNames.table()
      assert is_map(table)
      assert map_size(table) > 0

      for {spelling, key} <- table do
        assert spelling == String.downcase(spelling),
               "alias table key #{inspect(spelling)} must be down-cased"

        assert is_binary(key) or key == :platform_shell,
               "alias table value #{inspect(key)} for #{inspect(spelling)} is invalid"
      end
    end

    test "shell_tool_name/0 matches the platform's shell tool" do
      assert ToolNames.shell_tool_name() == @shell_tool_name
    end
  end

  describe "normalize/1 — every alias entry resolves" do
    test "each table entry resolves to its internal dispatch key (exact + upper-case)" do
      for {spelling, key} <- ToolNames.table() do
        expected = expected_key(key)

        assert ToolNames.normalize(spelling) == expected,
               "normalize(#{inspect(spelling)}) should be #{inspect(expected)}"

        # Matching is case-INSENSITIVE — every alias also resolves in upper case.
        assert ToolNames.normalize(String.upcase(spelling)) == expected,
               "normalize(#{inspect(String.upcase(spelling))}) should be #{inspect(expected)}"
      end
    end

    test "the legacy/internal spellings still resolve to themselves" do
      assert ToolNames.normalize("read_file") == "read_file"
      assert ToolNames.normalize("write_file") == "write_file"
      assert ToolNames.normalize("edit_file") == "edit_file"
      assert ToolNames.normalize("rg") == "rg"
      assert ToolNames.normalize("glob") == "glob"
      assert ToolNames.normalize("search_web") == "search_web"
    end

    test "the trained model-facing spellings resolve to the internal keys" do
      assert ToolNames.normalize("read") == "read_file"
      assert ToolNames.normalize("write") == "write_file"
      assert ToolNames.normalize("edit") == "edit_file"
      assert ToolNames.normalize("bash") == @shell_tool_name
      assert ToolNames.normalize("grep") == "rg"
      assert ToolNames.normalize("ripgrep") == "rg"
      assert ToolNames.normalize("web_search") == "search_web"
      assert ToolNames.normalize("websearch") == "search_web"
      assert ToolNames.normalize("task") == "subagent_manager"
      assert ToolNames.normalize("subagent") == "subagent_manager"
    end

    test "every one of the 9 historical shell spellings normalizes to the platform shell tool" do
      for spelling <- ~w(
            bash shell sh execute_bash bash_command run_shell shell_command
            run_bash run_powershell
          ) do
        assert ToolNames.normalize(spelling) == @shell_tool_name
      end
    end

    test "case variants of the shell spellings normalize too" do
      assert ToolNames.normalize("Bash") == @shell_tool_name
      assert ToolNames.normalize("BASH") == @shell_tool_name
      assert ToolNames.normalize("RUN_BASH") == @shell_tool_name
      assert ToolNames.normalize("Run_Powershell") == @shell_tool_name
      assert ToolNames.normalize("Shell") == @shell_tool_name
    end

    test "the Claude-Code capitalised spellings normalize" do
      assert ToolNames.normalize("Read") == "read_file"
      assert ToolNames.normalize("Write") == "write_file"
      assert ToolNames.normalize("Edit") == "edit_file"
      assert ToolNames.normalize("Bash") == @shell_tool_name
      assert ToolNames.normalize("Grep") == "rg"
      assert ToolNames.normalize("Glob") == "glob"
      assert ToolNames.normalize("WebSearch") == "search_web"
      assert ToolNames.normalize("Task") == "subagent_manager"
    end

    test "unknown/custom tool names pass through with their ORIGINAL spelling" do
      assert ToolNames.normalize("my_custom_tool") == "my_custom_tool"
      assert ToolNames.normalize("MyCustomTool") == "MyCustomTool"
      assert ToolNames.normalize("skill_add") == "skill_add"
      assert ToolNames.normalize("run_command") == "run_command"
      assert ToolNames.normalize("") == ""
    end

    test "non-binary input passes through untouched" do
      assert ToolNames.normalize(nil) == nil
      assert ToolNames.normalize(42) == 42
      assert ToolNames.normalize(:read) == :read
    end
  end

  describe "model_name/1 — internal key to model-facing schema name" do
    test "documented internal key -> model-facing schema name" do
      assert ToolNames.model_name("read_file") == "read"
      assert ToolNames.model_name("write_file") == "write"
      assert ToolNames.model_name("edit_file") == "edit"
      assert ToolNames.model_name("run_bash") == "bash"
      assert ToolNames.model_name("run_powershell") == "bash"
      assert ToolNames.model_name("search_web") == "web_search"
      # `rg` deliberately STAYS the canonical model-facing name for grep.
      assert ToolNames.model_name("rg") == "rg"
      assert ToolNames.model_name("glob") == "glob"
    end

    test "also accepts an alias spelling of the internal key" do
      assert ToolNames.model_name("read") == "read"
      assert ToolNames.model_name("Read") == "read"
      assert ToolNames.model_name("bash") == "bash"
      assert ToolNames.model_name("Grep") == "rg"
      assert ToolNames.model_name("WebSearch") == "web_search"
    end

    test "unknown/custom names are returned UNCHANGED" do
      assert ToolNames.model_name("my_custom_tool") == "my_custom_tool"
      assert ToolNames.model_name("MyCustomTool") == "MyCustomTool"
      assert ToolNames.model_name("create_files") == "create_files"
    end

    test "non-binary input passes through untouched" do
      assert ToolNames.model_name(nil) == nil
      assert ToolNames.model_name(42) == 42
    end
  end

  describe "matches_any?/2 — alias-aware whitelist matching" do
    test "an old spelling matches a new-spelling whitelist entry" do
      assert ToolNames.matches_any?("read_file", ["read"])
      assert ToolNames.matches_any?("write_file", ["read", "write"])
      assert ToolNames.matches_any?("edit_file", ["edit"])
      assert ToolNames.matches_any?("search_web", ["web_search"])
    end

    test "a new spelling matches an old-spelling whitelist entry" do
      assert ToolNames.matches_any?("read", ["read_file"])
      assert ToolNames.matches_any?("write", ["write_file"])
      assert ToolNames.matches_any?("edit", ["edit_file"])
      assert ToolNames.matches_any?("web_search", ["search_web"])
      assert ToolNames.matches_any?("bash", [@shell_tool_name])
    end

    test "matching is case-insensitive on both sides" do
      assert ToolNames.matches_any?("Read", ["read_file"])
      assert ToolNames.matches_any?("read_file", ["Read"])
      assert ToolNames.matches_any?("Bash", ["run_bash"])
      assert ToolNames.matches_any?("run_bash", ["BASH"])
    end

    test "a non-matching whitelist is false, and an empty whitelist never matches" do
      refute ToolNames.matches_any?("read", ["write", "edit"])
      refute ToolNames.matches_any?("read", [])
      refute ToolNames.matches_any?("my_custom_tool", ["read", "write"])
    end

    test "a custom tool name matches only its own spelling" do
      assert ToolNames.matches_any?("my_custom_tool", ["my_custom_tool"])
      assert ToolNames.matches_any?("my_custom_tool", ["read", "my_custom_tool"])
    end

    test "non-list whitelist / non-binary name are total (no raise)" do
      refute ToolNames.matches_any?("read", nil)
      refute ToolNames.matches_any?(nil, ["read"])
    end
  end

  describe "Failure.error/1" do
    test "prefixes a plain message with the literal 'Error: '" do
      assert Failure.error("file not found") == "Error: file not found"
    end

    test "starts with the literal 'Error: '" do
      assert String.starts_with?(Failure.error("boom"), "Error: ")
    end

    test "is idempotent" do
      once = Failure.error("boom")
      assert Failure.error(once) == once
      assert Failure.error(Failure.error(Failure.error("boom"))) == once
    end

    test "canonicalises the unspaced 'Error:' prefix" do
      assert Failure.error("Error:boom") == "Error: boom"
      # A message that ALREADY starts with the literal "Error: " is returned
      # unchanged (idempotency beats whitespace tidying).
      assert Failure.error("Error:  boom") == "Error:  boom"
    end

    test "strips a leading emoji/marker and still prefixes" do
      assert Failure.error("⚠️ failed to read file") == "Error: failed to read file"
      assert Failure.error("💡 try again") == "Error: try again"
      assert Failure.error("[NOTICE] failed") == "Error: failed"
      assert Failure.error("[WARNING] failed") == "Error: failed"
      assert Failure.error("[NOTICE]failed") == "Error: failed"
    end

    test "strips several stacked markers in any order" do
      assert Failure.error("⚠️ [NOTICE] failed") == "Error: failed"
      assert Failure.error("[WARNING]💡 failed") == "Error: failed"
      assert Failure.error("  \n ⚠️ failed") == "Error: failed"
    end

    test "the 'Error: ' prefix wins — nothing after it is touched" do
      assert Failure.error("Error: ⚠️ failed") == "Error: ⚠️ failed"
    end

    test "an empty message still leads with the prefix" do
      assert Failure.error("") == "Error: the tool call failed."
      assert Failure.error("   ") == "Error: the tool call failed."
    end

    test "non-binary input is routed through to_string/1" do
      assert Failure.error(:boom) == "Error: boom"
      assert Failure.error(nil) == "Error: the tool call failed."
    end

    test "never emits a marker on a plain message" do
      out = Failure.error("disk full")
      refute out =~ "⚠️"
      refute out =~ "💡"
      refute out =~ "[NOTICE]"
      refute out =~ "[WARNING]"
    end
  end

  describe "Failure.error/2" do
    test "error line + blank line + trailing guidance block" do
      out = Failure.error("file not found", "Use list_dir to find the file first.")
      assert out == "Error: file not found\n\nUse list_dir to find the file first."
      assert String.starts_with?(out, "Error: ")
      assert [_error_line, guidance] = String.split(out, "\n\n")
      assert guidance == "Use list_dir to find the file first."
    end

    test "the guidance block is marker-stripped" do
      out = Failure.error("boom", "💡 Re-read the file, then retry.")
      assert out == "Error: boom\n\nRe-read the file, then retry."
      refute out =~ "💡"
    end

    test "blank guidance renders just the error line" do
      assert Failure.error("boom", "") == "Error: boom"
      assert Failure.error("boom", "   ") == "Error: boom"
      assert Failure.error("boom", nil) == "Error: boom"
    end

    test "no marker leaks into the guidance block" do
      out = Failure.error("boom", "[WARNING] something")
      refute out =~ "[WARNING]"
      refute out =~ "⚠️"
      refute out =~ "💡"
      refute out =~ "[NOTICE]"
    end
  end

  describe "Failure.notice/1" do
    test "prefixes a blank line before the guidance block" do
      assert Failure.notice("Commit before delegating.") == "\n\nCommit before delegating."
    end

    test "strips a leading marker" do
      assert Failure.notice("⚠️ Commit first.") == "\n\nCommit first."
      assert Failure.notice("💡 Commit first.") == "\n\nCommit first."
      assert Failure.notice("[NOTICE] Commit first.") == "\n\nCommit first."
      assert Failure.notice("[WARNING] Commit first.") == "\n\nCommit first."
    end

    test "empty guidance yields an empty string (safe to concatenate)" do
      assert Failure.notice("") == ""
      assert Failure.notice("   ") == ""
      assert Failure.notice(nil) == ""
    end

    test "is not an error shape" do
      refute String.starts_with?(Failure.notice("Commit first."), "Error: ")
    end
  end

  describe "Tools.execute/5 — guard ordering (normalise BEFORE the write gates)" do
    test "run_bash is still blocked for a repo-less agent" do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      result = Tools.execute("run_bash", %{"command" => "echo hi"}, ".", nil, nil)

      assert is_binary(result)
      assert String.starts_with?(result, "Error: ")
      assert result =~ "read-only access to the system"
    end

    test "the 'bash' alias is blocked for a repo-less agent (never executed)" do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      result = Tools.execute("bash", %{"command" => "echo hi"}, ".", nil, nil)

      assert is_binary(result)
      assert String.starts_with?(result, "Error: ")
      assert result =~ "read-only access to the system"
    end

    test "'write' and 'Bash' are blocked for a repo-less agent too" do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      for name <- ["write", "Write", "Bash", "SHELL"] do
        result = Tools.execute(name, %{"command" => "echo hi"}, ".", nil, nil)

        assert is_binary(result)

        assert String.starts_with?(result, "Error: "),
               "#{inspect(name)} should be blocked with an Error: string"

        assert result =~ "read-only access to the system"
      end
    end
  end

  describe "Tools.whitelist_match?/2" do
    test "matches an old name against a new spelling and vice versa" do
      assert Tools.whitelist_match?("read_file", ["read"])
      assert Tools.whitelist_match?("read", ["read_file"])
      assert Tools.whitelist_match?("bash", [@shell_tool_name])
      assert Tools.whitelist_match?("web_search", ["search_web"])
    end

    test "case-insensitive" do
      assert Tools.whitelist_match?("Read", ["read_file"])
      assert Tools.whitelist_match?("RUN_BASH", ["bash"])
    end

    test "custom tool names keep resolving literally" do
      assert Tools.whitelist_match?("my_custom_tool", ["my_custom_tool"])
      refute Tools.whitelist_match?("my_custom_tool", ["read"])
      refute Tools.whitelist_match?("read", nil)
    end
  end

  describe "Tools.default_timeout_ms/1" do
    test "returns 120_000 for the shell tool in every accepted spelling" do
      assert Tools.default_timeout_ms("bash") == 120_000
      assert Tools.default_timeout_ms("Bash") == 120_000
      assert Tools.default_timeout_ms("shell") == 120_000
      assert Tools.default_timeout_ms("run_bash") == 120_000
      assert Tools.default_timeout_ms("run_powershell") == 120_000
      assert Tools.default_timeout_ms(@shell_tool_name) == 120_000
    end

    test "returns nil for every other tool" do
      assert Tools.default_timeout_ms("read") == nil
      assert Tools.default_timeout_ms("read_file") == nil
      assert Tools.default_timeout_ms("write") == nil
      assert Tools.default_timeout_ms("rg") == nil
      assert Tools.default_timeout_ms("my_custom_tool") == nil
      assert Tools.default_timeout_ms(nil) == nil
    end
  end

  describe "Tools.serial_tool?/1 — normalises the raw model-facing name" do
    test "the serial (read-modify-write) aliases are serial" do
      assert Tools.serial_tool?("write")
      assert Tools.serial_tool?("Write")
      assert Tools.serial_tool?("edit")
      assert Tools.serial_tool?("write_file")
      assert Tools.serial_tool?("edit_file")
      assert Tools.serial_tool?("create_files")
      assert Tools.serial_tool?("make_dir")
    end

    test "the shell aliases are NOT serial" do
      refute Tools.serial_tool?("bash")
      refute Tools.serial_tool?("Bash")
      refute Tools.serial_tool?("shell")
      refute Tools.serial_tool?("run_bash")
      refute Tools.serial_tool?("run_powershell")
      refute Tools.serial_tool?("run_git")
      refute Tools.serial_tool?("curl")
    end

    test "read-only aliases and unknown names are NOT serial" do
      refute Tools.serial_tool?("read")
      refute Tools.serial_tool?("Read")
      refute Tools.serial_tool?("grep")
      refute Tools.serial_tool?("rg")
      refute Tools.serial_tool?("web_search")
      refute Tools.serial_tool?("my_custom_tool")
      refute Tools.serial_tool?(nil)
    end
  end

  describe "background job aliases" do
    # The model-facing schema name and the internal dispatch key are the SAME
    # for the background-job control tools, so only the extra accepted spellings
    # live in the alias table — the canonical names pass through unchanged.
    test "normalize/1 maps the accepted output spellings onto `job_output`" do
      for spelling <- ~w(bash_output background_output job_status) do
        assert ToolNames.normalize(spelling) == "job_output"
      end
    end

    test "normalize/1 maps the accepted listing spellings onto `job_list`" do
      for spelling <- ~w(jobs background_jobs) do
        assert ToolNames.normalize(spelling) == "job_list"
      end
    end

    test "normalize/1 maps the accepted kill spellings onto `job_kill`" do
      for spelling <- ~w(kill_job job_stop stop_job) do
        assert ToolNames.normalize(spelling) == "job_kill"
      end
    end

    test "the canonical spellings normalize to themselves" do
      for spelling <- ~w(job_output job_list job_kill) do
        assert ToolNames.normalize(spelling) == spelling
      end
    end

    test "matches_any?/2 resolves a canonical name against an alias whitelist" do
      assert ToolNames.matches_any?("job_output", ["bash_output"])
      assert ToolNames.matches_any?("job_kill", ["kill_job", "job_stop"])
      assert ToolNames.matches_any?("job_list", ["jobs"])
      refute ToolNames.matches_any?("job_output", ["job_kill"])
    end
  end
end
