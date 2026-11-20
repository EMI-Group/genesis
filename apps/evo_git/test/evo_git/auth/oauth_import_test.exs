defmodule EvoGit.Auth.OAuthImportTest do
  use ExUnit.Case, async: true

  alias EvoGit.Auth
  alias EvoGit.Auth.OAuthImport

  setup do
    root = tmp_dir!("evogit_oauth_import")
    # The managed file default resolves through EvoGit.Config, so isolate the
    # config dir per test via the per-process :config_dir_fun seam.
    EvoGit.TestSupport.ConfigDir.activate(Path.join(root, "config"))

    %{
      root: root,
      managed: Path.join(root, "auth.json"),
      home: Path.join(root, "home")
    }
  end

  describe "sources/1" do
    test "derives the Claude path from the home directory", %{home: home} do
      assert OAuthImport.sources(:anthropic, home: home) == [
               Path.join([home, ".claude", ".credentials.json"])
             ]
    end

    test "returns no sources for an unsupported provider", %{home: home} do
      assert OAuthImport.sources(:deepseek, home: home) == []
    end
  end

  describe "import/2 — Claude" do
    test "imports the subscription login", %{managed: managed, home: home} do
      write_claude_source!(home, %{
        "accessToken" => "claude-access",
        "refreshToken" => "claude-refresh",
        "expiresAt" => 1_700_000_001_000
      })

      assert :imported = OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert %{"anthropic" => entry} = managed_json!(managed)
      assert entry["type"] == "oauth"
      assert entry["access"] == "claude-access"
      assert entry["refresh"] == "claude-refresh"
      assert entry["expires"] == 1_700_000_001_000
    end
  end

  describe "import/2 — freshness and merging" do
    test "an expired access token with a refresh token is still imported and reported", %{
      managed: managed,
      home: home
    } do
      token = jwt(%{"exp" => 1_600_000_000})

      write_claude_source!(home, %{
        "accessToken" => token,
        "refreshToken" => "refresh-1",
        "expiresAt" => 1_600_000_000_000
      })

      assert :imported =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert %{"anthropic" => %{"refresh" => "refresh-1"}} = managed_json!(managed)

      assert {:ok, %{expires: 1_600_000_000_000, account_id: nil}} =
               Auth.credential_status(:anthropic, oauth_file: managed)

      assert :ok =
               Auth.ensure_credentials(:anthropic,
                 home: Path.join(home, "absent"),
                 oauth_file: managed
               )
    end

    test "a missing source file skips and creates no managed file", %{
      managed: managed,
      home: home
    } do
      assert {:skipped, :source_missing} =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      refute File.exists?(managed)
    end

    test "a managed file newer than the source is never re-imported", %{
      managed: managed,
      home: home
    } do
      write_claude_source!(home, %{"accessToken" => jwt(%{"exp" => 1_800_000_000})})

      assert :imported =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      before = File.read!(managed)

      # Simulate ReqLLM's token rotation: the managed file is now newer than the
      # vendor login file. Set the mtime explicitly so the test cannot be
      # timing-flaky.
      File.touch!(managed, System.os_time(:second) + 3_600)

      assert {:skipped, :entry_exists_and_fresh} =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert File.read!(managed) == before
    end

    test "an existing entry for another provider is preserved", %{
      managed: managed,
      home: home
    } do
      File.write!(
        managed,
        Jason.encode!(%{"other-provider" => %{"type" => "oauth", "access" => "existing-token"}})
      )

      write_claude_source!(home, %{"accessToken" => jwt(%{"exp" => 1_800_000_000})})

      assert :imported =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert %{
               "other-provider" => %{"access" => "existing-token"},
               "anthropic" => %{"access" => _token}
             } = managed_json!(managed)
    end

    test "the managed file is owner-only", %{managed: managed, home: home} do
      write_claude_source!(home, %{"accessToken" => jwt(%{"exp" => 1_800_000_000})})

      assert :imported =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert Bitwise.band(File.stat!(managed).mode, 0o777) == 0o600
    end
  end

  describe "import/2 — managed file failures" do
    test "an unusable managed path is an error, while a missing source stays a skip", %{
      root: root,
      home: home
    } do
      write_claude_source!(home, %{"accessToken" => jwt(%{"exp" => 1_800_000_000})})

      # A regular file cannot serve as a parent directory, independently of
      # filesystem name limits or permissions (which root can bypass).
      blocker = Path.join(root, "not-a-directory")
      File.write!(blocker, "not a directory")
      managed = Path.join(blocker, "auth.json")

      assert {:error, {:managed_file_unreadable, :enotdir}} =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert OAuthImport.managed_file_failure_reason(
               {:error, {:managed_file_unreadable, :enotdir}}
             ) == :enotdir

      refute File.exists?(managed)
      assert File.read!(blocker) == "not a directory"

      # Same managed path, no vendor login: a skip, never a write error.
      assert {:skipped, :source_missing} =
               OAuthImport.import(:anthropic,
                 home: Path.join(root, "absent-codex-home"),
                 oauth_file: managed
               )
    end

    test "managed_file_failure_reason/1 maps ONLY managed-file failures" do
      for tag <- [
            :config_dir_unwritable,
            :temp_file_failed,
            :write_failed,
            :chmod_failed,
            :rename_failed,
            :managed_file_unreadable
          ] do
        assert OAuthImport.managed_file_failure_reason({:error, {tag, :erofs}}) == :erofs
      end

      assert OAuthImport.managed_file_failure_reason(:imported) == nil
      assert OAuthImport.managed_file_failure_reason({:skipped, :no_usable_tokens}) == nil

      assert OAuthImport.managed_file_failure_reason({:error, {:source_unreadable, :eacces}}) ==
               nil

      assert OAuthImport.managed_file_failure_reason({:error, {:invalid_managed_file, ":oops"}}) ==
               nil
    end
  end

  describe "import/2 — malformed input" do
    test "malformed source JSON returns an error and leaves the source untouched", %{
      managed: managed,
      home: home
    } do
      path = Path.join([home, ".claude", ".credentials.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      assert {:error, _reason} =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      refute File.exists?(managed)
      assert File.read!(path) == "{not json"
    end

    test "a malformed managed file returns an error and is left untouched", %{
      managed: managed,
      home: home
    } do
      write_claude_source!(home, %{"accessToken" => jwt(%{"exp" => 1_800_000_000})})
      File.write!(managed, "{oops")

      assert {:error, _reason} =
               OAuthImport.import(:anthropic, home: home, oauth_file: managed)

      assert File.read!(managed) == "{oops"
    end

    test "an unsupported provider is skipped", %{managed: managed} do
      assert {:skipped, :unsupported_provider} =
               OAuthImport.import(:deepseek, oauth_file: managed)
    end
  end

  describe "parse_claude_credentials/1" do
    test "requires an access token", %{} do
      assert {:error, :no_usable_tokens} =
               OAuthImport.parse_claude_credentials(%{"claudeAiOauth" => %{}})

      assert {:error, :no_access_token} =
               OAuthImport.parse_claude_credentials(%{
                 "claudeAiOauth" => %{"refreshToken" => "r"}
               })
    end
  end

  describe "parse_env_token/1" do
    test "has no fallback for the Codex provider", %{} do
      assert OAuthImport.parse_env_token(:openai_codex) == :error
      assert OAuthImport.env_token(:openai_codex) == nil
    end
  end

  describe "JWT helpers" do
    test "jwt_claim/2 reads a claim" do
      token = jwt(%{"exp" => 42, "sub" => "user-1"})
      assert OAuthImport.jwt_claim(token, "sub") == "user-1"
    end

    test "jwt_expires_at/1 converts seconds to milliseconds" do
      assert OAuthImport.jwt_expires_at(jwt(%{"exp" => 1_800_000_000})) == 1_800_000_000_000
      assert OAuthImport.jwt_expires_at(jwt(%{"sub" => "no-exp"})) == nil
    end

    test "malformed tokens never raise and return nil" do
      assert OAuthImport.jwt_claim(nil, "exp") == nil
      assert OAuthImport.jwt_claim("not-a-jwt", "exp") == nil
      assert OAuthImport.jwt_claim("a.!!!!.c", "exp") == nil
      assert OAuthImport.jwt_claim("a.eyJleHAi. c", "exp") == nil
      assert OAuthImport.jwt_expires_at(nil) == nil
      assert OAuthImport.jwt_expires_at("...") == nil
    end
  end

  ## Helpers

  defp tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_claude_source!(home, oauth) do
    dir = Path.join(home, ".claude")
    File.mkdir_p!(dir)
    path = Path.join(dir, ".credentials.json")
    File.write!(path, Jason.encode!(%{"claudeAiOauth" => oauth}))
    path
  end

  defp managed_json!(path), do: path |> File.read!() |> Jason.decode!()

  # Throw-away JWT: header.payload.signature, base64url-encoded without padding.
  defp jwt(claims) do
    header = base64url(%{"alg" => "none", "typ" => "JWT"})
    header <> "." <> base64url(claims) <> ".sig"
  end

  defp base64url(value) do
    value |> Jason.encode!() |> Base.url_encode64(padding: false)
  end
end
