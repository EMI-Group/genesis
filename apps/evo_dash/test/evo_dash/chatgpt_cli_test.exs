defmodule EvoDash.ChatGPTCLITest.StubStore do
  @moduledoc false
  # A per-account stub of the pieces of `EvoGit.Auth.ChatGPT.Store` the CLI uses
  # (the flow's five-function contract plus `status/1` for the read-only
  # commands). The account alias keys `:persistent_term`, so concurrent async
  # tests never share state, no credential file is read and no config directory
  # is touched.

  def path(account), do: {:ok, "/nonexistent/genesis-stub/#{account}.json"}

  def host_id, do: {:ok, "urn:uuid:stub-host"}

  def registration(account), do: config(account, :registration, {:error, :no_credentials})

  def install(account, record) do
    notify(account, {:stub_install, account, record})
    config(account, :install, {:ok, []})
  end

  def status(account) do
    status = config(account, :status, {:ok, %{account_id: account, models: []}})
    notify(account, {:stub_status, account, status})
    status
  end

  def put(account, config), do: :persistent_term.put({__MODULE__, account}, config)

  def erase(account), do: :persistent_term.erase({__MODULE__, account})

  defp config(account, key, default \\ nil) do
    case :persistent_term.get({__MODULE__, account}, :missing) do
      :missing -> default
      config -> Map.get(config, key, default)
    end
  end

  defp notify(account, message) do
    case config(account, :test) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end

