defmodule EvoGit.Agent.Completion do
  @moduledoc """
  The ONE completion side-effect writer for a finished agent run.

  An agent finishes by replying with NO tool calls — that reply text IS the
  report (`EvoGit.Agent.CompletionProtocol` + `EvoGit.Agent.ToolDispatch`).
  There is no completion tool: this module is not a tool and exposes no schema.
  It is called by `EvoGit.Agent.ToolDispatch.build_completion/2,3` with the
  final report text and the commit sha captured at completion.

  `complete/4` records the completion exactly once:
  - a git note on the final commit (only when a base commit is known),
  - the archive refs plus the ONE streaming `task_agent_archives` row (only when
    archiving and a base commit is known),
  - a `%EvoGit.Agent.Result{}` carrying `commit_sha`, `branch` and `repo_id`,
    which every downstream consumer (task persistence, `merge_and_report/3,4`,
    the `genesis/agent_*` review branch, the dashboard) reads unchanged.

  The side effects are identical regardless of how the report text was produced,
  so every downstream consumer is oblivious to the completion route.
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result

  @doc """
  Performs the actual completion: records branch name, adds metadata note.

  Returns a `%EvoGit.Agent.Result{}` struct with :result, :commit_sha, :branch, and :repo_id.

  The `repo_id` field is automatically populated from the process dictionary
  key `:evogit_repo_id` (set at dispatch time).

  ## Options
    - `:base_commit` - The commit SHA the agent started on (required for metadata)
    - `:parent_id` - The parent agent ID (if this is a subagent)
    - `:depth` - The depth of this agent in the hierarchy
    - `:objective` - The objective/task this agent was working on
    - `:usage` - The cumulative `EvoGit.Agent.Usage.t()` for this agent run
  """
  @spec complete(pos_integer(), String.t(), String.t(), keyword()) :: Result.t()
  def complete(agent_id, result, commit_sha, opts \\ []) when is_list(opts) do
    base_commit = Keyword.get(opts, :base_commit)
    parent_id = Keyword.get(opts, :parent_id)
    depth = Keyword.get(opts, :depth, 0)
    objective = Keyword.get(opts, :objective)
    archive = Keyword.get(opts, :archive, false)
    repo_path = Process.get(:repo_path)

    # Derive branch name using task-scoped naming: evogit-agent-T<task_number>-A<task_local_id>
    # Look up task_id/task_number from SchedMeta and task_local_id from AgentState via ETS
    {task_id, task_number, task_local_id} = lookup_task_info(agent_id)
    branch_name = "evogit-agent-T#{task_number}-A#{task_local_id}"

    # Add metadata as git note (if we have the base commit)
    if base_commit do
      add_metadata_note(repo_path, commit_sha, %{
        agent_id: agent_id,
        base_commit: base_commit,
        final_commit: commit_sha,
        parent_id: parent_id,
        depth: depth,
        objective: objective,
        result: result,
        usage: format_usage_for_note(Keyword.get(opts, :usage)),
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        agent_type: Keyword.get(opts, :agent_type),
        context_node_path: Keyword.get(opts, :context_node_path)
      })
    end

    if archive and base_commit do
      write_archive_refs(repo_path, task_id, task_local_id, agent_id, base_commit, commit_sha, %{
        objective: objective,
        result: result,
        parent_id: parent_id,
        depth: depth,
        branch_name: branch_name,
        usage: Keyword.get(opts, :usage),
        compression_count: Keyword.get(opts, :compression_count, 0),
        repo_id: Keyword.get(opts, :repo_id),
        repo_root: Keyword.get(opts, :repo_root),
        completed_at: DateTime.utc_now(),
        llm_model: Keyword.get(opts, :llm_model),
        model_id: Keyword.get(opts, :model_id),
        model_spec: Keyword.get(opts, :model_spec),
        llm_generation_params: Keyword.get(opts, :llm_generation_params, []),
        compression_threshold: Keyword.get(opts, :compression_threshold),
        max_turns: Keyword.get(opts, :max_turns),
        max_retries: Keyword.get(opts, :max_retries),
        max_agent_depth: Keyword.get(opts, :max_agent_depth),
        foreign_repos: Keyword.get(opts, :foreign_repos, []),
        agent_type: Keyword.get(opts, :agent_type),
        context_node_path: Keyword.get(opts, :context_node_path)
      })
    end

    %Result{
      result: result,
      commit_sha: commit_sha,
      branch: branch_name,
      repo_id: Process.get(:evogit_repo_id),
      usage: Keyword.get(opts, :usage)
    }
  end

  defp lookup_task_info(agent_id) do
    case EvoGit.AgentScheduler.Store.get_task_info(agent_id) do
      {:ok, task_id, task_number, task_local_id} ->
        {task_id, task_number, task_local_id}

      {:error, :not_found} ->
        {0, nil, 0}
    end
  end

  defp add_metadata_note(repo_path, commit_sha, metadata) when is_map(metadata) do
    note_content = Jason.encode!(metadata, pretty: true)

    # Use a notes ref specific to evogit to avoid conflicts with user's notes
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"]) do
      {:ok, _} ->
        Logger.info("Wrote git note for commit #{commit_sha} (ref: evogit)")
        :ok

      {:error, {:conflict, _msg}} ->
        # git notes add returns exit code 1 when note already exists — overwrite with force
        handle_fallback(repo_path, commit_sha, note_content)

      {:error, {_, _msg}} ->
        # If custom ref fails (might not exist yet), try with force to create it
        handle_fallback(repo_path, commit_sha, note_content)
    end
  end

  defp handle_fallback(repo_path, commit_sha, note_content) do
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"], true) do
      {:ok, _} ->
        Logger.info("Wrote git note for commit #{commit_sha} (ref: evogit, forced)")
        :ok

      {:error, {:conflict, msg}} ->
        Logger.warning("Failed to write git note for commit #{commit_sha}: #{msg}")
        {:error, msg}

      {:error, {_code, msg}} ->
        Logger.warning("Failed to write git note for commit #{commit_sha}: #{msg}")
        {:error, msg}
    end
  end

  @doc """
  Retrieves the metadata for an agent from their final commit's git note.

  Returns {:ok, metadata_map} or {:error, {:no_note, _}} / {:error, {:invalid_json, _}} /
  {:error, {:enoent, _}} (see `EvoGit.Adapters.Git.get_note/4`).

  ## Metadata includes
    - `agent_id` - The agent's ID
    - `base_commit` - The commit the agent started on
    - `final_commit` - The agent's final commit
    - `parent_id` - The parent agent ID (if subagent)
    - `depth` - Depth in the agent hierarchy
    - `objective` - The objective/task the agent was given
    - `result` - The agent's final result message
    - `completed_at` - ISO8601 timestamp of completion
  """
  def get_agent_metadata(repo_path, commit_sha) do
    Git.get_note(repo_path, commit_sha, ["--ref=evogit"])
  end

  defp format_usage_for_note(nil), do: nil

  defp format_usage_for_note(%EvoGit.Agent.Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      cost: usage.total_cost
    }
  end

  defp format_usage_for_archive(nil), do: nil

  defp format_usage_for_archive(%EvoGit.Agent.Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      input_cost: usage.input_cost,
      output_cost: usage.output_cost,
      total_cost: usage.total_cost,
      cached_tokens: usage.cached_tokens,
      cache_creation_tokens: usage.cache_creation_tokens,
      cache_hit_rate: EvoGit.Agent.Usage.cache_hit_rate(usage)
    }
  end

  defp write_archive_refs(
         repo_path,
         task_id,
         task_local_id,
         agent_id,
         base_commit,
         final_commit,
         data
       )
       when is_map(data) do
    ref_start = "refs/genesis/archive/T#{task_id}-A#{task_local_id}-start"
    ref_final = "refs/genesis/archive/T#{task_id}-A#{task_local_id}-final"

    # Write refs to protect commits from gc
    Git.update_ref(repo_path, ref_start, base_commit)
    Git.update_ref(repo_path, ref_final, final_commit)

    record = %{
      agent_id: agent_id,
      parent_id: data[:parent_id],
      depth: data[:depth] || 0,
      objective: data[:objective],
      result: data[:result],
      base_commit: base_commit,
      final_commit: final_commit,
      archive_ref_start: ref_start,
      archive_ref_final: ref_final,
      branch_name: data[:branch_name],
      usage: format_usage_for_archive(data[:usage]),
      compression_count: data[:compression_count] || 0,
      repo_path: repo_path,
      repo_id: data[:repo_id],
      repo_root: data[:repo_root],
      started_at: iso8601(parse_started_at(Process.get(:evogit_started_at))),
      completed_at: iso8601(data[:completed_at]),
      llm_settings:
        build_llm_settings(
          data[:llm_model],
          data[:llm_generation_params],
          data[:compression_threshold],
          data[:model_id],
          data[:model_spec]
        ),
      agent_settings: %{
        max_turns: data[:max_turns],
        max_retries: data[:max_retries],
        max_agent_depth: data[:max_agent_depth]
      },
      foreign_repos: format_foreign_repos(data[:foreign_repos]),
      agent_type: data[:agent_type],
      context_node_path: data[:context_node_path]
    }

    # Persist this agent's archive row RIGHT NOW — the streaming write. One row
    # per `{task_id, agent_id}` is upserted into `task_agent_archives` at agent
    # completion, so nothing is buffered in memory and nothing has to be
    # collected at task end (a crash-retry completing twice REPLACES the row).
    # An unknown task id (SchedMeta/scheduler lookup miss → 0) cannot identify
    # a row: skip the write (refs are still written above) instead of failing.
    if task_id in [nil, 0, ""] do
      Logger.debug(
        "Archive: no task id for agent #{agent_id} — skipping the archive row write " <>
          "(refs #{ref_start} and #{ref_final} were written)"
      )
    else
      case EvoGit.TaskRegistry.put_task_archive(Map.put(record, :task_id, task_id)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Archive: the archive row for agent #{agent_id} (task #{task_id}) was not persisted: " <>
              inspect(reason)
          )
      end
    end

    Logger.info("Archive: Wrote refs #{ref_start} and #{ref_final} for agent #{agent_id}")
  end

  defp parse_started_at(nil), do: nil

  defp parse_started_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  # The archive table keeps `started_at`/`completed_at` as ISO-8601 TEXT and
  # returns exactly the bytes that were written (no re-formatting round trip),
  # so the producer emits ISO-8601 STRINGS — never a `%DateTime{}`.
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_other), do: nil

  defp build_llm_settings(model, generation_params, compression_threshold, model_id, model_spec)
       when is_list(generation_params) or is_nil(generation_params) do
    # Keep the full selection alongside the effective request settings: model_id
    # identifies the account/slot pool, not the selected catalog model.
    %{
      model: model,
      context_compression_threshold: compression_threshold,
      model_id: model_id,
      model_spec: model_spec
    }
    |> Map.merge(Map.new(generation_params || []))
    |> archive_json()
  end

  # The archive row is PLAIN JSON (`Store.Types.ArchiveColumns`), so the
  # settings must be JSON-clean BY CONSTRUCTION: generation params legitimately
  # carry a keyword-list `provider_options` (tuples, which Jason cannot
  # encode), and an account with an explicit `api_key_env_var` carries
  # `:api_key`. A tuple or a raw secret here used to make the whole archive
  # write fail, silently dropping the row.
  defp archive_json(nil), do: nil
  defp archive_json(value) when is_boolean(value), do: value
  defp archive_json(value) when is_atom(value), do: Atom.to_string(value)
  defp archive_json(value) when is_binary(value) or is_number(value), do: value
  defp archive_json(%_{} = struct), do: struct |> Map.from_struct() |> archive_json()

  # Credentials are NEVER archived: an `api_key` key is dropped outright (at
  # any depth), never replaced by a placeholder a consumer could mistake for a
  # value.
  defp archive_json(%{} = map) do
    for {key, value} <- map, not credential?(key), into: %{} do
      {archive_json_key(key), archive_json(value)}
    end
  end

  defp archive_json(list) when is_list(list) do
    if pairs?(list) do
      for {key, value} <- list, not credential?(key), into: %{} do
        {archive_json_key(key), archive_json(value)}
      end
    else
      Enum.map(list, &archive_json/1)
    end
  end

  # Anything else (a pid, ref or function that should never be in request
  # settings) is archived as its inspected form so ONE exotic value cannot cost
  # the whole row.
  defp archive_json(other), do: inspect(other)

  defp archive_json_key(key) when is_binary(key), do: key
  defp archive_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp archive_json_key(key), do: inspect(key)

  defp credential?(:api_key), do: true
  defp credential?("api_key"), do: true
  defp credential?(_key), do: false

  # A keyword list or any other list of 2-tuples: a JSON object, not an array.
  defp pairs?([{_key, _value} | _rest] = list), do: Enum.all?(list, &is_tuple_of_two?/1)
  defp pairs?(_list), do: false

  defp is_tuple_of_two?({_key, _value}), do: true
  defp is_tuple_of_two?(_other), do: false

  defp format_foreign_repos(nil), do: []

  defp format_foreign_repos(repos) when is_list(repos) do
    Enum.map(repos, fn repo ->
      %{id: repo.id, root: repo.root, description: repo.description}
    end)
  end
end
