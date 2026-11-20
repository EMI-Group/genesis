defmodule EvoDash.ChatGPTLogin.Callback do
  @moduledoc """
  The loopback HTTP endpoint of ONE ChatGPT sign-in flow: `GET /auth/callback` and nothing else.
  The plug runs inside the flow's own 127.0.0.1 listener (started by `EvoDash.ChatGPTLogin.Flow`), forwards the query parameters to that flow and renders a SELF-CONTAINED HTML page — no external assets, no Phoenix template, and never a token or raw parameter in the response.
  Every response is `cache-control: no-store` + `referrer-policy: no-referrer`, because an OAuth callback URL must not be cached or leak through a `Referer`.
  """

  @behaviour Plug

  import Plug.Conn

  # An exchange may legitimately take a while (a cold TLS handshake plus the
  # token endpoint), so the request outlives the flow's own soft budgets but is
  # still bounded: the browser never hangs on a dead flow.
  @flow_call_timeout 150_000

  @loopback_hosts ["127.0.0.1", "localhost"]

  @impl true
  def init(flow) when is_pid(flow), do: flow

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: "/auth/callback"} = conn, flow) do
    conn = fetch_query_params(conn)

    if conn.host in @loopback_hosts do
      handle_callback(conn, flow)
    else
      respond(conn, 404, not_found_page())
    end
  end

  def call(conn, _flow), do: respond(conn, 404, not_found_page())

  defp handle_callback(conn, flow) do
    case ask_flow(flow, conn.query_params) do
      {:terminal, {status, body}} ->
        conn = respond(conn, status, body)
        # Only a TERMINAL answer ends the flow, and only AFTER the response is
        # written: stopping the listener mid-response would truncate the page
        # the user is looking at.
        GenServer.cast(flow, :responded)
        conn

      {:keep_open, {status, body}} ->
        # A rejected callback (wrong `state`, unusable parameters) leaves the
        # sign-in attempt PENDING, so a retry in the same browser tab still works.
        respond(conn, status, body)

      {:error, :unavailable} ->
        respond(conn, 503, unavailable_page())
    end
  end

  # A callback can only arrive while the flow is alive, so losing the call means
  # the attempt already ended (finished, cancelled, timed out or superseded) and
  # the only honest answer is "this sign-in is no longer pending".
  defp ask_flow(flow, params) do
    GenServer.call(flow, {:callback, params}, @flow_call_timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  @doc "The page shown after a successful exchange and installation."
  def success_page do
    page(
      "ChatGPT connected",
      "ChatGPT connected",
      "You can close this tab and return to Genesis."
    )
  end

  @doc "The page shown for a terminal failure, with a human-readable reason and no parameters."
  def failure_page(reason) do
    page("ChatGPT sign-in failed", "ChatGPT sign-in failed", reason_text(reason))
  end

  @doc "The page shown when the callback's `state` is absent or does not match this attempt."
  def invalid_attempt_page do
    page(
      "Invalid sign-in attempt",
      "Invalid sign-in attempt",
      "This callback does not belong to the sign-in Genesis started. Return to Genesis and start sign-in again."
    )
  end

  @doc "The page shown when a second callback arrives after this attempt already finished."
  def already_finished_page do
    page(
      "Sign-in already finished",
      "Sign-in already finished",
      "This sign-in attempt has already been completed. Return to Genesis."
    )
  end

  @doc "The page shown when the flow is gone (cancelled, superseded, expired or crashed)."
  def unavailable_page do
    page(
      "Sign-in is no longer pending",
      "Sign-in is no longer pending",
      "Genesis is not waiting for this sign-in any more. Start sign-in again from Genesis."
    )
  end

  @doc "The page shown for every path or method this listener does not serve."
  def not_found_page do
    page("Not found", "Not found", "This address only serves the ChatGPT sign-in callback.")
  end

  defp reason_text(:authorization_denied) do
    "ChatGPT sign-in was cancelled. Start sign-in again from Genesis to retry."
  end

  defp reason_text(:plan_not_authorized) do
    "Genesis did not receive permission to use your ChatGPT plan. Sign in again and approve plan usage."
  end

  defp reason_text(:chatgpt_account_alias_in_use) do
    "This ChatGPT account is already connected under a different account name. Choose another name in Genesis."
  end

  defp reason_text(:authorization_timeout) do
    "The sign-in window expired. Start sign-in again from Genesis."
  end

  defp reason_text(:cancelled) do
    "The sign-in was cancelled. Start sign-in again from Genesis."
  end

  defp reason_text(reason) do
    "Genesis could not finish connecting ChatGPT (#{describe(reason)}). Return to Genesis to retry."
  end

  # A reason is an atom or a small tuple from the core exchange/store, so its
  # inspection is safe to show; it is still truncated so a hostile or verbose
  # term can never turn into a large page.
  defp describe(reason) do
    reason
    |> inspect(limit: 4, printable_limit: 80)
    |> String.slice(0, 120)
  end

  defp page(title, heading, message) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{Plug.HTML.html_escape(title)}</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
            background: #0b0b0f;
            color: #f4f4f5;
          }
          main { max-width: 32rem; padding: 2rem; text-align: center; }
          h1 { font-size: 1.25rem; font-weight: 600; margin: 0 0 0.75rem; }
          p { margin: 0; line-height: 1.6; color: #c4c4cc; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{Plug.HTML.html_escape(heading)}</h1>
          <p>#{Plug.HTML.html_escape(message)}</p>
        </main>
      </body>
    </html>
    """
  end
end
