defmodule EvoDashWeb.HomeLive.ModelSelect do
  @moduledoc """
  Node-aware configuration loading and task-option boundary for Assistant chat.

  Selection projection, provider/model changes, legacy-id migration, reasoning
  defaults and validation belong to the shared `EvoDashWeb.LLMSelection`, not to
  this page helper. The page projects a loaded snapshot's config with
  `LLMSelection.from_config/2` and renders `LLMSelectionComponents` with a
  string-keyed `model_spec`.

  `load/1` returns a tagged snapshot.
  Keep the snapshot ephemeral: its config may contain authentication settings
  and must never enter ChatHistory, browser data attributes or form payloads.
  """

  alias EvoDash.NodeContext
  alias EvoDashWeb.LLMSelection
  alias EvoGit.Config

  @type snapshot :: %{
          node: node(),
          config: map(),
          model_selection_enabled: boolean()
        }

  @doc """
  Loads the viewed node's config and model-selection-script state.

  Remote callers MUST use a supervised `EvoDash.SafeCall.start/4` task and guard
  its nested result message by both model_select_seq and node context.
  The page must also handle an error returned by `SafeCall.start/4` itself;
  supervisor startup failures do not send a result message.
  Errors stay errors: a failed load must not silently turn an explicit pin into Auto.
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

  def load(target_node) when is_atom(target_node) and target_node not in [true, false] do
    with {:ok, config} when is_map(config) <- NodeContext.get_resolved_config(target_node),
         {:ok, enabled} <- remote_model_selection_enabled(target_node) do
      {:ok, %{node: target_node, config: config, model_selection_enabled: enabled}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_config_response}
    end
  end

  def load(_target_node), do: {:error, :invalid_model_selection_node}

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
  The shared resolver reconstructs that map from the resolved top-level
  provider_profile_id/model/reasoning_effort fields, NEVER resolved.model_spec
  (a ReqLLM identifier) or generation_params (which can contain credentials).
  Stale profiles/models/efforts are errors, never fallback Auto.

  A local scope is `{nil, node()}`; a remote scope requires both a nonblank
  target id and a nonlocal node atom. Pending targets, malformed node values
  and unscoped remote snapshots cannot launch even an Auto task.

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
      when is_map(config) and is_atom(target_node) and target_node not in [nil, true, false] and
             ((is_nil(node_id) and target_node == node()) or
                (is_binary(node_id) and node_id != "" and target_node != node())) do
    # Only nil may fall back to a legacy migration id. In particular, false
    # is malformed input, not Auto or an uninitialized/default selection.
    selection =
      case selection_state[:model_spec] do
        nil -> selection_state[:selected_model_id]
        spec -> spec
      end

    LLMSelection.task_opts(config, selection, opts)
  end

  def task_opts(_snapshot, %{model_selection_error: :invalid_model_spec}, _scope, _opts),
    do: {:error, :invalid_model_spec}

  def task_opts(_snapshot, _selection_state, _scope, _opts),
    do: {:error, :model_selection_not_loaded}
end
