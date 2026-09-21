defmodule EvoGit.CustomToolsTest do
  @moduledoc """
  Loader + public-API tests for the custom-tools subsystem
  (`EvoGit.CustomTools` / `EvoGit.CustomTools.Loader`).

  `async: false` — every test repoints the BEAM-global `XDG_CONFIG_HOME` env var
  so custom tools never read the real `~/.config/genesis/` directory.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias EvoGit.CustomTools
  alias EvoGit.CustomTools.Loader

  setup do
    isolate_xdg!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Points XDG_CONFIG_HOME at a fresh temp dir (so `EvoGit.Config.config_dir/0`
  # resolves under it) and restores it — plus the loader's `:persistent_term`
  # cache entry — on exit.
  defp isolate_xdg! do
    original = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg = Path.join(System.tmp_dir!(), "evogit-ct-xdg-#{uniq()}")
    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      Loader.invalidate(Path.join(EvoGit.Config.config_dir(), "tools"))

      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp dir, do: CustomTools.tools_dir()

  defp module_for(suffix), do: Module.concat([:"CustomToolsFixture#{suffix}"])

  defp ctx, do: %{repo_path: System.tmp_dir!(), repo_root: nil, node_path: nil}

  # Generates the SOURCE of a valid custom-tool module. Options control the
  # `read_only?/0` classification and the `execute/2` failure mode so a single
  # helper covers every loader/API scenario.
  defp tool_source(module, tool_name, opts) do
    read_only_clause =
      cond do
        Keyword.get(opts, :read_only_raises) ->
          "\n  @impl true\n  def read_only?, do: raise \"read_only boom\""

        Keyword.get(opts, :read_only) == nil ->
          ""

        true ->
          "\n  @impl true\n  def read_only?, do: #{Keyword.get(opts, :read_only)}"
      end

    {execute_body, uses_args?} =
      cond do
        Keyword.get(opts, :raise) -> {~s|raise "custom tool boom"|, false}
        Keyword.get(opts, :throw) -> {~s|throw(:custom_tool_boom)|, false}
        Keyword.get(opts, :non_string) -> {~s|{:not, "a string"}|, false}
        true -> {~s|"custom-tool-ran:" <> inspect(args)|, true}
      end

    # `_args` avoids an unused-variable warning for the failure-mode bodies.
    arg_name = if uses_args?, do: "args", else: "_args"

    """
    defmodule #{inspect(module)} do
      @behaviour EvoGit.CustomTools.Tool

      @impl true
      def schema do
        ReqLLM.tool(
          name: #{inspect(tool_name)},
          description: "custom tools test fixture",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, nil} end
        )
      end

      @impl true
      def execute(#{arg_name}, _ctx), do: #{execute_body}#{read_only_clause}
    end
    """
  end

  defp write_raw!(dir, basename, content) do
    File.mkdir_p!(dir)
    path = Path.join(dir, basename)
    File.write!(path, content)
    path
  end

  defp write_source_tool!(dir, basename, tool_name, opts \\ []) do
    module = module_for(uniq())
    path = write_raw!(dir, basename, tool_source(module, tool_name, opts))
    {module, path}
  end

  # Compiles generated source with `Code.compile_file/1` to obtain the beam
  # binary, then writes it as a `.beam` file so the loader takes its
  # `:beam_lib` + `:code.load_binary/3` path.
  defp write_beam_tool!(dir, tool_name, opts) do
    module = module_for(uniq())

    src_dir = Path.join(System.tmp_dir!(), "evogit-ct-src-#{uniq()}")
    File.mkdir_p!(src_dir)
    src_path = Path.join(src_dir, "source.ex")
    File.write!(src_path, tool_source(module, tool_name, opts))

    [{^module, beam}] = Code.compile_file(src_path)

    File.mkdir_p!(dir)
    beam_path = Path.join(dir, "#{inspect(module)}.beam")
    File.write!(beam_path, beam)

    File.rm_rf!(src_dir)

    {module, beam_path}
  end

  # ---------------------------------------------------------------------------
  # .ex files
  # ---------------------------------------------------------------------------

  describe "load/0 — .ex tool files" do
    test "loads a valid .ex tool module and exposes it via the API" do
      tool = "ct_ex_#{uniq()}"
      {module, path} = write_source_tool!(dir(), "#{tool}.ex", tool, read_only: true)
      CustomTools.reload()

      entries = CustomTools.load()
      assert Map.has_key?(entries, tool)

      entry = entries[tool]
      assert entry.name == tool
      assert entry.module == module
      assert entry.schema.name == tool
      assert entry.read_only? == true
      assert entry.file == path

      assert tool in Enum.map(CustomTools.schemas(), & &1.name)
      assert CustomTools.known?(tool)
    end

    test "defaults to a WRITE tool when read_only?/0 is absent" do
      tool = "ct_ex_default_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool)
      CustomTools.reload()

      assert CustomTools.load()[tool].read_only? == false
      assert CustomTools.write_tool?(tool)
    end
  end

  # ---------------------------------------------------------------------------
  # .beam files
  # ---------------------------------------------------------------------------

  describe "load/0 — .beam tool files" do
    test "loads a valid .beam file" do
      tool = "ct_beam_#{uniq()}"
      {module, beam_path} = write_beam_tool!(dir(), tool, read_only: true)

      assert String.ends_with?(beam_path, ".beam")
      CustomTools.reload()

      entries = CustomTools.load()
      assert Map.has_key?(entries, tool)
      assert entries[tool].module == module
      assert entries[tool].schema.name == tool
      assert entries[tool].read_only? == true
      assert entries[tool].file == beam_path
    end
  end

  # ---------------------------------------------------------------------------
  # Failure handling / collisions
  # ---------------------------------------------------------------------------

  describe "failure handling and collisions" do
    test "an uncompilable file is skipped and reported; valid tools still load" do
      good = "ct_good_#{uniq()}"
      write_source_tool!(dir(), "#{good}.ex", good, read_only: true)

      broken = "broken_#{uniq()}.ex"

      write_raw!(dir(), broken, """
      defmodule CustomToolsBroken#{uniq()} do
        def schema, do: (1 +
      end
      """)

      # Compiler diagnostics (if any) go to stderr — keep test output clean.
      capture_io(:stderr, fn ->
        CustomTools.reload()

        assert CustomTools.known?(good)

        status = CustomTools.status()
        assert Enum.any?(status.ok, &(&1.name == good))

        assert Enum.any?(status.errors, fn %{file: file, reason: reason} ->
                 String.ends_with?(file, broken) and reason =~ "failed to compile/load"
               end)
      end)
    end

    test "a file defining no behaviour module is skipped and reported" do
      plain = "plain_#{uniq()}.ex"

      write_raw!(dir(), plain, """
      defmodule CustomToolsPlain#{uniq()} do
        def foo, do: :bar
      end
      """)

      CustomTools.reload()

      assert CustomTools.load() == %{}

      status = CustomTools.status()
      assert status.ok == []

      assert Enum.any?(status.errors, fn %{file: file, reason: reason} ->
               String.ends_with?(file, plain) and
                 reason =~ "no module exporting both schema/0 and execute/2"
             end)
    end

    test "a custom name colliding with a built-in tool is rejected and reported" do
      write_source_tool!(dir(), "collide_#{uniq()}.ex", "read_file", read_only: true)
      CustomTools.reload()

      refute CustomTools.known?("read_file")
      refute Map.has_key?(CustomTools.load(), "read_file")

      assert Enum.any?(CustomTools.status().errors, fn %{reason: reason} ->
               reason =~ "collides with a built-in tool"
             end)
    end

    test "duplicate custom names across files: first wins (basename order) + reported" do
      suffix = uniq()
      tool = "ct_dup_#{suffix}"
      {first_module, first_path} = write_source_tool!(dir(), "a_dup_#{suffix}.ex", tool)
      write_source_tool!(dir(), "b_dup_#{suffix}.ex", tool)

      CustomTools.reload()

      entries = CustomTools.load()
      assert map_size(entries) == 1
      assert entries[tool].file == first_path
      assert entries[tool].module == first_module

      assert Enum.any?(CustomTools.status().errors, fn %{reason: reason} ->
               reason =~ "duplicate custom tool name"
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Missing / empty directory
  # ---------------------------------------------------------------------------

  describe "missing / empty directory" do
    test "missing tools dir → load/0 == %{} and status/0 == %{ok: [], errors: []}" do
      refute File.exists?(dir())
      assert CustomTools.load() == %{}
      assert CustomTools.status() == %{ok: [], errors: []}
    end

    test "empty tools dir → load/0 == %{} and status/0 == %{ok: [], errors: []}" do
      File.mkdir_p!(dir())
      CustomTools.reload()

      assert CustomTools.load() == %{}
      assert CustomTools.status() == %{ok: [], errors: []}
    end
  end

  # ---------------------------------------------------------------------------
  # reload/0
  # ---------------------------------------------------------------------------

  describe "reload/0" do
    test "picks up newly written files" do
      assert CustomTools.load() == %{}

      first = "ct_reload_a_#{uniq()}"
      write_source_tool!(dir(), "#{first}.ex", first, read_only: true)
      assert CustomTools.reload() == :ok
      assert CustomTools.known?(first)

      second = "ct_reload_b_#{uniq()}"
      write_source_tool!(dir(), "#{second}.ex", second, read_only: true)
      assert CustomTools.reload() == :ok

      # Adding a file forces the loader to rebuild the whole set (it also
      # recompiles the first file) — silence the expected redefinition warning.
      capture_io(:stderr, fn ->
        assert CustomTools.known?(first)
        assert CustomTools.known?(second)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # read_only?/0 classification + execute/3
  # ---------------------------------------------------------------------------

  describe "read_only?/0 classification and execute/3" do
    test "classifies read-only vs write custom tools; unknown → not a write tool" do
      read = "ct_ro_#{uniq()}"
      write = "ct_rw_#{uniq()}"
      write_source_tool!(dir(), "#{read}.ex", read, read_only: true)
      write_source_tool!(dir(), "#{write}.ex", write, read_only: false)
      CustomTools.reload()

      refute CustomTools.write_tool?(read)
      assert CustomTools.write_tool?(write)
      refute CustomTools.write_tool?("definitely-not-a-tool-#{uniq()}")
      refute CustomTools.write_tool?(nil)
    end

    test "execute/3 returns {:ok, string} for a successful tool" do
      tool = "ct_exec_ok_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, read_only: true)
      CustomTools.reload()

      assert {:ok, out} = CustomTools.execute(tool, %{"x" => 1}, ctx())
      assert out =~ "custom-tool-ran"
    end

    test "execute/3 converts a raising tool into {:error, _} (never crashes)" do
      tool = "ct_exec_raise_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, raise: true)
      CustomTools.reload()

      assert {:error, msg} = CustomTools.execute(tool, %{}, ctx())
      assert msg =~ "raised"
    end

    test "execute/3 converts a throwing tool into {:error, _}" do
      tool = "ct_exec_throw_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, throw: true)
      CustomTools.reload()

      assert {:error, msg} = CustomTools.execute(tool, %{}, ctx())
      assert msg =~ "throw"
    end

    test "execute/3 converts a non-string return into {:error, _}" do
      tool = "ct_exec_nonstring_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, non_string: true)
      CustomTools.reload()

      assert {:error, msg} = CustomTools.execute(tool, %{}, ctx())
      assert msg =~ "non-string"
    end

    test "execute/3 returns :unknown for an unknown (or non-binary) name" do
      CustomTools.reload()
      assert CustomTools.execute("ct_missing_#{uniq()}", %{}, ctx()) == :unknown
      assert CustomTools.execute(nil, %{}, ctx()) == :unknown
    end

    test "a read_only?/0 that raises is treated as a WRITE tool (warning logged)" do
      tool = "ct_ro_raise_#{uniq()}"
      write_source_tool!(dir(), "#{tool}.ex", tool, read_only_raises: true)

      log =
        capture_log(fn ->
          CustomTools.reload()
          assert CustomTools.write_tool?(tool)
        end)

      assert log =~ "read_only?/0 raised"
    end
  end
end
