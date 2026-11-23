defmodule EvoGit.Agent.Session.CustomAgentStartTest do
  @moduledoc """
  The ROOT-session startup contract of a CUSTOM agent (GitHub issue #177):
  `EvoGit.Agent.Session.Setup.build_initial_state/3` must resolve the ctx's
  `:custom_agent_id` for the DURATION of initial-state construction, because
  `EvoGit.Agents.Custom.system_prompt/0` / `.delegation_level/0` read it from
  the process dictionary — and before this fix the SESSION process never held
  that key (only the per-exchange worker installed it later), so building the
  initial state raised `EvoGit.Agents.Custom requires spec.opts[:custom_agent_id]`.

  Pinned here:
    * the reported crash — a calling process with NO `:custom_agent_id` in its
      dictionary builds a `%State{}` from the ctx id, and the Custom branch's
      DEFINITION (not just the module default) supplied the system prompt;
    * precedence — a stale process-dictionary value never wins over the ctx id;
    * a blank/absent ctx id REMOVES the key for the duration, so a stale value
      cannot mask a missing selection (the call still fails loudly), and the
      previous process-dictionary state is restored on every exit path
      (success, unknown id, missing ctx id).

  ## Why `async: true` — no BEAM-global state

  Each test owns a per-process isolated config dir
  (`EvoGit.TestSupport.ConfigDir.isolate!/1`, the suite-wide `:config_dir_fun`
  seam) and a private temp repo dir, so `EvoGit.CustomAgents` never touches the
  real `~/.config/genesis/`. No app-global store, ETS table, app-env key or
  PubSub topic is read or written, and every lookup runs in the calling test
  process.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Core.ContextNode
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("evogit-custom-start")

    # Leak hygiene: the test process starts with no custom-agent selection.
    refute :custom_agent_id in Process.get_keys()

    # `on_exit` callbacks run in a DIFFERENT process, so this is only a
    # backstop; each test that sets the key also asserts/cleans the TEST
    # process dictionary itself before it returns.
    on_exit(fn -> Process.delete(:custom_agent_id) end)

    :ok
  end

  describe "reported crash (issue #177)" do
    test "builds the initial state from the ctx id when the process has no :custom_agent_id" do
      id =
        save_definition!(%{
          name: "Custom Root Start",
          prompt: "Be a custom root.",
          delegation_level: :low
        })

      repo = workspace!("crash")

      # The exact reported state: the SESSION process never had the key.
      refute :custom_agent_id in Process.get_keys()

      assert {:ok, built} =
               Setup.build_initial_state(
                 EvoGit.Agents.Custom,
                 "the custom objective",
                 build_ctx(repo, custom_agent_id: id)
               )

      assert %EvoGit.Agent.State{} = built
      assert built.custom_agent_id == id

      # The Custom branch really resolved the ctx DEFINITION (a module default
      # would not carry this prompt).
      assert [%ReqLLM.Message{role: :system} = system | _rest] = built.context.messages
      assert EvoGit.Util.Strings.content_text(system.content) == "Be a custom root."

      # Construction restored the (absent) previous state.
      refute :custom_agent_id in Process.get_keys()
    end
  end

  describe "precedence over a stale process-dictionary value" do
    test "the ctx id wins and the previous value is restored afterwards" do
      ctx_id =
        save_definition!(%{name: "Ctx Winner", prompt: "The ctx definition prompt."})

      stale_id =
        save_definition!(%{name: "Stale Winner", prompt: "The stale pd definition prompt."})

      Process.put(:custom_agent_id, stale_id)
      repo = workspace!("precedence")

      assert {:ok, built} =
               Setup.build_initial_state(
                 EvoGit.Agents.Custom,
                 "the custom objective",
                 build_ctx(repo, custom_agent_id: ctx_id)
               )

      assert built.custom_agent_id == ctx_id

      assert [%ReqLLM.Message{role: :system} = system | _rest] = built.context.messages
      assert EvoGit.Util.Strings.content_text(system.content) == "The ctx definition prompt."

      # Prior value restored on the success path.
      assert Process.get(:custom_agent_id) == stale_id

      Process.delete(:custom_agent_id)
      refute :custom_agent_id in Process.get_keys()
    end
  end

  describe "restore on every exit path" do
    test "an absent prior key stays absent after a successful build" do
      id = save_definition!(%{name: "Absent Prior", prompt: "Absent prior prompt."})
      repo = workspace!("absent-success")

      refute :custom_agent_id in Process.get_keys()

      assert {:ok, _built} =
               Setup.build_initial_state(
                 EvoGit.Agents.Custom,
                 "the custom objective",
                 build_ctx(repo, custom_agent_id: id)
               )

      refute :custom_agent_id in Process.get_keys()
    end

    test "an unknown ctx id raises and restores the previous value" do
      prior_id = save_definition!(%{name: "Prior Value", prompt: "Prior value prompt."})

      Process.put(:custom_agent_id, prior_id)
      repo = workspace!("unknown-prior")

      assert_raise RuntimeError, ~r/Unknown custom agent id/, fn ->
        Setup.build_initial_state(
          EvoGit.Agents.Custom,
          "the custom objective",
          build_ctx(repo, custom_agent_id: "no-such-agent")
        )
      end

      assert Process.get(:custom_agent_id) == prior_id

      Process.delete(:custom_agent_id)
      refute :custom_agent_id in Process.get_keys()
    end

    test "an unknown ctx id raises and leaves an absent key absent" do
      repo = workspace!("unknown-absent")

      refute :custom_agent_id in Process.get_keys()

      assert_raise RuntimeError, ~r/Unknown custom agent id/, fn ->
        Setup.build_initial_state(
          EvoGit.Agents.Custom,
          "the custom objective",
          build_ctx(repo, custom_agent_id: "no-such-agent")
        )
      end

      refute :custom_agent_id in Process.get_keys()
    end
  end

  describe "a stale value cannot rescue a missing ctx id" do
    test "a nil ctx id removes the key for the duration, so the call still fails loudly" do
      valid_id = save_definition!(%{name: "Valid But Unused", prompt: "Valid prompt."})

      Process.put(:custom_agent_id, valid_id)
      repo = workspace!("nil-ctx")

      assert_raise RuntimeError, ~r/requires spec\.opts\[:custom_agent_id\]/, fn ->
        Setup.build_initial_state(
          EvoGit.Agents.Custom,
          "the custom objective",
          build_ctx(repo, custom_agent_id: nil)
        )
      end

      # Restored after the raise.
      assert Process.get(:custom_agent_id) == valid_id

      Process.delete(:custom_agent_id)
      refute :custom_agent_id in Process.get_keys()
    end

    test "a blank ctx id removes the key for the duration, so the call still fails loudly" do
      valid_id = save_definition!(%{name: "Valid But Blank", prompt: "Valid prompt."})

      Process.put(:custom_agent_id, valid_id)
      repo = workspace!("blank-ctx")

      assert_raise RuntimeError, ~r/requires spec\.opts\[:custom_agent_id\]/, fn ->
        Setup.build_initial_state(
          EvoGit.Agents.Custom,
          "the custom objective",
          build_ctx(repo, custom_agent_id: "   ")
        )
      end

      assert Process.get(:custom_agent_id) == valid_id

      Process.delete(:custom_agent_id)
      refute :custom_agent_id in Process.get_keys()
    end
  end

  # --- Fixtures ---

  # The exact `ctx` key set `EvoGit.Agent.Session.build_state/2` supplies to
  # `Setup.build_initial_state/3` (every `fetch!`ed key must be present). A
  # retry/resume is NOT requested (`restore_agent_state: false`), so no durable
  # store is ever touched.
  defp build_ctx(repo_path, overrides) do
    unique = System.unique_integer([:positive])

    defaults = [
      agent_id: "custom-start-agent-#{unique}",
      depth: 0,
      context_node: %ContextNode{path: "./", repo: repo_path},
      repo_path: repo_path,
      current_commit: "base-sha",
      repo_root: repo_path,
      repo_id: "primary",
      repo_less: false,
      task_id: "custom-start-task-#{unique}",
      parent_id: nil,
      archive: false,
      persistent_state: true,
      restore_agent_state: false,
      foreign_repos: [],
      repo_notes: nil,
      max_turns: 32,
      max_depth: 2,
      max_retries: 3,
      compression_count: 0,
      llm_context_window: 128_000,
      llm_model: "test:model",
      llm_generation_params: [],
      model_spec: nil,
      provider_profile_id: nil,
      model_id: nil,
      model_id_locked: false,
      prompt_cache_key: nil,
      session_mode: :oneshot,
      quality_level: nil,
      custom_agent_id: nil,
      attachments: nil
    ]

    Keyword.merge(defaults, overrides)
  end

  # A private repo dir for the `Setup.build_initial_state/3` node-path check.
  defp workspace!(label) do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "evogit_custom_start_#{label}_#{unique}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  # Saves a real custom-agent definition into the isolated config dir and
  # returns the id `EvoGit.Agents.Custom` resolves from the process dictionary.
  defp save_definition!(overrides) do
    definition =
      Map.merge(%{name: "Test Custom Agent", prompt: "You are a custom test agent."}, overrides)

    assert {:ok, %{id: id}} = EvoGit.CustomAgents.save(definition)
    assert is_binary(id)
    id
  end
end
