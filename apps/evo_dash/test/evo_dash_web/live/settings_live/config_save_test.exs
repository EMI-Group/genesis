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

  alias EvoDashWeb.SettingsLive.{ConfigIO, ConfigSave}

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
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_config_save_test-#{System.pid()}")
    on_exit(fn -> File.rm_rf!(dir) end)

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

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: nil, flash: %{}, current_node: node(), current_node_id: nil}
    }
  end
end
