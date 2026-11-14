Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.OperatorProjectsTest do
  @moduledoc """
  Genuine-Dune operator project discovery and exact-MFA refusal.

  Synchronous because the broker's runtime Task uses the app-global VCT, not
  TaskRegistryCase's process-local VCT seam. Only uniquely named test mounts
  are inserted and forgotten; the app's reserved mounts are never changed.
  Approval assertions inspect the app-global CommandApproval pending roster.
  No scheduler settings, environment variables or runtime seams are changed.
  """
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.{CommandApproval, VCT}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  setup %{store: store, registry: registry, tmp_dir: dir} do
    # DirectAPI deliberately carries registry authority, not arbitrary routing
    # seams; use the same node-local singleton as the real Assistant broker.
    Process.put(:evogit_vct_server, VCT)
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    token = "operator-project-#{fixture.agent_id}"

    mounts =
      for suffix <- ["alpha", "beta"] do
        path = Path.expand(Path.join(dir, "#{token}-#{suffix}"))
        refute File.exists?(path)
        {:ok, mount} = VCT.mount(path, name: "#{token}-#{suffix}")
        on_exit(fn -> assert :ok = GenServer.call(VCT, {:forget, mount.point}, 30_000) end)
        mount
      end

    %{fixture: fixture, mounts: mounts, token: token}
  end

  @moduletag :tmp_dir

  test "projects/0,1 return real Mounts including missing paths but never reserved mounts", ctx do
    {:ok, _} = VCT.resolve("vct:///genesis-source")
    expected = VCT.projects()
    assert Enum.all?(ctx.mounts, &(&1 in expected))
    refute Enum.any?(expected, &(&1.point == "vct:///genesis-source"))
    assert_value(ctx, "EvoGit.VCT.projects()", expected)
    assert_value(ctx, "EvoGit.VCT.projects(limit: 1)", Enum.take(expected, 1))

    assert read(ctx, """
           projects = EvoGit.VCT.projects()
           {Enum.all?(projects, fn mount ->
             Atom.to_string(mount.__struct__) == "Elixir.EvoGit.VCT.Mount"
           end), Enum.any?(projects, fn mount -> mount.point == "vct:///genesis-source" end)}
           """) == "Result: {true, false}"

    for mount <- ctx.mounts, do: refute(File.exists?(mount.path))
    assert_no_approval(ctx)
  end

  test "search/1,2 forward real case-insensitive name, path, point and blank queries", ctx do
    for query <- [
          String.upcase(ctx.token),
          hd(ctx.mounts).path,
          hd(ctx.mounts).point,
          "",
          "no-match-#{ctx.token}"
        ] do
      expected = VCT.search(query)
      if query == String.upcase(ctx.token), do: assert(length(expected) == 2)
      if query == "no-match-#{ctx.token}", do: assert(expected == [])
      assert_value(ctx, "EvoGit.VCT.search(#{inspect(query)})", expected)
      assert_value(ctx, "EvoGit.VCT.search(#{inspect(query)}, limit: 1)", Enum.take(expected, 1))
      refute Enum.any?(expected, &(&1.point == "vct:///genesis-source"))
    end

    assert_value(ctx, "EvoGit.VCT.search(\"genesis-source\")", VCT.search("genesis-source"))
    assert_no_approval(ctx)
  end

  test "no VCT mutation is admitted at either interpreted tier and read never escalates", ctx do
    mount = hd(ctx.mounts)
    before = VCT.projects()
    context_before = VCT.global_context()

    for code <- [
          "EvoGit.VCT.mount(#{inspect(mount.path)})",
          "EvoGit.VCT.mount(#{inspect(mount.path)}, name: \"forbidden\")",
          "EvoGit.VCT.ensure_mount(#{inspect(mount.point)}, #{inspect(mount.path)})",
          "EvoGit.VCT.ensure_mount(#{inspect(mount.point)}, #{inspect(mount.path)}, name: \"forbidden\")",
          "EvoGit.VCT.forget(#{inspect(mount.point)})",
          "EvoGit.VCT.put_global_context(\"forbidden\")"
        ] do
      assert read(ctx, code) =~ "Error: Evaluation rejected a restricted operation."

      for tier <- [:read, :write] do
        output =
          ctx.fixture
          |> Fixture.call_async(fn ->
            {:ok, authority} = Authorization.authorize()
            Engine.run(code, tier, authority, %{timeout_ms: 5_000, max_output_bytes: 16_384})
          end)
          |> Fixture.await()

        assert {:error, message} = output
        assert message =~ "Evaluation rejected a restricted operation."
        assert message =~ "no automatic escalation"
      end

      assert VCT.projects() == before
      assert VCT.global_context() == context_before
      assert_no_approval(ctx)
    end
  end

  defp read(ctx, code) do
    ctx.fixture
    |> Fixture.call_async(fn ->
      ElixirEval.execute(%{"code" => code, "tier" => "read"}, "[system]", "[system]")
    end)
    |> Fixture.await()
  end

  defp assert_value(ctx, code, expected) do
    # Dune does not intern unadmitted struct alias segments from source literals.
    # Preserve every Mount field and its struct identity, rendering only the
    # DateTime as ISO8601 instead of synthesizing a Mount/DateTime literal.
    expected =
      Enum.map(expected, fn mount ->
        {Atom.to_string(mount.__struct__),
         Map.update!(Map.from_struct(mount), :last_opened_at, fn
           nil -> nil
           timestamp -> DateTime.to_iso8601(timestamp)
         end)}
      end)

    literal = inspect(expected, limit: :infinity, printable_limit: :infinity)

    assert read(ctx, """
           Enum.map((#{code}), fn mount ->
             {Atom.to_string(mount.__struct__),
              Map.update!(Map.from_struct(mount), :last_opened_at, fn
                nil -> nil
                timestamp -> DateTime.to_iso8601(timestamp)
              end)}
           end) == #{literal}
           """) == "Result: true"
  end

  defp assert_no_approval(ctx) do
    task_id = ctx.fixture.task_id
    refute Enum.any?(CommandApproval.pending(), &(&1.task_id == task_id))
    refute_received {:approval_requested, %{task_id: ^task_id}}
  end
end
