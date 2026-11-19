defmodule EvoDashWeb.SettingsLive.LlmTestEvents do
  @moduledoc """
  The `/settings` LLM connection-test flow.

  Owns the test identity (`test_profile_id`), its generation stamp
  (`llm_test_seq`) and the visible status (`llm_test_status`) — the assigns the
  async result handler `AsyncResults.llm_test_result/4` stale-guards. The test
  itself always runs in a supervised task (`EvoDash.SafeCall.start/3`) against
  the VIEWED node's persisted configuration: resolution (`OAuth` import, named
  API-key environment variables, inherited generation/reasoning defaults)
  happens on that node, and the resolved object never enters DOM state.

  Events routed here by `EvoDashWeb.SettingsLive`:
    * `test_llm` — `handle_event/3` (refuses a pending remote target, an
      unloaded config scope and an in-flight save before spawning the test);
    * `select_test_profile` — `handle_event/3`.

  Also the ONE owner of `invalidate_llm_test/1` (a newer generation makes every
  in-flight result stale) and of `assign_test_config/2` — the authoritative
  `file_config` boundary, which re-scopes the test config, reconciles the
  selected profile and invalidates earlier results.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoGit.Config.Schema
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.PageState

  @events ["test_llm", "select_test_profile"]

  @doc """
  The event names this module owns.
  """
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  Routes the two LLM connection-test events to their handler.

  Called from `SettingsLive.handle_event/3` (one-line delegation).
  """
  def handle_event(event, params, socket) when event in @events do
    case event do
      "test_llm" -> test_llm(socket, params)
      "select_test_profile" -> select_test_profile(socket, params)
    end
  end

  defp select_test_profile(socket, %{"profile_id" => profile_id}) do
    {:noreply,
     socket
     |> assign(:test_profile_id, profile_id)
     |> reconcile_test_profile()
     |> invalidate_llm_test()}
  end

  defp test_llm(socket, params) do
    cond do
      PageState.pending_remote_target?(socket) ->
        # NodeAware falls back to the local BEAM until a requested remote target
        # connects. Reject BEFORE resolving anything that could import OAuth or
        # read local credentials; a local test would be dangerously misleading.
        {:noreply,
         socket
         |> invalidate_llm_test()
         |> put_flash(
           :error,
           gettext("Connect to the remote node before testing its configuration.")
         )}

      socket.assigns[:test_config_scope] != PageState.test_config_scope(socket) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Wait for this node's configuration to load before testing.")
         )}

      socket.assigns[:config_saving] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Wait for the configuration save to finish before testing.")
         )}

      true ->
        start_llm_test(params, socket)
    end
  end

  defp start_llm_test(params, socket) do
    socket = reconcile_test_profile(socket)
    profile_id = params["profile_id"] || socket.assigns.test_profile_id

    selection =
      Enum.find(ConfigIO.model_selections(socket.assigns.file_config), fn selection ->
        EvoDashWeb.SettingsComponents.model_selection_value(selection) == profile_id
      end)

    if selection do
      socket = socket |> assign(:test_profile_id, profile_id) |> invalidate_llm_test()
      seq = socket.assigns.llm_test_seq
      scope = llm_test_scope(socket)
      config = socket.assigns.file_config
      target_node = socket.assigns.current_node || node()
      spec = Map.take(selection, [:provider_profile_id, :model])

      # Capture the destination and persisted selection now, not from a later
      # socket. Resolved credentials/options stay inside this server-side task.
      case EvoDash.SafeCall.start(self(), {:llm_test_result, seq, scope}, fn ->
             run_llm_test(target_node, config, spec)
           end) do
        {:ok, _pid} ->
          {:noreply, assign(socket, :llm_test_status, :testing)}

        {:error, reason} ->
          {:noreply, assign(socket, :llm_test_status, {:error, reason})}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Selected profile has no model configured."))}
    end
  end

  defp run_llm_test(target_node, config, spec) do
    # Resolve on the VIEWED node: OAuth import, named API-key environment vars,
    # inherited reasoning/generation defaults and provider options belong there.
    resolved =
      if target_node == node() do
        ConfigIO.resolve_model_spec(config, spec)
      else
        case EvoDash.NodeContext.call_remote(target_node, Schema, :resolve_model_spec, [
               config,
               spec
             ]) do
          {:ok, result} -> result
          {:error, _} = error -> error
        end
      end

    with {:ok, resolved} <- resolved do
      # model_spec is the ReqLLM-ready identifier, NOT the canonical picker map.
      # Pass the full core-composed auth/generation options without rebuilding a
      # partial option list or ever putting the resolved object into DOM state.
      if target_node == node() do
        EvoGit.SystemCheck.llm_test(resolved.model_spec, resolved.generation_params)
      else
        EvoGit.RemoteNode.llm_test(target_node, resolved.model_spec, resolved.generation_params)
      end
    end
  end

  @doc """
  Installs an authoritative `file_config` snapshot for the task/test boundary.

  Captures that the test config belongs to the current scope, reconciles the
  selected test profile against the new inventory and invalidates any earlier
  test result: even an unchanged account/model can now have different
  credentials or generation defaults, so a pre-reload result must not describe
  the new config.
  """
  def assign_test_config(socket, file_config) do
    socket
    |> assign(:file_config, file_config)
    |> assign(:test_config_scope, PageState.test_config_scope(socket))
    |> reconcile_test_profile()
    |> invalidate_llm_test()
  end

  @doc """
  Keeps the selected test profile pointing at a configured account/model, or
  falls back to the first configured one.
  """
  def reconcile_test_profile(socket) do
    values =
      socket.assigns.file_config
      |> ConfigIO.model_selections()
      |> Enum.map(&EvoDashWeb.SettingsComponents.model_selection_value/1)

    selected = socket.assigns[:test_profile_id]
    selected = if selected in values, do: selected, else: List.first(values)
    assign(socket, :test_profile_id, selected)
  end

  @doc """
  Invalidates every in-flight test: the generation advances and the visible
  status returns to `:idle`.
  """
  def invalidate_llm_test(socket) do
    assign(socket, llm_test_seq: (socket.assigns[:llm_test_seq] || 0) + 1, llm_test_status: :idle)
  end

  @doc """
  The identity a test result must match to settle the visible status: the
  viewed target, its BEAM node and the tested profile.
  """
  def llm_test_scope(socket) do
    {target_id, target_node} = PageState.test_config_scope(socket)
    {target_id, target_node, socket.assigns[:test_profile_id]}
  end

  @doc """
  Normalizes the exit-safe `EvoDash.SafeCall.run/1` envelope around an LLM
  connection test into the `{:ok, data} | {:error, reason}` shape the
  `llm_test_result` handler renders: the test functions themselves already
  return that shape, so a successful guarded call nests it one level deeper.
  """
  def normalize_llm_test_result({:ok, {:ok, data}}), do: {:ok, data}
  def normalize_llm_test_result({:ok, {:error, reason}}), do: {:error, reason}
  def normalize_llm_test_result({:ok, other}), do: {:error, {:unexpected_result, other}}
  def normalize_llm_test_result({:error, reason}), do: {:error, reason}
end
