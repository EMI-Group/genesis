defmodule EvoGit.Agent.Cost do
  @moduledoc """
  Self-computed LLM cost for EvoGit agent runs.

  EvoGit does **not** trust the cost ReqLLM reports: token COUNTS from
  `ReqLLM.Response.usage/1` are accurate, but the cost fields are not, so this
  module recomputes them from the raw token counts plus the `llm_db` pricing
  catalog, with an EXPLICIT peak/off-peak pricing period resolved from the
  model profile's `EvoGit.PeakHours` configuration.

  ## Why we recompute (upstream defects — rationale only, do NOT "fix" ReqLLM)

  - **Double charging (ReqLLM 1.24).** `ReqLLM.Billing.calculate/2` uses
    `ReqLLM.Pricing.components/1`, which returns EVERY pricing component and
    IGNORES each component's `applies_when` condition (ReqLLM's `Component`
    struct has no such field). For `deepseek:deepseek-v4-flash` that sums BOTH
    the `off_peak` ($0.15/M in, $0.60/M out) AND the `peak` ($0.30/M in,
    $1.20/M out) components — ~2x the true rate whatever the actual tariff.
    We instead ask `LLMDB.Pricing.components_for/2` for the components that
    apply for our explicit `%{pricing_period: period}` context, so a known
    non-matching period component is excluded rather than charged.
  - **No cache discount.** The `token.cache_read*` components meter
    `"cache_read_tokens"`, a key ABSENT from ReqLLM's normalized usage map
    (which exposes the cache-hit count as `cached_tokens`), so ReqLLM bills the
    full cached-inclusive input at the full input rate. We map the component
    meter/id onto the usage keys ReqLLM actually populates, and subtract the
    cached tokens from the cache-miss input when the usage map says
    `input_includes_cached`.
  - **Scope.** Only components we fully understand are billed: `kind: "token"`
    with a positive `rate`/`per` and a recognizable token meter or `token.*`
    id, minus the model's `pricing.excluded_cost_components` (deepseek excludes
    `token.reasoning` because its completion tokens already include reasoning —
    billing it again would double-charge). Derived-rate / modifier / conditional
    shapes (`derives_from`, `multiplier`, `applies_to`, `rate_group`,
    non-standard `charge_scope`) and non-token kinds (tool/image/storage) are
    skipped, so `total_cost` is the TOKEN cost (`input_cost + output_cost`).

  ## `input_includes_cached`

  Read `:input_includes_cached` (then the string form) from the usage map —
  `ReqLLM.Usage.Normalize.normalize/1` puts that boolean there on both the
  streaming and non-streaming paths, and it is what ReqLLM's own
  `token_usage_count/2` uses. When the key is missing (an older/other-provider
  usage map) it is DERIVED deterministically: input includes cached when
  `cached_tokens > 0 and cached_tokens <= input_tokens` (the canonical
  OpenAI-style shape). Which path was taken is logged at `:debug`.

  ## Never crashes

  Every public function is total and wrapped in a `try/rescue/catch`: any
  unexpected input, missing agent state, dead scheduler, unresolvable model
  spec, empty component selection or internal error logs (at `:warning` for an
  exception, `:debug` for an expected miss) and returns `nil`, which makes the
  callers in `EvoGit.Agent.ToolDispatch` / `EvoGit.Agent.ContextCompression`
  keep ReqLLM's reported cost instead of overriding it.

  ## Known limitations

  - Only components resolvable from a `pricing_period` context are billed. A
    pricing product whose components are additionally gated behind a
    non-time condition (e.g. a GLM coding-plan credit tariff) yields NO
    applicable component, so those profiles keep the reported cost.
  - A map model spec carries no catalog pricing of its own (that is why
    ReqLLM reports `$0` for a `[[llm.models]]` profile with a `base_url`/`extra`
    override); we therefore fall back to the plain `"provider:id"` catalog
    entry for the price lookup.
  - Tool / image / storage priced components are not billed, so `total_cost` is
    the TOKEN cost.

  The `%EvoGit.Agent.Usage{}` struct shape is NOT touched by this module (no
  field is added/removed) — only the three cost fields of an already-built
  struct are overridden by `apply_to_usage/3`.
  """

  require Logger

  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.PeakHours

  @typedoc "Recomputed token cost for ONE LLM request."
  @type costs :: %{input_cost: float(), output_cost: float(), total_cost: float()}

  @typedoc ~s(Pricing period — "peak" | "off_peak".)
  @type period :: String.t()

  # Default divisor when a component declares no usable `per`.
  @default_per 1_000_000

  @peak "peak"
  @off_peak "off_peak"

  # Component `meter` → canonical token-count group (the value names documented
  # by `LLMDB.Pricing`'s `@canonical_token_groups`).
  @meter_groups %{
    "input_tokens" => :input,
    "output_tokens" => :output,
    "cache_read_tokens" => :cache_read,
    "cache_write_tokens" => :cache_write,
    "reasoning_tokens" => :reasoning
  }

  # Component id prefix → token-count group, used when a component carries no
  # (known) `meter`. Order matters: the more specific `token.cache_*` prefixes
  # must be tested before the legacy `token.cache` — mirrors
  # `ReqLLM.Billing.@token_id_map`.
  @id_prefix_groups [
    {"token.input", :input},
    {"token.output", :output},
    {"token.reasoning", :reasoning},
    {"token.cache_read", :cache_read},
    {"token.cache_write", :cache_write},
    {"token.cache", :cache_read}
  ]

  # `charge_scope` values we understand; any other explicit scope is an odd
  # shape we deliberately do not reason about.
  @standard_charge_scopes ["full_request"]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Recomputes the token cost of ONE LLM request.

    * `usage_map` — the raw usage map from `ReqLLM.Response.usage/1` (may be
      `nil`; atom- or string-keyed counts are both accepted);
    * `model_spec` — anything `ReqLLM.model/1` resolves (a `"provider:model"`
      string or a map spec); an already-resolved `%LLMDB.Model{}` is used
      directly;
    * `period` — `"peak"` or `"off_peak"` (anything else is treated as
      `"off_peak"`).

  Returns `nil` (let the caller keep ReqLLM's reported cost) when the usage map
  is not a map, the model cannot be resolved, no pricing component applies for
  the given period, or no selected component is a plain token rate we
  understand. Otherwise returns
  `%{input_cost: float, output_cost: float, total_cost: float}` rounded to 6
  decimals, where `input_cost` covers `token.input*`/`token.cache*` components,
  `output_cost` covers `token.output*`/`token.reasoning*` components and
  `total_cost = input_cost + output_cost`.
  """
  @spec recompute(map() | nil, term(), term()) :: costs() | nil
  def recompute(usage_map, model_spec, period) do
    safe("recompute/3", nil, fn ->
      do_recompute(usage_map, model_spec, normalize_period(period))
    end)
  end

  @doc """
  Recomputes the token cost of ONE LLM request for a scheduled agent.

  Resolves the agent's model spec + model profile id from
  `EvoGit.AgentScheduler.get_agent_state/1` and the pricing period from
  `period_for_model_id/1`. `nil` (never raising) whenever the agent state is
  gone or `recompute/3` cannot produce a cost.
  """
  @spec recompute_for_agent(map() | nil, term()) :: costs() | nil
  def recompute_for_agent(usage_map, agent_id) do
    safe("recompute_for_agent/2", nil, fn ->
      case agent_state(agent_id) do
        nil ->
          nil

        state ->
          model_spec = Map.get(state, :llm_model)
          period = period_for_model_id(Map.get(state, :model_id))
          recompute(usage_map, model_spec, period)
      end
    end)
  end

  @doc """
  Overrides ONLY the cost fields of an already-built `%Usage{}`.

  This is the single shared wiring helper for both cost-producing call sites
  (`EvoGit.Agent.ToolDispatch.update_turn_usage/2` and
  `EvoGit.Agent.ContextCompression.compress_if_needed/2`): the token counts
  stay whatever `Usage.from_response_usage/1` read (they are accurate), and
  when `recompute_for_agent/2` returns `nil` the ReqLLM-reported cost is kept
  verbatim.
  """
  @spec apply_to_usage(Usage.t(), map() | nil, term()) :: Usage.t()
  def apply_to_usage(%Usage{} = usage, raw_usage_map, agent_id) do
    case recompute_for_agent(raw_usage_map, agent_id) do
      nil ->
        usage

      %{input_cost: input_cost, output_cost: output_cost, total_cost: total_cost} ->
        %{
          usage
          | input_cost: input_cost,
            output_cost: output_cost,
            total_cost: total_cost
        }
    end
  end

  @doc """
  Pricing period (`"peak"` | `"off_peak"`) for a configured model profile id.

  Looks the id up in `EvoGit.AgentScheduler.get_config(:model_profiles)` (atom-
  or string-keyed ids tolerated) and delegates to `period_for_profile/1`.
  No profile / no peak configuration / ANY error → `"off_peak"` (the normal
  tariff).
  """
  @spec period_for_model_id(term()) :: period()
  def period_for_model_id(model_id) do
    safe("period_for_model_id/1", @off_peak, fn ->
      case find_profile(model_id) do
        nil -> @off_peak
        profile -> period_for_profile(profile)
      end
    end)
  end

  @doc """
  Pricing period (`"peak"` | `"off_peak"`) for ONE model profile map.

  Reuses `EvoGit.PeakHours` for all window/day math (never re-implemented
  here): validated windows (`[]`/absent/invalid → disabled → `"off_peak"`),
  the profile's canonical `off_peak_days`, and the profile's wall clock (the
  profile `timezone` when present, resolved from the `:peak_hours_utc_now_fun`
  seam and falling back to local wall clock on any resolution error — the same
  pattern as `EvoGit.PeakHourEngine`). Any error path → `"off_peak"`, never a
  raise.
  """
  @spec period_for_profile(map()) :: period()
  def period_for_profile(profile) when is_map(profile) do
    safe("period_for_profile/1", @off_peak, fn ->
      with {:ok, windows} <- PeakHours.validate_windows(field(profile, :peak_hours)),
           windows when windows != [] <- windows do
        off_peak_days = profile_off_peak_days(profile)
        wall_clock = profile_wall_clock(profile)

        if PeakHours.in_peak?(windows, wall_clock, off_peak_days), do: @peak, else: @off_peak
      else
        _disabled_or_invalid -> @off_peak
      end
    end)
  end

  def period_for_profile(_profile), do: @off_peak

  # ---------------------------------------------------------------------------
  # Recomputation
  # ---------------------------------------------------------------------------

  defp do_recompute(usage_map, model_spec, period) when is_map(usage_map) do
    case resolve_model(model_spec) do
      nil ->
        nil

      %LLMDB.Model{} = model ->
        compute(model, usage_map, period)
    end
  end

  defp do_recompute(other, _model_spec, _period) do
    Logger.debug("EvoGit.Agent.Cost: no usage map to recompute from (got #{describe(other)})")

    nil
  end

  # Resolves the model spec to an `%LLMDB.Model{}` (pricing catalog entry).
  #
  # A hand-built map model spec — the shape `EvoGit.Config` keeps for a
  # `[[llm.models]]` profile that carries a `base_url`/`extra` override —
  # resolves to a model WITHOUT catalog pricing, so the price lookup would find
  # nothing (ReqLLM itself reports a $0 cost for those profiles). Whenever the
  # resolved model carries no pricing components we fall back to the plain
  # `"provider:id"` catalog entry: the same model, hence the same tariff.
  defp resolve_model(%LLMDB.Model{} = model), do: with_catalog_pricing(model)

  defp resolve_model(spec) do
    case ReqLLM.model(spec) do
      {:ok, %LLMDB.Model{} = model} ->
        with_catalog_pricing(model)

      other ->
        Logger.debug(
          "EvoGit.Agent.Cost: could not resolve model #{describe(spec)} " <>
            "(ReqLLM.model/1 -> #{describe(other)})"
        )

        nil
    end
  end

  defp with_catalog_pricing(%LLMDB.Model{} = model) do
    if pricing_components_empty?(model) do
      catalog_model(model) || model
    else
      model
    end
  end

  defp catalog_model(%LLMDB.Model{provider: provider, id: id})
       when is_atom(provider) and is_binary(id) and id != "" do
    case ReqLLM.model("#{provider}:#{id}") do
      {:ok, %LLMDB.Model{} = catalog} ->
        if pricing_components_empty?(catalog), do: nil, else: catalog

      _other ->
        nil
    end
  end

  defp catalog_model(_model), do: nil

  defp pricing_components_empty?(%LLMDB.Model{} = model) do
    case field(field(model, :pricing) || %{}, :components) do
      list when is_list(list) and list != [] -> false
      _other -> true
    end
  end

  # Core computation: select the period-applicable components, drop the model's
  # excluded ones and every component whose shape we do not understand, then
  # bill each remaining plain token rate against the raw usage counts.
  defp compute(%LLMDB.Model{} = model, usage_map, period) do
    components = priced_components(model, period)

    if components == [] do
      Logger.debug(
        "EvoGit.Agent.Cost: no pricing component applies for period #{period} " <>
          "(model #{describe_model(model)}) — keeping the reported cost"
      )

      nil
    else
      excluded = excluded_components(model)

      {input_cost, output_cost, usable} =
        components
        |> Enum.reject(&(component_id(&1) in excluded))
        |> Enum.reduce({0.0, 0.0, 0}, fn component, {input_acc, output_acc, usable} ->
          case component_cost(component, usage_map) do
            {:cost, {cost, :input}} -> {round6(input_acc + cost), output_acc, usable + 1}
            {:cost, {cost, :output}} -> {input_acc, round6(output_acc + cost), usable + 1}
            :skip -> {input_acc, output_acc, usable}
          end
        end)

      if usable == 0 do
        Logger.debug(
          "EvoGit.Agent.Cost: none of the #{length(components)} period-applicable " <>
            "pricing component(s) of model #{describe_model(model)} is a plain token " <>
            "rate we understand — keeping the reported cost"
        )

        nil
      else
        %{
          input_cost: input_cost,
          output_cost: output_cost,
          total_cost: round6(input_cost + output_cost)
        }
      end
    end
  end

  # The components that actually apply for our explicit pricing period.
  # `LLMDB.Pricing.components_for/2` marks a component whose `applies_when`
  # condition is KNOWN to not match (`pricing_period` "peak" vs "off_peak") as
  # `:excluded` — it is not returned at all — so the peak and off-peak variants
  # of the same meter can never both be charged.
  defp priced_components(%LLMDB.Model{} = model, period) do
    model
    |> LLMDB.Pricing.components_for(%{pricing_period: period})
    |> Map.get(:components, [])
  end

  # The model's `pricing.excluded_cost_components` (atom- or string-keyed,
  # never nil) as a MapSet of ids we must not bill.
  defp excluded_components(%LLMDB.Model{} = model) do
    pricing = field(model, :pricing) || %{}

    case field(pricing, :excluded_cost_components) do
      list when is_list(list) -> MapSet.new(list)
      _other -> MapSet.new()
    end
  end

  # Bills ONE component: `{:cost, {cost, :input | :output}}` for a plain token
  # rate we fully understand, `:skip` (with a :debug log) for everything else.
  defp component_cost(component, usage_map) do
    id = component_id(component)
    rate = number_field(component, :rate)
    group = token_group(component)
    bucket = cost_bucket(id)

    cond do
      not token_component?(component) ->
        skip(component, "kind is not a token component")

      odd_component_shape?(component) ->
        skip(component, "derived-rate / modifier / conditional shape")

      not (is_number(rate) and rate > 0) ->
        skip(component, "rate is not a positive number")

      is_nil(group) ->
        skip(component, "no meter and no recognizable token id prefix")

      is_nil(bucket) ->
        skip(component, "id is neither an input nor an output token rate")

      true ->
        per = normalize_per(number_field(component, :per))
        count = token_count(usage_map, group)

        {:cost, {round6(count / per * rate), bucket}}
    end
  end

  # ---------------------------------------------------------------------------
  # Component field readers (atom- OR string-keyed — the llm_db snapshot loader
  # atomizes known keys but leaves `applies_when` opaque, and hand-built map
  # model specs may be either)
  # ---------------------------------------------------------------------------

  defp component_id(component), do: field(component, :id)

  defp token_component?(component) do
    field(component, :kind) in ["token", :token]
  end

  # Derived rates (`derives_from`), multipliers, modifiers (`applies_to`), rate
  # groups and non-standard charge scopes are shapes whose semantics we cannot
  # resolve here — bill nothing for them rather than guessing.
  defp odd_component_shape?(component) do
    Enum.any?(
      [:derives_from, :multiplier, :applies_to, :rate_group, :rate_group_policy],
      fn key ->
        not is_nil(field(component, key))
      end
    ) or odd_charge_scope?(component)
  end

  defp odd_charge_scope?(component) do
    case field(component, :charge_scope) do
      nil -> false
      scope -> scope not in @standard_charge_scopes
    end
  end

  # The token-count group a component bills: its declared `meter` when we know
  # it, else the component id's `token.*` prefix.
  defp token_group(component) do
    case field(component, :meter) do
      meter when is_binary(meter) ->
        Map.get(@meter_groups, meter) || group_from_id(component_id(component))

      _other ->
        group_from_id(component_id(component))
    end
  end

  defp group_from_id(id) when is_binary(id) do
    Enum.find_value(@id_prefix_groups, fn {prefix, group} ->
      if String.starts_with?(id, prefix), do: group
    end)
  end

  defp group_from_id(_id), do: nil

  # Input vs output bucket of a component id (mirrors `ReqLLM.Billing`'s
  # `token_input_item?/1` / `token_output_item?/1` classification).
  defp cost_bucket(id) when is_binary(id) do
    cond do
      String.starts_with?(id, "token.input") or String.starts_with?(id, "token.cache") ->
        :input

      String.starts_with?(id, "token.output") or String.starts_with?(id, "token.reasoning") ->
        :output

      true ->
        nil
    end
  end

  defp cost_bucket(_id), do: nil

  defp skip(component, reason) do
    Logger.debug(
      "EvoGit.Agent.Cost: skipping pricing component #{describe(component_id(component))} " <>
        "(#{reason})"
    )

    :skip
  end

  # ---------------------------------------------------------------------------
  # Token counts
  # ---------------------------------------------------------------------------

  # Cache-MISS input: the normalized `input_tokens` is cached-INCLUSIVE for the
  # OpenAI-style providers, and the cache-hit tokens are billed separately by
  # the `token.cache_read*` components. Mirrors the intent of ReqLLM's
  # `token_usage_count/2`.
  defp token_count(usage_map, :input) do
    input = count(usage_map, :input_tokens)

    if input_includes_cached?(usage_map) do
      max(input - count(usage_map, :cached_tokens) - count(usage_map, :cache_creation_tokens), 0)
    else
      input
    end
  end

  defp token_count(usage_map, :output), do: count(usage_map, :output_tokens)

  # The catalog meters cache hits as `cache_read_tokens`, but the normalized
  # usage map exposes the SAME number as `cached_tokens` (this mismatch is
  # exactly why ReqLLM gives no cache discount).
  defp token_count(usage_map, :cache_read), do: count(usage_map, :cached_tokens)

  defp token_count(usage_map, :cache_write), do: count(usage_map, :cache_creation_tokens)

  defp token_count(usage_map, :reasoning), do: count(usage_map, :reasoning_tokens)

  # Atom- or string-keyed non-negative number from the usage map; anything
  # missing / non-numeric counts as 0.
  defp count(usage_map, key) do
    case field(usage_map, key) do
      value when is_number(value) and value >= 0 -> value
      _other -> 0
    end
  end

  # Reads the normalized `:input_includes_cached` boolean, else DERIVES it
  # (cached tokens present and not exceeding the input total). Both paths are
  # logged at :debug.
  defp input_includes_cached?(usage_map) do
    case boolean_field(usage_map, :input_includes_cached) do
      {:ok, value} ->
        Logger.debug(
          "EvoGit.Agent.Cost: input_includes_cached=#{inspect(value)} (read from the usage map)"
        )

        value

      :error ->
        derived = derive_input_includes_cached(usage_map)

        Logger.debug(
          "EvoGit.Agent.Cost: input_includes_cached=#{inspect(derived)} (derived: " <>
            "cached_tokens>0 and cached_tokens<=input_tokens)"
        )

        derived
    end
  end

  defp derive_input_includes_cached(usage_map) do
    cached = count(usage_map, :cached_tokens)
    cached > 0 and cached <= count(usage_map, :input_tokens)
  end

  defp boolean_field(map, key) do
    case field(map, key) do
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp normalize_per(per) when is_number(per) and per > 0, do: per
  defp normalize_per(_per), do: @default_per

  defp number_field(map, key) do
    case field(map, key) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp round6(number), do: Float.round(number, 6)

  # ---------------------------------------------------------------------------
  # Period resolution
  # ---------------------------------------------------------------------------

  # Only the explicit "peak" string selects the peak tariff; everything else
  # (including nil, atoms and unknown strings) is the normal off-peak tariff.
  defp normalize_period(@peak), do: @peak
  defp normalize_period(_other), do: @off_peak

  defp find_profile(model_id) do
    Enum.find(profiles(), fn profile ->
      normalize_id(field(profile, :id)) == normalize_id(model_id)
    end)
  end

  defp profiles do
    case AgentScheduler.get_config(:model_profiles) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
  defp normalize_id(_id), do: nil

  # The profile's canonical off-peak-day list; absent / invalid → [] (disabled),
  # never a raise — `PeakHours.validate_days/1` is the single parse path.
  defp profile_off_peak_days(profile) do
    case PeakHours.validate_days(field(profile, :off_peak_days)) do
      {:ok, days} -> days
      {:error, _reason} -> []
    end
  end

  # The profile's wall clock for the in-peak check: a `timezone` profile
  # resolves the UTC clock seam into the zone's wall clock, falling back to the
  # local wall clock on any resolution error; a profile without a timezone uses
  # the local wall clock directly.
  defp profile_wall_clock(profile) do
    now = now_fun()

    case profile_timezone(profile) do
      nil ->
        now

      tz ->
        case PeakHours.wall_clock_in(tz, utc_now_fun()) do
          {:ok, wall_clock} ->
            wall_clock

          {:error, reason} ->
            Logger.debug(
              "EvoGit.Agent.Cost: could not resolve timezone #{inspect(tz)} " <>
                "(#{inspect(reason)}) — using the local wall clock"
            )

            now
        end
    end
  end

  defp profile_timezone(profile) do
    case field(profile, :timezone) do
      tz when is_binary(tz) and tz != "" -> tz
      _other -> nil
    end
  end

  defp now_fun do
    fun = Application.get_env(:evo_git, :peak_hours_now_fun, &NaiveDateTime.local_now/0)
    fun.()
  end

  defp utc_now_fun do
    fun = Application.get_env(:evo_git, :peak_hours_utc_now_fun, &DateTime.utc_now/0)
    fun.()
  end

  # ---------------------------------------------------------------------------
  # Agent state / safety net
  # ---------------------------------------------------------------------------

  defp agent_state(agent_id) do
    with id when not is_nil(id) <- agent_id,
         {:ok, state} when is_map(state) <- AgentScheduler.get_agent_state(id) do
      state
    else
      _other -> nil
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil

  # Total boundary: an exception (or an exit from a scheduler GenServer.call to
  # a dead scheduler) is logged and turned into `fallback` — a cost
  # recomputation must NEVER take down an agent run.
  defp safe(label, fallback, fun) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "EvoGit.Agent.Cost: #{label} failed (#{Exception.message(error)}) — " <>
          "keeping the reported cost"
      )

      fallback
  catch
    kind, reason ->
      Logger.warning(
        "EvoGit.Agent.Cost: #{label} failed (#{inspect(kind)}: #{inspect(reason)}) — " <>
          "keeping the reported cost"
      )

      fallback
  end

  # Log-safe description: a model spec may carry credentials, so only identity
  # fields are ever rendered.
  defp describe(spec) when is_binary(spec), do: inspect(spec)

  defp describe(%LLMDB.Model{} = model), do: describe_model(model)

  defp describe(spec) when is_map(spec) do
    provider = field(spec, :provider)
    id = field(spec, :id) || field(spec, :model)

    if is_nil(provider) and is_nil(id) do
      "a model spec"
    else
      "#{inspect(provider)}:#{inspect(id)}"
    end
  end

  defp describe(spec) when is_atom(spec), do: inspect(spec)
  defp describe(spec) when is_number(spec) or is_boolean(spec), do: inspect(spec)

  # Any other shape (tuple/keyword model specs can carry `api_key`/`base_url`)
  # is reduced to its type so no credential can reach a log line.
  defp describe(spec), do: "a #{type_name(spec)}"

  defp type_name(spec) when is_tuple(spec), do: "tuple"
  defp type_name(spec) when is_list(spec), do: "list"
  defp type_name(spec) when is_pid(spec), do: "pid"
  defp type_name(spec) when is_function(spec), do: "function"
  defp type_name(_spec), do: "term"

  defp describe_model(model) do
    "#{inspect(Map.get(model, :provider))}:#{inspect(Map.get(model, :id))}"
  end
end
