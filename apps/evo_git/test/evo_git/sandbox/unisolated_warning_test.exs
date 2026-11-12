defmodule EvoGit.Sandbox.UnisolatedWarningMappingTest do
  # Pure mapping + production-resolution assertions only: no app env, no latch.
  use ExUnit.Case, async: true

  alias EvoGit.{Platform, Sandbox}

  describe "warning_for/3 — the pure warn/no-warn decision" do
    test "mode enabled + no isolating backend → warns" do
      message = Sandbox.warning_for(:enabled, :auto, false)

      assert is_binary(message)
      assert message =~ "Sandbox: "
      assert message =~ "NO OS-LEVEL ISOLATION"
      assert message =~ "UNISOLATED"
    end

    test "mode enabled + an explicitly demanded backend that is unusable → warns" do
      assert is_binary(Sandbox.warning_for(:enabled, :systemd, false))
      assert is_binary(Sandbox.warning_for(:enabled, :bwrap, false))
    end

    test "an explicit backend demanded in auto mode + unusable → warns" do
      # Demanding `[sandbox] backend = "bwrap"` is a request for isolation even
      # though the mode itself is only "auto".
      assert is_binary(Sandbox.warning_for(:auto, :bwrap, false))
    end

    test "mode disabled + no backend → no warning (deliberate, must stay quiet)" do
      assert Sandbox.warning_for(:disabled, :auto, false) == nil
      assert Sandbox.warning_for(:disabled, :bwrap, false) == nil
    end

    test "mode enabled + an isolating backend (e.g. Linux/systemd-run) → no warning" do
      assert Sandbox.warning_for(:enabled, :auto, true) == nil
      assert Sandbox.warning_for(:enabled, :systemd, true) == nil
      assert Sandbox.warning_for(:auto, :bwrap, true) == nil
    end

    test "auto mode + auto backend falling back to no sandbox → no warning" do
      # The documented unsupported-platform fallback (e.g. Windows with
      # mode = "auto") is not a misconfiguration.
      assert Sandbox.warning_for(:auto, :auto, false) == nil
    end

    test "the warning names the actionable fixes" do
      message = Sandbox.warning_for(:enabled, :auto, false)

      assert message =~ "[sandbox] backend"
      assert message =~ "[sandbox] mode = \"disabled\""
      assert message =~ to_string(Platform.os())
    end
  end

  describe "backend_reason/0 — production resolution" do
    test "returns a non-empty, state-consistent human-readable string" do
      reason = Sandbox.backend_reason()

      assert is_binary(reason)
      assert reason != ""

      if Sandbox.enabled?() do
        assert reason =~ "sandbox active"
        refute reason =~ "UNISOLATED"
      else
        assert reason =~ "UNISOLATED"
      end
    end
  end
end

