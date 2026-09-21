defmodule EvoDashWeb.SettingsComponents.CustomToolsPanel do
  @moduledoc """
  `custom_tools_panel/1` — Read-only panel listing the custom tool modules
  discovered in `<config_dir>/tools/` (`.`ex`/`.exs`/`.beam`), fed by
  `EvoGit.CustomTools.status/0`.

  The status value is either the facade's summary map
  `%{ok: [%{name:, file:, module:, read_only?:}], errors: [%{file:, reason:}]}`
  or a `{:error, term()}` tuple when the status could not be read at all.

  Also exposes the pure `custom_tool_names/1` helper, used by the agents
  editor to offer the loaded custom tools in the tools whitelist.
  """

  # zh_CN: Custom Tools → "自定义工具", Read-only → "只读", Write → "可写",
  # Refresh → "刷新"

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.CardShell, only: [card_shell: 1]

  # ───────────────────────────────────────────────────────────────────────────
  # custom_tools_panel/1 — Read-only status panel for custom tool modules
  # ───────────────────────────────────────────────────────────────────────────

  attr(:status, :any, required: true)
  attr(:loading, :boolean, default: false)

  def custom_tools_panel(assigns) do
    assigns =
      assigns
      |> assign(
        :tools,
        assigns.status |> ok_entries() |> Enum.map(&tool_entry/1) |> Enum.reject(&is_nil/1)
      )
      |> assign(
        :errors,
        assigns.status |> error_entries() |> Enum.map(&error_entry/1) |> Enum.reject(&is_nil/1)
      )

    ~H"""
    <%!-- zh_CN: the description tells the user to drop tool module files
         into the tools directory and reference the tool names in an agent's
         tools whitelist → "把 .ex/.exs/.beam 工具模块放到 tools 目录，并在智能体的
         工具白名单中引用工具名称" --%>
    <.card_shell
      title={gettext("Custom Tools")}
      description={
        gettext(
          "Drop .ex/.exs/.beam tool modules into <config_dir>/tools/ and reference tool names in an agent's tools whitelist."
        )
      }
    >
      <:actions>
        <button
          type="button"
          phx-click="reload_custom_tools"
          class="btn btn-ghost btn-sm gap-2 shrink-0"
          disabled={@loading}
        >
          <.icon name="hero-arrow-path" class={"size-4 #{if @loading, do: "animate-spin", else: ""}"} />
          {gettext("Refresh")}
        </button>
      </:actions>

      <%= if match?({:error, _}, @status) do %>
        <% {:error, reason} = @status %>
        <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
          <div class="min-w-0">
            <h3 class="font-bold text-sm text-error mb-2">
              {gettext("Custom Tools Unavailable")} <%!-- zh_CN: 自定义工具不可用 --%>
            </h3>
            <pre class="text-xs text-error/80 font-mono whitespace-pre-wrap break-all"><%= inspect(reason) %></pre>
          </div>
        </div>
      <% end %>

      <%!-- zh_CN: the empty state must NOT render for an unreadable status
           (`{:error, _}`), which also yields no tools/errors — showing it
           below the error banner would imply nothing is configured --%>
      <%= if @tools == [] and @errors == [] and not match?({:error, _}, @status) do %>
        <div class="flex flex-col items-center justify-center py-10 text-center border-2 border-dashed border-base-300 rounded-lg">
          <div class="text-base-content/30 mb-3">
            <.icon name="hero-wrench-screwdriver" class="size-8" />
          </div>
          <p class="text-sm text-base-content/70 font-medium mb-1">
            {gettext("No custom tools loaded")}
          </p>
          <p class="text-xs text-base-content/60">
            {gettext("Drop tool modules into <config_dir>/tools/ and refresh.")}
          </p>
        </div>
      <% end %>

      <%= if @tools != [] do %>
        <div class="space-y-2">
          <%= for tool <- @tools do %>
            <div class="rounded-md border border-base-200 bg-base-100 px-3 py-2">
              <div class="flex items-center justify-between gap-3">
                <div class="min-w-0">
                  <span class="font-mono text-sm text-base-content">{tool.name}</span>
                  <%= if tool.module do %>
                    <span class="font-mono text-xs text-base-content/60 ml-2">{tool.module}</span>
                  <% end %>
                </div>
                <%= if tool[:read_only?] do %>
                  <span class="badge badge-ghost badge-sm shrink-0">{gettext("Read-only")}</span>
                <% else %>
                  <span class="badge badge-warning badge-sm shrink-0">{gettext("Write")}</span>
                <% end %>
              </div>
              <%= if tool.file do %>
                <p class="text-xs text-base-content/60 font-mono truncate mt-1">{tool.file}</p>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @errors != [] do %>
        <div class="space-y-2 mt-3">
          <%= for error <- @errors do %>
            <div class="rounded-md border border-error/30 bg-error/5 px-3 py-2">
              <p class="font-mono text-xs text-error break-all">
                {error.file || gettext("unknown file")}
              </p>
              <p class="font-mono text-xs text-error/80 whitespace-pre-wrap break-all mt-1">
                {error.reason}
              </p>
            </div>
          <% end %>
        </div>
      <% end %>
    </.card_shell>
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # custom_tool_names/1 — Public pure helper: loaded custom tool names
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Extracts the loaded custom tool NAMES from a `EvoGit.CustomTools.status/0`
  value (or a `{:error, term()}` tuple).

  Total: any non-map input, `{:error, _}`, or odd shape yields `[]`. Blank /
  non-binary names are dropped; the result is order-preserving deduped.
  """
  def custom_tool_names(status) do
    status
    |> ok_entries()
    |> Enum.map(&entry_name/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  # ── Total status readers (atom-or-string keys, non-list → []) ──

  defp ok_entries(status) do
    case field(status, :ok) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp error_entries(status) do
    case field(status, :errors) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # Reads a key that may be an atom OR a string on a map value; anything that
  # is not a map (incl. a `{:error, _}` tuple) reads as nil.
  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp field(_other, _key), do: nil

  # ── Entry normalization (a non-string/nil-`name` entry renders nothing) ──

  defp tool_entry(entry) do
    case entry_name(entry) do
      nil ->
        nil

      name ->
        %{
          name: name,
          module: module_string(field(entry, :module)),
          file: string_value(field(entry, :file)),
          read_only?: field(entry, :read_only?) == true
        }
    end
  end

  defp error_entry(entry) do
    file = string_value(field(entry, :file))
    reason = string_value(field(entry, :reason)) || inspect(field(entry, :reason))

    if file == nil and reason == nil do
      nil
    else
      %{file: file, reason: reason}
    end
  end

  defp entry_name(entry), do: string_value(field(entry, :name))

  defp string_value(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp string_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(_value), do: nil

  defp module_string(module) when is_atom(module) and not is_nil(module), do: inspect(module)
  defp module_string(module) when is_binary(module), do: module
  defp module_string(_module), do: nil
end
