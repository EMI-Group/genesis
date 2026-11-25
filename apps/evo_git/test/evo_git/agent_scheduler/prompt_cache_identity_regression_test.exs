defmodule EvoGit.AgentScheduler.PromptCacheIdentityRegressionTest.ScriptedAgent do
  @moduledoc """
  The role a scripted exchange runs AS: no tools, one-shot, so a tool-free
  engine reply is the ONE completion route and the run ends immediately.
  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring test files, so a helper defined after an
  async module can still be unloaded when its first test runs.
  """
  use EvoGit.Agent

  @doc "Fixed system prompt of the scripted role."
  def system_prompt, do: "You are the prompt-cache identity regression stub agent."

  @doc "No tools: every exchange here is driven by the `:llm_call` seam."
  def available_tools, do: []

  @doc "One-shot: a tool-free reply completes the run."
  def session_mode, do: :oneshot
end

defmodule EvoGit.AgentScheduler.PromptCacheIdentityRegressionTest do
  @moduledoc """
  END-TO-END regression coverage for the per-agent-run prompt-cache identity.

  The unit contract of `EvoGit.Config.Schema.LLM.with_cache_identity/3` and
  `put_cache_identity/3` lives in `test/evo_git/config/schema/llm_cache_identity_test.exs`.
  This module instead pins the PRODUCTION chain that the unit suite cannot see:

      canonical config -> Schema.ProviderProfiles.resolve_selection/2
        -> Dispatch.register_agent (the account provider decides the identity)
        -> the row's llm_generation_params
        -> ToolDispatch.do_turn's request-boundary re-assert
        -> the exact params the LLM call receives
        -> EvoGit.LLM.ChatGPTResponses.build_request/4 (SIWC headers + body)

  It also pins the two degradation shapes: a legacy BARE model string (no
  provider signal anywhere in the data) stays byte-identical and silent, while a
  cache-capable ACCOUNT whose `provider_options` is not a keyword list emits
  exactly ONE self-diagnosing warning naming the agent — and a non-cache
  provider with the same shape stays silent.

  ## Why `async: true` is safe

  The only BEAM-global state touched is the app-booted scheduler ETS pair
  (`:evogit_agent_summary` / `:evogit_sched_meta`), and every test uses a
  PER-TEST UNIQUE agent id (`7_100_000 + System.unique_integer([:positive,
  :monotonic])`), writes PRODUCTION-SHAPED rows and deletes exactly those rows
  in `on_exit`. No test asserts on a table as a whole, and no app-env key,
  `:persistent_term` entry or Logger level is mutated (`capture_log` windows are
  scoped to the unique agent id under test).
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State, as: AgentStateStruct
  alias EvoGit.AgentScheduler.AgentState, as: Row
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State, as: SchedulerState
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec
  alias EvoGit.Config.Schema.ProviderProfiles
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}
  alias EvoGit.LLM.ChatGPTResponses

  # Disjoint from every other suite's id base (the 9_9xx_000 ranges), so a row
  # this module installs can never collide with, or be deleted by, a sibling.
  @id_base 7_100_000
  @objective "Objective: pin the prompt-cache identity chain."
  @system_text "You are the prompt-cache identity regression stub agent."
  @report_text "scripted report text"
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
  @repo "/tmp/prompt_cache_identity_regression/primary"

  setup do
    # Repo-less identity, exactly as the Runner installs it for a `:reflect`
    # agent: no worktree, no git call, no archive row.
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)
    :ok
  end

  defp unique_id, do: @id_base + System.unique_integer([:positive, :monotonic])

  defp unique_task_id(label) do
    "task-#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # ── Config fixtures ─────────────────────────────────────────────────────

  defp openai_config(account_overrides \\ %{}) do
    account =
      Map.merge(
        %{id: "acct", provider: "openai", default_model: "gpt-4o", models: [%{model: "gpt-4o"}]},
        account_overrides
      )

    %{llm: %{default_provider_profile: "acct", providers: [account]}}
  end

  defp codex_config do
    %{
      llm: %{
        default_provider_profile: "acct",
        providers: [
          %{
            id: "acct",
            provider: "openai_codex",
            siwc_account: "work",
            default_model: "gpt-5.6-terra",
            models: [%{model: "gpt-5.6-terra"}]
          }
        ]
      }
    }
  end

  defp deepseek_config(account_overrides) do
    account =
      Map.merge(
        %{
          id: "acct",
          provider: "deepseek",
          default_model: "deepseek-v4-flash",
          models: [%{model: "deepseek-v4-flash"}]
        },
        account_overrides
      )

    %{llm: %{default_provider_profile: "acct", providers: [account]}}
  end

  # ── Registration through the REAL scheduler path ────────────────────────

  defp spec(opts) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: @repo},
      phylo_node: %PhyloGraphNode{repo: @repo, base_commit: "abc123", current_commit: "abc123"},
      agent_module: __MODULE__.ScriptedAgent,
      objective: @objective,
      repo_id: "primary",
      model_spec: Keyword.get(opts, :model_spec),
      model_id: Keyword.get(opts, :model_id),
      opts: Keyword.get(opts, :spec_opts, [])
    }
  end

  defp scheduler_state(config) do
    config
    |> SchedulerState.from_config()
    |> Map.put(:next_agent_id, unique_id())
  end

  defp legacy_scheduler_state(profiles) do
    profiles
    |> SchedulerState.from_model_profiles()
    |> Map.put(:next_agent_id, unique_id())
  end

  # Registers one agent and returns its id, the advanced state and the STORED
  # production-shaped row (the shape every downstream consumer reads).
  defp register!(state, spec, task_id, opts \\ []) do
    id = Keyword.get(opts, :agent_id, state.next_agent_id)
    on_exit(fn -> delete_rows(id) end)

    assert {^id, advanced} =
             Dispatch.register_agent(
               state,
               spec,
               nil,
               nil,
               0,
               task_id,
               1,
               Keyword.take(opts, [
                 :agent_id
               ])
             )

    assert {:ok, row} = SchedStore.get_agent_state(id)
    {id, advanced, row}
  end

  defp delete_rows(id) do
    SchedStore.delete_agent_state(id)
    SchedStore.delete_sched_meta(id)
    :ok
  end

  defp wire(account, model), do: %{"provider_profile_id" => account, "model" => model}

  defp provider_options(row), do: Keyword.fetch!(row.llm_generation_params, :provider_options)

  defp cache_key(row), do: Keyword.get(provider_options(row), :prompt_cache_key)

  # The deliberately NON-atom option key the two degradation tests pass through
  # `provider_options`, so the resulting list is not a keyword list.
  defp opaque_option?(options) when is_list(options) do
    Enum.any?(options, &match?({"genesis_test_opaque_flag", true}, &1))
  end

  defp opaque_option?(_options), do: false

  defp cache_key?(params) do
    case Keyword.fetch(params, :provider_options) do
      {:ok, options} when is_list(options) ->
        Keyword.keyword?(options) and Keyword.has_key?(options, :prompt_cache_key)

      _ ->
        false
    end
  end

  # ── A scripted one-turn run through the REAL agent loop ─────────────────

  # The production-shaped rows a `Exchange.run/2` in a bare process still needs
  # for the completion path (model/archive metadata + the spec's base commit).
  defp install_run_rows(agent_id, llm_model, params) do
    assert :ok =
             SchedStore.put_agent_state(agent_id, %Row{
               context_node: %ContextNode{path: "./", repo: "[system]"},
               parent_id: nil,
               archive: false,
               llm_model: llm_model,
               llm_generation_params: params,
               model_id: "scripted",
               max_turns: 128,
               max_retries: 3,
               max_depth: nil,
               repo_id: "primary",
               llm_context_window: 200_000,
               task_local_id: 1
             })

    assert :ok =
             SchedStore.put_sched_meta(agent_id, %SchedMeta{
               id: agent_id,
               depth: 0,
               task_number: 1,
               spec: %AgentSpec{
                 context_node: %ContextNode{path: "./", repo: "[system]"},
                 phylo_node: nil,
                 agent_module: __MODULE__.ScriptedAgent,
                 objective: @objective
               }
             })

    on_exit(fn -> delete_rows(agent_id) end)
    :ok
  end

  defp run_state(agent_id, llm_model, params, prompt_cache_key) do
    %AgentStateStruct{
      agent_id: agent_id,
      agent_module: __MODULE__.ScriptedAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(@system_text),
          ReqLLM.Context.user(@objective)
        ]),
      objective: @objective,
      repo_less: true,
      max_turns: 128,
      max_retries: 3,
      llm_model: llm_model,
      llm_generation_params: params,
      prompt_cache_key: prompt_cache_key,
      llm_context_window: 200_000
    }
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "prompt-cache-response",
      model: "scripted:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: @usage
    }
  end

  # ONE turn through `Exchange.run/2` (the real loop: turn parsing, the
  # `ToolDispatch.do_turn/6` request boundary, the completion route) in the
  # calling process, with the scripted `:llm_call` seam capturing the EXACT
  # generation params the production call would hand to `ReqLLM.stream_text/3`.
  defp run_one_turn(state) do
    test_pid = self()

    opts = [
      llm_call: fn context, _tools, params, _agent_id, _retries ->
        send(test_pid, {:llm_params, params})
        {:implicit_completion, response(context, @report_text), @report_text}
      end,
      scheduler: fn
        :drain_inputs, _payload, _state -> []
        :cancel_requested?, _payload, _state -> false
        :pause_requested?, _payload, _state -> false
      end,
      checkpoint: fn _state -> :ok end
    ]

    Exchange.run(state, opts)
  end

  # ────────────────────────────────────────────────────────────────────────
  # 1 + 2. Canonical `:openai` account: config -> registration -> one turn
  # ────────────────────────────────────────────────────────────────────────
  describe "canonical :openai account" do
    test "config resolution carries store: false and NO identity, registration freezes one" do
      config = openai_config()

      # The RESOLVER is identity-free: the key is derived from the AGENT RUN,
      # never from config, so two agents of one account get distinct keys.
      assert {:ok, resolved} = ProviderProfiles.resolve_selection(config, nil)
      assert resolved.provider == "openai"
      assert resolved.model_spec == "openai:gpt-4o"

      assert Keyword.fetch!(resolved.generation_params, :provider_options)
             |> Keyword.fetch!(:store) == false

      refute cache_key?(resolved.generation_params)

      task_id = unique_task_id("openai")

      {id, _state, row} =
        register!(scheduler_state(config), spec(model_spec: wire("acct", "gpt-4o")), task_id)

      options = provider_options(row)
      # EXACTLY one `genesis-` prefix: the helper owns the prefix, the scope
      # (task id + scheduler-unique agent id) does not.
      assert Keyword.fetch!(options, :prompt_cache_key) == "genesis-#{task_id}-#{id}"
      # The native-OpenAI default survives the injection.
      assert Keyword.fetch!(options, :store) == false
      # `session_id` is NOT part of the :openai provider schema.
      refute Keyword.has_key?(options, :session_id)
      assert row.llm_model == "openai:gpt-4o"
    end

    test "the EXACT params handed to the LLM call carry the registered key" do
      task_id = unique_task_id("end-to-end")

      {id, _state, row} =
        register!(
          scheduler_state(openai_config()),
          spec(model_spec: wire("acct", "gpt-4o")),
          task_id
        )

      registered_key = cache_key(row)
      assert registered_key == "genesis-#{task_id}-#{id}"

      # Production projection (`EvoGit.Agent.Session` derives the state field
      # this way from the SAME row) plus the REAL turn loop.
      state = run_state(id, row.llm_model, row.llm_generation_params, registered_key)
      assert {:finish, _final, %Result{result: @report_text}} = run_one_turn(state)

      assert_receive {:llm_params, params}
      options = Keyword.fetch!(params, :provider_options)
      assert Keyword.fetch!(options, :prompt_cache_key) == registered_key
      assert Keyword.fetch!(options, :store) == false
      # Idempotence: the boundary re-assert never duplicates the pair.
      assert Keyword.get_values(options, :prompt_cache_key) == [registered_key]
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 3. SIWC / `:openai_codex`: identity on the wire (headers + body)
  # ────────────────────────────────────────────────────────────────────────
  describe "SIWC :openai_codex account" do
    test "registration appends BOTH prompt_cache_key and session_id from the account provider" do
      task_id = unique_task_id("codex")

      {id, _state, row} =
        register!(
          scheduler_state(codex_config()),
          spec(model_spec: wire("acct", "gpt-5.6-terra")),
          task_id
        )

      options = provider_options(row)
      key = "genesis-#{task_id}-#{id}"
      assert Keyword.fetch!(options, :prompt_cache_key) == key
      assert Keyword.fetch!(options, :session_id) == key
      # The registration alias is untouched (it names the credential store).
      assert Keyword.fetch!(options, :siwc_account) == "work"
      assert row.llm_model == "openai_codex:gpt-5.6-terra"
    end

    test "the ChatGPT subscription request carries the identity as a header AND in the body" do
      task_id = unique_task_id("codex-wire")

      {id, _state, row} =
        register!(
          scheduler_state(codex_config()),
          spec(model_spec: wire("acct", "gpt-5.6-terra")),
          task_id
        )

      key = cache_key(row)
      assert key == "genesis-#{task_id}-#{id}"

      {:ok, request} = build_subscription_request(row.llm_generation_params)
      body = Jason.decode!(request.body)
      header_names = Enum.map(request.headers, fn {name, _value} -> name end)

      # ONE identity, two carriers: the body cache key and the session header.
      assert {"session-id", key} in request.headers
      assert body["prompt_cache_key"] == key
      assert body["store"] == false
      # Genesis-only / legacy aliases never leak into the Responses body.
      refute Map.has_key?(body, "siwc_account")
      refute Map.has_key?(body, "session_id")
      # No thread identity was supplied, so no thread header is invented.
      refute "thread-id" in header_names
      refute "x-client-request-id" in header_names
    end

    test "without an identity the request emits no session/thread header and no body cache key" do
      {:ok, request} = build_subscription_request([])
      body = Jason.decode!(request.body)
      header_names = Enum.map(request.headers, fn {name, _value} -> name end)

      refute "session-id" in header_names
      refute "thread-id" in header_names
      refute "x-client-request-id" in header_names
      refute Map.has_key?(body, "prompt_cache_key")
      # The stateless Responses envelope is unconditional.
      assert body["store"] == false
    end

    test "a supplied thread identity emits both thread headers and the session-id fallback" do
      {:ok, request} =
        build_subscription_request(
          provider_options: [prompt_cache_key: "genesis-threaded", thread_id: "th-1"]
        )

      body = Jason.decode!(request.body)
      # The session header falls back to the cache key when no session_id exists.
      assert {"session-id", "genesis-threaded"} in request.headers
      assert {"thread-id", "th-1"} in request.headers
      assert {"x-client-request-id", "th-1"} in request.headers
      assert body["prompt_cache_key"] == "genesis-threaded"
    end

    defp build_subscription_request(params) do
      model = %LLMDB.Model{provider: :openai_codex, id: "gpt-5.6-terra"}

      context =
        ReqLLM.Context.new([ReqLLM.Context.system(@system_text), ReqLLM.Context.user(@objective)])

      ChatGPTResponses.build_request(model, context, params, "example-token")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 4. Resume/retry stability + the request-boundary re-assert
  # ────────────────────────────────────────────────────────────────────────
  describe "resume and the request boundary" do
    test "re-registering the SAME task and agent id yields the SAME key (no rotation)" do
      task_id = unique_task_id("stable")
      config = openai_config()
      state = scheduler_state(config)
      spec = spec(model_spec: wire("acct", "gpt-4o"))

      {id, advanced, first_row} = register!(state, spec, task_id)
      assert cache_key(first_row) == "genesis-#{task_id}-#{id}"

      # A BEAM restart/durable-restore re-registers the SAME logical agent: the
      # scheduler rows are gone, the persisted agent id is adopted.
      delete_rows(id)
      {^id, _advanced, restored_row} = register!(advanced, spec, task_id, agent_id: id)

      assert cache_key(restored_row) == cache_key(first_row)
    end

    test "the boundary RESTORES a frozen identity whose params were rebuilt without it" do
      agent_id = unique_id()
      key = "genesis-restored-#{agent_id}"
      params = [provider_options: [store: false]]
      install_run_rows(agent_id, "openai:gpt-4o", params)

      state = run_state(agent_id, "openai:gpt-4o", params, key)
      assert {:finish, _final, %Result{}} = run_one_turn(state)

      assert_receive {:llm_params, seen}
      options = Keyword.fetch!(seen, :provider_options)
      assert Keyword.fetch!(options, :prompt_cache_key) == key
      assert Keyword.fetch!(options, :store) == false
    end

    test "the boundary is INERT for a nil key, a non-cache provider and an explicit user key" do
      # (a) nil key — nothing to re-assert.
      nil_id = unique_id()
      nil_params = [provider_options: [store: false]]
      install_run_rows(nil_id, "openai:gpt-4o", nil_params)

      assert {:finish, _, %Result{}} =
               run_one_turn(run_state(nil_id, "openai:gpt-4o", nil_params, nil))

      assert_receive {:llm_params, nil_seen}
      assert nil_seen == nil_params

      # (b) a non-cache provider is byte-identical (an undeclared
      # `provider_options` key is a hard request-time error there).
      zai_id = unique_id()
      zai_params = [provider_options: [thinking: %{type: "enabled"}]]
      install_run_rows(zai_id, "zai:glm-5.1", zai_params)

      assert {:finish, _, %Result{}} =
               run_one_turn(run_state(zai_id, "zai:glm-5.1", zai_params, "genesis-zai"))

      assert_receive {:llm_params, zai_seen}
      assert zai_seen == zai_params

      # (c) an explicit user key wins and is never duplicated; the surrounding
      # provider options survive the (no-op) injection.
      user_id = unique_id()

      user_params = [
        provider_options: [
          prompt_cache_key: "user-key",
          auth_mode: :oauth,
          oauth_file: "/tmp/auth.json"
        ]
      ]

      install_run_rows(user_id, "openai:gpt-4o", user_params)

      assert {:finish, _, %Result{}} =
               run_one_turn(
                 run_state(user_id, "openai:gpt-4o", user_params, "genesis-derived-other")
               )

      assert_receive {:llm_params, user_seen}
      user_options = Keyword.fetch!(user_seen, :provider_options)
      assert Keyword.get_values(user_options, :prompt_cache_key) == ["user-key"]
      assert Keyword.fetch!(user_options, :auth_mode) == :oauth
      assert Keyword.fetch!(user_options, :oauth_file) == "/tmp/auth.json"
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 5. Legacy selections and the honest degradation shapes
  # ────────────────────────────────────────────────────────────────────────
  describe "legacy selections" do
    test "a legacy QUALIFIED profile gets the identity from its model's provider" do
      task_id = unique_task_id("legacy-qualified")
      profiles = [%{id: "q", model: "openai:gpt-5.1", concurrency: 3}]
      state = legacy_scheduler_state(profiles)
      spec = spec(model_id: "q", spec_opts: [model_id_locked: true])

      {id, _state, row} = register!(state, spec, task_id)
      assert cache_key(row) == "genesis-#{task_id}-#{id}"
    end

    test "a legacy BARE model string carries no provider signal: byte-identical and SILENT" do
      task_id = unique_task_id("legacy-bare")
      profiles = [%{id: "b", model: "gpt-5.1", concurrency: 3}]
      state = legacy_scheduler_state(profiles)
      spec = spec(model_id: "b", spec_opts: [model_id_locked: true])
      expected = EvoGit.Config.Schema.llm_generation_params(%{id: "b", model: "gpt-5.1"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {id, _state, row} = register!(state, spec, task_id)
          send(self(), {:bare_registration, id, row})
        end)

      assert_received {:bare_registration, id, row}
      assert row.llm_model == "gpt-5.1"
      # The data carries NO provider, so no identity is invented and the params
      # are exactly the profile's own list.
      assert row.llm_generation_params == expected
      refute cache_key?(row.llm_generation_params)
      # Nothing is announced: an unknown vendor is the CORRECT outcome, not a skip.
      refute log =~ "no prompt cache identity attached for agent #{id}"
    end

    test "a cache-capable account with a non-keyword provider_options warns exactly ONCE" do
      # A user `provider_options` MAP whose keys are not existing atoms becomes a
      # NON-keyword option list — the one shape `put_cache_identity/3` refuses to
      # guess at, which is exactly when the operator must be told.
      config = openai_config(%{provider_options: %{"genesis_test_opaque_flag" => true}})
      task_id = unique_task_id("warn")
      spec = spec(model_spec: wire("acct", "gpt-4o"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {id, _state, row} = register!(scheduler_state(config), spec, task_id)
          send(self(), {:warn_registration, id, row})
        end)

      assert_received {:warn_registration, id, row}
      # The registration really produced the NON-keyword shape this test is
      # about (otherwise the warning assertion below would be vacuous).
      options = Keyword.fetch!(row.llm_generation_params, :provider_options)
      refute Keyword.keyword?(options)
      assert opaque_option?(options)
      refute cache_key?(row.llm_generation_params)

      marker = "no prompt cache identity attached for agent #{id}"
      # EXACTLY one line for THIS agent (the window is shared, so scope by id).
      assert length(String.split(log, marker)) == 2
      assert log =~ "account provider :openai"
      assert log =~ "is cache-capable but provider_options is not a keyword list"
    end

    test "a non-cache provider with the same non-keyword shape stays SILENT" do
      config = deepseek_config(%{provider_options: %{"genesis_test_opaque_flag" => true}})
      task_id = unique_task_id("silent")
      spec = spec(model_spec: wire("acct", "deepseek-v4-flash"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {id, _state, row} = register!(scheduler_state(config), spec, task_id)
          send(self(), {:deepseek_registration, id, row})
        end)

      assert_received {:deepseek_registration, id, row}
      # Same non-keyword shape as the warning case — only the provider differs.
      options = Keyword.fetch!(row.llm_generation_params, :provider_options)
      refute Keyword.keyword?(options)
      assert opaque_option?(options)
      refute cache_key?(row.llm_generation_params)
      refute log =~ "no prompt cache identity attached for agent #{id}"
      refute log =~ "account provider :deepseek"
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 6. Explicit user configuration wins on BOTH paths
  # ────────────────────────────────────────────────────────────────────────
  describe "explicit user configuration wins" do
    test "an account-level prompt_cache_key is preserved by registration and the boundary" do
      config = openai_config(%{provider_options: %{prompt_cache_key: "user-key"}})
      task_id = unique_task_id("user-key")

      {id, _state, row} =
        register!(scheduler_state(config), spec(model_spec: wire("acct", "gpt-4o")), task_id)

      options = provider_options(row)
      assert Keyword.get_values(options, :prompt_cache_key) == ["user-key"]
      # An account that SETS `provider_options` replaces the provider's default
      # option list, so the native-OpenAI `store: false` default is absent —
      # this is why `store: false` is only asserted for an account that leaves
      # `provider_options` unset.
      refute Keyword.has_key?(options, :store)

      # The request boundary re-asserts a DIFFERENT frozen key: the explicit
      # user value still wins and is never duplicated.
      state = run_state(id, row.llm_model, row.llm_generation_params, "genesis-derived-other")
      assert {:finish, _final, %Result{}} = run_one_turn(state)

      assert_receive {:llm_params, seen}
      seen_options = Keyword.fetch!(seen, :provider_options)
      assert Keyword.get_values(seen_options, :prompt_cache_key) == ["user-key"]
      assert seen_options == options
    end
  end
end
