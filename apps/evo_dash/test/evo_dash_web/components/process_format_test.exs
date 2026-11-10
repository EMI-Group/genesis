defmodule EvoDashWeb.ProcessesLive.FormatTest do
  @moduledoc """
  Unit coverage for `EvoDashWeb.ProcessesLive.Format` over the managed-process
  contract:

    * `:runtime` — `:foreground | :background`
    * `:backend` — `:builtin | :systemd | :bwrap | :sandbox_exec | :none`,
      where `:builtin` ran INSIDE the BEAM (no OS process at all)
    * `:exit_code` — an integer only when an external OS process really exited
    * `:reason` — the single terminal cause (`:exited`, `:timeout`,
      `:invalid_arguments`, `:owner_died`, `:no_os_process`, `{:killed_by, a}`,
      `{:crashed, d}`), `nil` while live

  Pure + total: every helper is asserted over an `%EvoGit.ProcessManager.Execution{}`
  struct, a struct-shaped map, a STRING-keyed map and garbage, because records
  cross the PubSub/RPC boundary in all of those shapes and a struct does not
  implement Access. This module writes no app env and touches no PubSub, so it
  runs async.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.ProcessesLive.Format
  alias EvoGit.ProcessManager.Execution

  @started_at ~U[2026-11-09 10:00:00Z]
  @ended_at ~U[2026-11-09 10:02:05Z]

  # ---------------------------------------------------------------------------
  # runtime_label/1
  # ---------------------------------------------------------------------------

  describe "runtime_label/1" do
    test "labels the two runtime values" do
      assert Format.runtime_label(:foreground) == "Foreground"
      assert Format.runtime_label(:background) == "Background"
    end

    test "degrades totally for the retired, unknown and non-atom values" do
      # `:detached` no longer exists in the core contract: it has no clause of
      # its own and falls through to the atom fallback.
      assert Format.runtime_label(:detached) == "detached"
      assert Format.runtime_label(:something_else) == "something_else"
      assert Format.runtime_label(nil) == "—"
      assert Format.runtime_label("foreground") == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # backend_label/1
  # ---------------------------------------------------------------------------

  describe "backend_label/1" do
    test "distinguishes an in-process built-in from an unsandboxed external process" do
      assert Format.backend_label(:builtin) == "In-process"
      assert Format.backend_label(:none) == "Unsandboxed"
    end

    test "keeps the sandbox/legacy product names verbatim" do
      assert Format.backend_label(:systemd) == "systemd"
      assert Format.backend_label(:bwrap) == "bwrap"
      assert Format.backend_label(:sandbox_exec) == "sandbox-exec"
      assert Format.backend_label(:posix) == "posix"
      assert Format.backend_label(:windows) == "windows"
    end

    test "degrades totally for an unknown atom, nil and garbage" do
      assert Format.backend_label(:mystery_backend) == "mystery_backend"
      assert Format.backend_label(nil) == "—"
      assert Format.backend_label("builtin") == "—"
      assert Format.backend_label(42) == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Classification: builtin?/1, external?/1, sampleable?/1
  # ---------------------------------------------------------------------------

  describe "builtin?/1, external?/1 and sampleable?/1" do
    test "a :builtin record is in-process: no OS identity, nothing to sample" do
      execution = execution(backend: :builtin, os_pid: 4242, unit: "genesis-tool-1.service")

      assert Format.builtin?(execution)
      refute Format.external?(execution)
      # Even with OS fields present, a built-in is never sampled.
      refute Format.sampleable?(execution)
    end

    test "the string forms \"builtin\"/\"none\" classify identically" do
      builtin = string_keyed(%{backend: "builtin", os_pid: 4242})
      none = string_keyed(%{backend: "none", os_pid: 4242})

      assert Format.builtin?(builtin)
      refute Format.external?(builtin)
      refute Format.sampleable?(builtin)

      refute Format.builtin?(none)
      assert Format.external?(none)
      assert Format.sampleable?(none)
    end

    test "every non-builtin backend is external" do
      for backend <- [:systemd, :bwrap, :sandbox_exec, :none, :unknown_backend, nil] do
        record = execution(backend: backend)

        assert Format.external?(record), "expected #{inspect(backend)} to be external"
        refute Format.builtin?(record), "expected #{inspect(backend)} not to be builtin"
      end
    end

    test "sampling needs an external record AND an OS identity" do
      assert Format.sampleable?(execution(backend: :systemd, os_pid: 4242))
      assert Format.sampleable?(execution(backend: :bwrap, os_pid: nil, unit: "u.service"))

      assert Format.sampleable?(
               execution(backend: :none, os_pid: nil, unit: nil, job_id: "job-1")
             )

      refute Format.sampleable?(execution(backend: :none, os_pid: nil, unit: nil, job_id: nil))
      # A non-integer pid is not an OS identity.
      refute Format.sampleable?(execution(backend: :systemd, os_pid: "4242"))
      # A blank unit/job id is not an OS identity either.
      refute Format.sampleable?(execution(backend: :systemd, os_pid: nil, unit: "  ", job_id: ""))
    end

    test "garbage is never builtin or sampleable, and only a non-map is not external" do
      for garbage <- [nil, "junk", 42, [:builtin]] do
        refute Format.builtin?(garbage)
        refute Format.external?(garbage)
        refute Format.sampleable?(garbage)
      end

      # `external?/1` is exactly "a map that is not `builtin?/1`", so an empty
      # map counts as external — but it carries no OS identity, so it can never
      # be sampled.
      refute Format.builtin?(%{})
      assert Format.external?(%{})
      refute Format.sampleable?(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # reason_text/1 and reason_label/1
  # ---------------------------------------------------------------------------

  describe "reason_text/1" do
    test "every terminal reason has a canonical English label" do
      assert Format.reason_text(:exited) == "Exited"
      assert Format.reason_text(:timeout) == "Timeout"
      assert Format.reason_text(:invalid_arguments) == "Invalid arguments"
      assert Format.reason_text(:owner_died) == "Owner died"
      assert Format.reason_text(:no_os_process) == "No OS process"
    end

    test "parameterized reasons include their payload" do
      assert Format.reason_text({:killed_by, :operator}) == "Killed by operator"
      assert Format.reason_text({:killed_by, "operator"}) == "Killed by operator"
      assert Format.reason_text({:killed_by, 7}) == "Killed by 7"
      assert Format.reason_text({:crashed, :segfault}) == "Crashed: segfault"
      assert Format.reason_text({:crashed, %{message: "boom"}}) =~ "Crashed: "
    end

    test "nil and unknown terms render as text instead of raising" do
      assert Format.reason_text(nil) == "—"
      assert Format.reason_text(:mystery) == "mystery"
      assert Format.reason_text({:weird, 1, 2}) == inspect({:weird, 1, 2})
      assert Format.reason_text(%{code: 9}) =~ "code: 9"
    end
  end

  describe "reason_label/1" do
    test "reads the record through reason_text/1, in every map shape" do
      assert Format.reason_label(execution(reason: {:killed_by, "operator"})) ==
               "Killed by operator"

      assert Format.reason_label(string_keyed(execution(reason: :timeout))) == "Timeout"
      assert Format.reason_label(execution(reason: nil)) == "—"
    end

    test "garbage renders a placeholder" do
      assert Format.reason_label(nil) == "—"
      assert Format.reason_label("junk") == "—"
      assert Format.reason_label(%{}) == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # exit_label/1 — the table's Exit column
  # ---------------------------------------------------------------------------

  describe "exit_label/1" do
    test "an integer exit code always wins" do
      assert Format.exit_label(execution(exit_code: 0, reason: :exited)) == "0"

      assert Format.exit_label(execution(exit_code: 137, reason: {:killed_by, :operator})) ==
               "137"

      assert Format.exit_label(string_keyed(execution(exit_code: 1, reason: :exited))) == "1"
    end

    test "a non-:exited reason without a code renders the reason label" do
      assert Format.exit_label(execution(exit_code: nil, reason: :timeout)) == "Timeout"
      assert Format.exit_label(execution(exit_code: nil, reason: :owner_died)) == "Owner died"

      assert Format.exit_label(execution(exit_code: nil, reason: :invalid_arguments)) ==
               "Invalid arguments"

      assert Format.exit_label(execution(exit_code: nil, reason: :no_os_process)) ==
               "No OS process"

      assert Format.exit_label(execution(exit_code: nil, reason: {:killed_by, "operator"})) ==
               "Killed by operator"

      assert Format.exit_label(execution(exit_code: nil, reason: {:crashed, :segfault})) ==
               "Crashed: segfault"

      assert Format.exit_label(string_keyed(execution(reason: :timeout, exit_code: nil))) ==
               "Timeout"
    end

    test "a plain exit without a code and a live row stay placeholders" do
      assert Format.exit_label(execution(exit_code: nil, reason: :exited)) == "—"
      assert Format.exit_label(execution(exit_code: nil, reason: nil)) == "—"
    end

    test "garbage renders a placeholder" do
      assert Format.exit_label(nil) == "—"
      assert Format.exit_label(%{}) == "—"
      assert Format.exit_label("junk") == "—"
    end
  end

  # `exit_code_label/1` stays the RAW integer-or-dash helper the detail panel
  # uses, independent of the reason.
  describe "exit_code_label/1" do
    test "is the raw integer code only" do
      assert Format.exit_code_label(execution(exit_code: 0)) == "0"
      assert Format.exit_code_label(execution(exit_code: nil, reason: :timeout)) == "—"
      assert Format.exit_code_label(string_keyed(execution(exit_code: 9))) == "9"
      assert Format.exit_code_label(nil) == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # OS-derived figures: a built-in execution renders placeholders
  # ---------------------------------------------------------------------------

  describe "OS-derived figures of a built-in execution" do
    test "target, uptime, CPU and memory are all placeholders" do
      execution =
        execution(
          backend: :builtin,
          os_pid: 4242,
          unit: "genesis-tool-1.service",
          job_id: "job-1",
          started_at: @started_at,
          ended_at: @ended_at,
          stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800}
        )

      assert Format.target_label(execution) == "—"
      assert Format.uptime(execution, @ended_at) == "—"
      assert Format.uptime(execution) == "—"
      assert Format.cpu_label(execution) == "—"
      assert Format.memory_label(execution) == "—"
    end

    test "the same record as a STRING-keyed map renders placeholders too" do
      execution =
        string_keyed(%{
          backend: "builtin",
          os_pid: 4242,
          unit: "genesis-tool-1.service",
          started_at: @started_at,
          stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800}
        })

      assert Format.target_label(execution) == "—"
      assert Format.uptime(execution, @ended_at) == "—"
      assert Format.cpu_label(execution) == "—"
      assert Format.memory_label(execution) == "—"
    end
  end

  describe "OS-derived figures of an external execution" do
    test "keep the real unit/pid/job target, uptime, CPU and memory" do
      execution =
        execution(
          backend: :systemd,
          os_pid: 4242,
          unit: "genesis-tool-1.service",
          started_at: @started_at,
          ended_at: @ended_at,
          stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800}
        )

      assert Format.target_label(execution) == "unit genesis-tool-1.service"
      assert Format.uptime(execution, @ended_at) == "2m 05s"
      assert Format.cpu_label(execution) == "12.3%"
      assert Format.memory_label(execution) == "50.0 MB"
    end

    test "fall back to the pid, then the job id, then a placeholder" do
      assert Format.target_label(execution(backend: :none, unit: nil, os_pid: 4242)) == "pid 4242"

      assert Format.target_label(
               execution(backend: :none, unit: nil, os_pid: nil, job_id: "job-1")
             ) ==
               "job job-1"

      assert Format.target_label(execution(backend: :none, unit: nil, os_pid: nil, job_id: nil)) ==
               "—"
    end

    test "garbage renders placeholders" do
      assert Format.target_label(nil) == "—"
      assert Format.uptime(nil) == "—"
      assert Format.cpu_label(nil) == "—"
      assert Format.memory_label(nil) == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp execution(overrides) do
    struct!(
      %Execution{
        id: "proc-1",
        kind: :tool_call,
        tool: "bash",
        command: "mix test",
        label: nil,
        agent_id: 101,
        task_id: "task-1",
        owner_pid: nil,
        cwd: "/tmp/repo",
        repo_root: "/srv/repo",
        backend: :systemd,
        runtime: :foreground,
        status: :running,
        os_pid: nil,
        unit: nil,
        job_id: nil,
        exit_code: nil,
        reason: nil,
        inserted_at: @started_at,
        started_at: @started_at,
        ended_at: nil,
        stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800},
        control_log: []
      },
      overrides
    )
  end

  # The SAME record with string keys — the shape a foreign/older node's payload
  # can take. `Map.delete/2` drops the `:__struct__` marker so both a struct and
  # a plain map convert the same way.
  defp string_keyed(record) when is_map(record) do
    record
    |> Map.delete(:__struct__)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end
end
