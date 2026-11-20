defmodule EvoGit.TestSupport.ChatGPTFixture do
  @moduledoc false

  def seed!(account, overrides \\ %{}) do
    {:ok, path} = EvoGit.Auth.ChatGPT.Store.path(account)

    record = %{
      "issuer" => "https://auth.openai.com",
      "client_id" => "oaiapp_test-#{account}",
      "subject" => "subject-#{account}",
      "email" => "#{account}@example.test",
      "access_token" => "access-#{account}",
      "refresh_token" => "refresh-#{account}",
      "expires_at" => System.system_time(:second) + 3600,
      "scopes" => ["chatgpt.tokens.use.direct"],
      "models" => [%{"slug" => "gpt-5.6-terra", "display_name" => "GPT Test"}]
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.merge(record, overrides)))
    File.chmod!(path, 0o600)
    path
  end
end
