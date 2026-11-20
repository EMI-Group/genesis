defmodule EvoDashWeb.ReviewLive.Events do
  @moduledoc """
  The event router of `EvoDashWeb.ReviewLive`.

  The LiveView keeps exactly ONE `handle_event/3` clause and hands every event
  to `dispatch/3`, so the page module stays a thin shell. `@handlers` is the ONE
  table mapping a client event string to the module + function that owns it;
  every handler takes `(socket, params)` and returns `{:noreply, socket}`.

  An unknown event is a no-op returning `{:noreply, socket}` — never a crash and
  never an atom conversion of client input.

  `"retry_load"` deliberately targets the PAGE module: it is the one event that
  re-runs the page's async review-data load, whose spawner (`start_async_load/2`)
  lives there and is not duplicated.
  """
  alias EvoDashWeb.ReviewLive
  alias EvoDashWeb.ReviewLive.FileActions
  alias EvoDashWeb.ReviewLive.RepoActions
  alias EvoDashWeb.ReviewLive.Tabs
  alias EvoDashWeb.ReviewLive.TaskActions

  # Client event name → the module/function owning it.
  @handlers %{
    "switch_tab" => {Tabs, :switch_tab},
    "retry_archive" => {Tabs, :retry_archive},
    "load_more_archive" => {Tabs, :load_more_archive},
    "load_archive_agent_result" => {Tabs, :load_archive_agent_result},
    "toggle_summary_view" => {Tabs, :toggle_summary_view},
    "toggle_objective_view" => {Tabs, :toggle_objective_view},
    "copied" => {Tabs, :copied},
    "retry_remote_connection" => {Tabs, :retry_remote_connection},
    "switch_to_local" => {Tabs, :switch_to_local},
    "retry_load" => {ReviewLive, :retry_load},
    "toggle_dir" => {FileActions, :toggle_dir},
    "collapse_all_dirs" => {FileActions, :collapse_all_dirs},
    "expand_all_dirs" => {FileActions, :expand_all_dirs},
    "filter_files" => {FileActions, :filter_files},
    "select_file" => {FileActions, :select_file},
    "toggle_file_expansion" => {FileActions, :toggle_file_expansion},
    "load_file_diff" => {FileActions, :load_file_diff},
    "expand_context" => {FileActions, :expand_context},
    "switch_repo" => {RepoActions, :switch_repo},
    "merge" => {RepoActions, :merge},
    "merge_all" => {RepoActions, :merge_all},
    "merge_target_change" => {RepoActions, :merge_target_change},
    "auto_resolve" => {RepoActions, :auto_resolve},
    "reject" => {RepoActions, :reject},
    "open_repo_diff" => {RepoActions, :open_repo_diff},
    "resume" => {TaskActions, :resume},
    "ignore" => {TaskActions, :ignore},
    "create_pr" => {TaskActions, :create_pr},
    "extract_skills" => {TaskActions, :extract_skills},
    "cancel_extract_skills" => {TaskActions, :cancel_extract_skills},
    "confirm_extract_skills" => {TaskActions, :confirm_extract_skills}
  }

  def dispatch(event, params, socket) do
    case Map.fetch(@handlers, event) do
      {:ok, {module, function}} -> apply(module, function, [socket, params])
      :error -> {:noreply, socket}
    end
  end
end
