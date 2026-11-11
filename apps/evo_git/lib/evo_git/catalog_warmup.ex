defmodule EvoGit.CatalogWarmup do
  @moduledoc """
  Throwaway warm-up of the LLM model catalog at boot and on profile changes.

  `EvoGit.AgentScheduler.init/1` is the first `ReqLLM.model/1` caller on a fresh
  BEAM, and that call makes `:llm_db` read + `Jason.decode` its packaged catalog
  snapshot (~11.7 MB of JSON, ~8.7k models) and build its indexes — tens of MB of
  TRANSIENT heap allocated in the CALLING process, of which only the durable
  catalog (published into `:persistent_term`) survives. An INTERACTIVE BEAM
  fullsweeps that dead heap away within the same boot, but an EMBEDDED boot
  (`-mode embedded`, i.e. the release and `genesis start`/`genesis serve`) never
  does: the scheduler ends `init/1` right after the load and never allocates
  again, so it kept ~47 MB for the whole BEAM lifetime.

  This module performs the load in a SEPARATE, short-lived process and returns
  `:ignore`, so the transient heap dies with that process and the scheduler
  started immediately afterwards only pays cheap `:persistent_term` reads of the
  now-warm catalog. It is declared in `EvoGit.AgentGroupSupervisor` immediately
  before `EvoGit.AgentScheduler`, so the ordering is explicit.

  `AgentScheduler.update_config/1` also warms explicit model profiles before
  calling the scheduler. A first model configured after an empty boot therefore
  pays the cold load outside the scheduler, keeping its mailbox responsive and
  avoiding the configuration call's five-second timeout.

  The warm-up is deliberately INERT when
  * the `:llm_model_metadata_fun` app-env seam is installed (the test suite's way
    of bypassing the catalog entirely — a test boot must not pay the decode), or
  * no model profile carries a model spec (nothing to resolve).

  Boot must never fail because of it: the work runs in an unlinked process whose
  crash is logged once and otherwise ignored, and a bounded timeout releases the
  supervisor if the warm-up ever hangs.
  """

  require Logger

  # The catalog decode measures ~2.8 s; the bound only exists so a pathological
  # hang can never block the boot forever.
  @warmup_timeout_ms 30_000

  @doc """
  Supervision entry point. Performs the warm-up and returns `:ignore` so that no
  process stays in the supervision tree (the work already happened in, and died
  with, its own throwaway process).
  """
  @spec start_link(term()) :: :ignore
  def start_link(_opts \\ []) do
    warm_up()
    :ignore
  end

  @doc false
  # No `use GenServer` here — this is a one-shot boot step, not a process. The
  # `restart: :temporary` spec is inert anyway because `start_link/1` always
  # returns `:ignore`, i.e. the supervisor never tracks it.
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Warms the LLM model catalog and returns `:ok`. Never raises.

  `profiles` is either `:configured` (resolve the runtime's effective model
  profiles inside the throwaway process) or an explicit list of profile maps.
  """
  @spec warm_up(:configured | [map()]) :: :ok
  def warm_up(profiles \\ :configured) do
    if metadata_seam_installed?() do
      :ok
    else
      run(profiles)
    end
  end

  @doc """
  The model profiles worth warming: the runtime's effective profiles (the
  `[[llm.models]]` entries, or the synthesized legacy `"default"` profile) that
  actually carry a model spec. A profile without a `model` has nothing to
  resolve against the catalog, so it contributes no warm-up work.
  """
  @spec configured_profiles() :: [map()]
  def configured_profiles do
    EvoGit.Config.Schema.effective_model_profiles(EvoGit.Config.resolve())
    |> Enum.filter(&(Map.get(&1, :model) != nil))
  end

  # The seam is what makes tests skip the catalog; matching its exact shape
  # (`is_function/1`) keeps the gate aligned with `Schema.LLM.model_metadata/1`,
  # which falls back to the catalog for any other value.
  defp metadata_seam_installed? do
    is_function(Application.get_env(:evo_git, :llm_model_metadata_fun), 1)
  end

  # `spawn_monitor` (not `Task.async`, not a link) keeps the warm-up's heap in a
  # process that exits immediately afterwards AND makes a failure unable to take
  # the supervisor down with it.
  defp run(profiles) do
    started_at = System.monotonic_time(:millisecond)
    {pid, ref} = spawn_monitor(fn -> warm(profiles) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        Logger.debug(fn ->
          "CatalogWarmup: LLM catalog warm-up finished in #{elapsed_ms(started_at)} ms"
        end)

        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning(
          "CatalogWarmup: LLM catalog warm-up failed (#{inspect(reason)}) — continuing boot"
        )

        :ok
    after
      @warmup_timeout_ms ->
        Process.demonitor(ref, [:flush])

        Logger.warning(
          "CatalogWarmup: LLM catalog warm-up did not finish within " <>
            "#{@warmup_timeout_ms} ms — continuing boot"
        )

        :ok
    end
  end

  defp warm(:configured), do: warm(configured_profiles())

  defp warm(profiles) when is_list(profiles) do
    # `llm_generation_params/1` is the SAME choke point the scheduler's `init/1`
    # uses (`State.from_model_profiles/2` and the `default_params` seed), so it
    # reaches `Schema.LLM.model_metadata/1` and therefore the catalog.
    Enum.each(profiles, &EvoGit.Config.Schema.llm_generation_params/1)
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
