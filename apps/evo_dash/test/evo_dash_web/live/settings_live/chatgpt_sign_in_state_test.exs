# Pure/unit suite for `EvoDashWeb.SettingsLive.ChatGPTSignInState` — the ONE
# page-level state machine behind every in-browser Sign in with ChatGPT surface
# (the add-account wizard, an expanded account's detail form and its auth-status
# row).
#
# ASYNC: the state module is pure plumbing (no LiveView imports, no `self()`
# except the explicit owner argument, no I/O) and the flow module is the
# per-process `EvoDash.Test.ChatGPTLoginStub`, installed through the CALL-TIME
# `$callers` seam. Nothing here is BEAM-global.
defmodule EvoDashWeb.SettingsLive.ChatGPTSignInStateTest do
  use ExUnit.Case, async: true

  alias EvoDash.Test.ChatGPTLoginStub
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState

  @flow_id "flow-1"
  @flow_url "https://auth.openai.com/device"

  # A bounded, event-driven wait for the stub's poll to reach it. The stub's
  # poll interval is 5 ms; `assert_receive` is the wait mechanism (never a
  # fixed sleep).
  @receive_timeout_ms 2_000
  # The NEGATIVE window that IS the detection mechanism for "no poll started".
  # 100 ms is far beyond the stub's 5 ms poll interval, so a started poll would
  # certainly be observed.
  @no_poll_window_ms 100

  defp waiting_state(surface, flow_id \\ @flow_id) do
    %{
      surface: surface,
      flow_id: flow_id,
      url: @flow_url,
      phase: :waiting,
      reason: nil
    }
  end

  defp install!(begin_result, statuses \\ []) do
    ChatGPTLoginStub.install!(begin: begin_result, statuses: statuses)
  end

  describe "new/0 and defaults/0" do
    test "both answer the same idle state with no owning surface" do
      idle = %{surface: nil, flow_id: nil, url: nil, phase: :idle, reason: nil}

      assert ChatGPTSignInState.new() == idle
      assert ChatGPTSignInState.defaults() == idle
    end
  end

  describe "surface_from_params/1" do
    test "an absent surface is the wizard (the wizard DOM carries none)" do
      assert ChatGPTSignInState.surface_from_params(%{}) == :wizard
      assert ChatGPTSignInState.surface_from_params(nil) == :wizard
      assert ChatGPTSignInState.surface_from_params("garbage") == :wizard
    end

    test "a named detail/status surface carries its profile id" do
      assert ChatGPTSignInState.surface_from_params(%{
               "surface" => "detail",
               "profile_id" => "profile-1"
             }) == {:detail, "profile-1"}

      assert ChatGPTSignInState.surface_from_params(%{
               "surface" => "status",
               "profile_id" => "profile-2"
             }) == {:status, "profile-2"}
    end

    test "atom-keyed params are tolerated" do
      assert ChatGPTSignInState.surface_from_params(%{
               surface: "detail",
               profile_id: "profile-1"
             }) == {:detail, "profile-1"}
    end

    test "an integer id is stringified and a blank/absent one falls back to the wizard" do
      assert ChatGPTSignInState.surface_from_params(%{
               "surface" => "status",
               "profile_id" => 42
             }) == {:status, "42"}

      assert ChatGPTSignInState.surface_from_params(%{"surface" => "detail"}) == :wizard

      assert ChatGPTSignInState.surface_from_params(%{"surface" => "status", "profile_id" => " "}) ==
               :wizard
    end

    test "explicit wizard and unknown surfaces are both the wizard" do
      assert ChatGPTSignInState.surface_from_params(%{"surface" => "wizard"}) == :wizard
      assert ChatGPTSignInState.surface_from_params(%{"surface" => "nope"}) == :wizard
    end
  end

  describe "begin/4" do
    test "stores the surface, flow id and url and starts exactly ONE poll" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      state =
        ChatGPTSignInState.begin(
          ChatGPTSignInState.new(),
          "work",
          {:detail, "profile-1"},
          self()
        )

      assert state == %{
               surface: {:detail, "profile-1"},
               flow_id: @flow_id,
               url: @flow_url,
               phase: :waiting,
               reason: nil
             }

      assert_receive {:chatgpt_stub, :begin, "work"}, @receive_timeout_ms
      # The poll is running: its first status read reaches the stub.
      assert_receive {:chatgpt_stub, :status, @flow_id}, @receive_timeout_ms
      assert ChatGPTSignInState.waiting?(state)
      assert ChatGPTSignInState.flow_id(state) == @flow_id
      # Exactly one flow was started (one begin, never a second one).
      refute_receive {:chatgpt_stub, :begin, _account}, @no_poll_window_ms
    end

    test "a flow that cannot start answers the :error phase with its reason and NO poll" do
      install!({:error, :loopback_listener_unavailable})

      state = ChatGPTSignInState.begin(ChatGPTSignInState.new(), nil, :wizard, self())

      assert state.phase == :error
      assert state.reason == :loopback_listener_unavailable
      assert state.flow_id == nil
      assert state.url == nil
      refute ChatGPTSignInState.waiting?(state)

      assert_receive {:chatgpt_stub, :begin, _account}, @receive_timeout_ms
      # No poll may be started for a flow that never existed.
      refute_receive {:chatgpt_stub, :status, _flow_id}, @no_poll_window_ms
    end

    test "a second flow on ANY surface cancels the still-waiting first one" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      first =
        ChatGPTSignInState.begin(
          ChatGPTSignInState.new(),
          "work",
          {:detail, "profile-1"},
          self()
        )

      assert ChatGPTSignInState.waiting?(first)

      second =
        ChatGPTSignInState.begin(first, "work", {:status, "profile-1"}, self())

      # The first flow was abandoned — two live flows can never race.
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @receive_timeout_ms
      assert_receive {:chatgpt_stub, :begin, "work"}, @receive_timeout_ms
      assert second.surface == {:status, "profile-1"}
      assert second.phase == :waiting
      assert ChatGPTSignInState.waiting?(second)
    end

    test "without a poll owner the flow is reported unavailable instead of waiting forever" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      state = ChatGPTSignInState.begin(ChatGPTSignInState.new(), "work", :wizard, nil)

      assert state.phase == :error
      assert state.reason == :sign_in_unavailable
      assert state.flow_id == nil
      # No flow module call is even attempted without an owner.
      refute_receive {:chatgpt_stub, :begin, _account}, @no_poll_window_ms
    end
  end

  describe "apply_result/3" do
    test "a non-current flow id is stale and leaves a WAITING state untouched" do
      state = waiting_state({:detail, "profile-1"})

      assert ChatGPTSignInState.apply_result(state, "other-flow", {:ok, %{account: "a"}}) ==
               {:stale, state}

      assert ChatGPTSignInState.apply_result(state, nil, {:ok, %{account: "a"}}) ==
               {:stale, state}
    end

    test "a non-current flow id is stale for an idle and an :ok state too" do
      idle = ChatGPTSignInState.new()
      done = %{waiting_state(:wizard) | phase: :ok}

      assert ChatGPTSignInState.apply_result(idle, @flow_id, {:ok, %{account: "a"}}) ==
               {:stale, idle}

      assert ChatGPTSignInState.apply_result(done, "other-flow", {:error, :authorization_denied}) ==
               {:stale, done}
    end

    test "the current flow's success keeps the surface and answers the account" do
      state = waiting_state({:status, "profile-2"})

      assert {:ok, applied, "work"} =
               ChatGPTSignInState.apply_result(state, @flow_id, {:ok, %{account: "work"}})

      assert applied.phase == :ok
      assert applied.reason == nil
      assert applied.surface == {:status, "profile-2"}
      assert applied.flow_id == @flow_id
    end

    test "the current flow's failure answers the :error phase with its reason" do
      state = waiting_state(:wizard)

      assert {:error, applied, :authorization_denied} =
               ChatGPTSignInState.apply_result(
                 state,
                 @flow_id,
                 {:error, :authorization_denied}
               )

      assert applied.phase == :error
      assert applied.reason == :authorization_denied
    end

    test "an unexpected payload degrades to :sign_in_unavailable" do
      state = waiting_state(:wizard)

      for unexpected <- [
            {:ok, %{account: ""}},
            {:ok, %{}},
            {:ok, %{"account" => "work"}},
            :bogus,
            nil
          ] do
        assert {:error, applied, :sign_in_unavailable} =
                 ChatGPTSignInState.apply_result(state, @flow_id, unexpected)

        assert applied.phase == :error
        assert applied.reason == :sign_in_unavailable
      end
    end

    test "a non-map state is stale and never raises" do
      assert ChatGPTSignInState.apply_result(nil, @flow_id, {:ok, %{account: "a"}}) ==
               {:stale, nil}

      assert ChatGPTSignInState.apply_result(%{}, @flow_id, {:ok, %{account: "a"}}) ==
               {:stale, %{}}
    end
  end

  describe "cancel/1" do
    test "closes the live flow and answers the IDLE state of the SAME surface" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      state = waiting_state({:detail, "profile-1"})

      cancelled = ChatGPTSignInState.cancel(state)

      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @receive_timeout_ms

      assert cancelled == %{
               surface: {:detail, "profile-1"},
               flow_id: nil,
               url: nil,
               phase: :idle,
               reason: nil
             }
    end

    test "is quiet when nothing waits" do
      state = ChatGPTSignInState.new()

      assert ChatGPTSignInState.cancel(state) == state
      refute_receive {:chatgpt_stub, :cancel, _flow_id}, @no_poll_window_ms
    end

    test "is total for a non-map state" do
      assert ChatGPTSignInState.cancel(nil) == ChatGPTSignInState.new()
    end
  end

  describe "cancel_owned_by/2" do
    test "cancels only the owning surface and leaves another surface's flow intact" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      state = waiting_state({:detail, "profile-1"})

      # Another surface's dismissal is a no-op.
      assert ChatGPTSignInState.cancel_owned_by(state, {:status, "profile-1"}) == state
      assert ChatGPTSignInState.cancel_owned_by(state, {:detail, "profile-2"}) == state
      assert ChatGPTSignInState.cancel_owned_by(state, :wizard) == state
      refute_receive {:chatgpt_stub, :cancel, _flow_id}, @no_poll_window_ms

      # The owning surface's dismissal abandons the flow.
      owned = ChatGPTSignInState.cancel_owned_by(state, {:detail, "profile-1"})
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @receive_timeout_ms
      assert owned.phase == :idle
      assert owned.surface == {:detail, "profile-1"}
      refute ChatGPTSignInState.waiting?(owned)
    end

    test "is total for non-map states and unknown surfaces" do
      assert ChatGPTSignInState.cancel_owned_by(nil, :wizard) == nil

      assert ChatGPTSignInState.cancel_owned_by(ChatGPTSignInState.new(), :wizard) ==
               ChatGPTSignInState.new()
    end
  end

  describe "ownership and surface_state/2" do
    test "owned_by?/2 compares surfaces and never matches a nil/blank id" do
      state = waiting_state({:detail, "profile-1"})

      assert ChatGPTSignInState.owned_by?(state, {:detail, "profile-1"})
      assert ChatGPTSignInState.owned_by?(state, {:detail, :profile_1}) == false
      refute ChatGPTSignInState.owned_by?(state, {:status, "profile-1"})
      refute ChatGPTSignInState.owned_by?(ChatGPTSignInState.new(), :wizard)
      refute ChatGPTSignInState.owned_by?(nil, :wizard)
    end

    test "surface_state/2 delegates the ONE isolation rule" do
      state = waiting_state(:wizard)

      assert ChatGPTSignInState.surface_state(state, :wizard) == %{
               flow_id: @flow_id,
               url: @flow_url,
               phase: :waiting,
               reason: nil
             }

      assert ChatGPTSignInState.surface_state(state, {:detail, "profile-1"}) == %{}
    end

    test "surface/1 answers the owning surface and nil for none" do
      assert ChatGPTSignInState.surface(waiting_state({:detail, "profile-1"})) ==
               {:detail, "profile-1"}

      assert ChatGPTSignInState.surface(ChatGPTSignInState.new()) == nil
      assert ChatGPTSignInState.surface(nil) == nil
    end
  end

  describe "manual?/1" do
    test "a local viewed node needs a real in-browser sign-in" do
      refute ChatGPTSignInState.manual?(%{current_node: node(), current_node_id: nil})
      refute ChatGPTSignInState.manual?(%{})
      refute ChatGPTSignInState.manual?(nil)
    end

    test "a remote viewed node gets the CLI hint (connected OR still pending)" do
      assert ChatGPTSignInState.manual?(%{current_node: :"genesis_remote@127.0.0.1"})
      assert ChatGPTSignInState.manual?(%{current_node: node(), current_node_id: "remote-1"})
    end

    test "a socket-like assigns map is accepted" do
      assert ChatGPTSignInState.manual?(%{assigns: %{current_node: :"genesis_remote@127.0.0.1"}})
      refute ChatGPTSignInState.manual?(%{assigns: %{current_node: node(), current_node_id: nil}})
    end

    test "string-keyed and odd inputs are total" do
      refute ChatGPTSignInState.manual?(%{"current_node" => :"genesis_remote@127.0.0.1"})
      refute ChatGPTSignInState.manual?(%{assigns: %{"current_node_id" => "remote-1"}})
      refute ChatGPTSignInState.manual?(:bogus)
    end
  end

  describe "waiting?/1 and flow_id/1 totals" do
    test "only a waiting phase with a binary flow id counts as waiting" do
      assert ChatGPTSignInState.waiting?(waiting_state(:wizard))
      refute ChatGPTSignInState.waiting?(%{waiting_state(:wizard) | flow_id: nil})
      refute ChatGPTSignInState.waiting?(%{waiting_state(:wizard) | flow_id: ""})
      refute ChatGPTSignInState.waiting?(%{waiting_state(:wizard) | phase: :ok})
      refute ChatGPTSignInState.waiting?(nil)
    end

    test "flow_id/1 answers nil for a blank/absent id and for non-map states" do
      assert ChatGPTSignInState.flow_id(waiting_state(:wizard)) == @flow_id
      assert ChatGPTSignInState.flow_id(%{waiting_state(:wizard) | flow_id: ""}) == nil
      assert ChatGPTSignInState.flow_id(nil) == nil
    end
  end
end
