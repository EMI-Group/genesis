defmodule EvoGit.PeakHours.Holidays do
  @moduledoc """
  Static public-holiday calendar for Mainland China (中华人民共和国法定节假日).

  Peak-hour scheduling uses this module to tell a statutory non-working day from an
  ordinary weekday, so a provider's peak windows can be suppressed on 公休 days.
  It is a STATIC, data-driven table — NOT a third-party package — so the project's
  dependency set (and therefore `genesis.nix`'s `mixFodDeps.hash`) stays untouched.

  ## Purity

  There is NO timezone math here, neither in the table nor in the functions:
  callers hand in a WALL-CLOCK `%Date{}` in the calendar's local frame, and the
  table is just a set of ISO dates. `%NaiveDateTime{}` input is accepted and its
  date is used (a naive struct carries no zone, so no conversion is implied).

  Every public function is TOTAL and never raises. A year that is not in the
  table simply answers `false` everywhere (`holiday?/1`, `make_up_workday?/1`,
  `non_working_day?/1` on a non-weekend date, `holiday_name/1` → `nil`), so an
  unsupported year degrades to plain weekend-only behaviour instead of crashing.

  ## Working-day precedence

  `non_working_day?/1` is `holiday?(date) or (weekend?(date) and not make_up_workday?(date))`:

    * a 调休 make-up workday (补班) that falls on a Saturday/Sunday is a WORKING day,
      even though the calendar weekday says weekend;
    * a statutory holiday that falls on a Saturday/Sunday is still a non-working day
      (the holiday predicate wins, and that weekend is non-working anyway);
    * a holiday date inside an announced block is a non-working day regardless of
      whether it is a make-up day elsewhere in the year.

  ## Supported years

  `2025`, `2026` and `2027` are all OFFICIALLY published arrangements. There are
  no provisional years as of the table's access date, so `provisional_years/0`
  returns `[]`. If the State Council has not yet published a year's arrangement,
  add the year to `provisional_years/0` and mark those entries `# provisional`.

  ## Sources

  Arrangements verified on 2026-11-19 against the State Council (国务院办公厅) notices:

    * 2025 — 国办发明电〔2024〕12号, published 2024-11-12:
      <https://www.forestry.gov.cn/c/www/szxx/594663.jhtml>
      (full text of the 中国政府网 notice)
    * 2026 — 国办发明电〔2025〕7号, published 2025-11-04:
      <https://www.waizi.org.cn/doc/270189.html>
      (full text; also <https://baike.baidu.com/item/66966371>)
    * 2027 — 国办发明电〔2026〕10号, published 2026-11-05:
      <https://www.news.cn/politics/20261105/f90cd6ad4df94ab4833b141e52ccfc13/c.html>

  ## How to extend this table each year

  The State Council publishes the next year's arrangement in November. When it
  does, update THIS module only (no dependency, config or migration change):

    1. Append every statutory holiday day to `@cn_holidays` (one entry per DAY,
       including each day of a contiguous block — they are NOT ranges).
       Entry shape: `{~D[2028-01-01], "元旦"}` — a `~D[YYYY-MM-DD]` literal plus
       the Chinese holiday name used for display.
    2. Append the 调休/补班 make-up workdays to `@cn_make_up_workdays` — a SEPARATE
       list of plain `~D[YYYY-MM-DD]` literals (dates only, no name). These are
       usually Saturday/Sunday dates that are worked to compensate.
    3. Add the new year to `@supported_years` (ascending order).
    4. Remove it from `@provisional_years` once the official notice is out; if you
       add a year before publication, put it in `@provisional_years` AND mark those
       `@cn_holidays` entries with a trailing `# provisional` comment.
    5. Keep both lists sorted ascending and unique — a test pins these invariants.
    6. An out-of-table year answers `false` everywhere by design: it degrades to
       weekend-only behaviour rather than raising, so extending is never required
       for the system to keep working.
  """

  @typedoc "A supported holiday-calendar identifier."
  @type calendar :: String.t()

  # Supported calendar identifiers (unique today, but kept a list for growth).
  @calendars ["CN"]

  # Supported years of the published arrangement, ascending.
  @supported_years [2025, 2026, 2027]

  # Years whose arrangement is NOT yet officially published (none today).
  @provisional_years []

  # Statutory Chinese public holidays (公休): `{date, name}`, one entry per DAY,
  # covering every published day of each announced block. Sorted ascending and
  # unique (enforced at compile time below).
  @cn_holidays [
    # ---- 2025 (国办发明电〔2024〕12号) ----
    {~D[2025-01-01], "元旦"},
    {~D[2025-01-28], "春节"},
    {~D[2025-01-29], "春节"},
    {~D[2025-01-30], "春节"},
    {~D[2025-01-31], "春节"},
    {~D[2025-02-01], "春节"},
    {~D[2025-02-02], "春节"},
    {~D[2025-02-03], "春节"},
    {~D[2025-02-04], "春节"},
    {~D[2025-04-04], "清明节"},
    {~D[2025-04-05], "清明节"},
    {~D[2025-04-06], "清明节"},
    {~D[2025-05-01], "劳动节"},
    {~D[2025-05-02], "劳动节"},
    {~D[2025-05-03], "劳动节"},
    {~D[2025-05-04], "劳动节"},
    {~D[2025-05-05], "劳动节"},
    {~D[2025-05-31], "端午节"},
    {~D[2025-06-01], "端午节"},
    {~D[2025-06-02], "端午节"},
    {~D[2025-10-01], "国庆节、中秋节"},
    {~D[2025-10-02], "国庆节、中秋节"},
    {~D[2025-10-03], "国庆节、中秋节"},
    {~D[2025-10-04], "国庆节、中秋节"},
    {~D[2025-10-05], "国庆节、中秋节"},
    {~D[2025-10-06], "国庆节、中秋节"},
    {~D[2025-10-07], "国庆节、中秋节"},
    {~D[2025-10-08], "国庆节、中秋节"},
    # ---- 2026 (国办发明电〔2025〕7号) ----
    {~D[2026-01-01], "元旦"},
    {~D[2026-01-02], "元旦"},
    {~D[2026-01-03], "元旦"},
    {~D[2026-02-15], "春节"},
    {~D[2026-02-16], "春节"},
    {~D[2026-02-17], "春节"},
    {~D[2026-02-18], "春节"},
    {~D[2026-02-19], "春节"},
    {~D[2026-02-20], "春节"},
    {~D[2026-02-21], "春节"},
    {~D[2026-02-22], "春节"},
    {~D[2026-02-23], "春节"},
    {~D[2026-04-04], "清明节"},
    {~D[2026-04-05], "清明节"},
    {~D[2026-04-06], "清明节"},
    {~D[2026-05-01], "劳动节"},
    {~D[2026-05-02], "劳动节"},
    {~D[2026-05-03], "劳动节"},
    {~D[2026-05-04], "劳动节"},
    {~D[2026-05-05], "劳动节"},
    {~D[2026-06-19], "端午节"},
    {~D[2026-06-20], "端午节"},
    {~D[2026-06-21], "端午节"},
    {~D[2026-09-25], "中秋节"},
    {~D[2026-09-26], "中秋节"},
    {~D[2026-09-27], "中秋节"},
    {~D[2026-10-01], "国庆节"},
    {~D[2026-10-02], "国庆节"},
    {~D[2026-10-03], "国庆节"},
    {~D[2026-10-04], "国庆节"},
    {~D[2026-10-05], "国庆节"},
    {~D[2026-10-06], "国庆节"},
    {~D[2026-10-07], "国庆节"},
    # ---- 2027 (国办发明电〔2026〕10号) ----
    {~D[2027-01-01], "元旦"},
    {~D[2027-01-02], "元旦"},
    {~D[2027-01-03], "元旦"},
    {~D[2027-02-05], "春节"},
    {~D[2027-02-06], "春节"},
    {~D[2027-02-07], "春节"},
    {~D[2027-02-08], "春节"},
    {~D[2027-02-09], "春节"},
    {~D[2027-02-10], "春节"},
    {~D[2027-02-11], "春节"},
    {~D[2027-02-12], "春节"},
    {~D[2027-02-13], "春节"},
    {~D[2027-04-03], "清明节"},
    {~D[2027-04-04], "清明节"},
    {~D[2027-04-05], "清明节"},
    {~D[2027-05-01], "劳动节"},
    {~D[2027-05-02], "劳动节"},
    {~D[2027-05-03], "劳动节"},
    {~D[2027-05-04], "劳动节"},
    {~D[2027-05-05], "劳动节"},
    {~D[2027-06-09], "端午节"},
    {~D[2027-09-15], "中秋节"},
    {~D[2027-10-01], "国庆节"},
    {~D[2027-10-02], "国庆节"},
    {~D[2027-10-03], "国庆节"},
    {~D[2027-10-04], "国庆节"},
    {~D[2027-10-05], "国庆节"},
    {~D[2027-10-06], "国庆节"},
    {~D[2027-10-07], "国庆节"}
  ]

  # 调休/补班 make-up WORKING days: plain dates that are worked although they fall
  # on a Saturday/Sunday. Sorted ascending and unique (enforced at compile time).
  @cn_make_up_workdays [
    # ---- 2025 ----
    ~D[2025-01-26],
    ~D[2025-02-08],
    ~D[2025-04-27],
    ~D[2025-09-28],
    ~D[2025-10-11],
    # ---- 2026 ----
    ~D[2026-01-04],
    ~D[2026-02-14],
    ~D[2026-02-28],
    ~D[2026-05-09],
    ~D[2026-09-20],
    ~D[2026-10-10],
    # ---- 2027 ----
    ~D[2027-01-31],
    ~D[2027-02-14],
    ~D[2027-05-08],
    ~D[2027-09-26],
    ~D[2027-10-09]
  ]

  # Compile-time sorted/unique forms plus O(log n) lookup structures. The map-set
  # and map literals are embedded in the BEAM, so a lookup is a term lookup.
  @holidays Enum.sort_by(@cn_holidays, &elem(&1, 0), Date)
  @make_up_workdays Enum.sort(@cn_make_up_workdays, Date)

  @holiday_set MapSet.new(@holidays, &elem(&1, 0))
  @holiday_names Map.new(@holidays)
  @make_up_workday_set MapSet.new(@make_up_workdays)
  @known_calendars MapSet.new(@calendars, &String.upcase/1)

  @doc """
  The supported calendar identifiers — today `["CN"]`.

  Kept as a list (rather than a single value) so additional calendars can be
  added later without an API break.
  """
  @spec calendars() :: [calendar()]
  def calendars, do: @calendars

  @doc """
  Is `id` an accepted calendar identifier?

  Accepts an atom or a string, case-insensitively (`:cn`, `"cn"`, `" CN "` all
  match `"CN"`). Any other input returns `false`.
  """
  @spec known?(term()) :: boolean()
  def known?(id) when is_atom(id), do: known_calendar?(Atom.to_string(id))
  def known?(id) when is_binary(id), do: known_calendar?(id)
  def known?(_id), do: false

  @doc """
  The years whose arrangements are in the table, ascending: `[2025, 2026, 2027]`.
  """
  @spec supported_years() :: [pos_integer()]
  def supported_years, do: @supported_years

  @doc """
  The years whose arrangement is not yet officially published.

  Empty today: the 2025, 2026 and 2027 arrangements are all officially published.
  A year added to the table before its State Council notice appears must be listed
  here, and its entries marked `# provisional` in the table.
  """
  @spec provisional_years() :: [pos_integer()]
  def provisional_years, do: @provisional_years

  @doc """
  All statutory holiday entries as sorted `{date, name}` tuples.

  Useful for display or for verifying the table; the lookup functions use
  compile-time map sets instead.
  """
  @spec holidays() :: [{Date.t(), String.t()}]
  def holidays, do: @holidays

  @doc """
  All 调休/补班 make-up workdays (dates only), ascending.
  """
  @spec make_up_workdays() :: [Date.t()]
  def make_up_workdays, do: @make_up_workdays

  @doc """
  Is `date` a statutory Chinese public holiday (公休)?

  Accepts a `%Date{}` or a `%NaiveDateTime{}` (its date is used). Any other input,
  and any date outside the table's years, returns `false`.
  """
  @spec holiday?(Date.t() | NaiveDateTime.t() | term()) :: boolean()
  def holiday?(%Date{} = date), do: MapSet.member?(@holiday_set, date)
  def holiday?(%NaiveDateTime{} = datetime), do: holiday?(NaiveDateTime.to_date(datetime))
  def holiday?(_input), do: false

  @doc """
  Is `date` a designated 调休/补班 make-up workday?

  These are the Saturday/Sunday dates that are worked to compensate for a
  contiguous holiday block. Accepts a `%Date{}` or a `%NaiveDateTime{}` (its date
  is used); any other input, and any date outside the table's years, returns `false`.
  """
  @spec make_up_workday?(Date.t() | NaiveDateTime.t() | term()) :: boolean()
  def make_up_workday?(%Date{} = date), do: MapSet.member?(@make_up_workday_set, date)

  def make_up_workday?(%NaiveDateTime{} = datetime),
    do: make_up_workday?(NaiveDateTime.to_date(datetime))

  def make_up_workday?(_input), do: false

  @doc """
  Is `date` a non-working day for the calendar?

  Precedence (documented above and load-bearing):

      non_working_day?(date) == holiday?(date) or (weekend?(date) and not make_up_workday?(date))

  So a make-up workday on a Saturday/Sunday is a WORKING day, while a holiday on
  a Saturday/Sunday is still non-working. Accepts a `%Date{}` or a
  `%NaiveDateTime{}` (its date is used); any other input returns `false`.
  """
  @spec non_working_day?(Date.t() | NaiveDateTime.t() | term()) :: boolean()
  def non_working_day?(%Date{} = date) do
    holiday?(date) or (weekend?(date) and not make_up_workday?(date))
  end

  def non_working_day?(%NaiveDateTime{} = datetime),
    do: non_working_day?(NaiveDateTime.to_date(datetime))

  def non_working_day?(_input), do: false

  @doc """
  Is `date` a Saturday or a Sunday? Calendar-only; makes no holiday allowance.

  Accepts a `%Date{}` or a `%NaiveDateTime{}` (its date is used); any other input
  returns `false`.
  """
  @spec weekend?(Date.t() | NaiveDateTime.t() | term()) :: boolean()
  def weekend?(%Date{} = date), do: Date.day_of_week(date) in [6, 7]
  def weekend?(%NaiveDateTime{} = datetime), do: weekend?(NaiveDateTime.to_date(datetime))
  def weekend?(_input), do: false

  @doc """
  The Chinese name of the statutory holiday on `date`, or `nil` when `date` is not
  a table holiday (including any out-of-table year).

  Names follow the State Council notice wording: `"元旦"`, `"春节"`, `"清明节"`,
  `"劳动节"`, `"端午节"`, `"中秋节"`, `"国庆节"` and, for 2025's combined block,
  `"国庆节、中秋节"`. Accepts a `%Date{}` or a `%NaiveDateTime{}` (its date is used).
  """
  @spec holiday_name(Date.t() | NaiveDateTime.t() | term()) :: String.t() | nil
  def holiday_name(%Date{} = date), do: Map.get(@holiday_names, date)
  def holiday_name(%NaiveDateTime{} = datetime), do: holiday_name(NaiveDateTime.to_date(datetime))
  def holiday_name(_input), do: nil

  # Callers guarantee a binary (see `known?/1`).
  defp known_calendar?(id) do
    MapSet.member?(@known_calendars, String.upcase(String.trim(id)))
  end
end
