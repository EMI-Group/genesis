defmodule EvoDashWeb.DashboardComponents do
  use EvoDashWeb, :html

  @default_concurrency to_string(EvoGit.Defaults.max_concurrency())
  @default_retries to_string(EvoGit.Defaults.max_retries())
  @default_agent_max_retries to_string(EvoGit.Defaults.agent_max_retries())

  attr :path, :string, default: ""
  attr :prompt, :string, default: ""
  attr :mode, :string, default: "genesis_new"
  attr :concurrency, :string, default: @default_concurrency
  attr :retries, :string, default: @default_retries
  attr :agent_max_retries, :string, default: @default_agent_max_retries

  def task_form(assigns) do
    ~H"""
    <.form for={%{}} phx-submit="task_submit" phx-change="task_change" class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Start a Task</h2>
        <p class="text-sm text-base-content/70 mb-4">
          Bootstrap a new codebase, analyze an existing one, or evolve your code.
        </p>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Repository Path</span>
          </label>
          <input
            type="text"
            name="path"
            value={@path || File.cwd!()}
            class="input input-bordered w-full"
            placeholder="/path/to/your/repo"
          />
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Task Mode</span>
          </label>
          <select name="mode" class="select select-bordered w-full">
            <optgroup label="Genesis (Bootstrap & Analyze)">
              <option value="genesis_new" selected={@mode == "genesis_new"}>New Codebase</option>
              <option value="genesis_existing" selected={@mode == "genesis_existing"}>Existing Codebase</option>
            </optgroup>
            <optgroup label="Evolve (Mutate Code)">
              <option value="evolve_simple" selected={@mode == "evolve_simple"}>Simple (Top-down)</option>
              <option value="evolve_complex" selected={@mode == "evolve_complex"}>Complex (Bottom-up)</option>
            </optgroup>
          </select>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Prompt / Objective</span>
          </label>
          <textarea
            name="prompt"
            class="textarea textarea-bordered h-32"
            placeholder="Describe the software you want to create or the change you want to make..."
          ><%= @prompt %></textarea>
        </div>

        <div class="grid grid-cols-3 gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Concurrency</span>
            </label>
            <input
              type="number"
              name="concurrency"
              value={@concurrency}
              min="1"
              max="10000"
              class="input input-bordered"
            />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Max Retries</span>
            </label>
            <input
              type="number"
              name="retries"
              value={@retries}
              min="1"
              max="10000"
              class="input input-bordered"
            />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Agent Max Retries</span>
            </label>
            <input
              type="number"
              name="agent_max_retries"
              value={@agent_max_retries}
              min="1"
              max="100"
              class="input input-bordered"
            />
          </div>
        </div>

        <div class="card-actions justify-end mt-4">
          <button type="submit" class="btn btn-primary">
            <.icon name="hero-rocket-launch" class="size-4" /> Start Task
          </button>
        </div>
      </div>
    </.form>
    """
  end

  attr :task, :map, required: true
  attr :show_details, :boolean, default: false

  def task_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-200">
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-4">
          <div class="flex items-start gap-3 flex-1">
            <div class="avatar placeholder">
              <div class="bg-neutral text-neutral-content rounded-lg w-12 h-12">
                <.icon name={task_type_icon(@task.type)} class="size-6" />
              </div>
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <h3 class="font-semibold capitalize">{@task.type}</h3>
                <span class={status_badge(@task.status)}>{@task.status}</span>
              </div>
              <p class="text-xs text-base-content/60 mt-1">
                ID: <code class="bg-base-200 px-1 rounded">{@task.id}</code>
              </p>
              <p class="text-sm mt-2 truncate">
                {task_description(@task)}
              </p>
              <div class="flex items-center gap-4 mt-2 text-xs text-base-content/60">
                <span>
                  <.icon name="hero-clock" class="size-3 inline" />
                  Started: {format_datetime(@task.started_at)}
                </span>
                <%= if Map.get(@task, :finished_at) do %>
                  <span>
                    <.icon name="hero-check-circle" class="size-3 inline" />
                    Finished: {format_datetime(@task.finished_at)}
                  </span>
                <% end %>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @task.status == :running do %>
              <button
                class="btn btn-sm btn-error btn-ghost"
                phx-click="cancel_task"
                phx-value-task_id={@task.id}
                phx-confirm="Are you sure you want to cancel this task?"
              >
                <.icon name="hero-x-mark" class="size-4" /> Cancel
              </button>
            <% end %>
            <button
              class="btn btn-sm btn-ghost"
              phx-click="toggle_task_details"
              phx-value-task_id={@task.id}
            >
              <%= if @show_details do %>
                <.icon name="hero-chevron-up" class="size-4" />
              <% else %>
                <.icon name="hero-chevron-down" class="size-4" />
              <% end %>
            </button>
          </div>
        </div>

        <%= if @show_details do %>
          <div class="divider my-2"></div>
          <div class="space-y-2">
            <div>
              <h4 class="text-sm font-semibold mb-2">Options</h4>
              <pre class="text-xs bg-base-200 p-2 rounded overflow-x-auto"><%= inspect(@task.opts, pretty: true) %></pre>
            </div>
            <%= if Map.get(@task, :result) do %>
              <div>
                <h4 class="text-sm font-semibold mb-2">Result</h4>
                <pre class="text-xs bg-base-200 p-2 rounded overflow-x-auto"><%= inspect(@task.result, pretty: true) %></pre>
              </div>
            <% end %>
            <%= if @task.logs != [] do %>
              <div>
                <h4 class="text-sm font-semibold mb-2">Logs</h4>
                <div class="bg-base-200 p-2 rounded max-h-48 overflow-y-auto text-xs font-mono space-y-1">
                  <%= for log <- Enum.reverse(@task.logs) do %>
                    <div class={[
                      "log-entry",
                      log.level == :error && "text-error",
                      log.level == :warn && "text-warning"
                    ]}>
                      <span class="text-base-content/40">
                        [{format_datetime(log.timestamp, :time)}]
                      </span>
                      <span class={[
                        "font-semibold",
                        log.level == :error && "text-error",
                        log.level == :warn && "text-warning"
                      ]}>
                        {String.upcase(to_string(log.level))}:
                      </span>
                      {log.message}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_badge(:running), do: "badge badge-info badge-sm"
  defp status_badge(:completed), do: "badge badge-success badge-sm"
  defp status_badge(:failed), do: "badge badge-error badge-sm"
  defp status_badge(:cancelled), do: "badge badge-warning badge-sm"
  defp status_badge(_), do: "badge badge-ghost badge-sm"

  defp task_type_icon(:genesis), do: "hero-cube"
  defp task_type_icon(:evolve), do: "hero-arrow-path"

  defp task_description(%{type: :genesis, opts: opts}) do
    "Mode: #{opts[:mode]} | #{String.slice(opts[:prompt] || "", 0, 50)}"
  end

  defp task_description(%{type: :evolve, opts: opts}) do
    "Mode: #{opts[:mode]} | #{String.slice(opts[:objective] || "", 0, 50)}"
  end

  defp task_description(_), do: ""

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp format_datetime(datetime, :time),
    do: datetime.time |> Time.to_string() |> String.slice(0..7)
end
