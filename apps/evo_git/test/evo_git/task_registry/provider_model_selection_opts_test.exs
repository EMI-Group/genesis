defmodule EvoGit.TaskRegistry.ProviderModelSelectionOptsTest do
  @moduledoc """
  Task-admission and runtime-option contracts for provider-account selections.

  All configuration is passed as a snapshot; no scheduler, Store, credentials,
  environment variables or application-env seams are mutated. The builder's
  ensure_all_started/1 is safe against the already-running test application.
  Explicit task selectors accept the schema's partial and atom/mixed-key maps;
  admission must resolve them to the scheduler's full string-keyed identity,
  never a ReqLLM model identifier or credential-bearing runtime profile.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema
  alias EvoGit.TaskRegistry.RuntimeOpts

  @secret "synthetic-provider-options-secret-never-persist"

  describe "admit_model_selection/2 explicit account/model/effort identity" do
    test "keeps two accounts for the same provider and model distinct" do
      for account <- ["personal", "team"] do
        spec = selection(account, "reasoner", "high")
        assert {:ok, admitted} = admit(model_spec: spec)
        assert Keyword.fetch!(admitted, :model_spec) == spec
        assert Keyword.fetch!(admitted, :model_id_locked) == true
        refute Keyword.has_key?(admitted, :model_id)
      end
    end

    test "selects a nondefault account, model and effort without substituting defaults" do
      spec = selection("personal", "reasoner", "high")
      assert {:ok, resolved} = Schema.resolve_model_spec(config(), spec)
      assert resolved.provider_profile_id == "personal"
      assert resolved.model == "reasoner"
      assert resolved.reasoning_effort == "high"

      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
    end

    test "persists the resolved unqualified model, not the accepted qualified spelling" do
      spec = selection("team", "openai:reasoner", "high")
      assert {:ok, resolved} = Schema.resolve_model_spec(config(), spec)
      assert resolved.model == "reasoner"
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
    end

    test "materializes a model's default effort when the explicit identity omits effort" do
      spec = selection("team", "reasoner")
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == selection("team", "reasoner", "medium")
    end

    test "materializes the provider effort when the selected model has no override" do
      assert {:ok, admitted} = admit(model_spec: selection("personal", "plain"))
      assert Keyword.fetch!(admitted, :model_spec) == selection("personal", "plain", "low")
    end

    test "an explicit nil effort resolves to the default, not a persisted nil placeholder" do
      spec = Map.put(selection("team", "reasoner"), "reasoning_effort", nil)
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == selection("team", "reasoner", "medium")
    end

    test "normalizes an atom effort to the schema's resolved string effort" do
      spec = Map.put(selection("team", "reasoner"), "reasoning_effort", :high)
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == selection("team", "reasoner", "high")
    end

    test "omits effort entirely when neither account nor model has an effort default" do
      snapshot = put_in(config(), [:llm, :providers], [plain_account()])
      spec = selection("plain-account", "plain")
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == spec
      refute Map.has_key?(Keyword.fetch!(admitted, :model_spec), "reasoning_effort")
    end

    test "drops an explicit nil effort if resolution has no effort default" do
      snapshot = put_in(config(), [:llm, :providers], [plain_account()])
      spec = Map.put(selection("plain-account", "plain"), "reasoning_effort", nil)
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == selection("plain-account", "plain")
    end

    test "an empty effort inventory does not prohibit an explicitly selected effort" do
      snapshot = put_in(config(), [:llm, :providers], [plain_account()])
      spec = selection("plain-account", "plain", "high")
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == spec
    end

    test "accepts a string-keyed configuration snapshot without changing the wire identity" do
      snapshot = config() |> Jason.encode!() |> Jason.decode!()
      spec = selection("personal", "reasoner", "high")
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == spec
    end
  end

  describe "clean persisted projection, not opaque resolved runtime data" do
    test "projects only identity fields even when the caller embeds credentials and runtime data" do
      spec =
        selection("team", "reasoner", "high")
        |> Map.merge(%{
          "api_key" => @secret,
          "generation_params" => %{"api_key" => @secret},
          "provider_options" => %{"api_key" => @secret},
          "provider_profile" => %{"oauth_file" => "/private/account/auth.json"},
          "runtime_profile" => %{"model" => "wrong:model"},
          "base_url" => "https://private.invalid/v1",
          "context_window" => 1,
          "concurrency" => 999,
          "unexpected" => "must not cross admission"
        })

      assert {:ok, resolved} = Schema.resolve_model_spec(config(), spec)
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
      refute Jason.encode!(Keyword.fetch!(admitted, :model_spec)) =~ @secret
    end

    test "does not copy generation_params containing provider-option secrets into task opts" do
      snapshot =
        update_in(config(), [:llm, :providers], fn [personal, team] ->
          [personal, Map.put(team, :provider_options, %{api_key: @secret})]
        end)

      spec = selection("team", "reasoner", "high")
      assert {:ok, resolved} = Schema.resolve_model_spec(snapshot, spec)
      assert inspect(resolved.generation_params) =~ @secret
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
      refute inspect(admitted) =~ @secret
      assert Enum.sort(Keyword.keys(admitted)) == [:model_id_locked, :model_spec]
    end

    test "does not persist the schema's qualified ReqLLM model_spec string as a task map" do
      spec = selection("personal", "reasoner", "high")
      assert {:ok, resolved} = Schema.resolve_model_spec(config(), spec)
      assert resolved.model_spec == "openai:reasoner"
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
      refute Keyword.fetch!(admitted, :model_spec) == resolved.model_spec
    end

    test "does not confuse an endpoint-bearing ReqLLM map with the task identity" do
      snapshot =
        update_in(config(), [:llm, :providers], fn [personal, team] ->
          [personal, Map.put(team, :base_url, "https://account-endpoint.invalid/v1")]
        end)

      spec = selection("team", "reasoner", "high")
      assert {:ok, resolved} = Schema.resolve_model_spec(snapshot, spec)
      assert %{provider: :openai, id: "reasoner", base_url: endpoint} = resolved.model_spec
      assert endpoint == "https://account-endpoint.invalid/v1"
      assert {:ok, admitted} = RuntimeOpts.admit_model_selection([model_spec: spec], snapshot)
      assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
      refute Map.has_key?(Keyword.fetch!(admitted, :model_spec), :base_url)
      refute Map.has_key?(Keyword.fetch!(admitted, :model_spec), "base_url")
    end

    test "canonical admission is idempotent and survives a JSON map round trip" do
      opts = [objective: "keep me", model_spec: selection("team", "reasoner", "high")]
      assert {:ok, first} = admit(opts)
      assert {:ok, ^first} = admit(first)
      wire = first |> Keyword.fetch!(:model_spec) |> Jason.encode!() |> Jason.decode!()
      assert {:ok, second} = admit(Keyword.put(first, :model_spec, wire))
      assert second == first
      assert Enum.all?(Map.keys(wire), &is_binary/1)
    end

    test "preserves unrelated caller options while sanitizing the selection" do
      unrelated = [
        path: "/fixture/repo",
        mode: "custom",
        objective: "repair the parser",
        agent: "reviewer",
        archive: true,
        foreign_repos: [%{"id" => "reference", "path" => "/fixture/reference"}],
        resume_from: "previous-task",
        attachments: []
      ]

      opts =
        unrelated ++ [model_spec: selection("team", "reasoner", "high"), model_id: "personal"]

      assert {:ok, admitted} = admit(opts)
      assert Keyword.drop(admitted, [:model_spec, :model_id_locked]) == unrelated
      refute Keyword.has_key?(admitted, :model_id)
    end
  end

  describe "competing selections and lock semantics" do
    for lock <- [nil, false, true, "truthy"] do
      test "explicit model_spec overrides legacy model_id with lock #{inspect(lock)}" do
        spec = selection("personal", "reasoner", "high")
        opts = [model_spec: spec, model_id: "team", model_id_locked: unquote(lock)]
        assert {:ok, admitted} = admit(opts)
        assert Keyword.fetch!(admitted, :model_spec) == spec
        assert Keyword.fetch!(admitted, :model_id_locked) == true
        refute Keyword.has_key?(admitted, :model_id)
      end
    end

    test "valid explicit spec does not validate or fall back to a competing unknown legacy id" do
      spec = selection("personal", "reasoner", "high")
      assert {:ok, admitted} = admit(model_spec: spec, model_id: "removed-account")
      assert Keyword.fetch!(admitted, :model_spec) == spec
      refute Keyword.has_key?(admitted, :model_id)
    end

    test "legacy account ids remain legacy ids and do not gain an implicit lock" do
      assert {:ok, admitted} = admit(model_id: "personal", objective: "legacy")
      assert admitted[:model_id] == "personal"
      assert admitted[:objective] == "legacy"
      refute Keyword.has_key?(admitted, :model_spec)
      refute Keyword.has_key?(admitted, :model_id_locked)
    end

    for lock <- [nil, false] do
      test "legacy selection drops falsey lock #{inspect(lock)}" do
        assert {:ok, admitted} = admit(model_id: "team", model_id_locked: unquote(lock))
        assert admitted == [model_id: "team"]
      end
    end

    for lock <- [true, "locked", 0] do
      test "legacy selection normalizes truthy lock #{inspect(lock)} to true" do
        assert {:ok, admitted} = admit(model_id: "team", model_id_locked: unquote(lock))
        assert admitted[:model_id] == "team"
        assert admitted[:model_id_locked] == true
        refute Keyword.has_key?(admitted, :model_spec)
      end
    end

    for legacy <- [:absent, nil, ""] do
      test "Auto #{inspect(legacy)} removes selection keys and a stale lock" do
        opts = [objective: "auto task", model_id_locked: true]

        opts =
          if unquote(legacy) == :absent,
            do: opts,
            else: Keyword.put(opts, :model_id, unquote(legacy))

        assert {:ok, admitted} = admit(opts)
        assert admitted == [objective: "auto task"]
      end
    end

    test "Auto is not frozen to the currently configured default account or model" do
      assert {:ok, resolved} = Schema.resolve_model_spec(config(), nil)
      assert identity(resolved) == selection("team", "reasoner", "medium")
      assert {:ok, []} = admit([])
      assert {:ok, []} = RuntimeOpts.admit_model_selection([], %{llm: %{providers: []}})
    end

    test "legacy account resolution honors its configured non-first default model" do
      assert {:ok, resolved} = Schema.resolve_model_spec(config(), "team")
      assert identity(resolved) == selection("team", "reasoner", "medium")
      assert {:ok, admitted} = admit(model_id: "team", model_id_locked: true)
      assert admitted[:model_id] == "team"
      refute Keyword.has_key?(admitted, :model_spec)
    end

    test "explicit model identity overrides both configured account and account model defaults" do
      spec = selection("personal", "reasoner", "high")
      assert {:ok, admitted} = admit(model_spec: spec)
      assert Keyword.fetch!(admitted, :model_spec) == spec
    end
  end

  describe "permissive selectors become canonical identities before scheduler dispatch" do
    # ProviderProfiles defaults missing/nil/false account and model fields and
    # normalizes atom/mixed keys; strict scheduler identities are the OUTPUT.
    for {spec, expected} <- [
          {%{}, {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => "team"}, {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => "personal"}, {"personal", "plain", "low"}},
          {%{"model" => "reasoner"}, {"team", "reasoner", "medium"}},
          {%{"model" => "plain"}, {"team", "plain", "low"}},
          {%{"reasoning_effort" => "high"}, {"team", "reasoner", "high"}},
          {%{"provider_profile_id" => nil, "model" => "reasoner"},
           {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => false, "model" => "reasoner"},
           {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => "team", "model" => nil}, {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => "team", "model" => false}, {"team", "reasoner", "medium"}},
          {%{provider_profile_id: "team", model: "reasoner"}, {"team", "reasoner", "medium"}},
          {%{"provider_profile_id" => "team", model: "reasoner"}, {"team", "reasoner", "medium"}}
        ] do
      test "canonicalizes selector #{inspect(spec)} using resolved defaults, not a competing legacy id" do
        spec = unquote(Macro.escape(spec))
        {account, model, effort} = unquote(Macro.escape(expected))
        assert {:ok, resolved} = Schema.resolve_model_spec(config(), spec)
        assert identity(resolved) == selection(account, model, effort)

        assert {:ok, admitted} =
                 admit(model_spec: spec, model_id: "personal", model_id_locked: false)

        assert Keyword.fetch!(admitted, :model_spec) == identity(resolved)
        assert Keyword.fetch!(admitted, :model_id_locked) == true
        refute Keyword.has_key?(admitted, :model_id)
        assert Enum.sort(Keyword.keys(admitted)) == [:model_id_locked, :model_spec]
      end
    end
  end

  describe "invalid explicit selections never fall back to defaults or legacy ids" do
    for value <- [
          nil,
          "",
          "team",
          false,
          123,
          [],
          [provider_profile_id: "team", model: "reasoner"]
        ] do
      test "rejects non-map model_spec #{inspect(value)} even with a valid locked legacy id" do
        assert {:error, :invalid_model_spec} =
                 admit(
                   model_spec: unquote(Macro.escape(value)),
                   model_id: "team",
                   model_id_locked: true
                 )
      end
    end

    # Invalid field values use the resolver's account/model-specific errors,
    # not the top-level non-map :invalid_model_spec error.
    for {field, value, reason} <- [
          {"provider_profile_id", "", {:provider_profile_not_found, ""}},
          {"provider_profile_id", "   ", {:provider_profile_not_found, "   "}},
          {"provider_profile_id", 123, {:provider_profile_not_found, 123}},
          {"model", "", {:model_not_found, "team", nil}},
          {"model", "   ", {:model_not_found, "team", "   "}},
          {"model", 123, {:model_not_found, "team", nil}}
        ] do
      test "rejects invalid identity field #{field}=#{inspect(value)}" do
        spec = Map.put(selection("team", "reasoner"), unquote(field), unquote(value))
        reason = unquote(Macro.escape(reason))
        assert Schema.resolve_model_spec(config(), spec) == {:error, reason}
        assert admit(model_spec: spec, model_id: "personal") == {:error, reason}
      end
    end

    test "unknown explicit account returns its error, not a successful configured default" do
      spec = selection("deleted-account", "reasoner", "high")

      assert {:error, {:provider_profile_not_found, "deleted-account"}} =
               admit(model_spec: spec, model_id: "team")
    end

    test "unknown explicit model returns its account-specific error, not its default model" do
      spec = selection("personal", "deleted-model", "high")

      assert {:error, {:model_not_found, "personal", "deleted-model"}} =
               admit(model_spec: spec, model_id: "team")
    end

    test "a model that exists only on another account is not borrowed from that account" do
      snapshot =
        update_in(config(), [:llm, :providers], fn [personal, team] ->
          [Map.put(personal, :models, ["plain"]), team]
        end)

      assert {:error, {:model_not_found, "personal", "reasoner"}} =
               RuntimeOpts.admit_model_selection(
                 [model_spec: selection("personal", "reasoner", "high"), model_id: "team"],
                 snapshot
               )
    end

    test "an explicit unsupported effort is not replaced with the model's default" do
      assert {:error, {:unsupported_reasoning_effort, "low", ["medium", "high"]}} =
               admit(model_spec: selection("team", "reasoner", "low"), model_id: "personal")
    end

    for effort <- ["", 42, [], %{}] do
      test "rejects malformed explicit effort #{inspect(effort)} rather than using a default" do
        effort = unquote(Macro.escape(effort))

        assert {:error, {:invalid_reasoning_effort, ^effort}} =
                 admit(
                   model_spec: Map.put(selection("team", "reasoner"), "reasoning_effort", effort)
                 )
      end
    end

    test "unknown legacy account id also fails admission instead of silently selecting the default" do
      assert {:error, {:provider_profile_not_found, "deleted-account"}} =
               admit(model_id: "deleted-account", model_id_locked: true)
    end

    test "a whitespace legacy id is an explicit invalid selection, not Auto" do
      assert {:error, {:provider_profile_not_found, "   "}} = admit(model_id: "   ")
    end

    test "an invalid legacy account default model cannot silently become its first model" do
      snapshot =
        update_in(config(), [:llm, :providers], fn [personal, team] ->
          [personal, Map.put(team, :default_model, "removed-default")]
        end)

      assert {:error, {:model_not_found, "team", "removed-default"}} =
               RuntimeOpts.admit_model_selection([model_id: "team"], snapshot)
    end
  end

  describe "execution-time readmission against a changed snapshot" do
    test "rejects a removed account even when the configured default still resolves" do
      assert {:ok, admitted} = admit(model_spec: selection("personal", "reasoner", "high"))

      snapshot =
        update_in(config(), [:llm, :providers], &Enum.reject(&1, fn p -> p.id == "personal" end))

      assert {:error, {:provider_profile_not_found, "personal"}} =
               RuntimeOpts.admit_model_selection(admitted, snapshot)
    end

    test "rejects a removed selected model rather than advancing to the account default" do
      assert {:ok, admitted} = admit(model_spec: selection("personal", "reasoner", "high"))

      snapshot =
        update_in(config(), [:llm, :providers], fn [personal, team] ->
          [Map.put(personal, :models, ["plain"]), team]
        end)

      assert {:error, {:model_not_found, "personal", "reasoner"}} =
               RuntimeOpts.admit_model_selection(admitted, snapshot)
    end

    test "rejects an effort removed from the selected model's inventory" do
      assert {:ok, admitted} = admit(model_spec: selection("team", "reasoner", "high"))

      snapshot =
        update_in(
          config(),
          [:llm, :providers, Access.at(1), :models, Access.at(1), :reasoning_efforts],
          fn _ -> ["medium"] end
        )

      assert {:error, {:unsupported_reasoning_effort, "high", ["medium"]}} =
               RuntimeOpts.admit_model_selection(admitted, snapshot)
    end

    test "a resolved default effort stays pinned if account defaults later change" do
      assert {:ok, admitted} = admit(model_spec: selection("personal", "plain"))

      snapshot =
        update_in(config(), [:llm, :providers, Access.at(0), :default_reasoning_effort], fn _ ->
          "high"
        end)

      assert {:ok, readmitted} = RuntimeOpts.admit_model_selection(admitted, snapshot)
      assert Keyword.fetch!(readmitted, :model_spec) == selection("personal", "plain", "low")
    end
  end

  describe "build_common_runtime_opts/3 forwards admitted selection and lock" do
    for {type, mode, expected_mode} <- [
          {:evolve, "simple", :simple},
          {:evolve, "custom", :custom},
          {:genesis, "new", :new},
          {:genesis, "existing", :existing}
        ] do
      test "forwards explicit identity through #{type}/#{mode} without legacy selection leakage" do
        spec = selection("personal", "reasoner", "high")

        opts = [
          path: "/fixture/repo",
          mode: unquote(mode),
          agent: "reviewer",
          model_spec: spec,
          model_id: "team",
          model_id_locked: false
        ]

        assert {:ok, admitted} = admit(opts)

        assert {nil, runtime} =
                 RuntimeOpts.build_common_runtime_opts(admitted, "task-provider", unquote(type))

        assert runtime[:repo_path] == "/fixture/repo"
        assert runtime[:mode] == unquote(expected_mode)
        assert runtime[:task_id] == "task-provider"
        assert runtime[:agent] == "reviewer"
        assert runtime[:model_spec] == spec
        assert runtime[:model_id_locked] == true
        refute Keyword.has_key?(runtime, :model_id)
      end
    end

    test "the builder gives an explicit spec precedence even if called before admission" do
      spec = selection("team", "reasoner", "high")

      assert {nil, runtime} =
               RuntimeOpts.build_common_runtime_opts(
                 [
                   path: "/fixture/repo",
                   model_spec: spec,
                   model_id: "personal",
                   model_id_locked: false
                 ],
                 "task-direct",
                 :evolve
               )

      assert runtime[:model_spec] == spec
      assert runtime[:model_id_locked] == true
      refute Keyword.has_key?(runtime, :model_id)
    end

    test "legacy unlocked and locked choices retain their distinct runtime semantics" do
      for lock <- [false, true] do
        assert {:ok, admitted} =
                 admit(path: "/fixture/repo", model_id: "personal", model_id_locked: lock)

        assert {nil, runtime} =
                 RuntimeOpts.build_common_runtime_opts(admitted, "task-legacy", :evolve)

        assert runtime[:model_id] == "personal"
        refute Keyword.has_key?(runtime, :model_spec)

        if lock,
          do: assert(runtime[:model_id_locked] == true),
          else: refute(Keyword.has_key?(runtime, :model_id_locked))
      end
    end

    test "admitted Auto does not reintroduce a stale lock in runtime options" do
      assert {:ok, admitted} = admit(path: "/fixture/repo", model_id: "", model_id_locked: true)

      assert {nil, runtime} =
               RuntimeOpts.build_common_runtime_opts(admitted, "task-auto", :evolve)

      assert Keyword.take(runtime, [:model_spec, :model_id, :model_id_locked]) == []
    end

    test "the sanitized default-effort identity is forwarded rather than the original caller map" do
      opts = [path: "/fixture/repo", model_spec: selection("team", "openai:reasoner")]
      assert {:ok, admitted} = admit(opts)

      assert {nil, runtime} =
               RuntimeOpts.build_common_runtime_opts(admitted, "task-normalized", :evolve)

      assert runtime[:model_spec] == selection("team", "reasoner", "medium")
      assert runtime[:model_id_locked] == true
    end
  end

  defp admit(opts), do: RuntimeOpts.admit_model_selection(opts, config())

  defp selection(account, model), do: %{"provider_profile_id" => account, "model" => model}

  defp selection(account, model, effort),
    do: Map.put(selection(account, model), "reasoning_effort", effort)

  # Deliberately project the schema's individual selection fields: model_spec
  # itself is a ReqLLM identifier, while generation_params may contain secrets.
  defp identity(resolved) do
    spec = selection(resolved.provider_profile_id, resolved.model)

    if is_nil(resolved.reasoning_effort),
      do: spec,
      else: Map.put(spec, "reasoning_effort", resolved.reasoning_effort)
  end

  defp plain_account do
    %{id: "plain-account", provider: "openai", auth_mode: "api_key", models: ["plain"]}
  end

  defp config do
    %{
      llm: %{
        default_provider_profile: "team",
        providers: [
          %{
            id: "personal",
            provider: "openai",
            auth_mode: "api_key",
            concurrency: 2,
            default_model: "plain",
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low",
            models: [
              %{model: "plain"},
              %{
                model: "reasoner",
                reasoning_efforts: ["low", "high"],
                default_reasoning_effort: "low"
              }
            ]
          },
          %{
            id: "team",
            provider: "openai",
            auth_mode: "api_key",
            concurrency: 7,
            default_model: "reasoner",
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low",
            models: [
              %{model: "plain"},
              %{
                model: "reasoner",
                reasoning_efforts: ["medium", "high"],
                default_reasoning_effort: "medium"
              }
            ]
          }
        ]
      }
    }
  end
end
