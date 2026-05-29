defmodule EvoDashWeb.Helpers do
  @moduledoc """
  Shared helper functions and components consolidating duplicated code
  from across the dashboard (AgentsLive, AgentsComponents, DashboardComponents,
  DashboardLive).

  This module is imported via `use EvoDashWeb, :html` and `use EvoDashWeb, :live_view`.
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # Agent Status Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns text color class for agent status (`:pending`, `:running`, `:waiting`).
  """
  def agent_status_color(:pending), do: "text-base-content/70"
  def agent_status_color(:running), do: "text-success"
  def agent_status_color(:waiting), do: "text-warning"
  def agent_status_color(:blocked), do: "text-error"
  def agent_status_color(:ready), do: "text-info"
  def agent_status_color(_), do: "text-base-content/70"

  @doc """
  Returns background color class for agent status.
  """
  def agent_status_bg(:pending), do: "bg-base-100"
  def agent_status_bg(:running), do: "bg-success/10"
  def agent_status_bg(:waiting), do: "bg-warning/10"
  def agent_status_bg(:blocked), do: "bg-error/10"
  def agent_status_bg(:ready), do: "bg-info/10"
  def agent_status_bg(_), do: "bg-base-100"

  @doc """
  Returns border color class for agent status.
  """
  def agent_status_border(:pending), do: "border-base-300"
  def agent_status_border(:running), do: "border-success/30"
  def agent_status_border(:waiting), do: "border-warning/30"
  def agent_status_border(:blocked), do: "border-error/30"
  def agent_status_border(:ready), do: "border-info/30"
  def agent_status_border(_), do: "border-base-300"

  @doc """
  Returns heroicon name for agent status.
  """
  def agent_status_icon(:pending), do: "hero-clock"
  def agent_status_icon(:running), do: "hero-play-circle"
  def agent_status_icon(:waiting), do: "hero-pause-circle"
  def agent_status_icon(:blocked), do: "hero-exclamation-circle"
  def agent_status_icon(:ready), do: "hero-arrow-path"
  def agent_status_icon(_), do: "hero-question-mark-circle"

  # ---------------------------------------------------------------------------
  # Task Status Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns badge class string for task status (`:running`, `:completed`, `:failed`,
  `:cancelled`, `:pending`).
  """
  def task_status_badge(:running), do: "badge badge-info badge-sm"
  def task_status_badge(:completed), do: "badge badge-success badge-sm"
  def task_status_badge(:failed), do: "badge badge-error badge-sm"
  def task_status_badge(:cancelled), do: "badge badge-warning badge-sm"
  def task_status_badge(_), do: "badge badge-ghost badge-sm"

  @doc """
  Returns heroicon name for task type (`:genesis`, `:evolve`).
  """
  def task_type_icon(:genesis), do: "hero-cube"
  def task_type_icon(:evolve), do: "hero-arrow-path"

  # ---------------------------------------------------------------------------
  # Datetime Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Formats a `DateTime` as `"YYYY-MM-DD HH:MM"`.

  With `:time` option, formats as `"HH:MM:SS"`.
  """
  def format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  def format_datetime(datetime, :time),
    do: datetime.time |> Time.to_string() |> String.slice(0..7)

  @doc """
  Formats a millisecond timestamp as `"HH:MM:SS"`.
  """
  def format_timestamp(timestamp_ms) do
    datetime = DateTime.from_unix!(timestamp_ms, :millisecond)
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  @doc """
  Formats a turn number as "Turn N".
  """
  def format_turn(turn) when is_integer(turn) do
    "Turn #{turn}"
  end

  # ---------------------------------------------------------------------------
  # History / Message Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns heroicon name for a message role (`"system"`, `"user"`, `"assistant"`,
  `"tool"`, etc.).
  """
  def history_entry_icon("system"), do: "hero-cog"
  def history_entry_icon("user"), do: "hero-chat-bubble-left-ellipsis"
  def history_entry_icon("assistant"), do: "hero-sparkles"
  def history_entry_icon("tool"), do: "hero-wrench-screwdriver"
  def history_entry_icon(_), do: "hero-document-text"

  @doc """
  Returns text color class for a message role.
  """
  def history_entry_color("system"), do: "text-accent"
  def history_entry_color("user"), do: "text-info"
  def history_entry_color("assistant"), do: "text-warning"
  def history_entry_color("tool"), do: "text-success"
  def history_entry_color(_), do: "text-base-content/70"

  @doc """
  Safely extracts the tool call name from various map formats.
  """
  def tool_call_name(call) when is_map(call) do
    cond do
      Map.has_key?(call, :function) and is_map(call.function) ->
        Map.get(call.function, :name, "unknown")

      Map.has_key?(call, "function") and is_map(call["function"]) ->
        Map.get(call["function"], "name") || Map.get(call["function"], "name", "unknown")

      Map.has_key?(call, :name) ->
        call.name

      Map.has_key?(call, "name") ->
        call["name"]

      true ->
        "unknown"
    end
  end

  def tool_call_name(_), do: "unknown"

  @doc """
  Safely extracts tool call arguments from various map formats.
  """
  def tool_call_arguments(call) when is_map(call) do
    cond do
      Map.has_key?(call, :function) and is_map(call.function) ->
        Map.get(call.function, :arguments_json) ||
          Map.get(call.function, :arguments, "{}")

      Map.has_key?(call, "function") and is_map(call["function"]) ->
        Map.get(call["function"], "arguments_json") ||
          Map.get(call["function"], "arguments") ||
          Map.get(call["function"], "arguments", "{}")

      Map.has_key?(call, :arguments) ->
        call.arguments

      Map.has_key?(call, "arguments") ->
        call["arguments"]

      true ->
        "{}"
    end
  end

  def tool_call_arguments(_), do: "{}"

  @doc """
  Extracts and joins reasoning text from a list of ReasoningDetails structs.
  Returns `nil` if the list is empty or contains no text.
  """
  def format_reasoning_details(nil), do: nil

  def format_reasoning_details(details) when is_list(details) do
    text =
      details
      |> Enum.map(fn
        %{text: text} when is_binary(text) -> text
        _ -> ""
      end)
      |> Enum.join("")

    if text == "", do: nil, else: text
  end

  # ---------------------------------------------------------------------------
  # Formatting Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Formats an atom module name to its last segment.
  e.g., `EvoGit.Agent.Spatial` → `"Spatial"`
  """
  def format_module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  def format_module_name(_), do: "Unknown"

  @doc """
  Returns a short description string for a task map based on its type and opts.
  """
  def task_description(%{type: :genesis, opts: opts}) do
    "Mode: #{opts[:mode]} | #{String.slice(opts[:prompt] || "", 0, 50)}"
  end

  def task_description(%{type: :evolve, opts: opts}) do
    "Mode: #{opts[:mode]} | #{String.slice(opts[:objective] || "", 0, 50)}"
  end

  def task_description(_), do: ""

  @doc """
  Returns an info message string for the given auto-detected mode identifier.
  """
  def mode_info_message("genesis_new"),
    do: "Empty directory detected — New Codebase mode selected"

  def mode_info_message("genesis_existing"),
    do: "No CONTEXT.md found — Existing Codebase mode selected"

  def mode_info_message("evolve_simple"),
    do: "Context tree detected — Simple (Top-down) mode selected"

  def mode_info_message("evolve_complex"),
    do: "Context tree detected — Complex (Bottom-up) mode selected"

  def mode_info_message(_), do: ""

  # ---------------------------------------------------------------------------
  # Modal Component
  # ---------------------------------------------------------------------------

  @doc """
  A shared modal component wrapping the common DaisyUI modal pattern.

  ## Attributes

    * `:id` - optional HTML id for the modal container
    * `:on_close` - the PHX event name dispatched when closing (via backdrop or action button)

  ## Slots

    * `:title` - the modal heading content
    * `:inner_block` - the modal body content
    * `:actions` - optional footer action buttons (rendered inside `modal-action`)
  """
  attr :id, :string, default: nil
  attr :on_close, :string, required: true
  attr :max_width, :string, default: "max-w-5xl"

  slot :title
  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    ~H"""
    <div class="modal modal-open bg-black/50" id={@id}>
      <div class={["modal-box w-11/12", @max_width]}>
        <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
          {render_slot(@title)}
        </h3>

        <div class="bg-base-200 p-4 rounded-lg overflow-x-auto max-h-[70vh] overflow-y-auto">
          {render_slot(@inner_block)}
        </div>

        <div class="modal-action">
          <button class="btn" phx-click={@on_close}>Close</button>
          {render_slot(@actions)}
        </div>
      </div>

      <div class="modal-backdrop" phx-click={@on_close}>
        <button class="cursor-default">close</button>
      </div>
    </div>
    """
  end
end
