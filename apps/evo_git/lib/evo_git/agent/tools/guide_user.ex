defmodule EvoGit.Agent.Tools.GuideUser do
  @moduledoc """
  Tool for showing transient user-facing guides in the dashboard UI.

  Broadcasts a `{:guide_updated, id, payload, node()}` message on the
  `"guides"` PubSub topic so the dashboard can render a guide card (e.g. a
  toast or inline hint) to the user. The broadcast is best-effort: the agent
  never crashes when the PubSub server is unavailable.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "guide_user",
      description:
        "Shows a short user-facing guide in the dashboard UI. " <>
          "Use this to explain to the user what you are doing, surface a question, " <>
          "or point them at a specific page or element. The guide is transient " <>
          "and dismissible by default.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "The guide text to show to the user (required)."
          },
          "page" => %{
            "type" => "string",
            "description" => "Optional URL path to point the guide at (e.g., '/settings')."
          },
          "selector" => %{
            "type" => "string",
            "description" => "Optional CSS selector to highlight/attach the guide to in the page."
          },
          "dismissible" => %{
            "type" => "boolean",
            "description" => "Whether the user can dismiss the guide. Defaults to true.",
            "default" => true
          }
        },
        "required" => ["message"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the guide_user tool.

  Broadcasts the guide payload on the `"guides"` PubSub topic and returns a
  short confirmation. Never raises on bad args (returns a descriptive error
  string) and never raises when PubSub is down (the broadcast is skipped and
  the confirmation is still returned).
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, message} <- Shared.fetch_string_arg(args, "message"),
         {:ok, dismissible} <- Shared.fetch_optional_boolean_arg(args, "dismissible", true) do
      page = Shared.get_optional_string(args, "page", nil)
      selector = Shared.get_optional_string(args, "selector", nil)

      id = "guide-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      payload = %{
        message: message,
        page: page,
        selector: selector,
        dismissible: dismissible
      }

      broadcast_guide(id, payload)

      "Guide shown to user: #{String.slice(message, 0, 80)}"
    end
  end

  # Tool-boundary rescue: the PubSub server may be down (headless remote
  # daemon without a dashboard subscriber, or a test env without the PubSub
  # app started). Showing a guide to the user is best-effort UI — the agent
  # must never crash because the UI is unavailable, so the broadcast failure
  # is swallowed and the confirmation is still returned.
  defp broadcast_guide(id, payload) do
    try do
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "guides", {:guide_updated, id, payload, node()})
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