defmodule EvoGit.Sandbox.UnisolatedWarningLatchTest do
  # async: false is REQUIRED: this module mutates BEAM-global state —
  # the `:persistent_term` once-only latch
  # `{EvoGit.Sandbox, :unisolated_warning_emitted}` plus the call-time seams
  # `:evo_git, :sandbox_mode_override` / `:evo_git, :sandbox_backend_override`,
  # which any concurrently running module's sandbox dispatch would observe.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Sandbox

  defmodule IsolatingBackend do
    # A stand-in for a genuinely active OS sandbox (Linux/macOS backends report
    # `enabled?/0 == false` under `MIX_ENV=test`, so the healthy branch needs one).
    def enabled?, do: true
  end

  setup do
    Sandbox.reset_unisolated_warning()

    on_exit(fn ->
      Application.delete_env(:evo_git, :sandbox_mode_override)
      Application.delete_env(:evo_git, :sandbox_backend_override)
      Sandbox.reset_unisolated_warning()
    end)

    :ok
  end

  defp demand_isolation_without_a_backend do
    Application.put_env(:evo_git, :sandbox_mode_override, :enabled)
    Application.put_env(:evo_git, :sandbox_backend_override, EvoGit.Sandbox.None)
  end

  describe "backend_reason/0 — degraded cases" do
    test "mode enabled + None reports NO isolation, the platform and the fix" do
      demand_isolation_without_a_backend()

      reason = Sandbox.backend_reason()

      assert reason =~ "NO OS-LEVEL ISOLATION"
      assert reason =~ "on #{EvoGit.Platform.os()}"
      assert reason =~ ~s([sandbox] mode = "enabled")
      assert reason =~ "[sandbox] backend"
      assert reason =~ "UNISOLATED"
    end

    test "mode disabled reports a config-disabled sandbox, not a misconfiguration" do
      Application.put_env(:evo_git, :sandbox_mode_override, :disabled)
      Application.put_env(:evo_git, :sandbox_backend_override, EvoGit.Sandbox.None)

      reason = Sandbox.backend_reason()

      assert reason =~ "disabled by configuration"
      refute reason =~ "NO OS-LEVEL ISOLATION"
    end

    test "an isolating backend reports the active sandbox by name" do
      Application.put_env(:evo_git, :sandbox_mode_override, :enabled)
      Application.put_env(:evo_git, :sandbox_backend_override, IsolatingBackend)

      assert Sandbox.backend_reason() =~ "sandbox active"
    end
  end

  describe "warn_if_unisolated/0 — the once-only latch" do
    test "warns exactly once until the latch is reset" do
      demand_isolation_without_a_backend()

      log =
        capture_log(fn ->
          assert Sandbox.warn_if_unisolated() == :ok
          assert Sandbox.warn_if_unisolated() == :ok
          assert Sandbox.warn_if_unisolated() == :ok
        end)

      assert log =~ "UNISOLATED"
      assert length(Regex.scan(~r/NO OS-LEVEL ISOLATION/, log)) == 1
    end

    test "after a reset it warns again (the reset seam itself works)" do
      demand_isolation_without_a_backend()

      capture_log(fn -> Sandbox.warn_if_unisolated() end)
      Sandbox.reset_unisolated_warning()

      log = capture_log(fn -> Sandbox.warn_if_unisolated() end)

      assert log =~ "NO OS-LEVEL ISOLATION"
    end
  end

  describe "dispatch entry points trip the warning" do
    test "run/4, run_with_partial/5 and spawn_detached/1 each warn on a fresh latch" do
      demand_isolation_without_a_backend()
      tmp = System.tmp_dir!()

      dispatches = [
        {"run/4", fn -> Sandbox.run(tmp, "echo", ["hi"]) end},
        {"run_with_partial/5",
         fn -> Sandbox.run_with_partial(tmp, "echo", ["hi"], nil, 10_000) end},
        {"spawn_detached/1", fn -> Sandbox.spawn_detached(%{}) end}
      ]

      for {label, dispatch} <- dispatches do
        Sandbox.reset_unisolated_warning()
        log = capture_log(dispatch)

        assert log =~ "NO OS-LEVEL ISOLATION",
               "#{label} must emit the unisolated warning on a fresh latch"
      end
    end
  end

  describe "no noise" do
    test "a genuinely isolating backend never warns, even in mode enabled" do
      Application.put_env(:evo_git, :sandbox_mode_override, :enabled)
      Application.put_env(:evo_git, :sandbox_backend_override, IsolatingBackend)

      log = capture_log(fn -> Sandbox.warn_if_unisolated() end)

      assert log == ""
    end

    test "mode disabled + no backend never warns (deliberate choice)" do
      Application.put_env(:evo_git, :sandbox_mode_override, :disabled)
      Application.put_env(:evo_git, :sandbox_backend_override, EvoGit.Sandbox.None)

      log = capture_log(fn -> Sandbox.warn_if_unisolated() end)

      assert log == ""
    end
  end
end
