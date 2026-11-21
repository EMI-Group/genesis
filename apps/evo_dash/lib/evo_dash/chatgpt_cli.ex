defmodule EvoDash.ChatGPTCLI do
  @moduledoc """
  Terminal entry point for the Sign in with ChatGPT flow.
  The flow itself lives in `EvoDash.ChatGPTLogin` (shared with the dashboard), so this module only parses the command line, prints the URL and the outcome, and lists what the credential store knows.
  A browser that cannot reach this machine — Genesis on a remote host, or an attempt whose loopback listener could not be bound at all — is not a dead end: `login/3` also reads stdin, so the user can paste the address the browser was redirected to (or just the code) and the SAME attempt completes.
  """

  alias EvoGit.Auth.ChatGPT.Store
  alias EvoGit.Util.Strings
  alias EvoGit.Util.Time
  alias EvoDash.ChatGPTLogin

  @port 1455
  @signin_timeout_ms 600_000
  @notification_slack_ms 15_000
  @poll_interval_ms 100
  @poll_attempts 50

  @paste_hint "If this Genesis runs on a remote host, the browser may not reach it."
  @paste_step "Approve in the browser, then paste the address it redirected to (or just the code) here and press Enter."

  @manual_hint "No local listener is open on this machine, so only the pasted link can complete the sign-in."

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
      IO.puts(@paste_hint)
      IO.puts(@paste_step)
      # An attempt without a listener can only be finished by hand, so say so
      # instead of letting the user wait for a browser redirect that cannot land.
      if flow.mode == :manual, do: IO.puts(@manual_hint)
      IO.puts("Waiting for ChatGPT authorization.")

      reader = start_reader()

      try do
        await_result(flow.id, deadline())
      after
        stop_reader(reader)
      end
    end
  end

  # The facade notifies this process exactly once per attempt, so the bounded
  # poll below is only the fallback for a missed notification, never a wait
  # loop.
  # The wait is a loop rather than one `receive` because a pasted redirect is
  # handled here too: every paste the user hands in proves the attempt is still
  # alive, so it RESTARTS the window (a rejected paste must not be able to eat
  # the whole sign-in budget).
  defp await_result(id, deadline) do
    receive do
      {:chatgpt_login, ^id, result} ->
        render_result(result)

      {:chatgpt_login_paste, line} ->
        case handle_paste(id, line) do
          :skip -> await_result(id, deadline)
          :restart -> await_result(id, deadline())
        end
    after
      remaining(deadline) -> poll_result(id, @poll_attempts)
    end
  end

  defp deadline, do: Time.now_ms() + @signin_timeout_ms + @notification_slack_ms

  defp remaining(deadline), do: max(deadline - Time.now_ms(), 0)

  defp handle_paste(id, line) do
    if Strings.blank?(line) do
      :skip
    else
      id
      |> ChatGPTLogin.submit_callback(String.trim(line))
      |> render_paste()
    end
  end

  # A paste only ever ACKS: an accepted one has an exchange running, a rejected
  # one left the attempt pending. Both keep the CLI waiting for the terminal
  # result the facade reports.
  defp render_paste({:ok, _flow}) do
    IO.puts("Checking the pasted sign-in...")
    :restart
  end

  defp render_paste({:error, reason}) do
    IO.puts(paste_retry_hint(reason))
    :restart
  end

  defp paste_retry_hint(:invalid_callback),
    do:
      "That link does not belong to this sign-in. Paste the address this sign-in was redirected to."

  defp paste_retry_hint(:no_code),
    do: "That text carries no sign-in code. Paste the whole address you were redirected to."

  defp paste_retry_hint(:already_finished),
    do: "This sign-in is already finishing; waiting for its result."

  defp paste_retry_hint(reason),
    do: "That paste could not be used (#{inspect(reason)}). Paste the redirect address again."

  # Reading stdin runs in its OWN process so a blocking `IO.gets/2` can never
  # hold the login hostage: each line is forwarded to the awaiting CLI process,
  # and `:eof` (a piped, closed or absent stdin) just ends the reader.
  # Deliberately unlinked — an stdin error must be able to end the reader ONLY,
  # never the sign-in that is waiting for its result.
  defp start_reader do
    cli = self()
    spawn(fn -> read_lines(cli) end)
  end

  defp read_lines(cli) do
    case IO.gets(:stdio, "") do
      line when is_binary(line) ->
        send(cli, {:chatgpt_login_paste, line})
        read_lines(cli)

      _eof_or_read_error ->
        :ok
    end
  end

  # A reader still parked in `IO.gets/2` would keep the terminal for itself
  # after the command returned, so it is killed instead of left behind.
  defp stop_reader(reader) do
    if Process.alive?(reader), do: Process.exit(reader, :kill)
    :ok
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
