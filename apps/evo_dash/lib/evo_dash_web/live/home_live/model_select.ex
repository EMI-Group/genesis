defmodule EvoDashWeb.HomeLive.ModelSelect do
  @moduledoc """
  Model-profile loading for the Home chat page's model selector.

  The selector lets the user pin which LLM model profile the repo-less
  `:reflect` task uses for the conversation — threaded as `:model_id` +
  `:model_id_locked` into `EvoDash.NodeContext.start_task/3` (the same
  contract as the Projects page task form). Node-aware: the profile list comes
  from the config of the node that will actually run the task.
  """

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoDash.NodeContext

  @doc """
  Loads `{model_profiles, model_selection_enabled}` for the viewed node.

  Mirrors the ProjectsLive task-form loading
  (`EvoDashWeb.ProjectsLive.Project.load_model_profiles/1` +
  `EvoDashWeb.ProjectsLive.AsyncLoad.load_custom_agents/1`): the LOCAL node
  resolves its own config + `EvoGit.CustomAgents.ModelSelector.enabled?/0`; a
  REMOTE node resolves via `EvoDash.NodeContext.get_resolved_config/1` and
  derives the script state from the remote node's own `agents.toml`
  (`list_custom_agents/1` — configured-but-broken scripts still count as
  enabled, matching `ModelSelector.enabled?/0` semantics). On RPC failure
  degrades to `{[], false}` — never crashes the page.
  """
  @spec load(node()) :: {[map()], boolean()}
  def load(node) do
    if node == node() do
      {Schema.model_profiles(Config.resolve()), EvoGit.CustomAgents.ModelSelector.enabled?()}
    else
      case NodeContext.get_resolved_config(node) do
        {:ok, config} ->
          {Schema.model_profiles(config), remote_model_selection_enabled?(node)}

        {:error, _reason} ->
          {[], false}
      end
    end
  end

  defp remote_model_selection_enabled?(node) do
    case NodeContext.list_custom_agents(node) do
      {:ok, %{model_selection_script: script}} -> is_binary(script) and script != ""
      _ -> false
    end
  end

  @doc """
  Threads the chat's pinned model into the reflect-task opts (mirrors
  `projects_live.ex` `task_submit`): a non-empty `selected_model_id` prepends
  `:model_id => <id>` + `:model_id_locked => true` (the runtime's
  model-selection script is deferred for this task — the lock is a no-op when
  no script is configured); `nil`/`""` (Auto) returns `opts` unchanged so the
  script (or the default model) decides.
  """
  @spec task_opts(String.t() | nil, keyword()) :: keyword()
  def task_opts(selected_model_id, opts)
      when is_binary(selected_model_id) and selected_model_id != "" do
    [{:model_id, selected_model_id}, {:model_id_locked, true} | opts]
  end

  def task_opts(_selected_model_id, opts), do: opts
end
