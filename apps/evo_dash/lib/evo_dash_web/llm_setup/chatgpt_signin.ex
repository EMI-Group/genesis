defmodule EvoDashWeb.LLMSetup.ChatGPTSignIn do
  @moduledoc """
  The dashboard's ONE Sign in with ChatGPT (SIWC) state/vocabulary boundary.

  It resolves the backend flow module, guards every call into it, drives the
  bounded authorization poll, and maps every documented outcome to a friendly
  localized message. The components and pages only ever talk to this module —
  no markup, no LiveView/Phoenix imports.

  The flow module is resolved AT CALL TIME (`login_module/0`): `Process.get`,
  then the same key on a `:"$callers"` ancestor, then the `:evo_dash,
  :chatgpt_login` app env whose default is the bare ATOM
  `EvoDash.ChatGPTLogin` — never called at compile time, so this module and
  its tests compile before that module exists and a test can inject a stub in
  its own process without touching BEAM-global state.

  Every call degrades to a VALUE: a dead, slow or raising flow module answers
  `{:error, :sign_in_unavailable}` instead of crashing a LiveView.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDash.SafeCall

  @result_tag :chatgpt_signin_result
  @default_login_module EvoDash.ChatGPTLogin
  @default_poll_interval_ms 750
  @default_poll_timeout_ms 660_000
  @call_timeout_ms 15_000
  @supervisor EvoDash.TaskSupervisor

  @typedoc "How a sign-in is presented: `:ok`, `:error` or still `:pending`."
  @type phase :: :ok | :error | :pending

  @typedoc "A friendly, already-localized message."
  @type message :: %{kind: :error | :info | :success, text: String.t()}

  # ── Flow-module resolution ─────────────────────────────────────────────────

  @doc """
  The SIWC flow module for this call — `Process.get(:chatgpt_login_module)`,
  then the same key on a `:"$callers"` ancestor, then the
  `:evo_dash, :chatgpt_login` app env (default `EvoDash.ChatGPTLogin`).
  """
  @spec login_module() :: atom()
  def login_module,
    do: seam(:chatgpt_login_module, :chatgpt_login, @default_login_module)

  @doc "The bounded timeout for ONE flow-module call (milliseconds)."
  @spec call_timeout_ms() :: pos_integer()
  def call_timeout_ms, do: @call_timeout_ms

  @doc "The poll interval used by `start_poll/2` (milliseconds)."
  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms,
    do:
      seam(
        :chatgpt_signin_poll_interval_ms,
        :chatgpt_signin_poll_interval_ms,
        @default_poll_interval_ms
      )

  @doc "The hard cap on ONE authorization poll (milliseconds)."
  @spec poll_timeout_ms() :: pos_integer()
  def poll_timeout_ms,
    do:
      seam(
        :chatgpt_signin_poll_timeout_ms,
        :chatgpt_signin_poll_timeout_ms,
        @default_poll_timeout_ms
      )

  @doc "The message tag a finished poll sends to its owner."
  @spec result_tag() :: atom()
  def result_tag, do: @result_tag

  # ── Flow calls ─────────────────────────────────────────────────────────────

  @doc """
  Starts ONE sign-in for `account` (`nil` = the default registration) and
  answers `{:ok, %{id: flow_id, url: sign_in_url}}` or `{:error, reason}`.
  """
  @spec begin(term()) :: {:ok, %{id: String.t(), url: String.t()}} | {:error, term()}
  def begin(account) do
    case call(login_module(), :begin, [account, []]) do
      {:ok, {:ok, %{id: id, url: url}}} -> started(id, url)
      {:ok, {:ok, %{"id" => id, "url" => url}}} -> started(id, url)
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _unexpected} -> {:error, :sign_in_unavailable}
      {:error, _failure} -> {:error, :sign_in_unavailable}
    end
  end

  @doc "Cancels a running sign-in flow."
  @spec cancel(term()) :: :ok | {:error, term()}
  def cancel(flow_id) do
    case call(login_module(), :cancel, [flow_id]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _unexpected} -> {:error, :sign_in_unavailable}
      {:error, _failure} -> {:error, :sign_in_unavailable}
    end
  end

  @doc """
  The flow's current status: `:pending` while the user is in the browser, a
  terminal `{:ok, map()}` or `{:error, reason}`.
  """
  @spec status(term()) :: :pending | {:ok, map()} | {:error, term()}
  def status(flow_id), do: status_with(login_module(), flow_id)

  # `module` is resolved by the CALLER (the page, or `start_poll/2`), never
  # re-resolved inside a spawned task.
  defp status_with(module, flow_id) do
    case call(module, :status, [flow_id]) do
      {:ok, :pending} -> :pending
      {:ok, {:ok, %{} = info}} -> {:ok, info}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _unexpected} -> {:error, :sign_in_unavailable}
      {:error, _failure} -> {:error, :sign_in_unavailable}
    end
  end

  # ── Polling ────────────────────────────────────────────────────────────────

  @doc """
  Polls `flow_id` and sends EXACTLY ONE
  `{:chatgpt_signin_result, flow_id, result}` to `owner`, then exits.

  `result` is `{:ok, map()}` or `{:error, reason}`
  (`{:error, :authorization_timeout}` at the hard cap). The flow module, the
  interval and the cap are resolved HERE, in the caller, and handed to the
  task. The owner is monitored, so a page that goes away stops the poll.
  Always answers `:ok`; when the poll cannot be started the error result is
  delivered immediately so a waiting page never hangs.
  """
  @spec start_poll(term(), pid()) :: :ok
  def start_poll(flow_id, owner_pid) when is_pid(owner_pid) do
    module = login_module()
    interval = poll_interval_ms()
    timeout = poll_timeout_ms()

    case start_child(fn -> poll(flow_id, owner_pid, module, interval, timeout) end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> deliver(owner_pid, flow_id, {:error, :sign_in_unavailable})
    end
  end

  def start_poll(_flow_id, _owner_pid), do: :ok

  defp start_child(fun) do
    # Deliberate catch-`exit`: `Task.Supervisor.start_child/2` is a
    # `GenServer.call`, which EXITS the caller when the supervisor name is
    # unknown or dead. That must surface as a value, never as a page crash.
    try do
      Task.Supervisor.start_child(@supervisor, fun)
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp poll(flow_id, owner, module, interval, timeout) do
    mon = Process.monitor(owner)

    poll_step(
      flow_id,
      owner,
      module,
      interval,
      System.monotonic_time(:millisecond) + timeout,
      mon
    )
  end

  defp poll_step(flow_id, owner, module, interval, deadline, mon) do
    receive do
      {:DOWN, ^mon, :process, ^owner, _reason} ->
        :ok
    after
      interval ->
        case status_with(module, flow_id) do
          :pending ->
            if System.monotonic_time(:millisecond) >= deadline do
              deliver(owner, flow_id, {:error, :authorization_timeout})
            else
              poll_step(flow_id, owner, module, interval, deadline, mon)
            end

          other ->
            deliver(owner, flow_id, other)
        end
    end
  end

  # Exactly once, and only while the owner is still alive.
  defp deliver(owner, flow_id, result) do
    if Process.alive?(owner), do: send(owner, {@result_tag, flow_id, result})
    :ok
  end

  # ── Presentation vocabulary ────────────────────────────────────────────────

  @doc """
  The friendly message for a sign-in outcome — TOTAL.

  Every documented outcome maps to localized text; anything else (an unknown
  atom, `nil`, a tuple) falls back to a generic sentence, so a raw atom is
  never rendered.
  """
  @spec message(term()) :: message()
  def message(reason)

  def message({:ok, _info}), do: message(:ok)
  def message({:error, reason}), do: message(reason)

  def message(%{kind: kind, text: text}) when kind in [:error, :info, :success],
    do: %{kind: kind, text: text}

  def message(:ok), do: %{kind: :success, text: gettext("ChatGPT connected")}

  def message(:authorization_denied),
    do: %{kind: :error, text: gettext("Sign-in was cancelled in the browser.")}

  def message(:plan_not_authorized),
    do: %{
      kind: :error,
      text: gettext("Genesis was not granted permission to use this ChatGPT plan.")
    }

  def message(:reauthorization_required),
    do: %{kind: :error, text: gettext("This ChatGPT account must be signed in again.")}

  def message(:authorization_timeout),
    do: %{kind: :error, text: gettext("The sign-in request timed out. Start again.")}

  def message(:cancelled), do: %{kind: :info, text: gettext("Sign-in cancelled.")}

  def message(:superseded),
    do: %{kind: :info, text: gettext("A newer sign-in request replaced this one.")}

  def message(:loopback_listener_unavailable), do: unavailable_message()
  def message(:sign_in_unavailable), do: unavailable_message()
  def message(:unreachable), do: unavailable_message()

  def message(reason)
      when reason in [:chatgpt_account_alias_in_use, :chatgpt_registration_already_installed],
      do: %{
        kind: :error,
        text:
          gettext("This ChatGPT registration is already connected under another account name.")
      }

  def message(_other),
    do: %{kind: :error, text: gettext("Sign-in could not be completed. Start again.")}

  defp unavailable_message do
    %{
      kind: :error,
      text:
        gettext(
          "Genesis could not start a local sign-in. Run `genesis chatgpt login` on the execution node instead."
        )
    }
  end

  @doc "A total phase for any sign-in value."
  @spec phase(term()) :: phase()
  def phase(:ok), do: :ok
  def phase({:ok, _info}), do: :ok
  def phase(:pending), do: :pending
  def phase(nil), do: :pending
  def phase(_other), do: :error

  # ── Internals ──────────────────────────────────────────────────────────────

  defp started(id, url) when is_binary(id) and id != "" and is_binary(url) and url != "",
    do: {:ok, %{id: id, url: url}}

  defp started(_id, _url), do: {:error, :sign_in_unavailable}

  # ONE guarded + bounded call into the flow module. `{:ok, raw_return}` carries
  # the module's own answer; `{:error, _}` means the call failed as a whole.
  defp call(module, fun, args) when is_atom(module) and is_atom(fun) do
    case SafeCall.run(fn -> bounded_apply(module, fun, args) end) do
      {:ok, result} -> result
      {:error, _failure} -> {:error, :sign_in_unavailable}
    end
  end

  defp call(_module, _fun, _args), do: {:error, :sign_in_unavailable}

  defp bounded_apply(module, fun, args) do
    task =
      Task.async(fn ->
        case SafeCall.run(fn -> apply(module, fun, args) end) do
          {:ok, value} -> {:module_result, value}
          # The module failed as a whole (raise/throw/exit) — a DIFFERENT thing
          # from the module's own `{:error, reason}` answer.
          {:error, _failure} -> :module_failure
        end
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:module_result, value}} -> {:ok, value}
      {:ok, :module_failure} -> {:error, :sign_in_unavailable}
      {:exit, _reason} -> {:error, :sign_in_unavailable}
      nil -> {:error, :sign_in_unavailable}
    end
  end

  # A call-time seam: this process, then its `$callers` ancestors, then app env.
  defp seam(key, app_env_key, default) do
    case Process.get(key) do
      nil -> caller_seam(key, Process.get(:"$callers")) || app_seam(app_env_key, default)
      value -> value
    end
  end

  defp caller_seam(_key, callers) when not is_list(callers), do: nil

  defp caller_seam(key, callers) do
    Enum.find_value(callers, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, key)
        _ -> nil
      end
    end)
  end

  defp app_seam(app_env_key, default) do
    case Application.get_env(:evo_dash, app_env_key, default) do
      value when is_integer(value) and value > 0 -> value
      value when is_atom(value) and not is_nil(value) -> value
      _ -> default
    end
  end
end
