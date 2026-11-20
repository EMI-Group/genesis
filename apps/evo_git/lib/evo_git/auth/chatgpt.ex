defmodule EvoGit.Auth.ChatGPT do
  @moduledoc """
  OpenAI's Sign in with ChatGPT protocol for a public, user-defined client.
  The caller owns the loopback listener and the credential store.
  """

  @issuer "https://auth.openai.com"
  @resource "https://api.openai.com/v1"
  @token_path "/api/accounts/oauth/token"
  @permission "chatgpt.tokens.use.direct"
  @scopes ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct)
  @dynamic_client "dynamic_agent_client"

  def resource, do: @resource

  @doc "Shared transport options for SIWC authorization and inference."
  def http_options do
    case System.get_env("GENESIS_SIWC_HTTPS_PROXY") do
      nil ->
        []

      url ->
        case URI.new(url) do
          {:ok, %URI{scheme: "http", host: host, port: port, userinfo: nil}}
          when is_binary(host) and host != "" and port in 1..65_535 ->
            [connect_options: [proxy: {:http, host, port, []}]]

          _ ->
            []
        end
    end
  end

  def authorization(host_id, redirect_uri, registration \\ nil) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: "127.0.0.1", path: "/auth/callback", port: port}
      when is_integer(port) and port in 1..65_535 ->
        attempt = %{
          state: random(),
          nonce: random(),
          verifier: random(),
          redirect_uri: redirect_uri,
          registration: registration
        }

        registration_params =
          case registration do
            %{"client_id" => client_id} -> [client_id: client_id]
            nil -> [client_id: @dynamic_client, agent_name_hint: "Genesis"]
          end

        query =
          URI.encode_query(
            registration_params ++
              [
                ext_agent_host_id: host_id,
                response_type: "code",
                redirect_uri: redirect_uri,
                scope: Enum.join(@scopes, " "),
                resource: @resource,
                state: attempt.state,
                nonce: attempt.nonce,
                code_challenge_method: "S256",
                code_challenge:
                  Base.url_encode64(:crypto.hash(:sha256, attempt.verifier), padding: false)
              ]
          )

        {:ok, @issuer <> "/api/accounts/authorize?" <> query, attempt}

      _ ->
        {:error, :invalid_redirect}
    end
  end

  def exchange(attempt, params) do
    with :ok <- verify_state(attempt.state, params),
         {:ok, code} <- authorization_code(params),
         {:ok, client_id} <- issued_client(attempt.registration, params["client_id"]),
         {:ok, body} <-
           request(:post, @issuer <> @token_path,
             form: [
               grant_type: "authorization_code",
               client_id: client_id,
               code: code,
               code_verifier: attempt.verifier,
               redirect_uri: attempt.redirect_uri,
               resource: @resource
             ]
           ),
         {:ok, tokens} <- tokens(body),
         {:ok, claims} <- verify_identity(body["id_token"], client_id, attempt.nonce),
         :ok <- same_subject(attempt.registration, claims["sub"]) do
      {:ok,
       Map.merge(tokens, %{
         "issuer" => @issuer,
         "client_id" => client_id,
         "subject" => claims["sub"],
         "email" => claims["email"],
         "id_token" => body["id_token"]
       })}
    end
  end

  def refresh(%{"client_id" => client_id, "refresh_token" => refresh_token, "scopes" => scopes}) do
    with {:ok, body} <-
           request(:post, @issuer <> @token_path,
             form: [
               grant_type: "refresh_token",
               client_id: client_id,
               refresh_token: refresh_token,
               resource: @resource
             ]
           ) do
      body
      |> Map.put_new("scope", Enum.join(scopes, " "))
      |> Map.put_new("refresh_token", refresh_token)
      |> Map.put_new("token_type", "Bearer")
      |> tokens()
    end
  end

  def revoke(%{"client_id" => client_id, "refresh_token" => refresh_token}) do
    case request(:post, @issuer <> "/api/accounts/oauth/revoke",
           form: [client_id: client_id, token: refresh_token, token_type_hint: "refresh_token"]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def models(token) do
    case request(:get, @resource <> "/models", auth: {:bearer, token}) do
      {:ok, %{"models" => models}} when is_list(models) ->
        catalog =
          for %{"visibility" => "list", "slug" => slug, "display_name" => name} <- models,
              is_binary(slug) and is_binary(name),
              do: %{"slug" => slug, "display_name" => name}

        {:ok, catalog}

      {:ok, _} ->
        {:error, :invalid_model_catalog}

      {:error, _} = error ->
        error
    end
  end

  def transferable?(%{
        "issuer" => @issuer,
        "client_id" => "oaiapp_" <> suffix,
        "subject" => subject,
        "access_token" => access,
        "refresh_token" => refresh,
        "expires_at" => expires,
        "scopes" => scopes
      })
      when is_binary(subject) and is_binary(access) and is_binary(refresh) and is_integer(expires) and
             is_list(scopes) do
    suffix != "" and subject != "" and access != "" and refresh != "" and @permission in scopes and
      Enum.all?(scopes, &is_binary/1)
  end

  def transferable?(_record), do: false

  defp verify_state(state, %{"state" => received}) when is_binary(received) do
    if :crypto.hash_equals(:crypto.hash(:sha256, state), :crypto.hash(:sha256, received)),
      do: :ok,
      else: {:error, :invalid_callback}
  end

  defp verify_state(_state, _params), do: {:error, :invalid_callback}

  defp authorization_code(%{"error" => _}), do: {:error, :authorization_denied}
  defp authorization_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp authorization_code(_params), do: {:error, :invalid_callback}

  defp issued_client(nil, "oaiapp_" <> suffix = id) when suffix != "", do: {:ok, id}
  defp issued_client(%{"client_id" => id}, received) when received in [nil, id], do: {:ok, id}
  defp issued_client(_registration, _received), do: {:error, :invalid_client}

  defp tokens(%{
         "access_token" => access,
         "refresh_token" => refresh,
         "expires_in" => expires,
         "token_type" => kind,
         "scope" => scope
       })
       when is_binary(access) and access != "" and is_binary(refresh) and refresh != "" and
              is_integer(expires) and expires > 0 and is_binary(scope) and is_binary(kind) do
    scopes = String.split(scope)

    if String.downcase(kind) == "bearer" and @permission in scopes do
      {:ok,
       %{
         "access_token" => access,
         "refresh_token" => refresh,
         "expires_at" => System.system_time(:second) + expires,
         "scopes" => scopes
       }}
    else
      {:error, :plan_not_authorized}
    end
  end

  defp tokens(_body), do: {:error, :invalid_token_response}

  defp verify_identity(token, client_id, nonce) when is_binary(token) do
    with {:ok, %{"keys" => keys}} when is_list(keys) <-
           request(:get, @issuer <> "/.well-known/jwks.json", []) do
      validate_identity(token, client_id, nonce, keys)
    else
      _ -> {:error, :identity_keys_unavailable}
    end
  end

  defp verify_identity(_token, _client_id, _nonce), do: {:error, :invalid_identity}

  @doc false
  def validate_identity(token, client_id, nonce, keys) do
    with [header, payload, signature] <- String.split(token, "."),
         {:ok, %{"alg" => "RS256", "kid" => kid}} when is_binary(kid) <- decode_segment(header),
         {:ok, sig} <- Base.url_decode64(signature, padding: false),
         {:ok, key} <- rsa_key(keys, kid),
         true <- :public_key.verify(header <> "." <> payload, :sha256, sig, key),
         {:ok, claims} <- decode_segment(payload),
         true <- valid_claims?(claims, client_id, nonce) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp rsa_key(keys, kid) do
    with %{"n" => modulus, "e" => exponent} <-
           Enum.find(keys, &match?(%{"kty" => "RSA", "kid" => ^kid}, &1)),
         {:ok, n} <- Base.url_decode64(modulus, padding: false),
         {:ok, e} <- Base.url_decode64(exponent, padding: false) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}}
    else
      _ -> {:error, :invalid_identity_key}
    end
  end

  defp valid_claims?(
         %{"iss" => @issuer, "aud" => aud, "exp" => exp, "nonce" => nonce, "sub" => sub} = claims,
         client_id,
         nonce
       )
       when is_integer(exp) and is_binary(sub) and sub != "" do
    audience = List.wrap(aud)

    exp > System.system_time(:second) and client_id in audience and
      (length(audience) == 1 or claims["azp"] == client_id) and
      Map.get(claims, "azp", client_id) == client_id
  end

  defp valid_claims?(_claims, _client_id, _nonce), do: false

  defp same_subject(nil, _subject), do: :ok
  defp same_subject(%{"subject" => subject}, subject), do: :ok
  defp same_subject(_registration, _subject), do: {:error, :account_changed}

  defp decode_segment(segment) do
    with {:ok, value} <- Base.url_decode64(segment, padding: false), do: Jason.decode(value)
  end

  defp request(method, url, opts) do
    options = [method: method, url: url, retry: false, redirect: false, receive_timeout: 15_000]

    case Req.request(options ++ http_options() ++ opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{body: %{"error" => "invalid_grant"}}} -> {:error, :reauthorization_required}
      {:ok, %{status: status}} -> {:error, {:openai_http, status}}
      {:error, _reason} -> {:error, :openai_unreachable}
    end
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
