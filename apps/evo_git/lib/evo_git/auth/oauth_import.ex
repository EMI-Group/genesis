defmodule EvoGit.Auth.OAuthImport do
  @moduledoc """
  Imports OAuth credentials from the vendor CLIs' own login files into the
  managed Genesis OAuth file (`EvoGit.Auth.oauth_file/1`).

  Genesis does not run its own OAuth device flow: the vendor CLI logs in once
  and writes a credentials file, and Genesis reuses it. The managed file is the
  SAME JSON document ReqLLM reads and rotates refreshed tokens back into, so
  its shape is ReqLLM-native:

      {"openai-codex": {"type": "oauth", "access": "...", "refresh": "...",
                        "expires": 1800000000000, "accountId": "..."}}

  ## Sources

    * `:openai_codex` — `$CODEX_HOME/auth.json` when `CODEX_HOME` is set, else
      `<home>/.codex/auth.json` (written by `codex login`)
    * `:anthropic` — `<home>/.claude/.credentials.json` (written by `claude`)

  ## Never clobber fresher credentials

  ReqLLM refreshes expired credentials and persists the rotated tokens into the
  managed file. Re-importing an old vendor file would undo that rotation, so an
  import happens ONLY when the managed file has no entry for the provider, or
  when the source file's mtime is NEWER than the managed file's mtime.
  Otherwise the import is skipped with `{:skipped, :entry_exists_and_fresh}`.

  ## Writes

  The managed file is written atomically (uniquely-named temp file in the same
  directory created with `[:exclusive]`, `File.chmod/2`, then `File.rename/2`)
  with owner-only `0o600` permissions for a NEW file and the EXISTING mode for
  a file that already exists. Existing entries for other providers are
  preserved; the document is merged, never replaced. Token contents are never
  logged.

  A write that cannot happen is reported with a tagged reason
  (`{:config_dir_unwritable | :temp_file_failed | :write_failed | :chmod_failed | :rename_failed, posix}`),
  and an unusable managed PATH (read-only home, Nix sandbox, a path component
  that is not a directory) as `{:managed_file_unreadable, posix}` — the
  distinction `EvoGit.Auth` needs to tell "credentials were found but the
  managed copy could not be written" apart from "no vendor login exists"
  (`managed_file_failure_reason/1`).

  ## Environment tokens

  `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_OAUTH_TOKEN` are the lowest-priority
  fallback for `:anthropic` — an OAuth access token with no refresh token.
  They are reported by `env_token/1` and never written to the managed file.
  """

  require Logger

  alias EvoGit.Auth

  @typedoc "Provider atoms that can be imported from a vendor login file."
  @type provider :: :openai_codex | :anthropic

  @typedoc """
  Source-file locations examined for a provider, highest priority first.
  """
  @type source :: String.t()

  @type parse_result :: {:ok, map()} | :error | {:error, term()}

  @type import_result ::
          :imported
          | {:skipped,
             :source_missing
             | :source_newer_not_required
             | :entry_exists_and_fresh
             | :no_usable_tokens
             | :auth_mode_not_chatgpt
             | :unsupported_provider}
          | {:error, term()}

  @env_token_names %{
    anthropic: ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN"],
    openai_codex: []
  }

  # Import error tags that mean "the managed file/path could not be used":
  # either it could not be written or its PATH is unusable. Source-file
  # problems (`:source_unreadable`/`:source_invalid`) and content problems
  # (`:invalid_managed_file`/`:encode_failed`) are deliberately NOT here.
  @managed_file_failure_tags [
    :config_dir_unwritable,
    :temp_file_failed,
    :write_failed,
    :chmod_failed,
    :rename_failed,
    :managed_file_unreadable
  ]

  @doc """
  Returns the candidate vendor login files for `provider`, in priority order.

  Recognized options (all optional):

    * `:home` — overrides the user home directory used to derive the paths
    * `:codex_home` — overrides the Codex CLI home; passing it explicitly
      (even as `nil`) bypasses `$CODEX_HOME`

  The home directory is read from the default-inert
  `Application.get_env(:evo_git, :auth_home_fun)` (0-arity fun) at CALL time,
  falling back to `System.user_home/0`.
  """
  @spec sources(atom(), keyword()) :: [source()]
  def sources(provider, opts \\ [])

  def sources(provider, opts) when is_list(opts) do
    case Auth.normalize_provider(provider) do
      :openai_codex -> codex_sources(opts)
      :anthropic -> claude_sources(opts)
      _other -> []
    end
  end

  def sources(_provider, _opts), do: []

  @doc """
  Imports `provider` credentials from the vendor login file into the managed
  OAuth file at `EvoGit.Auth.oauth_file(opts)`.

  Accepts the `sources/2` options plus `:oauth_file` (redirects the managed
  file). Returns `:imported`, a `{:skipped, reason}`, or `{:error, reason}` —
  never raises and never logs token contents.
  """
  @spec import(atom(), keyword()) :: import_result()
  def import(provider, opts \\ [])

  def import(provider, opts) when is_list(opts) do
    provider = Auth.normalize_provider(provider)

    if Auth.oauth_provider_id(provider) == nil do
      {:skipped, :unsupported_provider}
    else
      do_import(provider, opts)
    end
  end

  def import(_provider, _opts), do: {:skipped, :unsupported_provider}

  @doc """
  Builds a ReqLLM-native managed entry from the Codex CLI's `auth.json`.

  Accepted source shape:

      {"auth_mode": "chatgpt", "OPENAI_API_KEY": null,
       "tokens": {"id_token": "...", "access_token": "...",
                  "refresh_token": "...", "account_id": "..."}}

  `accountId` comes from `tokens.account_id`, falling back to the access
  token's JWT claim `https://api.openai.com/auth` → `chatgpt_account_id`.
  `expires` is derived from the access token's `exp` claim (seconds → ms).

  Returns `:error` when the CLI is in an explicit API-key mode (there is no
  OAuth token to import) and `{:error, :no_access_token}` when the access token
  is missing or blank. A missing/blank `auth_mode` is accepted because older
  CLI versions omit it.
  """
  @spec parse_codex_auth(map() | String.t()) :: parse_result()
  def parse_codex_auth(source) do
    case coerce_source(source) do
      {:ok, map} ->
        case build_codex_entry(map) do
          {:ok, entry} -> {:ok, entry}
          # An explicit API-key mode means there is no OAuth credential here.
          {:error, :auth_mode_not_chatgpt} -> :error
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds a ReqLLM-native managed entry from Claude's `.credentials.json`.

  Accepted source shape:

      {"claudeAiOauth": {"accessToken": "...", "refreshToken": "...",
                         "expiresAt": 1800000000000}}

  `expires` is taken from `expiresAt` as-is. Returns
  `{:error, :no_access_token}` when there is no access token and
  `{:error, :no_usable_tokens}` when the OAuth block carries neither an access
  nor a refresh token.
  """
  @spec parse_claude_credentials(map() | String.t()) :: parse_result()
  def parse_claude_credentials(source) do
    case coerce_source(source) do
      {:ok, map} -> build_claude_entry(map)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the OAuth-without-refresh entry from a provider environment variable.

  For `:anthropic` the `CLAUDE_CODE_OAUTH_TOKEN` then `ANTHROPIC_OAUTH_TOKEN`
  variables are consulted; `:openai_codex` has no env fallback and returns
  `:error`. The entry carries only `type` and `access`, so ReqLLM uses the
  token directly and cannot refresh it.
  """
  @spec parse_env_token(atom()) :: {:ok, map()} | :error
  def parse_env_token(provider) do
    case env_token(provider) do
      nil -> :error
      token -> {:ok, %{"type" => "oauth", "access" => token}}
    end
  end

  @doc """
  Returns the provider's OAuth access token from the environment, or `nil`.

  `:anthropic` checks `CLAUDE_CODE_OAUTH_TOKEN` then `ANTHROPIC_OAUTH_TOKEN`;
  every other provider has no env fallback. Values are read at CALL time and
  blank values are ignored.
  """
  @spec env_token(atom()) :: String.t() | nil
  def env_token(provider) when is_atom(provider) do
    provider
    |> env_token_names()
    |> Enum.find_value(fn name -> non_empty_string(System.get_env(name)) end)
  end

  def env_token(_provider), do: nil

  @doc """
  Returns the value of a JWT claim, or `nil` for any malformed input.

  Base64url-decodes the token's payload segment (padding-tolerant) and decodes
  it as JSON. Never raises.
  """
  @spec jwt_claim(String.t() | nil, String.t()) :: term() | nil
  def jwt_claim(token, claim_key) when is_binary(token) and is_binary(claim_key) do
    case jwt_claims(token) do
      %{} = claims -> Map.get(claims, claim_key)
      nil -> nil
    end
  end

  def jwt_claim(_token, _claim_key), do: nil

  @doc """
  Returns the `exp` claim of a JWT as milliseconds since the Unix epoch, or
  `nil` when the token has no usable `exp` claim. Never raises.
  """
  @spec jwt_expires_at(String.t() | nil) :: integer() | nil
  def jwt_expires_at(token) do
    token
    |> jwt_claim("exp")
    |> jwt_seconds()
    |> case do
      nil -> nil
      seconds -> seconds * 1000
    end
  end

  @doc false
  # Shared field lookup used by `EvoGit.Auth`: the first present key wins.
  @spec entry_field(map(), [String.t()]) :: term()
  def entry_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  def entry_field(_map, _keys), do: nil

  @doc false
  # Trims a binary and maps blank/non-binary values to nil.
  @spec non_empty_string(term()) :: String.t() | nil
  def non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def non_empty_string(_value), do: nil

  @doc false
  # Maps an `import/2` result to the underlying POSIX reason atom when the
  # MANAGED file could not be used (written, or even reached), and to `nil`
  # otherwise — a `{:skipped, _}` outcome, `:imported`, a source-file problem or
  # a broken managed document all yield `nil`. `EvoGit.Auth` uses this to report
  # `{:managed_file_unwritable, reason}` instead of collapsing the real cause
  # into `:no_credentials`.
  @spec managed_file_failure_reason(import_result()) :: atom() | term() | nil
  def managed_file_failure_reason({:error, reason}), do: managed_file_failure_reason(reason)

  def managed_file_failure_reason({tag, reason}) when tag in @managed_file_failure_tags,
    do: reason

  def managed_file_failure_reason(_result), do: nil

  ## Source paths

  defp codex_sources(opts) do
    case codex_home(opts) do
      nil -> [Path.join([home(opts), ".codex", "auth.json"])]
      dir -> [Path.join(dir, "auth.json")]
    end
  end

  # An explicit `:codex_home` (including `nil`/`""`) overrides `$CODEX_HOME`;
  # `nil` therefore means "the CLI has no custom Codex home".
  defp codex_home(opts) do
    case Keyword.fetch(opts, :codex_home) do
      {:ok, value} -> non_empty_string(value)
      :error -> non_empty_string(System.get_env("CODEX_HOME"))
    end
  end

  defp claude_sources(opts) do
    [Path.join([home(opts), ".claude", ".credentials.json"])]
  end

  defp home(opts) do
    case non_empty_string(Keyword.get(opts, :home)) do
      nil -> configured_home()
      home -> home
    end
  end

  # Read at CALL time so the seam stays default-inert in production.
  defp configured_home do
    home =
      case Application.get_env(:evo_git, :auth_home_fun) do
        fun when is_function(fun, 0) -> fun.()
        _other -> System.user_home()
      end

    case non_empty_string(home) do
      nil -> System.tmp_dir!()
      dir -> dir
    end
  end

  ## Import pipeline

  defp do_import(provider, opts) do
    managed = Auth.oauth_file(opts)

    case first_existing_source(provider, opts) do
      nil -> {:skipped, :source_missing}
      source_path -> maybe_import(provider, source_path, managed)
    end
  end

  defp first_existing_source(provider, opts) do
    provider
    |> sources(opts)
    |> Enum.find(fn path -> File.regular?(path) end)
  end

  defp maybe_import(provider, source_path, managed) do
    case read_managed(managed) do
      {:ok, existing} ->
        if entry_present?(existing, provider) and not source_newer?(source_path, managed) do
          {:skipped, :entry_exists_and_fresh}
        else
          import_from(provider, source_path, managed, existing)
        end

      {:error, reason} ->
        Logger.warning(
          "OAuth import for #{provider} skipped: the managed file #{managed} is unusable (#{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  defp read_managed(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = payload} -> {:ok, payload}
          {:ok, _other} -> {:error, {:invalid_managed_file, :not_an_object}}
          {:error, error} -> {:error, {:invalid_managed_file, Exception.message(error)}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:managed_file_unreadable, reason}}
    end
  end

  defp entry_present?(payload, provider) do
    key = Auth.oauth_provider_id(provider)
    is_binary(key) and is_map(Map.get(payload, key))
  end

  # Whole-second mtimes are enough here and make the decision deterministic in
  # tests (a managed file touched into the future is never re-imported over).
  defp source_newer?(source_path, managed_path) do
    with {:ok, %File.Stat{mtime: source_mtime}} <- File.stat(source_path, time: :posix),
         {:ok, %File.Stat{mtime: managed_mtime}} <- File.stat(managed_path, time: :posix) do
      source_mtime > managed_mtime
    else
      _other -> false
    end
  end

  defp import_from(provider, source_path, managed, existing) do
    case read_source(source_path) do
      {:ok, source} -> write_import(provider, source, managed, existing, source_path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_import(provider, source, managed, existing, source_path) do
    case build_entry(provider, source) do
      {:ok, entry} ->
        write_entry(provider, managed, existing, entry)

      {:skipped, reason} ->
        Logger.debug(fn ->
          "OAuth import for #{provider} skipped: #{inspect(reason)} (#{source_path})"
        end)

        {:skipped, reason}
    end
  end

  defp read_source(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = source} -> {:ok, source}
          {:ok, _other} -> {:error, {:source_invalid, :not_an_object}}
          {:error, error} -> {:error, {:source_invalid, Exception.message(error)}}
        end

      {:error, reason} ->
        {:error, {:source_unreadable, reason}}
    end
  end

  defp build_entry(:openai_codex, source) do
    case build_codex_entry(source) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, :auth_mode_not_chatgpt} ->
        {:skipped, :auth_mode_not_chatgpt}

      {:error, reason} when reason in [:no_access_token, :no_usable_tokens] ->
        {:skipped, :no_usable_tokens}
    end
  end

  defp build_entry(:anthropic, source) do
    case build_claude_entry(source) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, reason} when reason in [:no_access_token, :no_usable_tokens] ->
        {:skipped, :no_usable_tokens}
    end
  end

  defp build_entry(_provider, _source), do: {:skipped, :unsupported_provider}

  ## Entry builders

  defp build_codex_entry(source) do
    tokens = map_field(source, "tokens")
    access = non_empty_string(entry_field(tokens, ["access_token"]))
    refresh = non_empty_string(entry_field(tokens, ["refresh_token"]))
    account_id = non_empty_string(entry_field(tokens, ["account_id"]))
    auth_mode = non_empty_string(entry_field(source, ["auth_mode"]))

    cond do
      not chatgpt_mode?(auth_mode) ->
        {:error, :auth_mode_not_chatgpt}

      is_nil(access) ->
        {:error, :no_access_token}

      true ->
        entry = %{
          "type" => "oauth",
          "access" => access,
          "refresh" => refresh,
          "expires" => explicit_expiry(source, tokens) || jwt_expires_at(access),
          "accountId" => account_id || codex_account_id_from_token(access)
        }

        {:ok, drop_nil(entry)}
    end
  end

  defp build_claude_entry(source) do
    oauth = map_field(source, "claudeAiOauth")
    access = non_empty_string(entry_field(oauth, ["accessToken", "access_token"]))
    refresh = non_empty_string(entry_field(oauth, ["refreshToken", "refresh_token"]))
    expires = expiry_value(entry_field(oauth, ["expiresAt", "expires_at", "expires"]))

    cond do
      is_nil(access) and is_nil(refresh) ->
        {:error, :no_usable_tokens}

      is_nil(access) ->
        {:error, :no_access_token}

      true ->
        entry = %{
          "type" => "oauth",
          "access" => access,
          "refresh" => refresh,
          "expires" => expires || jwt_expires_at(access)
        }

        {:ok, drop_nil(entry)}
    end
  end

  defp chatgpt_mode?(nil), do: true
  defp chatgpt_mode?(mode) when is_binary(mode), do: String.downcase(mode) == "chatgpt"
  defp chatgpt_mode?(_mode), do: false

  defp explicit_expiry(source, tokens) do
    expiry_value(entry_field(source, ["expires", "expires_at", "expiresAt"])) ||
      expiry_value(entry_field(tokens, ["expires", "expires_at", "expiresAt"]))
  end

  defp expiry_value(value) when is_integer(value), do: value
  defp expiry_value(value) when is_float(value), do: round(value)

  defp expiry_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp expiry_value(_value), do: nil

  defp codex_account_id_from_token(token) do
    case jwt_claim(token, "https://api.openai.com/auth") do
      %{} = auth_claim -> non_empty_string(Map.get(auth_claim, "chatgpt_account_id"))
      _other -> nil
    end
  end

  defp map_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      %{} = value -> value
      _other -> %{}
    end
  end

  defp map_field(_map, _key), do: %{}

  ## Writing the managed file

  defp write_entry(provider, managed_path, existing, entry) do
    key = Auth.oauth_provider_id(provider)
    payload = Map.put(existing, key, entry)

    with {:ok, contents} <- encode_payload(payload),
         :ok <- atomic_write(managed_path, contents, existing_mode(managed_path)) do
      Logger.debug(fn -> "Imported #{key} OAuth credentials into #{managed_path}" end)
      :imported
    else
      {:error, reason} = error ->
        # Path + reason only — never token contents. This is the ONE trace of a
        # managed file Genesis could not write (e.g. a read-only home).
        Logger.warning(fn ->
          "OAuth import for #{provider} could not write the managed file #{managed_path} (#{inspect(reason)})"
        end)

        error
    end
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  # A NEW file is owner-only; an existing file keeps its mode (ReqLLM preserves
  # the mode on its own rotation writes, so a merged document must not change
  # it either).
  defp existing_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when is_integer(mode) and mode > 0 ->
        Bitwise.band(mode, 0o777)

      _other ->
        0o600
    end
  end

  defp atomic_write(path, contents, mode) do
    dir = Path.dirname(path)

    with :ok <- ensure_dir(dir),
         {:ok, temp} <- create_temp(dir, path, mode) do
      result =
        with :ok <- write_temp(temp, contents),
             :ok <- rename_temp(temp, path) do
          :ok
        end

      _ = File.rm(temp)
      result
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_dir_unwritable, reason}}
    end
  end

  defp create_temp(dir, path, mode) do
    temp = temp_path(dir, path)

    with :ok <- create_temp_file(temp),
         :ok <- chmod_temp(temp, mode) do
      {:ok, temp}
    else
      {:error, {:temp_file_failed, _} = reason} ->
        _ = File.rm(temp)
        {:error, reason}

      {:error, {:chmod_failed, _} = reason} ->
        _ = File.rm(temp)
        {:error, reason}
    end
  end

  defp create_temp_file(temp) do
    case File.write(temp, <<>>, [:exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:temp_file_failed, reason}}
    end
  end

  # A mode change can fail on its own (e.g. an ACL-restricted directory) and is
  # reported separately from the temp-file creation.
  defp chmod_temp(temp, mode) do
    case File.chmod(temp, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_failed, reason}}
    end
  end

  defp write_temp(temp, contents) do
    case File.write(temp, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp rename_temp(temp, path) do
    case File.rename(temp, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  defp temp_path(dir, path) do
    suffix =
      [System.system_time(:nanosecond), System.unique_integer([:positive, :monotonic])]
      |> Enum.join("-")

    Path.join(dir, ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  ## JSON / JWT helpers

  defp coerce_source(source) when is_map(source), do: {:ok, source}

  defp coerce_source(source) when is_binary(source) do
    case Jason.decode(source) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp coerce_source(_source), do: {:error, :invalid_source}

  defp drop_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp env_token_names(provider) do
    Map.get(@env_token_names, Auth.normalize_provider(provider), [])
  end

  defp jwt_claims(token) when is_binary(token) do
    with [_header, payload | _rest] <- String.split(token, "."),
         {:ok, decoded} <- decode_base64(payload),
         {:ok, %{} = claims} <- Jason.decode(decoded) do
      claims
    else
      _other -> nil
    end
  end

  # Tolerates both base64url (JWT standard) and padded base64 segments; never
  # raises on malformed input.
  defp decode_base64(segment) when is_binary(segment) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(segment, padding: false)
    end
  end

  defp jwt_seconds(value) when is_integer(value) and value > 0, do: value
  defp jwt_seconds(value) when is_float(value) and value > 0, do: round(value)

  defp jwt_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp jwt_seconds(_value), do: nil
end
