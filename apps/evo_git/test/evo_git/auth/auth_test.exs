defmodule EvoGit.AuthTest do
  use ExUnit.Case, async: true

  alias EvoGit.Auth

  setup do
    root = tmp_dir!("evogit_auth")
    # Keeps every user-config read in this module off the developer's real
    # ~/.config/genesis (the :config_dir_fun seam is per process).
    config_root = EvoGit.TestSupport.ConfigDir.isolate!("evogit_auth_config")

    %{root: root, config_root: config_root, managed: Path.join(root, "auth.json")}
  end

  describe "oauth_provider_id/1" do
    test "only the Claude subscription uses the managed ReqLLM file" do
      assert Auth.oauth_provider_id(:anthropic) == "anthropic"
      assert Auth.oauth_provider_id(:openai_codex) == nil
      assert Auth.oauth_provider_id(:openai) == nil
      assert Auth.oauth_provider_id(:deepseek) == nil
    end
  end

  describe "default_oauth_file/0" do
    test "is <config_dir>/auth.json", %{config_root: config_root} do
      assert Auth.default_oauth_file() == Path.join([config_root, "genesis", "auth.json"])
    end
  end

  describe "oauth_file/1 — precedence" do
    test "opts[:oauth_file] wins over the default", %{
      config_root: config_root,
      root: root
    } do
      explicit = Path.join(root, "from-opts.json")
      default = Path.join([config_root, "genesis", "auth.json"])

      assert Auth.oauth_file(oauth_file: explicit) == explicit
      refute Auth.oauth_file(oauth_file: explicit) == default
    end

    test "falls back to the default when no opts are given", %{config_root: config_root} do
      assert Auth.oauth_file([]) == Path.join([config_root, "genesis", "auth.json"])
    end

    test "expands a leading ~ in a user-supplied path" do
      refute String.starts_with?(Auth.oauth_file(oauth_file: "~/auth.json"), "~")
      assert Auth.oauth_file(oauth_file: "~/auth.json") == Path.expand("~/auth.json")
    end

    test "ignores a blank opts path", %{config_root: config_root} do
      assert Auth.oauth_file(oauth_file: "   ") ==
               Path.join([config_root, "genesis", "auth.json"])
    end
  end

  describe "credential_status/2" do
    test "reports :no_credentials for a missing managed file", %{root: root} do
      managed = Path.join(root, "missing-auth.json")

      assert Auth.credential_status(:anthropic, oauth_file: managed) ==
               {:error, :no_credentials}
    end

    test "reports :no_credentials when the provider has no entry", %{managed: managed} do
      File.write!(
        managed,
        Jason.encode!(%{"other-provider" => %{"access" => "a", "refresh" => "r"}})
      )

      assert Auth.credential_status(:anthropic, oauth_file: managed) ==
               {:error, :no_credentials}
    end

    test "reports the stored entry", %{managed: managed} do
      File.write!(
        managed,
        Jason.encode!(%{
          "anthropic" => %{
            "type" => "oauth",
            "access" => "access-token",
            "refresh" => "refresh-token",
            "expires" => 1_800_000_000_000,
            "accountId" => "acct-1"
          }
        })
      )

      assert Auth.credential_status(:anthropic, oauth_file: managed) ==
               {:ok, %{expires: 1_800_000_000_000, account_id: "acct-1"}}
    end

    test "normalizes a seconds-based expiry to milliseconds", %{managed: managed} do
      File.write!(
        managed,
        Jason.encode!(%{
          "anthropic" => %{"access" => "a", "refresh" => "r", "expires" => 1_800_000_000}
        })
      )

      assert {:ok, %{expires: 1_800_000_000_000}} =
               Auth.credential_status(:anthropic, oauth_file: managed)
    end

    test "rejects an entry with neither access nor refresh", %{managed: managed} do
      File.write!(managed, Jason.encode!(%{"anthropic" => %{"type" => "oauth"}}))

      assert Auth.credential_status(:anthropic, oauth_file: managed) ==
               {:error, :invalid_credentials}
    end

    test "rejects a broken managed file", %{managed: managed} do
      File.write!(managed, "{nope")

      assert Auth.credential_status(:anthropic, oauth_file: managed) ==
               {:error, :invalid_credentials}
    end

    test "an unsupported provider has no credentials", %{managed: managed} do
      assert Auth.credential_status(:deepseek, oauth_file: managed) == {:error, :no_credentials}
    end
  end

  describe "ensure_credentials/2" do
    test "returns :no_credentials when nothing is available", %{root: root} do
      opts = [
        oauth_file: Path.join(root, "absent-auth.json"),
        home: Path.join(root, "absent-home-home")
      ]

      assert Auth.ensure_credentials(:anthropic, opts) == {:error, :no_credentials}
    end

    test "is :ok for a stored entry with an access token", %{managed: managed, root: root} do
      File.write!(
        managed,
        Jason.encode!(%{
          "anthropic" => %{
            "access" => "a",
            "expires" => System.system_time(:millisecond) + 60_000
          }
        })
      )

      assert Auth.ensure_credentials(:anthropic,
               oauth_file: managed,
               home: Path.join(root, "absent-home-home")
             ) == :ok
    end

    test "is :ok for a refresh-only entry", %{managed: managed, root: root} do
      File.write!(managed, Jason.encode!(%{"anthropic" => %{"refresh" => "r"}}))

      assert Auth.ensure_credentials(:anthropic,
               oauth_file: managed,
               home: Path.join(root, "absent-home-home")
             ) == :ok
    end

    test "is an error for an expired entry without a refresh token", %{
      managed: managed,
      root: root
    } do
      File.write!(
        managed,
        Jason.encode!(%{"anthropic" => %{"access" => "a", "expires" => 1_000_000_000_000}})
      )

      assert Auth.ensure_credentials(:anthropic,
               oauth_file: managed,
               home: Path.join(root, "absent-home-home")
             ) == {:error, :expired_credentials}
    end

    test "never raises on a broken managed file", %{managed: managed, root: root} do
      File.write!(managed, "{nope")

      assert {:error, _reason} =
               Auth.ensure_credentials(:anthropic,
                 oauth_file: managed,
                 home: Path.join(root, "absent-home-home")
               )
    end

    test "returns an error for invalid options" do
      assert Auth.ensure_credentials(:anthropic, %{oauth_file: "/tmp/x"}) ==
               {:error, :invalid_options}
    end
  end

  describe "login_instructions/1" do
    test "names the Genesis ChatGPT authorization command" do
      assert Auth.login_instructions(:openai_codex) =~ "genesis chatgpt login"
      assert Auth.login_instructions(:openai) =~ "genesis chatgpt login"
    end

    test "names the Claude CLI" do
      instructions = Auth.login_instructions(:anthropic)
      assert instructions =~ "claude"
      assert instructions =~ "CLAUDE_CODE_OAUTH_TOKEN"
    end

    test "returns a neutral message for an unsupported provider" do
      assert Auth.login_instructions(:deepseek) =~ "No OAuth login instructions"
    end
  end

  describe "managed OAuth file failures" do
    test "a found login that cannot be written is reported instead of :no_credentials", %{
      root: root
    } do
      home = Path.join(root, "vendor-home")
      write_claude_source!(home)

      # A regular FILE where the managed file's directory should be: every
      # access fails with :enotdir (the hermetic stand-in for a read-only home).
      blocker = Path.join(root, "blocker")
      File.write!(blocker, "not a directory")
      managed = Path.join(blocker, "auth.json")

      # No vendor login + a sane managed path: the unchanged, plain outcome.
      assert Auth.ensure_credentials(:anthropic,
               oauth_file: Path.join(root, "absent-auth.json"),
               home: Path.join(root, "absent-home")
             ) == {:error, :no_credentials}

      # Vendor login present, managed path unusable: the actionable outcome.
      assert Auth.ensure_credentials(:anthropic, oauth_file: managed, home: home) ==
               {:error, {:managed_file_unwritable, :enotdir}}

      assert Auth.credential_status(:anthropic,
               oauth_file: managed,
               managed_file_error: :enotdir
             ) == {:error, {:managed_file_unwritable, :enotdir}}
    end

    test "a usable managed entry keeps its own status", %{managed: managed, root: root} do
      File.write!(managed, Jason.encode!(%{"anthropic" => %{"refresh" => "r"}}))

      assert Auth.credential_status(:anthropic,
               oauth_file: managed,
               managed_file_error: :erofs
             ) == {:ok, %{expires: nil, account_id: nil}}

      assert Auth.ensure_credentials(:anthropic,
               oauth_file: managed,
               home: Path.join(root, "absent-home")
             ) == :ok
    end
  end

  describe "managed_file_unwritable_remedy/2 + login_instructions/2" do
    test "names the path, the cause and the writable-path remedy" do
      remedy =
        Auth.managed_file_unwritable_remedy({:managed_file_unwritable, :erofs}, "/ro/a.json")

      assert remedy =~ "/ro/a.json"
      assert remedy =~ "read-only file system (:erofs)"
      assert remedy =~ "oauth_file"
      assert remedy =~ "writable location"
    end

    test "is nil for every other outcome" do
      assert Auth.managed_file_unwritable_remedy({:error, :no_credentials}, "/x/a.json") == nil
      assert Auth.managed_file_unwritable_remedy(:ok) == nil
    end

    test "login_instructions/2 appends the remedy only for a managed-file failure" do
      base = Auth.login_instructions(:anthropic)

      assert Auth.login_instructions(:anthropic, nil) == base
      assert Auth.login_instructions(:anthropic, {:error, :no_credentials}) == base

      extended =
        Auth.login_instructions(:anthropic, {:error, {:managed_file_unwritable, :erofs}})

      assert extended =~ "claude"
      assert extended =~ "oauth_file"
      assert extended =~ ":erofs"
    end
  end

  ## Helpers

  defp write_claude_source!(home) do
    File.mkdir_p!(Path.join(home, ".claude"))

    File.write!(
      Path.join([home, ".claude", ".credentials.json"]),
      Jason.encode!(%{
        "claudeAiOauth" => %{"accessToken" => "claude-access", "refreshToken" => "refresh-1"}
      })
    )
  end

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
end
