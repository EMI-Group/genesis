defmodule EvoDash.Test.SettingsAwait do
  @moduledoc """
  The Settings suites' ONE way to wait for a `/settings` page to reach a state
  that PROVES the work a test depends on has finished — and to FAIL LOUDLY the
  moment it provably has not.

  Every wait here is evidence-based and bounded (`@async_wait_budget_ms`,
  `@assigns_timeout_ms`); none is a fixed sleep, none is a negative window, and
  none samples a moving target. The page is read through
  `:sys.get_state(view.pid, #{30_000})`, a synchronous round trip, so an observed
  value has already had every earlier result message applied by the LiveView
  (its mailbox is processed in order) — the observation IS the witness.

  ## Why the old per-suite helpers were wrong

  `wait_settings(view, &(not &1[:config_saving]))` proves nothing about a SAVE:
  `EvoDashWeb.SettingsLive.ConfigSave.start/4` assigns `config_saving: true` only
  when a write actually LAUNCHES (`config_save.ex:157-160`), so every refusal
  path — `busy?/1` (`:save_in_progress`), `pending_scope?/1`
  (`:remote_not_connected`), `CategoryEvents.persist_file_config/4`'s
  `config_loaded_scope` mismatch (`:configuration_not_loaded`), a `SafeCall.start`
  startup failure — leaves the flag `false` and such a wait returns INSTANTLY,
  with the test then reading a page that never changed.

  Draining `EvoDash.TaskSupervisor` child pids is equally wrong for a MOUNT: the
  mount chain is a sequence (node-data load → apply → OAuth/auth-status load),
  so a single pid sample can be empty in the gap between one task exiting and the
  next being spawned, and the drain reports "settled" while the page is still
  loading.

  ## What it provides

    * `settled?/1` — the page's own authoritative markers (see below).
    * `await_settled/2` — bounded wait for `settled?/1`, for mounts.
    * `await_save/4` — runs the click and waits for ITS RECEIPT, failing with the
      refusal reason when the page instead reports a failure.
    * `await_rendered/3` — bounded `has_element?` poll, for "the surface is
      rendered now" claims, so a test never infers the DOM from an unrelated
      assign change.
    * `await_assigns/4` — the documented escape hatch for a wait on a specific
      authoritative assign that is neither a mount settle, a save receipt nor a
      rendered element; it REQUIRES a human-readable expectation string.
    * `assigns/1` — the shared `:sys.get_state` read.

  ## The settled-state predicate

  A page is settled exactly when no owned write, no owned load and no pending
  scope transition remains:

      settled?(assigns) =
        config_save_request == nil                 # ConfigSave owns no request
        and config_saving != true                  # no launched write indicator
        and config_save_owner is nil or dead        # no live writer guard
        and config_load_wait_ref == nil             # no invalidated-writer drain
        and custom_agents_loading != true           # mount loader landed
        and custom_tools_loading != true            # mount loader landed
        and (not apply_expected? or snapshot_applied?)

  `snapshot_applied?` is `config_loaded_scope == ConfigSave.scope(socket)` — the
  very scope match `CategoryEvents.persist_file_config/4` requires before it will
  build a whole-file write (`category_events.ex:288`) — PLUS
  `auth_status_seq >= 1`: `config_loaded_scope` is SEEDED to `{nil, node()}`
  (`page_state.ex:128`), i.e. already equal to a local socket's scope, so the
  scope match alone cannot prove the async node-data load was APPLIED. The apply
  always ends with `EvoDashWeb.SettingsLive.start_auth_status_load/1`
  (`async_results.ex:516` → `settings_live.ex:988-994`), which bumps
  `auth_status_seq`; on a fresh local mount that counter is `0` until the first
  apply, so `>= 1` witnesses it. On a `?node=` mount `reset_config_scope/1` bumps
  the counter first, but it also nils `config_loaded_scope`, so the scope match
  still has to come from the apply.

  A NON-LOCAL scope may legitimately land its snapshot as UNAVAILABLE: when the
  remote fetch fails, `apply_node_data_results/3` deliberately leaves
  `config_loaded_scope` nil (`async_results.ex:456-459`) while it applies the
  degraded `file_config`/`config_status` and a `remote_config_error`
  (`node_data.ex:114-128`). That IS an authoritative apply — the page has nothing
  further coming for this scope — so for a non-local viewed node the predicate
  also accepts `remote_config_error != nil`, which the mount seeds to `nil`
  (`page_state.ex:193`) and only that apply assigns. Both loading flags
  (`custom_agents_loading`/`custom_tools_loading`, seeded `true` at
  `page_state.ex:169`/`:179`, cleared only by the apply) must still be false, so
  the acceptance cannot fire before an apply has happened at all.

  `apply_expected?` is false only for a requested-but-not-connected remote target
  (`PageState.pending_remote_target?/1`), where `start_node_data_load/2`
  deliberately spawns nothing and `config_loaded_scope` stays nil — such a page
  is settled once its fire-and-forget loaders land.

  Deliberately NOT part of the predicate:

    * `settings_load_seq` — a GENERATION stamp, not an in-flight marker:
      `PageState.invalidate_config_load/1` bumps it both when a load starts and
      when a SAVE launches (`category_events.ex:291`).
    * `config_status_token` — the identity of the LAST saved-status re-fetch, not
      a pending one: `CategoryEvents.refresh_saved_config_status/1` assigns it and
      the result handler never clears it (`async_results.ex:81-96`), so requiring
      it to be nil would hang every remote save.
    * the OAuth/auth-status load itself — fire-and-forget credential status whose
      absence renders a neutral `:unknown`; a test that asserts a VERDICT awaits
      the rendered verdict instead.

  Known limit: a SAME-SCOPE reload (`AsyncResults.config_load_wait_down/1` after
  an invalidated writer) carries no in-flight assign, so `settled?/1` cannot see
  it. Closing that needs a production `config_loaded_seq`/`config_load_pending`
  marker; until then this await describes the mount and save chains only.

  ## Save receipts

  `await_save/4` MUST wrap the click (it captures the pre-click baseline itself).
  A save is complete when the socket carries the receipt's own consequence: a
  bump of `llm_test_seq` — `CategoryEvents.apply_config_receipt/1` always routes
  the receipt's `file_config` through `LlmTestEvents.assign_test_config/2`, which
  bumps it (`llm_test_events.ex:166-172` → `:193-195`) — together with the success
  flash and `settled?/1`. That is what makes two consecutive saves with the SAME
  success message distinguishable, which a flash-equality-only wait cannot do.
  A refusal lands an error flash in the same update and fails immediately, with
  the reason the page reported.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest, only: [has_element?: 2, render: 1]

  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.PageState

  @async_wait_budget_ms 30_000
  @assigns_timeout_ms 30_000
  @poll_ms 2
  @error_flash_prefix "Failed to save configuration:"

  @doc "The suites' bounded wait budget in milliseconds (a `:budget_ms` override wins)."
  def async_wait_budget_ms, do: @async_wait_budget_ms

  @doc "The `:sys.get_state/2` timeout used for every page read."
  def assigns_timeout_ms, do: @assigns_timeout_ms

  @doc """
  The viewed page's assigns, read through the LiveView process itself.

  `:sys.get_state/2` is a synchronous round trip, so everything the page had
  queued before the read — every async result, every diff — is already applied.
  The explicit timeout is load-bearing: `:sys.get_state/1`'s 5 s default exits
  the test whenever the page is starved on this shared host.
  """
  def assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  @doc """
  True when the page has no owned write, no owned load and no pending scope
  transition left (see the moduledoc for the exact conjunction and why each
  clause is the authoritative marker).
  """
  def settled?(assigns) when is_map(assigns) do
    not write_in_flight?(assigns) and not load_in_flight?(assigns)
  end

  @doc """
  Waits until `settled?/1` holds, then renders once (the proxy applies queued
  diffs on the way in) and returns the settled assigns.

  Options: `:budget_ms` (default `#{30_000}`).
  """
  def await_settled(view, opts \\ []) do
    budget_ms = budget(opts)

    state =
      poll(
        view,
        budget_ms,
        "the Settings page to settle (no owned save, no owned load, the viewed scope's config snapshot applied)",
        fn _view, current ->
          if settled?(current), do: {:ok, current}, else: :pending
        end
      )

    _ = render(view)
    state
  end

  @doc """
  Runs `click` (a 0-arity function performing the event) and waits for the SAVE
  RECEIPT it produced, returning the rendered HTML.

  `expected_msg` is the success flash the save's `success_msg` produces
  (e.g. `"Provider account saved."`). The wait fails immediately — with the
  reason the page reported — when the page flashes a save error instead, and at
  the budget with a full state report when no save was started at all (a refused
  wizard step, a validation error) or when the receipt carries another message.

  Options: `:budget_ms` (default `#{30_000}`).
  """
  def await_save(view, expected_msg, click, opts \\ [])
      when is_binary(expected_msg) and is_function(click, 0) do
    before = assigns(view)
    baseline_seq = before[:llm_test_seq]
    _ = click.()
    budget_ms = budget(opts)

    poll(
      view,
      budget_ms,
      "the save receipt #{inspect(expected_msg)} (a bumped llm_test_seq, the success flash and a settled page)",
      fn view, current -> decide_save(view, before, baseline_seq, expected_msg, current) end
    )
  end

  @doc """
  Waits until `selector` is rendered, returning the rendered HTML.

  Use this instead of inferring a surface from an unrelated assign change — the
  element being present IS the claim.

  Options: `:budget_ms` (default `#{30_000}`).
  """
  def await_rendered(view, selector, opts \\ []) when is_binary(selector) do
    budget_ms = budget(opts)

    poll(view, budget_ms, "the element #{inspect(selector)} to be rendered", fn view, _current ->
      if has_element?(view, selector), do: {:ok, render(view)}, else: :pending
    end)
  end

  @doc """
  The documented escape hatch: waits until `predicate` holds for the page's
  assigns, then renders and returns the assigns.

  `expectation` is a human-readable statement of what is awaited; it is part of
  every failure message, so a timeout reads as a claim that did not hold instead
  of "an authoritative state was not reached".

  Options: `:budget_ms` (default `#{30_000}`).
  """
  def await_assigns(view, expectation, predicate, opts \\ [])
      when is_binary(expectation) and is_function(predicate, 1) do
    budget_ms = budget(opts)

    state =
      poll(view, budget_ms, expectation, fn _view, current ->
        if predicate.(current), do: {:ok, current}, else: :pending
      end)

    _ = render(view)
    state
  end

  # ── the settled predicate ──────────────────────────────────────────────────
  defp write_in_flight?(assigns) do
    not is_nil(assigns[:config_save_request]) or
      assigns[:config_saving] == true or
      live_pid?(assigns[:config_save_owner]) or
      not is_nil(assigns[:config_load_wait_ref])
  end

  defp load_in_flight?(assigns) do
    assigns[:custom_agents_loading] == true or assigns[:custom_tools_loading] == true or
      (apply_expected?(assigns) and not snapshot_applied?(assigns))
  end

  # A requested-but-not-connected remote target spawns no node-data load, so
  # there is no apply to wait for.
  defp apply_expected?(assigns), do: not PageState.pending_remote_target?(socket(assigns))

  defp snapshot_applied?(assigns) do
    (assigns[:config_loaded_scope] == ConfigSave.scope(socket(assigns)) or
       unavailable_snapshot_applied?(assigns)) and (assigns[:auth_status_seq] || 0) >= 1
  end

  # A non-local scope's snapshot may land as "unavailable" (a failed remote
  # fetch): `apply_node_data_results/3` then keeps `config_loaded_scope` nil and
  # assigns `remote_config_error` instead. That is still the scope's ONE
  # authoritative apply, so it counts — but only for a non-local viewed node and
  # only once the mount's own loading flags have been cleared by an apply.
  defp unavailable_snapshot_applied?(assigns) do
    not is_nil(assigns[:remote_config_error]) and
      (assigns[:current_node] || node()) != node() and
      assigns[:custom_agents_loading] == false and assigns[:custom_tools_loading] == false
  end

  defp live_pid?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp live_pid?(_other), do: false

  # ── the save receipt ───────────────────────────────────────────────────────
  defp decide_save(view, before, baseline_seq, expected_msg, current) do
    error = flash_value(current, :error)

    cond do
      not is_nil(error) and error != flash_value(before, :error) ->
        {:halt, refusal_message(expected_msg, error, current)}

      receipt?(current, baseline_seq, expected_msg) ->
        {:ok, render(view)}

      true ->
        :pending
    end
  end

  defp receipt?(current, baseline_seq, expected_msg) do
    settled?(current) and (current[:llm_test_seq] || 0) > (baseline_seq || 0) and
      flash_value(current, :info) == expected_msg
  end

  # Phoenix stores the socket's flash map with STRING keys, while `put_flash/3`
  # models them as atoms — read BOTH spellings so a receipt can never be
  # invisible to the wait that is looking for it.
  defp flash_value(assigns, kind) when kind in [:info, :error] do
    case assigns[:flash] do
      %{} = flash -> Map.get(flash, Atom.to_string(kind)) || Map.get(flash, kind)
      _other -> nil
    end
  end

  defp refusal_message(expected_msg, error, current) do
    """
    the Settings save was REFUSED — the page did not produce the receipt #{inspect(expected_msg)}.
    The page flashed: #{inspect(error)}#{refusal_reason(error)}
    #{state_report(current)}\
    """
  end

  defp refusal_reason(error) when is_binary(error) do
    case String.split(error, @error_flash_prefix, parts: 2) do
      [_prefix, reason] -> "\nReported reason: #{String.trim(reason)}"
      _other -> ""
    end
  end

  defp refusal_reason(_error), do: ""

  # ── bounded polling ────────────────────────────────────────────────────────
  defp poll(view, budget_ms, expectation, decide) do
    poll(view, budget_ms, expectation, decide, System.monotonic_time(:millisecond) + budget_ms)
  end

  defp poll(view, budget_ms, expectation, decide, deadline) do
    current = assigns(view)

    case decide.(view, current) do
      {:ok, value} ->
        value

      {:halt, message} ->
        flunk(message)

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          #{expectation} did not happen within #{budget_ms} ms.
          #{state_report(current)}\
          """)
        else
          # The suites' poll cadence: a bounded receive, never a fixed wait.
          receive do
          after
            @poll_ms -> :ok
          end

          poll(view, budget_ms, expectation, decide, deadline)
        end
    end
  end

  defp budget(opts) do
    case Keyword.get(opts, :budget_ms, @async_wait_budget_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      other -> raise ArgumentError, "expected a positive :budget_ms, got: #{inspect(other)}"
    end
  end

  # The failure evidence: exactly the markers the predicate and the receipt read,
  # so a timeout names WHICH clause never became true.
  defp state_report(assigns) do
    """
    Settings page state at the deadline:
      settled?:               #{settled?(assigns)}
      config_saving:          #{inspect(assigns[:config_saving])}
      config_save_request:    #{inspect(request_summary(assigns[:config_save_request]))}
      config_save_owner:      #{inspect(owner_state(assigns[:config_save_owner]))}
      config_load_wait_ref:   #{inspect(assigns[:config_load_wait_ref])}
      config_loaded_scope:    #{inspect(assigns[:config_loaded_scope])} (viewed scope: #{inspect(ConfigSave.scope(socket(assigns)))}, pending remote target: #{inspect(PageState.pending_remote_target?(socket(assigns)))})#{apply_evidence(assigns)}
      custom_agents_loading:  #{inspect(assigns[:custom_agents_loading])}
      custom_tools_loading:   #{inspect(assigns[:custom_tools_loading])}
      auth_status_seq:        #{inspect(assigns[:auth_status_seq])} (>= 1 proves a node-data apply)
      settings_load_seq:      #{inspect(assigns[:settings_load_seq])}
      llm_test_seq:           #{inspect(assigns[:llm_test_seq])}  llm_test_status: #{inspect(assigns[:llm_test_status])}
      flash:                  #{inspect(assigns[:flash])}  (info: #{inspect(flash_value(assigns, :info))}, error: #{inspect(flash_value(assigns, :error))})
      per_category_errors:    #{inspect(assigns[:per_category_errors])}
      profile_form_errors:    #{inspect(assigns[:profile_form_errors])}
      provider_wizard:        #{inspect(wizard_summary(assigns[:provider_wizard]))}
    """
  end

  defp apply_evidence(assigns) do
    if apply_expected?(assigns) and not snapshot_applied?(assigns),
      do: " — the node-data snapshot has NOT been applied yet",
      else: ""
  end

  defp request_summary(nil), do: nil

  defp request_summary(%{} = request) do
    %{scope: Map.get(request, :scope), success_msg: Map.get(request, :success_msg)}
  end

  defp request_summary(other), do: other

  defp owner_state(nil), do: nil
  defp owner_state(pid) when is_pid(pid), do: %{pid: inspect(pid), alive?: Process.alive?(pid)}
  defp owner_state(other), do: other

  defp wizard_summary(%{} = wizard) do
    draft = Map.get(wizard, :draft) || %{}

    %{
      step: Map.get(wizard, :step),
      profile_id_new: Map.get(draft, "profile_id_new"),
      name: Map.get(draft, "name"),
      model: Map.get(draft, "model"),
      errors: Map.get(wizard, :errors) || Map.get(wizard, :form_errors)
    }
  end

  defp wizard_summary(other), do: other

  # The production helpers read a socket's assigns; the page read above is the
  # same map, so the ONE definition of a scope (ConfigSave.scope/1) and of a
  # pending target (PageState.pending_remote_target?/1) is reused, never copied.
  defp socket(assigns), do: %Phoenix.LiveView.Socket{assigns: assigns}
end
