defmodule EvoDashWeb.HomeLive.ModelSelectTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.{ChatState, ModelSelect}

  # Exercise the real shared resolver, not a duplicate picker implementation.
  # All task options are inspected as values: no task, scheduler or LLM is run.
  @config %{
    llm: %{
      default_provider_profile: "work-account",
      providers: [
        %{
          id: "first-account",
          provider: "openai",
          models: ["fast-model"]
        },
        %{
          id: "work-account",
          provider: "openai",
          base_url: "https://example.invalid/v1",
          extra: %{account_secret: "server-only"},
          default_model: "reasoned-model",
          models: [
            "fast-model",
            %{
              model: "reasoned-model",
              reasoning_efforts: ["low", "medium", "high"],
              default_reasoning_effort: "medium"
            },
            %{model: "no-default-model", reasoning_efforts: ["high", "low"]}
          ]
        }
      ]
    }
  }

  describe "task_opts/4 canonical reflect-task boundary" do
    test "uninitialized selection uses the configured account, model and effort, even with rules" do
      for enabled <- [false, true] do
        snapshot = snapshot(@config, node(), enabled)

        assert {:ok, opts} = ModelSelect.task_opts(snapshot, selection(nil), scope(), task_opts())

        assert opts == [
                 mode: "reflect",
                 objective: "Explain scheduling",
                 model_spec: spec("reasoned-model", "medium"),
                 model_id_locked: true
               ]
      end
    end

    test "explicit selection survives persistence and never leaks account credentials into opts" do
      selection =
        %{model_spec: spec("reasoned-model", "high"), model_selection_scope: scope()}
        |> ChatState.build()
        |> ChatState.restore()
        |> ChatState.restore_selection(scope())

      assert {:ok, opts} = ModelSelect.task_opts(snapshot(), selection, scope(), task_opts())
      assert opts[:model_spec] == spec("reasoned-model", "high")
      assert opts[:model_id_locked] == true
      refute Keyword.has_key?(opts, :model_id)
      assert Enum.sort(Keyword.keys(opts)) == [:mode, :model_id_locked, :model_spec, :objective]
      assert Enum.all?(opts[:model_spec], fn {k, v} -> is_binary(k) and is_binary(v) end)
    end

    test "Auto removes every old model pin while preserving unrelated options" do
      opts = task_opts() ++ [model_id: "duplicate-old-id", model_spec: %{"model" => "duplicate"}]
      state = %{selection(%{}) | selected_model_id: "must-not-win"}

      assert {:ok, [mode: "reflect", objective: "Explain scheduling"]} =
               ModelSelect.task_opts(snapshot(), state, scope(), opts)
    end

    test "provider-only specs resolve account defaults and inventories choose their first effort" do
      assert {:ok, opts} =
               ModelSelect.task_opts(
                 snapshot(),
                 selection(%{"provider_profile_id" => "work-account"}),
                 scope()
               )

      assert opts[:model_spec] == spec("reasoned-model", "medium")

      assert {:ok, opts} =
               ModelSelect.task_opts(snapshot(), selection(spec("no-default-model")), scope())

      assert opts[:model_spec] == spec("no-default-model", "high")
    end

    test "a model without an effort inventory emits no task-level reasoning override" do
      assert {:ok, opts} =
               ModelSelect.task_opts(snapshot(), selection(spec("fast-model")), scope())

      assert opts[:model_spec] == spec("fast-model")
      refute Map.has_key?(opts[:model_spec], "reasoning_effort")
    end

    test "an explicit spec wins over legacy migration input" do
      state = %{selection(spec("fast-model")) | selected_model_id: "removed-legacy-id"}
      assert {:ok, opts} = ModelSelect.task_opts(snapshot(), state, scope())
      assert opts[:model_spec] == spec("fast-model")
    end

    test "legacy ids resolve as whole account ids, never by splitting their colon segments" do
      id = "legacy:openai:account"
      config = %{llm: %{models: [%{id: id, model: "openai:legacy-model"}]}}

      state =
        %{selected_model_id: id}
        |> ChatState.restore()
        |> ChatState.restore_selection(scope())

      assert {:ok, opts} = ModelSelect.task_opts(snapshot(config), state, scope(), task_opts())
      assert opts[:model_spec] == %{"provider_profile_id" => id, "model" => "legacy-model"}
      assert opts[:model_id_locked] == true
      refute Keyword.has_key?(opts, :model_id)
    end

    test "stale accounts, models, efforts and legacy ids fail rather than launching Auto" do
      for {candidate, reason} <- [
            {%{"provider_profile_id" => "removed-account"},
             {:provider_profile_not_found, "removed-account"}},
            {spec("removed-model"), {:model_not_found, "work-account", "removed-model"}},
            {spec("reasoned-model", "unsupported"),
             {:unsupported_reasoning_effort, "unsupported", ["low", "medium", "high"]}}
          ] do
        assert ModelSelect.task_opts(snapshot(), selection(candidate), scope(), task_opts()) ==
                 {:error, reason}
      end

      state = %{selection(nil) | selected_model_id: "removed-legacy-id"}

      assert ModelSelect.task_opts(snapshot(), state, scope()) ==
               {:error, {:provider_profile_not_found, "removed-legacy-id"}}
    end

    test "raw false is an error, not default or Auto" do
      assert ModelSelect.task_opts(snapshot(), selection(false), scope()) ==
               {:error, :invalid_model_spec}
    end

    test "persisted malformed specs cannot fall back through a normalized nil spec" do
      state =
        %{model_spec: false, model_selection_scope: scope()}
        |> ChatState.build()
        |> ChatState.restore_selection(scope())

      assert ModelSelect.task_opts(snapshot(), state, scope()) == {:error, :invalid_model_spec}
    end

    test "fresh config validates a restored pin instead of trusting an earlier snapshot" do
      state = selection(spec("reasoned-model", "high"))
      assert {:ok, _} = ModelSelect.task_opts(snapshot(), state, scope())

      config = put_in(@config, [:llm, :providers], [hd(@config.llm.providers)])

      assert ModelSelect.task_opts(snapshot(config), state, scope()) ==
               {:error, {:provider_profile_not_found, "work-account"}}
    end
  end

  describe "task_opts/4 snapshot and scope guards" do
    test "a remote snapshot resolves only its own config, even when local account ids coincide" do
      remote_scope = {"server-a", :assistant_remote@host}

      config =
        @config
        |> put_in([:llm, :providers, Access.at(1), :models], ["remote-model"])
        |> put_in([:llm, :providers, Access.at(1), :default_model], "remote-model")

      state = selection(%{"provider_profile_id" => "work-account"}, remote_scope)
      remote = snapshot(config, :assistant_remote@host)

      assert {:ok, opts} = ModelSelect.task_opts(remote, state, remote_scope)
      assert opts[:model_spec] == spec("remote-model")
    end

    test "the snapshot node and full selection scope must match the submission target" do
      remote_scope = {"server-a", :assistant_remote@host}
      state = selection(spec("fast-model"), remote_scope)
      remote = snapshot(@config, :assistant_remote@host)

      for {loaded, saved, target} <- [
            {nil, state, remote_scope},
            {snapshot(), state, remote_scope},
            {remote, state, {"server-b", :assistant_remote@host}},
            {remote, state, {"server-a", :replacement@host}},
            {remote, selection(%{}), remote_scope},
            {%{node: :assistant_remote@host, config: nil}, state, remote_scope},
            {remote, Map.delete(state, :model_selection_error), remote_scope}
          ] do
        assert ModelSelect.task_opts(loaded, saved, target) ==
                 {:error, :model_selection_not_loaded}
      end
    end

    test "pending remote scopes reject even an apparently matching local snapshot and Auto" do
      for id <- ["pending-a", "pending-b", ""] do
        pending_scope = {id, node()}

        assert ModelSelect.task_opts(snapshot(), selection(%{}, pending_scope), pending_scope) ==
                 {:error, :model_selection_not_loaded}
      end
    end

    test "a persisted invalid-spec error stays explicit even when the snapshot is absent" do
      state = %{selection(nil) | model_selection_error: :invalid_model_spec}
      assert ModelSelect.task_opts(nil, state, scope()) == {:error, :invalid_model_spec}
    end
  end

  describe "load/1 node-scoped snapshots" do
    setup do
      EvoDash.Test.ConfigDir.isolate!("assistant_provider_selection")
      config_dir = EvoGit.Config.config_dir()
      File.mkdir_p!(config_dir)

      File.write!(EvoGit.Config.config_path(), """
      [llm]
      default_provider_profile = "assistant-account"

      [[llm.providers]]
      id = "assistant-account"
      provider = "openai"
      base_url = "https://example.invalid/v1"
      models = ["assistant-model"]
      """)

      {:ok, config_dir: config_dir}
    end

    test "nil and the local node return a tagged full-config snapshot, not a legacy tuple" do
      assert {:ok, loaded} = ModelSelect.load(nil)
      assert loaded.node == node()
      assert loaded.model_selection_enabled == false
      assert loaded.config.llm.default_provider_profile == "assistant-account"

      assert loaded.config.llm.providers == [
               %{
                 "id" => "assistant-account",
                 "provider" => "openai",
                 "base_url" => "https://example.invalid/v1",
                 "models" => ["assistant-model"]
               }
             ]

      assert ModelSelect.load(node()) == {:ok, loaded}

      assert {:ok, opts} = ModelSelect.task_opts(loaded, selection(nil), scope())

      assert opts[:model_spec] == %{
               "provider_profile_id" => "assistant-account",
               "model" => "assistant-model"
             }
    end

    test "configured but broken rules still advertise Auto without evaluating a task", %{
      config_dir: dir
    } do
      File.write!(Path.join(dir, "agents.toml"), """
      [model_selection]
      script = "if ("
      """)

      assert {:ok, loaded} = ModelSelect.load(node())
      assert loaded.model_selection_enabled == true
      assert {:ok, []} = ModelSelect.task_opts(loaded, selection(%{}), scope())

      # Rules being enabled must not change nil from configured-default to Auto.
      assert {:ok, opts} = ModelSelect.task_opts(loaded, selection(nil), scope())
      assert opts[:model_spec]["provider_profile_id"] == "assistant-account"
    end

    test "an unreachable node stays an error inside the supervised SafeCall envelope" do
      target = :assistant_selection_unreachable@host
      token = {:model_select_loaded, 17, target}
      EvoDash.SafeCall.start(self(), token, fn -> ModelSelect.load(target) end)

      assert_receive {^token, {:ok, {:error, _reason}}}, 5_000
    end
  end

  defp scope, do: {nil, node()}

  defp selection(spec, scope \\ scope()) do
    %{
      model_spec: spec,
      selected_model_id: nil,
      model_selection_error: nil,
      model_selection_scope: scope
    }
  end

  defp snapshot(config \\ @config, target_node \\ node(), enabled \\ false) do
    %{node: target_node, config: config, model_selection_enabled: enabled}
  end

  defp spec(model, effort \\ nil) do
    spec = %{"provider_profile_id" => "work-account", "model" => model}
    if effort, do: Map.put(spec, "reasoning_effort", effort), else: spec
  end

  defp task_opts do
    [
      mode: "reflect",
      objective: "Explain scheduling",
      model_id: "old-id",
      model_spec: %{"model" => "old-model"},
      model_id_locked: false
    ]
  end
end
