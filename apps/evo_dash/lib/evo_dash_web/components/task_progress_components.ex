defmodule EvoDashWeb.TaskProgressComponents do
  @moduledoc "Task progress shared with structured clients, rendered without fetching conversations."
  use EvoDashWeb, :html

  attr :id, :string, required: true
  attr :report, :map, default: nil
  attr :status, :atom, default: :running
  attr :compact, :boolean, default: false

  def progress(assigns) do
    assigns =
      assigns
      |> assign(:sections, sections(assigns.status))
      |> assign(:has_report, has_report?(assigns.report))

    ~H"""
    <section
      id={@id}
      aria-label={gettext("Task progress")}
      class="space-y-3 min-w-0"
      aria-live="polite"
    >
      <%= if @has_report do %>
        <div class="space-y-1">
          <p :if={@report["summary"]} class="text-sm text-base-content leading-relaxed break-words">
            {@report["summary"]}
          </p>
          <time
            :if={@report["updated_at"]}
            datetime={@report["updated_at"]}
            class="text-xs text-base-content/70"
          >
            {gettext("Last update")}: {@report["updated_at"]}
          </time>
        </div>
        <dl :if={!@compact} class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4 text-sm">
          <div :for={{key, label} <- @sections} :if={Map.get(@report, key, []) != []} class="min-w-0">
            <dt class="font-medium text-base-content mb-1">{label}</dt>
            <dd>
              <ul class="list-disc pl-4 space-y-1 text-base-content/80 break-words">
                <li :for={item <- Map.get(@report, key, [])}>{item}</li>
              </ul>
            </dd>
          </div>
        </dl>
        <p :if={!@compact && @report["truncated"]} class="text-xs text-base-content/70">
          {gettext("Recent progress is shown; some earlier reports are omitted.")}
        </p>
      <% else %>
        <p class="text-sm text-base-content/70">{gettext("No progress reported yet")}</p>
      <% end %>
    </section>
    """
  end

  defp has_report?(nil), do: false

  defp has_report?(report) do
    is_binary(report["summary"]) or
      Enum.any?(
        ~w(current_work completed remaining blockers next_steps),
        &(Map.get(report, &1, []) != [])
      )
  end

  defp sections(status) do
    current =
      if status in [:completed, :failed, :cancelled],
        do: gettext("Last reported work"),
        else: gettext("Current work")

    [
      {"current_work", current},
      {"completed", gettext("Reported outcomes")},
      {"remaining", gettext("Remaining work")},
      {"blockers", gettext("Blockers")},
      {"next_steps", gettext("Next steps")}
    ]
  end
end
