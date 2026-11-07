defmodule EvoDashWeb.ProjectsLive.LaunchOptions do
  @moduledoc """
  Pure, shared task-selection options for normal submissions and GitHub fixes.

  The caller owns mode, objective, repository and attachment options; this
  module adds the validated model selection, custom agent and quality policy.
  Invalid/stale explicit selections are errors, never an implicit Auto launch.
  """

  alias EvoDashWeb.LLMSelection
  alias EvoDashWeb.ProjectsLive.ModelSelectionScope

  @doc """
  Adds the current picker options to an existing launch payload.

  `assigns.model_selection` is the bundle returned by `LLMSelection.from_config/2`;
  `selected_model_spec` is a string-keyed map (empty for Auto). Only the shared
  helper resolves defaults and validates membership/reasoning. Legacy model
  options are removed, including for Auto, so a resumed payload cannot leak a
  previous lock or profile id into a new task.
  Ownership must match `{current_node_id, current_node || node()}` and the
  picker must be ready, without a load error or pending browser restore.
  Unstamped local mount bundles remain compatible; remote ones never do.
  """
  def apply(opts, assigns) when is_list(opts) and is_map(assigns) do
    with {:ok, model_opts} <- model_opts(assigns) do
      opts =
        opts
        |> Keyword.drop([:model_id, :model_spec, :model_id_locked])
        |> Keyword.merge(model_opts)
        |> put_agent(assigns[:selected_agent_id])
        |> put_quality(assigns[:quality_level])

      {:ok, opts}
    end
  end

  defp model_opts(assigns) do
    with {:ok, data} <- ModelSelectionScope.bundle(assigns) do
      if is_nil(assigns[:pending_model_selection]) do
        LLMSelection.task_opts(data, Map.get(assigns, :selected_model_spec))
      else
        {:error, :model_selection_restore_pending}
      end
    end
  end

  defp put_agent(opts, agent) when is_binary(agent) and agent != "",
    do: Keyword.put(opts, :agent, agent)

  defp put_agent(opts, _agent), do: Keyword.delete(opts, :agent)

  defp put_quality(opts, quality) when quality in ["fast", "high_quality"],
    do: Keyword.put(opts, :quality_level, quality)

  defp put_quality(opts, _quality), do: Keyword.delete(opts, :quality_level)
end
