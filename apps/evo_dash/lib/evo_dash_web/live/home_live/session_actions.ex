defmodule EvoDashWeb.HomeLive.SessionActions do
  @moduledoc """
  URL, URL-state and session-command helpers for the Genesis Assistant
  interactive-session UX (`EvoDashWeb.HomeLive` at `/help`).

  Everything here is a thin, TOTAL boundary over the core's interactive-session
  API on `EvoDash.NodeContext` — `start_session/2`,
  `send_session_message/4`, `close_session/3`, `list_agents/1`,
  `list_awaiting_input/1` and `get_agent_history/2`. Nothing is reimplemented
  and nothing is wrapped in `EvoDash.SafeCall`: CALLERS wrap (an RPC can exit
  its caller, which no `rescue` catches).

  ## URL state

  A chat is addressed by integer agent id: `/help?session=<agent_id>`
  (session FIRST, `node` appended with `&` when a remote target is viewed). An
  interactive session's agent id is positive, so it doubles as the
  `EvoDash.ChatHistory` chat id.

  ## Runner seams (resolved AT CALL TIME)

  Every executor reads its runner from the application env INSIDE the function
  — never at compile time — so a test can `Application.put_env/3` a stub:

    * `:home_session_start_runner` — 2-arity `(node, opts)`, default
      `&EvoDash.NodeContext.start_session/2`.
    * `:home_session_send_runner` — 4-arity `(node, agent_id, message, policy)`,
      default `&EvoDash.NodeContext.send_session_message/4`.
    * `:home_session_close_runner` — 3-arity `(node, agent_id, reason)`,
      default `&EvoDash.NodeContext.close_session/3`.
    * `:home_session_attach_runner` — 2-arity `(node, session_id)`, default the
      module's own loader (exported as `default_load_attach/2`, because
      `load_attach/2` itself resolves the seam and would otherwise recurse).
    * `:home_session_list_runner` — 1-arity `(node)`, default
      `&default_list/1` — the raw `{list_agents, list_awaiting_input}` pair,
      shared with the conversation-list panel.

  ## Delivery policy

  `send_session_message/4` accepts `:queue` (default) or `:interrupt`, but the
  core applies BOTH identically today (the message is delivered at the next
  turn boundary). UI copy must never claim a chunk-level halt.

  A session-command failure is the session's own `{:error, {:session, reason}}`
  — classify the terminal ones with `session_ended?/1` and the reflect-fallback
  triggers with `session_unavailable?/1`.
  """

  alias EvoDash.NodeContext

  @agent_module EvoGit.Agents.SelfReflective

  # `"EvoGit.Agents.SelfReflective"` — the module's name without the `Elixir.`
  # prefix, so a string/atom summary row compares equal to the module itself.
  @agent_module_name @agent_module |> Atom.to_string() |> String.trim_leading("Elixir.")

  # Reasons that mean "this node cannot run an interactive session" — the
  # caller falls back to the legacy one-shot `:reflect` send path.
  @unavailable_reasons [:llm_not_configured, :session_api_unavailable]

  @type reason :: term()
  @type attach_state :: %{
          summary: map() | nil,
          awaiting?: boolean(),
          history: [term()]
        }

  ## URL state

  @doc """
  Builds a `/help` query URL.

  No session and no node → `"/help"`; node only → `"/help?node=<node_param>"`;
  session only → `"/help?session=<id>"`; both →
  `"/help?session=<id>&node=<node_param>"` (session FIRST, node appended with
  `&`). The node param is passed through verbatim as received (`nil`/blank
  omitted); a session id is emitted only when `parse_session/1` accepts it.
  """
  @spec url(term(), term()) :: String.t()
  def url(node_param, session_id) do
    parts = Enum.reject([session_param(session_id), node_param_part(node_param)], &is_nil/1)

    case parts do
      [] -> "/help"
      parts -> "/help?" <> Enum.join(parts, "&")
    end
  end

  defp node_param_part(node_param) when is_binary(node_param) do
    if String.trim(node_param) == "", do: nil, else: "node=#{node_param}"
  end

  defp node_param_part(_node_param), do: nil

  defp session_param(session_id) when is_integer(session_id) and session_id > 0,
    do: "session=#{session_id}"

  defp session_param(session_id) when is_binary(session_id) do
    case parse_session(session_id) do
      {:ok, id} -> "session=#{id}"
      :none -> nil
    end
  end

  defp session_param(_session_id), do: nil

  @doc """
  Parses the `?session=` URL value. Pure and whitelisted: only a positive
  integer literal is accepted (`Integer.parse/1` must consume the WHOLE
  string), so a non-numeric value is never converted.

  Returns `{:ok, id}` or `:none`.
  """
  @spec parse_session(term()) :: {:ok, pos_integer()} | :none
  def parse_session(id) when is_integer(id) and id > 0, do: {:ok, id}

  def parse_session(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> :none
    end
  end

  def parse_session(_value), do: :none

  ## Session start

  @doc """
  Builds the `EvoGit.AgentScheduler.SessionOpts.build/1` keyword list for a
  session's FIRST message.

  Always `agent_module: EvoGit.Agents.SelfReflective`, `repo_less: true`,
  `session_mode: :interactive` and the message text as `:objective` — no
  conversation preamble, because an interactive session keeps its own context
  across exchanges. `opts` may carry `:model_spec` (included only when a
  non-empty canonical spec is supplied — omitted entirely for Auto) and
  `:attachments` (included only when non-empty). `:depth`/`:parent_id` are
  never passed: sessions are root-only.
  """
  @spec session_opts(term(), term()) :: keyword()
  def session_opts(text, opts \\ []) do
    opts = if is_list(opts), do: opts, else: []

    base = [
      agent_module: @agent_module,
      repo_less: true,
      objective: if(is_binary(text), do: text, else: ""),
      session_mode: :interactive
    ]

    base
    |> maybe_put(:model_spec, canonical_spec(Keyword.get(opts, :model_spec)))
    |> maybe_put(:attachments, attachment_list(Keyword.get(opts, :attachments)))
  end

  @doc """
  Starts an interactive session through `:home_session_start_runner`.

  Returns `{:ok, agent_id}` or `{:error, reason}` — the node's own error
  verbatim (`{:invalid_session_opts, detail}` / `{:interactive_root_only, msg}`
  / `{:unsupported_session_mode, value}` / `:llm_not_configured` /
  `{:start_session_failed, inner}` / a transport failure). When
  `EvoDash.NodeContext.start_session/2` is not available at all, answers
  `{:error, :session_api_unavailable}` instead of calling it.
  """
  @spec start(node(), keyword()) :: {:ok, pos_integer()} | {:error, reason()}
  def start(node, opts) do
    if start_session_available?() do
      runner = runner(:home_session_start_runner, 2, &NodeContext.start_session/2)
      runner.(node, opts) |> normalize_start()
    else
      {:error, :session_api_unavailable}
    end
  end

  defp normalize_start({:ok, agent_id}) when is_integer(agent_id) and agent_id > 0,
    do: {:ok, agent_id}

  defp normalize_start({:error, reason}), do: {:error, reason}
  defp normalize_start(other), do: {:error, {:unexpected_start_result, other}}

  @doc """
  Whether a start failure means "interactive sessions are UNAVAILABLE here" —
  i.e. the caller should fall back to the legacy one-shot `:reflect` send path.

  True for `:llm_not_configured`, `{:interactive_root_only, _}`,
  `{:invalid_session_opts, _}`, `{:unsupported_session_mode, _}`, each wrapped
  in `{:start_session_failed, inner}`, and `:session_api_unavailable`; also true
  whenever `EvoDash.NodeContext.start_session/2` does not exist, because no
  session can be started on this build at all. Every other failure (a transport
  error, a crashed scheduler) is NOT a fallback trigger — it is a real error
  that must be surfaced.
  """
  @spec session_unavailable?(term()) :: boolean()
  def session_unavailable?(reason) do
    not start_session_available?() or unavailable_reason?(reason)
  end

  defp unavailable_reason?({:start_session_failed, inner}), do: unavailable_reason?(inner)
  defp unavailable_reason?(reason) when reason in @unavailable_reasons, do: true
  defp unavailable_reason?({:interactive_root_only, _detail}), do: true
  defp unavailable_reason?({:invalid_session_opts, _detail}), do: true
  defp unavailable_reason?({:unsupported_session_mode, _value}), do: true
  defp unavailable_reason?(_reason), do: false

  # `Code.ensure_loaded?/1` first: `function_exported?/3` answers false for a
  # module that merely has not been loaded yet in this node.
  defp start_session_available? do
    Code.ensure_loaded?(NodeContext) and function_exported?(NodeContext, :start_session, 2)
  end

  ## Session messaging

  @doc """
  Sends a user message to a session through `:home_session_send_runner`.

  `attachments` is the `EvoDashWeb.HomeLive.Attachments.to_message/2`
  attachment list: a non-empty list sends the core's message MAP
  `%{text: text, attachments: attachments}`, an empty one sends the bare
  binary. `policy` is `:queue` (default) or `:interrupt` — both are applied
  identically at the next turn boundary today.

  Returns `:ok` or `{:error, reason}` (the session's own errors are
  `{:session, :finished}` / `{:session, :not_found}` /
  `{:session, {:bad_state, phase}}`).
  """
  @spec send_message(node(), term(), term(), term(), :queue | :interrupt) ::
          :ok | {:error, reason()}
  def send_message(node, agent_id, text, attachments, policy \\ :queue) do
    message = build_message(text, attachments)
    runner = runner(:home_session_send_runner, 4, &NodeContext.send_session_message/4)

    case runner.(node, agent_id, message, policy) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_send_result, other}}
    end
  end

  defp build_message(text, attachments) do
    text = if is_binary(text), do: text, else: ""

    case attachment_list(attachments) do
      nil -> text
      list -> %{text: text, attachments: list}
    end
  end

  @doc """
  Whether a send failure means the session is GONE (terminal), so the chat must
  move to `:ended` instead of showing a retry: `{:session, :finished}` and
  `{:session, :not_found}` — bare or wrapped in `{:error, _}`.
  """
  @spec session_ended?(term()) :: boolean()
  def session_ended?({:error, reason}), do: session_ended?(reason)
  def session_ended?({:session, :finished}), do: true
  def session_ended?({:session, :not_found}), do: true
  def session_ended?(_reason), do: false

  @doc """
  Closes an interactive session through `:home_session_close_runner`.

  Closing is the only non-cancellation way out of `:awaiting_input`;
  `reason` defaults to `:normal`. The result is the node's own answer,
  verbatim (`:ok` or `{:error, reason}`).
  """
  @spec close(node(), term(), term()) :: :ok | {:error, reason()}
  def close(node, agent_id, reason \\ :normal) do
    runner = runner(:home_session_close_runner, 3, &NodeContext.close_session/3)
    runner.(node, agent_id, reason)
  end

  ## Reattach

  @doc """
  Loads the state needed to REATTACH to an existing session (a `/help?session=<id>`
  load or a mount reconciliation) through `:home_session_attach_runner`.

  Returns `%{summary: map | nil, awaiting?: boolean, history: list}`:

    * `:summary` — the root self-reflective summary row for `session_id`
      (see `session_agent?/1`), or nil;
    * `:awaiting?` — the session is ALIVE: such a summary row exists OR
      `list_awaiting_input/1` reports the id;
    * `:history` — the agent's `%ReqLLM.Message{}` history (`[]` once the
      session is gone).

  Every read is defensive: a non-list agent/awaiting answer degrades to "not
  there" and a non-map summary to nil, so a dead or unreachable node yields the
  empty shape rather than an error.
  """
  @spec load_attach(node(), term()) :: attach_state()
  def load_attach(node, session_id) do
    runner = runner(:home_session_attach_runner, 2, &default_load_attach/2)
    runner.(node, session_id) |> normalize_attach()
  end

  @doc false
  # The default attach loader (exported so it can be the seam default without
  # `load_attach/2` resolving itself).
  def default_load_attach(node, session_id) do
    case parse_session(session_id) do
      {:ok, id} ->
        summary = node |> NodeContext.list_agents() |> find_summary(id)
        awaiting? = node |> NodeContext.list_awaiting_input() |> awaiting_entry?(id)
        history = node |> NodeContext.get_agent_history(id) |> history_list()

        %{summary: summary, awaiting?: summary != nil or awaiting?, history: history}

      :none ->
        %{summary: nil, awaiting?: false, history: []}
    end
  end

  defp find_summary(agents, session_id) when is_list(agents) do
    Enum.find(agents, fn summary ->
      is_map(summary) and agent_id(summary) == session_id and session_agent?(summary)
    end)
  end

  defp find_summary(_agents, _session_id), do: nil

  # `case` rather than two `defp` clauses: the compiler can prove from the
  # caller's spec that the awaiting answer is a list, which makes a trailing
  # catch-all clause warn as unreachable.
  defp awaiting_entry?(awaiting, session_id) do
    case awaiting do
      list when is_list(list) -> Enum.any?(list, &awaiting_entry_for?(&1, session_id))
      _other -> false
    end
  end

  defp awaiting_entry_for?(entry, session_id) do
    is_map(entry) and Map.get(entry, :agent_id, Map.get(entry, "agent_id")) == session_id
  end

  defp history_list(history) when is_list(history), do: history
  defp history_list(_history), do: []

  defp agent_id(summary), do: Map.get(summary, :id, Map.get(summary, "id"))

  defp normalize_attach(%{summary: summary, awaiting?: awaiting?, history: history} = state)
       when is_list(history) do
    %{state | summary: if(is_map(summary), do: summary, else: nil), awaiting?: awaiting? == true}
  end

  defp normalize_attach(_state), do: %{summary: nil, awaiting?: false, history: []}

  @doc """
  Maps a session phase (from a summary row and/or the awaiting list) to the
  chat status the page renders: `:awaiting_input` → `:idle`, `:running` (and
  the not-yet-busy `:starting`) → `:running`, `:cancelling` → `:cancelling`, and
  a missing/`:done`/finished session → `:ended` (unless the awaiting list still
  reports it, which means it is parked idle).

  Total — an unusable summary/phase reads as `:ended` (or `:idle` when
  `awaiting?`).
  """
  @spec status_from(term(), term()) :: :idle | :running | :cancelling | :ended
  def status_from(summary, awaiting? \\ false)

  def status_from(summary, awaiting?) when is_map(summary) do
    case phase(summary) do
      :awaiting_input -> :idle
      "awaiting_input" -> :idle
      :running -> :running
      "running" -> :running
      :starting -> :running
      "starting" -> :running
      :cancelling -> :cancelling
      "cancelling" -> :cancelling
      _other -> if awaiting? == true, do: :idle, else: :ended
    end
  end

  def status_from(_summary, awaiting?), do: if(awaiting? == true, do: :idle, else: :ended)

  defp phase(summary), do: Map.get(summary, :status, Map.get(summary, "status"))

  @doc """
  Whether a summary row belongs to an interactive session agent: its
  `agent_module` resolves to `EvoGit.Agents.SelfReflective` (module, atom or
  string form) AND it is a ROOT (`parent_id` in `[nil, ""]`).

  Total and defensive — a missing `agent_module` (or an absent/unknown row) is
  never enough, even when the status happens to look like a session's.
  """
  @spec session_agent?(term()) :: boolean()
  def session_agent?(summary) when is_map(summary) do
    self_reflective_agent?(Map.get(summary, :agent_module, Map.get(summary, "agent_module"))) and
      Map.get(summary, :parent_id, Map.get(summary, "parent_id")) in [nil, ""]
  end

  def session_agent?(_summary), do: false

  defp self_reflective_agent?(value) when value == @agent_module, do: true

  defp self_reflective_agent?(value) when is_atom(value) and not is_nil(value) do
    normalize_module_name(Atom.to_string(value)) == @agent_module_name
  end

  defp self_reflective_agent?(value) when is_binary(value) do
    normalize_module_name(value) == @agent_module_name
  end

  defp self_reflective_agent?(_value), do: false

  defp normalize_module_name(value) when is_binary(value) do
    value |> String.trim() |> String.trim_leading("Elixir.")
  end

  @doc """
  The raw conversation-list data: `{agent_summaries, awaiting_entries}` from
  `:home_session_list_runner` (default `default_list/1`).

  Neither element is normalized here — the list panel decides how to render a
  non-list answer. The result is whatever the runner answers.
  """
  @spec list(node()) :: term()
  def list(node) do
    runner(:home_session_list_runner, 1, &default_list/1).(node)
  end

  @doc false
  # Seam default for `:home_session_list_runner` — the raw pair.
  def default_list(node) do
    {NodeContext.list_agents(node), NodeContext.list_awaiting_input(node)}
  end

  ## Seams & small normalizers

  # Resolved AT CALL TIME (never at compile time). A wrong-arity or
  # non-function env value falls back to the production default instead of
  # crashing a user click.
  defp runner(key, arity, default) do
    case Application.get_env(:evo_dash, key, default) do
      fun when is_function(fun, arity) -> fun
      _other -> default
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: opts ++ [{key, value}]

  defp canonical_spec(%{} = spec) when map_size(spec) > 0, do: spec
  defp canonical_spec(_spec), do: nil

  defp attachment_list(list) when is_list(list) do
    case Enum.filter(list, &is_map/1) do
      [] -> nil
      attachments -> attachments
    end
  end

  defp attachment_list(_list), do: nil
end
