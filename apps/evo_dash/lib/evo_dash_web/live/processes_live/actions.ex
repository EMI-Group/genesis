defmodule EvoDashWeb.ProcessesLive.Actions do
  @moduledoc """
  Control-action execution and error mapping for the Processes page.

  Every control call goes through `EvoDash.NodeContext.process_control/4` (by
  default), which is LOCAL-FIRST: it applies the action directly on the in-BEAM
  `EvoGit.ProcessManager` when the viewed node IS this BEAM and uses the
  cross-node RPC only for a genuinely remote viewed node.
  The call therefore runs inside `EvoDash.SafeCall.run/1`: a `GenServer.call`
  timeout / dead target EXITS its caller, so the boundary is what turns "the
  manager or the remote daemon is gone" into a flashable value instead of a
  crashed LiveView. Control answers are values — `:ok` or `{:error, reason}` —
  and this module maps them to a `{flash_kind, message}` pair.

  App-env seam, resolved at CALL time: `:processes_control_runner` — a 4-arity
  `(node, id, action, reason)` function, default
  `&EvoDash.NodeContext.process_control/4`.

  Pause/Resume use a DEFAULT reason (they are one-click, reversible actions).
  Terminate and Kill are destructive and require an operator-entered reason;
  the page enforces that in its confirmation modal and passes the EXACT trimmed
  string here, so it is what the core records in the execution's control log.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDash.SafeCall

  @pause_reason "Paused from the Genesis dashboard"
  @resume_reason "Resumed from the Genesis dashboard"

  @doc "Reason recorded for a one-click Pause."
  def pause_reason, do: @pause_reason

  @doc "Reason recorded for a one-click Resume."
  def resume_reason, do: @resume_reason

  @doc "The default reason for a reversible action (`:pause` / `:resume`)."
  def default_reason(:pause), do: @pause_reason
  def default_reason(:resume), do: @resume_reason
  def default_reason(_action), do: nil

  @doc """
  Runs one control action through the exit-safe boundary.

  Returns `:ok` on success, or `{:error, reason}` — either the core's own
  reason (`:not_found`, `:terminal`, `:unsupported`, `:no_handle`, …) or a
  transport/SafeCall failure.
  """
  @spec control(node(), String.t(), atom() | {:signal, String.t()}, term()) ::
          :ok | {:error, term()}
  def control(node, id, action, reason) do
    runner =
      Application.get_env(
        :evo_dash,
        :processes_control_runner,
        &EvoDash.NodeContext.process_control/4
      )

    case SafeCall.run(fn -> runner.(node, id, action, reason) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates an operator-entered reason (`:ok` when non-blank after trimming).
  The page keeps the modal open and performs NO control call on `:blank`.
  """
  @spec validate_reason(term()) :: :ok | :blank
  def validate_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: :blank, else: :ok
  end

  def validate_reason(_reason), do: :blank

  @doc """
  Maps a control outcome to `{flash_kind, message}`. Every answer is surfaced —
  success and failure alike — so a click never appears to do nothing.
  """
  @spec result_message(atom(), :ok | {:error, term()}) :: {:info | :error, String.t()}
  def result_message(action, :ok), do: {:info, success_message(action)}
  def result_message(action, {:error, reason}), do: {:error, error_message(action, reason)}

  @doc "Success flash text for an action."
  def success_message(:pause), do: gettext("Process paused.")
  def success_message(:resume), do: gettext("Process resumed.")
  def success_message(:terminate), do: gettext("Terminate signal sent to the process.")
  def success_message(:kill), do: gettext("Kill signal sent to the process.")
  def success_message(_action), do: gettext("Process action sent.")

  @doc """
  Failure flash text for an action.

  Known core reasons get a precise message (in particular `:unsupported`, which
  means the platform cannot deliver POSIX signals — e.g. Windows — so the
  action is impossible rather than merely failed); anything else includes the
  formatted reason so the operator can act on it.
  """
  def error_message(_action, :unsupported),
    do: gettext("This action is not supported on this platform.")

  def error_message(_action, :terminal), do: gettext("This process has already exited.")
  def error_message(_action, :not_found), do: gettext("This process is no longer tracked.")

  def error_message(_action, :no_handle),
    do: gettext("This process has no OS handle yet — nothing to signal.")

  def error_message(_action, :no_os_process),
    do: gettext("This execution has no OS process to signal.")

  def error_message(_action, :invalid_signal),
    do: gettext("The requested signal is not valid for this process.")

  def error_message(action, reason) do
    gettext("%{action} failed: %{reason}",
      action: action_name(action),
      reason: EvoDashWeb.ProcessesLive.Format.term_text(reason)
    )
  end

  defp action_name(:pause), do: gettext("Pause")
  defp action_name(:resume), do: gettext("Resume")
  defp action_name(:terminate), do: gettext("Terminate")
  defp action_name(:kill), do: gettext("Kill")
  defp action_name(_action), do: gettext("Process action")
end
