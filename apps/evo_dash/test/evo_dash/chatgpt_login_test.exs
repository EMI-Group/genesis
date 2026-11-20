defmodule EvoDash.ChatGPTLoginTest.StubStore do
  @moduledoc false
  # A per-account stub of `EvoGit.Auth.ChatGPT.Store`'s five-function contract
  # (`path/1`, `registration/1`, `host_id/0`, `install/2`, `status/1`).
  # The account alias keys the configuration in `:persistent_term`, so concurrent
  # async tests never share state, no credential file is read and no config
  # directory is touched.

  def path(account), do: {:ok, "/nonexistent/genesis-stub/#{account}.json"}

  def host_id, do: {:ok, "urn:uuid:stub-host"}

  def registration(account), do: config(account, :registration, {:error, :no_credentials})

  def install(account, record) do
    notify(account, {:stub_install, account, record})
    config(account, :install, {:ok, []})
  end

  def status(account) do
    status = config(account, :status, {:ok, %{account_id: account}})
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

defmodule EvoDash.ChatGPTLoginTest do
  # async: true — every test uses its OWN account alias (the stub store's key),
  # its own ephemeral loopback port and, where it matters, its own retention
  # window. The shared facade is a plain GenServer whose calls are serialized,
  # and no test mutates a BEAM-global (env var / app env / table).
  use ExUnit.Case, async: true

  alias EvoDash.ChatGPTLogin
  alias EvoDash.ChatGPTLoginTest.StubStore

  setup do
    _ = Application.ensure_all_started(:req)
    account = unique_account("flow")
    StubStore.put(account, %{test: self()})
    on_exit(fn -> StubStore.erase(account) end)
    %{account: account}
  end

  test "begin/2 binds an ephemeral loopback port and the callback installs the registration", %{
    account: account
  } do
    StubStore.put(account, %{
      test: self(),
      status:
        {:ok, %{account_id: account, models: [%{"slug" => "gpt-5", "display_name" => "GPT-5"}]}}
    })

    flow = start_flow(account, caller: self())

    assert is_binary(flow.id)
    assert is_integer(flow.port) and flow.port > 0
    assert flow.url =~ "https://auth.openai.com/api/accounts/authorize?"
    assert flow.url =~ "redirect_uri=http%3A%2F%2F127.0.0.1%3A#{flow.port}%2Fauth%2Fcallback"

    state = state_from_url(flow.url)

    {status, headers, body} =
      http_request(flow.port, "/auth/callback?state=#{URI.encode_www_form(state)}&code=abc")

    assert status == 200
    assert body =~ "<!doctype html"
    assert body =~ "close this tab"
    assert header(headers, "cache-control") == "no-store"
    assert header(headers, "referrer-policy") == "no-referrer"

    assert_receive {:stub_exchange, _attempt, %{"code" => "abc"}}, 5_000
    assert_receive {:stub_install, ^account, record}, 5_000
    assert record["code"] == "abc"

    assert_receive {:chatgpt_login, id, {:ok, %{account: ^account} = result}}, 5_000
    assert id == flow.id

    assert result.status == %{
             account_id: account,
             models: [%{"slug" => "gpt-5", "display_name" => "GPT-5"}]
           }

    assert {:ok, %{account: ^account}} = ChatGPTLogin.status(flow.id)

    wait_until(fn -> port_closed?(flow.port) end)
  end

  test "a callback with a foreign state or an unknown path is refused and the attempt stays pending",
       %{account: account} do
    flow = start_flow(account)

    assert {400, _headers, body} =
             http_request(flow.port, "/auth/callback?state=not-the-state&code=abc")

    assert body =~ "Invalid sign-in attempt"
    assert ChatGPTLogin.status(flow.id) == :pending
    refute_received {:stub_exchange, _attempt, _params}
    refute_received {:stub_install, _account, _record}

    assert {404, _headers, _body} = http_request(flow.port, "/not-a-callback")
    assert {404, _headers, _body} = http_request(flow.port, "/auth/callback", :post)
    assert ChatGPTLogin.status(flow.id) == :pending
  end

  test "a denial callback ends the attempt without calling the exchange", %{account: account} do
    flow = start_flow(account, caller: self())
    state = state_from_url(flow.url)

    {status, _headers, body} =
      http_request(
        flow.port,
        "/auth/callback?state=#{URI.encode_www_form(state)}&error=access_denied"
      )

    assert status == 400
    assert body =~ "cancelled"

    assert_receive {:chatgpt_login, id, {:error, :authorization_denied}}, 5_000
    assert id == flow.id
    assert ChatGPTLogin.status(flow.id) == {:error, :authorization_denied}
    refute_received {:stub_exchange, _attempt, _params}
  end

  test "an attempt that is never authorized times out and closes its listener", %{
    account: account
  } do
    flow = start_flow(account, caller: self(), timeout_ms: 150)

    wait_until(fn -> ChatGPTLogin.status(flow.id) == {:error, :authorization_timeout} end)
    assert_receive {:chatgpt_login, id, {:error, :authorization_timeout}}, 5_000
    assert id == flow.id
    wait_until(fn -> port_closed?(flow.port) end)
  end

  test "cancel/1 stops a live attempt and unknown ids are refused", %{account: account} do
    flow = start_flow(account, caller: self())

    assert :ok = ChatGPTLogin.cancel(flow.id)
    assert ChatGPTLogin.status(flow.id) == {:error, :cancelled}
    assert_receive {:chatgpt_login, id, {:error, :cancelled}}, 5_000
    assert id == flow.id
    wait_until(fn -> port_closed?(flow.port) end)

    assert ChatGPTLogin.cancel("no-such-flow") == {:error, :unknown_flow}
  end

  test "a second begin/2 for the same account supersedes the first", %{account: account} do
    first = start_flow(account, caller: self())
    second = start_flow(account, caller: self())

    assert first.id != second.id
    assert ChatGPTLogin.status(first.id) == {:error, :superseded}
    assert ChatGPTLogin.status(second.id) == :pending
    assert ChatGPTLogin.active_for(account) == second.id
    assert_receive {:chatgpt_login, id, {:error, :superseded}}, 5_000
    assert id == first.id
    wait_until(fn -> port_closed?(first.port) end)
  end

  test "unknown ids have no status and a retained terminal expires", %{account: account} do
    assert ChatGPTLogin.status("no-such-flow") == {:error, :unknown_flow}
    assert ChatGPTLogin.active_for("no-such-account") == nil

    flow = start_flow(account, retention_ms: 80)
    assert :ok = ChatGPTLogin.cancel(flow.id)
    assert ChatGPTLogin.status(flow.id) == {:error, :cancelled}
    wait_until(fn -> ChatGPTLogin.status(flow.id) == {:error, :unknown_flow} end)
  end

  test "a port that cannot be bound is reported and leaves the facade alive", %{account: account} do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert ChatGPTLogin.begin(account, port: port, store: StubStore) ==
             {:error, :loopback_listener_unavailable}

    assert ChatGPTLogin.status("no-such-flow") == {:error, :unknown_flow}
  end

  defp start_flow(account, opts \\ []) do
    opts =
      Keyword.merge(
        [port: 0, store: StubStore, exchange: stub_exchange(), caller: self()],
        opts
      )

    {:ok, flow} = ChatGPTLogin.begin(account, opts)
    on_exit(fn -> _ = ChatGPTLogin.cancel(flow.id) end)
    flow
  end

  defp stub_exchange do
    test = self()

    fn attempt, params ->
      _ = send(test, {:stub_exchange, attempt, params})
      {:ok, %{"access_token" => "stub-access", "code" => params["code"]}}
    end
  end

  defp unique_account(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp state_from_url(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp http_request(port, path, method \\ :get) do
    {:ok, response} =
      Req.request(
        method: method,
        url: "http://127.0.0.1:#{port}#{path}",
        retry: false,
        receive_timeout: 5_000
      )

    {response.status, response.headers, response.body}
  end

  defp header(headers, name), do: headers |> Map.get(name, []) |> List.first()

  defp port_closed?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _reason} ->
        true
    end
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until/2 did not become true within its budget")

      true ->
        receive do
        after
          10 -> do_wait_until(fun, deadline)
        end
    end
  end
end
