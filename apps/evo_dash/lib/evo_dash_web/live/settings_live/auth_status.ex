defmodule EvoDashWeb.SettingsLive.AuthStatus do
  @moduledoc """
  Async loader for the per-profile OAuth/subscription credential status shown by
  the Settings page's model-profiles editor.

  Only OAuth-enabled profiles (an explicit `auth_mode = "oauth"` or an
  OAuth-only provider such as `openai_codex`) produce an entry; every other
  profile is absent from the map, so the editor can tell "API key" apart from
  "subscription credential" without a second lookup.

  The status of one profile is `EvoGit.Config.Schema.LLM.oauth_credential_status/1`
  (which lazily imports the vendor CLI login first) plus the managed
  `EvoGit.Auth.oauth_file/1` path. Both run on the VIEWED node: a local socket
  calls them directly, a remote (`?node=`) socket reaches them through
  `EvoDash.NodeContext.call_remote/4`.

  Everything runs inside `EvoDash.SafeCall.run/1` in a supervised task and the
  result message is ALWAYS sent, so a dead/slow node can never wedge the page —
  the statuses degrade to `:unknown` instead. Tokens are never read, logged or
  rendered: only the state, the expiry, the account id and the file path.
  """

  alias EvoDash.SafeCall
  alias EvoGit.Config.Schema.LLM, as: LLMSchema
  alias EvoDashWeb.SettingsLive.ProviderProfiles

  @doc "Credential-only adapter for canonical provider profiles and legacy model profiles."
  def credential_profile(profile) when is_map(profile) do
    provider =
      profile_field(profile, :provider) ||
        case profile_field(profile, :model) do
          value when is_binary(value) -> value |> String.split(":", parts: 2) |> List.first()
          value when is_map(value) -> profile_field(value, :provider)
          _ -> nil
        end

    %{
      model: %{provider: ProviderProfiles.provider_atom(provider), id: "credential-status"},
      auth_mode: profile_field(profile, :auth_mode),
      oauth_file: profile_field(profile, :oauth_file)
    }
  end

  def credential_profile(_), do: %{}

  @doc """
  Spawns a supervised task computing `statuses/2` for the socket's viewed node
  and returns `:ok` (fire-and-forget).

  The task always sends `{:settings_auth_status_loaded, node, seq, statuses}`
  to the calling process (`seq` is the caller's `:auth_status_seq` captured
  before spawning, so an out-of-order result can be dropped). On any failure it
  sends `unknown_statuses(profiles)` instead, so every OAuth profile still has a
  neutral entry and the editor never renders a stale status.
  """
  @spec start(Phoenix.LiveView.Socket.t(), [map()]) :: :ok
  def start(socket, profiles) do
    parent = self()
    target_node = Map.get(socket.assigns, :current_node) || node()
    seq = Map.get(socket.assigns, :auth_status_seq, 0)

    _ =
      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        statuses =
          case SafeCall.run(fn -> statuses(profiles, target_node) end) do
            {:ok, %{} = loaded} -> loaded
            {:error, _reason} -> unknown_statuses(profiles)
            _other -> unknown_statuses(profiles)
          end

        send(parent, {:settings_auth_status_loaded, target_node, seq, statuses})
      end)

    :ok
  end

  @doc """
  Computes the OAuth credential status map for `profiles` on `node`:

      %{profile_id => %{state: :ok | :missing | :unknown | :unwritable,
                        expires: integer | nil, account_id: binary | nil,
                        login_instructions: binary | nil, oauth_file: binary | nil}}

  `:unwritable` is the "login found, managed file not writable" state — the
  vendor login was read and parsed fine, but Genesis could not write its own
  managed copy of it (read-only home, sandbox, container).

  Non-OAuth profiles produce NO entry. Profile maps may be atom- or
  string-keyed (the resolved config is atom-keyed).
  """
  @spec statuses([map()], node()) :: %{optional(String.t()) => map()}
  def statuses(profiles, target_node) when is_list(profiles) do
    Enum.reduce(profiles, %{}, fn profile, acc ->
      case oauth_profile_id(profile) do
        nil -> acc
        profile_id -> Map.put(acc, profile_id, status_for(profile, target_node))
      end
    end)
  end

  def statuses(_profiles, _target_node), do: %{}

  @doc """
  The neutral `:unknown` map for every OAuth-enabled profile — the degradation
  used when the status load itself failed (unreachable node, dead task, an
  older daemon without the core function).
  """
  @spec unknown_statuses([map()]) :: %{optional(String.t()) => map()}
  def unknown_statuses(profiles) when is_list(profiles) do
    Enum.reduce(profiles, %{}, fn profile, acc ->
      case oauth_profile_id(profile) do
        nil -> acc
        profile_id -> Map.put(acc, profile_id, unknown_entry())
      end
    end)
  end

  def unknown_statuses(_profiles), do: %{}

  # ───────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp unknown_entry do
    %{state: :unknown, expires: nil, account_id: nil, login_instructions: nil, oauth_file: nil}
  end

  # The profile id of an OAuth-enabled profile, or nil when the profile is not
  # OAuth-enabled / carries no usable id (such profiles get no entry at all).
  defp oauth_profile_id(profile) when is_map(profile) do
    with true <- LLMSchema.oauth_profile?(credential_profile(profile)),
         profile_id when is_binary(profile_id) and profile_id != "" <-
           profile_field(profile, :id) do
      profile_id
    else
      _other -> nil
    end
  end

  defp oauth_profile_id(_profile), do: nil

  # Builds one profile's entry. Reading the credential status is a plain core
  # read: it is fault-isolated there and the whole map is computed inside the
  # SafeCall boundary, so no per-profile rescue is needed. `login_instructions`
  # is static text and always resolves LOCALLY; `oauth_file` is nil unless the
  # node actually reported its credential state.
  defp status_for(profile, target_node) do
    entry = %{
      state: :unknown,
      expires: nil,
      account_id: nil,
      login_instructions: login_instructions_for(profile),
      oauth_file: nil
    }

    case credential_status(profile, target_node) do
      {:ok, verdict, oauth_file} ->
        %{
          entry
          | state: :ok,
            expires: Map.get(verdict, :expires),
            account_id: Map.get(verdict, :account_id),
            oauth_file: oauth_file
        }

      {:missing, oauth_file} ->
        %{entry | state: :missing, oauth_file: oauth_file}

      {:unwritable, oauth_file} ->
        %{entry | state: :unwritable, oauth_file: oauth_file}

      :unknown ->
        entry
    end
  end

  # Local node: direct calls. Remote node: the same two core functions over
  # `:erpc`, where the core's own `{:ok, _} | {:error, _}` verdict arrives
  # NESTED inside the transport tuple — unwrap the transport first. Any
  # transport error (including `:undef` for a daemon predating the function)
  # degrades to `:unknown` with no file path.
  defp credential_status(profile, target_node) do
    profile = credential_profile(profile)

    if target_node == node() do
      profile
      |> LLMSchema.oauth_credential_status()
      |> classify(oauth_file_path(profile))
    else
      verdict =
        EvoDash.NodeContext.call_remote(
          target_node,
          LLMSchema,
          :oauth_credential_status,
          [profile]
        )

      oauth_file =
        EvoDash.NodeContext.call_remote(
          target_node,
          EvoGit.Auth,
          :oauth_file,
          [[oauth_file: profile_field(profile, :oauth_file)]]
        )

      classify_remote(verdict, oauth_file)
    end
  end

  # Maps ONE core credential-status result plus the managed path to the state
  # `status_for/2` stores. `@doc false` + public only so the shape contract can
  # be pinned by tests — `statuses/2` is the real entry point.
  #
  # `{:error, {:managed_file_unwritable, reason}}` is matched ATOM-PRECISELY: it
  # means "the vendor login WAS found and parsed, but Genesis could not write
  # its managed copy", which is a different problem from a missing login. Every
  # other value (including an unknown future tuple, a non-map verdict, or an
  # older remote daemon's shape) stays on the `:unknown` path, which renders
  # neutral guidance with no verdict.
  @doc false
  @spec classify(term(), binary() | nil) ::
          {:ok, map(), binary() | nil}
          | {:missing, binary() | nil}
          | {:unwritable, binary() | nil}
          | :unknown
  def classify({:ok, verdict}, oauth_file) when is_map(verdict), do: {:ok, verdict, oauth_file}
  def classify({:error, :no_credentials}, oauth_file), do: {:missing, oauth_file}
  def classify({:error, :invalid_credentials}, oauth_file), do: {:missing, oauth_file}

  def classify({:error, {:managed_file_unwritable, _reason}}, oauth_file),
    do: {:unwritable, oauth_file}

  def classify(_other, _oauth_file), do: :unknown

  @doc false
  # The remote (`:erpc`) form of `classify/2`: the core's own verdict arrives
  # NESTED inside the transport tuple, so unwrap the transport first and then
  # classify exactly like a local call. Any transport error (`{:error, …}`,
  # including `:undef` for a daemon predating a shape) is `:unknown`.
  # `@doc false` + public only so the shape contract can be pinned by tests.
  @spec classify_remote(term(), term()) ::
          {:ok, map(), binary() | nil}
          | {:missing, binary() | nil}
          | {:unwritable, binary() | nil}
          | :unknown
  def classify_remote(verdict, oauth_file_result) do
    # The file path is informational: a failed path lookup never changes the
    # credential state, it just leaves `oauth_file` nil.
    oauth_file =
      case oauth_file_result do
        {:ok, path} when is_binary(path) -> path
        _other -> nil
      end

    # The core's own `{:ok, _} | {:error, _}` verdict arrives NESTED inside the
    # transport tuple (see the header comment above).
    case verdict do
      {:ok, result} -> classify(result, oauth_file)
      _other -> :unknown
    end
  end

  defp oauth_file_path(profile) do
    EvoGit.Auth.oauth_file(oauth_file: profile_field(profile, :oauth_file))
  end

  defp login_instructions_for(profile) do
    case LLMSchema.provider_from_model(credential_profile(profile).model) do
      nil -> nil
      provider -> EvoGit.Auth.login_instructions(provider)
    end
  end

  # Total atom-or-string key read — the resolved config is atom-keyed, TOML
  # drafts may still be string-keyed.
  defp profile_field(profile, key) when is_map(profile) do
    Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
  end

  defp profile_field(_profile, _key), do: nil
end
