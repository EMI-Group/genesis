defmodule EvoGit.Agent.Session.Outcome do
  @moduledoc """
  The PURE outcome classification of `EvoGit.Agent.Session` — what an exchange outcome means for
  the session, given the phase it arrived in and the mode the agent runs in.

  `EvoGit.Agent.Exchange.run/2` returns `{:yield, state, text}`, `{:finish, state, result}` or
  `{:error, reason}`, and the SAME outcome can mean different things:

  | phase | mode | outcome | verdict |
  |---|---|---|---|
  | `:running` | `:interactive` | `{:yield, state, text}` | `{:idle, state, text}` — non-terminal, `:awaiting_input` |
  | `:cancelling` | any | `{:yield, state, text}` | `{:finalize_yield, state, text}` — the cancel-grace report IS the terminal result |
  | `:running` / `:cancelling` | any | `{:finish, state, result}` | `{:finish, state, result}` — terminal success |
  | `:running` / `:cancelling` | any | `{:error, reason}` | `{:error, reason}` — terminal failure, delivered VERBATIM |
  | anything else | any | anything | `{:unexpected, outcome}` — LOUD, never a silent drop |

  "Anything else" covers the two contract violations worth naming: a `:yield` from a ONE-SHOT
  agent (a role that must never yield) and any outcome arriving in a phase that has no exchange
  running at all (`:awaiting_input`, `:starting`, `:finalizing`, `:done`).

  A yield whose text is not a binary is treated as unexpected too: a report that cannot be
  delivered as text would silently become an empty final report.

  Nothing here mutates process state or sends a message — the session owns every transition and
  every scheduler notification.
  """

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State

  @type verdict ::
          {:idle, State.t(), String.t()}
          | {:finalize_yield, State.t(), String.t()}
          | {:finish, State.t(), Result.t()}
          | {:error, term()}
          | {:unexpected, term()}

  @doc """
  Classifies `outcome` for a session in `phase` whose agent runs in `mode`.
  """
  @spec classify(atom(), atom() | nil, term()) :: verdict()
  # A yield while CANCELLING is the engine's cancel-grace report: the session is on its way out,
  # so this yield is its LAST output and must be finalized (never parked as `:awaiting_input`).
  def classify(:cancelling, _mode, {:yield, %State{} = state, text}) when is_binary(text) do
    {:finalize_yield, state, text}
  end

  # The ONLY legal idle transition: an interactive agent yields while it is running.
  def classify(:running, :interactive, {:yield, %State{} = state, text}) when is_binary(text) do
    {:idle, state, text}
  end

  def classify(phase, _mode, {:finish, %State{} = state, %Result{} = result})
      when phase in [:running, :cancelling] do
    {:finish, state, result}
  end

  def classify(phase, _mode, {:error, reason}) when phase in [:running, :cancelling] do
    {:error, reason}
  end

  def classify(_phase, _mode, outcome), do: {:unexpected, outcome}
end
