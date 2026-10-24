defmodule EvoGit.Agent.ContextBuilder do
  @moduledoc """
  Dynamic context building helpers extracted from `EvoGit.Agent.__using__/1`.

  Builds the context tree and foreign repos sections for the first user prompt,
  provides XML-like block wrappers for the context/objective framing, and
  handles syncing agent state (context, usage, turn, tokens) to ETS.
  Also provides turn-tagging and creation-time timestamp stamping utilities
  for messages in the chat context (timestamps are Unix seconds).

  ## The runtime-context snapshot carries a CLOCK

  The `<context>…</context>` snapshot (`build_context_block/1`) ends with a
  one-line clock (`build_clock_section/1`) — the current local date/time, e.g.
  `Current local time: 2025-06-14 09:32 (Europe/Berlin)` — so an agent can tell
  how stale a commit, log line or issue is. It is the LAST section (environment
  band last: stable sections first, volatile environment data last).

  Two invariants hold:

    * **Byte-identity of message #1** — the clock is re-rendered into the
      APPENDED refresh message (`build_context_refresh_message/2`), never into
      the system message or the original first user message, so the provider's
      cacheable prefix stays byte-identical across compression cycles.
    * **`:now` test seam** — every section builder reads the clock through a
      `:now` key on its plain-map input (`build_clock_section/1`,
      `build_context_block/1`, `build_context_refresh_message/2`,
      `refresh_first_user_message/2`); a `%DateTime{}`/`%NaiveDateTime{}` pins
      the rendered line exactly, `nil`/absent (the production case) means
      "the real local clock, now".
  """

  alias EvoGit.Agent.BackgroundJobNotice
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.AgentScheduler

  # The zone the clock section falls back to when no local zone name can be
  # resolved — `NaiveDateTime.local_now/1`'s own default (Elixir's "local now").
  @default_time_zone "Etc/UTC"
  # --- Dynamic Context Building ---

  @doc """
  Builds the context tree string for a given node path and repo path.
  """
  def build_dynamic_context(state) do
    case ContextNode.build_context(state.node_path, state.repo_path) do
      {:ok, context} -> context
      {:error, _} -> "Current Path: '#{state.node_path}'."
    end
  end

  @doc """
  Builds the foreign repositories markdown section for the first user prompt.
  Returns an empty string when there are no non-primary foreign repos.
  """
  def build_foreign_repos_section(foreign_repos) do
    repos =
      foreign_repos
      |> Enum.reject(&ForeignRepo.primary?(&1.id))

    if repos == [] do
      ""
    else
      rows =
        repos
        |> Enum.map(fn repo ->
          desc = repo.description || "(no description)"
          "| :#{repo.id} | #{path_cell(repo)} | #{desc} |"
        end)
        |> Enum.join("\n")

      writable? = Enum.any?(repos, & &1.writable)

      writable_note =
        if writable? do
          "\n\nFor a writable foreign repo, the repo root is where delegated write work happens; " <>
            "the worktree is a read-only checkout of the latest committed state."
        else
          ""
        end

      "# Foreign Repositories\n\n" <>
        "| ID | Path | Description |\n|------|------|-------------|\n#{rows}\n\n" <>
        "Use absolute paths (e.g., `#{hd(repos).root}`) when delegating to foreign repositories." <>
        writable_note
    end
  end

  # Renders a foreign repo's Path cell. Writable repos additionally expose their
  # persistent worktree path (a read-only checkout of the latest committed
  # state); read-only repos render the root only, exactly as before.
  defp path_cell(%{writable: true} = repo) do
    "#{repo.root} (worktree: #{ForeignRepo.worktree_path(repo)})"
  end

  defp path_cell(%{root: root}), do: root

  @doc """
  Builds the delegation-authority markdown section for the first user prompt.

  Authoritatively tells THIS agent whether it is the ROOT agent of the task
  (`parent_id` nil == depth 0) or a NESTED agent, and which foreign-repo spawn
  authority that role carries. Pinned wording — do not paraphrase.

  Input: a plain map `%{parent_id: integer | nil, repo_less: boolean,
  foreign_repos: [ForeignRepo.t()]}` — pure function, never reads the process
  dictionary. Returns `""` when the agent is repo-less (the chat persona must
  not read a task-role statement) or when the task has no non-primary foreign
  repos (single-repo tasks stay token-neutral), mirroring
  `build_foreign_repos_section/1`'s empty-string convention so the runner's
  existing blank-filter drops the section.
  """
  def build_authority_section(%{repo_less: true}), do: ""

  def build_authority_section(%{parent_id: parent_id, foreign_repos: foreign_repos}) do
    repos =
      foreign_repos
      |> Enum.reject(&ForeignRepo.primary?(&1.id))

    cond do
      repos == [] ->
        ""

      is_nil(parent_id) ->
        "- **Delegation authority**: You are the **ROOT agent** of this task (depth 0 — you were not spawned by a parent). You MAY spawn write-capable (`:read_write`) subagents into writable foreign repos, one at a time (serialized: spawn one, wait for it to complete, then spawn the next — never parallel writable foreign-repo subagents). Read-only foreign-repo spawns (subagent_investigator / subagent_task_scheduler / subagent_context_extractor) are unrestricted for any agent at any depth."

      true ->
        "- **Delegation authority**: You are a **NESTED agent** (spawned by a parent agent — you are NOT the root agent of this task). You may spawn read-only agents (subagent_investigator / subagent_task_scheduler / subagent_context_extractor) into foreign repos freely, but you may NOT spawn write-capable (`:read_write`) subagents into a foreign repo. If the task needs writable changes in a foreign repo, report the need back up to your parent agent (the higher level in the delegation chain), which will handle it."
    end
  end

  @doc """
  Builds the quality-level guidance markdown section for the first user prompt.

  Returns the ROOT agent's `:quality_level` guidance block (FAST speed block /
  HIGH QUALITY block) via `EvoGit.QualityLevel.guidance/1`, or `""` when no
  extra guidance applies. Purely a root-agent concern:

    * `""` when the agent is repo-less (`repo_less: true`) — the chat persona
      must never receive a task-mode statement;
    * `""` for any NESTED agent (`parent_id` not nil) — subagents are unaffected;
    * otherwise `EvoGit.QualityLevel.guidance(quality_level)`, which itself
      returns `""` for `"balanced"`/absent/anything unknown.

  Input: a plain map with keys `:parent_id`, `:repo_less`, `:quality_level` —
  pure function, never reads the process dictionary, robust to missing keys
  (`Map.get/3`). Mirrors `build_authority_section/1`'s empty-string convention
  so the runner's existing blank-filter drops the section.
  """
  def build_quality_guidance_section(%{} = state) do
    cond do
      Map.get(state, :repo_less) == true -> ""
      not is_nil(Map.get(state, :parent_id)) -> ""
      true -> EvoGit.QualityLevel.guidance(Map.get(state, :quality_level))
    end
  end

  @doc """
  Builds the ONE-LINE clock section of the runtime-context snapshot.

  Agents otherwise have no clock at all, so any "how stale is this?" reasoning
  is blind. Format is terse, plain, no emoji, no markdown header, and at MINUTE
  granularity (no seconds, so the value is stable within a minute):

      Current local time: 2025-06-14 09:32 (Europe/Berlin)

  The trailing zone name is rendered only when the value KNOWS one (a
  `%DateTime{}` carries its `:time_zone`); when it is unavailable the line
  degrades to `Current local time: 2025-06-14 09:32`.

  Input: a plain map with an optional `:now` key — the deterministic TEST SEAM:

    * `%DateTime{}` — its own wall-clock value + its own zone name;
    * `%NaiveDateTime{}` — its wall-clock value, no zone name;
    * `nil`/absent (the production case) — the current local time, computed at
      CALL time, degrading to UTC (`#{@default_time_zone}`) when local-zone
      resolution is unavailable.

  Pure and TOTAL: never raises (an unusable `TZ` value or a missing time-zone
  database falls back to the naive local wall clock), never reads the process
  dictionary. Mirrors `build_authority_section/1`'s "plain map, robust to
  missing keys" convention; the rendered line is never blank.
  """
  @spec build_clock_section(map()) :: String.t()
  def build_clock_section(%{} = state) do
    {naive, zone} = clock_value(Map.get(state, :now))

    "Current local time: " <> Calendar.strftime(naive, "%Y-%m-%d %H:%M") <> zone_suffix(zone)
  end

  defp zone_suffix(zone) when is_binary(zone) and zone != "", do: " (" <> zone <> ")"
  defp zone_suffix(_zone), do: ""

  # Resolves the `:now` seam to `{%NaiveDateTime{} (second precision), zone | nil}`.
  defp clock_value(%DateTime{time_zone: zone} = now) do
    {now |> DateTime.to_naive() |> NaiveDateTime.truncate(:second), zone_name(zone)}
  end

  defp clock_value(%NaiveDateTime{} = now), do: {NaiveDateTime.truncate(now, :second), nil}

  defp clock_value(_absent), do: current_clock()

  defp zone_name(zone) when is_binary(zone) do
    case String.trim(zone) do
      "" -> nil
      name -> name
    end
  end

  defp zone_name(_zone), do: nil

  # The real clock, computed at CALL time. `NaiveDateTime.local_now/0` is the
  # OS local wall clock (`:calendar.local_time/0`, which honors `TZ`) and needs
  # no time-zone database — unlike `local_now/1`, which converts through the
  # wall-clock database and would raise when none is installed. The zone LABEL
  # is resolved separately (Elixir exposes no portable "the OS's zone name"
  # API). Defensive: an unusable clock source must never take an agent down, so
  # the value degrades to UTC.
  defp current_clock do
    {NaiveDateTime.truncate(NaiveDateTime.local_now(), :second), local_zone_name()}
  rescue
    _ -> utc_clock()
  catch
    _kind, _reason -> utc_clock()
  end

  defp utc_clock do
    {NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second), @default_time_zone}
  end

  # Best-effort local zone NAME — the cheapest hints are the `TZ` environment
  # variable (e.g. `Europe/Berlin`; POSIX allows a leading `:`) and the
  # `/etc/localtime` symlink into the IANA `zoneinfo` tree. Nothing resolvable →
  # `nil`, and the line renders the wall-clock value without a zone name.
  defp local_zone_name do
    zone_name(System.get_env("TZ") |> strip_zone_prefix()) || zone_name(zoneinfo_link())
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp strip_zone_prefix(zone) when is_binary(zone) do
    case String.trim_leading(zone, ":") do
      "" -> nil
      name -> name
    end
  end

  defp strip_zone_prefix(_zone), do: nil

  defp zoneinfo_link do
    with {:ok, link} <- File.read_link("/etc/localtime"),
         [_prefix, name] <- String.split(link, "zoneinfo/", parts: 2) do
      name
    else
      _unresolvable -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Builds the git-submodules note section for the first user prompt.

  `repo_notes` is the ALREADY-RENDERED markdown block (produced by
  `EvoGit.Runtime.Helpers.load_repo_notes/2` at root spec build) or `nil` when
  the repo has no gitlink/submodule entries (or detection failed). Returns the
  text as-is (trimmed), or `""` when nil/blank — mirroring
  `build_foreign_repos_section/1`'s "empty string when absent" convention so
  the runner's existing blank-filter drops it and no noise reaches prompts for
  repos without submodules.
  """
  def build_repo_notes_section(repo_notes) do
    if blank?(repo_notes), do: "", else: String.trim(repo_notes)
  end

  @doc """
  Builds the FULL `<context>...</context>` block of the first user prompt.

  The single shared assembly path used BOTH at run start (`Runner.do_run/2`)
  and by the mid-run compression refresh
  (`refresh_first_user_message/2`), so the two can never drift.

  Input: a plain map with keys `:node_path, :repo_path, :parent_id,
  :repo_less, :foreign_repos, :repo_notes, :quality_level` plus the optional
  clock seam `:now` (a `%DateTime{}`/`%NaiveDateTime{}` pins the rendered
  `Current local time:` line; `nil`/absent means the real local clock, now —
  see `build_clock_section/1`) and the optional `:background_jobs` list (the
  agent's live/finished background shell jobs, rendered by
  `EvoGit.Agent.BackgroundJobNotice.section/1`; absent/`nil`/`[]` renders
  nothing, so the block stays byte-identical for an agent with no jobs). A
  `%LoopState{}` satisfies this. Purely reads the CONTEXT.md chain from disk via
  `build_dynamic_context/1` — so calling it
  again later re-reads the CURRENT chain — plus the static sections, drops
  blank ones, joins them with `"\\n\\n"`, and wraps them via `context_block/1`.

  Section order is pinned (environment band LAST, so the stable sections form a
  cacheable prefix): `context tree`, delegation authority, foreign repos, repo
  notes, quality guidance, background jobs, then the CLOCK line.

  Returns `""` when the joined body is blank (matching `context_block/1`'s
  convention), so the caller's blank-filter drops it.

  Robust to missing keys (`Map.get/3`), mirroring
  `build_authority_section/1`/`build_quality_guidance_section/1`.
  """
  @spec build_context_block(map()) :: String.t()
  def build_context_block(%{} = state) do
    repo_less = Map.get(state, :repo_less) == true
    foreign_repos = Map.get(state, :foreign_repos) || []
    parent_id = Map.get(state, :parent_id)

    context_tree =
      build_dynamic_context(%{
        node_path: Map.get(state, :node_path),
        repo_path: Map.get(state, :repo_path)
      })

    body =
      [
        context_tree,
        build_authority_section(%{
          parent_id: parent_id,
          repo_less: repo_less,
          foreign_repos: foreign_repos
        }),
        build_foreign_repos_section(foreign_repos),
        build_repo_notes_section(Map.get(state, :repo_notes)),
        build_quality_guidance_section(%{
          parent_id: parent_id,
          repo_less: repo_less,
          quality_level: Map.get(state, :quality_level)
        }),
        BackgroundJobNotice.section(Map.get(state, :background_jobs)),
        build_clock_section(%{now: Map.get(state, :now)})
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    context_block(body)
  end

  # --- Blank Detection ---

  @doc """
  Treats `nil` or whitespace-only strings/binaries as blank.
  """
  def blank?(nil), do: true

  def blank?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  def blank?(_), do: false

  # --- XML-like Block Wrappers ---

  @doc """
  Wraps the environment/context body in an XML-like block. Returns \"\" when
  the body is blank so the caller can drop it without leaving an empty
  `<context></context>` block.
  """
  def context_block(body) do
    if blank?(body), do: "", else: "<context>\n#{body}\n</context>"
  end

  @doc """
  Wraps the objective body in an XML-like block. Returns \"\" when the body
  is blank so the caller can drop it without leaving an empty
  `<objective></objective>` block.
  """
  def objective_block(body) do
    if blank?(body), do: "", else: "<objective>\n#{body}\n</objective>"
  end

  @doc """
  Assembles the two initial messages (`[system, user]`) for an agent run.

  Pure — never reads the process dictionary. `combined_prompt` is the already
  joined context/objective block text (a plain `String.t()`); the objective
  stays a string end-to-end. Media attachments (images/audio, see
  `EvoGit.Attachments`) ride on the ROOT agent's first user message ONLY: when
  `parent_id` is nil (this agent is the task root — exactly equivalent to
  SchedMeta depth 0) AND `attachments` is a non-empty list, the user message
  is built as a content-part list —
  `ReqLLM.Context.user([ContentPart.text(combined_prompt) | image/file parts])`
  with parts in input order. Otherwise the legacy binary fast path
  `ReqLLM.Context.user(combined_prompt)` is used, producing a byte-identical
  message shape. Subagents (non-nil `parent_id`) never inherit attachments;
  pass `nil` for `attachments` to force the plain-text path.

  This root gate applies to the `:attachments` TASK OPT ONLY. Media reaching an
  agent through any OTHER channel is not gated — in particular a mid-run
  INJECTED user message may carry attachments for an agent at ANY depth (see
  `build_injected_message/2`).
  """
  @spec build_initial_messages(String.t(), String.t(), integer() | nil, term()) ::
          [ReqLLM.Message.t()]
  def build_initial_messages(system_prompt, combined_prompt, parent_id, attachments) do
    [
      ReqLLM.Context.system(system_prompt),
      build_first_user_message(combined_prompt, parent_id, attachments)
    ]
  end

  @doc """
  Builds the agent's first USER message (the `[system, user]` user half).

  Pure — never reads the process dictionary. `combined_prompt` is the already
  joined context/objective block text (a plain `String.t()`). Media
  attachments (images/audio, see `EvoGit.Attachments`) ride on the ROOT
  agent's first user message ONLY: when `parent_id` is nil (this agent is the
  task root — exactly equivalent to SchedMeta depth 0) AND `attachments` is a
  non-empty list, the message is built as a content-part list —
  `ReqLLM.Context.user([ContentPart.text(combined_prompt) | image/file parts])`
  with parts in input order. Otherwise the legacy binary fast path
  `ReqLLM.Context.user(combined_prompt)` is used, producing a byte-identical
  message shape. Subagents (non-nil `parent_id`) never inherit attachments;
  pass `nil` for `attachments` to force the plain-text path.

  The returned message carries whatever metadata `ReqLLM.Context.user/1`
  assigns (typically none) — turn-tagging happens at the call site
  (`tag_context_messages_with_turn/2`). Extracted verbatim from
  `build_initial_messages/4` so the compression refresh
  (`refresh_first_user_message/2`) reproduces exactly the same message shape.
  """
  @spec build_first_user_message(String.t(), integer() | nil, term()) :: ReqLLM.Message.t()
  def build_first_user_message(combined_prompt, parent_id, attachments) do
    case {is_nil(parent_id), attachments} do
      {true, [_ | _]} ->
        ReqLLM.Context.user(EvoGit.Attachments.to_content_parts(combined_prompt, attachments))

      _ ->
        ReqLLM.Context.user(combined_prompt)
    end
  end

  @doc """
  Rebuilds the agent's first user message with a FRESH `<context>` block.

  Kept public for backward compatibility (and covered by tests). Compression
  itself no longer rewrites message #1 — doing so would break the provider's
  cached prefix, which is why the mid-run refresh is delivered as an APPENDED
  message instead (`build_context_refresh_message/2`). The context tree (the
  CONTEXT.md chain for the agent's node) is otherwise frozen at run start, so an
  agent that edited or created CONTEXT.md files in its worktree during the run
  would keep seeing the stale chain.

  `msg` is the EXISTING first user message (as it sits in the conversation);
  `state` is a plain map (a `%EvoGit.Agent.LoopState{}`) carrying
  `:node_path, :repo_path, :parent_id, :repo_less, :foreign_repos,
  :repo_notes, :quality_level` PLUS:

    * `:objective` — the RAW objective string (re-rendered through the SAME
      `objective_block/1`, so the `<objective>` block stays byte-identical);
    * `:attachments` — the SAME value originally passed to
      `build_initial_messages/4` (already `nil` for repo-less agents), so media
      content parts on the root agent's first message are reproduced
      byte-identically from the stored base64;
    * `:now` — the CLOCK seam (see `build_clock_section/1`). Production never
      sets it (absent = the real local clock at call time), so a refreshed
      message carries a FRESH `Current local time:` line; a test that compares
      a refreshed message against the original must pass the SAME fixed `:now`
      on both sides.

  The returned message preserves the ORIGINAL message's metadata
  (`%{refreshed | metadata: msg.metadata}`) so the turn-0 tag + creation
  timestamp survive. When the CONTEXT.md chain did NOT change and `:now` is
  pinned to the same value, the refreshed message is structurally identical to
  the original.
  """
  @spec refresh_first_user_message(ReqLLM.Message.t(), map()) :: ReqLLM.Message.t()
  def refresh_first_user_message(%ReqLLM.Message{} = msg, %{} = state) do
    objective_body =
      case Map.get(state, :objective) do
        objective when is_binary(objective) -> if blank?(objective), do: "", else: objective
        _ -> ""
      end

    combined_prompt =
      [
        build_context_block(state),
        objective_block(objective_body)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n---\n\n")

    refreshed =
      build_first_user_message(
        combined_prompt,
        Map.get(state, :parent_id),
        Map.get(state, :attachments)
      )

    %{refreshed | metadata: msg.metadata}
  end

  # The refresh notice prepended to every runtime-context refresh message. The
  # wording is pinned: it must (a) say the message is machine-generated, (b) say
  # it SUPERSEDES every earlier `<context>` snapshot, (c) say the `<objective>`
  # block is unchanged, and (d) forbid acknowledging it, so a compressed agent
  # neither re-sends a stale context tree nor spends a turn on pleasantries.
  @context_refresh_notice "This is an automatically generated runtime-context refresh. " <>
                            "It SUPERSEDES any earlier <context> snapshot in this conversation, " <>
                            "including the one in the first user message. " <>
                            "The <objective> block is unchanged. " <>
                            "Continue the task directly — do NOT acknowledge this refresh."

  @doc """
  Builds an appenedable `<context>` REFRESH message carrying the CURRENT context
  tree.

  Used by `EvoGit.Agent.ContextCompression.compress_if_needed/2` on EVERY
  compression event (both the prune-only and the summarising path) instead of
  rewriting message #1: the first two messages (system prompt + original user
  message) must stay BYTE-IDENTICAL so the provider's prompt cache keeps hitting
  and the verbatim objective is never re-rendered. The freshness is delivered as
  a NEW final `:user` message (`build_context_block/1` — the same assembly the
  first user message uses, so a CONTEXT.md edit made in the worktree mid-run is
  now visible).

  The message states that it SUPERSEDES any earlier `<context>` snapshot and
  that the `<objective>` block is unchanged; it deliberately carries NO
  objective block of its own (the objective stays verbatim in message #1).
  Its trailing CLOCK line (`build_clock_section/1`) is re-rendered from the
  `:now` seam on `state` — absent in production, so every refresh carries a
  FRESH `Current local time:` reading while message #1 keeps the run-start one.

  `turn` — when an integer, the message is turn-tagged exactly like every other
  appended message via `tag_message_turn/2`; `nil` leaves it untagged.

  Returns `nil` when `build_context_block/1` renders blank (nothing to refresh),
  so the caller can skip appending rather than injecting an empty message.
  """
  @spec build_context_refresh_message(map(), integer() | nil) :: ReqLLM.Message.t() | nil
  def build_context_refresh_message(%{} = state, turn) do
    case build_context_block(state) do
      context when is_binary(context) and context != "" ->
        message = ReqLLM.Context.user(@context_refresh_notice <> "\n\n" <> context)

        case turn do
          turn when is_integer(turn) -> tag_message_turn(message, turn)
          _ -> message
        end

      _blank ->
        nil
    end
  end

  @doc """
  Materializes ONE injected (mid-run) user message into an LLM user message.

  Injected messages travel through the pending-message queue
  (`EvoGit.AgentScheduler.send_user_message/2` → the `pending_user_messages`
  drain) either as a legacy plain `String.t()` or as a `%{text:,
  attachments:}` map (`EvoGit.Attachments.message/1` normalizes both), so this
  helper normalizes first and then materializes:

    * a legacy binary, or a map whose attachments are `nil`/`[]` →
      `ReqLLM.Context.user(text)` — the plain-text fast path;
    * a map carrying attachments →
      `ReqLLM.Context.user([ContentPart.text(text) | image/file parts])` via
      `EvoGit.Attachments.to_content_parts/2`, parts in input order.

  NO root gate: unlike the `:attachments` TASK OPT (root agent's first user
  message only — see `build_initial_messages/4`), ANY agent at ANY depth may
  receive an injected message carrying media.

  `turn` — when an integer, the message is turn-tagged exactly as every other
  injected message via `tag_message_turn/2` (that also stamps a creation-time
  timestamp); `nil` skips tagging entirely, so the returned message is the raw
  `ReqLLM.Context.user/1` result. Pure — never reads the process dictionary;
  a malformed message map raises a descriptive `ArgumentError` (spec-error
  style, see `EvoGit.Attachments.validate_message!/1`).
  """
  @spec build_injected_message(String.t() | map(), integer() | nil) :: ReqLLM.Message.t()
  def build_injected_message(message, turn) do
    %{text: text, attachments: attachments} = EvoGit.Attachments.message(message)

    user_message =
      case attachments do
        [_ | _] -> ReqLLM.Context.user(EvoGit.Attachments.to_content_parts(text, attachments))
        _ -> ReqLLM.Context.user(text)
      end

    case turn do
      turn when is_integer(turn) -> tag_message_turn(user_message, turn)
      _ -> user_message
    end
  end

  # --- ETS Sync Helpers ---

  def sync_context_to_ets(agent_id, context) do
    AgentScheduler.update_agent_context(agent_id, context)
  end

  def sync_turn_to_ets(agent_id, turn) do
    AgentScheduler.update_agent_turn(agent_id, turn)
  end

  def sync_total_tokens_to_ets(agent_id, total_tokens) do
    AgentScheduler.update_total_tokens(agent_id, total_tokens)
  end

  # --- Turn Tagging ---

  @doc """
  Tags a single message struct with the given turn number via its metadata.
  Also stamps a creation-time timestamp (Unix seconds) on the metadata,
  idempotently — an already-present timestamp is preserved.
  """
  def tag_message_turn(%ReqLLM.Message{} = msg, turn) when is_integer(turn) do
    metadata = Map.put(msg.metadata || %{}, :turn, turn)
    metadata = Map.put_new(metadata, :timestamp, System.system_time(:second))
    %{msg | metadata: metadata}
  end

  @doc """
  Stamps a single message struct with a creation-time timestamp (Unix seconds)
  via its metadata, idempotently — an already-present timestamp is preserved.
  Tolerates `metadata: nil`. For append sites that are NOT turn-tagged.
  """
  def tag_message_timestamp(%ReqLLM.Message{} = msg) do
    metadata = msg.metadata || %{}
    %{msg | metadata: Map.put_new(metadata, :timestamp, System.system_time(:second))}
  end

  @doc """
  Tags the last message in a context with the given turn number.
  """
  def tag_context_tail_with_turn(%ReqLLM.Context{} = context, turn)
      when is_integer(turn) do
    case context.messages do
      [] ->
        context

      msgs ->
        last = List.last(msgs)
        tagged = tag_message_turn(last, turn)
        %{context | messages: List.replace_at(msgs, length(msgs) - 1, tagged)}
    end
  end

  @doc """
  Tags ALL messages in a context with the given turn number (for initial setup).
  """
  def tag_context_messages_with_turn(%ReqLLM.Context{} = context, turn)
      when is_integer(turn) do
    tagged_msgs = Enum.map(context.messages, &tag_message_turn(&1, turn))
    %{context | messages: tagged_msgs}
  end
end
