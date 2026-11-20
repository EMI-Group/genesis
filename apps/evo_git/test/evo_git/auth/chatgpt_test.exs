defmodule EvoGit.Auth.ChatGPTTest do
  use ExUnit.Case, async: false

  alias EvoGit.Auth.{ChatGPT, OAuthImport}

  test "the old Codex cache is no longer a source for either OpenAI profile" do
    assert OAuthImport.sources(:openai_codex, home: "/home/example") == []
    assert OAuthImport.sources(:openai, home: "/home/example") == []
  end

  test "authorization binds a fresh code challenge and a stable host" do
    assert {:ok, url, attempt} =
             ChatGPT.authorization("urn:uuid:test", "http://127.0.0.1:1455/auth/callback")

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert uri.host == "auth.openai.com"
    assert query["client_id"] == "dynamic_agent_client"
    assert query["ext_agent_host_id"] == "urn:uuid:test"
    assert query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback"
    assert query["state"] == attempt.state
    assert query["nonce"] == attempt.nonce

    assert query["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, attempt.verifier), padding: false)

    assert {:error, :invalid_callback} = ChatGPT.exchange(attempt, %{"state" => "wrong"})

    assert {:error, :authorization_denied} =
             ChatGPT.exchange(attempt, %{"state" => attempt.state, "error" => "access_denied"})
  end

  test "the ID token must be signed for the registered client and current attempt" do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    modulus = elem(private, 2)
    exponent = elem(private, 3)

    keys = [
      %{
        "kty" => "RSA",
        "kid" => "openai-test",
        "n" => encoded_integer(modulus),
        "e" => encoded_integer(exponent)
      }
    ]

    header = %{"alg" => "RS256", "kid" => "openai-test"}

    claims = %{
      "iss" => "https://auth.openai.com",
      "aud" => "oaiapp_genesis",
      "sub" => "account",
      "nonce" => "current",
      "exp" => System.system_time(:second) + 60
    }

    signed = segment(header) <> "." <> segment(claims)

    token =
      signed <>
        "." <> Base.url_encode64(:public_key.sign(signed, :sha256, private), padding: false)

    assert ChatGPT.validate_identity(token, "oaiapp_genesis", "current", keys) == {:ok, claims}

    assert {:error, :invalid_identity} =
             ChatGPT.validate_identity(token, "oaiapp_other", "current", keys)

    assert {:error, :invalid_identity} =
             ChatGPT.validate_identity(token, "oaiapp_genesis", "earlier", keys)
  end

  test "accounts have an independent selection and do not fall back to legacy auth" do
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-siwc")
    store = ChatGPT.Store
    EvoGit.TestSupport.ChatGPTFixture.seed!("work")

    File.write!(
      EvoGit.Auth.default_oauth_file(),
      Jason.encode!(%{"openai-codex" => %{"access" => "old"}})
    )

    assert {:ok, "access-work"} = store.token("work", "gpt-5.6-terra")
    assert {:error, :model_not_available_for_chatgpt_account} = store.token("work", "unlisted")
    assert {:error, :no_credentials} = store.token("default", "gpt-5.6-terra")
    assert {:error, :invalid_account_alias} = store.path("../credentials")
    assert {:ok, host_id} = store.host_id()
    assert {:ok, ^host_id} = store.host_id()
  end

  test "parallel requests share one rotating refresh and persist the replacement" do
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-siwc-refresh")
    current = Req.default_options()
    on_exit(fn -> Req.default_options(current) end)
    owner = self()

    Req.default_options(
      Keyword.put(current, :adapter, fn request ->
        assert request.url.host == "auth.openai.com"
        assert request.url.path == "/api/accounts/oauth/token"
        form = IO.iodata_to_binary(request.body)

        assert %{
                 "client_id" => "oaiapp_test-work",
                 "grant_type" => "refresh_token",
                 "refresh_token" => "refresh-work"
               } =
                 URI.decode_query(form)

        send(owner, :refreshed)

        {request,
         Req.Response.new(
           status: 200,
           body: %{
             "access_token" => "rotated-access",
             "refresh_token" => "rotated-refresh",
             "expires_in" => 3600
           }
         )}
      end)
    )

    path = EvoGit.TestSupport.ChatGPTFixture.seed!("work", %{"expires_at" => 0})

    assert 1..4
           |> Task.async_stream(fn _ -> ChatGPT.Store.token("work", "gpt-5.6-terra") end)
           |> Enum.to_list() == List.duplicate({:ok, {:ok, "rotated-access"}}, 4)

    assert_received :refreshed
    refute_received :refreshed
    assert %{"refresh_token" => "rotated-refresh"} = Jason.decode!(File.read!(path))
  end

  test "import rejects a registration already bound to another alias" do
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-siwc-alias")
    path = EvoGit.TestSupport.ChatGPTFixture.seed!("work")

    assert {:error, :chatgpt_registration_already_installed} =
             ChatGPT.Store.import_file("another", path)

    assert {:error, :no_credentials} = ChatGPT.Store.status("another")
  end

  test "a killed refresh process releases the registration lock" do
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-siwc-interrupted-refresh")
    EvoGit.TestSupport.ChatGPTFixture.seed!("work", %{"expires_at" => 0})
    current = Req.default_options()
    on_exit(fn -> Req.default_options(current) end)
    owner = self()

    Req.default_options(
      Keyword.put(current, :adapter, fn request ->
        send(owner, {:refresh_started, self()})

        receive do
          :finish_refresh ->
            {request,
             Req.Response.new(
               status: 200,
               body: %{"access_token" => "new-access", "expires_in" => 3600}
             )}
        end
      end)
    )

    token = fn -> ChatGPT.Store.token("work", "gpt-5.6-terra") end
    interrupted = Task.async(token)
    assert_receive {:refresh_started, _}, 2_000
    Task.shutdown(interrupted, :brutal_kill)

    next = Task.async(token)
    assert_receive {:refresh_started, refresh}, 2_000
    send(refresh, :finish_refresh)
    assert {:ok, "new-access"} = Task.await(next)
  end

  defp encoded_integer(n), do: Base.url_encode64(:binary.encode_unsigned(n), padding: false)
  defp segment(map), do: Base.url_encode64(Jason.encode!(map), padding: false)
end
