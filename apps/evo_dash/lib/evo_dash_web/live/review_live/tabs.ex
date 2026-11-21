defmodule EvoDashWeb.ReviewLive.Tabs do
  @moduledoc """
  Tab, archive and page-chrome events of `EvoDashWeb.ReviewLive`.

  Every function here is an event handler in the shape the page's dispatcher
  expects — `(socket, params)` in, `{:noreply, socket}` out — so the page keeps
  only its LiveView contract while the tab state machine lives here.

  `switch_tab/2` is TABLE-DRIVEN over `@tab_params`; the Archive tab is the one
  special case (it is only reachable for a task that opted into archiving and
  it lazily loads its first page), and an unknown/absent tab param stays a
  no-op. Client input is never converted to an atom.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.ReviewLive.ArchiveLoad

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  # Tab param → the page's tab atom. Anything absent from this map is either the
  # Archive tab (gated below) or an unknown tab (no-op).
  @tab_params %{
    "conversation" => :conversation,
    "files_changed" => :files_changed,
    "objective" => :objective,
    "commits" => :commits
  }

  def switch_tab(socket, params) do
    case Map.fetch(@tab_params, Map.get(params, "tab")) do
      {:ok, tab} ->
        {:noreply, assign(socket, :review_tab, tab)}

      :error ->
        {:noreply, maybe_open_archive(socket, Map.get(params, "tab"))}
    end
  end

  # The Archive tab is only reachable for a task that opted into archiving
  # (`@archive_opt_in?`, from the task opts): for any other task the click is a
  # complete no-op — no tab switch, no fetch.
  defp maybe_open_archive(socket, "archive") do
    if Map.get(socket.assigns, :archive_opt_in?, false) do
      socket
      |> assign(:review_tab, :archive)
      |> ArchiveLoad.ensure_loaded()
    else
      socket
    end
  end

  defp maybe_open_archive(socket, _tab), do: socket

  # Retry button inside the Archive tab's error state — re-arms the archive
  # state machine and starts one fresh first page (never a poll).
  def retry_archive(socket, _params) do
    {:noreply, ArchiveLoad.retry(socket)}
  end

  # "Load more" (and its inline Retry after a failed append): appends the next
  # page. The support module owns every guard (already loaded, append in
  # flight, nothing left to load).
  def load_more_archive(socket, _params) do
    {:noreply, ArchiveLoad.load_more(socket)}
  end

  # Per-agent lazy result: fetches ONE agent's heavy "result" on demand (also
  # the Retry path for a failed fetch). Never triggered by a render.
  # LiveView passes the `phx-value-*` attribute SUFFIX verbatim as the params
  # key, so the attribute (`phx-value-agent_id`) and this match must both be
  # snake_case — a kebab attribute would arrive as "agent-id" and never match.
  def load_archive_agent_result(socket, %{"agent_id" => agent_id}) do
    {:noreply, ArchiveLoad.load_agent_result(socket, agent_id)}
  end

  def load_archive_agent_result(socket, _params), do: {:noreply, socket}

  def toggle_summary_view(socket, %{"mode" => mode}) do
    {:noreply, assign(socket, :summary_raw, mode == "raw")}
  end

  def toggle_objective_view(socket, %{"mode" => mode}) do
    {:noreply, assign(socket, :objective_raw, mode == "raw")}
  end

  def copied(socket, _params) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  def retry_remote_connection(socket, _params) do
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)
    {:noreply, socket}
  end

  def switch_to_local(socket, _params) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end
end
