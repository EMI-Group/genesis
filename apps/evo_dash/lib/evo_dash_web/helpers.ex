defmodule EvoDashWeb.Helpers do
  @moduledoc """
  Shared helper functions and components consolidating duplicated code
  from across the dashboard (AgentsLive, AgentsComponents, DashboardComponents,
  DashboardLive).

  This module is imported via `use EvoDashWeb, :html` and `use EvoDashWeb, :live_view`.
  """

  use Phoenix.Component
  import EvoDashWeb.CoreComponents
  use Gettext, backend: EvoDashWeb.Gettext

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
  def task_status_badge(:running),
    do: "bg-success/10 text-success rounded-full flex items-center justify-center"

  def task_status_badge(:finalizing),
    do: "bg-orange-500/10 text-orange-500 rounded-full flex items-center justify-center"

  def task_status_badge(:completed),
    do: "bg-info/10 text-info rounded-full flex items-center justify-center"

  def task_status_badge(:failed),
    do: "bg-error/10 text-error rounded-full flex items-center justify-center"

  def task_status_badge(:cancelled),
    do: "bg-warning/10 text-warning rounded-full flex items-center justify-center"

  def task_status_badge(_),
    do: "bg-base-200 text-base-content/70 rounded-full flex items-center justify-center"

  @doc """
  Returns heroicon name for task type (`:genesis`, `:evolve`).
  """
  def task_type_icon(:genesis), do: "hero-cube"
  def task_type_icon(:evolve), do: "hero-arrow-path"

  # ---------------------------------------------------------------------------
  # Review Status Helpers
  # ---------------------------------------------------------------------------

  @doc "Returns DaisyUI badge class for review status."
  def review_status_badge(:open), do: "badge-warning"
  def review_status_badge(:merged), do: "badge-success"
  def review_status_badge(:rejected), do: "badge-error"
  def review_status_badge(:continued), do: "badge-info"
  def review_status_badge(:ignored), do: "badge-ghost"
  def review_status_badge(:no_changes), do: "badge-ghost"
  def review_status_badge(_), do: "badge-ghost"

  @doc "Returns heroicon name for review status."
  def review_status_icon(:open), do: "hero-clock"
  def review_status_icon(:merged), do: "hero-check-circle"
  def review_status_icon(:rejected), do: "hero-x-circle"
  def review_status_icon(:continued), do: "hero-arrow-path"
  def review_status_icon(:ignored), do: "hero-eye-slash"
  def review_status_icon(:no_changes), do: "hero-information-circle"
  def review_status_icon(_), do: "hero-question-mark-circle"

  @doc "Returns localized label for review status."
  def review_status_label(:open), do: gettext("Open")
  def review_status_label(:merged), do: gettext("Merged")
  def review_status_label(:rejected), do: gettext("Rejected")
  def review_status_label(:continued), do: gettext("Continued")
  def review_status_label(:ignored), do: gettext("Ignored")
  def review_status_label(:no_changes), do: gettext("No Changes")
  def review_status_label(_), do: gettext("Unknown")

  # ---------------------------------------------------------------------------
  # Datetime Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Formats a `DateTime` as `"YYYY-MM-DD HH:MM"`.

  With `:time` option, formats as `"HH:MM:SS"`.

  Robust to `nil` (returns an empty string) and ISO8601 binary strings
  (as stored in JSON/DETS archive metadata) by parsing them before
  formatting. Unparseable strings are returned as-is.
  """
  def format_datetime(nil), do: ""

  def format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_datetime(dt)
      {:error, _} -> datetime
    end
  end

  def format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  def format_datetime(nil, :time), do: ""

  def format_datetime(datetime, :time) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_datetime(dt, :time)
      {:error, _} -> datetime
    end
  end

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
    gettext("Turn %{turn}", turn: turn)
  end

  @doc """
  Returns a human-friendly relative time string for a `DateTime`.

  Computes the difference between `DateTime.utc_now()` and the given datetime.

  ## Examples

      iex> relative_time(DateTime.add!(DateTime.utc_now(), -5, :second))
      "just now"

      iex> relative_time(DateTime.add!(DateTime.utc_now(), -45, :second))
      "45s ago"

      iex> relative_time(DateTime.add!(DateTime.utc_now(), -120, :second))
      "2m ago"

      iex> relative_time(DateTime.add!(DateTime.utc_now(), -3600, :second))
      "1h ago"

      iex> relative_time(DateTime.add!(DateTime.utc_now(), -86400, :second))
      "1d ago"
  """
  def relative_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> relative_time(dt)
      {:error, _} -> datetime
    end
  end

  def relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff < 10 -> gettext("just now")
      diff < 60 -> gettext("%{count}s ago", count: diff)
      diff < 3600 -> gettext("%{count}m ago", count: div(diff, 60))
      diff < 86400 -> gettext("%{count}h ago", count: div(diff, 3600))
      true -> gettext("%{count}d ago", count: div(diff, 86400))
    end
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

  def format_module_name(_), do: gettext("Unknown")

  @doc """
  Returns a short description string for a task map based on its type and opts.
  """
  def task_description(%{type: :genesis, opts: opts}) do
    prompt = opts[:prompt] || ""
    gettext("Mode: %{mode} | %{prompt}", mode: opts[:mode], prompt: String.slice(prompt, 0, 200))
  end

  def task_description(%{type: :evolve, opts: opts}) do
    objective = opts[:objective] || ""

    gettext("Mode: %{mode} | %{prompt}",
      mode: opts[:mode],
      prompt: String.slice(objective, 0, 200)
    )
  end

  def task_description(_), do: ""

  @doc """
  Returns an info message string for the given auto-detected mode identifier.
  """
  def mode_info_message("genesis_new"),
    do: gettext("Empty directory detected — New Codebase mode selected")

  def mode_info_message("genesis_existing"),
    do: gettext("No CONTEXT.md found — Existing Codebase mode selected")

  def mode_info_message("evolve_simple"),
    do: gettext("Context tree detected — Evolution mode selected")

  def mode_info_message(_), do: ""

  # ---------------------------------------------------------------------------
  # Config Status Badge
  # ---------------------------------------------------------------------------

  @doc """
  Calls `EvoGit.Config.config_status/0`.

  The call is intentionally NOT wrapped in a try/rescue — if the config system
  crashes, the error must propagate rather than be hidden behind a fake "config
  OK" status.
  """
  def config_status do
    EvoGit.Config.config_status()
  end

  @doc """
  Renders a status badge for configuration completeness.

  Takes a map with `:ok?` (boolean) and `:missing` (list of atoms) keys, as
  returned by `EvoGit.Config.config_status/0`.

  Returns a HEEx fragment via `~H`.

  ## Examples

      config_status_badge(%{ok?: true, missing: []})
      #=> green badge with "All configured"

      config_status_badge(%{ok?: false, missing: [:llm_model, :api_key]})
      #=> warning card listing missing items
  """
  attr(:status, :map, required: true)

  def config_status_badge(assigns) do
    ~H"""
    <%= if @status.ok? do %>
      <div class="bg-success/10 border border-success/20 rounded-xl p-4 flex items-center gap-3">
        <.icon name="hero-check-circle" class="size-5 text-success shrink-0" />
        <div>
          <p class="font-semibold text-success">{gettext("All configured")}</p>
          <p class="text-xs text-success/70">{gettext("All critical configuration values are set")}</p>
        </div>
      </div>
    <% else %>
      <div class="bg-warning/10 border border-warning/20 rounded-xl p-4">
        <h3 class="font-semibold text-warning flex items-center gap-2 mb-2">
          <.icon name="hero-exclamation-triangle" class="size-5" /> {gettext("Missing Configuration")}
        </h3>
        <div class="flex flex-wrap gap-2">
          <%= for item <- @status.missing do %>
            <span class="badge badge-warning badge-sm">
              <.icon name="hero-x-mark" class="size-3" />
              {format_config_item(item)}
            </span>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp format_config_item(:llm_model), do: gettext("LLM Model")
  defp format_config_item(:api_key), do: gettext("API Key")
  defp format_config_item(:github_username), do: gettext("GitHub Username")

  defp format_config_item(item),
    do: Atom.to_string(item) |> String.replace("_", " ") |> String.capitalize()

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
  attr(:id, :string, default: nil)
  attr(:on_close, :string, required: true)
  attr(:max_width, :string, default: "max-w-5xl")

  slot(:title)
  slot(:inner_block, required: true)
  slot(:actions)

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
          <button class="btn" phx-click={@on_close}>{gettext("Close")}</button>
          {render_slot(@actions)}
        </div>
      </div>

      <div class="modal-backdrop" phx-click={@on_close}>
        <button class="cursor-default">{gettext("close")}</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tooltip / Tip Component
  # ---------------------------------------------------------------------------

  @doc """
  Renders an inline info icon with a tooltip on hover.
  Uses DaisyUI tooltip component.

  ## Attributes

    * `:text` (required) — the tooltip content
    * `:icon` (optional) — icon name, default "hero-information-circle"
    * `:class` (optional) — additional CSS classes
    * `:position` (optional) — tooltip position, one of :top, :bottom, :left, :right (default :top)
  """
  attr(:text, :string, required: true)
  attr(:icon, :string, default: "hero-information-circle")
  attr(:class, :string, default: "")
  attr(:position, :atom, default: :top)

  def tip(assigns) do
    assigns = assign(assigns, :position_class, tip_position_class(assigns.position))

    ~H"""
    <span class={["tooltip", @position_class, "cursor-help"]} data-tip={@text}>
      <.icon name={@icon} class={"size-4 text-base-content/40 hover:text-base-content/70 transition-colors inline-block align-middle #{@class}"} />
    </span>
    """
  end

  defp tip_position_class(:bottom), do: "tooltip-bottom"
  defp tip_position_class(:left), do: "tooltip-left"
  defp tip_position_class(:right), do: "tooltip-right"
  defp tip_position_class(_), do: "tooltip-top"

  # ---------------------------------------------------------------------------
  # Mode Description Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns a short human-readable description of the given task mode.
  """
  def mode_description("genesis_new"),
    do:
      gettext(
        "Creates a brand new codebase from scratch in an empty directory using your prompt."
      )

  def mode_description("genesis_existing"),
    do:
      gettext("Analyzes an existing codebase and generates CONTEXT.md spatial contracts for it.")

  def mode_description("evolve_simple"),
    do: gettext("Uses a single top-down agent to modify the codebase based on your objective.")

  def mode_description(_), do: ""

  # ---------------------------------------------------------------------------
  # Number / Cost Formatting
  # ---------------------------------------------------------------------------

  @thousands_regex ~r/(\d)(?=(\d{3})+$)/

  @doc """
  Formats an integer with comma-separated thousands.
  """
  def format_number(n) when is_integer(n), do: format_number(Integer.to_string(n))

  def format_number(str) when is_binary(str) do
    Regex.replace(@thousands_regex, str, "\\1,")
  end

  def format_number(_), do: "0"

  @doc """
  Formats a number as a cost string with 6 decimal places.
  """
  def format_cost(cost) when is_number(cost) do
    :erlang.float_to_binary(cost * 1.0, decimals: 6)
  end

  def format_cost(_), do: "0.000000"

  @doc """
  Formats the cache hit rate as a percentage (cached tokens / input tokens).
  """
  def format_cache_hit_rate(usage) when is_map(usage) do
    # Map.get with default is used instead of dot access because the guard
    # accepts is_map/1 (plain maps in addition to EvoGit.Agent.Usage structs).
    input = Map.get(usage, :input_tokens, 0)
    cached = Map.get(usage, :cached_tokens, 0)

    if input > 0 do
      :erlang.float_to_binary(cached / input * 100.0, decimals: 1) <> "%"
    else
      "0.0%"
    end
  end

  def format_cache_hit_rate(_), do: "0.0%"

  # ---------------------------------------------------------------------------
  # String Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Truncates a string to `len` characters, appending "..." if truncated.
  """
  def truncate_string(nil, _len), do: ""
  def truncate_string(str, len) when byte_size(str) > len, do: String.slice(str, 0, len) <> "..."
  def truncate_string(str, _len), do: str
end
