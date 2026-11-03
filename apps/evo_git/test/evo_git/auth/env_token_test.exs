defmodule EvoGit.Auth.EnvTokenTest do
  # async: false — these tests mutate the BEAM-global process environment
  # (System.put_env/delete_env on CLAUDE_CODE_OAUTH_TOKEN and
  # ANTHROPIC_OAUTH_TOKEN), which any concurrently running module would observe.
  use ExUnit.Case, async: false

  alias EvoGit.Auth

  @variables ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN"]

  setup do
    previous = Map.new(@variables, fn name -> {name, System.get_env(name)} end)
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_auth_env-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{managed: Path.join(root, "auth.json"), home: Path.join(root, "home")}
  end

  test "CLAUDE_CODE_OAUTH_TOKEN makes anthropic credentials usable without writing the file", %{
    managed: managed,
    home: home
  } do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "env-oauth-token")

    assert {:ok, %{expires: nil, account_id: nil}} =
             Auth.credential_status(:anthropic, oauth_file: managed, home: home)

    assert Auth.ensure_credentials(:anthropic, oauth_file: managed, home: home) == :ok
    refute File.exists?(managed)
  end

  test "ANTHROPIC_OAUTH_TOKEN is the secondary fallback", %{managed: managed, home: home} do
    System.put_env("ANTHROPIC_OAUTH_TOKEN", "secondary-env-token")

    assert {:ok, %{account_id: nil}} =
             Auth.credential_status(:anthropic, oauth_file: managed, home: home)
  end

  test "a stored entry wins over the environment token", %{managed: managed, home: home} do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "env-oauth-token")

    File.write!(
      managed,
      Jason.encode!(%{
        "anthropic" => %{"type" => "oauth", "access" => "file-token", "accountId" => "acct-file"}
      })
    )

    assert {:ok, %{account_id: "acct-file"}} =
             Auth.credential_status(:anthropic, oauth_file: managed, home: home)
  end

  test "no env token means no anthropic credentials", %{managed: managed, home: home} do
    assert Auth.credential_status(:anthropic, oauth_file: managed, home: home) ==
             {:error, :no_credentials}

    assert Auth.ensure_credentials(:anthropic, oauth_file: managed, home: home) ==
             {:error, :no_credentials}
  end
end
