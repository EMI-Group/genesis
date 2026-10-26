defmodule EvoDashWeb.SettingsLive.CustomAgentEvents do
  @moduledoc """
  Event handlers for the `:agents` settings category — custom-agent CRUD and
  the model-selection script editor.

  Extracted from SettingsLive to keep the main module focused on category-based
  config editing and remote-connection management (same pattern as
  `ModelProfileEvents`). All persistence goes through `EvoDash.NodeContext`
  (node-aware: local calls run directly, remote nodes route through `:erpc`).

  EXIT SAFETY: every `EvoDash.NodeContext` call is wrapped in
  `EvoDash.SafeCall.run/1`, because a cross-node call to a dead/unreachable
  node EXITS the caller (a `GenServer.call`/`:erpc` timeout is an exit, which
  `rescue` cannot catch) and would otherwise crash the LiveView. Captured
  failures become the module's existing error flashes.

  These flows stay SYNCHRONOUS-but-exit-safe on the LiveView process for BOTH
  local and remote nodes (a ~30s remote agents.toml save blocking this page is
  accepted here): the module has no result-message plumbing, and inventing a
  tagged async message would need a `handle_info` clause in SettingsLive that
  does not exist. The follow-up refreshes already use the established paths —
  `SettingsLive.load_custom_agents_data/1` (itself `SafeCall`-wrapped) and the
  ASYNC supervised `SettingsLive.refresh_custom_tools/1`.
  """

  # zh_CN: Agent → "智能体", Model → "模型", Script → "脚本",
  # Subagent → "子智能体", Tool → "工具", Turn → "回合"

  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.SettingsLive

  # ───────────────────────────────────────────────────────────────────────────
  # Custom agent CRUD
  # ───────────────────────────────────────────────────────────────────────────

  def add_custom_agent(socket, _params) do
    # "new" is the editing sentinel for a not-yet-saved draft (core
    # auto-generates the real id from the name on first save).
    {:noreply, assign(socket, :editing_agent_id, "new")}
  end

  def edit_custom_agent(socket, %{"id" => id}) do
    {:noreply,
     assign(socket,
       editing_agent_id: if(socket.assigns.editing_agent_id == id, do: nil, else: id)
     )}
  end

  def cancel_edit_custom_agent(socket, _params) do
    {:noreply, assign(socket, :editing_agent_id, nil)}
  end

  def save_custom_agent(socket, params) do
    case build_agent_def(params) do
      {:ok, agent_def} ->
        node = socket.assigns.current_node

        case save_agent_def(node, agent_def) do
          :ok ->
            socket =
              socket
              |> assign(:editing_agent_id, nil)
              |> put_flash(:info, gettext("Custom agent saved."))
              |> SettingsLive.load_custom_agents_data()
              |> SettingsLive.refresh_custom_tools()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def delete_custom_agent(socket, %{"id" => id}) do
    node = socket.assigns.current_node

    case delete_agent_def(node, id) do
      :ok ->
        socket =
          socket
          |> assign(:editing_agent_id, nil)
          |> put_flash(:info, gettext("Custom agent deleted."))
          |> SettingsLive.load_custom_agents_data()
          |> SettingsLive.refresh_custom_tools()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Custom agent not found."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to delete custom agent: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Model selection script
  # ───────────────────────────────────────────────────────────────────────────

  def save_model_selection_script(socket, params) do
    script = params["script"] || ""
    node = socket.assigns.current_node

    case save_script(node, script) do
      :ok ->
        # The core saves broken scripts as :ok — the compile status only
        # surfaces via ModelSelector.status/0. Invalidate the compile cache
        # and reload so script_status reflects the just-saved script.
        reload_custom_agents(node)

        socket =
          socket
          |> put_flash(:info, gettext("Model selection script saved."))
          |> SettingsLive.load_custom_agents_data()
          |> SettingsLive.refresh_custom_tools()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :script_save_error, script_save_error_message(reason))}
    end
  end

  def test_model_selection_script(socket, _params) do
    node = socket.assigns.current_node

    # Invalidate the compile cache first so the test always reflects the
    # latest saved script (the cache is stat-validated, but a same-second /
    # same-size write could otherwise yield a stale compile).
    reload_custom_agents(node)

    results =
      for {label, attrs} <- sample_attrs() do
        %{label: label, result: select_model_result(node, attrs)}
      end

    socket = assign(socket, :script_test_results, results)

    {:noreply, SettingsLive.refresh_custom_tools(socket)}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: exit-safe NodeContext calls
  # ───────────────────────────────────────────────────────────────────────────

  # Saves the agent definition on the viewed node. `NodeContext.save_custom_agent/2`
  # returns `{:ok, saved} | {:error, reason}`; `SafeCall.run/1` adds an EXIT
  # (dead remote node) as `{:error, reason}`, so both collapse to the shape the
  # caller's case already handles.
  defp save_agent_def(node, agent_def) do
    case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.save_custom_agent(node, agent_def) end) do
      {:ok, {:ok, _saved}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, other}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deletes the agent on the viewed node (success value is the bare `:ok`).
  defp delete_agent_def(node, id) do
    normalize_ok(
      EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.delete_custom_agent(node, id) end)
    )
  end

  # Persists the model-selection script on the viewed node (success value is the
  # bare `:ok`).
  defp save_script(node, script) do
    normalize_ok(
      EvoDash.SafeCall.run(fn ->
        EvoDash.NodeContext.save_model_selection_script(node, script)
      end)
    )
  end

  # Invalidates the model-selector compile cache on the viewed node. Exit-safe;
  # the outcome is deliberately IGNORED (it is pure cache invalidation, and the
  # `load_custom_agents_data/1` call right after re-reads the script status) —
  # only the cross-node exit must never reach the LiveView.
  defp reload_custom_agents(node) do
    EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.reload_custom_agents(node) end)
    :ok
  end

  # Runs one sample `ModelSelector.select_model/1` call on the viewed node.
  # `NodeContext.call_remote/4` already normalizes transport failures to
  # `{:error, reason}`; `SafeCall` additionally converts a local EXIT (a dead
  # local process) into the same value the results renderer expects.
  defp select_model_result(node, attrs) do
    case EvoDash.SafeCall.run(fn ->
           EvoDash.NodeContext.call_remote(
             node,
             EvoGit.CustomAgents.ModelSelector,
             :select_model,
             [attrs]
           )
         end) do
      {:ok, {:ok, res}} -> res
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, other}
      {:error, reason} -> {:error, reason}
    end
  end

  # Normalizes a `SafeCall.run/1` result around a NodeContext call whose SUCCESS
  # value is the bare `:ok`: `{:ok, :ok}` → `:ok`; `{:ok, {:error, reason}}`
  # (core failure) and `{:error, reason}` (an EXIT) → `{:error, reason}`.
  # Total: an unexpected success payload surfaces as an error instead of a
  # crash.
  defp normalize_ok({:ok, :ok}), do: :ok
  defp normalize_ok({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_ok({:ok, other}), do: {:error, other}
  defp normalize_ok({:error, reason}), do: {:error, reason}

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: params → agent definition
  # ───────────────────────────────────────────────────────────────────────────

  # Builds the atom-keyed definition map the core `EvoGit.CustomAgents.save/1`
  # expects from the flat form params. Returns {:ok, def} or
  # {:error, message} for locally-detected invalid input (name/prompt
  # validation is delegated to the core, which returns the specific error
  # atoms handled by error_message/1).
  defp build_agent_def(params) do
    agent_id = String.trim(params["agent_id"] || "")

    with {:ok, max_turns} <- parse_max_turns(params["max_turns"]) do
      {:ok,
       %{
         id: if(agent_id == "", do: nil, else: agent_id),
         name: String.trim(params["name"] || ""),
         description: empty_to_nil(params["description"]),
         prompt: params["prompt"] || "",
         agent_type: agent_type_atom(params["agent_type"]),
         delegation_level: delegation_level_atom(params["delegation_level"]),
         model_id: empty_to_nil(params["model_id"]),
         max_turns: max_turns,
         # [] / missing = all tools (nil), otherwise the checked tool names.
         tools: tools_value(params["tools"]),
         # missing = no subagents, otherwise the checked type names.
         subagents: param_list(params["subagents"])
       }}
    end
  end

  defp parse_max_turns(nil), do: {:ok, nil}
  defp parse_max_turns(""), do: {:ok, nil}

  defp parse_max_turns(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, gettext("Max turns must be a positive integer.")}
    end
  end

  defp empty_to_nil(nil), do: nil

  defp empty_to_nil(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  # Whitelist lookup — never String.to_existing_atom on untrusted input.
  defp agent_type_atom("read"), do: :read
  defp agent_type_atom("read_write"), do: :read_write
  defp agent_type_atom(_other), do: :read_write

  defp delegation_level_atom("high"), do: :high
  defp delegation_level_atom("low"), do: :low
  defp delegation_level_atom(_other), do: :low

  # Checkbox params arrive as a single string (one checked) or a list
  # (several checked); missing key = nothing checked.
  defp param_list(nil), do: []
  defp param_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp param_list(value), do: [to_string(value)]

  defp tools_value(value) do
    case param_list(value) do
      [] -> nil
      names -> names
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: error messages
  # ───────────────────────────────────────────────────────────────────────────

  # Maps the core `EvoGit.CustomAgents.save/1` validation atoms (and the
  # transport failures that can bubble up through NodeContext) to
  # human-readable messages.
  defp error_message(:duplicate_id) do
    # zh_CN: 已存在同名智能体（id 冲突）——请改名或编辑现有智能体
    gettext("An agent with this id already exists. Rename the agent or edit the existing one.")
  end

  defp error_message(:missing_name), do: gettext("Name cannot be empty.")
  defp error_message(:missing_prompt), do: gettext("Prompt cannot be empty.")
  defp error_message(:invalid_prompt), do: gettext("Prompt is invalid.")

  defp error_message(:invalid_agent_type) do
    gettext(~s(Agent type must be "read" or "read_write".))
  end

  defp error_message(:invalid_delegation_level) do
    gettext(~s(Delegation level must be "high" or "low".))
  end

  defp error_message(:invalid_model_id), do: gettext("Model id is invalid.")
  defp error_message(:invalid_max_turns), do: gettext("Max turns must be a positive integer.")
  defp error_message(:invalid_tools), do: gettext("Tools must be a list of tool names.")

  defp error_message(:invalid_subagents),
    do: gettext("Subagents must be a list of agent type names.")

  defp error_message(reason) do
    gettext("Failed to save custom agent: %{reason}", reason: inspect(reason))
  end

  defp script_save_error_message({:compile_error, msg}), do: msg
  defp script_save_error_message({:error, {:compile_error, msg}}), do: msg

  defp script_save_error_message(reason) do
    gettext("Failed to save script: %{reason}", reason: inspect(reason))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: test script samples
  # ───────────────────────────────────────────────────────────────────────────

  # Three representative agent-spawn attribute maps covering a depth-0 root,
  # a nested built-in agent, and a custom agent.
  defp sample_attrs do
    [
      {gettext("Root architect (depth 0)"),
       %{
         agent_type: EvoGit.Agents.Architect,
         custom_agent_id: nil,
         depth: 0,
         parent_id: nil,
         task_id: "sample",
         objective: "sample"
       }},
      {gettext("Nested executor (depth 2)"),
       %{
         agent_type: EvoGit.Agents.Executor,
         custom_agent_id: nil,
         depth: 2,
         parent_id: 1,
         task_id: "sample",
         objective: "sample"
       }},
      {gettext("Custom agent (depth 1)"),
       %{
         agent_type: :custom,
         custom_agent_id: "my-agent",
         depth: 1,
         parent_id: 2,
         task_id: "sample",
         objective: "sample"
       }}
    ]
  end
end
