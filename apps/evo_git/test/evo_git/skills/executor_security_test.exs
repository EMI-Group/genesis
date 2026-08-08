defmodule EvoGit.Skills.ExecutorSecurityTest do
  # Security tests for the skills execution path: positional-parameter
  # substitution (values passed as argv, never inlined) and sandbox routing.
  #
  # NOTE: This file lives in the skills node (lib tree) temporarily — it will
  # be relocated to the app test tree by the parent. It is a normal ExUnit
  # test file and can run from either location.
  use ExUnit.Case, async: false

  alias EvoGit.Skills.Executor
  alias EvoGit.Skills.Skill

  # ---------------------------------------------------------------------------
  # substitute_params/3 — pinned legacy behavior (raw, NOT safe for execution)
  # ---------------------------------------------------------------------------

  describe "substitute_params/3 (legacy raw substitution)" do
    test "still inlines values verbatim (byte-for-byte legacy behavior)" do
      script = ~s(echo "{{name}}")
      params = [%{name: "name", type: "string", description: "Name", required: true}]

      assert Executor.substitute_params(script, params, %{"name" => "Alice"}) ==
               ~s(echo "Alice")
    end

    test "inlines shell metacharacters verbatim (proving it is NOT execution-safe)" do
      script = ~s(echo "{{x}}")
      params = [%{name: "x", type: "string", description: "X", required: true}]
      payload = "; rm -rf /some/path; #"

      assert Executor.substitute_params(script, params, %{"x" => payload}) ==
               ~s(echo "; rm -rf /some/path; #")
    end
  end

  # ---------------------------------------------------------------------------
  # build_positional_script/3 — injection-safe substitution scheme
  # ---------------------------------------------------------------------------

  describe "build_positional_script/3" do
    test "single param becomes a double-quoted positional reference" do
      script = ~s(echo "{{name}}")
      params = [%{name: "name", type: "string", description: "Name", required: true}]

      assert Executor.build_positional_script(script, params, %{"name" => "Alice"}) ==
               {~s(echo ""$1""), ["Alice"]}
    end

    test "multiple params: refs are 1-indexed in parameters order, values match" do
      script = ~s(echo {{a}} {{b}})

      params = [
        %{name: "a", type: "string", description: "A", required: true},
        %{name: "b", type: "string", description: "B", required: true}
      ]

      assert Executor.build_positional_script(script, params, %{"a" => "A", "b" => "B"}) ==
               {~s(echo "$1" "$2"), ["A", "B"]}
    end

    test "replaces ALL occurrences of each placeholder" do
      script = ~s(echo "{{x}}" && echo {{x}} && DEBUG={{x}})
      params = [%{name: "x", type: "string", description: "X", required: true}]

      {script_refs, values} = Executor.build_positional_script(script, params, %{"x" => "V"})

      assert script_refs == ~s(echo ""$1"" && echo "$1" && DEBUG="$1")
      assert values == ["V"]
    end

    test "values order matches parameters order regardless of script order" do
      script = ~s(echo {{second}} {{first}})

      params = [
        %{name: "first", type: "string", description: "First", required: true},
        %{name: "second", type: "string", description: "Second", required: true}
      ]

      {script_refs, values} =
        Executor.build_positional_script(script, params, %{"first" => "F", "second" => "S"})

      assert script_refs == ~s(echo "$2" "$1")
      assert values == ["F", "S"]
    end

    test "uses default value when arg not provided" do
      script = ~s(DEBUG={{debug}})

      params = [
        %{name: "debug", type: "boolean", description: "Debug", required: false, default: false}
      ]

      {script_refs, values} = Executor.build_positional_script(script, params, %{})

      assert script_refs == ~s(DEBUG="$1")
      assert values == ["false"]
    end

    test "uses empty string when no arg and no default" do
      script = ~s(echo "{{greeting}} {{name}}")

      params = [
        %{name: "greeting", type: "string", description: "Greeting", required: false},
        %{name: "name", type: "string", description: "Name", required: true}
      ]

      {script_refs, values} = Executor.build_positional_script(script, params, %{"name" => "W"})

      assert script_refs == ~s(echo ""$1" "$2"")
      assert values == ["", "W"]
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end injection tests through the FULL Executor.execute/4 path
  # (real bash; test env uses the disabled sandbox path → plain bash, hermetic)
  # ---------------------------------------------------------------------------

  describe "Executor.execute/4 injection resistance (full path)" do
    test "benign value passes through as data" do
      tmp = fresh_tmp_dir!()
      skill = skill_with_echo(%{name: "x", type: "string", description: "X", required: true})

      result = Executor.execute([skill], "echo-skill", %{"x" => "Alice"}, tmp)

      assert result =~ "Skill executed successfully"
      assert result =~ "Alice"
    end

    test "semicolon payload cannot delete the sentinel file" do
      tmp = fresh_tmp_dir!()
      sentinel = Path.join(tmp, "sentinel.txt")
      File.write!(sentinel, "keep me")
      payload = "; rm -rf #{sentinel}; #"

      result = run_echo_skill(tmp, payload)

      assert result =~ "Skill executed successfully"
      assert result =~ payload
      assert File.exists?(sentinel), "sentinel file was deleted — injection succeeded!"
    end

    test "backtick payload cannot create the marker file" do
      tmp = fresh_tmp_dir!()
      sentinel = Path.join(tmp, "sentinel.txt")
      File.write!(sentinel, "keep me")
      marker = Path.join(tmp, "marker.txt")
      payload = "`touch #{marker}`"

      result = run_echo_skill(tmp, payload)

      assert result =~ "Skill executed successfully"
      assert result =~ payload
      assert File.exists?(sentinel)
      refute File.exists?(marker), "marker file was created — injection succeeded!"
    end

    test "$() payload cannot create the marker file" do
      tmp = fresh_tmp_dir!()
      sentinel = Path.join(tmp, "sentinel.txt")
      File.write!(sentinel, "keep me")
      marker = Path.join(tmp, "marker.txt")
      payload = "$(touch #{marker})"

      result = run_echo_skill(tmp, payload)

      assert result =~ "Skill executed successfully"
      assert result =~ payload
      assert File.exists?(sentinel)
      refute File.exists?(marker), "marker file was created — injection succeeded!"
    end

    test "payload with quotes and metacharacters passes through as literal data" do
      tmp = fresh_tmp_dir!()
      sentinel = Path.join(tmp, "sentinel.txt")
      File.write!(sentinel, "keep me")
      marker = Path.join(tmp, "marker.txt")
      payload = ~s("; touch #{marker} & echo "nested)

      result = run_echo_skill(tmp, payload)

      assert result =~ "Skill executed successfully"
      assert result =~ "; touch #{marker}"
      assert File.exists?(sentinel)
      refute File.exists?(marker), "marker file was created — injection succeeded!"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Runs a skill whose bash block echoes the param both inside double quotes
  # and bare — the two contexts the positional scheme must keep safe.
  defp run_echo_skill(tmp, payload) do
    skill = skill_with_echo(%{name: "x", type: "string", description: "X", required: true})
    Executor.execute([skill], "echo-skill", %{"x" => payload}, tmp)
  end

  defp skill_with_echo(param) do
    %Skill{
      name: "echo-skill",
      description: "Echoes the x parameter",
      parameters: [param],
      body: """
      # Echo Skill

      Echoes the value.

      ```bash
      echo "{{x}}"
      echo {{x}}
      ```
      """,
      file_path: "echo-skill.md"
    }
  end

  defp fresh_tmp_dir! do
    tmp = Path.join(System.tmp_dir!(), "evogit_skill_sec_#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end
end
