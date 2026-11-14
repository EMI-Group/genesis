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
  `:awaiting_input`, each with its reason. The first is a caller-facing
  asymmetry: `TaskControl.status_filters/0` is a FILTER VOCABULARY (it defaults
  to `"all"`, so every row is listable without naming a status), not a liveness
  admission set. The second is the Assistant's pause facade
  (`Broker.pause_statuses/0`): an interactive session is deliberately
  UNPAUSABLE, so its idle `:awaiting_input` status must not be admitted.

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

  ## The TASK-PAUSE pairing (`docs/task-pause.md` §7)

  A task-level pause adds two NON-terminal statuses: `:pausing` (a pause
  request is draining the task's agents — wrapper alive, lease renewed) and
  `:paused` (the resting state — no wrapper, no lease, resumable, `finished_at`
  nil). The second pairing rule therefore holds over the SAME `@lists` table: a
  set that admits `:running` must admit `:pausing`, and a set that admits
  `:awaiting_input` must admit `:paused`.

  The deliberate absences are pinned by table:

    * `@agent_level_lists` — the AGENT-level sets (`SchedMeta`'s
      status/phase/live/idle/cancel-reachable enumerations,
      `InteractiveRoot.accepted_statuses/0`,
      `Authorization.accepted_agent_statuses/0`,
      `Projection.agent_statuses/0`) admit NEITHER new status: a pause moves the
      TASK row and flags agents through the control plane, never an agent's own
      status;
    * `@paused_lease_lists` — `Lease.renewed_statuses/0`,
      `Lease.leaked_statuses/0` and `Lightweight.lease_statuses/0` admit
      `:pausing` (a draining task still has a live wrapper, so its lease keeps
      being renewed and it may still be swept if that wrapper dies) but NEVER
      `:paused` (the resting row has no wrapper and no heartbeat, so listing it
      would make every paused task look like a leaked lease row).

  Both new statuses are also pinned NON-terminal and self-decoding
  (`TaskRegistry.terminal_statuses/0`, `Codec.known_statuses/0`,
  `Types.Status.statuses/0`).

  Every accessor below is a PURE function over module attributes, so nothing
  here mutates BEAM-global state and the module runs `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval.Authorization
  alias EvoGit.Agent.Tools.ElixirEval.Broker
  alias EvoGit.Agent.Tools.ElixirEval.Projection
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.CommandApproval
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Lightweight
  alias EvoGit.Store.Types.Status
  alias EvoGit.TaskControl
  alias EvoGit.TaskRegistry
  alias EvoGit.TaskRegistry.Lease

  @running :running
  @awaiting_input :awaiting_input
  @pausing :pausing
  @paused :paused

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
    # A pause is requested FROM a running task and stays idempotent on the two
    # pause statuses; an idle `:awaiting_input` interactive session is refused by
    # the registry (`:not_pausable`), so this list is pinned in `@exempt_lists`.
    {"Agent.Tools.ElixirEval.Broker.pause_statuses/0", {Broker, :pause_statuses}, :atom,
     :running},
    {"Agent.Tools.ElixirEval.Broker.resume_statuses/0", {Broker, :resume_statuses}, :atom,
     :not_running},
    {"Agent.Tools.ElixirEval.Authorization.accepted_agent_statuses/0",
     {Authorization, :accepted_agent_statuses}, :atom, :running},
    {"Agent.Tools.ElixirEval.Authorization.accepted_agent_task_statuses/0",
     {Authorization, :accepted_agent_task_statuses}, :atom, :running},
    # The Assistant's scalar projections must not hide a waiting session: a
    # task row keeps its `:awaiting_input` status and `list_agents` reports it.
    {"Agent.Tools.ElixirEval.Projection.statuses/0", {Projection, :statuses}, :atom, :running},
    {"Agent.Tools.ElixirEval.Projection.agent_statuses/0", {Projection, :agent_statuses}, :atom,
     :running},
    # ── scheduler agent enumerations ──
    {"AgentScheduler.SchedMeta.statuses/0", {SchedMeta, :statuses}, :atom, :running},
    {"AgentScheduler.SchedMeta.phases/0", {SchedMeta, :phases}, :atom, :running},
    {"AgentScheduler.SchedMeta.live_statuses/0", {SchedMeta, :live_statuses}, :atom, :running},
    {"AgentScheduler.SchedMeta.idle_statuses/0", {SchedMeta, :idle_statuses}, :atom,
     :not_running},
    {"AgentScheduler.SchedMeta.cancel_reachable_statuses/0",
     {SchedMeta, :cancel_reachable_statuses}, :atom, :running},
    {"AgentScheduler.InteractiveRoot.accepted_statuses/0",
     {EvoGit.AgentScheduler.InteractiveRoot, :accepted_statuses}, :atom, :running},
    # The Assistant's `list` facade FILTER vocabulary (STRING values, `"all"`
    # first): it names every persisted status a caller may filter by, so a
    # paused task is listable. It is a QUERY vocabulary, not a liveness set —
    # pinned in `@exempt_lists` below.
    {"TaskControl.status_filters/0", {TaskControl, :status_filters}, :string, :running}
  ]

  # {label, {module, function}, :atom | :string, reason} — a list that admits
  # `:running` but DELIBERATELY does not admit `:awaiting_input`. The mechanism
  # exists so an intentional asymmetry is pinned WITH its reason instead of
  # silently weakening the sweep below.
  @exempt_lists [
    # A filter VOCABULARY, not an admission set: `list/1` defaults to `"all"`, so
    # every row (an idle `:awaiting_input` session included) is listable without
    # naming its status. It gains the pause values because they are persisted
    # statuses, which is the only rule it follows.
    {"TaskControl.status_filters/0", {TaskControl, :status_filters}, :string,
     "a caller-facing filter VOCABULARY, not a liveness/admission set: the " <>
       "filter defaults to \"all\", so an :awaiting_input row is listable " <>
       "without a dedicated value"},
    # An interactive session is deliberately UNPAUSABLE (`:not_pausable`): it has
    # no resumable one-shot run, so its idle `:awaiting_input` status must not be
    # admitted by the Assistant's pause facade.
    {"Agent.Tools.ElixirEval.Broker.pause_statuses/0", {Broker, :pause_statuses}, :atom,
     "an idle :awaiting_input interactive session is refused `:not_pausable` by " <>
       "the task registry: a pause needs a resumable one-shot run"}
  ]

  # The pinned "absence is deliberate" sets that are not running-bearing live
  # sets but would otherwise look like a forgotten admission.
  @pinned_absences [
    {"TaskRegistry.finalizing_ignored_statuses/0", {TaskRegistry, :finalizing_ignored_statuses},
     :atom,
     "closing an idle session legitimately moves it through :finalizing, so ONLY " <>
       "already-terminal / mid-graceful-cancel rows ignore that broadcast"}
  ]

  # ── the TASK-PAUSE pairing (`docs/task-pause.md` §7) ───────────────────────
  #
  # `:pausing` (a pause request is draining the task's agents — non-terminal,
  # wrapper alive) must follow `:running` in every TASK-level admission set, and
  # `:paused` (the non-terminal resting state — no wrapper, no lease, resumable)
  # must follow `:awaiting_input`. Where an absence is deliberate it is pinned
  # below WITH its reason.

  @agent_level_reason "agent-level, not task-level: a task pause is a TASK status and " <>
                        "never appears in an AGENT status/phase set"

  # {label, {module, function}, :atom | :string} — AGENT-level sets. They admit
  # `:running` and `:awaiting_input` (AGENT statuses) and must admit NEITHER new
  # status: `begin_task_pause/1` flags agents through the control plane and moves
  # the TASK row, never an agent's own status.
  @agent_level_lists [
    {"AgentScheduler.SchedMeta.statuses/0", {SchedMeta, :statuses}, :atom},
    {"AgentScheduler.SchedMeta.phases/0", {SchedMeta, :phases}, :atom},
    {"AgentScheduler.SchedMeta.live_statuses/0", {SchedMeta, :live_statuses}, :atom},
    {"AgentScheduler.SchedMeta.idle_statuses/0", {SchedMeta, :idle_statuses}, :atom},
    {"AgentScheduler.SchedMeta.cancel_reachable_statuses/0",
     {SchedMeta, :cancel_reachable_statuses}, :atom},
    {"AgentScheduler.InteractiveRoot.accepted_statuses/0",
     {EvoGit.AgentScheduler.InteractiveRoot, :accepted_statuses}, :atom},
    {"Agent.Tools.ElixirEval.Authorization.accepted_agent_statuses/0",
     {Authorization, :accepted_agent_statuses}, :atom},
    {"Agent.Tools.ElixirEval.Projection.agent_statuses/0", {Projection, :agent_statuses}, :atom}
  ]

  # {label, {module, function}, :atom | :string, reason} — sets that admit
  # `:running` but DELIBERATELY not `:pausing`. The AGENT-level sets only: no
  # TASK-level set is exempt from this implication.
  @pause_exempt_lists Enum.map(@agent_level_lists, fn {label, mfa, kind} ->
                        {label, mfa, kind, @agent_level_reason}
                      end)

  # {label, {module, function}, :atom | :string} — the LEASE sets. They admit
  # `:pausing` (a mid-drain task still has a LIVE WRAPPER, so its lease keeps
  # being renewed and it may still be swept when that wrapper dies) but NEVER
  # `:paused`: the resting state has no wrapper and no heartbeat, so listing it
  # would make every paused task look like a leaked lease row.
  @paused_lease_lists [
    {"TaskRegistry.Lease.renewed_statuses/0", {Lease, :renewed_statuses}, :atom},
    {"TaskRegistry.Lease.leaked_statuses/0", {Lease, :leaked_statuses}, :atom},
    {"Store.Operations.Lightweight.lease_statuses/0", {Lightweight, :lease_statuses}, :string}
  ]

  # {label, {module, function}, :atom | :string, reason} — sets that admit
  # `:awaiting_input` but DELIBERATELY not `:paused`: the AGENT-level sets (a
  # task pause is not an agent status) and the LEASE sets (a paused row never
  # holds a lease).
  @paused_exempt_lists Enum.map(@pause_exempt_lists, & &1) ++
                         Enum.map(@paused_lease_lists, fn {label, mfa, kind} ->
                           {label, mfa, kind,
                            "a paused row never holds a lease: no wrapper, no heartbeat"}
                         end)

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
            "AgentScheduler.SchedMeta.cancel_reachable_statuses/0",
            "AgentScheduler.InteractiveRoot.accepted_statuses/0"
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
    end
  end

  describe "task-pause pairing (:running ⇒ :pausing, :awaiting_input ⇒ :paused)" do
    test "every list that admits :running also admits :pausing" do
      for {label, {module, function}, kind, _category} <- @lists,
          not pause_exempt?(label) do
        statuses = assert_list!(label, module, function)

        if marker(kind, @running) in statuses do
          assert marker(kind, @pausing) in statuses,
                 "#{label} admits #{inspect(marker(kind, @running))} but NOT " <>
                   "#{inspect(marker(kind, @pausing))}. A pause request must be " <>
                   "admitted wherever a running task is, so the drain can be " <>
                   "observed, listed, cancelled and force-killed; either add it " <>
                   "to this list or pin it in @pause_exempt_lists with a reason.\n" <>
                   "Got: #{inspect(statuses)}"
        end
      end
    end

    test "every list that admits :awaiting_input also admits :paused" do
      for {label, {module, function}, kind, _category} <- @lists,
          not paused_exempt?(label) do
        statuses = assert_list!(label, module, function)

        if marker(kind, @awaiting_input) in statuses do
          assert marker(kind, @paused) in statuses,
                 "#{label} admits #{inspect(marker(kind, @awaiting_input))} but NOT " <>
                   "#{inspect(marker(kind, @paused))}. A paused task is the " <>
                   "non-terminal resting counterpart of an idle session (alive, " <>
                   "resumable, never `finished`); either add it to this list or " <>
                   "pin it in @paused_exempt_lists with a reason.\n" <>
                   "Got: #{inspect(statuses)}"
        end
      end
    end

    test "the pause sweep is not vacuous — the task-level sets admit both" do
      for label <- [
            "TaskRegistry.killable_statuses/0",
            "TaskRegistry.gracefully_cancellable_statuses/0",
            "TaskRegistry.active_statuses/0",
            "Store.Operations.Lightweight.live_statuses/0",
            "Store.Codec.known_statuses/0",
            "Store.Types.Status.statuses/0",
            "CommandApproval.denying_task_statuses/0",
            "CommandApproval.eval_active_task_statuses/0",
            "Agent.Tools.ElixirEval.Authorization.accepted_agent_task_statuses/0",
            "Agent.Tools.ElixirEval.Projection.statuses/0",
            "TaskControl.status_filters/0"
          ] do
        {kind, statuses} = statuses_for!(label)
        assert marker(kind, @pausing) in statuses, "#{label} must admit :pausing"
        assert marker(kind, @paused) in statuses, "#{label} must admit :paused"
      end
    end

    test "each pinned absence really lacks the status it is excused from" do
      for {label, {module, function}, kind, reason} <- @pause_exempt_lists do
        statuses = assert_list!(label, module, function)

        refute marker(kind, @pausing) in statuses,
               "#{label} is pinned as a deliberate absence of :pausing (#{reason}); " <>
                 "delete the pin if the change is intended"
      end

      for {label, {module, function}, kind, reason} <- @paused_exempt_lists do
        statuses = assert_list!(label, module, function)

        refute marker(kind, @paused) in statuses,
               "#{label} is pinned as a deliberate absence of :paused (#{reason}); " <>
                 "delete the pin if the change is intended"
      end
    end

    test "the AGENT-level sets admit neither new status (a task pause is not an agent status)" do
      for {label, {module, function}, kind} <- @agent_level_lists do
        statuses = assert_list!(label, module, function)

        refute marker(kind, @pausing) in statuses, "#{label}: #{@agent_level_reason}"
        refute marker(kind, @paused) in statuses, "#{label}: #{@agent_level_reason}"
      end
    end

    test "the LEASE sets admit :pausing but never :paused" do
      for {label, {module, function}, kind} <- @paused_lease_lists do
        statuses = assert_list!(label, module, function)

        assert marker(kind, @pausing) in statuses,
               "#{label} must admit :pausing — a draining task still has a live wrapper"

        refute marker(kind, @paused) in statuses,
               "#{label} must NOT admit :paused — a paused row holds no lease"
      end
    end

    test ":pausing/:paused are non-terminal and each decodes to itself" do
      for status <- [@pausing, @paused] do
        refute status in TaskRegistry.terminal_statuses(),
               "#{inspect(status)} is a NON-terminal resting/draining status"

        assert status in Codec.known_statuses(),
               "#{inspect(status)} must decode to itself, never to nil/:pending"

        assert status in Status.statuses(),
               "#{inspect(status)} must be a persistable tasks.status value"
      end
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

  defp pause_exempt?(label),
    do: Enum.any?(@pause_exempt_lists, fn {row_label, _, _, _} -> row_label == label end)

  defp paused_exempt?(label),
    do: Enum.any?(@paused_exempt_lists, fn {row_label, _, _, _} -> row_label == label end)

  # The same status in the spelling that list carries: atom lists compare
  # atoms, the store's SQL projections compare the TEXT spelling.
  defp marker(:atom, status), do: status
  defp marker(:string, status), do: Atom.to_string(status)
end
