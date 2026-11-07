defmodule EvoDashWeb.HomeLive.ModelSelect do
  @moduledoc """
  Node-aware configuration loading and task-option boundary for Assistant chat.

  Selection projection, provider/model changes, legacy-id migration, reasoning
  defaults and validation belong to the shared `EvoDashWeb.LLMSelection`, not to
  this page helper. The page projects a loaded snapshot's config with the core
  `Schema.provider_profiles/1` and `Schema.model_selections/1` APIs (or the shared
  helper) and renders `LLMSelectionComponents` with a string-keyed `model_spec`.

  `load/1` returns a tagged snapshot, not the old `{profiles, enabled}` tuple.
  Keep the snapshot ephemeral: its config may contain authentication settings
  and must never enter ChatHistory, browser data attributes or form payloads.
  """

  alias EvoDash.NodeContext
  alias EvoGit.Config

  @type snapshot :: %{
          node: node(),
          config: map(),
          model_selection_enabled: boolean()
        }

  @doc """
  Loads the viewed node's config and model-selection-script state.

  Remote callers MUST use a supervised `EvoDash.SafeCall.start/4` task and guard
  its nested result message by both model_select_seq and node context. Errors
  stay errors: a failed load must not silently turn an explicit pin into Auto.
  A nil node means local, but a pending remote target MUST be blocked by the
  page before calling this function with its fallback local node.

  The script's configured-but-broken state still counts as enabled, matching
  `ModelSelector.enabled?/0`. No scheduler/catalog defaults are substituted for
  the target node's config.
  """
  @spec load(node() | nil) :: {:ok, snapshot()} | {:error, term()}
  def load(target_node) when target_node in [nil, node()] do
    {:ok,
     %{
       node: node(),
       config: Config.resolve(),
       model_selection_enabled: EvoGit.CustomAgents.ModelSelector.enabled?()
     }}
  end

  def load(target_node) do
    with {:ok, config} <- NodeContext.get_resolved_config(target_node),
         {:ok, enabled} <- remote_model_selection_enabled(target_node) do
      {:ok, %{node: target_node, config: config, model_selection_enabled: enabled}}
    end
  end

  defp remote_model_selection_enabled(target_node) do
    # list_custom_agents/1 masks transport failures as a successful empty list.
    # Query the actual predicate so an unreachable node stays a load error.
    case NodeContext.call_remote(target_node, EvoGit.CustomAgents.ModelSelector, :enabled?, []) do
      {:ok, enabled} when is_boolean(enabled) -> {:ok, enabled}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_model_selection_response, other}}
    end
  end

  @doc """
  Prepares reflect-task options against a snapshot for the SAME target node.

  Shared-helper contract: `LLMSelection.task_opts(config, spec_or_legacy_id,
  opts)` returns `{:ok, keyword}` or `{:error, reason}`. It resolves through
  `Schema.resolve_model_spec/2`, validates against canonical model selections,
  and resolves the advertised default reasoning effort before submission.
  Explicit options contain only a STRING-keyed `:model_spec` and
  `model_id_locked: true`; Auto strips model_spec/model_id/model_id_locked.
  Stale profiles/models/efforts are errors, never fallback Auto.

  A parent page must handle the error BEFORE appending a user bubble, clearing
  the draft or calling start_task. A node switch invalidates the old snapshot
  even when two nodes happen to use the same provider-profile id.
  """
  @spec task_opts(snapshot() | nil, map(), {String.t() | nil, node()}, keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def task_opts(snapshot, selection_state, scope, opts \\ [])

  def task_opts(
        %{node: target_node, config: config},
        %{model_selection_scope: scope, model_selection_error: nil} = selection_state,
        {node_id, target_node} = scope,
        opts
      )
      when is_map(config) and
             (is_nil(node_id) or
                (is_binary(node_id) and node_id != "" and target_node != node())) do
    selection = selection_state[:model_spec] || selection_state[:selected_model_id]

    # The shared module is parent-owned and may not yet be shipped by the
    # integrating branch; fail closed instead of emitting a legacy id.
    if Code.ensure_loaded?(EvoDashWeb.LLMSelection) and
         function_exported?(EvoDashWeb.LLMSelection, :task_opts, 3) do
      apply(EvoDashWeb.LLMSelection, :task_opts, [config, selection, opts])
    else
      {:error, :llm_selection_unavailable}
    end
  end

  def task_opts(_snapshot, %{model_selection_error: :invalid_model_spec}, _scope, _opts),
    do: {:error, :invalid_model_spec}

  def task_opts(_snapshot, _selection_state, _scope, _opts),
    do: {:error, :model_selection_not_loaded}
end
