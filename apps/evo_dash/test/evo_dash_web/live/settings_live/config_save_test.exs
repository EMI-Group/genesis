# `EvoDashWeb.SettingsLive.ConfigSave` — receipt semantics of the owned
# whole-file save.
#
# The regression pinned here is the FULL-SUITE flake in
# `settings_live/auth_status_test.exs`: the shared write path
# (`RemoteAPI.save_user_config/1`) writes the file and THEN reloads the
# process-global `EvoGit.AgentScheduler` with a default 5 s `GenServer.call`, so
# under a saturated async cohort the reload times out and `SafeCall` reports
# `{:error, {:exit, {:timeout, ...}}}` AFTER a successful disk write. The page
# flashed "Failed to save configuration" for a save that HAD landed.
#
# `ConfigSave.save/3` now decides by the authoritative read: the written
# candidate on disk is a SAVED receipt; the previous config (a genuine
# validation/write failure) keeps the writer's reason as the failure.
#
# ASYNC by default: every test either injects both callbacks (no global state)
# or isolates the config directory through the `:config_dir_fun` seam.
defmodule EvoDashWeb.SettingsLive.ConfigSaveTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsLive.{ConfigIO, ConfigSave, PageState}

  # The exact failure shape observed in the flake: a default-5s scheduler call
  # timing out inside the write's best-effort reload.
  @unacknowledged {:exit,
                   {:timeout,
                    {:gen_server, :call,
                     [
                       EvoGit.AgentScheduler,
                       {:update_config, [default_llm_max_concurrency: 3]},
                       5000
                     ]}}}

  @success_msg "Provider profile saved."

  @candidate %{
    llm: %{
      default_provider_profile: "profile-1",
      providers: [
        %{
          "id" => "profile-1",
          "provider" => "anthropic",
          "default_model" => "claude-opus-5-5",
          "auth_mode" => "oauth",
          "models" => [%{"model" => "claude-opus-5-5"}]
        },
        %{
          "id" => "profile-2",
          "provider" => "deepseek",
          "default_model" => "deepseek-v4-pro",
          "models" => [%{"model" => "deepseek-v4-pro"}]
        }
      ]
    }
  }

  @previous_config %{llm: %{default_provider_profile: nil, providers: []}}

  # The recorded identity a page mounted before a runtime distribution change
  # still carries.
  @stale_node :stale_local@host

  test "an unacknowledged write proven by the authoritative read is a SAVED receipt" do
    socket = socket()

    socket =
      start(socket, @candidate,
        writer: fn _node, _candidate -> {:error, @unacknowledged} end,
        reader: fn _node -> {:ok, @candidate} end
      )

    assert {:saved, receipt, socket} = complete(socket)

    assert receipt.success_msg == @success_msg
    assert receipt.runtime? == true
    assert receipt.scope == {nil, node()}
    # The read matched the written candidate: nothing to warn about — the
    # persisted file is exactly what the user asked for.
    assert receipt.warnings == []
    # The authoritative read is what the page applies (same as the
    # acknowledged-write path).
    assert receipt.file_config == @candidate
    assert socket.assigns.config_saving == false
    assert socket.assigns.config_save_request == nil
  end

  test "an unacknowledged write whose read still shows the previous config FAILS with the writer reason" do
    socket = socket()

    socket =
      start(socket, @candidate,
        writer: fn _node, _candidate -> {:error, @unacknowledged} end,
        reader: fn _node -> {:ok, @previous_config} end
      )

    assert {:failed, receipt, socket} = complete(socket)

    # The timeout is NOT swallowed: it is the reason the user sees, and no
    # configuration is applied optimistically.
    assert receipt.reason == @unacknowledged
    refute Map.has_key?(receipt, :file_config)
    assert socket.assigns.config_saving == false
    assert socket.assigns.config_save_request == nil
  end

  test "a rejected write value keeps its validation reason when the read shows no change" do
    errors = [%{key_path: [:llm], message: ~s(default_model must be one of [], got "renamed")}]
    socket = socket()

    socket =
      start(socket, @candidate,
        writer: fn _node, _candidate -> {:error, errors} end,
        reader: fn _node -> {:ok, @previous_config} end
      )

    assert {:failed, receipt, _socket} = complete(socket)
    assert receipt.reason == errors
  end

  test "an acknowledged write still reports SAVED when the follow-up read fails" do
    socket = socket()

    socket =
      start(socket, @candidate,
        writer: fn _node, _candidate -> :ok end,
        reader: fn _node -> {:error, :config_unavailable} end
      )

    assert {:saved, receipt, _socket} = complete(socket)
    assert receipt.warnings == [{:config_reload, :config_unavailable}]
    # A failed read falls back to the canonical candidate that was written.
    assert receipt.file_config == ConfigIO.canonicalize_file_config(@candidate)
  end

  # The REAL write path, end to end: the file is written by the core's own
  # `save_user_config/1` and only the acknowledgement is lost. This pins that
  # verification compares what persistence can actually preserve — a legacy
  # `[[llm.models]]` fixture reads back in its migrated canonical shape, which
  # is NOT byte-equal to the in-memory candidate.
  test "a real legacy fixture write verified through the read is SAVED despite a lost acknowledgement" do
    EvoDash.Test.ConfigDir.isolate!("evogit_config_save_test-#{System.pid()}")

    path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    [[llm.models]]
    id = "profile-1"
    model = "anthropic:claude-opus-5-5"
    concurrency = 3
    """)

    candidate = ConfigIO.canonicalize_file_config(EvoGit.Config.resolve())
    assert :ok = EvoGit.Config.save_user_config(candidate)

    # The write landed, but its scheduler reload timed out.
    socket = socket()

    socket =
      start(socket, candidate,
        writer: fn _node, _candidate -> {:error, @unacknowledged} end,
        reader: fn _node -> {:ok, ConfigIO.load_file_config()} end
      )

    assert {:saved, receipt, _socket} = complete(socket)
    assert receipt.warnings == []
    # The read is authoritative for the applied configuration: it is the
    # persisted canonical account, not the pre-save migrated shape.
    assert [persisted] = receipt.file_config[:llm][:providers]
    assert persisted["id"] == "profile-1"
    assert persisted["default_model"] == "claude-opus-5-5"
  end

  describe "a genuinely unwritten candidate" do
    test "fails even when the candidate is canonically normalized on both sides" do
      socket = socket()
      # The previous config differs only inside a canonical provider, i.e. not
      # on any persistence mirror dropped by the verification projection.
      stale = put_in(@candidate, [:llm, :providers, Access.at(0), "default_model"], "old-model")

      socket =
        start(socket, @candidate,
          writer: fn _node, _candidate -> {:error, @unacknowledged} end,
          reader: fn _node -> {:ok, stale} end
        )

      assert {:failed, receipt, _socket} = complete(socket)
      assert receipt.reason == @unacknowledged
    end
  end

  # A LOCAL context (`current_node_id == nil`) whose recorded `current_node` no
  # longer names this BEAM: the VM's distribution identity started/stopped while
  # the page was mounted, so every scope the page keyed is stale.
  describe "a stale LOCAL node identity" do
    test "refuses the save with ONE warning naming both identities and never writes" do
      test_pid = self()
      socket = stale_local_socket()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:rejected, :node_identity_changed, refused} =
                   ConfigSave.start(
                     socket,
                     @candidate,
                     @success_msg,
                     writer: fn node, _candidate ->
                       send(test_pid, {:writer_called, node})
                       :ok
                     end,
                     reader: fn node ->
                       send(test_pid, {:reader_called, node})
                       {:ok, @candidate}
                     end
                   )

          # A rejected start is a strict no-op on the socket.
          assert refused.assigns == socket.assigns
        end)

      # Nothing reached the injected writer OR the authoritative read: no
      # foreign-node write, no erpc probe.
      refute_received {:writer_called, _node}
      refute_received {:reader_called, _node}

      # The ONE log line names the recorded and the live identity.
      assert log =~ inspect(@stale_node)
      assert log =~ inspect(node())
    end

    test "an in-flight receipt from the pre-flip scope settles stale, never failed" do
      token = make_ref()
      pre_flip_scope = {nil, @stale_node}

      socket =
        local_socket(
          config_save_request: %{
            token: token,
            scope: pre_flip_scope,
            candidate: @candidate,
            success_msg: @success_msg,
            runtime?: true,
            editor_token: nil
          },
          config_saving: true
        )

      assert {:stale, stale_socket} =
               ConfigSave.complete(
                 socket,
                 {{:settings_config_saved, token, pre_flip_scope},
                  {:ok, {:saved, @candidate, []}}}
               )

      # A strict no-op: nothing applied, the ownership guard still held.
      assert stale_socket.assigns == socket.assigns
      assert stale_socket.assigns.config_saving == true
      assert stale_socket.assigns.config_save_request.token == token
    end

    test "the same receipt for the LIVE identity settles saved" do
      token = make_ref()

      socket =
        local_socket(
          config_save_request: %{
            token: token,
            scope: {nil, node()},
            candidate: @candidate,
            success_msg: @success_msg,
            runtime?: true,
            editor_token: nil
          },
          config_saving: true
        )

      assert {:saved, receipt, saved_socket} =
               ConfigSave.complete(
                 socket,
                 {{:settings_config_saved, token, {nil, node()}}, {:ok, {:saved, @candidate, []}}}
               )

      assert receipt.scope == {nil, node()}
      assert receipt.file_config == @candidate
      assert saved_socket.assigns.config_saving == false
      assert saved_socket.assigns.config_save_request == nil
    end

    test "a remote target is unaffected: writer and reader both get the remote node" do
      test_pid = self()

      socket =
        socket(
          current_node_id: "target-1",
          current_node: :remote@host,
          remote_status: %{phase: :connected}
        )

      socket =
        start(socket, @candidate,
          writer: fn node, _candidate ->
            send(test_pid, {:writer_called, node})
            :ok
          end,
          reader: fn node ->
            send(test_pid, {:reader_called, node})
            {:ok, @candidate}
          end
        )

      assert_receive {:writer_called, :remote@host}, 5_000
      assert_receive {:reader_called, :remote@host}, 5_000

      assert {:saved, receipt, _socket} = complete(socket)
      assert receipt.scope == {"target-1", :remote@host}
    end

    test "pending_scope?/1 still refuses a not-yet-connected target" do
      socket =
        socket(current_node_id: "target-1", current_node: node(), remote_status: nil)

      assert {:rejected, :remote_not_connected, _socket} =
               ConfigSave.start(socket, @candidate, @success_msg)
    end

    test "ONE derivation: scope/1, test_config_scope/1 and target_node/1 agree" do
      stale = stale_local_socket()
      assert ConfigSave.scope(stale) == {nil, node()}
      assert PageState.test_config_scope(stale) == {nil, node()}
      assert PageState.target_node(stale) == node()
      assert ConfigSave.node_identity_changed?(stale)

      live = socket()
      assert ConfigSave.scope(live) == {nil, node()}
      assert PageState.target_node(live) == node()
      refute ConfigSave.node_identity_changed?(live)

      # A remote context keeps its recorded BEAM-node alias and never reads as
      # a stale local identity, however the alias compares to `node()`.
      remote =
        socket(
          current_node_id: "target-1",
          current_node: :remote@host,
          remote_status: %{phase: :connected}
        )

      assert ConfigSave.scope(remote) == {"target-1", :remote@host}
      assert PageState.target_node(remote) == :remote@host
      refute ConfigSave.node_identity_changed?(remote)
    end
  end

  defp start(socket, candidate, opts) do
    assert {:started, socket} = ConfigSave.start(socket, candidate, @success_msg, opts)
    socket
  end

  defp complete(socket) do
    assert_receive {{:settings_config_saved, _token, _scope}, _result} = message,
                   5_000,
                   "config save worker never reported its receipt"

    ConfigSave.complete(socket, message)
  end

  defp socket(overrides \\ []) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{__changed__: nil, flash: %{}, current_node: node(), current_node_id: nil},
          Map.new(overrides)
        )
    }
  end

  # The recorded identity a page mounted before a runtime distribution change
  # still carries, together with the scope marker minted against it.
  defp stale_local_socket,
    do: socket(current_node: @stale_node, config_loaded_scope: {nil, @stale_node})

  defp local_socket(overrides),
    do: socket(Keyword.put(overrides, :current_node, node()))
end
