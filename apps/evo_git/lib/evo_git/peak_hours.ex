defmodule EvoGit.PeakHours do
  @moduledoc """
  Pure helpers for per-model-profile peak-hour concurrency windows.

  LLM providers charge more during peak hours. Each `[[llm.models]]` profile
  may declare optional `peak_concurrency` and `peak_hours` fields:

      [[llm.models]]
      id = "glm"
      concurrency = 4        # normal (off-peak) concurrency
      peak_concurrency = 2   # concurrency during peak windows
      peak_hours = [         # daily time windows (local wall-clock)
        { start = "09:00", end = "12:00" },
        { start = "14:00", end = "18:00" }
      ]

  ## Day-of-week scoping

  Both the profile and each individual window may be restricted to specific
  days of the week, using the same vocabulary of day identifiers and
  keywords:

  - day identifiers: `"mon"` | `"tue"` | `"wed"` | `"thu"` | `"fri"` |
    `"sat"` | `"sun"` (canonical 3-letter lowercase English)
  - keywords: `"weekdays"` (= mon–fri) and `"weekends"` (= sat–sun)

  Input is case-insensitive (`"Mon"`, `"MON"` and `"mon"` are equivalent);
  `validate_days/1` normalizes to a canonical list of day atoms
  (`:mon..:sun`, keywords expanded, duplicates removed).

  - **Profile `off_peak_days`** (optional list): on the listed days the
    profile is off-peak the ENTIRE day — normal `concurrency` applies 24/7,
    every `peak_hours` window is suppressed (never peak), and
    `peak_concurrency` (including the hard-pause `0`) never applies.
    `off_peak_days` **wins** over window `days` (precedence rule).
    Absent / `[]` → disabled.
  - **Profile `off_peak_holidays`** (optional holiday-calendar id, e.g.
    `"CN"`): selected through `validate_holidays/1` (the calendar vocabulary
    lives in `EvoGit.PeakHours.Holidays`). On a date the calendar calls a
    NON-WORKING day — a statutory public holiday, an ordinary weekend, or a
    cancelled weekend `NOT` covered by a 调休 make-up workday — the profile is
    off-peak the ENTIRE day, exactly like `off_peak_days`. A 调休 make-up
    workday on a Saturday/Sunday is a WORKING day, so the day is NOT
    off-peak and that Saturday's window (e.g. a `days = ["sat"]` window)
    still applies. Absent / `""` / an unknown id → no calendar (disabled,
    never raises).
  - **Window `days`** (optional key on each `peak_hours` window): the time
    window applies ONLY on the listed days; absent → every day (fully
    backward compatible). An overnight window's wrapped tail `[0, end)`
    occupies the day AFTER each applicable day (e.g.
    `{ start = "22:00", end = "06:00", days = ["mon"] }` is in peak Mon
    22:00–24:00 AND Tue 00:00–06:00).

  Example — DeepSeek weekends fully off-peak, weekday peak windows:

      [[llm.models]]
      id = "deepseek"
      concurrency = 5
      peak_concurrency = 2
      off_peak_days = ["sat", "sun"]        # weekends off-peak the whole day
      peak_hours = [                        # weekday peak windows
        { start = "09:00", end = "12:00", days = ["mon", "tue", "wed", "thu", "fri"] },
        { start = "14:00", end = "18:00", days = ["weekdays"] }
      ]

  ## Semantics

  - Each window is a map with `start`/`end` `"HH:MM"` 24-hour strings
    (atom-keyed or string-keyed — TOML decoding may produce string keys).
  - Windows are **half-open** `[start, end)`: at `start` the window is
    active, at `end` it is not.
  - `start > end` means an **overnight window** that wraps midnight
    (`22:00`→`06:00` occupies `[22:00, 24:00) ∪ [00:00, 06:00)`).
  - `peak_hours` absent / `[]` / all-invalid → disabled: normal `concurrency`
    applies 24/7.
  - `peak_concurrency` present → effective during peak windows; `peak_hours`
    present but `peak_concurrency` absent → defaults to `concurrency`
    (a legal no-op).

  ## Canonical form

  `validate_windows/1` parses raw window maps into a canonical list of
  `%{start: minute_of_day, end: minute_of_day}` maps (integers 0..1439,
  atom keys; `start > end` ⇒ overnight). A window with a `days` key gains a
  canonical `:days` key holding its day-atom list; a window without `days`
  stays exactly `%{start:, end:}` (absent = every day). `in_peak?/2,3` and
  `next_transition/2,3` operate on this canonical form.

  Raw `start`/`end` values may be written either as strict `"HH:MM"`
  strings (e.g. `"09:00"`) or directly as integer minutes of day
  (e.g. `540`), in atom-keyed or string-keyed maps — both forms parse to
  the same canonical integer minutes.

  This module is pure — no GenServer, no state, no I/O. It is the single
  source of truth for peak-window parsing/validation: the config schema
  reuses `validate_windows/1` for TOML validation errors, and the peak-hour
  engine (owned separately) uses the runtime helpers.

  ## Holidays

  `off_peak_holidays` names a holiday calendar (`validate_holidays/1` accepts
  it; the calendar data itself lives in `EvoGit.PeakHours.Holidays`). The
  day-level rule is ONE predicate: a date is off-peak when its weekday is in
  `off_peak_days` OR the selected calendar reports a non-working day
  (`Holidays.non_working_day?/1`) — so statutory holidays suppress every
  window while 调休 make-up workdays behave as ordinary working days. All
  holiday math is date-based on the WALL-CLOCK date handed in by the caller.
  """

  alias EvoGit.PeakHours.Holidays

  @typedoc "Minute of day: 0 (00:00) to 1439 (23:59)."
  @type minute :: 0..1439

  @typedoc """
  Canonical day of week, aligned with `Date.day_of_week/1` (1 = Monday ..
  7 = Sunday).
  """
  @type day :: :mon | :tue | :wed | :thu | :fri | :sat | :sun

  @typedoc """
  Canonical validated window. `start > end` means an overnight window that
  wraps midnight. The optional `:days` key restricts the window to specific
  days of the week (a canonical day-atom list; absent `:days` = every day).
  """
  @type window ::
          %{start: minute(), end: minute()}
          | %{start: minute(), end: minute(), days: [day()]}

  @typedoc "List of canonical validated windows."
  @type windows :: [window()]

  @minutes_per_day 1440

  # `next_transition/4` search horizon in days. Must comfortably exceed the
  # longest published Chinese holiday block (9 consecutive days, e.g. 2027
  # 春节 Feb 5–13) PLUS the gap until a scoped window re-applies (at most two
  # days) PLUS the day before it during which `now` may sit — 21 days leaves
  # ample margin for future longer blocks at negligible cost (this path runs
  # at most once per peak-hour wakeup, never per request).
  @horizon_days 21

  # All seven canonical day atoms, in `Date.day_of_week/1` order (Mon..Sun).
  @all_days [:mon, :tue, :wed, :thu, :fri, :sat, :sun]

  # Day-identifier/keyword vocabulary: each key (lowercase input form) maps
  # to its canonical day-atom list. Day identifiers map 1:1; keywords expand
  # (`"weekdays"` = mon-fri, `"weekends"` = sat-sun).
  @day_vocabulary %{
    "mon" => [:mon],
    "tue" => [:tue],
    "wed" => [:wed],
    "thu" => [:thu],
    "fri" => [:fri],
    "sat" => [:sat],
    "sun" => [:sun],
    "weekdays" => [:mon, :tue, :wed, :thu, :fri],
    "weekends" => [:sat, :sun]
  }

  # Fixed mid-year UTC instant used to probe a time zone database for an IANA
  # name (mid-year avoids DST edge cases; any valid instant works for the
  # existence probe).
  @probe_iso_days Calendar.ISO.naive_datetime_to_iso_days(2025, 7, 1, 12, 0, 0, {0, 0})

  @doc """
  Validates an IANA time zone name against a time zone database.

  `nil` / `""` (absent/disabled) are always valid. A non-empty binary must
  resolve in the database returned by `Calendar.get_time_zone_database/0` (or
  the explicitly passed `db`). When no database is configured (Elixir's
  default `Calendar.UTCOnlyTimeZoneDatabase`), returns
  `{:error, :no_time_zone_database}` — the caller should treat that as "time
  zones unsupported".

  The probe uses the database's `time_zone_period_from_utc_iso_days/2`
  callback at the fixed mid-year UTC instant above: a valid IANA name returns
  `{:ok, period}`; unknown names return `{:error, :time_zone_not_found}`.

  The optional `db` argument exists so the no-database case is testable
  without mutating the global time zone database (pass
  `Calendar.UTCOnlyTimeZoneDatabase` directly).
  """
  @spec validate_timezone(term(), module()) :: :ok | {:error, term()}
  def validate_timezone(tz, db \\ Calendar.get_time_zone_database())

  def validate_timezone(nil, _db), do: :ok
  def validate_timezone("", _db), do: :ok

  def validate_timezone(tz, db) when is_binary(tz) do
    cond do
      db == Calendar.UTCOnlyTimeZoneDatabase ->
        {:error, :no_time_zone_database}

      true ->
        case db.time_zone_period_from_utc_iso_days(@probe_iso_days, tz) do
          {:ok, _period} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_timezone(_other, _db), do: {:error, :invalid_timezone}

  @doc """
  Resolves a UTC instant into the wall clock of `tz`.

  Returns `{:ok, %NaiveDateTime{}}` (DST-aware — real UTC instants never hit
  gaps/ambiguities) or `{:error, reason}` for an unknown time zone, a
  non-binary `tz`, or a non-DateTime `utc` input.
  """
  @spec wall_clock_in(term(), term()) :: {:ok, NaiveDateTime.t()} | {:error, term()}
  def wall_clock_in(tz, %DateTime{} = utc) when is_binary(tz) do
    case DateTime.shift_zone(utc, tz, Calendar.get_time_zone_database()) do
      {:ok, shifted} -> {:ok, DateTime.to_naive(shifted)}
      {:error, reason} -> {:error, reason}
    end
  end

  def wall_clock_in(tz, _utc) when not is_binary(tz), do: {:error, :invalid_timezone}

  def wall_clock_in(_tz, _utc), do: {:error, :invalid_datetime}

  @doc """
  Parses a strict `"HH:MM"` 24-hour time string into minute-of-day.

  Accepts `"00:00"`..`"23:59"` only. Rejects `"24:00"`, `"9:00"`, `"23:60"`,
  surrounding whitespace, and any non-string input.

      iex> EvoGit.PeakHours.parse_time("09:30")
      {:ok, 570}

      iex> EvoGit.PeakHours.parse_time("24:00")
      :error

  """
  @spec parse_time(term()) :: {:ok, minute()} | :error
  def parse_time(t) when is_binary(t) do
    case Regex.run(~r/\A(\d{2}):(\d{2})\z/, t) do
      [_, hh, mm] ->
        h = String.to_integer(hh)
        m = String.to_integer(mm)

        if h <= 23 and m <= 59 do
          {:ok, h * 60 + m}
        else
          :error
        end

      nil ->
        :error
    end
  end

  def parse_time(_), do: :error

  @doc """
  Validates a list of day identifiers / keywords into canonical day atoms.

  Accepts the seven day identifiers (`"mon"`..`"sun"`, canonical 3-letter
  lowercase English) and the keywords `"weekdays"` (= mon–fri) and
  `"weekends"` (= sat–sun). Input is case-insensitive — `"Mon"`, `"MON"`
  and `"mon"` are equivalent. Returns a canonical list of day atoms
  (`:mon..:sun`, aligned with `Date.day_of_week/1`) in first-appearance
  order, keywords expanded and duplicates removed — e.g.
  `["mon", "weekdays"]` → `[:mon, :tue, :wed, :thu, :fri]`.

  `nil` / absent / `[]` → `{:ok, []}` (disabled). Any other non-list input
  or an invalid/unknown identifier → `{:error, {:invalid_days, value}}`
  where `value` is the offending raw input (the whole non-list value, or
  the first invalid element) — the config schema uses it to build
  descriptive error messages. A bare non-list day value (e.g. a single
  `"mon"` string) is rejected — the field is always a list.
  """
  @spec validate_days(term()) :: {:ok, [day()]} | {:error, {:invalid_days, term()}}
  def validate_days(nil), do: {:ok, []}

  def validate_days(days) when is_list(days) do
    case Enum.reduce_while(days, {:ok, []}, fn d, {:ok, acc} ->
           case normalize_day(d) do
             {:ok, atoms} -> {:cont, {:ok, acc ++ atoms}}
             :error -> {:halt, {:error, {:invalid_days, d}}}
           end
         end) do
      {:ok, lists} -> {:ok, lists |> List.flatten() |> Enum.uniq()}
      other -> other
    end
  end

  def validate_days(other), do: {:error, {:invalid_days, other}}

  @doc """
  Validates an optional holiday-calendar id (`off_peak_holidays`).

  `nil` / `""` (absent/disabled) are always valid. An atom or a binary
  naming a supported calendar — case-insensitive, surrounding whitespace
  ignored (`:cn`, `"cn"`, `" CN "` all match `"CN"`) — is valid; the accepted
  vocabulary is `EvoGit.PeakHours.Holidays.calendars/0`, so this function
  never hardcodes a calendar name. Anything else (an unknown id, a list, a
  number) returns `{:error, {:unknown_calendar, value}}` carrying the RAW
  input, which the config schema turns into a descriptive message.

  Total — never raises.
  """
  @spec validate_holidays(term()) :: :ok | {:error, {:unknown_calendar, term()}}
  def validate_holidays(nil), do: :ok
  def validate_holidays(""), do: :ok

  def validate_holidays(value) when is_binary(value) or is_atom(value) do
    if Holidays.known?(value), do: :ok, else: {:error, {:unknown_calendar, value}}
  end

  def validate_holidays(value), do: {:error, {:unknown_calendar, value}}

  @doc """
  Parses a single peak-hour window map into canonical form.

  Accepts atom-keyed (`%{start: "09:00", end: "12:00"}`) and string-keyed
  (`%{"start" => "09:00", "end" => "12:00"}`) maps. `start`/`end` values may
  be either strict `"HH:MM"` strings or integer minutes of day (`0..1439`) —
  both values of one window must use the same representation. Returns
  `{:error, reason}` with a descriptive reason:

    * `{:invalid_window, value}` — entry is not a map
    * `{:invalid_format, window}` — missing `start`/`end` key, or a value
      that is neither a valid `"HH:MM"` string nor an integer minute of day
      in `0..1439`
    * `{:zero_length, window}` — `start == end` (zero-length window)
    * `{:invalid_days, window}` — invalid `days` value (see `validate_days/1`)

  The optional `days` key (atom- or string-keyed, see the moduledoc) is
  parsed via `validate_days/1`: absent / `nil` / `[]` → no `:days` key in
  the canonical map (every day); a valid non-empty list → a canonical
  `:days` key holding the day-atom list.
  """
  @spec parse_window(term()) :: {:ok, window()} | {:error, term()}
  def parse_window(w) when is_map(w) do
    with {:ok, s_raw} <- fetch_window_key(w, :start),
         {:ok, e_raw} <- fetch_window_key(w, :end),
         true <- same_time_kind?(s_raw, e_raw),
         {:ok, s} <- parse_window_time(s_raw),
         {:ok, e} <- parse_window_time(e_raw) do
      if s == e do
        {:error, {:zero_length, w}}
      else
        build_window(s, e, w)
      end
    else
      :error -> {:error, {:invalid_format, w}}
      false -> {:error, {:invalid_format, w}}
    end
  end

  def parse_window(other), do: {:error, {:invalid_window, other}}

  @doc """
  Validates a list of raw peak-hour window maps into canonical form.

  Returns `{:ok, windows}` when every window parses and no two windows
  overlap (half-open, overnight-wrap aware). Empty list → `{:ok, []}`;
  `nil` → `{:ok, []}` (absent/disabled). On the first problem returns
  `{:error, reason}` — reasons as in `parse_window/1`, plus:

    * `{:overlap, w1, w2}` — two windows overlap (the raw maps as written)
    * `{:invalid_windows, value}` — input is not a list
  """
  @spec validate_windows(term()) :: {:ok, windows()} | {:error, term()}
  def validate_windows(nil), do: {:ok, []}

  def validate_windows(hours) when is_list(hours) do
    case parse_all(hours) do
      {:ok, canonical} ->
        pairs = Enum.zip(canonical, hours)

        case find_overlap(pairs) do
          nil -> {:ok, canonical}
          {w1, w2} -> {:error, {:overlap, w1, w2}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_windows(other), do: {:error, {:invalid_windows, other}}

  @doc """
  True when `now` (local wall-clock) falls inside any peak window.

  Half-open: at a window `start` → true, at its `end` → false. Overnight
  windows wrap midnight. `windows` must be the canonical form produced by
  `validate_windows/1`; an empty list → false.
  """
  @spec in_peak?(windows(), NaiveDateTime.t()) :: boolean()
  def in_peak?(windows, now), do: in_peak?(windows, now, [], nil)

  @doc """
  Day-aware variant of `in_peak?/2`.

  `off_peak_days` is a canonical day-atom list (see `validate_days/1`).
  When `now`'s weekday is in it the profile is off-peak the ENTIRE day and
  this returns `false` — `off_peak_days` wins over window `days`
  (precedence rule). Otherwise true iff `now` falls inside a window whose
  `:days` include today (a window without a `:days` key applies every
  day).

  Overnight day-scoped windows: the wrapped tail `[0, end)` occupies the
  day AFTER each applicable day (e.g. `{22:00-06:00, days: ["mon"]}` is in
  peak Mon 22:00–24:00 AND Tue 00:00–06:00; Tuesday's own applicability is
  irrelevant for the tail — it is the continuation of the Monday window).
  The tail is additionally suppressed when the PREVIOUS day was an
  off-peak day (the precedence rule cuts the whole window, tail included).
  """
  @spec in_peak?(windows(), NaiveDateTime.t(), [day()]) :: boolean()
  def in_peak?(windows, now, off_peak_days), do: in_peak?(windows, now, off_peak_days, nil)

  @doc """
  Holiday-aware variant of `in_peak?/3`.

  `off_peak_holidays` is an optional holiday-calendar id (`nil` / `""` /
  an unknown id = no calendar, see `validate_holidays/1`). The day is
  off-peak when `now`'s WALL-CLOCK date is in `off_peak_days` **or** the
  selected calendar reports a non-working day for it
  (`EvoGit.PeakHours.Holidays.non_working_day?/1` — statutory holiday,
  ordinary weekend, or make-up-workday-aware). On such a day this returns
  `false` for the ENTIRE day, so a statutory holiday or a weekend suppresses
  every window exactly like an `off_peak_days` entry — including the wrapped
  tail of an overnight window on the previous (or the holiday's own) day.

  Because the predicate is evaluated PER DATE, a 调休 make-up workday that
  falls on a Saturday/Sunday is a WORKING day: it is never off-peak and a
  window whose `:days` include `:sat` still applies there.
  """
  @spec in_peak?(windows(), NaiveDateTime.t(), [day()], term()) :: boolean()
  def in_peak?(windows, %NaiveDateTime{} = now, off_peak_days, off_peak_holidays)
      when is_list(windows) and is_list(off_peak_days) do
    rules = day_rules(off_peak_days, off_peak_holidays)

    cond do
      non_working?(NaiveDateTime.to_date(now), rules) -> false
      true -> any_window_active?(windows, now, rules)
    end
  end

  @doc """
  Returns the next `NaiveDateTime` boundary at which the in-peak state
  flips, or `nil` when `windows` is empty (the calling engine caps its
  sleep at 6h anyway, so `nil` is safe).

  Well-defined in every state: inside a window → that window's `end` (the
  next-day `end` minute for an overnight window); outside → the next window
  `start`. With multiple windows the earliest boundary wins. `windows` must
  be the canonical form produced by `validate_windows/1`.
  """
  @spec next_transition(windows(), NaiveDateTime.t()) :: NaiveDateTime.t() | nil
  def next_transition(windows, now), do: next_transition(windows, now, [], nil)

  @doc """
  Day-aware variant of `next_transition/2`.

  `off_peak_days` is a canonical day-atom list (see `validate_days/1`);
  windows are suppressed on those days (precedence rule), exactly as in
  `in_peak?/3`. The next in-peak state flip is computed day-aware:

    * per window, the next start/end minute on an applicable day —
      non-applicable days are SKIPPED entirely (a Monday-only window at
      Mon 13:00 → next boundary is NEXT Mon 09:00, not Tue 09:00);
    * overnight day-scoped windows contribute BOTH the start boundary on
      the applicable day AND the wrapped tail's end boundary on the
      following day;
    * midnight day-boundary flips are real transitions (a day where any
      window applies ↔ a day where none applies, including off-peak-day
      boundaries) — the earliest such midnight is a candidate.

  Returns `nil` when `windows` is empty or every applicable day is
  off-peak (the calling engine caps its sleep at 6h anyway, so `nil` is
  safe). `windows` must be the canonical form produced by
  `validate_windows/1`.
  """
  @spec next_transition(windows(), NaiveDateTime.t(), [day()]) :: NaiveDateTime.t() | nil
  def next_transition(windows, now, off_peak_days),
    do: next_transition(windows, now, off_peak_days, nil)

  @doc """
  Holiday-aware variant of `next_transition/3`.

  `off_peak_holidays` is an optional holiday-calendar id (`nil` / `""` /
  unknown = no calendar — see `validate_holidays/1`). A date the calendar
  reports as a non-working day is off-peak for the ENTIRE day, so it
  contributes no window boundaries — and, because the day-level predicate is
  evaluated PER DATE, the midnight flips at both edges of a holiday block
  (and of a 调休 make-up-workday weekend edge) are reported as real
  transitions whenever the in-peak state actually changes across them.

  Example: a weekday window at Thu 13:00 followed by a Fri–Tue holiday block
  reports the next WORKING day's window start (Wed 09:00), never a
  suppressed window start inside the block.

  The search horizon is 21 days, comfortably beyond the longest published
  Chinese holiday block (9 consecutive days, e.g. 2027 春节 Feb 5–13): a
  weekday-scoped window first re-applies at most two days after such a block
  ends, and `now` may sit one day before it. `nil` is returned only when
  nothing can flip.
  """
  @spec next_transition(windows(), NaiveDateTime.t(), [day()], term()) ::
          NaiveDateTime.t() | nil
  def next_transition([], _now, _off_peak_days, _off_peak_holidays), do: nil

  def next_transition(windows, %NaiveDateTime{} = now, off_peak_days, off_peak_holidays)
      when is_list(windows) and is_list(off_peak_days) do
    date = NaiveDateTime.to_date(now)
    rules = day_rules(off_peak_days, off_peak_holidays)

    candidates =
      Enum.flat_map(0..(@horizon_days - 1), fn offset ->
        date_d = Date.add(date, offset)

        window_candidates =
          Enum.flat_map(windows, fn w ->
            window_day_candidates(w, date_d, now, offset, rules)
          end)

        midnight_candidates =
          if offset >= 1, do: midnight_candidates(windows, date_d, rules), else: []

        window_candidates ++ midnight_candidates
      end)

    case candidates do
      [] ->
        nil

      _ ->
        Enum.reduce(candidates, fn c, acc ->
          if NaiveDateTime.compare(c, acc) == :lt, do: c, else: acc
        end)
    end
  end

  @doc """
  Returns the effective concurrency for a model profile at `now`.

  `profile` is a map with atom keys: `:concurrency` (normal/off-peak),
  optional `:peak_concurrency`, optional `:peak_hours`, optional
  `:off_peak_days` and optional `:off_peak_holidays` (all atom- or
  string-keyed). Returns `peak_concurrency`
  when in peak and the field is present, else `concurrency`. `peak_hours`
  absent / empty / invalid → always `concurrency`. On an off-peak day
  (`now`'s weekday in the profile's `off_peak_days`, or its wall-clock date
  a non-working day for the profile's `off_peak_holidays` calendar) the
  profile is off-peak the ENTIRE day: `concurrency` applies 24/7 and every
  `peak_hours` window (and `peak_concurrency`, including the hard-pause
  `0`) is suppressed — the day rule wins over window `days`
  (precedence rule). Also accepts already-canonical windows (integer
  `start`/`end`) in `:peak_hours` for callers that validated once.
  Returns `nil` when `:concurrency` is missing.
  """
  @spec effective_concurrency(map(), NaiveDateTime.t()) :: non_neg_integer() | nil
  def effective_concurrency(profile, now) when is_map(profile) do
    case Map.get(profile, :concurrency) do
      nil ->
        nil

      concurrency ->
        rules = day_rules(profile_off_peak_days(profile), profile_off_peak_holidays(profile))

        cond do
          non_working?(NaiveDateTime.to_date(now), rules) ->
            concurrency

          true ->
            case normalize_peak_hours(Map.get(profile, :peak_hours)) do
              {:ok, windows} ->
                if any_window_active?(windows, now, rules) do
                  Map.get(profile, :peak_concurrency) || concurrency
                else
                  concurrency
                end

              {:error, _reason} ->
                concurrency
            end
        end
    end
  end

  @doc """
  Timezone-aware variant of `effective_concurrency/2`.

  Resolves `utc_instant` (a `%DateTime{}` UTC instant) into `tz`'s wall clock
  via `wall_clock_in/2` and delegates to `effective_concurrency/2` — no window
  logic is re-implemented here. On any resolution error (unknown time zone,
  unconfigured tz database, bad input) falls back to `concurrency` — the same
  fallback the two-arity version uses for invalid windows (`nil` when
  `:concurrency` is missing).
  """
  @spec effective_concurrency(map(), DateTime.t(), term()) :: non_neg_integer() | nil
  def effective_concurrency(profile, utc_instant, tz) when is_map(profile) do
    case wall_clock_in(tz, utc_instant) do
      {:ok, wall} -> effective_concurrency(profile, wall)
      {:error, _reason} -> Map.get(profile, :concurrency)
    end
  end

  # --- Private helpers ---

  # Fetches a window key tolerating both atom and string key styles.
  defp fetch_window_key(w, key) do
    case Map.fetch(w, key) do
      {:ok, v} ->
        {:ok, v}

      :error ->
        case Map.fetch(w, Atom.to_string(key)) do
          {:ok, v} -> {:ok, v}
          :error -> :error
        end
    end
  end

  # Parses every window in order, failing fast on the first invalid one.
  defp parse_all(hours) do
    result =
      Enum.reduce_while(hours, {:ok, []}, fn h, {:ok, acc} ->
        case parse_window(h) do
          {:ok, w} -> {:cont, {:ok, [w | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, ws} -> {:ok, Enum.reverse(ws)}
      other -> other
    end
  end

  # Pairwise overlap scan over {canonical, raw} pairs; returns the raw
  # maps of the first overlapping pair, or nil when none overlap.
  defp find_overlap(pairs), do: find_overlap(pairs, [])

  defp find_overlap([], _seen), do: nil

  defp find_overlap([{cw, rw} | rest], seen) do
    case Enum.find(seen, fn {c2, _rw2} -> windows_overlap?(cw, c2) end) do
      nil -> find_overlap(rest, [{cw, rw} | seen])
      {_c2, rw2} -> {rw, rw2}
    end
  end

  # Two canonical windows overlap only if they share at least one
  # applicable day (a window without a `:days` key — or with an empty list
  # — applies every day) AND their time segments overlap. Windows with
  # DISJOINT `days` never overlap — overlap is checked per-day.
  defp windows_overlap?(w1, w2) do
    shared_days?(w1, w2) and
      Enum.any?(segments(w1), fn seg1 ->
        Enum.any?(segments(w2), fn seg2 -> segments_overlap?(seg1, seg2) end)
      end)
  end

  # True when the two canonical windows have at least one day in common.
  defp shared_days?(w1, w2) do
    Enum.any?(window_days(w1), fn d -> d in window_days(w2) end)
  end

  # Applicable days of a canonical window: its `:days` list, or all seven
  # days when absent / empty (every day).
  defp window_days(w), do: Map.get(w, :days, @all_days) || @all_days

  # Two half-open segments [a, b) and [c, d) overlap iff a < d and c < b.
  defp segments_overlap?({a, b}, {c, d}), do: a < d and c < b

  defp segments(%{start: s, end: e}) when s < e, do: [{s, e}]

  defp segments(%{start: s, end: e}) do
    [{s, @minutes_per_day}, {0, e}]
  end

  # All strictly-future transition instants contributed by window `w` on
  # day `date_d` (`offset` = days after `now`'s date; used only to filter
  # offset-0 instants to strictly-after-`now` so a boundary that just
  # flipped — or is exactly `now` — is not re-reported). On a non-working
  # day (off-peak weekday OR a calendar non-working date) every window is
  # suppressed (no in-day boundaries). Same-day windows
  # contribute start + end; overnight windows contribute their start on an
  # applicable day and their wrapped tail's end on the FOLLOWING day — the
  # tail is cut when the previous date is itself non-working.
  defp window_day_candidates(w, date_d, now, offset, rules) do
    %{start: s, end: e} = w
    dow = day_atom(date_d)

    instants =
      cond do
        non_working?(date_d, rules) ->
          []

        s < e ->
          if dow in window_days(w), do: [at(date_d, s), at(date_d, e)], else: []

        true ->
          start_instant = if dow in window_days(w), do: [at(date_d, s)], else: []

          tail_exit =
            if prev_day_atom(dow) in window_days(w) and
                 not non_working?(Date.add(date_d, -1), rules),
               do: [at(date_d, e)],
               else: []

          start_instant ++ tail_exit
      end

    if offset == 0 do
      Enum.filter(instants, fn instant -> NaiveDateTime.compare(instant, now) == :gt end)
    else
      instants
    end
  end

  # Midnight transition candidate at the boundary between `date_d - 1` and
  # `date_d` (only meaningful for offsets >= 1): the midnight instant is a
  # real transition iff the in-peak state differs across it (a day where
  # any window applies ↔ a day where none applies; overnight windows are
  # continuous across midnight; non-working days are always out of peak).
  # Because `state_at_minute/4` evaluates the day rule PER DATE, the edges
  # of a holiday block — and of a 调休 make-up-workday weekend — flip here
  # automatically.
  defp midnight_candidates(windows, date_d, rules) do
    if state_at_minute(windows, Date.add(date_d, -1), @minutes_per_day - 1, rules) !=
         state_at_minute(windows, date_d, 0, rules) do
      [at(date_d, 0)]
    else
      []
    end
  end

  # In-peak state at minute-of-day `m` on `date` (non-working days are always
  # out of peak; window day scoping + overnight tails included).
  defp state_at_minute(windows, date, m, rules) do
    if non_working?(date, rules) do
      false
    else
      Enum.any?(windows, fn w -> window_active_at?(w, date, m, rules) end)
    end
  end

  # True when minute-of-day `m` on `date` is inside window `w`: same-day
  # windows need today's weekday in `days(w)` and `[s, e)`; overnight
  # windows are active on `[s, 1440)` when today's weekday is applicable and
  # on the wrapped tail `[0, e)` when the PREVIOUS day's weekday is
  # applicable and that previous DATE is not non-working.
  defp window_active_at?(w, date, m, rules) do
    %{start: s, end: e} = w
    days = window_days(w)
    dow = day_atom(date)

    if s < e do
      dow in days and m >= s and m < e
    else
      (dow in days and m >= s) or
        (prev_day_atom(dow) in days and not non_working?(Date.add(date, -1), rules) and m < e)
    end
  end

  # True when any window of `windows` is active at `now` on a working day.
  # Shared by `in_peak?/4` and `effective_concurrency/2` so the two can
  # never disagree.
  defp any_window_active?(windows, %NaiveDateTime{} = now, rules) do
    date = NaiveDateTime.to_date(now)
    t = minute_of_day(now)
    Enum.any?(windows, fn w -> window_active_at?(w, date, t, rules) end)
  end

  defp at(date, minute) do
    NaiveDateTime.new!(date, Time.new!(div(minute, 60), rem(minute, 60), 0))
  end

  defp minute_of_day(%NaiveDateTime{hour: h, minute: m}), do: h * 60 + m

  # Canonical day atom of a date (`Date.day_of_week/1`: 1 = Monday ..
  # 7 = Sunday); also accepts a wall-clock instant.
  defp day_atom(%Date{} = date), do: Enum.at(@all_days, Date.day_of_week(date) - 1)
  defp day_atom(%NaiveDateTime{} = now), do: day_atom(NaiveDateTime.to_date(now))

  # The day atom immediately before `d` in the weekly cycle (Mon → Sun,
  # Tue → Mon, ..., Sun → Sat) — used for overnight window tails that wrap
  # into the following day.
  defp prev_day_atom(:mon), do: :sun
  defp prev_day_atom(:tue), do: :mon
  defp prev_day_atom(:wed), do: :tue
  defp prev_day_atom(:thu), do: :wed
  defp prev_day_atom(:fri), do: :thu
  defp prev_day_atom(:sat), do: :fri
  defp prev_day_atom(:sun), do: :sat

  # Accepts raw "HH:MM" / integer-minute windows (validated) OR nil/[]; any
  # non-list → {:error, _} so callers fall back to normal concurrency.
  # `validate_windows/1` is the single parse/validate path — it handles
  # string-keyed, atom-keyed, "HH:MM", and canonical integer-minute windows
  # uniformly, so no separate canonical fast path is needed here.
  defp normalize_peak_hours(nil), do: {:ok, []}

  defp normalize_peak_hours(hours) when is_list(hours), do: validate_windows(hours)

  defp normalize_peak_hours(_), do: {:error, :invalid_windows}

  # Parses a single window time value: a strict "HH:MM" binary (delegated to
  # parse_time/1) or an integer minute-of-day in 0..1439 (canonical form);
  # anything else → :error.
  defp parse_window_time(t) when is_binary(t), do: parse_time(t)

  defp parse_window_time(m) when is_integer(m) do
    if m in 0..1439, do: {:ok, m}, else: :error
  end

  defp parse_window_time(_), do: :error

  # `start`/`end` of one window must use the same representation — both
  # "HH:MM" strings or both integer minutes of day; mixing the two is
  # rejected as invalid.
  defp same_time_kind?(a, b), do: is_binary(a) == is_binary(b)

  # Assembles the canonical window map after `start`/`end` parsed OK. The
  # optional `days` key (atom- or string-keyed) is parsed via
  # `validate_days/1`: absent / nil / [] → no `:days` key (every day); a
  # valid non-empty list → canonical day atoms. Invalid days →
  # `{:error, {:invalid_days, w}}` carrying the RAW window map so the
  # config schema can locate the window by raw-map equality.
  defp build_window(s, e, w) do
    case fetch_window_key(w, :days) do
      :error ->
        {:ok, %{start: s, end: e}}

      {:ok, days} ->
        case validate_days(days) do
          {:ok, []} -> {:ok, %{start: s, end: e}}
          {:ok, day_atoms} -> {:ok, %{start: s, end: e, days: day_atoms}}
          {:error, {:invalid_days, _raw}} -> {:error, {:invalid_days, w}}
        end
    end
  end

  # Normalizes one raw day identifier/keyword (a binary) into its canonical
  # day-atom list. Case-insensitive; unknown identifiers → :error.
  defp normalize_day(d) when is_binary(d) do
    case Map.get(@day_vocabulary, String.downcase(d)) do
      nil -> :error
      atoms -> {:ok, atoms}
    end
  end

  defp normalize_day(_), do: :error

  # Profile's canonical off-peak day list (atom- or string-keyed
  # `:off_peak_days`); invalid / absent / empty → [] (never crashes,
  # mirroring how invalid windows fall back to normal concurrency).
  defp profile_off_peak_days(profile) do
    case Map.get(profile, :off_peak_days) || Map.get(profile, "off_peak_days") do
      nil ->
        []

      days ->
        case validate_days(days) do
          {:ok, list} -> list
          {:error, _reason} -> []
        end
    end
  end

  # Profile's optional holiday-calendar id (atom- or string-keyed
  # `:off_peak_holidays`); the raw value — `day_rules/2` canonicalizes it and
  # degrades an unknown id to "no calendar".
  defp profile_off_peak_holidays(profile) do
    Map.get(profile, :off_peak_holidays) || Map.get(profile, "off_peak_holidays")
  end

  # The "day rules" context threaded through the runtime math: the profile's
  # canonical off-peak weekday list plus the canonical holiday-calendar id
  # (`nil` = none). ONE context so every day-level question goes through
  # `non_working?/2`.
  defp day_rules(off_peak_days, off_peak_holidays) do
    %{days: off_peak_days, calendar: calendar_id(off_peak_holidays)}
  end

  # THE day-level predicate: a date is off-peak (non-working) when its
  # weekday is in the profile's `off_peak_days` OR the selected holiday
  # calendar reports a non-working day. `Holidays.non_working_day?/1` already
  # applies the make-up-workday precedence (a 调休 Saturday is a WORKING day),
  # so no weekday re-derivation is allowed here.
  defp non_working?(%Date{} = date, %{days: days, calendar: calendar}) do
    day_atom(date) in days or (calendar != nil and Holidays.non_working_day?(date))
  end

  # Canonical calendar id ("CN") for a raw value, or nil when absent / blank
  # / unknown (degrade to no calendar — never raise; mirrors how invalid
  # windows fall back to normal concurrency). The VOCABULARY lives in
  # `Holidays.calendars/0`; this never hardcodes a calendar name.
  defp calendar_id(nil), do: nil
  defp calendar_id(""), do: nil

  defp calendar_id(value) when is_atom(value) and not is_nil(value),
    do: calendar_id(Atom.to_string(value))

  defp calendar_id(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.upcase()
    Enum.find(Holidays.calendars(), fn id -> String.upcase(id) == normalized end)
  end

  defp calendar_id(_value), do: nil
end
