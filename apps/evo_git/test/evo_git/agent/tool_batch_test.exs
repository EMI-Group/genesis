defmodule EvoGit.Agent.ToolBatchTest.BatchSubagent do
  @moduledoc """
  A subagent module declared by `BatchAgent`, used to prove that the `:subagent`
  class is driven by the AGENT'S declared `subagent_modules/0` (the same way the
  runtime derives it) and by nothing else.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  @doc "The generated subagent tool name (what the model emits)."
  def subagent_tool_name, do: "subagent_batch_probe"

  @doc "The generated subagent tool description."
  def subagent_tool_description, do: "A probe subagent declared only by the tool-batch test."
end

defmodule EvoGit.Agent.ToolBatchTest.BatchAgent do
  @moduledoc """
  The role whose `subagent_modules/0` the classifier receives — the production
  contract, which is `agent_module.subagent_modules()` (`EvoGit.Agent.Turn`).
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the tool-batch classification stub agent."

  @doc "No tools: classification is name-only, no schema is ever dispatched."
  def available_tools, do: []

  @doc "The declared subagent modules handed to `EvoGit.Agent.ToolBatch`."
  def subagent_modules, do: [EvoGit.Agent.ToolBatchTest.BatchSubagent]
end

defmodule EvoGit.Agent.ToolBatchTest do
  @moduledoc """
  Unit contract for `EvoGit.Agent.ToolBatch` — the in-flight tool-batch marker
  persisted on `%EvoGit.Agent.State{pending_tool_batch: batch}`.

  ## What is pinned

  1. **Classification** comes from the EXISTING sources of truth and never from
     a duplicated list: `:subagent` from the agent's own `subagent_modules/0`,
     `:shell` for both platform shell spellings (`run_bash`/`run_powershell`)
     plus the `bash`/`shell`/`sh` model-facing aliases and the legacy
     `run_command` spelling, `:edit` for the editing write tools, `:write` for
     the rest of `EvoGit.Agent.Tools`' write set, `:read` for everything else;
  2. **`build/3` is total** — a non-list/empty call list yields NO marker (an
     empty batch is never "executing"), and malformed entries degrade to a
     well-formed entry with a `:read` class instead of raising;
  3. **`normalize/1` is the ONE JSON boundary** — a round trip through Jason
     reproduces the built marker exactly (STRING keys + STRING classes back to
     Atom classes, call order preserved), and every malformed shape a restored
     column could hold degrades to `nil` (no marker) rather than raising in the
     resume path.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.ToolBatchTest.BatchAgent
  alias EvoGit.Agent.ToolNames
  alias EvoGit.Agent.Tools

  # Every accepted spelling of the platform shell tool, INCLUDING both
  # platform-pinned names (`run_bash` on POSIX, `run_powershell` on Windows):
  # `ToolNames.normalize/1` resolves all of them to `shell_tool_name/0`.
  @shell_names [
    "bash",
    "Bash",
    "sh",
    "shell",
    "run_bash",
    "run_powershell",
    "execute_bash",
    "shell_command",
    "run_shell"
  ]

  # The editing write tools, in `ToolNames`' NORMALIZED spelling, plus one
  # accepted model-facing alias.
  @edit_names ["edit", "Edit", "edit_file", "edit_context"]

  # Non-edit members of `EvoGit.Agent.Tools`' write set.
  @write_names [
    "write",
    "write_file",
    "create_files",
    "make_dir",
    "write_context",
    "run_git",
    "skill_add"
  ]

  # Read-only tools (and an unknown name, which must never be classified as a
  # write: custom tools rely on the passthrough).
  @read_names [
    "read",
    "read_file",
    "Read",
    "rg",
    "grep",
    "glob",
    "web_search",
    "list_dir",
    "elixir_eval",
    "unknown_tool_name"
  ]

  describe "class/2 — the classification sources of truth" do
    test "a DECLARED subagent module's tool name is :subagent" do
      # The declaration is what the runtime hands the classifier
      # (`state.agent_module.subagent_modules()`); assert the derivation too so
      # the test cannot pass on a hand-written name list.
      assert SubagentSchemas.tools(BatchAgent) == ["subagent_batch_probe"]

      assert ToolBatch.class("subagent_batch_probe", BatchAgent.subagent_modules()) == :subagent
    end

    test "the same subagent name is NOT :subagent without the declaration" do
      # No declared subagent modules ([] or nil) ⇒ the name is an ordinary
      # unknown tool. This is what makes the class agent-specific.
      assert ToolBatch.class("subagent_batch_probe", []) == :read
      assert ToolBatch.class("subagent_batch_probe", nil) == :read
    end

    test "every shell spelling (both platform names included) is :shell" do
      for name <- @shell_names do
        assert ToolBatch.class(name, []) == :shell, "expected #{inspect(name)} to be :shell"
      end

      # The platform-pinned name the schema actually offers.
      assert ToolNames.shell_tool_name() in @shell_names
      assert ToolBatch.class(ToolNames.shell_tool_name(), []) == :shell
    end

    test "the legacy run_command spelling is :shell even though dispatch refuses it" do
      # `run_command` is not in the alias table (it is refused by
      # `Tools.execute/5`), but a historical transcript can still carry it, so
      # the marker must not classify it as a read.
      assert ToolNames.normalize("run_command") == "run_command"
      assert ToolBatch.class("run_command", []) == :shell
    end

    test "the editing write tools are :edit, not :write" do
      for name <- @edit_names do
        assert ToolBatch.class(name, []) == :edit, "expected #{inspect(name)} to be :edit"
      end
    end

    test "the remaining write set is :write" do
      for name <- @write_names do
        assert Tools.write_tool_name?(name),
               "#{inspect(name)} is expected to be in the write set"

        assert ToolBatch.class(name, []) == :write, "expected #{inspect(name)} to be :write"
      end
    end

    test "read-only and unknown tools are :read" do
      for name <- @read_names do
        refute Tools.write_tool_name?(name),
               "#{inspect(name)} must not be in the write set"

        assert ToolBatch.class(name, []) == :read, "expected #{inspect(name)} to be :read"
      end
    end

    test "class/2 is total: a non-binary name is :read and never raises" do
      for garbage <- [nil, 42, :bash, %{}, []] do
        assert ToolBatch.class(garbage, []) == :read
      end

      # `nil` subagent modules (the `List.wrap/1` arm) is an ordinary read too.
      assert ToolBatch.class("subagent_batch_probe", nil) == :read
    end
  end

  describe "build/3 — the marker of ONE batch" do
    test "builds one entry per call from %ReqLLM.ToolCall{} structs, in model order" do
      calls = [
        ReqLLM.ToolCall.new("call_0", "read", Jason.encode!(%{"path" => "./a.ex"})),
        ReqLLM.ToolCall.new("call_1", "bash", Jason.encode!(%{"command" => "ls"})),
        ReqLLM.ToolCall.new("call_2", "edit", Jason.encode!(%{"path" => "./b.ex"}))
      ]

      batch = ToolBatch.build(calls, 4, BatchAgent.subagent_modules())

      assert batch.turn == 4
      assert is_binary(batch.started_at)
      assert {:ok, _, _} = DateTime.from_iso8601(batch.started_at)

      assert batch.calls == [
               %{index: 0, id: "call_0", name: "read", class: :read},
               %{index: 1, id: "call_1", name: "bash", class: :shell},
               %{index: 2, id: "call_2", name: "edit", class: :edit}
             ]

      # The marker carries NO arguments and no output: the assistant message in
      # the transcript already holds those.
      refute Map.has_key?(hd(batch.calls), :arguments)
      refute Map.has_key?(hd(batch.calls), :output)
    end

    test "classifies from the DECLARED subagent list and preserves a nil turn" do
      batch =
        ToolBatch.build(
          [
            %{id: "c0", name: "subagent_batch_probe"},
            %{id: "c1", name: "bash"},
            %{id: "c2", name: "write"}
          ],
          nil,
          BatchAgent.subagent_modules()
        )

      assert batch.turn == nil
      assert Enum.map(batch.calls, & &1.class) == [:subagent, :shell, :write]
      assert Enum.map(batch.calls, & &1.id) == ["c0", "c1", "c2"]
    end

    test "malformed ENTRIES degrade instead of raising" do
      batch = ToolBatch.build([%{name: "read"}, :not_a_call, 42], 2, [])

      assert batch.calls == [
               %{index: 0, id: nil, name: "read", class: :read},
               %{index: 1, id: nil, name: nil, class: :read},
               %{index: 2, id: nil, name: nil, class: :read}
             ]

      # A STRING-keyed call map (the decoded-transcript shape) is read too.
      assert ToolBatch.build([%{"id" => "c9", "name" => "bash"}], 2, []).calls == [
               %{index: 0, id: "c9", name: "bash", class: :shell}
             ]
    end

    test "an empty or non-list call list is NO marker" do
      # `pending_tool_batch != nil <=> a tool batch is executing right now`, so
      # an empty batch can never open one.
      assert ToolBatch.build([], 4, []) == nil
      assert ToolBatch.build(:nope, 4, []) == nil
      assert ToolBatch.build(nil, 4, []) == nil
      assert ToolBatch.build(%{}, 4, []) == nil
    end
  end

  describe "normalize/1 — the ONE JSON boundary" do
    test "a Jason round trip reproduces the built marker exactly" do
      calls = [
        ReqLLM.ToolCall.new("call_0", "read", "{}"),
        ReqLLM.ToolCall.new("call_1", "bash", "{}"),
        ReqLLM.ToolCall.new("call_2", "edit", "{}"),
        ReqLLM.ToolCall.new("call_3", "create_files", "{}"),
        ReqLLM.ToolCall.new("call_4", "subagent_batch_probe", "{}")
      ]

      batch = ToolBatch.build(calls, 7, BatchAgent.subagent_modules())
      restored = batch |> Jason.encode!() |> Jason.decode!()

      # The durable shape really is STRING-keyed with STRING classes.
      assert Map.has_key?(restored, "turn")
      assert Enum.all?(restored["calls"], &is_binary(&1["class"]))

      normalized = ToolBatch.normalize(restored)

      assert normalized == batch

      assert Enum.map(normalized.calls, & &1.class) ==
               [:read, :shell, :edit, :write, :subagent]

      # ORDER preserved (index and id sequence identify the model's call order).
      assert Enum.map(normalized.calls, & &1.index) == [0, 1, 2, 3, 4]

      assert Enum.map(normalized.calls, & &1.id) ==
               ["call_0", "call_1", "call_2", "call_3", "call_4"]

      assert ToolBatch.calls(normalized) == normalized.calls
    end

    test "STRING classes map to Atom classes, unknown becomes :read" do
      raw = %{
        "turn" => 5,
        "started_at" => "2026-01-01T00:00:00Z",
        "calls" => [
          %{"index" => 0, "id" => "a", "name" => "bash", "class" => "shell"},
          %{"index" => 1, "id" => "b", "name" => "task", "class" => "subagent"},
          %{"index" => 2, "id" => "c", "name" => "mystery", "class" => "not_a_class"},
          %{"index" => 3, "id" => "d", "name" => "mystery2"}
        ]
      }

      normalized = ToolBatch.normalize(raw)

      assert normalized.turn == 5
      assert normalized.started_at == "2026-01-01T00:00:00Z"
      assert Enum.map(normalized.calls, & &1.class) == [:shell, :subagent, :read, :read]
    end

    test "a missing or non-integer index falls back to the entry POSITION" do
      raw = %{
        "calls" => [
          %{"name" => "read"},
          %{"index" => "seven", "name" => "edit"},
          %{"index" => 9, "name" => "write"}
        ]
      }

      assert Enum.map(ToolBatch.normalize(raw).calls, & &1.index) == [0, 1, 9]
    end

    test "atom-keyed and atom-class values normalize to the canonical shape" do
      raw = %{
        turn: 3,
        started_at: "2026-01-01T00:00:00Z",
        calls: [%{index: 0, id: "a", name: "edit", class: :edit}]
      }

      assert ToolBatch.normalize(raw) == %{
               turn: 3,
               started_at: "2026-01-01T00:00:00Z",
               calls: [%{index: 0, id: "a", name: "edit", class: :edit}]
             }
    end

    test "malformed scalars degrade to nil fields, never to a raise" do
      normalized =
        ToolBatch.normalize(%{
          "turn" => "not_a_turn",
          "started_at" => 12_345,
          "calls" => [%{"name" => "read", "id" => 7, "class" => 99}]
        })

      assert normalized.turn == nil
      assert normalized.started_at == nil
      assert normalized.calls == [%{index: 0, id: nil, name: "read", class: :read}]
    end

    test "garbage normalizes to nil (total, never raises)" do
      for garbage <- [
            nil,
            %{},
            %{"nope" => 1},
            "a binary",
            42,
            :an_atom,
            [],
            %{"calls" => "not_a_list"},
            %{"calls" => nil},
            %{"calls" => []},
            # Every entry malformed ⇒ no well-formed call ⇒ NO marker (the
            # `!= nil <=> executing` invariant holds for restored values too).
            %{"calls" => [1, :two, nil]}
          ] do
        assert ToolBatch.normalize(garbage) == nil,
               "expected #{inspect(garbage)} to normalize to nil"
      end
    end

    test "a partially malformed calls list keeps the well-formed entries" do
      normalized =
        ToolBatch.normalize(%{
          "calls" => [%{"name" => "read"}, "junk", nil, %{"name" => "bash"}]
        })

      assert Enum.map(normalized.calls, & &1.name) == ["read", "bash"]
      # Positions come from the ORIGINAL list, so dropping entries never
      # renumbers the survivors into a different call.
      assert Enum.map(normalized.calls, & &1.index) == [0, 3]

      # An EMPTY map entry is still an ENTRY (every field degrades), so the
      # marker survives as one unclassified call rather than disappearing.
      assert ToolBatch.normalize(%{"calls" => [%{}]}) == %{
               turn: nil,
               started_at: nil,
               calls: [%{index: 0, id: nil, name: nil, class: :read}]
             }
    end
  end

  describe "calls/1 and class_counts/1 — total readers over the marker" do
    test "calls/1 answers [] for anything that is not a marker" do
      batch = ToolBatch.build([%{id: "c0", name: "read"}], 1, [])

      assert ToolBatch.calls(batch) == batch.calls
      assert ToolBatch.calls(nil) == []
      assert ToolBatch.calls(%{}) == []
      assert ToolBatch.calls("garbage") == []
    end

    test "class_counts/1 reports the fixed class order and omits empty classes" do
      batch =
        ToolBatch.build(
          [
            %{id: "c0", name: "read"},
            %{id: "c1", name: "bash"},
            %{id: "c2", name: "sh"},
            %{id: "c3", name: "subagent_batch_probe"},
            %{id: "c4", name: "write"}
          ],
          1,
          BatchAgent.subagent_modules()
        )

      # Fixed order is [:subagent, :shell, :edit, :write, :read]; `:edit` has no
      # calls and is therefore absent.
      assert ToolBatch.class_counts(batch) == [subagent: 1, shell: 2, write: 1, read: 1]
      assert ToolBatch.class_counts(nil) == []
      assert ToolBatch.class_counts(%{}) == []
    end
  end
end
