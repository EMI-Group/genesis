defmodule EvoGit.Agent.Session.Finalize do
  @moduledoc """
  The ONE completion-once mechanism of an interactive agent session.

  `EvoGit.Agent.Completion.Builder.finalize/2` commits pending worktree work, reads the
  post-commit HEAD and writes the completion side effects (git note, archive refs and the
  streaming archive row).  It is expensive — git, the store — and it RAISES when the worktree
  vanished mid-run, so it must never run inside the session process itself: a hanging or
  crashing finalizer would make the session unanswerable (`inspect/2`, `history/2`, `cancel/2`).

  `start/4` therefore runs it in a short-lived MONITORED process whose `:evogit_agent_pid` is the
  SESSION pid (the durable owner), and reports back as
  `{:session_finalized, finalizer_pid, result}` where `result` is
  `{:ok, %EvoGit.Agent.Result{}} | {:error, term()}`.  Any raise/exit inside the builder becomes
  `{:error, {:finalize_crashed, reason}}`, never a session crash.

  Completion happens EXACTLY ONCE per session, at the terminal outcome of the whole session — a
  yield never finalizes, and the session starts one finalizer and nothing else.
  """

  alias EvoGit.Agent.Completion.Builder
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State

  @type handle :: {pid(), reference()}

  @doc """
  Starts the finalizer for `state`, delivering `text` as the final report.

  Returns the monitored `{pid, reference}` handle the session keeps (and can `stop/1`).
  """
  @spec start(pid(), State.t(), String.t() | nil, String.t() | nil) :: handle()
  def start(session_pid, %State{} = state, tmpdir, text) when is_pid(session_pid) do
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        # The OWNER must stay the session pid: the completion bookkeeping (archive refs, notes,
        # worktree ownership) is keyed on the durable agent process, never on this short-lived one.
        Setup.install_process_context(state, tmpdir, session_pid)
        send(owner, {:session_finalized, self(), run(state, text)})
      end)

    {pid, ref}
  end

  @doc "True when `pid`/`ref` are this data's current finalizer."
  @spec current?(handle() | nil, pid(), reference()) :: boolean()
  def current?({pid, ref}, pid, ref), do: true
  def current?(_handle, _pid, _ref), do: false

  @doc "True when `pid` is the process of this data's current finalizer."
  @spec current?(handle() | nil, pid()) :: boolean()
  def current?({pid, _ref}, pid), do: true
  def current?(_handle, _pid), do: false

  @doc """
  Kills a finalizer that is no longer wanted (a force kill while finalizing) and flushes its
  monitor message, so the session never sees a stale `:DOWN` for it.
  """
  @spec stop(handle() | nil) :: :ok
  def stop({pid, ref}) do
    Process.demonitor(ref, [:flush])
    # The finalizer owns nothing durable beyond what the session owns (worktree/archive), so a
    # kill is safe: it is only mid-git/mid-store when it is being abandoned.
    Process.exit(pid, :kill)
    :ok
  end

  def stop(nil), do: :ok

  # The builder RAISES on a vanished worktree (`"Worktree vanished while agent was running"`): the
  # session converts that into a terminal error result instead of crashing, which is the whole
  # reason this wrapper exists.
  defp run(state, text) do
    Builder.finalize(state, to_text(text))
  rescue
    exception -> {:error, {:finalize_crashed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:finalize_crashed, {kind, reason}}}
  end

  defp to_text(text) when is_binary(text), do: text
  # A session can be closed before any yield produced text: the built-in default is "" so the
  # completion never sees a nil report.
  defp to_text(_text), do: ""
end
