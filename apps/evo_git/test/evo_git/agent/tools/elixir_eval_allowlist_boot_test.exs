defmodule EvoGit.Agent.Tools.ElixirEval.AllowlistBootTest do
  @moduledoc """
  Release-boot safety of the `elixir_eval` allowlist wrappers.

  A `-mode embedded` release primLoads modules and runs every `@on_load` handler
  while `Code.ensure_loaded/1` can still answer `{:error, :embedded}` for a
  module nobody has loaded yet, so an `@on_load` that loads a sibling module
  takes kernel down with `on_load_function_failed` (the BEAM exits 1). The
  wrappers therefore only materialize their compile-time alias-segment atoms in
  `@on_load`, and the generated `*Allowlist.Base` specs are loaded at the
  `Engine` parse chokepoint by `ReadAllowlist.ensure_initialized/0` and
  `WriteAllowlist.ensure_initialized/0`.

  Both halves run inside a THROWAWAY VM (`System.cmd("elixir", ...)`) so the
  probe can observe modules that are not loaded yet and load them itself
  without touching this suite's code server. Embedded mode cannot be requested
  from the stock CLI (OTP 29 has no `code:set_mode/1`, and
  `--erl "-mode embedded"` cannot boot an `-e` script), so the probe pins the
  invariant that makes embedded boot safe instead of the boot mode itself.

  `async: true`: the test mutates no BEAM-global state — it only spawns one OS
  child and reads the compiled code path.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{ReadAllowlist, WriteAllowlist}

  # A probe that faithfully mirrors the boot-safe contract; a regression (any
  # module load in an `@on_load`, e.g. the pre-fix `Code.ensure_loaded!` on the
  # generated Base spec) fails it with an explicit message and exit status 1.
  @probe ~S"""
  # Throwaway-VM probe for the elixir_eval allowlist wrappers' release-boot safety.
  stage = System.argv() |> List.first() |> to_string()

  read = EvoGit.Agent.Tools.ElixirEval.ReadAllowlist
  write = EvoGit.Agent.Tools.ElixirEval.WriteAllowlist
  read_base = EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base
  write_base = EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base

  fail = fn message ->
    IO.puts(:stderr, "allowlist boot probe failed: " <> message)
    System.halt(1)
  end

  alias_atom? = fn name ->
    try do
      _ = :erlang.binary_to_existing_atom(name, :utf8)
      true
    rescue
      ArgumentError -> false
    end
  end

  unloaded = fn {name, module} ->
    case :code.is_loaded(module) do
      false -> :ok
      status -> fail.("expected #{name} to stay unloaded, got: #{inspect(status)}")
    end
  end

  loaded = fn {name, module} ->
    case :code.is_loaded(module) do
      false -> fail.("expected #{name} to be loaded")
      _ -> :ok
    end
  end

  prepare = fn module ->
    path = :code.which(module)

    unless is_list(path) or is_binary(path) do
      fail.("#{inspect(module)} is not on the code path")
    end

    {module, path, File.read!(path)}
  end

  # The pinned invariant: an `@on_load` runs while the code server may refuse
  # every load (`{:error, :embedded}`), so it must materialize its compile-time
  # atoms and load NOTHING else. Loading the wrapper has to load exactly itself.
  load_only_itself = fn {module, path, binary} ->
    before = :erlang.loaded()

    case :code.load_binary(module, path, binary) do
      {:module, ^module} -> :ok
      other -> fail.("loading #{inspect(module)} did not succeed: #{inspect(other)}")
    end

    newly_loaded = :erlang.loaded() -- before

    unless newly_loaded == [module] do
      fail.(
        "loading #{inspect(module)} must load no other module, " <>
          "but the newly loaded modules were: #{inspect(newly_loaded)}"
      )
    end
  end

  run_on_load = fn ->
    unless alias_atom?.("Read") == false do
      fail.("precondition: atom :Read already exists")
    end

    unless alias_atom?.("Write") == false do
      fail.("precondition: atom :Write already exists")
    end

    unloaded.({"ReadAllowlist.Base", read_base})
    unloaded.({"WriteAllowlist.Base", write_base})

    load_only_itself.(prepare.(read))
    unloaded.({"ReadAllowlist.Base", read_base})
    unloaded.({"WriteAllowlist.Base", write_base})

    unless alias_atom?.("Read") do
      fail.("loading ReadAllowlist did not materialize the alias atom :Read")
    end

    unless alias_atom?.("Write") == false do
      fail.("loading ReadAllowlist materialized the write-only alias atom :Write")
    end

    load_only_itself.(prepare.(write))
    unloaded.({"ReadAllowlist.Base", read_base})
    unloaded.({"WriteAllowlist.Base", write_base})

    unless alias_atom?.("Write") do
      fail.("loading WriteAllowlist did not materialize the alias atom :Write")
    end
  end

  run_chokepoint = fn ->
    unloaded.({"ReadAllowlist.Base", read_base})
    unloaded.({"WriteAllowlist.Base", write_base})

    # Write is the FIRST tier initialized in this cold VM: its spec extends the
    # read spec, so the chokepoint has to load both generated Base allowlists.
    case write.ensure_initialized() do
      :ok -> :ok
      {:error, reason} -> fail.("WriteAllowlist.ensure_initialized/0 failed: #{inspect(reason)}")
    end

    loaded.({"ReadAllowlist.Base", read_base})
    loaded.({"WriteAllowlist.Base", write_base})

    case read.ensure_initialized() do
      :ok -> :ok
      {:error, reason} -> fail.("ReadAllowlist.ensure_initialized/0 failed: #{inspect(reason)}")
    end

    read_atoms = EvoGit.Agent.Tools.ElixirEval.AllowlistAliases.atoms(:read)
    write_atoms = EvoGit.Agent.Tools.ElixirEval.AllowlistAliases.atoms(:write)
    read_atom = :erlang.binary_to_existing_atom("Read", :utf8)
    write_atom = :erlang.binary_to_existing_atom("Write", :utf8)

    unless :lists.member(read_atom, read_atoms) do
      fail.("the read alias atoms do not contain :Read")
    end

    unless :lists.member(write_atom, write_atoms) do
      fail.("the write alias atoms do not contain :Write")
    end

    unless write_atoms -- read_atoms == [write_atom] do
      fail.(
        "the write-only alias atoms are #{inspect(write_atoms -- read_atoms)}, " <>
          "expected [:Write]"
      )
    end
  end

  case stage do
    "on_load" -> run_on_load.()
    "chokepoint" -> run_chokepoint.()
    other -> fail.("unknown probe stage #{inspect(other)}")
  end

  IO.puts("allowlist boot probe ok (" <> stage <> ")")
  """

  @probe_timeout 60_000

  setup_all do
    # A probe against a missing beam would fail with a confusing message: pin
    # that every module the throwaway VM loads is compiled on this code path.
    Enum.each([ReadAllowlist, WriteAllowlist, Dune.Allowlist], &ebin_dir!/1)
    :ok
  end

  describe "a cold-BEAM wrapper @on_load" do
    test "loads only the wrapper itself and materializes only its own alias atoms" do
      assert_probe!(:on_load)
    end
  end

  describe "the parse chokepoint" do
    test "ensure_initialized/0 loads both Base allowlists, write-first on a cold BEAM" do
      assert_probe!(:chokepoint)
    end
  end

  defp assert_probe!(stage) do
    {output, status} = run_probe(stage)

    assert status == 0,
           "isolated allowlist probe (#{stage}) failed with exit status #{status}:\n#{output}"

    assert output =~ "allowlist boot probe ok (#{stage})"
  end

  defp run_probe(stage) do
    elixir = System.find_executable("elixir") || flunk("the `elixir` executable is not on PATH")

    args = [
      "-pa",
      ebin_dir!(ReadAllowlist),
      "-pa",
      ebin_dir!(Dune.Allowlist),
      "-e",
      @probe,
      "--",
      Atom.to_string(stage)
    ]

    task = Task.async(fn -> System.cmd(elixir, args, stderr_to_stdout: true) end)

    case Task.yield(task, @probe_timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)

        flunk(
          "the isolated allowlist probe (#{stage}) did not finish within #{@probe_timeout} ms"
        )
    end
  end

  # Derive the code path from the compiled beams, so any worktree and MIX_ENV works.
  defp ebin_dir!(module) do
    case :code.which(module) do
      path when is_list(path) ->
        path |> List.to_string() |> Path.dirname()

      path when is_binary(path) ->
        Path.dirname(path)

      other ->
        flunk("#{inspect(module)} is not compiled on the code path (got #{inspect(other)})")
    end
  end
end
