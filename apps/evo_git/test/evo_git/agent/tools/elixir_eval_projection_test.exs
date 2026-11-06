defmodule EvoGit.Agent.Tools.ElixirEval.ProjectionTest.Registry do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, opts}

  def handle_call(request, _from, opts) do
    send(opts[:observer], {:projection_read, request})
    {:reply, opts[:reply], opts}
  end
end

defmodule EvoGit.Agent.Tools.ElixirEval.ProjectionTest do
  @moduledoc """
  Async-safe scalar/argument projections and reads against a private registry.
  Never enumerates app-global ETS or reads/mutates the global scheduler.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval.Projection

  @task_keys ~w(id type status review_status started_at finished_at updated_at agent_count)a
  @statuses ~w(pending running finalizing cancelling completed failed cancelled)a

  describe "task/1 confidentiality boundary" do
    test "returns exactly the scalar allowlist, never nested runtime data" do
      secret = "not-for-the-assistant"

      row = %{
        id: "task_01-A",
        type: :evolve,
        status: :completed,
        review_status: :open,
        started_at: ~U[2026-01-02 03:04:05Z],
        finished_at: ~N[2026-01-02 04:05:06],
        updated_at: "2026-01-02T04:05:06Z",
        agent_count: 2,
        objective: secret,
        opts: %{credentials: secret, objective: secret},
        result: {:ok, %{result: secret}},
        error: %{message: secret},
        usage: %{secret: secret},
        logs: [secret],
        context: [secret],
        history: [secret],
        generation_params: [api_key: secret],
        credentials: secret,
        foreign_repos: [%{root: secret}],
        branch_name: secret,
        commit_sha: secret
      }

      assert Projection.task(row) == %{
               id: "task_01-A",
               type: :evolve,
               status: :completed,
               review_status: :open,
               started_at: "2026-01-02T03:04:05Z",
               finished_at: "2026-01-02T04:05:06",
               updated_at: "2026-01-02T04:05:06Z",
               agent_count: 2
             }

      refute inspect(Projection.task(row)) =~ secret
      assert Enum.sort(Map.keys(Projection.task(row))) == Enum.sort(@task_keys)
    end

    test "normalizes unknown or nested scalars to nil instead of inspecting them" do
      row = Map.new(@task_keys, &{&1, %{secret: "private"}})
      assert Projection.task(row) == Map.new(@task_keys, &{&1, nil})
      assert Projection.task(%{}) == Map.new(@task_keys, &{&1, nil})
      assert Projection.task(nil) == nil
      assert Projection.task(id: "task") == nil

      for value <- [-1, 1.0, "1", true, nil] do
        assert Projection.task(%{agent_count: value}).agent_count == nil
      end
    end

    test "permits only the literal type, status and review enums" do
      for type <- [:genesis, :evolve, :reflect, :extract_skills] do
        assert Projection.task(%{type: type}).type == type
        assert Projection.task(%{type: Atom.to_string(type)}).type == nil
      end

      for status <- @statuses do
        assert Projection.task(%{status: status}).status == status
        assert Projection.task(%{status: Atom.to_string(status)}).status == nil
      end

      for review <- [:open, :merged, :rejected, :continued, :ignored, :no_changes] do
        assert Projection.task(%{review_status: review}).review_status == review
      end

      assert Projection.task(%{type: :custom, status: :unknown, review_status: :secret}) ==
               Map.new(@task_keys, &{&1, nil})
    end

    test "bounds text fields and does not return malformed UTF-8" do
      assert Projection.task(%{id: String.duplicate("a", 129)}).id == String.duplicate("a", 128)

      assert Projection.task(%{updated_at: String.duplicate("x", 41)}).updated_at ==
               String.duplicate("x", 40)

      assert Projection.task(%{id: <<255>>, started_at: <<255>>}).id == nil
      assert Projection.task(%{started_at: <<255>>}).started_at == nil
    end
  end

  describe "page_options/1" do
    test "defaults and exact inclusive limit/offset boundaries" do
      assert Projection.page_options(%{}) == {:ok, [limit: 25, offset: 0, status: "all"]}

      for limit <- [1, 50], offset <- [0, 10_000] do
        assert Projection.page_options(%{"limit" => limit, "offset" => offset}) ==
                 {:ok, [limit: limit, offset: offset, status: "all"]}
      end
    end

    test "maps only literal atom/string statuses without converting arbitrary input to atoms" do
      for status <- @statuses do
        expected = {:ok, [limit: 25, offset: 0, status: Atom.to_string(status)]}
        assert Projection.page_options(%{status: status}) == expected
        assert Projection.page_options(%{"status" => Atom.to_string(status)}) == expected
      end

      for status <- [:all, "RUNNING", "unknown", "running ", [], %{}, nil, 0] do
        assert {:error, _} = Projection.page_options(%{status: status})
      end
    end

    test "rejects unsupported keys, excessive options and non-map input" do
      for options <- [
            %{include_results: true},
            %{"opts" => true},
            %{limit: 1, offset: 0, status: "all", include_settings: true},
            [],
            [limit: 1],
            nil,
            "limit=1"
          ] do
        assert {:error, _} = Projection.page_options(options)
      end
    end

    test "rejects values outside bounds or of a coercible but incorrect type" do
      for value <- [0, -1, 51, 1.0, "1", nil, true, %{}] do
        assert {:error, _} = Projection.page_options(%{limit: value})
      end

      for value <- [-1, 10_001, 0.0, "0", nil, false, []] do
        assert {:error, _} = Projection.page_options(%{offset: value})
      end
    end
  end

  describe "task_id/1" do
    test "accepts only 1..128 bytes of ASCII identifier characters" do
      for id <- ["a", "0", "_", "-", "Az09_-", String.duplicate("a", 128)] do
        assert Projection.task_id(id) == :ok
      end

      for id <- [
            "",
            String.duplicate("a", 129),
            "é",
            "任务",
            "a/b",
            "../a",
            "a.b",
            "a b",
            "a\n",
            "a\r\n",
            "a\t",
            "a" <> <<0>>,
            <<255>>,
            :task,
            1,
            nil,
            %{}
          ] do
        assert Projection.task_id(id) == {:error, "Invalid task id."}
      end
    end
  end

  describe "bounded registry read projection" do
    test "task pages request the lean API, cap returned rows and project each row" do
      rows = for n <- 1..60, do: %{id: "task_#{n}", result: "secret", opts: %{api_key: "secret"}}
      registry = registry(%{rows: rows, total: 60})

      page =
        Projection.tasks(%{registry: registry}, %{
          "limit" => 2,
          "offset" => 4,
          "status" => :failed
        })

      assert_receive {:projection_read,
                      {:list_tasks_page, [limit: 2, offset: 4, status: "failed"]}}

      assert %{total: 60, limit: 2, offset: 4, rows: projected} = page
      assert Enum.map(projected, & &1.id) == ["task_1", "task_2"]
      assert Enum.all?(projected, &(Enum.sort(Map.keys(&1)) == Enum.sort(@task_keys)))
      refute inspect(page) =~ "secret"
    end

    test "invalid page arguments never reach the registry; malformed responses are unavailable" do
      registry = registry(%{rows: :not_a_list, total: 1})
      assert {:error, _} = Projection.tasks(%{registry: registry}, %{limit: 51})
      refute_received {:projection_read, _}
      assert Projection.tasks(%{registry: registry}, %{}) == {:error, "Task page unavailable."}
      assert_receive {:projection_read, {:list_tasks_page, _}}
    end

    test "empty page normalizes an unusable total" do
      registry = registry(%{rows: [], total: %{private: "secret"}})

      assert Projection.tasks(%{registry: registry}, %{}) ==
               %{rows: [], total: nil, limit: 25, offset: 0}
    end

    test "single-task reads validate first, request lite data, and strip secrets" do
      registry = registry(%{id: "task-a", status: :running, result: "private", error: "private"})
      assert {:error, _} = Projection.get_task(%{registry: registry}, "../task")
      refute_received {:projection_read, _}
      task = Projection.get_task(%{registry: registry}, "task-a")
      assert_receive {:projection_read, {:get_task_lite, "task-a"}}
      assert task.id == "task-a"
      assert task.status == :running
      refute inspect(task) =~ "private"
      assert Enum.sort(Map.keys(task)) == Enum.sort(@task_keys)
    end

    test "missing single task is nil" do
      assert Projection.get_task(%{registry: registry(nil)}, "missing") == nil
    end
  end

  describe "scalar helpers and local system info" do
    test "text/count/enum refuse nested values without leaking their inspection" do
      assert Projection.text("éclair", 2) == "éc"
      assert Projection.text(<<255>>, 10) == nil
      assert Projection.text(%{secret: "private"}, 10) == nil
      assert Projection.count(0) == 0
      assert Projection.count(123) == 123
      for value <- [-1, 1.5, "1", %{}, nil], do: assert(Projection.count(value) == nil)
      assert Projection.enum(:running, [:running]) == :running
      assert Projection.enum("running", [:running]) == nil
    end

    test "system info has only the public scalar keys, no paths, hostname or credentials" do
      info = Projection.system_info()
      assert Enum.sort(Map.keys(info)) == Enum.sort(~w(os elixir otp utc_time schedulers)a)
      assert info.os in [:linux, :macos, :windows, nil]
      assert info.elixir == System.version()
      assert info.otp == System.otp_release()
      assert {:ok, _, 0} = DateTime.from_iso8601(info.utc_time)
      assert is_integer(info.schedulers) and info.schedulers > 0
    end
  end

  defp registry(reply) do
    start_supervised!({__MODULE__.Registry, observer: self(), reply: reply})
  end
end
