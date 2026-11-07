defmodule EvoGit.Auth do
  @moduledoc """
  Credential-resolution facade for OAuth-backed LLM providers.

  Genesis authenticates OAuth-backed providers against the SAME managed file
  ReqLLM reads: a JSON object at `auth.json` whose keys are the ReqLLM OAuth
  provider ids (`"openai-codex"`, `"anthropic"`) and whose values are
  ReqLLM-native entries (`type`/`access`/`refresh`/`expires`/`accountId`).
  ReqLLM refreshes expired entries and rotates the new tokens back into that
  file, so Genesis only has to make sure the file exists and holds usable
  credentials.

  The vendor CLIs already write their own login files (`codex login` writes
  `~/.codex/auth.json`, `claude` writes `~/.claude/.credentials.json`).
  `EvoGit.Auth.OAuthImport` imports those into the managed file — see that
  module for the import rules.

  This module is the public entry point the rest of the runtime codes against:

    * `oauth_provider_id/1` — provider atom → ReqLLM OAuth id
    * `default_oauth_file/0` / `oauth_file/1` — where the managed file lives
    * `ensure_credentials/2` — lazily import, then report usability
    * `credential_status/2` — report the managed entry without importing
    * `login_instructions/1` — the one-time login guidance for humans

  Everything that touches the filesystem is fault-isolated: `ensure_credentials/2`
  NEVER raises, whatever the vendor files, the config directory or the managed
  JSON look like.

  A vendor login that exists but cannot be persisted into the managed file (a
  read-only home, a Nix sandbox, a bad `oauth_file` path) is reported as
  `{:error, {:managed_file_unwritable, posix_reason}}` — never as a misleading
  "no credentials" — and `managed_file_unwritable_remedy/2` turns it into the
  path + cause + writable-location remedy the CLI, health checks and dashboard
  render.
  """

  alias EvoGit.Auth.OAuthImport

  # The ONE place the provider → ReqLLM OAuth id mapping lives. The ids are
  # what ReqLLM looks up in the auth file (`oauth_provider_id/0` on each
  # provider module).
  @oauth_provider_ids %{
    openai_codex: "openai-codex",
    anthropic: "anthropic"
  }

  # Provider atoms that resolve to an OAuth credential. `:openai` is accepted as
  # an alias for the Codex provider because ReqLLM's OpenAI provider reports the
  # same OAuth id (`openai-codex`).
  @type oauth_provider :: :openai_codex | :anthropic

  @doc """
  Returns the ReqLLM OAuth provider id for a provider atom, or `nil` when the
  provider has no OAuth credential of its own.

  `:openai` is accepted as an alias for `:openai_codex` (ReqLLM's OpenAI
  provider reports the `"openai-codex"` OAuth id).
  """
  @spec oauth_provider_id(atom()) :: String.t() | nil
  def oauth_provider_id(provider) when is_atom(provider) do
    Map.get(@oauth_provider_ids, normalize_provider(provider))
  end

  def oauth_provider_id(_provider), do: nil

  @doc false
  # Single normalization point for the `:openai` → `:openai_codex` alias.
  @spec normalize_provider(atom()) :: atom()
  def normalize_provider(:openai), do: :openai_codex
  def normalize_provider(provider), do: provider

  @doc """
  Returns the default managed OAuth file: `<config_dir>/auth.json`.

  The config directory is resolved through `EvoGit.Platform.config_dir/1`, so
  the per-process `:config_dir_fun` test seam is honoured.
  """
  @spec default_oauth_file() :: String.t()
  def default_oauth_file do
    Path.join(EvoGit.Platform.config_dir("genesis"), "auth.json")
  end

  @doc """
  Returns the managed OAuth file path to use.

  Precedence:

    1. `opts[:oauth_file]` when it is a non-empty binary (a leading `~` is
       expanded against the user's home directory) — callers resolve it from
       the `[[llm.providers]]` account profile they are running, via
       `EvoGit.Config.Schema.LLM.oauth_file_for/1`
    2. `default_oauth_file/0`

  A provider account profile may point at its own file through its `oauth_file` setting;
  this function never reads the user config itself, so the path always comes
  from the caller's explicit argument.
  """
  @spec oauth_file(keyword()) :: String.t()
  def oauth_file(opts \\ [])

  def oauth_file(opts) when is_list(opts) do
    case expand_path(Keyword.get(opts, :oauth_file)) do
      nil -> default_oauth_file()
      path -> path
    end
  end

  def oauth_file(_opts), do: default_oauth_file()

  @doc """
  Ensures usable credentials exist for `provider`, importing vendor CLI
  credentials when appropriate.

  The import (`EvoGit.Auth.OAuthImport.import/2`) is attempted first — it is
  cheap (`File.stat/1` + two small `File.read/1` calls, no network and no
  process spawning) and it never clobbers credentials that ReqLLM has since
  rotated. The result is then judged for usability:

    * `:ok` — the managed entry has an access token, or a refresh token ReqLLM
      can exchange (an expired access token WITH a refresh token is usable)
    * `:ok` — no managed entry, but a provider env token is set
      (`EvoGit.Auth.OAuthImport.env_token/1`)
    * `{:error, :no_credentials}` — nothing available (no vendor login, no env
      token, no managed entry)
    * `{:error, {:managed_file_unwritable, reason}}` — a vendor login WAS found,
      but the managed copy could not be written or its path is unusable;
      `reason` is the underlying POSIX reason (e.g. `:erofs` on a read-only home,
      `:enotdir` for a bad `oauth_file`) — see `managed_file_unwritable_remedy/2`
    * `{:error, :invalid_credentials}` / `{:error, :expired_credentials}` — the
      managed entry itself cannot be used

  Fully fault-isolated: any raise/exit becomes `{:error, reason}`.
  """
  @spec ensure_credentials(atom(), keyword()) :: :ok | {:error, term()}
  def ensure_credentials(provider, opts \\ [])

  def ensure_credentials(provider, opts) when is_list(opts) do
    # KEPT (justified): this is the designated fault-isolation boundary. The
    # function runs on the hot provider-option path, so a corrupt vendor file,
    # an unwritable config dir or a broken managed JSON must surface as an
    # error tuple instead of taking the calling agent down.
    try do
      case OAuthImport.managed_file_failure_reason(OAuthImport.import(provider, opts)) do
        nil -> usable_credentials(provider, opts)
        reason -> prefer_import_failure(usable_credentials(provider, opts), reason)
      end
    rescue
      error -> {:error, {:credential_check_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:credential_check_failed, {kind, reason}}}
    end
  end

  def ensure_credentials(_provider, _opts), do: {:error, :invalid_options}

  @doc """
  Reports the managed credential entry for `provider` WITHOUT importing.

  Returns `{:ok, %{expires: ms_epoch | nil, account_id: String.t() | nil}}` for
  an entry that carries at least an access or a refresh token, and
  `{:error, :no_credentials}` when there is no entry at all.

  When the managed file has no entry, a provider env token
  (`EvoGit.Auth.OAuthImport.env_token/1`) is reported instead — that is the
  lowest-priority fallback and is never written to the managed file.
  `{:error, :invalid_credentials}` covers an unreadable/broken managed file and
  entries with neither an access nor a refresh token.

  `opts[:managed_file_error]` is the POSIX reason of an already-attempted
  import that could not write the managed copy (as reported by
  `OAuthImport.managed_file_failure_reason/1`). When the managed entry is
  nevertheless unusable, that failure is reported as
  `{:error, {:managed_file_unwritable, reason}}` — it is the actionable cause —
  while a usable (`{:ok, _}`) entry keeps its own answer.

  `expires` is always reported in milliseconds since the Unix epoch, mirroring
  ReqLLM's own normalization (values below 10_000_000_000 are treated as
  seconds).
  """
  @spec credential_status(atom(), keyword()) ::
          {:ok, %{expires: integer() | nil, account_id: String.t() | nil}}
          | {:error, :no_credentials | :invalid_credentials}
          | {:error, {:managed_file_unwritable, term()}}
  def credential_status(provider, opts \\ [])

  def credential_status(provider, opts) when is_list(opts) do
    status =
      case managed_entry(provider, oauth_file(opts)) do
        {:ok, entry} -> {:ok, project_entry(entry)}
        {:error, :no_credentials} -> env_status(provider)
        {:error, reason} -> {:error, reason}
      end

    case Keyword.get(opts, :managed_file_error) do
      nil -> status
      reason -> prefer_import_failure(status, reason)
    end
  end

  def credential_status(_provider, _opts), do: {:error, :no_credentials}

  @doc """
  Returns the one-time login guidance for humans (CLI wizard, dashboard health
  messages).

  Each message is short, names the exact command and file, and never contains a
  token. For an unsupported provider a neutral message is returned.

  `login_instructions(provider, credential_error)` appends
  `managed_file_unwritable_remedy/2` when the error is
  `{:error, {:managed_file_unwritable, _}}` — i.e. when the sibling `/1` text
  would be wrong advice (the login already exists). Every other error yields the
  unchanged `/1` text.
  """
  @spec login_instructions(atom(), term()) :: String.t()
  def login_instructions(provider, credential_error \\ nil)

  def login_instructions(provider, nil) do
    case normalize_provider(provider) do
      :openai_codex ->
        """
        Run `codex login` once in a terminal — it writes ~/.codex/auth.json.
        Genesis imports those credentials on the next run, so no token needs to be copied here.\
        """

      :anthropic ->
        """
        Run `claude` and log in once — it writes ~/.claude/.credentials.json.
        Alternatively run `claude setup-token` and export CLAUDE_CODE_OAUTH_TOKEN.
        Genesis imports the file credentials on the next run.\
        """

      _other ->
        "No OAuth login instructions are available for #{inspect(provider)}."
    end
  end

  def login_instructions(provider, credential_error) do
    base = login_instructions(provider, nil)

    case managed_file_unwritable_remedy(credential_error) do
      nil -> base
      remedy -> base <> "\n\n" <> remedy
    end
  end

  @doc """
  Returns the actionable remedy for a managed-OAuth-file failure: the file, the
  cause and the profile setting that fixes it.

  `{:managed_file_unwritable, reason}` (as returned by `ensure_credentials/2`,
  `credential_status/2` and `EvoGit.Config.Schema.LLM.oauth_credential_status/1`)
  yields a multi-line remedy naming `path` (default `oauth_file([])`) and the
  POSIX cause; any other term yields `nil`. Never contains token contents.
  """
  @spec managed_file_unwritable_remedy(term(), String.t() | nil) :: String.t() | nil
  def managed_file_unwritable_remedy(credential_error, path \\ nil)

  # Accepts both the error tuple the credential functions return and the bare
  # outcome, so callers can pass either through unchanged.
  def managed_file_unwritable_remedy({:error, credential_error}, path) do
    managed_file_unwritable_remedy(credential_error, path)
  end

  def managed_file_unwritable_remedy({:managed_file_unwritable, reason}, path) do
    path = path || oauth_file([])

    """
    Genesis found the subscription login but could not write its managed OAuth file
    (#{path}): #{describe_reason(reason)}.
    Remedy: set the OAuth profile's oauth_file to a writable location, e.g.
    oauth_file = "~/.config/genesis/auth.json" inside the relevant [[llm.providers]] account profile
    under a writable home — running the vendor login again will not help.\
    """
  end

  def managed_file_unwritable_remedy(_credential_error, _path), do: nil

  ## OAuth file resolution

  defp expand_path(value) do
    case OAuthImport.non_empty_string(value) do
      nil -> nil
      path -> expand_home(path)
    end
  end

  # `Path.expand/1` resolves `~` against the user's home directory. Pre-checking
  # the home dir keeps the no-home case from raising inside `Path.expand/1`.
  defp expand_home("~" <> _rest = path) do
    case System.user_home() do
      nil -> path
      _home -> Path.expand(path)
    end
  end

  defp expand_home(path), do: Path.expand(path)

  ## Credential state

  # A managed-file failure outranks the residual "nothing usable" verdict,
  # because it IS the actionable cause: the vendor login exists, Genesis just
  # could not persist it. A usable entry (`:ok` / `{:ok, _}`) and an entry that
  # was READ fine but has expired (`:expired_credentials`) keep their own
  # meaning — the write failure is not what stops them from working.
  defp prefer_import_failure(:ok, _reason), do: :ok
  defp prefer_import_failure({:ok, _status} = status, _reason), do: status
  defp prefer_import_failure({:error, :expired_credentials} = error, _reason), do: error

  defp prefer_import_failure({:error, _other}, reason),
    do: {:error, {:managed_file_unwritable, reason}}

  # Human wording for the POSIX reasons a managed-file write actually hits on
  # the supported platforms; anything else is shown verbatim. Never a token.
  defp describe_reason(:erofs), do: "read-only file system (:erofs)"
  defp describe_reason(:eacces), do: "permission denied (:eacces)"
  defp describe_reason(:enotdir), do: "a path component is not a directory (:enotdir)"
  defp describe_reason(:enospc), do: "no space left on device (:enospc)"
  defp describe_reason(:eisdir), do: "the path is a directory (:eisdir)"
  defp describe_reason(:enametoolong), do: "file name too long (:enametoolong)"
  defp describe_reason(reason), do: inspect(reason)

  defp usable_credentials(provider, opts) do
    case managed_entry(provider, oauth_file(opts)) do
      {:ok, entry} -> entry_usability(entry)
      {:error, :no_credentials} -> env_usability(provider)
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry_usability(entry) do
    access = entry_string(entry, ["access", "access_token"])
    refresh = entry_string(entry, ["refresh", "refresh_token"])
    expires = expiry_ms(OAuthImport.entry_field(entry, ["expires", "expires_at"]))

    cond do
      is_nil(access) and is_nil(refresh) -> {:error, :invalid_credentials}
      # ReqLLM exchanges a refresh token for a new access token, so an entry
      # carrying one is usable even when the access token has expired.
      not is_nil(refresh) -> :ok
      expired?(expires) -> {:error, :expired_credentials}
      true -> :ok
    end
  end

  defp env_usability(provider) do
    case OAuthImport.env_token(provider) do
      nil -> {:error, :no_credentials}
      _token -> :ok
    end
  end

  defp env_status(provider) do
    case OAuthImport.env_token(provider) do
      nil -> {:error, :no_credentials}
      token -> {:ok, %{expires: OAuthImport.jwt_expires_at(token), account_id: nil}}
    end
  end

  defp managed_entry(provider, path) do
    case oauth_provider_id(provider) do
      nil -> {:error, :no_credentials}
      key -> managed_entry_for_key(path, key)
    end
  end

  defp managed_entry_for_key(path, key) do
    case read_managed_payload(path) do
      {:ok, payload} ->
        case Map.get(payload, key) do
          nil -> {:error, :no_credentials}
          %{} = entry -> validate_entry(entry)
          _other -> {:error, :invalid_credentials}
        end

      {:error, :no_credentials} ->
        {:error, :no_credentials}

      {:error, _reason} ->
        {:error, :invalid_credentials}
    end
  end

  defp read_managed_payload(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = payload} -> {:ok, payload}
          _other -> {:error, :invalid_json}
        end

      {:error, :enoent} ->
        {:error, :no_credentials}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp validate_entry(entry) do
    if is_nil(entry_string(entry, ["access", "access_token"])) and
         is_nil(entry_string(entry, ["refresh", "refresh_token"])) do
      {:error, :invalid_credentials}
    else
      {:ok, entry}
    end
  end

  defp project_entry(entry) do
    %{
      expires: expiry_ms(OAuthImport.entry_field(entry, ["expires", "expires_at"])),
      account_id: entry_string(entry, ["accountId", "account_id"])
    }
  end

  # Mirrors ReqLLM's expiry normalization: a value below 10_000_000_000 is
  # epoch SECONDS and is multiplied by 1000, anything larger is already ms.
  defp expiry_ms(value) when is_integer(value) and value > 0 and value < 10_000_000_000 do
    value * 1000
  end

  defp expiry_ms(value) when is_integer(value) and value > 0, do: value
  defp expiry_ms(value) when is_float(value) and value > 0, do: expiry_ms(round(value))

  defp expiry_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> expiry_ms(integer)
      _other -> nil
    end
  end

  defp expiry_ms(_value), do: nil

  defp expired?(nil), do: false

  defp expired?(expires_ms) when is_integer(expires_ms),
    do: System.system_time(:millisecond) >= expires_ms

  defp entry_string(map, keys) do
    OAuthImport.entry_field(map, keys) |> OAuthImport.non_empty_string()
  end
end
