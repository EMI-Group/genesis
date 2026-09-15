defmodule EvoGit.LeakDump do
  @moduledoc "TEMPORARY helper module for zz_leak_watch_test.exs (remove before committing)."

  def agent_state(agent_id) do
    case EvoGit.AgentScheduler.Store.get_agent_state(agent_id) do
      {:ok, s} ->
        %{
          model_id: Map.get(s, :model_id),
          llm_model: inspect(Map.get(s, :llm_model)),
          objective: Map.get(s, :objective),
          repo_id: Map.get(s, :repo_id),
          repo_root: Map.get(s, :repo_root),
          task_local_id: Map.get(s, :task_local_id),
          parent_id: Map.get(s, :parent_id),
          turn: Map.get(s, :turn)
        }

      other ->
        other
    end
  catch
    _, r -> {:error, r}
  end

  def sched_meta(agent_id) do
    case EvoGit.AgentScheduler.Store.get_sched_meta(agent_id) do
      {:ok, m} ->
        spec = m.spec

        %{
          task_id: m.task_id,
          status: m.status,
          task_number: m.task_number,
          parent_id: m.parent_id,
          retries: m.retries,
          worktree: m.worktree,
          spec_repo_id: spec && spec.repo_id,
          spec_context_node: spec && inspect(spec.context_node),
          spec_objective: spec && spec.objective,
          spec_model_id: spec && spec.model_id,
          spec_agent_module: spec && inspect(spec.agent_module)
        }

      other ->
        other
    end
  catch
    _, r -> {:error, r}
  end

  def all_agent_states do
    :ets.tab2list(:evogit_agent_state)
    |> Enum.map(fn {id, s} ->
      {id,
       %{
         model_id: Map.get(s, :model_id),
         objective: Map.get(s, :objective),
         repo_id: Map.get(s, :repo_id),
         repo_root: Map.get(s, :repo_root),
         task_local_id: Map.get(s, :task_local_id),
         parent_id: Map.get(s, :parent_id)
       }}
    end)
  end

  def all_sched_metas do
    :ets.tab2list(:evogit_sched_meta)
    |> Enum.map(fn {id, m} ->
      spec = m.spec

      {id,
       %{
         task_id: m.task_id,
         status: m.status,
         parent_id: m.parent_id,
         spec_repo_id: spec && spec.repo_id,
         spec_objective: spec && spec.objective,
         spec_agent_module: spec && inspect(spec.agent_module)
       }}
    end)
  end

  def ets_ids(tab) do
    if :ets.whereis(tab) == :undefined do
      :undefined
    else
      :ets.tab2list(tab) |> Enum.map(fn {k, _} -> k end)
    end
  end
end

defmodule EvoGit.LeakWatchTest do
  @moduledoc """
  TEMPORARY leak hunter (remove before committing).

  Installs a suite-wide watcher at FILE-LOAD time (module body executes while
  `mix test` requires the test files, i.e. before ANY test runs) that polls the
  global scheduler's live `llm_slots` map and dumps everything needed to
  attribute a leaked LLM-slot holder.

  The suspicious model ids are the scheduler's INITIAL `model_profiles` ids —
  the developer's real `~/.config/genesis/config.toml` profiles, which tests do
  NOT redirect. A holder appearing under one of those ids can only come from a
  test that acquires a real LLM slot with an agent id that has no ETS row (or a
  nil `model_id`) WITHOUT first pinning `model_profiles`.
  """
  use ExUnit.Case, async: false

  baseline_profiles =
    try do
      EvoGit.AgentScheduler.get_config(:model_profiles)
    rescue
      _ -> []
    catch
      _, _ -> []
    end

  baseline_model_ids = Enum.map(baseline_profiles, &Map.get(&1, :id))

  watcher =
    spawn(fn ->
      IO.puts(
        "[LEAK-WATCH] installed; baseline (developer) model ids = #{inspect(baseline_model_ids)}"
      )

      loop = fn loop, seen ->
        receive do
          :stop ->
            IO.puts("[LEAK-WATCH] watcher stopped")
            :ok
        after
          15 ->
            status =
              try do
                EvoGit.AgentScheduler.get_llm_slot_status()
              rescue
                _ -> %{}
              catch
                _, _ -> %{}
              end

            suspicious =
              status
              |> Enum.filter(fn {model_id, %{used: used}} ->
                used > 0 and model_id in baseline_model_ids
              end)

            seen =
              Enum.reduce(suspicious, seen, fn {model_id, %{used: used}}, acc ->
                holders =
                  try do
                    :sys.get_state(EvoGit.AgentScheduler).llm_holders
                    |> Map.get(model_id, MapSet.new())
                  rescue
                    _ -> MapSet.new()
                  catch
                    _, _ -> MapSet.new()
                  end

                agent_ids = MapSet.to_list(holders)
                new = Enum.reject(agent_ids, &MapSet.member?(acc, {model_id, &1}))

                if new != [] do
                  IO.puts(
                    "\n[LEAK-WATCH] !!! LEAK model=#{inspect(model_id)} used=#{used} " <>
                      "agent_ids=#{inspect(agent_ids)} new=#{inspect(new)}"
                  )

                  for agent_id <- new do
                    IO.puts(
                      "[LEAK-WATCH]   agent ##{agent_id} state=#{inspect(EvoGit.LeakDump.agent_state(agent_id))}"
                    )

                    IO.puts(
                      "[LEAK-WATCH]   agent ##{agent_id} meta=#{inspect(EvoGit.LeakDump.sched_meta(agent_id))}"
                    )
                  end

                  IO.puts(
                    "[LEAK-WATCH]   ALL agent_states=#{inspect(EvoGit.LeakDump.all_agent_states())}"
                  )

                  IO.puts(
                    "[LEAK-WATCH]   ALL sched_metas=#{inspect(EvoGit.LeakDump.all_sched_metas())}"
                  )

                  IO.puts("[LEAK-WATCH] !!! END LEAK\n")
                end

                Enum.reduce(new, acc, fn id, a -> MapSet.put(a, {model_id, id}) end)
              end)

            loop.(loop, seen)
        end
      end

      loop.(loop, MapSet.new())
    end)

  ExUnit.after_suite(fn _ -> send(watcher, :stop) end)

  test "leak watcher placeholder" do
    assert true
  end
end
