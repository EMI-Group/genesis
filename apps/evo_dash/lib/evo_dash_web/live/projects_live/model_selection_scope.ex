defmodule EvoDashWeb.ProjectsLive.ModelSelectionScope do
  @moduledoc """
  Server-only ownership and readiness of the Projects picker bundle.

  A bundle belongs to `{target_id, beam_node}`, not just the BEAM node. The
  async loader stamps ownership only after validating its request envelope.
  Unstamped bundles are compatible with the local mount seed only; they can
  never authorize a remote launch, restore or partial persistence.
  """

  import Phoenix.Component, only: [assign: 2]

  def current(assigns), do: {assigns[:current_node_id], assigns[:current_node] || node()}

  def pending_remote?(assigns) do
    {target_id, target_node} = current(assigns)
    not is_nil(target_id) and target_node == node()
  end

  @doc "Returns the usable, owned bundle, without consuming a pending restore."
  def bundle(assigns) do
    data = assigns[:model_selection]
    scope = assigns[:model_selection_scope]

    cond do
      pending_remote?(assigns) ->
        {:error, :model_selection_pending_remote}

      not is_nil(assigns[:model_selection_error]) ->
        {:error, {:model_selection_load_failed, assigns.model_selection_error}}

      assigns[:model_selection_ready?] == false ->
        {:error, :model_selection_not_loaded}

      not bundle?(data) ->
        {:error, :model_selection_not_loaded}

      scope == current(assigns) or (is_nil(scope) and current(assigns) == {nil, node()}) ->
        {:ok, data}

      true ->
        {:error, :model_selection_scope_mismatch}
    end
  end

  def bundle?(%{config: config, provider_profiles: providers, model_selections: models})
      when is_map(config) and is_list(providers) and is_list(models),
      do: true

  def bundle?(_), do: false

  @doc "Invalidates launch readiness while preserving selected and pending choices."
  def invalidate(socket, reason) do
    assign(socket,
      model_selection: nil,
      model_selection_scope: nil,
      model_selection_ready?: false,
      model_selection_error: reason,
      provider_profiles: [],
      model_selections: []
    )
  end
end
