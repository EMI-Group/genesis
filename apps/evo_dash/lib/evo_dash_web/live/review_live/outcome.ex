defmodule EvoDashWeb.ReviewLive.Outcome do
  @moduledoc """
  The terminal-outcome matrix of the `/review` page.

  A finished task now opens `/review/<id>` directly from the project history
  panel, so the page must be an honest destination for EVERY terminal outcome —
  not only for a successful, mergeable one. This module owns the ONE pure,
  total decision surface that tells the page (and its components) how much of
  the review machinery a given outcome may use:

  | outcome      | merge / reject | "Mark as read" dismissal | diff-stat row |
  |--------------|----------------|--------------------------|---------------|
  | `:completed` | allowed        | allowed (no changes only) | shown         |
  | `:cancelled` | allowed (the gracefully cancelled task preserves its result) | never | hidden when there is no diff data |
  | `:failed`    | NEVER (a force-killed task is a diagnostics record) | never | hidden when there is no diff data |
  | `:other`     | allowed        | never | shown |

  No I/O, no gettext and no raises: every function accepts any term and answers
  a boolean (or one of the four outcome atoms).
  """

  @type outcome :: :completed | :failed | :cancelled | :other

  @doc """
  Classifies a task status into the review page's outcome vocabulary. Only the
  three terminal outcomes have a dedicated class; anything else (including
  `nil`, a string status or an unknown atom) is `:other`.
  """
  @spec classify(term()) :: outcome()
  def classify(:completed), do: :completed
  def classify(:failed), do: :failed
  def classify(:cancelled), do: :cancelled
  def classify(_status), do: :other

  @doc """
  Whether the per-repo / page action surface (merge, reject, Create PR,
  Extract Skills, View PR) may be offered. A `:failed` task is a diagnostics
  record — its work cannot be merged or rejected. Every other outcome keeps
  today's behaviour (a gracefully cancelled task preserves its result and
  stays mergeable).
  """
  @spec actions_allowed?(outcome()) :: boolean()
  def actions_allowed?(:failed), do: false
  def actions_allowed?(_outcome), do: true

  @doc """
  Whether the task-level "Mark as read" dismissal may be promoted to the
  primary action: ONLY a COMPLETED task with no changes anywhere. A failed or
  cancelled task is never dismissed as "no changes".
  """
  @spec dismissable?(outcome(), boolean()) :: boolean()
  def dismissable?(:completed, true), do: true
  def dismissable?(_outcome, _is_no_changes), do: false

  @doc """
  Whether the diff-stat row ("N commits / N files changed") may be shown.
  Suppressed only for a failed/cancelled task that produced NO diff data
  (`files_count` and `commits_count` both 0/absent) — a "0 commits / 0 files
  changed" row would misrepresent such a run as an empty-but-successful change.
  """
  @spec show_stats?(term(), outcome() | nil) :: boolean()
  def show_stats?(stats, outcome) when outcome in [:failed, :cancelled] do
    not (count(stats, :files_count) == 0 and count(stats, :commits_count) == 0)
  end

  def show_stats?(_stats, _outcome), do: true

  # Total read of a numeric stat: atom key first, then the string-keyed
  # variant, then 0. Any non-numeric value reads as 0 (never raises).
  defp count(stats, key) when is_map(stats) do
    case Map.get(stats, key, Map.get(stats, Atom.to_string(key))) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _other -> 0
    end
  end

  defp count(_stats, _key), do: 0
end
