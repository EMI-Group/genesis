defmodule EvoDash.ChatGPTCLI do
  @moduledoc """
  Local terminal entry point for the Sign in with ChatGPT loopback flow.
  The flow itself lives in `EvoDash.ChatGPTLogin` (shared with the dashboard), so this module only parses the command line, prints the URL and the outcome, and lists what the credential store knows.
  """

  alias EvoGit.Auth.ChatGPT.Store
  alias EvoDash.ChatGPTLogin

  @port 1455
  @signin_timeout_ms 600_000
  @notification_slack_ms 15_000
  @poll_interval_ms 100
  @poll_attempts 50

  @doc "Runs the command and halts the VM with exit code 1 on error."
  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "ChatGPT: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Runs one `genesis chatgpt <login|status|models|logout|import FILE>` command and returns `:ok` or `{:error, reason}`.
  """
  def run(args), do: run(args, [])

  @doc false
  def run([flag], _opts) when flag in ["help", "-h", "--help"], do: usage()

  @doc false
  # `opts[:store]` and `opts[:exchange]` exist so a test can drive the command
  # against a stub instead of the node's real credential store; production
  # callers pass none and resolve the core modules.
  def run(args, opts) do
    with {options, positional, []} <-
           OptionParser.parse(args, strict: [account: :string, port: :integer]),
         {:ok, _} <- Application.ensure_all_started(:req) do
      store = opts[:store] || Store
      account = options[:account] || Store.default_account()
      command(positional, account, options, Keyword.put(opts, :store, store))
    else
      _ -> {:error, :invalid_command}
    end
  end

  defp command(["login"], account, options, opts) do
    login(account, options[:port] || @port, opts)
  end

  defp command(["models"], account, _options, opts) do
    with {:ok, models} <- opts[:store].models(account), do: print_models(models)
  end

  defp command(["status"], account, _options, opts) do
    with {:ok, status} <- opts[:store].status(account) do
      IO.puts("Connected as #{status.account_id}.")
      print_models(status.models)
    end
  end

  defp command(["logout"], account, _options, opts) do
    with :ok <- opts[:store].logout(account),
         do: IO.puts("Disconnected ChatGPT account #{account}.")
  end

  defp command(["import", protected_path], account, _options, opts) do
    with {:ok, models} <- opts[:store].import_file(account, protected_path) do
      IO.puts("Imported ChatGPT account #{account}.")
      print_models(models)
    end
  end

  defp command(_args, _account, _options, _opts), do: usage()

  # The listener binds AFTER the flow starts, so the printed URL always carries
  # the port that is really open (the default 1455 or an explicit `--port`).
  defp login(account, port, opts) do
    flow_opts = [port: port, caller: self()] ++ Keyword.take(opts, [:store, :exchange])

    with {:ok, flow} <- ChatGPTLogin.begin(account, flow_opts) do
      IO.puts("Open this URL in the browser on the computer with the loopback listener:")
      IO.puts(flow.url)
      IO.puts("Waiting for ChatGPT authorization.")
      await_result(flow.id)
    end
  end

  # The facade notifies this process exactly once per attempt; the bounded poll
  # is only the fallback for a missed notification, never a wait loop.
  defp await_result(id) do
    receive do
      {:chatgpt_login, ^id, result} -> render_result(result)
    after
      @signin_timeout_ms + @notification_slack_ms -> poll_result(id, @poll_attempts)
    end
  end

  defp poll_result(_id, 0), do: {:error, :authorization_timeout}

  defp poll_result(id, attempts) do
    case ChatGPTLogin.status(id) do
      :pending ->
        receive do
          {:chatgpt_login, ^id, result} -> render_result(result)
        after
          @poll_interval_ms -> poll_result(id, attempts - 1)
        end

      result ->
        render_result(result)
    end
  end

  defp render_result({:ok, %{account: account} = result}) do
    IO.puts("Connected ChatGPT account #{account}.")
    result |> Map.get(:status) |> print_models()
    :ok
  end

  defp render_result({:error, reason}), do: {:error, reason}

  # A running attempt is never a command outcome.
  defp render_result(:pending), do: {:error, :authorization_timeout}

  defp usage do
    IO.puts("""
    Usage: genesis chatgpt <login|status|models|logout|import FILE> [--account NAME]
    Login listens on 127.0.0.1:1455. Use --port PORT to choose a different port.
    Use a different --account name to add another account or workspace.
    """)

    :ok
  end

  defp print_models(%{models: models}), do: print_models(models)

  defp print_models(models) when is_list(models) do
    Enum.each(models, fn
      %{"slug" => slug, "display_name" => name} -> IO.puts("#{slug}\t#{name}")
      _other -> :ok
    end)
  end

  defp print_models(_models), do: :ok
end
