defmodule EvoGit.TaskRegistry.ModelSelectionFixtures do
  @moduledoc false

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.TestSupport.ConfigDir

  def install! do
    root = ConfigDir.isolate!("model_selection_persistence")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    suffix = System.unique_integer([:positive])
    token_a = "GENESIS_SELECTION_A_#{suffix}_TOKEN"
    token_b = "GENESIS_SELECTION_B_#{suffix}_TOKEN"
    secret_a = "selection-account-a-secret-#{suffix}"
    secret_b = "selection-account-b-secret-#{suffix}"

    # These deliberately do NOT end in _API_KEY: credentials/0 must not install
    # a ReqLLM-global key as a side effect of reading this private fixture.
    File.write!(Path.join(dir, "credentials.toml"), """
    #{token_a} = "#{secret_a}"
    #{token_b} = "#{secret_b}"
    """)

    File.write!(Path.join(dir, "config.toml"), """
    [tmp]
    mode = "custom"
    path = #{inspect(dir)}

    [llm]
    default_provider_profile = "account-a"

    [[llm.providers]]
    id = "account-a"
    provider = "openai"
    auth_mode = "api_key"
    api_key_env_var = "#{token_a}"
    base_url = "http://127.0.0.1:1/v1"
    default_model = "gpt-5"
    default_reasoning_effort = "low"
    reasoning_efforts = ["low", "high"]
    models = ["gpt-5", "gpt-5-mini"]

    [[llm.providers]]
    id = "account-b"
    provider = "openai"
    auth_mode = "api_key"
    api_key_env_var = "#{token_b}"
    base_url = "http://127.0.0.1:1/v1"
    default_model = "gpt-5-mini"
    default_reasoning_effort = "high"
    reasoning_efforts = ["low", "high"]
    models = ["gpt-5", "gpt-5-mini"]
    """)

    config = Config.resolve()
    {:ok, default} = Schema.resolve_model_spec(config, nil)
    # An invalid explicit choice must fail even though Auto has a valid target.
    unless identity(default) == spec("account-a", "gpt-5", "low") do
      raise "model-selection fixture failed to resolve its valid default"
    end

    %{
      config_dir: root,
      config: config,
      secret_a: secret_a,
      secret_b: secret_b,
      token_a: token_a,
      token_b: token_b
    }
  end

  def spec(account \\ "account-b", model \\ "gpt-5", effort \\ "high") do
    %{
      "provider_profile_id" => account,
      "model" => model,
      "reasoning_effort" => effort
    }
  end

  # resolved.model_spec is a ReqLLM identifier (or custom-endpoint map), NOT
  # the serializable account/model/effort identity to persist in task opts.
  def identity(resolved) do
    %{
      "provider_profile_id" => resolved.provider_profile_id,
      "model" => resolved.model,
      "reasoning_effort" => resolved.reasoning_effort
    }
  end

  def rejection_cases do
    [
      {"unknown account", spec("missing-account"),
       {:provider_profile_not_found, "missing-account"}},
      {"unknown model", spec("account-b", "missing-model"),
       {:model_not_found, "account-b", "missing-model"}},
      {"qualified model string is not an account id", spec("openai:gpt-5"),
       {:provider_profile_not_found, "openai:gpt-5"}},
      {"unsupported effort", spec("account-b", "gpt-5", "medium"),
       {:unsupported_reasoning_effort, "medium", ["low", "high"]}},
      {"malformed effort", spec("account-b", "gpt-5", %{"invalid" => true}),
       {:invalid_reasoning_effort, %{"invalid" => true}}},
      {"empty explicit effort", spec("account-b", "gpt-5", ""), {:invalid_reasoning_effort, ""}},
      {"explicit nil", nil, :invalid_model_spec},
      {"ReqLLM string in place of identity map", "openai:gpt-5", :invalid_model_spec}
    ]
  end
end

