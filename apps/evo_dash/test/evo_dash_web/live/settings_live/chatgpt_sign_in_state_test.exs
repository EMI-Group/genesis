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

  require Phoenix.LiveViewTest

  alias EvoDash.Test.ChatGPTLoginStub
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState

  @flow_id "flow-1"
  @flow_url "https://auth.openai.com/device"

  # A bounded, event-driven wait for the stub's poll to reach it. The stub's
  # poll interval is 5 ms; `assert_receive` is the wait mechanism (never a
  # fixed sleep).
  @receive_timeout_ms 2_000

  # ── Negative proofs are STRUCTURAL, never a wall-clock window ─────────────
  #
  # Every `refute_receive …` below falls into one of two classes, and each
  # class has a deterministic fence instead of a sleep-length window:
  #
  #   * a `:begin` / `:cancel` notification is sent SYNCHRONOUSLY, from THIS
  #     process, inside the stub call the state module just made. Once the last
  #     such call has returned, this process' mailbox is COMPLETE: no other
  #     producer can ever add one, so a 0 ms mailbox scan is conclusive (the
  #     same "already drained at a synchronous fence" rule the picker suite
  #     uses). Those refutes are therefore `, 0`.
  #   * a `:status` notification comes from the ASYNCHRONOUS poll task that
  #     `ChatGPTSignIn.start_poll/2` starts. "No poll exists" is proven with
  #     `assert_no_poll/1`: the poll is a `EvoDash.TaskSupervisor` child whose
  #     `:"$callers"` starts with the process that started it, so an empty
  #     child set IS the fence — and with no poll alive, no status read can
  #     ever happen.
  defp assert_no_poll(owner) do
    assert poll_children(owner) == [],
           "a poll was started for #{inspect(owner)} but none was expected"
  end

  defp poll_children(owner) do
    EvoDash.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&(owner in callers(&1)))
  end

  defp callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", [])
      _ -> []
    end
  end

  defp waiting_state(surface, flow_id \\ @flow_id) do
    %{
      surface: surface,
      flow_id: flow_id,
      url: @flow_url,
      phase: :waiting,
      reason: nil,
      port: 48_123,
      mode: :loopback,
      paste: "",
      paste_error: nil
    }
  end

  defp install!(begin_result, statuses \\ [], opts \\ []) do
    ChatGPTLoginStub.install!([begin: begin_result, statuses: statuses] ++ opts)
  end

  # A hand-built socket for the page's event handlers: `assign/3` needs
  # `__changed__`, and `sync_sign_in_state/1` reads `:provider_wizard` and the
  # node assigns (absent = this local node, never `manual`).
  defp socket(state) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, chatgpt_sign_in: state, provider_wizard: nil}
    }
  end

  defp assign_state(socket), do: socket.assigns.chatgpt_sign_in

  defp render_panel(surface, profile_id, sign_in) do
    Phoenix.LiveViewTest.render_component(
      &EvoDashWeb.SettingsComponents.ChatGPTSignInPanel.sign_in_panel/1,
      id: "probe",
      surface: surface,
      profile_id: profile_id,
      sign_in: sign_in
    )
  end

  describe "new/0 and defaults/0" do
    test "both answer the same idle state with no owning surface" do
      idle = %{
        surface: nil,
        flow_id: nil,
        url: nil,
        phase: :idle,
        reason: nil,
        port: nil,
        mode: nil,
        paste: "",
        paste_error: nil
      }

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
               reason: nil,
               port: 48_123,
               mode: nil,
               paste: "",
               paste_error: nil
             }

      assert_receive {:chatgpt_stub, :begin, "work"}, @receive_timeout_ms
      # The poll is running: its first status read reaches the stub.
      assert_receive {:chatgpt_stub, :status, @flow_id}, @receive_timeout_ms
      assert ChatGPTSignInState.waiting?(state)
      assert ChatGPTSignInState.flow_id(state) == @flow_id
      # Exactly one flow was started (one begin, never a second one). The
      # `:begin` notification is sent synchronously by the stub inside the
      # state module's own call, so the mailbox is already complete.
      refute_receive {:chatgpt_stub, :begin, _account}, 0
    end

    test "a flow that cannot start answers the :error phase with its reason and NO poll" do
      install!({:error, :loopback_listener_unavailable})

      state = ChatGPTSignInState.begin(ChatGPTSignInState.new(), nil, :wizard, self())

      assert state.phase == :error
      assert state.reason == :loopback_listener_unavailable
      assert state.flow_id == nil
      assert state.url == nil
      assert state.port == nil
      assert state.mode == nil
      refute ChatGPTSignInState.waiting?(state)

      assert_receive {:chatgpt_stub, :begin, _account}, @receive_timeout_ms
      # No poll may be started for a flow that never existed: with no
      # supervised poll alive, no status read can ever reach the stub.
      assert_no_poll(self())
      refute_receive {:chatgpt_stub, :status, _flow_id}, 0
    end

    test "records the flow's redirect port and mode (absent ones are nil)" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123, mode: :manual}})

      manual = ChatGPTSignInState.begin(ChatGPTSignInState.new(), "work", :wizard, self())

      assert_receive {:chatgpt_stub, :begin, "work"}, @receive_timeout_ms
      assert manual.port == 48_123
      assert manual.mode == :manual

      projection = ChatGPTSignInState.surface_state(manual, :wizard)
      assert projection.port == 48_123
      assert projection.mode == :manual

      # A flow module that reports neither is still a usable waiting surface.
      install!({:ok, %{id: @flow_id, url: @flow_url}})
      bare = ChatGPTSignInState.begin(manual, "work", {:detail, "profile-1"}, self())

      assert bare.phase == :waiting
      assert bare.port == nil
      assert bare.mode == nil
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
      # No flow module call is even attempted without an owner (`:begin` is a
      # synchronous notification, so the mailbox is conclusive here too).
      refute_receive {:chatgpt_stub, :begin, _account}, 0
    end
  end

  describe "chatgpt_sign_in_paste/2 and chatgpt_sign_in_submit/2 — the manual fallback" do
    test "the typed text reaches the flow and the surface stays waiting" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      surface = {:detail, "profile-1"}
      typed = "  http://127.0.0.1:48123/auth/callback?code=abc&state=s1  "

      {:noreply, pasted} =
        ChatGPTSignInState.chatgpt_sign_in_paste(socket(waiting_state(surface)), %{
          "surface" => "detail",
          "profile_id" => "profile-1",
          "value" => typed
        })

      # `phx-change` stores the text verbatim (the user may still be typing) and
      # clears an earlier rejection — no flow call at all.
      assert assign_state(pasted).paste == typed
      assert assign_state(pasted).paste_error == nil
      assert assign_state(pasted).phase == :waiting
      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0

      {:noreply, submitted} =
        ChatGPTSignInState.chatgpt_sign_in_submit(pasted, %{
          "surface" => "detail",
          "profile_id" => "profile-1"
        })

      assert_receive {:chatgpt_stub, :submit, @flow_id, text}, @receive_timeout_ms
      assert text == String.trim(typed)

      state = assign_state(submitted)
      assert state.phase == :waiting
      assert state.paste == ""
      assert state.paste_error == nil
      assert state.flow_id == @flow_id
    end

    test "the submit payload's value is the fallback when nothing was typed" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      {:noreply, submitted} =
        ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting_state(:wizard)), %{
          "surface" => "wizard",
          "value" => "abc123"
        })

      assert_receive {:chatgpt_stub, :submit, @flow_id, "abc123"}, @receive_timeout_ms
      assert assign_state(submitted).phase == :waiting
    end

    test "a blank paste answers an inline, retryable :no_code WITHOUT touching the flow" do
      waiting = waiting_state(:wizard)

      for params <- [%{"surface" => "wizard"}, %{"surface" => "wizard", "value" => "   "}] do
        {:noreply, submitted} =
          ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting), params)

        assert assign_state(submitted).phase == :waiting
        assert assign_state(submitted).paste_error == :no_code
        assert assign_state(submitted).flow_id == @flow_id
      end

      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0
    end

    test "a rejected paste keeps the waiting panel with a retryable inline error" do
      for reason <- [:invalid_callback, :no_code, :already_finished] do
        install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}}, [],
          submit: {:error, reason}
        )

        surface = {:status, "profile-2"}
        waiting = %{waiting_state(surface) | paste: "code=abc"}

        {:noreply, socket} =
          ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting), %{
            "surface" => "status",
            "profile_id" => "profile-2"
          })

        assert_receive {:chatgpt_stub, :submit, @flow_id, "code=abc"}, @receive_timeout_ms

        state = assign_state(socket)
        assert state.phase == :waiting
        assert state.paste_error == reason
        assert state.reason == nil
        assert state.flow_id == @flow_id

        # The surface still renders its waiting block with the inline error.
        projection = ChatGPTSignInState.surface_state(state, surface)
        assert projection.phase == :waiting
        assert projection.paste_error == reason
        assert render_panel("status", "profile-2", projection) =~ "Submit pasted link"
      end
    end

    test "any other flow failure becomes the :error phase" do
      install!(
        {:ok, %{id: @flow_id, url: @flow_url, port: 48_123}},
        [],
        submit: {:error, :unknown_flow}
      )

      {:noreply, socket} =
        ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting_state(:wizard)), %{
          "surface" => "wizard",
          "value" => "abc"
        })

      assert_receive {:chatgpt_stub, :submit, @flow_id, "abc"}, @receive_timeout_ms

      state = assign_state(socket)
      assert state.phase == :error
      assert state.reason == :unknown_flow
      assert state.paste_error == nil
    end

    test "a cancelled flow answers :already_finished and keeps the panel retryable" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      # The stub records the cancel, then answers submits for that id as an
      # already-finished attempt.
      _ = ChatGPTLoginStub.cancel(@flow_id)
      assert_receive {:chatgpt_stub, :cancel, @flow_id}, @receive_timeout_ms

      {:noreply, socket} =
        ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting_state(:wizard)), %{
          "surface" => "wizard",
          "value" => "abc"
        })

      assert assign_state(socket).phase == :waiting
      assert assign_state(socket).paste_error == :already_finished
    end

    test "a paste for a surface that no longer owns a waiting flow is dropped" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})

      # A CLOSED attempt keeps its surface but is idle again.
      closed = %{
        ChatGPTSignInState.new()
        | surface: {:detail, "profile-1"},
          paste: "stale",
          paste_error: :invalid_callback
      }

      {:noreply, submitted} =
        ChatGPTSignInState.chatgpt_sign_in_submit(socket(closed), %{
          "surface" => "detail",
          "profile_id" => "profile-1",
          "value" => "abc"
        })

      assert assign_state(submitted) == closed
      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0

      # A paste typed for ANOTHER surface never mutates the waiting surface's state.
      waiting = waiting_state({:detail, "profile-1"})

      {:noreply, pasted} =
        ChatGPTSignInState.chatgpt_sign_in_paste(socket(waiting), %{
          "surface" => "detail",
          "profile_id" => "profile-2",
          "value" => "abc"
        })

      assert assign_state(pasted) == waiting

      # And a submit addressed to another surface never reaches the flow.
      {:noreply, foreign} =
        ChatGPTSignInState.chatgpt_sign_in_submit(socket(waiting), %{
          "surface" => "detail",
          "profile_id" => "profile-2",
          "value" => "abc"
        })

      assert assign_state(foreign) == waiting
      refute_receive {:chatgpt_stub, :submit, _flow_id, _input}, 0
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
               reason: nil,
               port: nil,
               mode: nil,
               paste: "",
               paste_error: nil
             }
    end

    test "is quiet when nothing waits" do
      state = ChatGPTSignInState.new()

      assert ChatGPTSignInState.cancel(state) == state
      # `:cancel` is a synchronous notification from this process.
      refute_receive {:chatgpt_stub, :cancel, _flow_id}, 0
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
      # `:cancel` is a synchronous notification from this process.
      refute_receive {:chatgpt_stub, :cancel, _flow_id}, 0

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
               reason: nil,
               port: 48_123,
               mode: :loopback,
               paste: "",
               paste_error: nil
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

  # The stub's Agent pid is per-test process-dictionary state, and the sign-in
  # boundary calls it from tasks several hops BELOW the test. Resolution must
  # therefore follow the `:"$callers"` chain transitively — and must fail
  # loudly, never call an Agent that does not exist.
  describe "stub pid resolution through the caller chain" do
    test "resolves the Agent through a MULTI-HOP chain, not just the direct callers" do
      install!({:ok, %{id: @flow_id, url: @flow_url, port: 48_123}})
      test_pid = self()

      # A TRUNCATED chain: each hop names ONLY the hop above it, so the Agent
      # pid sits two hops up and the innermost process' direct `$callers` entry
      # cannot resolve it. That is the shape of a boundary/poll task whose
      # starter's chain was not flattened into one list.
      {_outer, outer_ref} =
        spawn_monitor(fn ->
          Process.put(:"$callers", [test_pid])
          outer_pid = self()

          spawn_monitor(fn ->
            Process.put(:"$callers", [outer_pid])

            send(
              test_pid,
              {:stub_call, ChatGPTLoginStub.begin("work", []), ChatGPTLoginStub.status(@flow_id)}
            )

            send(outer_pid, :inner_done)
          end)

          receive do
            :inner_done -> :ok
          end
        end)

      assert_receive {:stub_call, {:ok, %{id: @flow_id}}, :pending}, @receive_timeout_ms
      # The notification still reaches the TEST pid, not the intermediate hop.
      assert_receive {:chatgpt_stub, :begin, "work"}, @receive_timeout_ms
      assert_receive {:chatgpt_stub, :status, @flow_id}, @receive_timeout_ms
      assert_receive {:DOWN, ^outer_ref, :process, _pid, :normal}, @receive_timeout_ms
    end

    test "fails loudly when no install!/1 is in the caller chain" do
      test_pid = self()

      # No stub was installed here or above, so this used to reach
      # `GenServer.call(nil, …)` and exit `{:noproc, _}` with no diagnosis.
      {:ok, _pid} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          try do
            ChatGPTLoginStub.begin("work", [])
            send(test_pid, :stub_call_returned)
          rescue
            error -> send(test_pid, {:stub_call_raised, error})
          end
        end)

      assert_receive {:stub_call_raised, %ExUnit.AssertionError{} = error}, @receive_timeout_ms
      message = Exception.message(error)

      assert message =~ "EvoDash.Test.ChatGPTLoginStub"
      assert message =~ "no Agent pid"
      assert message =~ "install!/1"
      # The test pid is named so the failure points at the suite that forgot it.
      assert message =~ inspect(test_pid)
      refute_receive :stub_call_returned, 0
    end
  end
end
