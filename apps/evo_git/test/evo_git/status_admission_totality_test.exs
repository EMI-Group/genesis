defmodule EvoGit.StatusAdmissionTotalityTest do
  @moduledoc """
  The P3 status-admission INVARIANT, asserted once for every status list the
  runtime exposes.

  `:awaiting_input` is the NON-TERMINAL status of an idle interactive session:
  the wrapper is alive on this node, the lease is still renewable and the task
  is still cancellable/closeable, but no exchange is running (no worker, no LLM
  slot, no tool slot, no timer). It must therefore be admitted everywhere
  `:running` is admitted for LIVENESS purposes:

    * liveness/cancellation/lease sets — a waiting session must stay visible,
      cancellable, force-killable and lease-renewable exactly like a running
      task;
    * the boot/lease projections (`Lightweight.live_statuses/0`,
      `lease_statuses/0`, STRING lists) — an idle session must never be deleted
      by `clear_finished_tasks`, and a session whose wrapper is GONE must be
      reconciled on boot instead of waiting forever;
    * the closed atom whitelists (`Codec.known_statuses/0`,
      `Types.Status.statuses/0`) — the value must decode to itself, never to
      `nil`/`:pending`;
    * the scheduler's own `SchedMeta` enumerations — a session's status/phases
      must be reported and its cancel path must remain reachable;
    * the evaluation (`elixir_eval`) admission sets owned by
      `Agent.Tools.ElixirEval.Broker` (`cancel_statuses/0`,
      `force_kill_statuses/0`), `Agent.Tools.ElixirEval.Authorization`
      (`accepted_agent_statuses/0`, `accepted_agent_task_statuses/0`) and the
      `Agent.Tools.ElixirEval.Projection` scalar whitelists (`statuses/0` for
      task rows, `agent_statuses/0` for `list_agents` agent rows) — an idle
      interactive session must stay inspectable, drivable, cancellable,
      force-killable and VISIBLE (with its real status) through the Assistant's
      task facades.

  The rule is enforced by the `@lists` data table below: for EVERY entry that
  advertises `:running`, the same list must also advertise `:awaiting_input`.
  Adding a new status enumeration is a ONE-LINE change to that table (and a
  list that gains `:running` without `:awaiting_input` fails here, even if its
  table row still says `:not_running`, because the tag itself is checked).

  ## The deliberate exemptions

  `@exempt_lists` pins any set that admits `:running` but DELIBERATELY not
  `:awaiting_input`, each with its reason; there is no such set today, so the
  pairing rule currently applies to every `:running`-bearing list without
  exception.

  `@pinned_absences` pins the one set whose ABSENCE of `:awaiting_input` is
  intentional without being a live-session set:
  `EvoGit.TaskRegistry.finalizing_ignored_statuses/0`. Closing an idle session
  legitimately moves it through `:finalizing`, so the statuses that IGNORE a
  `{:task_updated, id, :finalizing, node}` broadcast are the already-terminal
  and mid-graceful-cancel ones — a set that admits neither `:running` nor
  `:awaiting_input`.

  There is deliberately NO "busy for update/idle purposes" list that pairs
  `:running` with the exclusion of `:awaiting_input`: the task in-flight set
  (`TaskRegistry.active_statuses/0`) is documented as the LIVE set, never the
  busy one, and admits `:awaiting_input`; the scheduler owns "idle" separately
  in `SchedMeta.idle_statuses/0`, which is `[:awaiting_input]` and never
  `:blocked`.

  Every accessor below is a PURE function over module attributes, so nothing
  here mutates BEAM-global state and the module runs `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval.Authorization
  alias EvoGit.Agent.Tools.ElixirEval.Broker
  alias EvoGit.Agent.Tools.ElixirEval.Projection
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.CLI
  alias EvoGit.CommandApproval
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Lightweight
  alias EvoGit.Store.Types.Status
  alias EvoGit.TaskRegistry
  alias EvoGit.TaskRegistry.Lease

  @running :running
  @awaiting_input :awaiting_input

  # {label, {module, function}, :atom | :string, :running | :not_running}
  #
  # `:running` says the list is a LIVE-session set and must admit
  # `:awaiting_input`; `:not_running` says it is pinned as a set that does not
  # admit `:running` at all (so the pairing rule is vacuous, and the tag is
  # checked so it cannot silently become a live set).
  @lists [
    # ── task lifecycle (EvoGit.TaskRegistry) ──
    {"TaskRegistry.terminal_statuses/0", {TaskRegistry, :terminal_statuses}, :atom, :not_running},
    {"TaskRegistry.killable_statuses/0", {TaskRegistry, :killable_statuses}, :atom, :running},
    {"TaskRegistry.gracefully_cancellable_statuses/0",
     {TaskRegistry, :gracefully_cancellable_statuses}, :atom, :running},
    {"TaskRegistry.unstartable_statuses/0", {TaskRegistry, :unstartable_statuses}, :atom,
     :not_running},
    {"TaskRegistry.finalizing_ignored_statuses/0", {TaskRegistry, :finalizing_ignored_statuses},
     :atom, :not_running},
    {"TaskRegistry.active_statuses/0", {TaskRegistry, :active_statuses}, :atom, :running},
    # ── lease heartbeat / sweep (EvoGit.TaskRegistry.Lease) ──
    {"TaskRegistry.Lease.renewed_statuses/0", {Lease, :renewed_statuses}, :atom, :running},
    {"TaskRegistry.Lease.leaked_statuses/0", {Lease, :leaked_statuses}, :atom, :running},
    # ── SQL projections (STRING lists) ──
    {"Store.Operations.Lightweight.live_statuses/0", {Lightweight, :live_statuses}, :string,
     :running},
    {"Store.Operations.Lightweight.lease_statuses/0", {Lightweight, :lease_statuses}, :string,
     :running},
    # ── persisted wire-value whitelists ──
    {"Store.Codec.known_statuses/0", {Codec, :known_statuses}, :atom, :running},
    {"Store.Types.Status.statuses/0", {Status, :statuses}, :atom, :running},
    # ── command approval / evaluation admission ──
    {"CommandApproval.denying_task_statuses/0", {CommandApproval, :denying_task_statuses}, :atom,
     :not_running},
    {"CommandApproval.eval_active_task_statuses/0", {CommandApproval, :eval_active_task_statuses},
     :atom, :running},
    # ── evaluation (elixir_eval) capability + projection admission ──
    {"Agent.Tools.ElixirEval.Broker.cancel_statuses/0", {Broker, :cancel_statuses}, :atom,
     :running},
    {"Agent.Tools.ElixirEval.Broker.force_kill_statuses/0", {Broker, :force_kill_statuses}, :atom,
     :running},
    {"Agent.Tools.ElixirEval.Authorization.accepted_agent_statuses/0",
     {Authorization, :accepted_agent_statuses}, :atom, :running},
    {"Agent.Tools.ElixirEval.Authorization.accepted_agent_task_statuses/0",
     {Authorization, :accepted_agent_task_statuses}, :atom, :running},
    # The Assistant's scalar projections must not hide a waiting session: a
    # task row keeps its `:awaiting_input` status and `list_agents` reports it.
    {"Agent.Tools.ElixirEval.Projection.statuses/0", {Projection, :statuses}, :atom, :running},
    {"Agent.Tools.ElixirEval.Projection.agent_statuses/0", {Projection, :agent_statuses}, :atom,
     :running},
    # ── CLI foreground wait classification ──
    {"CLI.halted_wait_statuses/0", {CLI, :halted_wait_statuses}, :atom, :not_running},
    {"CLI.terminal_statuses/0", {CLI, :terminal_statuses}, :atom, :not_running},
    # ── scheduler agent enumerations ──
    {"AgentScheduler.SchedMeta.statuses/0", {SchedMeta, :statuses}, :atom, :running},
    {"AgentScheduler.SchedMeta.phases/0", {SchedMeta, :phases}, :atom, :running},
    {"AgentScheduler.SchedMeta.live_statuses/0", {SchedMeta, :live_statuses}, :atom, :running},
    {"AgentScheduler.SchedMeta.idle_statuses/0", {SchedMeta, :idle_statuses}, :atom,
     :not_running},
    {"AgentScheduler.SchedMeta.cancel_reachable_statuses/0",
     {SchedMeta, :cancel_reachable_statuses}, :atom, :running}
  ]

  # {label, {module, function}, :atom | :string, reason} — a list that admits
  # `:running` but DELIBERATELY does not admit `:awaiting_input`. Empty today
  # (every running-bearing list pairs them); the mechanism exists so a future
  # intentional asymmetry is pinned WITH its reason instead of silently
  # weakening the sweep below.
  @exempt_lists []

  # The pinned "absence is deliberate" sets that are not running-bearing live
  # sets but would otherwise look like a forgotten admission.
  @pinned_absences [
    {"TaskRegistry.finalizing_ignored_statuses/0", {TaskRegistry, :finalizing_ignored_statuses},
     :atom,
     "closing an idle session legitimately moves it through :finalizing, so ONLY " <>
       "already-terminal / mid-graceful-cancel rows ignore that broadcast"}
  ]

  describe "status-list totality (:running ⇒ :awaiting_input)" do
    test "every exposed list that admits :running also admits :awaiting_input" do
      for {label, {module, function}, kind, _category} <- @lists,
          not exempt?(label) do
        statuses = assert_list!(label, module, function)

        if marker(kind, @running) in statuses do
          assert marker(kind, @awaiting_input) in statuses,
                 "#{label} admits #{inspect(marker(kind, @running))} but NOT " <>
                   "#{inspect(marker(kind, @awaiting_input))}. An idle interactive " <>
                   "session must stay exactly as visible/renewable/cancellable as a " <>
                   "running task; either add it to this list or pin it in " <>
                   "@exempt_lists with a reason.\nGot: #{inspect(statuses)}"
        end
      end
    end

    test "the table's :running / :not_running tags match reality" do
      for {label, {module, function}, kind, category} <- @lists do
        statuses = assert_list!(label, module, function)
        admits_running? = marker(kind, @running) in statuses

        case category do
          :running ->
            assert admits_running?,
                   "#{label} is tagged :running (a live-session set) but does not " <>
                     "admit #{inspect(marker(kind, @running))}.\nGot: #{inspect(statuses)}"

          :not_running ->
            refute admits_running?,
                   "#{label} is tagged :not_running but now admits " <>
                     "#{inspect(marker(kind, @running))}; re-classify the table row " <>
                     "(and make sure #{inspect(marker(kind, @awaiting_input))} follows).\n" <>
                     "Got: #{inspect(statuses)}"
        end
      end
    end

    test "the sweep is not vacuous — the core live-session sets admit both statuses" do
      # A guard against a future refactor that drops :running from every list:
      # the implication above would then pass trivially.
      live_rows =
        Enum.filter(@lists, fn {_label, _mfa, _kind, category} -> category == :running end)

      assert length(live_rows) >= 10

      for label <- [
            "TaskRegistry.killable_statuses/0",
            "TaskRegistry.gracefully_cancellable_statuses/0",
            "TaskRegistry.active_statuses/0",
            "TaskRegistry.Lease.renewed_statuses/0",
            "TaskRegistry.Lease.leaked_statuses/0",
            "Store.Operations.Lightweight.live_statuses/0",
            "Store.Operations.Lightweight.lease_statuses/0",
            "Store.Codec.known_statuses/0",
            "Store.Types.Status.statuses/0",
            "CommandApproval.eval_active_task_statuses/0",
            "Agent.Tools.ElixirEval.Broker.cancel_statuses/0",
            "Agent.Tools.ElixirEval.Broker.force_kill_statuses/0",
            "Agent.Tools.ElixirEval.Authorization.accepted_agent_statuses/0",
            "Agent.Tools.ElixirEval.Authorization.accepted_agent_task_statuses/0",
            "Agent.Tools.ElixirEval.Projection.statuses/0",
            "Agent.Tools.ElixirEval.Projection.agent_statuses/0",
            "AgentScheduler.SchedMeta.statuses/0",
            "AgentScheduler.SchedMeta.live_statuses/0",
            "AgentScheduler.SchedMeta.cancel_reachable_statuses/0"
          ] do
        {kind, statuses} = statuses_for!(label)
        assert marker(kind, @running) in statuses, "#{label} must admit :running"
        assert marker(kind, @awaiting_input) in statuses, "#{label} must admit :awaiting_input"
      end
    end
  end

  describe "pinned deliberate absences" do
    test "an exempt list does not admit :awaiting_input (with its reason on record)" do
      for {_label, {module, function}, kind, reason} <- @exempt_lists do
        statuses = apply(module, function, [])
        refute marker(kind, @awaiting_input) in statuses, "exemption reason: #{reason}"
      end

      for {label, {module, function}, kind, reason} <- @pinned_absences do
        statuses = assert_list!(label, module, function)

        refute marker(kind, @awaiting_input) in statuses,
               "#{label} is pinned as a deliberate absence but now admits " <>
                 ":awaiting_input (#{reason}); delete the pin if the change is intended"

        refute marker(kind, @running) in statuses,
               "#{label} is not a live-session set; it must not admit :running either"
      end
    end
  end

  describe "SchedMeta idle semantics" do
    test "idle is :awaiting_input and never :blocked" do
      idle = SchedMeta.idle_statuses()

      assert :awaiting_input in idle
      refute :blocked in idle

      # `:blocked` keeps its own meaning ("parked in an LLM/tool slot queue"),
      # so it is still a legitimate STATUS — it is just never the idle one.
      assert :blocked in SchedMeta.statuses()
    end

    test "the idle set is a subset of every live-session enumeration" do
      for fun <- [:statuses, :live_statuses, :cancel_reachable_statuses] do
        statuses = apply(SchedMeta, fun, [])

        assert Enum.all?(SchedMeta.idle_statuses(), &(&1 in statuses)),
               "SchedMeta.#{fun}/0 must admit every idle status"
      end
    end
  end

  describe "wire-value whitelists" do
    test "Codec.known_statuses/0 is a superset of Types.Status.statuses/0" do
      known = Codec.known_statuses()
      persisted = Status.statuses()

      assert Enum.all?(persisted, &(&1 in known)),
             "every persisted status must be decodable by the Codec"

      # The two lists are identical TODAY; the superset relation is the
      # contract (the Codec may carry legacy values), so assert the important
      # direction explicitly and keep the equality as a canary.
      assert Enum.sort(known) == Enum.sort(persisted)
    end

    test "both whitelists admit :awaiting_input and it is not a terminal value" do
      assert :awaiting_input in Codec.known_statuses()
      assert :awaiting_input in Status.statuses()
      refute :awaiting_input in TaskRegistry.terminal_statuses()
      refute :awaiting_input in CLI.terminal_statuses()
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp assert_list!(label, module, function) do
    statuses = apply(module, function, [])

    assert is_list(statuses),
           "#{label} must return a list, got: #{inspect(statuses)}"

    assert statuses != [], "#{label} must not be empty"

    assert Enum.all?(statuses, &(is_atom(&1) or is_binary(&1))),
           "#{label} must contain atoms or strings only, got: #{inspect(statuses)}"

    statuses
  end

  defp statuses_for!(label) do
    {_label, {module, function}, kind, _category} =
      Enum.find(@lists, fn {row_label, _mfa, _kind, _category} -> row_label == label end) ||
        flunk("no @lists row labelled #{inspect(label)}")

    {kind, assert_list!(label, module, function)}
  end

  defp exempt?(label),
    do: Enum.any?(@exempt_lists, fn {row_label, _, _, _} -> row_label == label end)

  # The same status in the spelling that list carries: atom lists compare
  # atoms, the store's SQL projections compare the TEXT spelling.
  defp marker(:atom, status), do: status
  defp marker(:string, status), do: Atom.to_string(status)
end