defmodule EvoGit.TaskRegistry.ModelSelectionPersistenceTest do
  @moduledoc """
  Store/registry integration for serializable model identity and admission.

  Async-safe: every Store, registry, config path, credential and task id is
  private. The suite-wide ConfigDir seam is bound INSIDE the isolated registry
  via :sys.replace_state/2; no XDG environment, global scheduler, app env or
  shared ETS table is changed. PubSub assertions pin our own task ids.
  Valid persistence fixtures are seeded through Store, never dispatched to an
  LLM. Invalid admission probes must return before creating any wrapper.
  """

  use EvoGit.TaskRegistryCase, async: true

  import Ecto.Query
  import EvoGit.TaskRegistry.ModelSelectionFixtures

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskRegistry.RuntimeOpts

  setup %{registry: registry} do
    fixture = install!()
    bind_config!(registry, fixture.config_dir)
    {:ok, fixture}
  end

  describe "the persisted identity, not the runtime generation profile" do
    test "raw SQLite JSON contains the complete three-field string-key identity" do
      selection = spec()
      task = persist!(model_spec: selection, model_id_locked: true)
      raw = raw_opts(task.id)

      assert raw["model_spec"] == selection

      assert Enum.sort(Map.keys(raw["model_spec"])) ==
               ~w(model provider_profile_id reasoning_effort)

      assert raw["model_id_locked"] == true
      refute Map.has_key?(raw, "model_id")
      assert raw["objective"] == "Keep the chosen account and effort"
      assert Store.get_task(store(), task.id).model_id == nil
    end

    test "Store reload atomizes the outer model_spec key and keeps inner keys strings" do
      selection = spec()
      task = persist!(model_spec: selection)
      loaded = Store.get_task(store(), task.id)

      assert Keyword.fetch(loaded.opts, :model_spec) == {:ok, selection}
      refute List.keymember?(loaded.opts, "model_spec", 0)
    end

    test "registry detail reload retains the full selection" do
      selection = spec()
      task = persist!(model_spec: selection)
      loaded = TaskRegistry.get_task(task.id)

      assert Keyword.fetch(loaded.opts, :model_spec) == {:ok, selection}
      assert loaded.ref == nil
    end

    test "registry roster reload retains each task's complete identity" do
      a = persist!(model_spec: spec("account-a", "gpt-5-mini", "low"))
      b = persist!(model_spec: spec("account-b", "gpt-5", "high"))
      by_id = Map.new(TaskRegistry.list_tasks(), &{&1.id, &1})

      assert Keyword.fetch(by_id[a.id].opts, :model_spec) ==
               {:ok, spec("account-a", "gpt-5-mini", "low")}

      assert Keyword.fetch(by_id[b.id].opts, :model_spec) == {:ok, spec()}
    end

    test "two accounts on the SAME provider, model and endpoint never collapse", fixture do
      {:ok, resolved_a} = Schema.resolve_model_spec(fixture.config, spec("account-a"))
      {:ok, resolved_b} = Schema.resolve_model_spec(fixture.config, spec("account-b"))
      assert resolved_a.provider == resolved_b.provider
      assert resolved_a.model_spec == resolved_b.model_spec
      assert resolved_a.generation_params[:api_key] == fixture.secret_a
      assert resolved_b.generation_params[:api_key] == fixture.secret_b

      a = persist!(model_spec: identity(resolved_a))
      b = persist!(model_spec: identity(resolved_b))
      assert raw_opts(a.id)["model_spec"] == spec("account-a")
      assert raw_opts(b.id)["model_spec"] == spec("account-b")
      refute raw_opts(a.id)["model_spec"] == raw_opts(b.id)["model_spec"]
    end

    test "same account and model with different effort remain distinct identities" do
      low = persist!(model_spec: spec("account-b", "gpt-5", "low"))
      high = persist!(model_spec: spec("account-b", "gpt-5", "high"))

      assert raw_opts(low.id)["model_spec"] == spec("account-b", "gpt-5", "low")
      assert raw_opts(high.id)["model_spec"] == spec("account-b", "gpt-5", "high")
    end

    test "same account with different models retains the non-default model" do
      task = persist!(model_spec: spec("account-b", "gpt-5", "low"))
      assert raw_opts(task.id)["model_spec"] == spec("account-b", "gpt-5", "low")
    end

    test "nil effort is JSON null, not an omitted identity field or invented default" do
      task = persist!(model_spec: spec("account-b", "gpt-5", nil))
      assert raw_opts(task.id)["model_spec"] == spec("account-b", "gpt-5", nil)
      assert Map.has_key?(raw_opts(task.id)["model_spec"], "reasoning_effort")
    end

    test "admission persists only the identity derived from resolved selection", fixture do
      {:ok, resolved} = Schema.resolve_model_spec(fixture.config, spec())
      assert is_map(resolved.model_spec)
      assert resolved.generation_params[:api_key] == fixture.secret_b

      assert {:ok, admitted} =
               RuntimeOpts.admit_model_selection([model_spec: identity(resolved)], fixture.config)

      task = persist!(admitted)
      raw = raw_opts(task.id)

      assert raw["model_spec"] == spec()
      assert raw["model_id_locked"] == true
      assert_secret_free!(raw, fixture)
    end

    test "untrusted extras and generation credentials are projected out BEFORE persistence",
         fixture do
      {:ok, resolved} = Schema.resolve_model_spec(fixture.config, spec())

      dirty =
        spec()
        |> Map.put("generation_params", Map.new(resolved.generation_params))
        |> Map.put("api_key", fixture.secret_b)
        |> Map.put("provider_profile", resolved.provider_profile)
        |> Map.put("unrecognized", "do-not-persist")

      assert {:ok, admitted} =
               RuntimeOpts.admit_model_selection([model_spec: dirty], fixture.config)

      task = persist!(admitted)
      raw = raw_opts(task.id)
      assert_secret_free!(raw, fixture)
      assert raw["model_spec"] == spec()
    end
  end

  describe "registry restart and runtime reuse" do
    test "restart keeps the raw account/model/effort identity unchanged", context do
      task = persist!(model_spec: spec(), model_id_locked: true)
      before_restart = raw_opts(task.id)
      restart_registry!(context)

      assert raw_opts(task.id) == before_restart
      assert TaskRegistry.get_task(task.id).id == task.id
      assert :sys.get_state(context.registry).task_refs == %{}
    end

    test "restart reload exposes atom-keyed model_spec to core consumers", context do
      task = persist!(model_spec: spec(), model_id_locked: true)
      restart_registry!(context)
      loaded = TaskRegistry.get_task(task.id)

      assert Keyword.fetch(loaded.opts, :model_spec) == {:ok, spec()}
      refute List.keymember?(loaded.opts, "model_spec", 0)
    end

    for {type, mode} <- [evolve: "simple", genesis: "new"] do
      test "#{type} runtime builder keeps model_spec after a real Store/registry reload",
           context do
        type = unquote(type)
        mode = unquote(mode)
        task = persist!([model_spec: spec(), model_id_locked: true, mode: mode], type)
        loaded = TaskRegistry.get_task(task.id)
        assert {:ok, admitted} = RuntimeOpts.admit_model_selection(loaded.opts, context.config)
        assert {nil, runtime} = RuntimeOpts.build_common_runtime_opts(admitted, task.id, type)

        assert Keyword.fetch(runtime, :model_spec) == {:ok, spec()}
        assert runtime[:model_id_locked] == true
        refute Keyword.has_key?(runtime, :model_id)
      end
    end

    test "a reloaded selection must not become Auto and resolve the configured default",
         context do
      task = persist!(model_spec: spec())
      loaded = TaskRegistry.get_task(task.id)
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection(loaded.opts, context.config)
      assert Keyword.fetch(admitted, :model_spec) == {:ok, spec()}
      assert {:ok, resolved} = Schema.resolve_model_spec(context.config, admitted[:model_spec])
      assert identity(resolved) == spec()
      refute resolved.provider_profile_id == "account-a"
    end

    test "reloaded non-default effort overrides the account default", context do
      selection = spec("account-b", "gpt-5", "low")
      task = persist!(model_spec: selection)
      loaded = TaskRegistry.get_task(task.id)
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection(loaded.opts, context.config)
      assert {nil, runtime} = RuntimeOpts.build_common_runtime_opts(admitted, task.id, :evolve)
      assert Keyword.fetch(runtime, :model_spec) == {:ok, selection}
      assert {:ok, resolved} = Schema.resolve_model_spec(context.config, runtime[:model_spec])
      assert resolved.reasoning_effort == "low"
      # Identity stays a string; LLM.profile_generation_params/1 converts it to
      # the atom accepted by ReqLLM.Provider.Options' canonical effort schema.
      assert resolved.generation_params[:reasoning_effort] == :low
    end

    for {label, overrides, reason} <- [
          {"model", %{"models" => ["gpt-5-mini"]}, {:model_not_found, "account-b", "gpt-5"}},
          {"effort", %{"reasoning_efforts" => ["low"], "default_reasoning_effort" => "low"},
           {:unsupported_reasoning_effort, "high", ["low"]}}
        ] do
      test "reloaded explicit #{label} removed from inventory is rejected instead of defaulted",
           context do
        task = persist!(model_spec: spec())
        loaded = TaskRegistry.get_task(task.id)

        providers =
          Enum.map(context.config.llm.providers, fn profile ->
            if profile["id"] == "account-b" do
              Map.merge(profile, unquote(Macro.escape(overrides)))
            else
              profile
            end
          end)

        config = put_in(context.config, [:llm, :providers], providers)
        assert {:ok, _valid_default} = Schema.resolve_model_spec(config, nil)

        assert RuntimeOpts.admit_model_selection(loaded.opts, config) ==
                 {:error, unquote(Macro.escape(reason))}
      end
    end

    test "reloaded explicit account removed from config is rejected instead of defaulted",
         context do
      task = persist!(model_spec: spec())
      loaded = TaskRegistry.get_task(task.id)

      config =
        put_in(
          context.config,
          [:llm, :providers],
          Enum.reject(context.config.llm.providers, &(&1["id"] == "account-b"))
        )

      assert {:ok, _valid_default} = Schema.resolve_model_spec(config, nil)

      assert RuntimeOpts.admit_model_selection(loaded.opts, config) ==
               {:error, {:provider_profile_not_found, "account-b"}}
    end
  end

  describe "real registry admission rejects before creation" do
    for {label, selection, reason} <- rejection_cases() do
      test "public start_task rejects #{label}", context do
        selection = unquote(Macro.escape(selection))
        reason = unquote(Macro.escape(reason))
        before_refs = :sys.get_state(context.registry).task_refs
        before_tasks = Store.safe_select_all_tasks(store())

        assert TaskRegistry.start_task(:reflect,
                 objective: "Admission must reject before execution",
                 model_spec: selection,
                 model_id: "account-a"
               ) == {:error, reason}

        assert Store.safe_select_all_tasks(store()) == before_tasks
        assert TaskRegistry.list_tasks() == before_tasks
        assert :sys.get_state(context.registry).task_refs == before_refs
      end

      test "id-pinned handler rejects #{label} with no row, ref or broadcast", context do
        selection = unquote(Macro.escape(selection))
        reason = unquote(Macro.escape(reason))
        assert :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
        id = task_id("reject")
        control = persist!(model_spec: spec("account-a"))
        before_refs = :sys.get_state(context.registry).task_refs
        before_control = raw_opts(control.id)

        assert GenServer.call(
                 context.registry,
                 {:start_task, id, :reflect,
                  [objective: "Must not run", model_spec: selection, model_id: "account-a"]}
               ) ==
                 {:error, reason}

        # Synchronous reply is ordered after any handler broadcast; the second
        # call also flushes the registry before the zero-wait negative assertion.
        assert TaskRegistry.get_task(id) == nil
        assert Store.get_task(store(), id) == nil
        assert Store.get_task_status(store(), id) == nil
        assert :sys.get_state(context.registry).task_refs == before_refs
        assert raw_opts(control.id) == before_control
        refute_receive {:task_updated, ^id, _, _}, 0
        refute_receive {:task_deleted, ^id, _}, 0
      end
    end

    for type <- [:genesis, :evolve, :extract_skills] do
      test "#{type} admission also rejects an unknown explicit account before dispatch",
           context do
        id = task_id("reject_type")
        assert :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
        before_refs = :sys.get_state(context.registry).task_refs

        assert GenServer.call(
                 context.registry,
                 {:start_task, id, unquote(type),
                  [model_spec: spec("missing-account"), model_id: "account-a"]}
               ) ==
                 {:error, {:provider_profile_not_found, "missing-account"}}

        assert TaskRegistry.get_task(id) == nil
        assert Store.get_task_status(store(), id) == nil
        assert :sys.get_state(context.registry).task_refs == before_refs
        refute_receive {:task_updated, ^id, _, _}, 0
      end
    end

    test "invalid legacy account is also rejected before task creation", context do
      id = task_id("legacy_reject")
      assert :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      before_refs = :sys.get_state(context.registry).task_refs

      assert TaskRegistry.start_task(:reflect, model_id: "missing-account") ==
               {:error, {:provider_profile_not_found, "missing-account"}}

      assert GenServer.call(
               context.registry,
               {:start_task, id, :reflect, [model_id: "missing-account"]}
             ) ==
               {:error, {:provider_profile_not_found, "missing-account"}}

      assert TaskRegistry.list_tasks() == []
      assert :sys.get_state(context.registry).task_refs == before_refs
      assert TaskRegistry.get_task(id) == nil
      refute_receive {:task_updated, ^id, _, _}, 0
    end
  end

  defp bind_config!(registry, dir) do
    :sys.replace_state(registry, fn state ->
      Process.put(:evogit_config_dir, dir)
      # Executed in the GenServer: prove the seam works here, not just in the
      # test process. This changes no production state and needs no XDG write.
      assert Config.config_dir() == Path.join(dir, "genesis")
      assert {:ok, resolved} = Schema.resolve_model_spec(Config.resolve(), nil)
      assert identity(resolved) == spec("account-a", "gpt-5", "low")
      state
    end)
  end

  defp restart_registry!(context) do
    assert :ok = stop_supervised(context.registry)

    start_supervised!(
      Supervisor.child_spec(
        {TaskRegistry,
         task_store: context.store, data_dir: context.data_dir, name: context.registry},
        id: context.registry
      )
    )

    bind_config!(context.registry, context.config_dir)
  end

  defp persist!(extra, type \\ :evolve) do
    opts =
      Keyword.merge(
        [
          path: Path.join(Config.config_dir(), "repo"),
          mode: "simple",
          objective: "Keep the chosen account and effort"
        ],
        extra
      )

    task = %TaskInfo{
      id: task_id("persist"),
      type: type,
      status: :completed,
      opts: opts,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: []
    }

    assert :ok = Store.put_task(store(), task)
    task
  end

  defp raw_opts(id) do
    RepoScope.with_repo(Store.__repo_pid__(store()), fn ->
      json = Repo.one!(from(t in TaskRowRaw, where: t.id == ^id, select: t.opts))
      Jason.decode!(json)
    end)
  end

  defp assert_secret_free!(raw, fixture) do
    encoded = Jason.encode!(raw)
    refute encoded =~ fixture.secret_a
    refute encoded =~ fixture.secret_b
    refute encoded =~ fixture.token_a
    refute encoded =~ fixture.token_b
    selection = raw["model_spec"]
    refute Map.has_key?(selection, "generation_params")
    refute Map.has_key?(selection, "provider_profile")
    refute Map.has_key?(selection, "runtime_profile")
    refute Map.has_key?(selection, "api_key")
    refute Map.has_key?(selection, "provider_options")
    refute Map.has_key?(selection, "oauth_file")
  end

  defp task_id(prefix), do: "selection_#{prefix}_#{System.unique_integer([:positive])}"
