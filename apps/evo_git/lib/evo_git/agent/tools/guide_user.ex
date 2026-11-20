defmodule EvoGit.Agent.Tools.GuideUser do
  @moduledoc """
  Command handler for the `GuideUser.guide_user` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Shows transient
  user-facing guides in the dashboard UI.

  NOT an LLM tool: it exposes no `schema/0` and is never listed in an agent's
  `available_tools/0` — the model reaches it only through the `run_command`
  tool's literal command registry.

  ## Return contract

  A SUCCESS returns the confirmation string
  `"Guide shown to user: <first 80 characters of the message>"` (a plain
  `String.t()`); a bad or missing argument (`message`, `dismissible`) returns
  `{:error, String.t()}` through the `with` chain, with no `else` clause — the
  exact shape `EvoGit.CommandShell` propagates as a shell error.
  The return values are never truncated beyond that 80-character confirmation.

  ## Delivery

  Broadcasts a `{:guide_updated, id, payload, node()}` message on the
  `"guides"` PubSub topic so the dashboard can render a guide card (e.g. a
  toast or inline hint) to the user. The broadcast is best-effort: PubSub being
  down (a headless remote daemon without a dashboard subscriber, or an
  environment without the PubSub app) never raises, and the confirmation is
  returned anyway.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the guide_user command handler.

  Broadcasts the guide payload on the `"guides"` PubSub topic and returns the
  confirmation string described in the moduledoc. Never raises: a bad/missing
  argument returns `{:error, message}` (not a string), and a PubSub outage
  skips the broadcast while still returning the confirmation.
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

  # Delivery guard: the PubSub server may be down (headless remote daemon
  # without a dashboard subscriber, or a test env without the PubSub app
  # started). Showing a guide to the user is best-effort UI — the agent must
  # never crash because the UI is unavailable — so this is the one place a
  # failure is deliberately swallowed, and the SUCCESS value (`:ok`) rather than
  # an error is the point: `EvoGit.Agent.Tools.Boundary`'s error rendering does
  # not apply.
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
