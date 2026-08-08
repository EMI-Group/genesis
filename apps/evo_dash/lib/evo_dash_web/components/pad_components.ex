defmodule EvoDashWeb.PadComponents do
  @moduledoc """
  Function components and pure task-map helpers for the Pad — the v3 home
  design (`HomeLive` `/` + `ReviewsLive` `/reviews`). See
  `docs/launchpad-frontend-spec.md`.

  Two-pole attention model: L1 (solid `base-content`) is reserved for the
  prompt textarea, the Start button, the current mode tab, and the running
  pulse; EVERYTHING else is L3 (`base-content` at ~35–40% alpha). No
  mid-levels — no semi-bold secondary headings, no colored badges.

  Components:

    * `pad_top_bar/1` — the single global chrome for EVERY page (the old
      sidebar shell is retired): brand on the left, fixed right-side nav
      (Tree / Review N / Settings / System links, theme toggle). `N` is the
      awaiting-review count — the top bar's only strong signal; the current
      page's link is L1, all other links L3. `current` is one of `:home`,
      `:tree`, `:reviews`, `:settings`, `:system`, `:tasks`, `:review`,
      `:none`.
    * `rail_square/1` — one task card in the home rail: the project folder
      name + a prompt preview + a status dot. Tooltip content travels in
      `data-tip-*` attributes (the PadFly hook renders it fixed-position —
      the rail is a scroll container and would clip an in-rail tooltip).

  Pure helpers (shared by both LiveViews; summary-map safe — `Map.get` only,
  no dot access beyond contract keys): `task_prompt/1`, `task_branch/1`,
  `awaiting_review?/1`, `decided_review?/1`, `rail_status/1`, `square_link/1`,
  `project_name/1`, `prompt_preview/1`.
  """

  use EvoDashWeb, :html

  @decided_statuses [:merged, :rejected, :continued, :ignored]

  # ---------------------------------------------------------------------------
  # pad_top_bar/1 — the single global chrome for EVERY page (the sidebar shell
  # is retired). All L3 except the review count and the current page's link.
  # ---------------------------------------------------------------------------

  attr(:current, :atom,
    required: true,
    values: [:home, :tree, :reviews, :settings, :system, :tasks, :review, :none]
  )

  attr(:review_count, :integer, default: 0)

  def pad_top_bar(assigns) do
    ~H"""
    <header class="h-[50px] shrink-0 w-full flex items-center gap-6 px-6 border-b border-base-300 bg-base-100">
      <.link
        navigate={~p"/"}
        class="font-mono text-xs text-base-content/40 hover:text-base-content transition-colors"
      >
        {gettext("Genesis")}
      </.link>
      <div class="flex-1"></div>
      <nav class="flex items-center gap-5" aria-label={gettext("Pad navigation")}>
        <.link
          navigate={~p"/"}
          class={pad_nav_classes(@current == :home)}
          aria-current={if @current == :home, do: "page", else: false}
        >
          {gettext("Start")}
        </.link>
        <.link
          navigate={~p"/agents"}
          class={pad_nav_classes(@current == :tree)}
          aria-current={if @current == :tree, do: "page", else: false}
        >
          {gettext("Tree")}
        </.link>
        <.link
          navigate={~p"/reviews"}
          class={pad_nav_classes(@current == :reviews)}
          aria-current={if @current == :reviews, do: "page", else: false}
        >
          {gettext("Review")}
          <b :if={@review_count > 0} class="font-semibold text-base-content not-italic">
            {@review_count}
          </b>
        </.link>
        <.link
          navigate={~p"/tasks"}
          class={pad_nav_classes(@current == :tasks)}
          aria-current={if @current == :tasks, do: "page", else: false}
        >
          {gettext("Projects")}
        </.link>
        <.link
          navigate={~p"/settings"}
          class={pad_nav_classes(@current == :settings)}
          aria-current={if @current == :settings, do: "page", else: false}
        >
          {gettext("Settings")}
        </.link>
        <.link
          navigate={~p"/system"}
          class={pad_nav_classes(@current == :system)}
          aria-current={if @current == :system, do: "page", else: false}
        >
          {gettext("System")}
        </.link>
        <%!-- Compact theme swap (L3): one icon, not the 3-button pill. --%>
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="dark"
          title={gettext("Dark theme")}
          class="text-base-content/40 hover:text-base-content transition-colors [[data-theme=dark]_&]:hidden"
        >
          <.icon name="hero-moon-micro" class="w-4 h-4" />
        </button>
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="light"
          title={gettext("Light theme")}
          class="hidden text-base-content/40 hover:text-base-content transition-colors [[data-theme=dark]_&]:block"
        >
          <.icon name="hero-sun-micro" class="w-4 h-4" />
        </button>
      </nav>
    </header>
    """
  end

  # Nav link classes: the current page's link is the only L1 item in the bar
  # (besides the review count); everything else stays L3.
  defp pad_nav_classes(current?) do
    [
      "text-xs transition-colors inline-flex items-baseline gap-1",
      current? && "text-base-content font-semibold",
      !current? && "text-base-content/40 hover:text-base-content"
    ]
  end

  # ---------------------------------------------------------------------------
  # rail_square/1 — one task card in the home rail: project folder name +
  # prompt preview + a status dot. Clickable when the task leads somewhere:
  # unfinished (running/pending/finalizing) → /agents (tree); completed →
  # /review/:id (review, with the review color as the cue). Tooltip content
  # travels in `data-tip-*` attributes (the PadFly hook renders it
  # fixed-position — the rail is a scroll container and would clip an
  # in-rail tooltip).
  # ---------------------------------------------------------------------------

  attr(:task, :map, required: true)
  attr(:enter, :boolean, default: false, doc: "play the pop entrance animation")

  def rail_square(assigns) do
    status = rail_status(assigns.task)

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:name, project_name(Map.get(assigns.task, :project_path)))
      |> assign(:preview, prompt_preview(assigns.task))
      |> assign(:link, square_link(assigns.task))
      |> assign(:prompt, task_prompt(assigns.task))
      |> assign(:tip_time, tip_time(assigns.task))

    ~H"""
    <%= if @link do %>
      <.link
        navigate={@link}
        id={"pad-sq-#{@task.id}"}
        class={["pad-sq", status_class(@status), @enter && "pad-sq-enter"]}
        data-tip-prompt={@prompt}
        data-tip-path={Map.get(@task, :project_path)}
        data-tip-time={@tip_time}
      >
        <span class="pad-sq-name">{@name}</span>
        <span class="pad-sq-preview">{@preview}</span>
        <span class="pad-st"></span>
      </.link>
    <% else %>
      <div
        id={"pad-sq-#{@task.id}"}
        class={["pad-sq", status_class(@status), @enter && "pad-sq-enter"]}
        data-tip-prompt={@prompt}
        data-tip-path={Map.get(@task, :project_path)}
        data-tip-time={@tip_time}
      >
        <span class="pad-sq-name">{@name}</span>
        <span class="pad-sq-preview">{@preview}</span>
        <span class="pad-st"></span>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Pure helpers on task summary maps
  # ---------------------------------------------------------------------------

  @doc "Prompt/objective text from the task opts (summary-map safe)."
  def task_prompt(task) do
    opts = Map.get(task, :opts) || []
    text = opts[:prompt] || opts[:objective] || ""
    String.trim(to_string(text))
  end

  @doc """
  The task's branch name: the `branch_name` contract key first, then the
  result payload (`{:ok, %{branch_name: ...}}`). `nil` when there is none.
  """
  def task_branch(task) do
    case Map.get(task, :branch_name) do
      branch when is_binary(branch) and branch != "" ->
        branch

      _ ->
        case Map.get(task, :result) do
          {:ok, result} when is_map(result) ->
            case Map.get(result, :branch_name) do
              branch when is_binary(branch) and branch != "" -> branch
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  @doc """
  Awaiting review = `completed` + non-empty branch + `review_status` nil.
  These tasks are what the top-bar count and the "Waiting for you" group show.
  """
  def awaiting_review?(task) do
    Map.get(task, :status) == :completed and is_nil(Map.get(task, :review_status)) and
      task_branch(task) != nil
  end

  @doc "Decided = `review_status` is one of merged/rejected/continued/ignored."
  def decided_review?(task), do: Map.get(task, :review_status) in @decided_statuses

  @doc "The statuses that count as a taken review decision, in display order."
  def decided_statuses, do: @decided_statuses

  @doc """
  Rail status classification → square CSS variant:

    * `:run` — running/pending/finalizing (unfinished): L1 border + pulsing
      black dot, links to the tree (`/agents`)
    * `:review` — completed: solid black dot, links to the review
      (`/review/:id`)
    * `:failed` — failed: the dot becomes a small black square
    * `:plain` — everything else (cancelled): gray dot
  """
  def rail_status(task) do
    status = Map.get(task, :status)

    cond do
      status in [:running, :pending, :finalizing] -> :run
      status == :failed -> :failed
      status == :completed -> :review
      true -> :plain
    end
  end

  @doc """
  Where a rail square links to: completed → `/review/:id`, unfinished →
  `/agents` (tree), everything else is not clickable (`nil`).
  """
  def square_link(task) do
    case rail_status(task) do
      :review -> ~p"/review/#{Map.get(task, :id)}"
      :run -> ~p"/agents"
      _ -> nil
    end
  end

  @doc """
  Project folder name for a square: the basename of the project path
  (the last folder), `"?"` when there is none.
  """
  def project_name(path) when is_binary(path) do
    case path |> String.replace("\\", "/") |> String.trim_trailing("/") |> Path.basename() do
      "" -> "?"
      name -> name
    end
  end

  def project_name(_), do: "?"

  @doc """
  The first few graphemes of the task's prompt (project description) for a
  square, with an ellipsis when truncated.
  """
  def prompt_preview(task, limit \\ 12) do
    prompt = task_prompt(task)

    if String.length(prompt) > limit do
      String.slice(prompt, 0, limit) <> "…"
    else
      prompt
    end
  end

  defp status_class(:run), do: "pad-sq-run"
  defp status_class(:review), do: "pad-sq-review"
  defp status_class(:failed), do: "pad-sq-failed"
  defp status_class(:plain), do: nil

  defp tip_time(task) do
    case Map.get(task, :finished_at) || Map.get(task, :started_at) do
      nil -> ""
      datetime -> relative_time(datetime)
    end
  end
end
