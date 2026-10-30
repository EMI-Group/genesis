defmodule EvoGit.Agent.ToolsTest do
  @moduledoc """
  `async: false` — the web-search tests mutate the BEAM-global `:req_llm`
  application env (`:tavily_api_key`), which concurrently running modules
  observe. The config directory itself is isolated PER PROCESS
  (`EvoGit.TestSupport.ConfigDir`, via the private `with_isolated_config/1`
  helper), so no process-wide env var is touched.
  """

  use ExUnit.Case, async: false
  alias EvoGit.Agent.Tools
  alias EvoGit.TestSupport.ConfigDir

  @moduletag :tmp_dir

  # The platform-specific shell tool name (POSIX `run_bash` / Windows
  # `run_powershell`), mirroring the private `@shell_tool_name` in
  # `EvoGit.Agent.Tools`. Shell-tool aliases normalize to this name.
  @shell_tool_name if(EvoGit.Platform.os() == :windows, do: "run_powershell", else: "run_bash")

  describe "schemas/0" do
    test "returns a list of tool schemas" do
      schemas = Tools.schemas()
      assert is_list(schemas)
      assert length(schemas) > 0

      names = Enum.map(schemas, & &1.name)

      # `read` / `write` / `edit` / `bash` are the MODEL-FACING schema names; the
      # internal dispatch keys stay `read_file` / `write_file` / `edit_file` /
      # `run_bash` (see `EvoGit.Agent.ToolNames`).
      assert "read" in names
      assert "write" in names
      assert "edit" in names
      assert "bash" in names
      assert "make_dir" in names
      assert "read_context" in names
      assert "write_context" in names
      assert "edit_context" in names
    end

    test "tool names are unique (regression: 'Tool names must be unique' provider 400)" do
      names = Enum.map(Tools.schemas(), & &1.name)
      assert length(names) == length(Enum.uniq(names))
    end

    test "does NOT include the self-reflective/task-control tools (regression)" do
      names = Enum.map(Tools.schemas(), & &1.name)

      # These 8 tools belong to the repo-less SelfReflective agent's explicit
      # available_tools/0 list only — never in the standard schemas/0 set. In
      # particular, SpawnInvestigator's schema name "subagent_investigator"
      # collides with the SubagentSchemas-generated tool of the same name that
      # every agent with an Investigator subagent receives, which broke ALL
      # normal coding agents with a provider 400 "Tool names must be unique".
      for tool <- [
            "list_tasks",
            "get_task",
            "start_task",
            "cancel_task",
            "force_kill_task",
            "delete_task",
            "guide_user",
            "subagent_investigator"
          ] do
        refute tool in names, "expected #{inspect(tool)} to NOT be in Tools.schemas()"
      end
    end
  end

  describe "agent available_tools/0 uniqueness (regression: 'Tool names must be unique')" do
    test "Manager.available_tools() has unique names and one subagent_investigator" do
      # Manager's subagent_modules/0 includes EvoGit.Agents.Investigator, so its
      # default available_tools/0 (Tools.schemas() ++ SubagentSchemas.schemas/1
      # ++ [CompleteTask.schema()]) receives the real "subagent_investigator"
      # subagent tool. This is the exact collision class that broke production
      # when the placeholder SpawnInvestigator schema was inside Tools.schemas/0.
      names =
        EvoGit.Agents.Manager.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert length(names) == length(Enum.uniq(names))
      assert Enum.count(names, &(&1 == "subagent_investigator")) == 1
    end
  end

  describe "run_command shell tool containment" do
    test "run_command is in NEITHER schemas/0 nor read_only_schemas/0" do
      refute "run_command" in Enum.map(Tools.schemas(), & &1.name)
      refute "run_command" in Enum.map(Tools.read_only_schemas(), & &1.name)
    end

    test "SelfReflective.available_tools() exposes run_command and none of the 10 old task-control tools" do
      names =
        EvoGit.Agents.SelfReflective.available_tools()
        |> Enum.map(&EvoGit.Agent.tool_name/1)

      assert "run_command" in names
      assert "complete_task" in names

      # The 10 former per-function task-control tools are gone — their commands
      # are reachable only through the single run_command shell tool.
      for old <- [
            "list_tasks",
            "get_task",
            "start_task",
            "cancel_task",
            "force_kill_task",
            "delete_task",
            "guide_user",
            "subagent_investigator",
            "list_recent_projects",
            "system_info"
          ] do
        refute old in names,
               "expected #{inspect(old)} to NOT be in SelfReflective.available_tools()"
      end

      # Unique names — no "Tool names must be unique" provider-400 regressions.
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "serial_tool?/1 classification" do
    # The file-mutating read-modify-write subset the dispatcher serializes.
    @serial_tool_names ~w(
      create_files write_file edit_file make_dir write_context edit_context
      skill_add skill_edit skill_remove skill_enable skill_disable
    )

    @read_only_tool_names ~w(
      read_file read_context glob list_dir rg search_context search_history
      skill_list skill_read skill_where
    )

    # Write tools that are NOT read-modify-write file operations: opaque whole
    # commands / network calls that agents legitimately run concurrently.
    # `bash` is the MODEL-FACING shell name (`run_bash`/`run_powershell` are the
    # internal dispatch keys); `serial_tool?/1` normalises both spellings.
    @non_serial_write_tool_names ~w(
      run_bash run_powershell bash run_git run_command search_web web_search
    )

    test "returns true for every file-mutating read-modify-write tool" do
      with_isolated_config(fn ->
        for tool <- @serial_tool_names do
          assert Tools.serial_tool?(tool),
                 "expected #{inspect(tool)} to be classified as a serial tool"
        end
      end)
    end

    test "returns false for the read-only tools" do
      with_isolated_config(fn ->
        for tool <- @read_only_tool_names do
          refute Tools.serial_tool?(tool),
                 "expected read-only #{inspect(tool)} to NOT be classified as serial"
        end
      end)
    end

    test "returns false for the shell/exec/network tools" do
      with_isolated_config(fn ->
        for tool <- @non_serial_write_tool_names do
          refute Tools.serial_tool?(tool),
                 "expected #{inspect(tool)} to NOT be classified as serial"
        end
      end)
    end

    test "returns false for an unknown tool name and for non-binary input" do
      with_isolated_config(fn ->
        refute Tools.serial_tool?("teleport_code")
        refute Tools.serial_tool?(nil)
        refute Tools.serial_tool?(:write_file)
      end)
    end

    test "classifies a loaded custom tool from its read_only?/0 report" do
      with_isolated_config(fn ->
        writer = Module.concat([:"SerialToolWriterFixture#{System.unique_integer([:positive])}"])
        reader = Module.concat([:"SerialToolReaderFixture#{System.unique_integer([:positive])}"])
        write_isolated_custom_tool!(writer, "custom_serial_writer", false)
        write_isolated_custom_tool!(reader, "custom_serial_reader", true)

        # A custom tool that does NOT declare itself read-only is treated like a
        # built-in file-mutating writer (opaque user code that may mutate files).
        assert Tools.serial_tool?("custom_serial_writer")

        # An explicitly read-only custom tool is not serialized.
        refute Tools.serial_tool?("custom_serial_reader")
      end)
    end
  end

  describe "execute/4 - read_file" do
    # The read-output shape (File: header, numbered lines, `line_numbers: false`,
    # footers, clips, size caps, missing-file error) is owned by
    # `test/evo_git/agent/tools/file_read_test.exs`. This suite owns the DISPATCH
    # contract for both the internal key and the model-facing name.
    test "dispatches read_file / read to the file reader", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      assert Tools.execute("read_file", %{"file_path" => "test.txt"}, tmp_dir) =~ "hello world"

      assert Tools.execute("read", %{"file_path" => "test.txt"}, tmp_dir) =~ "hello world"

      assert Tools.execute("read_file", %{"file_path" => "missing.txt"}, tmp_dir) =~
               "Error: reading file"
    end
  end

  describe "execute/4 - write_file" do
    test "writes to a new file and creates directory", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "write_file",
          %{"file_path" => "new_dir/test.txt", "content" => "new content"},
          tmp_dir
        )

      assert result =~ "Successfully wrote to"

      assert File.read!(Path.join([tmp_dir, "new_dir", "test.txt"])) == "new content"
    end
  end

  describe "execute/4 - edit_file" do
    # The edit-string semantics (byte-exact replacement, unique-match enforcement,
    # replace_all, trailing whitespace fidelity, the `Error: ` prefixes) are owned
    # by `test/evo_git/agent/tools/file_edit_test.exs`, which pins them against the
    # module directly AND asserts the model-facing `edit` name reaches the same
    # dispatch key. This suite only owns the internal dispatch-key routing.
    test "the internal `edit_file` key still dispatches to the edit tool", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world 123")

      result =
        Tools.execute(
          "edit_file",
          %{"file_path" => "test.txt", "old_string" => "world", "new_string" => "elixir"},
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      assert File.read!(file_path) == "hello elixir 123"
    end
  end

  describe "execute/4 - make_dir" do
    # The mkdir semantics themselves (CONTEXT.md default, multiple/nested paths,
    # `keep_file` .gitkeep/none, the `parents: false` error, commit staging) are
    # pinned by `test/evo_git/agent/tools/make_dir_test.exs` against the module
    # directly. This suite only owns the DISPATCH contract.
    test "dispatches through the make_dir key and honors keep_file", %{tmp_dir: tmp_dir} do
      result = Tools.execute("make_dir", %{"paths" => ["lib"], "commit" => false}, tmp_dir)

      assert result =~ "Successfully created 1 directory"
      assert result =~ "lib"
      assert File.dir?(Path.join(tmp_dir, "lib"))
      assert File.exists?(Path.join(tmp_dir, "lib/CONTEXT.md"))

      result =
        Tools.execute(
          "make_dir",
          %{"paths" => ["other"], "keep_file" => ".gitkeep", "commit" => false},
          tmp_dir
        )

      assert result =~ "Successfully created 1 directory"
      refute File.exists?(Path.join(tmp_dir, "other/CONTEXT.md"))
      assert File.exists?(Path.join(tmp_dir, "other/.gitkeep"))
    end
  end

  describe "execute/4 - read_context" do
    test "reads existing CONTEXT.md", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "dir context")

      result = Tools.execute("read_context", %{"dir_path" => "lib"}, tmp_dir)
      assert result == "dir context"
    end

    test "reports each failure branch: no CONTEXT.md, missing dir, path is a file", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "test.txt"), "")

      # CONTEXT.md absent from an existing directory
      assert Tools.execute("read_context", %{"dir_path" => "lib"}, tmp_dir) =~
               "No CONTEXT.md found"

      # directory absent
      assert Tools.execute("read_context", %{"dir_path" => "missing"}, tmp_dir) =~
               "does not exist"

      # path is a regular file
      assert Tools.execute("read_context", %{"dir_path" => "test.txt"}, tmp_dir) =~
               "is a file, not a directory"
    end
  end

  describe "execute/4 - glob" do
    test "returns matching paths, or the exact no-match shape with the pattern hint", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/a.ex"), "")
      File.write!(Path.join(tmp_dir, "lib/b.ex"), "")

      result = Tools.execute("glob", %{"pattern" => "lib/*.ex"}, tmp_dir)

      assert result =~ "lib/a.ex"
      assert result =~ "lib/b.ex"

      # Fixed first line + the pattern echoed as a trailing hint.
      assert Tools.execute("glob", %{"pattern" => "missing/*.ex"}, tmp_dir) ==
               "No files found.\n\n[pattern: missing/*.ex]"
    end
  end

  describe "execute/4 - list_dir" do
    test "lists contents of a directory", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "a.ex"), "")
      File.mkdir_p!(Path.join(dir_path, "sub"))

      result = Tools.execute("list_dir", %{"dir_path" => "lib"}, tmp_dir)

      files = String.split(result, "\n")
      assert "a.ex" in files
      assert "sub" in files
    end

    test "returns error for missing directory", %{tmp_dir: tmp_dir} do
      result = Tools.execute("list_dir", %{"dir_path" => "missing"}, tmp_dir)
      assert result == "Error: listing directory 'missing' failed: no such file or directory"
    end
  end

  describe "execute/4 - write_context" do
    test "writes CONTEXT.md and commits in systemd-run sandbox", %{tmp_dir: tmp_dir} do
      # Initialize a git repository
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit so we have a HEAD
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)

      # Pass repo_root as tmp_dir as well so that systemd-run has access to .git
      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "lib", "content" => "new context", "commit" => true},
          tmp_dir,
          tmp_dir
        )

      assert result =~ "Successfully updated CONTEXT.md for directory 'lib'"
      assert result =~ "Committed:"

      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"

      # Check git log
      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Update CONTEXT.md for lib"
    end

    test "writes CONTEXT.md without committing", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "lib", "content" => "new context", "commit" => false},
          tmp_dir
        )

      assert result == "Successfully updated CONTEXT.md for directory 'lib'"

      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"
    end

    test "auto-creates a missing directory", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "missing", "content" => "context", "commit" => false},
          tmp_dir
        )

      assert result =~ "Successfully updated CONTEXT.md"

      assert File.read!(Path.join(tmp_dir, "missing/CONTEXT.md")) == "context"
    end

    test "returns error if path is a file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "")

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "test.txt", "content" => "context"},
          tmp_dir
        )

      assert result == "Error: creating directory 'test.txt' failed: not a directory"
    end

    test "write_context with hostile dir_path (quotes/angle brackets) commits and round-trips", %{
      tmp_dir: tmp_dir
    } do
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      hostile_dir = ~s(lib"with">angle)
      File.mkdir_p!(Path.join(tmp_dir, hostile_dir))

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => hostile_dir, "content" => "hostile context", "commit" => true},
          tmp_dir,
          tmp_dir
        )

      assert result =~ "Successfully updated CONTEXT.md for directory '#{hostile_dir}'"
      assert result =~ "Committed:"
      assert File.read!(Path.join([tmp_dir, hostile_dir, "CONTEXT.md"])) == "hostile context"

      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Update CONTEXT.md for #{hostile_dir}"
    end
  end

  describe "execute/4 - edit_context" do
    test "edits existing CONTEXT.md with exact string replacement", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "# My Context\n\nSome content here")

      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => "lib",
            "old_string" => "Some content here",
            "new_string" => "Updated content",
            "commit" => false
          },
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "# My Context\n\nUpdated content"
    end

    test "replaces all occurrences when replace_all is true", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "hello world hello world")

      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => "lib",
            "old_string" => "hello",
            "new_string" => "hi",
            "replace_all" => true,
            "commit" => false
          },
          tmp_dir
        )

      assert result =~ "All occurrences were successfully replaced"
      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "hi world hi world"
    end

    test "returns error if multiple matches found without replace_all", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "hello world hello world")

      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => "lib",
            "old_string" => "hello",
            "new_string" => "hi",
            "commit" => false
          },
          tmp_dir
        )

      assert result =~ "Found 2 matches"
      assert result =~ "Set replace_all=true"
      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "hello world hello world"
    end

    test "returns error if old_string not found", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "hello world")

      result =
        Tools.execute(
          "edit_context",
          %{"dir_path" => "lib", "old_string" => "missing", "new_string" => "replacement"},
          tmp_dir
        )

      assert result =~ "old_string not found in file"
    end

    test "reports each failure branch: no CONTEXT.md, missing dir, path is a file", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "test.txt"), "")

      # CONTEXT.md absent from an existing directory
      assert Tools.execute(
               "edit_context",
               %{"dir_path" => "lib", "old_string" => "hello", "new_string" => "world"},
               tmp_dir
             ) =~ "No CONTEXT.md found"

      # directory absent
      assert Tools.execute(
               "edit_context",
               %{"dir_path" => "missing", "old_string" => "hello", "new_string" => "world"},
               tmp_dir
             ) =~ "does not exist"

      # path is a regular file
      assert Tools.execute(
               "edit_context",
               %{"dir_path" => "test.txt", "old_string" => "hello", "new_string" => "world"},
               tmp_dir
             ) =~ "is a file, not a directory"
    end

    test "edits and commits CONTEXT.md", %{tmp_dir: tmp_dir} do
      # Initialize a git repository
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit so we have a HEAD
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "old context")

      # Pass repo_root as tmp_dir as well so that systemd-run has access to .git
      result =
        Tools.execute(
          "edit_context",
          %{"dir_path" => "lib", "old_string" => "old", "new_string" => "new", "commit" => true},
          tmp_dir,
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      assert result =~ "Committed:"
      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"

      # Check git log
      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Update CONTEXT.md for lib"
    end

    test "edits without committing when commit is false", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "CONTEXT.md"), "old context")

      result =
        Tools.execute(
          "edit_context",
          %{"dir_path" => "lib", "old_string" => "old", "new_string" => "new", "commit" => false},
          tmp_dir
        )

      assert result =~ "has been updated successfully"
      refute result =~ "Committed:"
      assert File.read!(Path.join(dir_path, "CONTEXT.md")) == "new context"
    end

    test "edit_context with hostile dir_path (quotes/angle brackets) commits and round-trips", %{
      tmp_dir: tmp_dir
    } do
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "init")
      System.cmd("git", ["add", "README.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init commit"], cd: tmp_dir)

      hostile_dir = ~s(lib"with">angle)
      File.mkdir_p!(Path.join(tmp_dir, hostile_dir))
      File.write!(Path.join([tmp_dir, hostile_dir, "CONTEXT.md"]), "old content")

      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => hostile_dir,
            "old_string" => "old content",
            "new_string" => "new content",
            "commit" => true
          },
          tmp_dir,
          tmp_dir
        )

      assert result =~ "The file #{Path.join(hostile_dir, "CONTEXT.md")} has been updated"
      assert result =~ "Committed:"
      assert File.read!(Path.join([tmp_dir, hostile_dir, "CONTEXT.md"])) == "new content"

      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
      assert log =~ "Update CONTEXT.md for #{hostile_dir}"
    end
  end

  describe "write_context node scope" do
    test "writes the agent's own node and its descendants", %{tmp_dir: tmp_dir} do
      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./src", "content" => "src context", "commit" => false},
          tmp_dir,
          nil,
          "./src"
        )

      assert result == "Successfully updated CONTEXT.md for directory './src'"
      assert File.read!(Path.join(tmp_dir, "src/CONTEXT.md")) == "src context"

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./src/nested/deeper", "content" => "deep context", "commit" => false},
          tmp_dir,
          nil,
          "./src"
        )

      assert result ==
               "Successfully updated CONTEXT.md for directory './src/nested/deeper'"

      assert File.read!(Path.join(tmp_dir, "src/nested/deeper/CONTEXT.md")) == "deep context"
    end

    test "rejects a sibling directory and touches neither the filesystem nor git", %{
      tmp_dir: tmp_dir
    } do
      init_git_repo!(tmp_dir)

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./doc", "content" => "doc context", "commit" => true},
          tmp_dir,
          tmp_dir,
          "./src"
        )

      assert_context_scope_error(result, "doc")

      # Rejected BEFORE any filesystem change: the directory was never created
      # and nothing was staged or committed.
      refute File.exists?(Path.join(tmp_dir, "doc"))
      assert last_commit_subject(tmp_dir) == "init commit"
      assert git_status_porcelain(tmp_dir) == ""
    end

    test "rejects the repo root (a parent node) and a sibling without touching either file", %{
      tmp_dir: tmp_dir
    } do
      root_context = Path.join(tmp_dir, "CONTEXT.md")
      File.write!(root_context, "root context")
      File.mkdir_p!(Path.join(tmp_dir, "doc"))
      File.write!(Path.join(tmp_dir, "doc/CONTEXT.md"), "doc context")

      # A node may only write ITSELF and its DESCENDANTS — never a parent
      # (`./`, the repo root) and never a sibling (`./doc`).
      parent_result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./", "content" => "hijacked root", "commit" => false},
          tmp_dir,
          nil,
          "./src"
        )

      sibling_result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./doc/CONTEXT.md", "content" => "hijacked doc", "commit" => false},
          tmp_dir,
          nil,
          "./src"
        )

      assert_context_scope_error(parent_result, ".")
      assert_context_scope_error(sibling_result, "doc/CONTEXT.md")

      # Both pre-existing files are byte-identical afterwards.
      assert File.read!(root_context) == "root context"
      assert File.read!(Path.join(tmp_dir, "doc/CONTEXT.md")) == "doc context"
    end

    test "a root agent (node_path './') may write the root, a child and a deep descendant", %{
      tmp_dir: tmp_dir
    } do
      init_git_repo!(tmp_dir)

      assert "Successfully updated CONTEXT.md for directory './'" =
               Tools.execute(
                 "write_context",
                 %{"dir_path" => "./", "content" => "root context", "commit" => false},
                 tmp_dir,
                 tmp_dir,
                 "./"
               )

      assert "Successfully updated CONTEXT.md for directory './doc'" =
               Tools.execute(
                 "write_context",
                 %{"dir_path" => "./doc", "content" => "doc context", "commit" => false},
                 tmp_dir,
                 tmp_dir,
                 "./"
               )

      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./src/deep", "content" => "deep context", "commit" => true},
          tmp_dir,
          tmp_dir,
          "./"
        )

      assert result =~ "Successfully updated CONTEXT.md for directory './src/deep'"
      assert result =~ "Committed:"

      assert File.read!(Path.join(tmp_dir, "CONTEXT.md")) == "root context"
      assert File.read!(Path.join(tmp_dir, "doc/CONTEXT.md")) == "doc context"
      assert File.read!(Path.join(tmp_dir, "src/deep/CONTEXT.md")) == "deep context"
      assert last_commit_subject(tmp_dir) =~ "Update CONTEXT.md for ./src/deep"
    end

    test "a nil node_path (4-arity dispatch and Context.execute_write/3) allows any directory", %{
      tmp_dir: tmp_dir
    } do
      # Backward compatibility: direct callers that pass no node_path are not
      # scope-checked at all — the pre-existing contract, at both layers.
      result =
        Tools.execute(
          "write_context",
          %{"dir_path" => "./doc", "content" => "doc context", "commit" => false},
          tmp_dir,
          tmp_dir
        )

      assert result == "Successfully updated CONTEXT.md for directory './doc'"
      assert File.read!(Path.join(tmp_dir, "doc/CONTEXT.md")) == "doc context"

      assert "Successfully updated CONTEXT.md for directory 'outside/any/node'" =
               EvoGit.Agent.Tools.Context.execute_write(
                 %{
                   "dir_path" => "outside/any/node",
                   "content" => "direct context",
                   "commit" => false
                 },
                 tmp_dir,
                 nil
               )

      assert File.read!(Path.join(tmp_dir, "outside/any/node/CONTEXT.md")) == "direct context"
    end
  end

  describe "edit_context node scope" do
    test "edits the agent's own node and its descendants", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "src/deep"))
      File.write!(Path.join(tmp_dir, "src/CONTEXT.md"), "old src")
      File.write!(Path.join(tmp_dir, "src/deep/CONTEXT.md"), "old deep")

      assert "The file ./src/CONTEXT.md has been updated successfully." =
               Tools.execute(
                 "edit_context",
                 %{
                   "dir_path" => "./src",
                   "old_string" => "old",
                   "new_string" => "new",
                   "commit" => false
                 },
                 tmp_dir,
                 nil,
                 "./src"
               )

      assert "The file ./src/deep/CONTEXT.md has been updated successfully." =
               Tools.execute(
                 "edit_context",
                 %{
                   "dir_path" => "./src/deep",
                   "old_string" => "old",
                   "new_string" => "new",
                   "commit" => false
                 },
                 tmp_dir,
                 nil,
                 "./src"
               )

      assert File.read!(Path.join(tmp_dir, "src/CONTEXT.md")) == "new src"
      assert File.read!(Path.join(tmp_dir, "src/deep/CONTEXT.md")) == "new deep"
    end

    test "rejects a sibling directory, leaving its CONTEXT.md byte-identical and uncommitted", %{
      tmp_dir: tmp_dir
    } do
      init_git_repo!(tmp_dir)

      doc_context = Path.join(tmp_dir, "doc/CONTEXT.md")
      File.mkdir_p!(Path.dirname(doc_context))
      File.write!(doc_context, "# Doc\n\nOriginal content here")
      System.cmd("git", ["add", "doc/CONTEXT.md"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "doc context commit"], cd: tmp_dir)
      original = File.read!(doc_context)

      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => "./doc",
            "old_string" => "Original",
            "new_string" => "Rewritten",
            "commit" => true
          },
          tmp_dir,
          tmp_dir,
          "./src"
        )

      assert_context_scope_error(result, "doc")

      # The rejection happens BEFORE the file is read/replaced or committed.
      assert File.read!(doc_context) == original
      assert last_commit_subject(tmp_dir) == "doc context commit"
      assert git_status_porcelain(tmp_dir) == ""
    end

    test "a non-existent OUT-OF-SCOPE directory reports the scope error, not 'does not exist'", %{
      tmp_dir: tmp_dir
    } do
      # The scope check precedes the existence check, so the model learns the
      # real obstacle (scope) instead of a misleading missing-directory error.
      result =
        Tools.execute(
          "edit_context",
          %{
            "dir_path" => "./nope",
            "old_string" => "a",
            "new_string" => "b",
            "commit" => false
          },
          tmp_dir,
          nil,
          "./src"
        )

      assert_context_scope_error(result, "nope")
      refute result =~ "does not exist"
      refute File.exists?(Path.join(tmp_dir, "nope"))
    end

    test "Context.execute_edit/3 (node_path defaults to nil) still edits anywhere", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "outside/any/node"))
      File.write!(Path.join(tmp_dir, "outside/any/node/CONTEXT.md"), "old")

      assert "The file outside/any/node/CONTEXT.md has been updated successfully." =
               EvoGit.Agent.Tools.Context.execute_edit(
                 %{
                   "dir_path" => "outside/any/node",
                   "old_string" => "old",
                   "new_string" => "new",
                   "commit" => false
                 },
                 tmp_dir,
                 nil
               )

      assert File.read!(Path.join(tmp_dir, "outside/any/node/CONTEXT.md")) == "new"
    end
  end

  describe "CONTEXT.md node scope - repo role interaction" do
    test "a read-only foreign repo is still rejected at the PATH level for both tools", %{
      tmp_dir: tmp_dir
    } do
      foreign_root = Path.join(tmp_dir, "foreign")

      # The AGENT is a primary-repo agent (so the dispatch-level gate lets the
      # call through); the TARGET directory lives inside the read-only foreign
      # repo. Only `validate_file_scope/4`'s path-level check can catch this —
      # and it does, before the node-scope comparison.
      with_repo_role(
        [%EvoGit.Core.ForeignRepo{id: "orig", root: foreign_root, writable: false}],
        EvoGit.Core.ForeignRepo.primary_id(),
        tmp_dir,
        fn _repo_path ->
          foreign_dir = Path.join(foreign_root, "src")

          write_result =
            Tools.execute(
              "write_context",
              %{"dir_path" => foreign_dir, "content" => "foreign context", "commit" => false},
              tmp_dir,
              nil,
              "./src"
            )

          edit_result =
            Tools.execute(
              "edit_context",
              %{
                "dir_path" => foreign_dir,
                "old_string" => "a",
                "new_string" => "b",
                "commit" => false
              },
              tmp_dir,
              nil,
              "./src"
            )

          for result <- [write_result, edit_result] do
            assert String.starts_with?(result, "Error: ")
            assert result =~ "read-only foreign repository"
            refute result =~ "outside your scope"
          end

          refute File.exists?(Path.join(foreign_dir, "CONTEXT.md"))
        end
      )
    end

    test "a writable foreign repo still accepts an in-node CONTEXT.md write", %{
      tmp_dir: tmp_dir
    } do
      with_foreign_repo(tmp_dir, [writable: true], fn repo_path ->
        result =
          Tools.execute(
            "write_context",
            %{"dir_path" => "./src", "content" => "foreign context", "commit" => false},
            repo_path,
            nil,
            "./src"
          )

        assert result == "Successfully updated CONTEXT.md for directory './src'"
        assert File.read!(Path.join(repo_path, "src/CONTEXT.md")) == "foreign context"
      end)
    end

    test "a primary repo with a read-only foreign repo registered still writes its own subtree",
         %{tmp_dir: tmp_dir} do
      with_primary_repo(tmp_dir, fn repo_path ->
        write_result =
          Tools.execute(
            "write_context",
            %{"dir_path" => "./src", "content" => "primary context", "commit" => false},
            repo_path,
            nil,
            "./src"
          )

        File.mkdir_p!(Path.join(tmp_dir, "doc"))
        File.write!(Path.join(tmp_dir, "doc/CONTEXT.md"), "old")

        edit_result =
          Tools.execute(
            "edit_context",
            %{
              "dir_path" => "./doc",
              "old_string" => "old",
              "new_string" => "new",
              "commit" => false
            },
            repo_path,
            nil,
            "./"
          )

        assert write_result == "Successfully updated CONTEXT.md for directory './src'"
        assert edit_result =~ "has been updated successfully"
        assert File.read!(Path.join(tmp_dir, "doc/CONTEXT.md")) == "new"
      end)
    end
  end

  describe "execute/4 - unknown tool" do
    # Both tests below also pin the generic "Unknown tool" shape, so no separate
    # generic-unknown test is needed.
    test "suggests the closest tool name for a near miss", %{tmp_dir: tmp_dir} do
      result = Tools.execute("read_fil", %{}, tmp_dir)
      assert result =~ "Unknown tool 'read_fil'"
      assert result =~ "Did you mean 'read'?"
    end

    test "lists the available tools when there is no close match", %{tmp_dir: tmp_dir} do
      result = Tools.execute("zzz_missing_zzz", %{}, tmp_dir)
      assert result =~ "Unknown tool 'zzz_missing_zzz'"
      assert result =~ "Available tools:"
    end
  end

  describe "execute/5 - shell tool alias normalization" do
    test "normalizes well-known shell aliases to the platform shell tool", %{tmp_dir: tmp_dir} do
      for alias_name <- ~w(
            Bash bash BASH Shell shell sh
            execute_bash bash_command run_shell shell_command
          ) do
        result = Tools.execute(alias_name, %{"command" => "echo alias-ok"}, tmp_dir, tmp_dir)

        assert result =~ "alias-ok",
               "expected alias #{inspect(alias_name)} to execute the shell command, got: #{inspect(result)}"

        refute result =~ "Unknown tool",
               "expected alias #{inspect(alias_name)} NOT to be reported as an unknown tool, got: #{inspect(result)}"
      end
    end

    test "normalizes a case-variant of the platform shell tool name", %{tmp_dir: tmp_dir} do
      result = Tools.execute("RUN_BASH", %{"command" => "echo upper-ok"}, tmp_dir, tmp_dir)

      assert result =~ "upper-ok"
      refute result =~ "Unknown tool"
    end

    test "runs the other platform's shell tool name too", %{tmp_dir: tmp_dir} do
      other = if @shell_tool_name == "run_bash", do: "run_powershell", else: "run_bash"

      result = Tools.execute(other, %{"command" => "echo cross-platform-ok"}, tmp_dir, tmp_dir)

      assert result =~ "cross-platform-ok"
      refute result =~ "Unknown tool"
    end

    test "normalizes the alias through the JSON-encoded whole-args fallback", %{tmp_dir: tmp_dir} do
      args = Jason.encode!(%{"command" => "echo json-ok"})

      result = Tools.execute("Bash", args, tmp_dir, tmp_dir)

      assert result =~ "json-ok"
      refute result =~ "Unknown tool"
    end
  end

  describe "execute/5 - shell alias honors the write guards" do
    test "a shell alias is blocked for repo-less agents (normalized before the guard)", %{
      tmp_dir: tmp_dir
    } do
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)

      result = Tools.execute("Bash", %{"command" => "echo should-not-run"}, tmp_dir, tmp_dir)

      assert is_binary(result)
      assert result =~ "read-only access to the system"
      refute result =~ "should-not-run"
    end
  end

  describe "execute/4 - whole args as JSON string fallback" do
    test "recovers when entire args object is a JSON-encoded string", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.txt")
      File.write!(file_path, "hello world")

      # The model double-encodes the WHOLE arguments object as a string.
      encoded = Jason.encode!(%{"file_path" => "test.txt"})

      result = Tools.execute("read_file", encoded, tmp_dir)

      # Recovery succeeds — the tool reads the file normally.
      assert result =~ "hello world"
      refute result =~ "JSON-encoded string"
    end

    test "returns a helpful string error when the string decodes to something that is not an object",
         %{tmp_dir: tmp_dir} do
      # Invalid JSON and valid JSON that is not an object (an array) take the same
      # teaching-error path.
      for malformed <- ["not-json", Jason.encode!(["not", "an", "object"])] do
        result = Tools.execute("read_file", malformed, tmp_dir)

        assert is_binary(result)
        assert result =~ "JSON-encoded string instead of a JSON object"
        assert result =~ "Pass the arguments as a real JSON object"
      end
    end
  end

  describe "web_search in schemas" do
    test "web_search is NOT included in schemas/0 or read_only_schemas/0 by default" do
      with_isolated_config(fn ->
        refute "web_search" in Enum.map(Tools.schemas(), & &1.name)
        refute "web_search" in Enum.map(Tools.read_only_schemas(), & &1.name)
      end)
    end
  end

  describe "read_only_schemas/0 contents" do
    test "offers the unconditional read-only network reader, but not the config-gated lsp" do
      with_isolated_config(fn ->
        names = Enum.map(Tools.read_only_schemas(), & &1.name)

        # `web_fetch` is always offered; `lsp` is appended only when
        # `EvoGit.Config.lsp_enabled?/0` (an enabled `[lsp]` section with a
        # non-empty command), so it is absent under the stock config.
        assert "web_fetch" in names
        refute "lsp" in names
      end)
    end

    test "omits the file-mutating write tools" do
      names = Enum.map(Tools.read_only_schemas(), & &1.name)

      # `write_context`/`edit_context`/`bash` are KEPT by design (read-only
      # agents still update CONTEXT.md and run `mix test` in their own repo);
      # every other writer must be absent from the read-only set.
      for name <- ~w(write edit create_files make_dir run_git skill_add skill_edit skill_remove) do
        refute name in names,
               "expected the write tool #{inspect(name)} to be absent from read_only_schemas/0"
      end
    end
  end

  describe "execute/5 - read-only foreign repo write gate" do
    test "blocks write tools inside a read-only foreign repo", %{tmp_dir: tmp_dir} do
      with_read_only_foreign_repo(tmp_dir, fn repo_path ->
        # The guard classifies an ALIAS-AWARE tool name and blocks BEFORE any
        # tool runs, so the argument values below are never interpreted — the
        # fixture is about the SPELLING (model-facing names such as `write` /
        # `edit` / `bash` alongside the internal dispatch keys).
        for {name, args} <- [
              {"write_file", %{"file_path" => "test.txt", "content" => "x"}},
              {"write", %{"file_path" => "test.txt", "content" => "x"}},
              {"edit_file",
               %{"file_path" => "test.txt", "old_string" => "a", "new_string" => "b"}},
              {"edit", %{"file_path" => "test.txt", "old_string" => "a", "new_string" => "b"}},
              {"create_files", %{"paths" => [%{"path" => "test.txt", "content" => "x"}]}},
              {"make_dir", %{"path" => "sub"}},
              {"write_context", %{"dir_path" => "lib", "content" => "x"}},
              {"edit_context", %{"dir_path" => "lib", "old_string" => "a", "new_string" => "b"}},
              {"run_bash", %{"command" => "echo hi"}},
              {"Bash", %{"command" => "echo hi"}},
              {"run_git", %{"args" => ["status"]}}
            ] do
          result = Tools.execute(name, args, repo_path)

          assert result =~ "read-only foreign repository",
                 "expected #{inspect(name)} to be blocked in a read-only foreign repo, got: #{inspect(result)}"
        end
      end)
    end

    test "blocks the JSON-encoded whole-args form inside a read-only foreign repo", %{
      tmp_dir: tmp_dir
    } do
      with_read_only_foreign_repo(tmp_dir, fn repo_path ->
        result =
          Tools.execute(
            "write_file",
            Jason.encode!(%{"file_path" => "test.txt", "content" => "x"}),
            repo_path
          )

        assert result =~ "read-only foreign repository"
      end)
    end

    test "allows write tools unless the target repo is a READ-ONLY foreign repo", %{
      tmp_dir: tmp_dir
    } do
      # Same call under every non-blocking repo role: a writable foreign repo, the
      # primary repo (with a read-only foreign repo registered), and no foreign
      # repos at all.
      write = fn repo_path ->
        Tools.execute("write_file", %{"file_path" => "sub/file.txt", "content" => "x"}, repo_path)
      end

      with_foreign_repo(tmp_dir, [writable: true], fn repo_path ->
        assert write.(repo_path) =~ "Successfully wrote to"
      end)

      with_primary_repo(tmp_dir, fn repo_path ->
        assert write.(repo_path) =~ "Successfully wrote to"
      end)

      with_no_foreign_repos(tmp_dir, fn repo_path ->
        assert write.(repo_path) =~ "Successfully wrote to"
      end)
    end
  end

  describe "EvoGit.Config.tools_search_enabled?/0" do
    test "returns false by default and stays false when only the API key is set" do
      with_isolated_config(fn ->
        refute EvoGit.Config.tools_search_enabled?()

        # A provider key alone never enables the tool — the config toggle must
        # also be on.
        ReqLLM.put_key(:tavily_api_key, "test-key")

        try do
          refute EvoGit.Config.tools_search_enabled?()
        after
          Application.delete_env(:req_llm, :tavily_api_key)
        end
      end)
    end
  end

  describe "WebSearch.execute/3" do
    test "returns error when API key is missing" do
      # Ensure no API key is set
      original_reqllm_key = Application.get_env(:req_llm, :tavily_api_key)
      Application.delete_env(:req_llm, :tavily_api_key)

      try do
        result = EvoGit.Agent.Tools.WebSearch.execute(%{"query" => "test query"}, nil, nil)
        assert result =~ "Error: API key for search provider is not set"
      after
        if original_reqllm_key,
          do: Application.put_env(:req_llm, :tavily_api_key, original_reqllm_key)
      end
    end

    test "returns error for missing query argument" do
      result = EvoGit.Agent.Tools.WebSearch.execute(%{}, nil, nil)
      assert {:error, msg} = result
      assert msg =~ "Missing required argument 'query'"
    end

    test "returns error for invalid search_depth" do
      result =
        EvoGit.Agent.Tools.WebSearch.execute(
          %{"query" => "test", "search_depth" => "deep"},
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "Argument 'search_depth' must be 'basic' or 'advanced'"
    end

    test "returns error for invalid max_results" do
      result =
        EvoGit.Agent.Tools.WebSearch.execute(%{"query" => "test", "max_results" => 100}, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "Argument 'max_results' must be an integer between 1 and 50"
    end
  end

  describe "WebSearch.schema/1" do
    test "returns a valid tool schema with defaults" do
      schema = EvoGit.Agent.Tools.WebSearch.schema()
      assert schema.name == "web_search"
      assert schema.description =~ "web"
      assert schema.parameter_schema["properties"]["query"]
      assert schema.parameter_schema["required"] == ["query"]
    end

    test "schema/1 accepts opts (ignored for now)" do
      schema1 = EvoGit.Agent.Tools.WebSearch.schema([])
      schema2 = EvoGit.Agent.Tools.WebSearch.schema(some: :opts)
      assert schema1.name == schema2.name
    end
  end

  # Runs `fun` with the process-dict keys that `maybe_block_read_only_foreign_repo/5`
  # reads (`:foreign_repos`, `:evogit_repo_id`, `:repo_path`) set to the given
  # values. Restores any prior values on exit (the test process's dictionary
  # dies with the test anyway; this is belt-and-braces).
  defp with_repo_role(foreign_repos, repo_id, repo_path, fun) do
    prior = {Process.get(:foreign_repos), Process.get(:evogit_repo_id), Process.get(:repo_path)}

    on_exit(fn ->
      {prior_foreign, prior_id, prior_path} = prior
      restore_process_key(:foreign_repos, prior_foreign)
      restore_process_key(:evogit_repo_id, prior_id)
      restore_process_key(:repo_path, prior_path)
    end)

    Process.put(:foreign_repos, foreign_repos)
    Process.put(:evogit_repo_id, repo_id)
    Process.put(:repo_path, repo_path)

    fun.(repo_path)
  end

  defp restore_process_key(_key, nil), do: :ok
  defp restore_process_key(key, value), do: Process.put(key, value)

  # Agent operating inside a READ-ONLY foreign repo: the id matches the foreign
  # repo entry and the repo_path lives under the foreign root's workers dir.
  defp with_read_only_foreign_repo(tmp_dir, fun) do
    foreign_root = Path.join(tmp_dir, "foreign")
    repo_path = Path.join([foreign_root, ".genesis", "workers", "worker_T1_A1"])

    with_repo_role(
      [%EvoGit.Core.ForeignRepo{id: "orig", root: foreign_root, writable: false}],
      "orig",
      repo_path,
      fun
    )
  end

  defp with_foreign_repo(tmp_dir, opts, fun) do
    foreign_root = Path.join(tmp_dir, "foreign")
    repo_path = Path.join([foreign_root, ".genesis", "workers", "worker_T1_A1"])

    with_repo_role(
      [%EvoGit.Core.ForeignRepo{id: "orig", root: foreign_root, writable: opts[:writable]}],
      "orig",
      repo_path,
      fun
    )
  end

  # Primary-repo agent: repo_id is the primary id and repo_path sits OUTSIDE the
  # foreign root, so the resolve_path fallback cannot re-match the foreign repo.
  defp with_primary_repo(tmp_dir, fun) do
    with_repo_role(
      [
        %EvoGit.Core.ForeignRepo{id: "orig", root: Path.join(tmp_dir, "foreign"), writable: false}
      ],
      EvoGit.Core.ForeignRepo.primary_id(),
      tmp_dir,
      fun
    )
  end

  defp with_no_foreign_repos(tmp_dir, fun) do
    with_repo_role([], EvoGit.Core.ForeignRepo.primary_id(), tmp_dir, fun)
  end

  # Initializes a git repository in `dir` with a single "init commit". Mirrors
  # the inline fixture the existing write_context/edit_context commit tests use,
  # so a rejected node-scope call can be proven to leave history untouched.
  defp init_git_repo!(dir) do
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "init")
    System.cmd("git", ["add", "README.md"], cd: dir)
    System.cmd("git", ["commit", "-m", "init commit"], cd: dir)
    :ok
  end

  defp last_commit_subject(dir) do
    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: dir)
    String.trim(log)
  end

  defp git_status_porcelain(dir) do
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
    String.trim(status)
  end

  # Asserts the out-of-node CONTEXT.md rejection shape: an `"Error: "` result
  # carrying the whole teaching text from `Shared.format_context_scope_error/2`
  # (the target path is rendered repo-relative — `"doc"`, or `"."` for the repo
  # root itself).
  defp assert_context_scope_error(result, target) do
    assert String.starts_with?(result, "Error: "),
           "expected an Error: result, got: #{inspect(result)}"

    assert result =~ "Cannot modify CONTEXT.md at '#{target}'."
    assert result =~ "outside your scope"
    assert result =~ "The agent that owns '#{target}' (or its parent) must make that update"
    assert result =~ "Put the finding in your report instead"
  end

  # Runs `fun` with the PER-PROCESS config directory pointed at a fresh temp
  # directory that contains NO genesis/config.toml, so tests are isolated from
  # the real user config. The override is dropped again when `fun` returns.
  defp with_isolated_config(fun) do
    ConfigDir.isolate!("evogit-tools-cfg")

    try do
      fun.()
    after
      Process.delete(:evogit_config_dir)
    end
  end

  # Writes a minimal custom-tool module into the isolated config dir's `tools/`
  # subdirectory (see `with_isolated_config/1`) so `Tools.serial_tool?/1` can be
  # classified through `EvoGit.CustomTools.write_tool?/1`. `read_only` selects
  # whether the tool declares itself read-only.
  defp write_isolated_custom_tool!(module, tool_name, read_only) do
    dir = Path.join(EvoGit.Config.config_dir(), "tools")
    File.mkdir_p!(dir)

    source = """
    defmodule #{inspect(module)} do
      @behaviour EvoGit.CustomTools.Tool

      @impl true
      def schema do
        ReqLLM.tool(
          name: #{inspect(tool_name)},
          description: "serial_tool?/1 classification fixture",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, nil} end
        )
      end

      @impl true
      def execute(_args, _ctx), do: "ok"

      @impl true
      def read_only?, do: #{read_only}
    end
    """

    File.write!(Path.join(dir, "#{tool_name}.exs"), source)
  end
end
