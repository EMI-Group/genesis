defmodule EvoDashWeb.TaskCardComponents.ResultRender do
  @moduledoc """
  Task-result rendering for the task card: `render_result/1,2` (the capped
  in-card body), `render_result_full/1` (the uncapped Full Result modal body),
  `result_copy_text/1` (the copyable plain text) and the shared branch-badge
  truncation class.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.TaskCardComponents
  alias EvoDashWeb.TaskCardComponents.Repos

  # ---------------------------------------------------------------------------
  # Public helpers — render_result/2
  # ---------------------------------------------------------------------------

  def render_result(data) do
    render_result(data, [])
  end

  def render_result({:ok, %{result: result} = data}, opts) when is_binary(result) do
    render_result(data, opts)
  end

  def render_result({:error, reason}, opts) do
    # `truncate: true` = expanded-card body (capped preview of the inspected
    # reason); `truncate: false` = zoomed view (the modal's own container
    # scrolls, full text).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: TaskCardComponents.text_preview(inspect(reason, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Error")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason.text %></pre>
      <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@reason} />
    </div>
    """
  end

  def render_result({:exit, reason}, opts) do
    # `truncate: true` = expanded-card body (capped preview of the inspected
    # reason); `truncate: false` = zoomed view (the modal's own container
    # scrolls, full text).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: TaskCardComponents.text_preview(inspect(reason, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Crashed")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason.text %></pre>
      <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@reason} />
    </div>
    """
  end

  def render_result(%{result: result, no_changes: true} = data, opts) when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: TaskCardComponents.text_preview(result, truncate),
      repos: Repos.result_repos(data),
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if @truncate do %>
        <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
          <div class="text-sm whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
            {@result.text}
          </div>
          <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@result} />
        </div>
        <div class="bg-warning/10 border border-warning/20 p-3 rounded-lg">
          <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
          </h5>
          <p class="text-sm text-warning">
            <%!-- zh_CN: agent → "智能体" --%>{gettext(
              "The agent completed without making any changes to the codebase."
            )}
          </p>
        </div>
      <% else %>
        <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
          <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
          </h5>
          <p class="text-sm text-warning">
            <%!-- zh_CN: agent → "智能体" --%>{gettext(
              "The agent completed without making any changes to the codebase."
            )}
          </p>
        </div>
        <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" />
            <%!-- zh_CN: Agent → "智能体" --%>{gettext("Agent Message")}
          </h5>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result.text %></pre>
        </div>
      <% end %>
      <%= if @repos do %>
        <div>
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-server-stack" class="size-3" />
            <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
              "Repositories"
            )}
          </h5>
          <EvoDashWeb.TaskCardComponents.result_repos_badges
            repos={@repos}
            size_class={if @truncate, do: "text-xs", else: "text-sm"}
          />
        </div>
      <% end %>
    </div>
    """
  end

  def render_result(%{result: result, commit_sha: commit_sha} = data, opts)
      when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: TaskCardComponents.text_preview(result, truncate),
      commit_sha: commit_sha,
      tag: Map.get(data, :tag),
      branch_name: Map.get(data, :branch_name),
      pr_url: Map.get(data, :pr_url),
      repos: Repos.result_repos(data),
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if !@truncate do %>
        <div class="flex flex-wrap gap-2 mb-4">
          <%= if @branch_name do %>
            <span class={[branch_badge_class(), "text-sm"]}>
              <.icon name="hero-code-bracket-square" class="size-4 mr-1 shrink-0" />
              <span class="truncate min-w-0">{@branch_name}</span>
            </span>
          <% end %>
          <%= if @commit_sha do %>
            <span class="badge badge-ghost font-mono text-sm">
              <.icon name="hero-code-bracket" class="size-4 mr-1" />
              {String.slice(@commit_sha, 0..7)}
            </span>
          <% end %>
          <%= if @tag do %>
            <span class="badge badge-ghost font-mono text-sm">
              <.icon name="hero-tag" class="size-4 mr-1" />
              {@tag}
            </span>
          <% end %>
          <%= if @pr_url do %>
            <a
              href={@pr_url}
              target="_blank"
              class="badge badge-success font-mono text-sm hover:opacity-80 transition-opacity"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-1" />
              {gettext("View PR")}
            </a>
          <% end %>
        </div>
        <%= if @repos do %>
          <div class="mb-4">
            <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
              <.icon name="hero-server-stack" class="size-3" />
              <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
                "Repositories"
              )}
            </h5>
            <EvoDashWeb.TaskCardComponents.result_repos_badges repos={@repos} size_class="text-sm" />
          </div>
        <% end %>
      <% end %>
      <div class={
        if @truncate,
          do: "bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner",
          else: "bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"
      }>
        <%= if !@truncate do %>
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Agent Message")}
          </h5>
        <% end %>
        <%= if @truncate do %>
          <div class="text-sm whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
            {@result.text}
          </div>
          <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@result} />
        <% else %>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result.text %></pre>
        <% end %>
      </div>
      <%= if @truncate do %>
        <div class="flex flex-wrap gap-2 text-xs">
          <%= if @commit_sha do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-code-bracket" class="size-3 mr-1" />
              {String.slice(@commit_sha, 0..7)}
            </span>
          <% end %>
          <%= if @tag do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-tag" class="size-3 mr-1" />
              {@tag}
            </span>
          <% end %>
          <%= if @branch_name do %>
            <span class={branch_badge_class()}>
              <.icon name="hero-code-bracket-square" class="size-3 mr-1 shrink-0" />
              <span class="truncate min-w-0">{@branch_name}</span>
            </span>
          <% end %>
          <%= if @pr_url do %>
            <a
              href={@pr_url}
              target="_blank"
              class="badge badge-success font-mono hover:opacity-80 transition-opacity"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3 mr-1" />
              {gettext("View PR")}
            </a>
          <% end %>
        </div>
        <%= if @repos do %>
          <div>
            <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
              <.icon name="hero-server-stack" class="size-3" />
              <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
                "Repositories"
              )}
            </h5>
            <EvoDashWeb.TaskCardComponents.result_repos_badges repos={@repos} />
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def render_result(%{result: result}, opts) do
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-base-100 p-3 rounded-lg border border-base-200",
        else: "bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      result:
        TaskCardComponents.text_preview(inspect(result, pretty: true, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result.text %></pre>
    <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@result} />
    """
  end

  def render_result(result, opts) do
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-base-100 p-3 rounded-lg border border-base-200 overflow-x-auto shadow-inner",
        else: "bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      result:
        TaskCardComponents.text_preview(inspect(result, pretty: true, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result.text %></pre>
    <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@result} />
    """
  end

  # ---------------------------------------------------------------------------
  # Public API — render_result_full/1 renders full task result without truncation
  # ---------------------------------------------------------------------------

  # `truncate: false` = the Full Result MODAL body: THE complete, uncapped text
  # (no byte cap, no limit note) — reached only by an explicit user action
  # (`view_full_result`) and scrolled by the modal's own container.
  def render_result_full(assigns) do
    render_result(assigns, truncate: false)
  end

  @doc """
  Returns the copyable plain-text representation of a task result value.

  Used by both the unzoomed "Agent Message" card copy button and the zoomed
  Full Result modal copy button (`tasks_live.ex`). Success/no-changes results
  copy the raw agent message; error/crash results copy the inspected reason
  (unlimited); anything else falls back to a pretty-inspected representation.

  Deliberately returns the COMPLETE text — this function itself never truncates
  so the Full Result modal (`tasks_live.ex`) can copy the whole thing. The
  in-card copy button deliberately does NOT use the raw value: it bounds its
  HTML-materialized `data-content` through `copy_payload/1` (1 MiB) and renders
  only a preview in the body (`render_result/2` with `truncate: true`).
  """
  def result_copy_text({:ok, %{result: result}}) when is_binary(result), do: result
  def result_copy_text({:error, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text({:exit, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text(%{result: result}) when is_binary(result), do: result
  def result_copy_text(result), do: inspect(result, pretty: true, limit: :infinity)

  # Shared truncation classes for branch-name badges (all 3 render sites).
  # daisyUI `.badge` is `display: inline-flex; width: fit-content` with no
  # wrapping, so a long unbreakable branch name (`genesis/agent_<id>`) would
  # force the badge wider than the card. `min-w-0` lets the badge (a flex
  # item) shrink below its content width, the responsive `max-w-*` caps it at
  # narrow widths only (`md:max-w-none` = full name on desktop), and the text
  # itself is wrapped in a `truncate` span — text-overflow ellipsis does NOT
  # apply on the flex badge container itself, only on a block container.
  def branch_badge_class do
    "badge badge-primary font-mono min-w-0 max-w-[10rem] sm:max-w-[14rem] md:max-w-none"
  end
end