end

defmodule EvoGit.TaskRegistry.ModelSelectionAdmissionProjectionTest do
  @moduledoc """
  Pure admission projection, default-selector and malformed-input regressions,
  kept outside the Store/registry fixture. Config and credentials are per-process isolated.
  """
  use ExUnit.Case, async: true

  import EvoGit.TaskRegistry.ModelSelectionFixtures
  alias EvoGit.Config.Schema
  alias EvoGit.TaskRegistry.RuntimeOpts

  setup do
    {:ok, install!()}
  end

  test "atom-key input is canonicalized to exactly three string identity keys", context do
    input = %{provider_profile_id: "account-b", model: "gpt-5", reasoning_effort: "high"}

    assert {:ok, resolved} = Schema.resolve_model_spec(context.config, input)
    assert identity(resolved) == spec()

    assert {:ok, admitted} =
             RuntimeOpts.admit_model_selection([model_spec: input], context.config)

    assert admitted[:model_spec] == identity(resolved)
    assert admitted[:model_id_locked] == true
  end

  test "qualified model input is stored as the resolved unqualified identity", context do
    input = spec("account-b", "openai:gpt-5", "high")

    assert {:ok, admitted} =
             RuntimeOpts.admit_model_selection([model_spec: input], context.config)

    assert admitted[:model_spec] == spec()
  end

  test "valid full spec wins over legacy id and forces a boolean lock", context do
    opts = [model_spec: spec(), model_id: "account-a", model_id_locked: false, objective: "keep"]
    assert {:ok, admitted} = RuntimeOpts.admit_model_selection(opts, context.config)
    assert admitted[:model_spec] == spec()
    assert admitted[:model_id_locked] == true
    assert admitted[:objective] == "keep"
    refute Keyword.has_key?(admitted, :model_id)
  end

  test "missing effort is filled from the resolved account default, never omitted", context do
    input = Map.delete(spec("account-b", "gpt-5"), "reasoning_effort")

    assert {:ok, admitted} =
             RuntimeOpts.admit_model_selection([model_spec: input], context.config)

    assert admitted[:model_spec] == spec()
  end

  test "unknown fields are removed instead of becoming persisted runtime data", context do
    input = Map.put(spec(), "unexpected", %{"nested" => ["payload"]})

    assert {:ok, admitted} =
             RuntimeOpts.admit_model_selection([model_spec: input], context.config)

    assert admitted[:model_spec] == spec()
  end

  # Missing/nil account and model fields are selectors for configured defaults,
  # not malformed scheduler identities: admission resolves before projecting.
  for {label, input, expected} <- [
        {"empty map", %{}, {"account-a", "gpt-5", "low"}},
        {"account without model", %{"provider_profile_id" => "account-b"},
         {"account-b", "gpt-5-mini", "high"}},
        {"model without account", %{"model" => "gpt-5"}, {"account-a", "gpt-5", "low"}},
        {"nondefault model without account", %{"model" => "gpt-5-mini"},
         {"account-a", "gpt-5-mini", "low"}},
        {"effort without account", %{"reasoning_effort" => "high"},
         {"account-a", "gpt-5", "high"}},
        {"nil account", %{"provider_profile_id" => nil, "model" => "gpt-5"},
         {"account-a", "gpt-5", "low"}},
        {"nil explicit model", %{"provider_profile_id" => "account-b", "model" => nil},
         {"account-b", "gpt-5-mini", "high"}},
        {"mixed keys", %{"provider_profile_id" => "account-b", model: "gpt-5"},
         {"account-b", "gpt-5", "high"}}
      ] do
    test "selector #{label} becomes a resolved canonical identity", context do
      input = unquote(Macro.escape(input))
      {account, model, effort} = unquote(Macro.escape(expected))
      assert {:ok, resolved} = Schema.resolve_model_spec(context.config, input)
      assert identity(resolved) == spec(account, model, effort)

      assert {:ok, admitted} =
               RuntimeOpts.admit_model_selection(
                 [model_spec: input, model_id: "account-a", model_id_locked: false],
                 context.config
               )

      assert admitted[:model_spec] == identity(resolved)
      assert admitted[:model_id_locked] == true
      assert Enum.sort(Keyword.keys(admitted)) == [:model_id_locked, :model_spec]
      refute Keyword.has_key?(admitted, :model_id)
    end
  end

  for {label, input, reason} <- [
        {"non-string account", %{"provider_profile_id" => 42, "model" => "gpt-5"},
         {:provider_profile_not_found, 42}},
        {"non-string explicit model", %{"provider_profile_id" => "account-b", "model" => []},
         {:model_not_found, "account-b", nil}}
      ] do
    test "invalid identity #{label} returns its specific resolver error", context do
      input = unquote(Macro.escape(input))
      reason = unquote(Macro.escape(reason))
      assert Schema.resolve_model_spec(context.config, input) == {:error, reason}

      assert RuntimeOpts.admit_model_selection(
               [model_spec: input, model_id: "account-a"],
               context.config
             ) == {:error, reason}
    end
  end

  test "Auto strips stale lock and empty legacy id without inventing model_spec", context do
    assert {:ok, [objective: "Auto"]} =
             RuntimeOpts.admit_model_selection(
               [objective: "Auto", model_id: "", model_id_locked: true],
               context.config
             )
  end
end
