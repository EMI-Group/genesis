Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.GenesisSourceTest do
  # async: false is FORCED by BEAM-global knobs: the `:self_reflective_source_*`
  # app-env keys and the `GENESIS_SOURCE_ROOT` OS env var (both read by the
  # app-global source resolution), plus the app-global VCT mount it may touch.
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)
    root = Path.join(System.tmp_dir!(), "genesis_source_optional_#{fixture.agent_id}")

    original =
      for key <- [
            :self_reflective_source_root,
            :self_reflective_source_dir,
            :self_reflective_source_url
          ],
          into: %{},
          do: {key, Application.get_env(:evo_git, key)}

    env = System.get_env("GENESIS_SOURCE_ROOT")
    System.delete_env("GENESIS_SOURCE_ROOT")
    Application.delete_env(:evo_git, :self_reflective_source_root)
    Application.put_env(:evo_git, :self_reflective_source_dir, root)
    Application.put_env(:evo_git, :self_reflective_source_url, Path.join(root, "missing-origin"))
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

    on_exit(fn ->
      Fixture.stop(fixture)
      File.rm_rf(root)

      for {key, value} <- original do
        if value == nil,
          do: Application.delete_env(:evo_git, key),
          else: Application.put_env(:evo_git, key, value)
      end

      if env == nil,
        do: System.delete_env("GENESIS_SOURCE_ROOT"),
        else: System.put_env("GENESIS_SOURCE_ROOT", env)
    end)

    {:ok, fixture: fixture, root: root}
  end

  test "missing source is optional and ordinary callers cannot request preparation", %{
    fixture: fixture,
    root: root
  } do
    assert Tools.execute(
             "genesis_source",
             %{"action" => "prepare", "purpose" => "explain runtime"},
             "[system]",
             nil,
             nil
           ) =~ "Error:"

    result = call(fixture, %{"action" => "status"}) |> Jason.decode!()
    assert result["available"] == false
    assert result["reference_path"] == nil
    refute File.exists?(root)
    refute_receive {:approval_requested, _}
  end

  test "existing reference provides bounded context and real read/search dispatch from an isolated session",
       %{fixture: fixture, root: root} do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "CONTEXT.md"), "SOURCE_ENTRY " <> String.duplicate("x", 20_000))
    File.write!(Path.join(root, "VERSION"), "source-version-different")
    File.write!(Path.join(root, "fixture.ex"), "defmodule OptionalSourceFixture do\nend\n")
    Application.put_env(:evo_git, :self_reflective_source_root, root)
    result = call(fixture, %{"action" => "context"}) |> Jason.decode!()
    assert result["available"]
    assert result["reference_path"] == root
    assert result["source_version"] == "source-version-different"
    assert result["version_matches"] == false
    assert result["truncated"]
    assert byte_size(result["context"]) == 16_384

    read =
      Fixture.call_async(fixture, fn ->
        Tools.execute("read", %{"file_path" => "fixture.ex"}, "[system]", "[system]", "./")
      end)
      |> Fixture.await()

    assert read =~ "OptionalSourceFixture"

    context_read =
      Fixture.call_async(fixture, fn ->
        Tools.execute("read_context", %{"dir_path" => "./"}, "[system]", "[system]", "./")
      end)
      |> Fixture.await()

    assert context_read =~ "SOURCE_ENTRY"
    ordinary = Tools.execute("read", %{"file_path" => "fixture.ex"}, "[system]", "[system]", "./")
    refute ordinary =~ "OptionalSourceFixture"

    search =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "rg",
          %{"args" => ["OptionalSourceFixture", "fixture.ex"]},
          "[system]",
          "[system]",
          "./"
        )
      end)
      |> Fixture.await()

    assert search =~ "OptionalSourceFixture"
    refute search =~ "Error:"
    refute_receive {:approval_requested, _}
  end

  test "denied preparation never creates the source directory", %{fixture: fixture, root: root} do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "genesis_source",
          %{"action" => "prepare", "purpose" => "解释 Session 实现"},
          "[system]",
          nil,
          nil
        )
      end)

    assert_receive {:approval_requested, request}, 3000
    assert request.tool_name == "genesis_source"
    assert request.parameters["path"] == root
    assert request.parameters["purpose"] == "解释 Session 实现"
    assert request.summary =~ "只读参考源码"
    assert EvoGit.CommandApproval.respond(request.request_id, :deny) == :ok
    assert Fixture.await(handle) =~ "denied"
    refute File.exists?(root)
  end

  test "approval cannot be reused after the configured source target changes", %{
    fixture: fixture,
    root: root
  } do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "genesis_source",
          %{"action" => "prepare", "purpose" => "explain runtime"},
          "[system]",
          nil,
          nil
        )
      end)

    assert_receive {:approval_requested, request}, 3000
    Application.put_env(:evo_git, :self_reflective_source_dir, root <> "-changed")
    assert EvoGit.CommandApproval.respond(request.request_id, :approve) == :ok
    assert Fixture.await(handle) =~ "target changed"
    refute File.exists?(root)
    refute File.exists?(root <> "-changed")
  end

  test "approved download failure leaves normal status usable", %{fixture: fixture} do
    handle =
      Fixture.call_async(fixture, fn ->
        Tools.execute(
          "genesis_source",
          %{"action" => "prepare", "purpose" => "explain runtime"},
          "[system]",
          nil,
          nil
        )
      end)

    assert_receive {:approval_requested, request}, 3000
    assert EvoGit.CommandApproval.respond(request.request_id, :approve) == :ok
    assert Fixture.await(handle) =~ "Source preparation failed"

    assert call(fixture, %{"action" => "status"}) |> Jason.decode!() |> Map.fetch!("available") ==
             false
  end

  defp call(fixture, args) do
    Fixture.call_async(fixture, fn ->
      Tools.execute("genesis_source", args, "[system]", nil, nil)
    end)
    |> Fixture.await()
  end
end