defmodule EvoDash.ChatGPTCLITest do
  # async: true — every test uses its OWN account alias (the stub store's key)
  # and its own loopback port, passes its stub through `run/2`'s call-time
  # options, and mutates no BEAM-global (no env var, no app env, no table).
  use ExUnit.Case, async: true

  alias EvoDash.ChatGPTCLI
  alias EvoDash.ChatGPTCLITest.StubStore

  # The CLI drives a supervised loopback flow from its OWN process, so its
  # 5 s / 10 s literals are latency assumptions, not correctness bounds: the
  # shared host swings 10-30x under load (see test/CONTEXT.md).
  @async_wait_budget_ms 30_000

  setup do
    _ = Application.ensure_all_started(:req)
    account = unique_account("work")
    StubStore.put(account, %{test: self()})
    on_exit(fn -> StubStore.erase(account) end)
    %{account: account}
  end

  test "login drives the shared flow end to end and prints the URL and the outcome", %{
    account: account
  } do
    port = free_port()

    StubStore.put(account, %{
      test: self(),
      status:
        {:ok, %{account_id: account, models: [%{"slug" => "gpt-5", "display_name" => "GPT-5"}]}}
    })

    test = self()

    exchange = fn attempt, params ->
      send(test, {:cli_stub_exchange, attempt, params})
      {:ok, %{"access_token" => "stub-access", "code" => params["code"]}}
    end

    {:ok, device} = StringIO.open("")

    start_cli(device, ["login", "--account", account, "--port", Integer.to_string(port)],
      store: StubStore,
      exchange: exchange
    )

    # The printed URL is the only place the browser-facing attempt identity is
    # published, so the test waits for it before it can call back.
    url = wait_for(fn -> url_in(output(device)) end)
    assert url =~ "https://auth.openai.com/api/accounts/authorize?"
    assert url =~ "redirect_uri=http%3A%2F%2F127.0.0.1%3A#{port}%2Fauth%2Fcallback"

    state = state_from_url(url)

    {status, _headers, body} =
      http_request(port, "/auth/callback?state=#{URI.encode_www_form(state)}&code=abc")

    assert status == 200
    assert body =~ "ChatGPT connected"

    assert_receive {:stub_install, ^account, record}, @async_wait_budget_ms
    assert record["code"] == "abc"

    assert_receive {:cli_result, :ok}, @async_wait_budget_ms

    printed = output(device)
    assert printed =~ "Waiting for ChatGPT authorization."
    assert printed =~ "Connected ChatGPT account #{account}."
    assert printed =~ "gpt-5\tGPT-5"
  end

  test "a pasted code completes the login without the browser callback", %{account: account} do
    port = free_port()

    StubStore.put(account, %{
      test: self(),
      status:
        {:ok, %{account_id: account, models: [%{"slug" => "gpt-5", "display_name" => "GPT-5"}]}}
    })

    test = self()

    exchange = fn attempt, params ->
      send(test, {:cli_stub_exchange, attempt, params})
      {:ok, %{"access_token" => "stub-access", "code" => params["code"]}}
    end

    # The stdin reader calls `IO.gets(:stdio, "")`, which reads from the group
    # leader, so the device's own input IS the user pasting the line and
    # pressing Enter.
    {:ok, device} = StringIO.open("pasted-code-123\n")

    start_cli(device, ["login", "--account", account, "--port", Integer.to_string(port)],
      store: StubStore,
      exchange: exchange
    )

    assert_receive {:cli_stub_exchange, attempt, params}, @async_wait_budget_ms
    assert params["code"] == "pasted-code-123"
    # The paste completed the SAME attempt the printed URL was minted for.
    assert attempt.state == state_from_url(wait_for(fn -> url_in(output(device)) end))

    assert_receive {:stub_install, ^account, record}, @async_wait_budget_ms
    assert record["code"] == "pasted-code-123"

    assert_receive {:cli_result, :ok}, @async_wait_budget_ms

    printed = output(device)
    assert printed =~ "paste the address it redirected to"
    refute printed =~ "No local listener is open on this machine"
    assert printed =~ "Checking the pasted sign-in..."
    assert printed =~ "Connected ChatGPT account #{account}."
    assert printed =~ "gpt-5\tGPT-5"
  end

  test "a rejected paste keeps the attempt open and a later paste completes it", %{
    account: account
  } do
    port = free_port()

    StubStore.put(account, %{
      test: self(),
      status: {:ok, %{account_id: account, models: []}}
    })

    test = self()

    exchange = fn _attempt, params ->
      send(test, {:cli_stub_exchange, params})
      {:ok, %{"access_token" => "stub-access"}}
    end

    # First a redirect URL carrying a FOREIGN state, then prose that holds no
    # code at all, then the real retry: only the third line can complete the
    # sign-in, so the first two must leave the attempt pending.
    pasted = """
    http://127.0.0.1:1455/auth/callback?state=another-sign-in&code=stale-code
    this is not a redirect or a code
    retried-code-456
    """

    {:ok, device} = StringIO.open(pasted)

    start_cli(device, ["login", "--account", account, "--port", Integer.to_string(port)],
      store: StubStore,
      exchange: exchange
    )

    assert_receive {:cli_stub_exchange, %{"code" => "retried-code-456"}}, @async_wait_budget_ms
    refute_receive {:cli_stub_exchange, _params}, 200

    assert_receive {:stub_install, ^account, record}, @async_wait_budget_ms
    assert record["access_token"] == "stub-access"

    assert_receive {:cli_result, :ok}, @async_wait_budget_ms

    printed = output(device)
    assert printed =~ "That link does not belong to this sign-in."
    assert printed =~ "That text carries no sign-in code."
    assert printed =~ "Connected ChatGPT account #{account}."
  end

  test "login without any stdin input still completes through the loopback callback", %{
    account: account
  } do
    port = free_port()

    StubStore.put(account, %{test: self(), status: {:ok, %{account_id: account, models: []}}})

    test = self()

    exchange = fn _attempt, params ->
      send(test, {:cli_stub_exchange, params})
      {:ok, %{"access_token" => "stub-access"}}
    end

    # A non-interactive run: the reader sees `:eof` at once, exits, and the
    # command must still wait for the browser instead of crashing or spinning.
    {:ok, device} = StringIO.open("")

    start_cli(device, ["login", "--account", account, "--port", Integer.to_string(port)],
      store: StubStore,
      exchange: exchange
    )

    url = wait_for(fn -> url_in(output(device)) end)
    state = state_from_url(url)

    {status, _headers, _body} =
      http_request(port, "/auth/callback?state=#{URI.encode_www_form(state)}&code=abc")

    assert status == 200

    assert_receive {:stub_install, ^account, _record}, @async_wait_budget_ms
    assert_receive {:cli_result, :ok}, @async_wait_budget_ms

    assert output(device) =~ "Connected ChatGPT account #{account}."
  end

  test "an attempt that cannot bind a listener prints the manual hint and completes from a paste",
       %{account: account} do
    {port, occupied} = occupied_port()
    on_exit(fn -> :ok = :gen_tcp.close(occupied) end)

    StubStore.put(account, %{test: self(), status: {:ok, %{account_id: account, models: []}}})

    test = self()

    exchange = fn _attempt, params ->
      send(test, {:cli_stub_exchange, params})
      {:ok, %{"access_token" => "stub-access"}}
    end

    {:ok, device} = StringIO.open("manual-code-789\n")

    start_cli(device, ["login", "--account", account, "--port", Integer.to_string(port)],
      store: StubStore,
      exchange: exchange
    )

    assert_receive {:cli_stub_exchange, %{"code" => "manual-code-789"}}, @async_wait_budget_ms
    assert_receive {:cli_result, :ok}, @async_wait_budget_ms

    printed = output(device)
    assert printed =~ "No local listener is open on this machine"
    assert printed =~ "Connected ChatGPT account #{account}."
  end

  test "status reads through the injected store", %{account: account} do
    StubStore.put(account, %{
      test: self(),
      status:
        {:ok,
         %{account_id: "work-label", models: [%{"slug" => "gpt-5", "display_name" => "GPT-5"}]}}
    })

    printed =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = ChatGPTCLI.run(["status", "--account", account], store: StubStore)
      end)

    assert printed =~ "Connected as work-label."
    assert printed =~ "gpt-5\tGPT-5"
    assert_receive {:stub_status, ^account, {:ok, %{account_id: "work-label"}}}
  end

  test "a store failure is propagated, never swallowed", %{account: account} do
    StubStore.put(account, %{test: self(), status: {:error, :no_credentials}})

    assert ChatGPTCLI.run(["status", "--account", account], store: StubStore) ==
             {:error, :no_credentials}
  end

  test "help, no arguments and an unknown command all print the usage text" do
    for args <- [["help"], ["-h"], ["--help"], [], ["bogus"]] do
      printed = ExUnit.CaptureIO.capture_io(fn -> assert :ok = ChatGPTCLI.run(args) end)
      assert printed =~ "Usage: genesis chatgpt <login|status|models|logout|import FILE>"
    end
  end

  defp start_cli(device, args, opts) do
    test = self()

    pid =
      spawn_link(fn ->
        Process.group_leader(self(), device)
        result = ChatGPTCLI.run(args, opts)
        send(test, {:cli_result, result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp output(device), do: device |> StringIO.contents() |> elem(1)

  defp url_in(printed) do
    case Regex.run(~r{https://auth\.openai\.com/api/accounts/authorize\?\S+}, printed) do
      [url] -> url
      nil -> nil
    end
  end

  defp state_from_url(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # A port that is already taken: the flow cannot bind its loopback listener
  # there, so it degrades to `mode: :manual` — the remote-host shape.
  defp occupied_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    {port, socket}
  end

  defp http_request(port, path) do
    {:ok, response} =
      Req.request(
        method: :get,
        url: "http://127.0.0.1:#{port}#{path}",
        retry: false,
        receive_timeout: 5_000
      )

    {response.status, response.headers, response.body}
  end

  defp unique_account(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp wait_for(fun, timeout \\ @async_wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _unset ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("wait_for/2 did not produce a value within its budget")
        else
          receive do
          after
            10 -> do_wait_for(fun, deadline)
          end
        end
    end
  end
end
