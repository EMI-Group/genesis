defmodule EvoGit.CatalogWarmupTest do
  @moduledoc """
  `EvoGit.CatalogWarmup` is a boot step, so its contract is narrow: it must
  never leave a process in the supervision tree, it must be inert when the
  catalog would be pointless to load (the `:llm_model_metadata_fun` seam is
  installed, or no model is configured), and a failing warm-up must never turn
  into a failed boot.

  `async: false` — every test here writes the BEAM-global app-env key
  `:llm_model_metadata_fun`, which the scheduler, tool dispatch and compression
  read at call time from concurrently running modules.
  """
  use ExUnit.Case, async: false

  alias EvoGit.CatalogWarmup
  alias EvoGit.TestSupport.ConfigDir

  @seam :llm_model_metadata_fun

  # A seam stub: the warm-up gate must short-circuit BEFORE any metadata lookup,
  # so a test can assert no lookup happened by watching the message.
  @stub_metadata %{limits: %{}, capabilities: %{}}

  setup do
    previous = Application.get_env(:evo_git, @seam)
    on_exit(fn -> restore_seam(previous) end)
    :ok
  end

  describe "supervision entry point" do
    test "start_link/1 warms, returns :ignore, and leaves no child behind" do
      Application.put_env(:evo_git, @seam, fn _model -> @stub_metadata end)

      assert CatalogWarmup.start_link([]) == :ignore

      refute Enum.any?(
               Supervisor.which_children(EvoGit.AgentGroupSupervisor),
               fn {id, _pid, _type, _mods} -> id == CatalogWarmup end
             ),
             "a `:ignore` child must never appear in the supervised child list"
    end
  end

  describe "warm_up/1" do
    test "canonical account updates warm metadata outside the scheduler" do
      Application.delete_env(:evo_git, @seam)
      scheduler = Process.whereis(EvoGit.AgentScheduler)
      previous = :sys.get_state(scheduler)
      on_exit(fn -> :sys.replace_state(scheduler, fn _ -> previous end) end)

      config = %{
        llm: %{
          default_provider_profile: "warm-account",
          providers: [
            %{
              "id" => "warm-account",
              "provider" => "openai",
              "auth_mode" => "api_key",
              "default_model" => "gpt-4o-mini",
              "models" => [%{"model" => "gpt-4o-mini"}]
            }
          ]
        }
      }

      session = :trace.session_create(:canonical_catalog_warmup, self(), [])

      try do
        :trace.process(session, self(), true, [:call, :set_on_spawn])
        :trace.process(session, scheduler, true, [:call])
        :trace.function(session, {EvoGit.Config.Schema.LLM, :model_metadata, 1}, true, [:local])

        assert :ok =
                 EvoGit.AgentScheduler.update_config(
                   EvoGit.AgentScheduler.ModelSelection.config_opts(config)
                 )

        barrier = :trace.delivered(session, :all)
        callers = metadata_callers(barrier, [])

        assert Enum.any?(callers, &(&1 != scheduler)),
               "canonical metadata was only loaded in the scheduler"
      after
        :trace.session_destroy(session)
      end
    end

    test "is inert when the metadata seam is installed" do
      test_pid = self()

      Application.put_env(:evo_git, @seam, fn model ->
        send(test_pid, {:metadata_lookup, model})
        @stub_metadata
      end)

      # The gate is evaluated in the CALLER, so this returns only after the
      # (skipped) warm-up would have completed: any lookup would already be in
      # our mailbox.
      assert CatalogWarmup.warm_up([%{id: "p", model: "vendor:model"}]) == :ok
      refute_received {:metadata_lookup, _}
    end

    test "is a no-op when there is nothing to warm" do
      assert CatalogWarmup.warm_up([]) == :ok
    end

    test "completes when a profile carries no model spec (no catalog involved)" do
      assert CatalogWarmup.warm_up([%{id: "no-model"}]) == :ok
    end

    test "a crashing warm-up is logged and swallowed instead of failing the boot" do
      # `:bogus` matches neither `:configured` nor a list, so the throwaway
      # process dies with a FunctionClauseError — exactly the failure mode the
      # boot contract must contain.
      assert CatalogWarmup.warm_up(:bogus) == :ok
    end
  end

  describe "configured_profiles/0" do
    test "is empty when no model profile is configured" do
      write_config("")

      assert CatalogWarmup.configured_profiles() == []
    end

    test "returns the configured profiles that carry a model spec" do
      write_config("""
      [[llm.models]]
      id = "fast"
      model = "vendor:model-a"
      concurrency = 2

      [[llm.models]]
      id = "model-less"
      concurrency = 3
      """)

      assert [profile] = CatalogWarmup.configured_profiles()
      assert profile[:id] == "fast"
      assert profile[:model] == "vendor:model-a"
    end
  end

  # Writes `toml` into an isolated, per-test config dir (active for THIS
  # process, which is where `configured_profiles/0` resolves the config when a
  # test calls it directly).
  defp write_config(toml) do
    dir = Path.join(ConfigDir.isolate!("evogit_catalog_warmup"), "genesis")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.toml"), toml)
  end

  defp restore_seam(nil), do: Application.delete_env(:evo_git, @seam)

  defp restore_seam(value), do: Application.put_env(:evo_git, @seam, value)

  defp metadata_callers(barrier, callers) do
    receive do
      {:trace_delivered, :all, ^barrier} ->
        callers

      {:trace, pid, :call, {EvoGit.Config.Schema.LLM, :model_metadata, _}} ->
        metadata_callers(barrier, [pid | callers])

      {:trace, _, _, _} ->
        metadata_callers(barrier, callers)

      {:trace, _, _, _, _} ->
        metadata_callers(barrier, callers)
    after
      5000 -> flunk("catalog trace barrier did not complete")
    end
  end
end
