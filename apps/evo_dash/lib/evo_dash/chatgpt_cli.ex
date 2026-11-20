defmodule EvoDash.ChatGPTCLI do
  @moduledoc """
  Local terminal entry point for the Sign in with ChatGPT loopback flow.
  """

  alias EvoGit.Auth.ChatGPT
  alias EvoGit.Auth.ChatGPT.Store
  import Plug.Conn

  @port 1455
  @timeout :timer.minutes(10)

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "ChatGPT: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def run([flag]) when flag in ["help", "-h", "--help"], do: usage()

  def run(args) do
    with {options, positional, []} <-
           OptionParser.parse(args, strict: [account: :string, port: :integer]),
         {:ok, _} <- Application.ensure_all_started(:req) do
      account = options[:account] || Store.default_account()
      command(positional, account, options)
    else
      _ -> {:error, :invalid_command}
    end
  end

  defp command(["login"], account, options) do
    port = options[:port] || @port

    with {:ok, _} <- Store.path(account),
         {:ok, registration} <- existing_registration(account),
         {:ok, host} <- Store.host_id(),
         {:ok, url, attempt} <-
           ChatGPT.authorization(host, "http://127.0.0.1:#{port}/auth/callback", registration),
         {:ok, _} <- Application.ensure_all_started(:bandit),
         {:ok, server} <-
           Bandit.start_link(
             plug: {__MODULE__, {self(), attempt.state}},
             ip: {127, 0, 0, 1},
             port: port,
             startup_log: false
           ) do
      try do
        IO.puts("Open this URL in the browser on the computer with the loopback listener:")
        IO.puts(url)
        IO.puts("Waiting for ChatGPT authorization.")

        receive do
          {:chatgpt_callback, browser, ref, params} ->
            result = finish_login(attempt, params, account)
            send(browser, {ref, callback_result(result)})
            await_callback_response(ref)
            result
        after
          @timeout -> {:error, :authorization_timeout}
        end
      after
        Supervisor.stop(server)
      end
    else
      {:error, {:shutdown, _}} -> {:error, :loopback_listener_unavailable}
      {:error, _} = error -> error
    end
  end

  defp command(["models"], account, _) do
    with {:ok, models} <- Store.models(account), do: print_models(models)
  end

  defp command(["status"], account, _) do
    with {:ok, status} <- Store.status(account) do
      IO.puts("Connected as #{status.account_id}.")
      print_models(status.models)
    end
  end

  defp command(["logout"], account, _) do
    with :ok <- Store.logout(account), do: IO.puts("Disconnected ChatGPT account #{account}.")
  end

  defp command(["import", protected_path], account, _) do
    with {:ok, models} <- Store.import_file(account, protected_path) do
      IO.puts("Imported ChatGPT account #{account}.")
      print_models(models)
    end
  end

  defp command(_args, _account, _options), do: usage()

  defp usage do
    IO.puts("""
    Usage: genesis chatgpt <login|status|models|logout|import FILE> [--account NAME]
    Login listens on 127.0.0.1:1455. Use --port PORT to choose a different port.
    Use a different --account name to add another account or workspace.
    """)

    :ok
  end

  defp existing_registration(account) do
    case Store.registration(account) do
      {:error, reason} when reason in [:no_credentials, :invalid_credentials] -> {:ok, nil}
      result -> result
    end
  end

  defp print_models(models) do
    Enum.each(models, fn model ->
      IO.puts("#{model["slug"]}\t#{model["display_name"]}")
    end)
  end

  defp finish_login(attempt, params, account) do
    with {:ok, record} <- ChatGPT.exchange(attempt, params),
         {:ok, models} <- Store.install(account, record) do
      IO.puts("Connected ChatGPT account #{account}.")
      print_models(models)
    end
  end

  defp callback_result(:ok),
    do:
      {200,
       "ChatGPT connected to Genesis. Return to Welcome or Settings to choose your account and models."}

  defp callback_result({:error, :authorization_denied}),
    do:
      {400, "ChatGPT authorization was cancelled. Run the Genesis login command again to retry."}

  defp callback_result({:error, :plan_not_authorized}),
    do:
      {400,
       "Genesis did not receive permission to use your ChatGPT plan. Sign in again and approve plan usage."}

  defp callback_result({:error, reason}),
    do:
      {400,
       "Genesis could not finish connecting ChatGPT (#{inspect(reason)}). Return to the terminal to retry."}

  defp await_callback_response(ref) do
    receive do
      {:chatgpt_callback_sent, ^ref} -> :ok
    after
      2_000 -> :ok
    end
  end

  @doc false
  def init(options), do: options

  @doc false
  def call(
        %Plug.Conn{method: "GET", host: "127.0.0.1", request_path: "/auth/callback"} = conn,
        {caller, state}
      ) do
    conn =
      conn
      |> fetch_query_params()
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    case conn.query_params do
      %{"state" => ^state} = params ->
        ref = make_ref()
        send(caller, {:chatgpt_callback, self(), ref, params})

        receive do
          {^ref, {status, message}} ->
            resp = send_resp(conn, status, message)
            send(caller, {:chatgpt_callback_sent, ref})
            resp
        after
          90_000 ->
            send_resp(
              conn,
              504,
              "Genesis is still finishing sign-in. Check the result in your terminal."
            )
        end

      _ ->
        send_resp(conn, 400, "Invalid sign-in attempt.")
    end
  end

  def call(conn, _), do: send_resp(conn, 404, "Not found")
end
