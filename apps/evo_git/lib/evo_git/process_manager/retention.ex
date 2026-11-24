defmodule EvoGit.ProcessManager.Retention do
  @moduledoc """
  The ONE retention decision for `EvoGit.ProcessManager.Registry`: which
  TERMINAL records a retention pass drops.

  `EvoGit.ProcessManager.Registry.prune_state/1` does the state surgery (drop
  the records, their handles, their kill intents and any now-unused owner
  monitor); this module only answers the IDS, so the policy is a pure function
  of its input list plus the call-time seams.

  ## Two classes of terminal record

  A terminal `:background_job` execution whose `owner_pid` is STILL ALIVE is
  PROTECTED: a running agent may still ask `/processes` (or an audit) about a
  job it started minutes ago, so such a record is never age-pruned. It is
  bounded PER OWNER instead — the newest `background_max_per_owner/0` of that
  owner survive regardless of age, and only that owner's own overflow (oldest
  first) is dropped. Its lifetime is therefore tied to its own owner, not to
  the churn of other agents' records.

  Every other terminal record — a dead owner's `:background_job`, and EVERY
  `:tool_call` — keeps the historical behaviour unchanged: dropped once it is
  older than `finished_retention_ms/0`, and the survivors capped at the newest
  `max_terminal_records/0` GLOBALLY.

  Live records are never doomed by anything here: the input (every record the
  registry holds, live ones included) is filtered to terminal statuses FIRST, so
  a running execution is always observable and controllable.

  An `owner_pid` that is not a pid (nil included) is a DEAD owner: nothing can
  vouch for the record any more, so it ages out normally.
  """

  alias EvoGit.ProcessManager.Execution

  @default_max_per_owner 20
  @default_retention_ms 300_000
  @default_max_terminal 200

  @doc """
  How many terminal `:background_job` records ONE live owner keeps — app env
  `:process_background_max_per_owner` (default `#{@default_max_per_owner}`),
  read at CALL time like every other retention seam.
  """
  @spec background_max_per_owner() :: non_neg_integer()
  def background_max_per_owner do
    case Application.get_env(
           :evo_git,
           :process_background_max_per_owner,
           @default_max_per_owner
         ) do
      count when is_integer(count) and count >= 0 -> count
      _other -> @default_max_per_owner
    end
  end

  @doc """
  Whether an execution's owner is still alive.

  Total: only a live pid answers `true`; a nil or non-pid owner (and a pid whose
  process has ended) answers `false`, which puts the record back on the ordinary
  age/global-cap path.
  """
  @spec owner_alive?(term()) :: boolean()
  def owner_alive?(owner_pid) when is_pid(owner_pid), do: Process.alive?(owner_pid)
  def owner_alive?(_owner_pid), do: false

  @doc """
  Whether a terminal record is PROTECTED from age retention: a
  `:background_job` whose owner is still alive.

  Total: anything else — a `:tool_call`, a dead owner, a non-struct — is not
  protected.
  """
  @spec protected?(term(), (term() -> boolean())) :: boolean()
  def protected?(%Execution{kind: :background_job, owner_pid: owner_pid}, alive?) do
    alive?.(owner_pid) == true
  end

  def protected?(_execution, _alive?), do: false

  @doc """
  The ids a retention pass must drop.

  Options (all resolved from the registry's call-time seams when omitted, apart
  from `:now` and the `:alive?` predicate, which exist for a deterministic
  suite):

    * `:now` — the reference `DateTime` (default `DateTime.utc_now/0`).
    * `:retention_ms` — the terminal age window.
    * `:max_terminal` — the GLOBAL cap over the non-protected terminal records.
    * `:max_per_owner` — the PER-OWNER cap over protected records.
    * `:alive?` — the owner-liveness predicate (default `owner_alive?/1`).

  Returns a de-duplicated id list (nil ids dropped), and a non-list input
  answers `[]` instead of raising — a retention pass must never take the
  registry down with it.
  """
  @spec doomed_ids([Execution.t()], keyword()) :: [String.t()]
  def doomed_ids(executions, opts \\ [])

  def doomed_ids(executions, opts) when is_list(executions) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    retention_ms = opt(opts, :retention_ms, finished_retention_ms(), @default_retention_ms)
    max_terminal = opt(opts, :max_terminal, max_terminal_records(), @default_max_terminal)

    max_per_owner =
      opt(opts, :max_per_owner, background_max_per_owner(), @default_max_per_owner)

    alive? = Keyword.get(opts, :alive?, &owner_alive?/1)

    terminal = Enum.filter(executions, &Execution.terminal?(&1.status))
    {protected, ordinary} = Enum.split_with(terminal, &protected?(&1, alive?))

    expired_ids =
      ordinary
      |> Enum.filter(&aged_out?(&1, now, retention_ms))
      |> ids()

    capped_ids =
      ordinary
      |> Enum.reject(&aged_out?(&1, now, retention_ms))
      |> newest_then_drop(max_terminal)
      |> ids()

    overflow_ids =
      protected
      |> Enum.group_by(& &1.owner_pid)
      |> Enum.flat_map(fn {_owner, records} -> newest_then_drop(records, max_per_owner) end)
      |> ids()

    Enum.uniq(expired_ids ++ capped_ids ++ overflow_ids)
  end

  def doomed_ids(_executions, _opts), do: []

  @doc "The terminal age window (ms) — app env `:process_finished_retention_ms`."
  @spec finished_retention_ms() :: non_neg_integer()
  def finished_retention_ms do
    case Application.get_env(
           :evo_git,
           :process_finished_retention_ms,
           @default_retention_ms
         ) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @default_retention_ms
    end
  end

  @doc "The GLOBAL cap on non-protected terminal records — app env `:process_finished_max_records`."
  @spec max_terminal_records() :: non_neg_integer()
  def max_terminal_records do
    case Application.get_env(:evo_git, :process_finished_max_records, @default_max_terminal) do
      count when is_integer(count) and count >= 0 -> count
      _other -> @default_max_terminal
    end
  end

  # A terminal record with no end time cannot age; it stays and is bounded by
  # the count cap only (the historical rule).
  defp aged_out?(%Execution{ended_at: %DateTime{} = ended_at}, now, retention_ms) do
    DateTime.diff(now, ended_at, :millisecond) >= retention_ms
  end

  defp aged_out?(_execution, _now, _retention_ms), do: false

  # Newest first, then everything past `cap` is doomed.
  defp newest_then_drop(records, cap) do
    records
    |> Enum.sort_by(&Execution.sort_key/1, :desc)
    |> Enum.drop(cap)
  end

  defp ids(records) do
    records
    |> Enum.map(& &1.id)
    |> Enum.reject(&is_nil/1)
  end

  defp opt(opts, key, fallback, default) do
    case Keyword.get(opts, key, fallback) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
