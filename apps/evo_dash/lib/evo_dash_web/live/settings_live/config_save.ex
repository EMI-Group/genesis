defmodule EvoDashWeb.SettingsLive.ConfigSave do
  @moduledoc """
  Owned, non-optimistic whole-file saves for SettingsLive.

  `start/4` returns `{:started, socket}`, `{:rejected, reason, socket}` or
  `{:failed, reason, socket}` (supervisor startup failure). Route the complete
  SafeCall message to `complete/2`; it returns `{:saved, receipt, socket}`,
  `{:failed, receipt, socket}` or `{:stale, original_socket}`. A receipt contains
  `scope`, `success_msg` and `runtime?`, plus `file_config`/`warnings` on success
  or `reason` on failure. Only a confirmed write — acknowledged by the writer OR
  proven by the authoritative read returning the written candidate — produces a
  saved receipt.

  This module owns `config_save_request`, `config_save_owner` and the shared
  `config_saving` indicator. It never assigns `file_config`, test configuration,
  status, errors or flashes. The parent applies a saved receipt's file_config
  through its authoritative config/test-selection boundary, performs status and
  OAuth refreshes, and presents success or failure. Warnings are tagged
  `{:config_reload, reason}`; the saved candidate is the fallback on read failure.

  A writer error is NOT proof of a failed save. The shared write path persists
  the file BEFORE its best-effort scheduler reload, so a reload timeout/exit can
  fail the acknowledgement of a completed write. The authoritative read decides:
  a config matching the written candidate is a saved receipt (no warning — the
  file is exactly what was requested), while the previous config keeps the
  writer's reason as the failure. The runtime push is deliberately NOT duplicated
  here: a saved receipt still carries `runtime?`, and the parent performs the one
  best-effort push after the receipt lands, so a save converges even when the
  writer's own reload timed out.

  Pass `editor_token: token` EXPLICITLY only from provider editor Save/Delete.
  Do not infer it from the socket in a generic persistence wrapper: category,
  search, reset, Quick Setup, reorder and default saves must not close an editor.
  ModelProfileEvents callbacks themselves reject tokens from newer edits.

  For a selected target resolving to the local BEAM, the parent must provide
  the current target's authoritative `remote_status` map (as NodeAware does).
  Only `%{phase: :connected}` admits such an alias; missing or non-connected
  status is pending and must never fall through to a local write. Connection
  status must be refreshed with target changes, not carried from an old target.

  Call `invalidate/1` BEFORE replacing a node/target's page state. It detaches
  presentation ownership but retains the live worker guard, so a scope round
  trip cannot revive the old completion or start a concurrent write. A stale
  completion is a strict no-op, including loading and flash state. After an
  invalidated worker exits, the next start can acquire ownership without a
  special drain message. Never reset these ownership assigns in node loaders.

  Ownership is per LiveView, not a distributed file lock. Navigation/remount,
  other tabs/processes and timed-out remote calls can outlive this owner; tokens
  cannot cancel or order those whole-file writes. Avoid navigation while busy
  and reload authoritative config before building a new candidate after a
  scope change. Cross-page serialization/conflict detection requires a core
  persistence API, not resetting a token here. The existing NodeContext write
  also reloads the scheduler internally: an exception there can occur AFTER
  disk persistence but before acknowledgement, so an unacknowledged write is
  not proof that the file was unchanged.
  """

  import Phoenix.Component, only: [assign: 2]

  require Logger

  alias EvoDash.{NodeContext, SafeCall}
  alias EvoDashWeb.SettingsLive.{ConfigIO, ModelProfileEvents}

  @doc "The full target identity, including connection aliases of a BEAM node."
  def scope(socket),
    do: {socket.assigns[:current_node_id], socket.assigns[:current_node] || node()}

  @doc "True while this socket owns an unsettled request or an invalidated live worker."
  def busy?(socket) do
    not is_nil(socket.assigns[:config_save_request]) or
      live_owner?(socket.assigns[:config_save_owner]) or
      socket.assigns[:config_saving] == true
  end

  @doc """
  Starts one scoped save without changing rendered configuration.

  Options are `:editor_token` (default nil), `:runtime?` (default true), and
  per-call test seams `:supervisor`, `:writer` (node, canonical_config -> :ok |
  {:error, reason}), `:reader` (node -> {:ok, config} | {:error, reason}).
  Production uses NodeContext for the write and ConfigIO/local or NodeContext/
  remote for the authoritative read, each guarded separately by SafeCall.
  A rejected start settles only the explicitly supplied editor token; it never
  changes the existing request, configuration, loading indicator or flashes.
  """
  def start(socket, candidate, success_msg, opts \\ []) do
    editor_token = Keyword.get(opts, :editor_token)

    cond do
      busy?(socket) ->
        reject(socket, :save_in_progress, editor_token)

      pending_scope?(socket) ->
        reject(socket, :remote_not_connected, editor_token)

      true ->
        request = %{
          token: make_ref(),
          scope: scope(socket),
          candidate: ConfigIO.canonicalize_file_config(candidate),
          success_msg: success_msg,
          runtime?: Keyword.get(opts, :runtime?, true),
          editor_token: editor_token
        }

        launch(socket, request, opts)
    end
  end

  @doc """
  Detaches UI ownership without cancelling the writer or releasing its guard.

  The parent may reset other scope-specific page state afterwards, but must
  preserve config_save_owner. Do not manually clear config_saving to unlock
  saves: busy?/1 checks ownership independently of that presentation flag.
  """
  def invalidate(socket) do
    socket =
      case socket.assigns[:config_save_request] do
        %{editor_token: token} -> ModelProfileEvents.persistence_failed(socket, token)
        _ -> socket
      end

    assign(socket, config_save_request: nil, config_saving: false)
  end

  @doc "Accept a nested SafeCall result only for the currently owned request and scope."
  def complete(socket, {{:settings_config_saved, token, saved_scope}, result}) do
    case socket.assigns[:config_save_request] do
      %{token: ^token, scope: ^saved_scope} = request ->
        if scope(socket) == saved_scope do
          settle(socket, request, result)
        else
          {:stale, socket}
        end

      _ ->
        {:stale, socket}
    end
  end

  def complete(socket, _message), do: {:stale, socket}

  defp launch(socket, request, opts) do
    tag = {:settings_config_saved, request.token, request.scope}
    writer = Keyword.get(opts, :writer, &NodeContext.save_user_config/2)
    reader = Keyword.get(opts, :reader, &read_config/1)
    supervisor_opts = Keyword.take(opts, [:supervisor])

    case SafeCall.start(self(), tag, fn -> save(request, writer, reader) end, supervisor_opts) do
      {:ok, pid} ->
        {:started,
         assign(socket,
           config_save_request: request,
           config_save_owner: pid,
           config_saving: true
         )}

      {:error, reason} ->
        {:failed, {:startup, reason},
         ModelProfileEvents.persistence_failed(socket, request.editor_token)}
    end
  end

  # Guard write and read SEPARATELY: a failed read after :ok is still a saved
  # configuration, not a failed write. No status/presentation work runs here.
  defp save(request, writer, reader) do
    {_target_id, target_node} = request.scope

    case SafeCall.run(fn -> writer.(target_node, request.candidate) end) do
      {:ok, :ok} ->
        confirmed_save(request, reader, target_node)

      {:ok, {:error, reason}} ->
        unacknowledged_save(request, reader, target_node, reason)

      {:error, reason} ->
        unacknowledged_save(request, reader, target_node, reason)

      other ->
        {:failed, {:unexpected_write_result, other}}
    end
  end

  # The writer acknowledged the write, so the authoritative read only refines
  # the receipt: a failed read keeps the confirmed candidate with a warning.
  defp confirmed_save(request, reader, target_node) do
    case read(reader, target_node) do
      {:ok, %{} = config} -> {:saved, config, []}
      {:error, reason} -> saved_fallback(request, reason)
    end
  end

  # An unacknowledged write is NOT proof of a failed save: the shared write path
  # persists the file BEFORE its best-effort scheduler reload, so a reload
  # timeout/exit (e.g. the process-global scheduler saturated under load) fails
  # the acknowledgement of a write that already landed. The authoritative read
  # decides — the written candidate on disk means the save SUCCEEDED (no warning:
  # the persisted file is exactly what was requested), while the previous config
  # (a genuine validation/write failure) or an unreadable config keeps the
  # writer's reason as the failure. Nothing pushes runtime configuration here:
  # the receipt still carries `runtime?`, and the parent's single best-effort
  # push after the receipt lands is what converges the running scheduler.
  defp unacknowledged_save(request, reader, target_node, reason) do
    case read(reader, target_node) do
      {:ok, %{} = config} ->
        if candidate_written?(request.candidate, config) do
          Logger.warning(
            "Settings save was not acknowledged (#{inspect(reason)}), but the " <>
              "authoritative read matches the written configuration; treating it as saved."
          )

          {:saved, config, []}
        else
          {:failed, reason}
        end

      _unverifiable ->
        {:failed, reason}
    end
  end

  defp read(reader, target_node) do
    case SafeCall.run(fn -> reader.(target_node) end) do
      {:ok, {:ok, %{} = config}} -> {:ok, config}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_config_result, other}}
    end
  end

  defp read_config(target_node) when target_node == node(),
    do: {:ok, ConfigIO.load_file_config()}

  defp read_config(target_node), do: NodeContext.get_resolved_config(target_node)

  defp saved_fallback(request, reason),
    do: {:saved, request.candidate, [{:config_reload, reason}]}

  # The legacy flat `[llm]` mirrors/`models` inventory: `EvoGit.Config.save_user_config/1`
  # never persists them once canonical provider profiles exist, and TOML has no
  # null, so a resolved read can never deep-equal the in-memory candidate on
  # those keys even though the persisted configuration IS that candidate.
  @llm_persistence_mirror_keys ~w(model temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty models auth_mode oauth_file provider_options)

  # Does the authoritative read prove the candidate was persisted? Compare what
  # a TOML round trip can actually preserve, normalized the same way on both
  # sides (a canonical read of a legacy fixture differs from its migrated
  # in-memory candidate only on the persistence mirrors and null values).
  defp candidate_written?(candidate, read_config),
    do: persisted_projection(candidate) == persisted_projection(read_config)

  defp persisted_projection(config) do
    config
    |> ConfigIO.canonicalize_file_config()
    |> drop_llm_persistence_mirrors()
    |> drop_nils()
  end

  defp drop_llm_persistence_mirrors(%{llm: llm} = config) when is_map(llm),
    do: %{config | llm: drop_persistence_mirror_keys(llm)}

  defp drop_llm_persistence_mirrors(%{"llm" => llm} = config) when is_map(llm),
    do: %{config | "llm" => drop_persistence_mirror_keys(llm)}

  defp drop_llm_persistence_mirrors(config), do: config

  defp drop_persistence_mirror_keys(llm) do
    Enum.reject(llm, fn
      {key, _value} when is_atom(key) -> Atom.to_string(key) in @llm_persistence_mirror_keys
      {key, _value} when is_binary(key) -> key in @llm_persistence_mirror_keys
      _other -> false
    end)
    |> Map.new()
  end

  # TOML has no null: the writer drops nil-valued keys, so a persisted read can
  # never carry them back.
  defp drop_nils(%{} = map) when not is_struct(map) do
    for {key, value} <- map, not is_nil(value), into: %{}, do: {key, drop_nils(value)}
  end

  defp drop_nils(list) when is_list(list), do: Enum.map(list, &drop_nils/1)

  defp drop_nils(other), do: other

  defp settle(socket, request, result) do
    socket =
      assign(socket, config_save_request: nil, config_save_owner: nil, config_saving: false)

    receipt = Map.take(request, [:scope, :success_msg, :runtime?])

    case result do
      {:ok, {:saved, %{} = config, warnings}} ->
        {:saved, Map.merge(receipt, %{file_config: config, warnings: warnings}),
         ModelProfileEvents.persistence_succeeded(socket, request.editor_token)}

      {:ok, {:failed, reason}} ->
        failed(socket, request, receipt, reason)

      {:error, reason} ->
        failed(socket, request, receipt, reason)

      other ->
        failed(socket, request, receipt, {:unexpected_save_result, other})
    end
  end

  defp failed(socket, request, receipt, reason),
    do:
      {:failed, Map.put(receipt, :reason, reason),
       ModelProfileEvents.persistence_failed(socket, request.editor_token)}

  defp reject(socket, reason, editor_token),
    do: {:rejected, reason, ModelProfileEvents.persistence_failed(socket, editor_token)}

  defp pending_scope?(socket) do
    {target_id, target_node} = scope(socket)

    not is_nil(target_id) and target_node == node() and
      not match?(%{phase: :connected}, socket.assigns[:remote_status])
  end

  defp live_owner?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp live_owner?(_), do: false
end
