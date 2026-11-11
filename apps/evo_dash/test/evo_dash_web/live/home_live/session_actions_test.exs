defmodule EvoDashWeb.HomeLive.SessionActionsTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.HomeLive.SessionActions` — the TOTAL boundary
  between the `/help` page and the core's interactive-session API.

  No page is mounted and no global state is mutated: every live call is routed
  through a CALL-TIME app-env runner seam (`:home_session_*_runner`), which this
  suite injects and restores `app-env`-for-`app-env` in `on_exit`. The only
  "real" call exercised is `load_attach(node, <unparseable id>)`, which the
  default loader answers from `parse_session/1` alone — before any RPC.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.SessionActions

  @agent_module EvoGit.Agents.SelfReflective

  # Sentinel for "this seam was not set before the test".
  @unset :__session_actions_seam_unset__

  @empty_attach %{summary: nil, awaiting?: false, history: []}

  defp seam(key, value) do
    restore_on_exit(key)
    Application.put_env(:evo_dash, key, value)
  end

  defp clear_seam(key) do
    restore_on_exit(key)
    Application.delete_env(:evo_dash, key)
  end

  defp restore_on_exit(key) do
    previous = Application.get_env(:evo_dash, key, @unset)

    on_exit(fn ->
      case previous do
        @unset -> Application.delete_env(:evo_dash, key)
        restored -> Application.put_env(:evo_dash, key, restored)
      end
    end)
  end

  defp summary(overrides) do
    Map.merge(
      %{agent_module: @agent_module, parent_id: nil, status: :running},
      overrides
    )
  end

  describe "url/2" do
    test "no session and no node is the bare /help path" do
      assert SessionActions.url(nil, nil) == "/help"
    end

    test "a session id is emitted FIRST, then the node param" do
      assert SessionActions.url(nil, 7) == "/help?session=7"
      assert SessionActions.url("t1", nil) == "/help?node=t1"
      assert SessionActions.url("t1", 7) == "/help?session=7&node=t1"
    end

    test "blank/non-binary node params and unusable session ids are omitted" do
      assert SessionActions.url("", 7) == "/help?session=7"
      assert SessionActions.url("   ", nil) == "/help"
      assert SessionActions.url(:node1, nil) == "/help"
      assert SessionActions.url(42, nil) == "/help"

      assert SessionActions.url(nil, 0) == "/help"
      assert SessionActions.url(nil, -3) == "/help"
      assert SessionActions.url(nil, 7.0) == "/help"
      assert SessionActions.url(nil, "0") == "/help"
      assert SessionActions.url(nil, "-1") == "/help"
      assert SessionActions.url(nil, "abc") == "/help"
      assert SessionActions.url(nil, "%{}") == "/help"
    end

    test "a string session id is emitted only when parse_session/1 accepts it" do
      assert SessionActions.url(nil, "7") == "/help?session=7"
      assert SessionActions.url(nil, "007") == "/help?session=7"
      assert SessionActions.url("t1", "7") == "/help?session=7&node=t1"
      assert SessionActions.url(nil, "7x") == "/help"
      assert SessionActions.url(nil, " 7") == "/help"
    end
  end

  describe "parse_session/1" do
    test "positive integers and digit-only strings pass through" do
      assert SessionActions.parse_session(7) == {:ok, 7}
      assert SessionActions.parse_session(1) == {:ok, 1}
      assert SessionActions.parse_session("7") == {:ok, 7}
      assert SessionActions.parse_session("42") == {:ok, 42}
    end

    test "everything else is :none (whitelist, no atom conversion)" do
      for value <- [
            0,
            -1,
            "-1",
            "0",
            "7x",
            " 7",
            " ",
            "",
            "abc",
            7.0,
            nil,
            %{},
            [],
            %{"session" => 7},
            :seven,
            {:ok, 7}
          ] do
        assert SessionActions.parse_session(value) == :none,
               "expected :none for #{inspect(value)}"
      end
    end
  end

  describe "session_opts/2" do
    test "always builds the repo-less interactive root session opts, with no preamble" do
      assert SessionActions.session_opts("Ship it") == [
               agent_module: @agent_module,
               repo_less: true,
               objective: "Ship it",
               session_mode: :interactive
             ]

      opts = SessionActions.session_opts("Ship it")
      refute Keyword.has_key?(opts, :depth)
      refute Keyword.has_key?(opts, :parent_id)
      refute Keyword.has_key?(opts, :model_spec)
      refute Keyword.has_key?(opts, :attachments)
    end

    test "a non-binary text becomes an empty objective, and junk opts are ignored" do
      assert SessionActions.session_opts(nil, :junk)[:objective] == ""
      assert SessionActions.session_opts(%{"text" => "hi"}, %{model_spec: %{}})[:objective] == ""
    end

    test "includes :model_spec only for a non-empty canonical string-keyed map" do
      spec = %{"provider_profile_id" => "acct", "model" => "m", "reasoning_effort" => "high"}

      assert SessionActions.session_opts("hi", model_spec: spec)[:model_spec] == spec
      refute Keyword.has_key?(SessionActions.session_opts("hi", model_spec: %{}), :model_spec)
      refute Keyword.has_key?(SessionActions.session_opts("hi", model_spec: nil), :model_spec)
      refute Keyword.has_key?(SessionActions.session_opts("hi", model_spec: "auto"), :model_spec)
      refute Keyword.has_key?(SessionActions.session_opts("hi"), :model_spec)
    end

    test "includes :attachments only for a non-empty list of maps" do
      attachments = [%{name: "a.txt", content: "hi"}]

      assert SessionActions.session_opts("hi", attachments: attachments)[:attachments] ==
               attachments

      refute Keyword.has_key?(SessionActions.session_opts("hi", attachments: []), :attachments)

      refute Keyword.has_key?(
               SessionActions.session_opts("hi", attachments: ["junk", 3, nil]),
               :attachments
             )

      refute Keyword.has_key?(SessionActions.session_opts("hi", attachments: :junk), :attachments)
    end
  end

  describe "session_agent?/1" do
    test "accepts a root self-reflective summary in module, atom-name or Elixir-prefixed form" do
      assert SessionActions.session_agent?(summary(%{id: 1}))
      assert SessionActions.session_agent?(summary(%{id: 1, parent_id: ""}))
      assert SessionActions.session_agent?(summary(%{id: 1, agent_module: @agent_module}))

      assert SessionActions.session_agent?(
               summary(%{id: 1, agent_module: "EvoGit.Agents.SelfReflective"})
             )

      assert SessionActions.session_agent?(
               summary(%{id: 1, agent_module: "Elixir.EvoGit.Agents.SelfReflective"})
             )

      assert SessionActions.session_agent?(
               summary(%{id: 1, agent_module: " EvoGit.Agents.SelfReflective "})
             )

      assert SessionActions.session_agent?(%{
               "agent_module" => "Elixir.EvoGit.Agents.SelfReflective",
               "parent_id" => nil
             })
    end

    test "rejects non-roots, other modules, missing modules and non-maps" do
      refute SessionActions.session_agent?(summary(%{id: 1, parent_id: 3}))
      refute SessionActions.session_agent?(summary(%{id: 1, parent_id: "3"}))

      refute SessionActions.session_agent?(
               summary(%{id: 1, agent_module: EvoGit.Agents.Executor})
             )

      refute SessionActions.session_agent?(
               summary(%{id: 1, agent_module: "EvoGit.Agents.Executor"})
             )

      refute SessionActions.session_agent?(summary(%{id: 1, agent_module: nil}))
      refute SessionActions.session_agent?(Map.delete(summary(%{id: 1}), :agent_module))
      refute SessionActions.session_agent?(nil)
      refute SessionActions.session_agent?(:junk)
      refute SessionActions.session_agent?([])
      refute SessionActions.session_agent?("EvoGit.Agents.SelfReflective")
    end
  end

  describe "session_ended?/1" do
    test "finished and not_found are terminal, bare or wrapped in {:error, _}" do
      assert SessionActions.session_ended?({:session, :finished})
      assert SessionActions.session_ended?({:session, :not_found})
      assert SessionActions.session_ended?({:error, {:session, :finished}})
      assert SessionActions.session_ended?({:error, {:session, :not_found}})
    end

    test "everything else is not terminal" do
      refute SessionActions.session_ended?({:session, {:bad_state, :running}})
      refute SessionActions.session_ended?({:session, {:bad_state, :awaiting_input}})
      refute SessionActions.session_ended?({:error, {:session, {:bad_state, :running}}})
      refute SessionActions.session_ended?({:erpc, :noconnection})
      refute SessionActions.session_ended?(:timeout)
      refute SessionActions.session_ended?(nil)
      refute SessionActions.session_ended?(:finished)
    end
  end

  describe "session_unavailable?/1" do
    test "every unavailable reason is a fallback trigger, bare and wrapped" do
      for reason <- [
            :llm_not_configured,
            :session_api_unavailable,
            {:interactive_root_only, "sessions are root-only"},
            {:invalid_session_opts, "bad"},
            {:unsupported_session_mode, "one_shot"}
          ] do
        assert SessionActions.session_unavailable?(reason),
               "expected a fallback trigger for #{inspect(reason)}"

        assert SessionActions.session_unavailable?({:start_session_failed, reason}),
               "expected a wrapped fallback trigger for #{inspect(reason)}"

        assert SessionActions.session_unavailable?(
                 {:start_session_failed, {:start_session_failed, reason}}
               )
      end
    end

    test "transport failures are real errors, not fallback triggers" do
      refute SessionActions.session_unavailable?({:erpc, :noconnection})
      refute SessionActions.session_unavailable?(:timeout)
      refute SessionActions.session_unavailable?({:start_session_failed, {:erpc, :noconnection}})
      refute SessionActions.session_unavailable?({:error, :boom})
      refute SessionActions.session_unavailable?(nil)
    end
  end

  describe "status_from/2" do
    test "awaiting_input parks idle; running/starting are running; cancelling stays cancelling" do
      assert SessionActions.status_from(%{status: :awaiting_input}) == :idle
      assert SessionActions.status_from(%{"status" => "awaiting_input"}) == :idle
      assert SessionActions.status_from(%{status: :running}) == :running
      assert SessionActions.status_from(%{"status" => "running"}) == :running
      assert SessionActions.status_from(%{status: :starting}) == :running
      assert SessionActions.status_from(%{"status" => "starting"}) == :running
      assert SessionActions.status_from(%{status: :cancelling}) == :cancelling
      assert SessionActions.status_from(%{"status" => "cancelling"}) == :cancelling
    end

    test "a missing or finished summary ends unless the awaiting list reports it" do
      assert SessionActions.status_from(%{status: :done}) == :ended
      assert SessionActions.status_from(%{status: :finished}) == :ended
      assert SessionActions.status_from(%{status: nil}) == :ended
      assert SessionActions.status_from(%{}) == :ended

      assert SessionActions.status_from(%{status: :done}, true) == :idle
      assert SessionActions.status_from(%{}, true) == :idle
      assert SessionActions.status_from(%{status: :done}, false) == :ended
    end

    test "non-map summaries are total" do
      assert SessionActions.status_from(nil) == :ended
      assert SessionActions.status_from(nil, true) == :idle
      assert SessionActions.status_from(:junk) == :ended
      assert SessionActions.status_from(:junk, true) == :idle
      assert SessionActions.status_from([], false) == :ended
      assert SessionActions.status_from("running", true) == :idle
    end
  end

  describe "start/2 seam" do
    test "normalizes a positive {:ok, id} answer" do
      seam(:home_session_start_runner, fn node, opts ->
        send(self(), {:started, node, opts})
        {:ok, 42}
      end)

      assert SessionActions.start(:some@host, agent_module: @agent_module) == {:ok, 42}
      assert_received {:started, :some@host, [agent_module: @agent_module]}
    end

    test "answers the node's own {:error, reason} verbatim" do
      seam(:home_session_start_runner, fn _node, _opts -> {:error, :llm_not_configured} end)

      assert SessionActions.start(:some@host, []) == {:error, :llm_not_configured}
    end

    test "an unusable answer is {:error, {:unexpected_start_result, term}}" do
      seam(:home_session_start_runner, fn _node, _opts -> {:ok, 0} end)

      assert SessionActions.start(:some@host, []) ==
               {:error, {:unexpected_start_result, {:ok, 0}}}
    end

    test "a non-tagged garbage answer is {:error, {:unexpected_start_result, term}}" do
      seam(:home_session_start_runner, fn _node, _opts -> :garbage end)

      assert SessionActions.start(:some@host, []) ==
               {:error, {:unexpected_start_result, :garbage}}
    end
  end

  describe "send_message/5 seam" do
    test "sends the bare text with the default :queue policy when there are no attachments" do
      seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(self(), {:sent, node, agent_id, message, policy})
        :ok
      end)

      assert SessionActions.send_message(:some@host, 7, "hello", []) == :ok
      assert_received {:sent, :some@host, 7, "hello", :queue}

      assert SessionActions.send_message(:some@host, 7, nil, nil) == :ok
      assert_received {:sent, :some@host, 7, "", :queue}

      assert SessionActions.send_message(:some@host, 7, "hello", [], :interrupt) == :ok
      assert_received {:sent, :some@host, 7, "hello", :interrupt}
    end

    test "sends the core's message map when attachments are present" do
      attachments = [%{name: "a.txt", content: "hi"}]

      seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(self(), {:sent, node, agent_id, message, policy})
        {:ok, %{accepted: true}}
      end)

      assert SessionActions.send_message(:some@host, 9, "look", attachments) == :ok

      assert_received {:sent, :some@host, 9, %{text: "look", attachments: ^attachments}, :queue}
    end

    test "answers {:error, reason} verbatim and tags an unusable answer" do
      seam(:home_session_send_runner, fn _node, _agent_id, _message, _policy ->
        Process.get(:send_answer)
      end)

      Process.put(:send_answer, {:error, {:session, :finished}})

      assert SessionActions.send_message(:some@host, 7, "hi", []) ==
               {:error, {:session, :finished}}

      assert SessionActions.session_ended?({:error, {:session, :finished}})

      Process.put(:send_answer, :garbage)

      assert SessionActions.send_message(:some@host, 7, "hi", []) ==
               {:error, {:unexpected_send_result, :garbage}}
    end
  end

  describe "close/3 seam" do
    test "returns the node's answer verbatim and passes the reason through" do
      seam(:home_session_close_runner, fn node, agent_id, reason ->
        send(self(), {:closed, node, agent_id, reason})
        :ok
      end)

      assert SessionActions.close(:some@host, 7) == :ok
      assert_received {:closed, :some@host, 7, :normal}

      assert SessionActions.close(:some@host, 7, :user_left) == :ok
      assert_received {:closed, :some@host, 7, :user_left}
    end

    test "returns an error answer verbatim" do
      seam(:home_session_close_runner, fn _node, _agent_id, _reason -> {:error, :boom} end)

      assert SessionActions.close(:some@host, 7, :normal) == {:error, :boom}
    end
  end

  describe "load_attach/2 seam" do
    test "normalizes the documented attach state" do
      seam(:home_session_attach_runner, fn node, session_id ->
        send(self(), {:attached, node, session_id})
        Process.get(:attach_answer)
      end)

      Process.put(:attach_answer, %{summary: %{id: 7}, awaiting?: true, history: [1, 2]})

      assert SessionActions.load_attach(:some@host, 7) == %{
               summary: %{id: 7},
               awaiting?: true,
               history: [1, 2]
             }

      assert_received {:attached, :some@host, 7}
    end

    test "coerces a non-map summary to nil and awaiting? to a strict boolean" do
      seam(:home_session_attach_runner, fn _node, _session_id -> Process.get(:attach_answer) end)

      Process.put(:attach_answer, %{summary: "junk", awaiting?: "yes", history: [1]})

      assert SessionActions.load_attach(:some@host, 7) == %{
               summary: nil,
               awaiting?: false,
               history: [1]
             }

      Process.put(:attach_answer, %{summary: nil, awaiting?: true, history: []})

      assert SessionActions.load_attach(:some@host, 7) == %{
               summary: nil,
               awaiting?: true,
               history: []
             }
    end

    test "degrades to the empty shape instead of raising on an unusable answer" do
      seam(:home_session_attach_runner, fn _node, _session_id -> Process.get(:attach_answer) end)

      for answer <- [
            :boom,
            nil,
            [],
            %{summary: nil, awaiting?: true, history: "nope"},
            %{summary: %{id: 7}, awaiting?: true},
            "junk"
          ] do
        Process.put(:attach_answer, answer)

        assert SessionActions.load_attach(:some@host, 7) == @empty_attach,
               "expected the empty attach shape for #{inspect(answer)}"
      end
    end
  end

  describe "default attach loader" do
    test "guards an unparseable session id before any RPC" do
      clear_seam(:home_session_attach_runner)

      assert SessionActions.load_attach(node(), "junk") == @empty_attach
      assert SessionActions.load_attach(node(), "7x") == @empty_attach
      assert SessionActions.load_attach(node(), 0) == @empty_attach
      assert SessionActions.load_attach(node(), nil) == @empty_attach
      assert SessionActions.default_load_attach(node(), :nope) == @empty_attach
    end

    test "a wrong-arity seam value falls back to the production default instead of crashing" do
      seam(:home_session_attach_runner, fn _single_argument ->
        send(self(), :wrong_arity_runner_called)
        :boom
      end)

      # The fallback default loader is guarded by parse_session/1, so this goes
      # nowhere near an RPC.
      assert SessionActions.load_attach(node(), "junk") == @empty_attach
      refute_received :wrong_arity_runner_called
    end
  end
end
