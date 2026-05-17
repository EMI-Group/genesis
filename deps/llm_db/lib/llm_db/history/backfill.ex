defmodule LLMDB.History.Backfill do
  @moduledoc """
  Backfills model history by diffing committed provider snapshots across git history.

  This module is intentionally git-driven and infrastructure-free: it reads
  `priv/llm_db/providers/*.json` from commit history and writes append-only
  NDJSON event files under a local history directory.
  """

  @providers_dir "priv/llm_db/providers"
  @manifest_path "priv/llm_db/manifest.json"
  @default_output_dir Path.join(["priv", "llm_db", "history"])
  @lineage_overrides_file "lineage_overrides.json"

  @sortable_list_keys MapSet.new(["aliases", "tags", "input", "output"])

  # Keep inference conservative. Use lineage overrides for ambiguous migrations.
  @lineage_inference_threshold 30

  @type summary :: %{
          commits_scanned: non_neg_integer(),
          commits_processed: non_neg_integer(),
          snapshots_written: non_neg_integer(),
          events_written: non_neg_integer(),
          output_dir: String.t(),
          from_commit: String.t() | nil,
          to_commit: String.t() | nil
        }

  @type check_result ::
          :history_unavailable
          | :up_to_date
          | {:outdated, %{new_commits: non_neg_integer(), latest_commit: String.t()}}

  @doc """
  Runs a full history backfill from git.

  ## Options

  - `:from` - Optional start commit (inclusive)
  - `:to` - Optional end commit/reference (default: `"HEAD"`)
  - `:output_dir` - Output directory (default: `"priv/llm_db/history"`)
  - `:force` - Remove previously generated history files first (default: `false`)
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    force? = Keyword.get(opts, :force, false)
    from_ref = Keyword.get(opts, :from)
    to_ref = Keyword.get(opts, :to, "HEAD")

    with :ok <- prepare_output_dir(output_dir, force?),
         {:ok, lineage_overrides} <- load_lineage_overrides(output_dir),
         {:ok, commits} <- history_commits(from_ref, to_ref),
         {:ok, summary} <- process_commits(commits, output_dir, lineage_overrides) do
      {:ok, summary}
    end
  end

  @doc """
  Incrementally syncs history output from the last generated commit to `:to` (default `HEAD`).

  If no history output exists yet, this performs a full backfill into the output directory.

  ## Options

  - `:to` - Optional end commit/reference (default: `"HEAD"`)
  - `:output_dir` - Output directory (default: `"priv/llm_db/history"`)
  """
  @spec sync(keyword()) :: {:ok, summary()} | {:error, term()}
  def sync(opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    to_ref = Keyword.get(opts, :to, "HEAD")

    with :ok <- ensure_output_dir(output_dir),
         {:ok, lineage_overrides} <- load_lineage_overrides(output_dir),
         {:ok, meta} <- read_meta(output_dir) do
      case meta do
        nil ->
          if partial_history_output?(output_dir) do
            {:error,
             "history output is partially present at #{output_dir}. Re-run with mix llm_db.history.backfill --force."}
          else
            with {:ok, commits} <- history_commits(nil, to_ref),
                 {:ok, summary} <- process_commits(commits, output_dir, lineage_overrides) do
              {:ok, summary}
            end
          end

        meta_map ->
          sync_from_meta(meta_map, to_ref, output_dir, lineage_overrides)
      end
    end
  end

  @doc """
  Checks whether generated history is current with git history.

  Returns `:history_unavailable` when `meta.json` is missing, `:up_to_date` when no
  metadata commits are pending, or `{:outdated, ...}` when new commits exist.
  """
  @spec check(keyword()) :: {:ok, check_result()} | {:error, term()}
  def check(opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    to_ref = Keyword.get(opts, :to, "HEAD")

    with {:ok, meta} <- read_meta(output_dir) do
      case meta do
        nil ->
          {:ok, :history_unavailable}

        meta_map ->
          with {:ok, %{pending_commits: commits}} <-
                 resolve_history_anchor(meta_map, to_ref, output_dir) do
            case commits do
              [] ->
                {:ok, :up_to_date}

              _ ->
                {:ok,
                 {:outdated, %{new_commits: length(commits), latest_commit: List.last(commits)}}}
            end
          end
      end
    end
  end

  @doc """
  Diffs two model maps and returns deterministic model events.

  Expects maps keyed by `"provider:model_id"` with normalized model payload values.
  """
  @spec diff_models(%{optional(String.t()) => map()}, %{optional(String.t()) => map()}) :: [map()]
  def diff_models(previous_models, current_models)
      when is_map(previous_models) and is_map(current_models) do
    previous_keys = Map.keys(previous_models) |> MapSet.new()
    current_keys = Map.keys(current_models) |> MapSet.new()

    introduced =
      MapSet.difference(current_keys, previous_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn model_key ->
        %{type: "introduced", model_key: model_key, changes: []}
      end)

    removed =
      MapSet.difference(previous_keys, current_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn model_key ->
        %{type: "removed", model_key: model_key, changes: []}
      end)

    changed =
      MapSet.intersection(previous_keys, current_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.reduce([], fn model_key, acc ->
        before_model = Map.fetch!(previous_models, model_key)
        after_model = Map.fetch!(current_models, model_key)
        changes = deep_changes(before_model, after_model, [])

        if changes == [] do
          acc
        else
          [%{type: "changed", model_key: model_key, changes: changes} | acc]
        end
      end)
      |> Enum.reverse()

    introduced ++ removed ++ changed
  end

  @doc false
  @spec snapshot_digest(%{optional(String.t()) => map()}) :: String.t()
  def snapshot_digest(models) when is_map(models) do
    models
    |> canonical_digest_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Internal pipeline

  defp sync_from_meta(meta, to_ref, output_dir, lineage_overrides) do
    with {:ok, resolution} <- resolve_history_anchor(meta, to_ref, output_dir) do
      case resolution do
        %{resolved_commit: from_commit, pending_commits: commits, repaired?: repaired?} ->
          case commits do
            [] ->
              summary = noop_summary(meta, output_dir, from_commit)

              if repaired? do
                write_meta(summary, output_dir)
              end

              {:ok, summary}

            _ ->
              process_incremental_commits(
                meta,
                from_commit,
                commits,
                output_dir,
                lineage_overrides
              )
          end
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_incremental_commits(meta, from_commit, commits, output_dir, lineage_overrides) do
    with {:ok, state_by_file} <- load_commit_state(from_commit) do
      previous_models = flatten_state_models(state_by_file)

      previous_lineage_by_key =
        load_previous_lineage(output_dir, Map.keys(previous_models), previous_models)

      initial = %{
        commits_scanned: length(commits),
        commits_processed: 0,
        snapshots_written: 0,
        events_written: 0,
        output_dir: output_dir,
        from_commit: meta_value(meta, "from_commit") || from_commit,
        to_commit: from_commit,
        state_by_file: state_by_file,
        previous_models: previous_models,
        previous_sha: from_commit,
        previous_lineage_by_key: previous_lineage_by_key,
        lineage_overrides: lineage_overrides
      }

      final =
        Enum.reduce(commits, initial, fn sha, acc ->
          process_commit(sha, acc)
        end)

      summary =
        final
        |> summarize(base_counts(meta))
        |> Map.put(:generated_at, DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put(:source_repo, source_repo())

      write_meta(summary, output_dir)
      {:ok, summary}
    else
      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp noop_summary(meta, output_dir, to_commit) do
    %{
      commits_scanned: meta_count(meta, "commits_scanned"),
      commits_processed: meta_count(meta, "commits_processed"),
      snapshots_written: meta_count(meta, "snapshots_written"),
      events_written: meta_count(meta, "events_written"),
      output_dir: output_dir,
      from_commit: meta_value(meta, "from_commit"),
      to_commit: to_commit,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_repo: source_repo()
    }
  end

  defp base_counts(meta) do
    %{
      commits_scanned: meta_count(meta, "commits_scanned"),
      commits_processed: meta_count(meta, "commits_processed"),
      snapshots_written: meta_count(meta, "snapshots_written"),
      events_written: meta_count(meta, "events_written")
    }
  end

  defp summarize(final, base_counts) do
    base =
      base_counts ||
        %{commits_scanned: 0, commits_processed: 0, snapshots_written: 0, events_written: 0}

    final
    |> Map.drop([
      :state_by_file,
      :previous_models,
      :previous_sha,
      :previous_lineage_by_key,
      :lineage_overrides
    ])
    |> Map.update!(:commits_scanned, &(&1 + base.commits_scanned))
    |> Map.update!(:commits_processed, &(&1 + base.commits_processed))
    |> Map.update!(:snapshots_written, &(&1 + base.snapshots_written))
    |> Map.update!(:events_written, &(&1 + base.events_written))
  end

  defp prepare_output_dir(output_dir, force?) do
    events_dir = Path.join(output_dir, "events")
    meta_path = Path.join(output_dir, "meta.json")
    snapshots_path = Path.join(output_dir, "snapshots.ndjson")

    if force? do
      File.rm_rf!(events_dir)
      File.rm_rf!(meta_path)
      File.rm_rf!(snapshots_path)
    end

    if not force? and
         (File.exists?(events_dir) or File.exists?(meta_path) or File.exists?(snapshots_path)) do
      {:error,
       "history output already exists at #{output_dir}. Re-run with --force for one-time regeneration."}
    else
      File.mkdir_p!(events_dir)
      :ok
    end
  end

  defp ensure_output_dir(output_dir) do
    events_dir = Path.join(output_dir, "events")
    File.mkdir_p!(events_dir)
    :ok
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp partial_history_output?(output_dir) do
    events_dir = Path.join(output_dir, "events")
    snapshots_path = Path.join(output_dir, "snapshots.ndjson")
    meta_path = Path.join(output_dir, "meta.json")

    events_present? =
      case File.ls(events_dir) do
        {:ok, entries} ->
          Enum.any?(entries, &String.ends_with?(&1, ".ndjson"))

        {:error, _} ->
          false
      end

    (events_present? or File.exists?(snapshots_path)) and not File.exists?(meta_path)
  end

  defp history_commits(from_ref, to_ref) do
    with {:ok, commits_output} <-
           git([
             "rev-list",
             "--reverse",
             "--topo-order",
             to_ref,
             "--",
             @providers_dir,
             @manifest_path
           ]),
         commits <- parse_lines(commits_output),
         {:ok, commits} <- maybe_apply_from(commits, from_ref) do
      {:ok, commits}
    end
  end

  defp history_commits_after(from_ref, to_ref) do
    with {:ok, commits} <- history_commits(from_ref, to_ref) do
      case commits do
        [] -> {:ok, []}
        [_from | rest] -> {:ok, rest}
      end
    end
  end

  defp maybe_apply_from(commits, nil), do: {:ok, commits}

  defp maybe_apply_from(commits, from_ref) do
    with {:ok, from_sha} <- git(["rev-parse", "--verify", from_ref]),
         from_sha <- String.trim(from_sha),
         true <- from_sha in commits do
      commits
      |> Enum.drop_while(&(&1 != from_sha))
      |> then(&{:ok, &1})
    else
      {:error, _reason} ->
        {:error, metadata_history_range_error(from_ref)}

      false ->
        {:error, metadata_history_range_error(from_ref)}
    end
  end

  defp resolve_history_anchor(meta, to_ref, output_dir) do
    case meta_value(meta, "to_commit") do
      from_commit when is_binary(from_commit) ->
        case history_commits_after(from_commit, to_ref) do
          {:ok, commits} ->
            {:ok, %{resolved_commit: from_commit, pending_commits: commits, repaired?: false}}

          {:error, reason} ->
            if reason == metadata_history_range_error(from_commit) do
              resolve_reanchored_history(meta, to_ref, output_dir)
            else
              {:error, reason}
            end
        end

      _ ->
        resolve_reanchored_history(meta, to_ref, output_dir)
    end
  end

  defp resolve_reanchored_history(meta, to_ref, output_dir) do
    with {:ok, snapshot_digest} <- read_last_snapshot_digest(output_dir),
         {:ok, commits} <- history_commits(nil, to_ref),
         {:ok, resolved_commit} <- find_reachable_anchor_by_digest(commits, snapshot_digest),
         {:ok, pending_commits} <- history_commits_after(resolved_commit, to_ref) do
      {:ok,
       %{
         resolved_commit: resolved_commit,
         pending_commits: pending_commits,
         repaired?: resolved_commit != meta_value(meta, "to_commit")
       }}
    else
      {:error, :missing_last_snapshot_digest} ->
        {:error, unrecoverable_history_error(output_dir, :missing_last_snapshot_digest)}

      {:error, :no_matching_snapshot} ->
        {:error, unrecoverable_history_error(output_dir, :no_matching_snapshot)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_reachable_anchor_by_digest(commits, snapshot_digest)
       when is_binary(snapshot_digest) do
    Enum.reduce_while(Enum.reverse(commits), {:error, :no_matching_snapshot}, fn sha, _acc ->
      case commit_models_summary(sha) do
        {:ok, %{digest: ^snapshot_digest}} ->
          {:halt, {:ok, sha}}

        {:ok, _summary} ->
          {:cont, {:error, :no_matching_snapshot}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp read_last_snapshot_digest(output_dir) do
    path = Path.join(output_dir, "snapshots.ndjson")

    cond do
      not File.exists?(path) ->
        {:error, :missing_last_snapshot_digest}

      true ->
        case File.read(path) do
          {:ok, content} ->
            with lines <- parse_lines(content),
                 true <- lines != [],
                 last_line <- List.last(lines),
                 {:ok, snapshot} <- Jason.decode(last_line),
                 snapshot_digest when is_binary(snapshot_digest) <- Map.get(snapshot, "digest") do
              {:ok, snapshot_digest}
            else
              false ->
                {:error, :missing_last_snapshot_digest}

              _ ->
                {:error, :missing_last_snapshot_digest}
            end

          {:error, _reason} ->
            {:error, :missing_last_snapshot_digest}
        end
    end
  end

  defp commit_models_summary(sha) do
    with {:ok, state_by_file} <- load_commit_state(sha) do
      models = flatten_state_models(state_by_file)

      {:ok,
       %{
         model_count: map_size(models),
         digest: snapshot_digest(models)
       }}
    end
  end

  defp metadata_history_range_error(from_ref) do
    "commit #{from_ref} is not reachable in the metadata history range."
  end

  defp unrecoverable_history_error(output_dir, :missing_last_snapshot_digest) do
    "history output at #{output_dir} cannot be re-anchored because the last snapshot digest is unavailable. " <>
      "Re-run with mix llm_db.history.backfill --force."
  end

  defp unrecoverable_history_error(output_dir, :no_matching_snapshot) do
    "history output at #{output_dir} cannot be re-anchored because no reachable metadata commit matches the last snapshot digest. " <>
      "Re-run with mix llm_db.history.backfill --force."
  end

  defp process_commits(commits, output_dir, lineage_overrides) do
    initial = %{
      commits_scanned: length(commits),
      commits_processed: 0,
      snapshots_written: 0,
      events_written: 0,
      output_dir: output_dir,
      from_commit: nil,
      to_commit: nil,
      state_by_file: nil,
      previous_models: nil,
      previous_sha: nil,
      previous_lineage_by_key: %{},
      lineage_overrides: lineage_overrides
    }

    final =
      Enum.reduce(commits, initial, fn sha, acc ->
        process_commit(sha, acc)
      end)

    summary =
      final
      |> summarize(nil)
      |> Map.put(:generated_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put(:source_repo, source_repo())

    write_meta(summary, output_dir)
    {:ok, summary}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp process_commit(sha, acc) do
    case acc.state_by_file do
      nil ->
        first_commit_state(sha, acc)

      state_by_file ->
        incremental_commit_state(sha, state_by_file, acc)
    end
  end

  defp first_commit_state(sha, acc) do
    case load_commit_state(sha) do
      {:ok, state_by_file} when map_size(state_by_file) == 0 ->
        acc

      {:ok, state_by_file} ->
        models = flatten_state_models(state_by_file)
        lineage_by_key = initialize_lineage(models, acc.lineage_overrides)
        events = diff_models(%{}, models) |> attach_lineage(%{}, lineage_by_key)
        commit_date = commit_date_iso8601(sha)
        manifest_generated_at = manifest_generated_at(sha)

        write_snapshot(sha, commit_date, manifest_generated_at, models, events, acc.output_dir)
        write_events(sha, commit_date, events, acc.output_dir)

        %{
          acc
          | commits_processed: acc.commits_processed + 1,
            snapshots_written: acc.snapshots_written + 1,
            events_written: acc.events_written + length(events),
            from_commit: sha,
            to_commit: sha,
            state_by_file: state_by_file,
            previous_models: models,
            previous_sha: sha,
            previous_lineage_by_key: lineage_by_key
        }

      {:error, _} ->
        acc
    end
  end

  defp incremental_commit_state(sha, state_by_file, acc) do
    {:ok, next_state_by_file} = apply_commit_delta(acc.previous_sha, sha, state_by_file)

    previous_models = acc.previous_models || %{}
    previous_lineage_by_key = acc.previous_lineage_by_key || %{}

    current_models = flatten_state_models(next_state_by_file)

    current_lineage_by_key =
      resolve_current_lineage(
        previous_models,
        current_models,
        previous_lineage_by_key,
        acc.lineage_overrides
      )

    events =
      diff_models(previous_models, current_models)
      |> attach_lineage(previous_lineage_by_key, current_lineage_by_key)

    if events == [] do
      %{
        acc
        | commits_processed: acc.commits_processed + 1,
          to_commit: sha,
          state_by_file: next_state_by_file,
          previous_models: current_models,
          previous_sha: sha,
          previous_lineage_by_key: current_lineage_by_key
      }
    else
      commit_date = commit_date_iso8601(sha)
      manifest_generated_at = manifest_generated_at(sha)

      write_snapshot(
        sha,
        commit_date,
        manifest_generated_at,
        current_models,
        events,
        acc.output_dir
      )

      write_events(sha, commit_date, events, acc.output_dir)

      %{
        acc
        | commits_processed: acc.commits_processed + 1,
          snapshots_written: acc.snapshots_written + 1,
          events_written: acc.events_written + length(events),
          to_commit: sha,
          state_by_file: next_state_by_file,
          previous_models: current_models,
          previous_sha: sha,
          previous_lineage_by_key: current_lineage_by_key
      }
    end
  end

  defp initialize_lineage(models, lineage_overrides) do
    models
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn model_key, acc ->
      lineage = lineage_for_model_key(model_key, lineage_overrides, %{}, acc, model_key)
      Map.put(acc, model_key, lineage)
    end)
  end

  defp resolve_current_lineage(
         previous_models,
         current_models,
         previous_lineage_by_key,
         lineage_overrides
       ) do
    previous_keys = Map.keys(previous_models) |> MapSet.new()
    current_keys = Map.keys(current_models) |> MapSet.new()

    shared_keys =
      MapSet.intersection(previous_keys, current_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    removed_keys =
      MapSet.difference(previous_keys, current_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    introduced_keys =
      MapSet.difference(current_keys, previous_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    current_lineage_by_key =
      Enum.reduce(shared_keys, %{}, fn model_key, acc ->
        default_lineage = Map.get(previous_lineage_by_key, model_key, model_key)

        lineage =
          lineage_for_model_key(
            model_key,
            lineage_overrides,
            previous_lineage_by_key,
            acc,
            default_lineage
          )

        Map.put(acc, model_key, lineage)
      end)

    {current_lineage_by_key, unresolved_introduced} =
      Enum.reduce(introduced_keys, {current_lineage_by_key, []}, fn model_key,
                                                                    {acc, unresolved} ->
        if Map.has_key?(lineage_overrides, model_key) do
          lineage =
            lineage_for_model_key(
              model_key,
              lineage_overrides,
              previous_lineage_by_key,
              acc,
              model_key
            )

          {Map.put(acc, model_key, lineage), unresolved}
        else
          {acc, [model_key | unresolved]}
        end
      end)

    unresolved_introduced = Enum.reverse(unresolved_introduced)

    inferred_matches =
      infer_lineage_matches(removed_keys, unresolved_introduced, previous_models, current_models)

    {current_lineage_by_key, matched_introduced} =
      Enum.reduce(inferred_matches, {current_lineage_by_key, MapSet.new()}, fn {new_key, old_key},
                                                                               {acc, matched} ->
        default_lineage = Map.get(previous_lineage_by_key, old_key, old_key)

        lineage =
          lineage_for_model_key(
            new_key,
            lineage_overrides,
            previous_lineage_by_key,
            acc,
            default_lineage
          )

        {Map.put(acc, new_key, lineage), MapSet.put(matched, new_key)}
      end)

    Enum.reduce(unresolved_introduced, current_lineage_by_key, fn model_key, acc ->
      if MapSet.member?(matched_introduced, model_key) do
        acc
      else
        lineage =
          lineage_for_model_key(
            model_key,
            lineage_overrides,
            previous_lineage_by_key,
            acc,
            model_key
          )

        Map.put(acc, model_key, lineage)
      end
    end)
  end

  defp infer_lineage_matches(removed_keys, introduced_keys, previous_models, current_models) do
    candidates =
      for removed_key <- removed_keys,
          introduced_key <- introduced_keys,
          score =
            lineage_inference_score(
              Map.get(previous_models, removed_key, %{}),
              Map.get(current_models, introduced_key, %{})
            ),
          score >= @lineage_inference_threshold do
        {score, introduced_key, removed_key}
      end

    candidates
    |> Enum.sort_by(fn {score, introduced_key, removed_key} ->
      {-score, introduced_key, removed_key}
    end)
    |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn {_score, introduced_key, removed_key},
                                                        {acc, claimed_new, claimed_old} ->
      cond do
        MapSet.member?(claimed_new, introduced_key) ->
          {acc, claimed_new, claimed_old}

        MapSet.member?(claimed_old, removed_key) ->
          {acc, claimed_new, claimed_old}

        true ->
          {
            [{introduced_key, removed_key} | acc],
            MapSet.put(claimed_new, introduced_key),
            MapSet.put(claimed_old, removed_key)
          }
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp lineage_inference_score(previous_model, current_model)
       when is_map(previous_model) and is_map(current_model) do
    previous_id = Map.get(previous_model, "id")
    current_id = Map.get(current_model, "id")

    previous_provider_model_id = Map.get(previous_model, "provider_model_id")
    current_provider_model_id = Map.get(current_model, "provider_model_id")

    previous_aliases = string_list(Map.get(previous_model, "aliases"))
    current_aliases = string_list(Map.get(current_model, "aliases"))

    alias_overlap = overlap_count(previous_aliases, current_aliases)

    id_match_score =
      if is_binary(previous_id) and previous_id == current_id do
        50
      else
        0
      end

    provider_model_score =
      if is_binary(previous_provider_model_id) and
           previous_provider_model_id == current_provider_model_id do
        40
      else
        0
      end

    previous_id_in_current_aliases_score =
      if is_binary(previous_id) and previous_id in current_aliases do
        30
      else
        0
      end

    current_id_in_previous_aliases_score =
      if is_binary(current_id) and current_id in previous_aliases do
        30
      else
        0
      end

    model_field_score =
      if is_binary(Map.get(previous_model, "model")) and
           Map.get(previous_model, "model") == Map.get(current_model, "model") do
        5
      else
        0
      end

    name_field_score =
      if is_binary(Map.get(previous_model, "name")) and
           Map.get(previous_model, "name") == Map.get(current_model, "name") do
        2
      else
        0
      end

    id_match_score + provider_model_score + previous_id_in_current_aliases_score +
      current_id_in_previous_aliases_score + alias_overlap * 5 + model_field_score +
      name_field_score
  end

  defp string_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp string_list(_), do: []

  defp overlap_count(left, right) do
    right_lookup = Map.new(right, &{&1, true})
    Enum.count(left, &Map.has_key?(right_lookup, &1))
  end

  defp lineage_for_model_key(
         model_key,
         lineage_overrides,
         previous_lineage_by_key,
         current_lineage_by_key,
         default_lineage
       ) do
    case resolve_override_target(model_key, lineage_overrides) do
      nil ->
        default_lineage

      target_key ->
        Map.get(current_lineage_by_key, target_key) ||
          Map.get(previous_lineage_by_key, target_key) ||
          target_key
    end
  end

  defp resolve_override_target(model_key, lineage_overrides) do
    if Map.has_key?(lineage_overrides, model_key) do
      follow_override_target(model_key, lineage_overrides, [], 0)
    else
      nil
    end
  end

  defp follow_override_target(model_key, _lineage_overrides, _seen, depth) when depth >= 32,
    do: model_key

  defp follow_override_target(model_key, lineage_overrides, seen, depth) do
    if model_key in seen do
      model_key
    else
      case Map.get(lineage_overrides, model_key) do
        nil ->
          model_key

        target when is_binary(target) ->
          follow_override_target(
            target,
            lineage_overrides,
            [model_key | seen],
            depth + 1
          )
      end
    end
  end

  defp attach_lineage(events, previous_lineage_by_key, current_lineage_by_key) do
    Enum.map(events, fn event ->
      lineage_key =
        case event.type do
          "removed" ->
            Map.get(previous_lineage_by_key, event.model_key, event.model_key)

          _ ->
            Map.get(current_lineage_by_key, event.model_key) ||
              Map.get(previous_lineage_by_key, event.model_key, event.model_key)
        end

      Map.put(event, :lineage_key, lineage_key)
    end)
  end

  defp load_previous_lineage(output_dir, model_keys, previous_models) do
    needed_keys = MapSet.new(model_keys)

    loaded =
      output_dir
      |> event_paths()
      |> Enum.reduce(%{}, fn path, acc ->
        File.stream!(path)
        |> Enum.reduce(acc, fn line, inner_acc ->
          case Jason.decode(line) do
            {:ok, %{"model_key" => model_key} = event} ->
              if MapSet.member?(needed_keys, model_key) do
                Map.put(inner_acc, model_key, Map.get(event, "lineage_key", model_key))
              else
                inner_acc
              end

            _ ->
              inner_acc
          end
        end)
      end)

    Enum.reduce(previous_models, %{}, fn {model_key, _model}, acc ->
      Map.put(acc, model_key, Map.get(loaded, model_key, model_key))
    end)
  end

  defp load_commit_state(sha) do
    with {:ok, files_output} <- git(["ls-tree", "-r", "--name-only", sha, "--", @providers_dir]) do
      files =
        files_output
        |> parse_lines()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()

      state =
        Enum.reduce(files, %{}, fn path, acc ->
          case provider_models_for_path(sha, path) do
            {:ok, models} -> Map.put(acc, path, models)
            {:error, _} -> acc
          end
        end)

      {:ok, state}
    end
  end

  defp apply_commit_delta(previous_sha, current_sha, state_by_file) do
    with {:ok, diff_output} <-
           git([
             "diff",
             "--name-status",
             "--no-renames",
             previous_sha,
             current_sha,
             "--",
             @providers_dir
           ]) do
      next_state =
        diff_output
        |> parse_lines()
        |> Enum.reduce(state_by_file, fn line, acc ->
          case String.split(line, "\t", trim: true) do
            [status, path] when status in ["A", "M"] ->
              case provider_models_for_path(current_sha, path) do
                {:ok, models} -> Map.put(acc, path, models)
                {:error, _} -> acc
              end

            ["D", path] ->
              Map.delete(acc, path)

            _ ->
              acc
          end
        end)

      {:ok, next_state}
    end
  end

  defp provider_models_for_path(sha, path) do
    with {:ok, content} <- git(["show", "#{sha}:#{path}"]),
         {:ok, provider_data} <- Jason.decode(content) do
      provider_id = Map.get(provider_data, "id")
      models_map = Map.get(provider_data, "models", %{})

      if is_binary(provider_id) and is_map(models_map) do
        models =
          Enum.reduce(models_map, %{}, fn {model_id, model_data}, acc ->
            model =
              model_data
              |> Map.put_new("id", model_id)
              |> Map.put_new("provider", provider_id)
              |> normalize_value([])

            Map.put(acc, "#{provider_id}:#{model_id}", model)
          end)

        {:ok, models}
      else
        {:error, :invalid_provider_payload}
      end
    end
  end

  defp flatten_state_models(state_by_file) do
    Enum.reduce(state_by_file, %{}, fn {_path, models}, acc ->
      Map.merge(acc, models)
    end)
  end

  defp normalize_value(value, path)

  defp normalize_value(value, path) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, normalize_value(v, [to_string(k) | path])} end)
    |> Map.new()
  end

  defp normalize_value(value, path) when is_list(value) do
    normalized = Enum.map(value, &normalize_value(&1, path))

    case path do
      [key | _] ->
        if key in @sortable_list_keys and Enum.all?(normalized, &scalar?/1) do
          Enum.sort(normalized)
        else
          normalized
        end

      _ ->
        normalized
    end
  end

  defp normalize_value(value, _path), do: value

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp deep_changes(before_value, after_value, path)

  defp deep_changes(before_value, after_value, path)
       when is_map(before_value) and is_map(after_value) do
    keys =
      (Map.keys(before_value) ++ Map.keys(after_value))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      in_before = Map.has_key?(before_value, key)
      in_after = Map.has_key?(after_value, key)
      next_path = path ++ [to_string(key)]

      cond do
        in_before and in_after ->
          deep_changes(Map.get(before_value, key), Map.get(after_value, key), next_path)

        in_before ->
          [
            %{
              path: Enum.join(next_path, "."),
              op: "remove",
              before: Map.get(before_value, key),
              after: nil
            }
          ]

        in_after ->
          [
            %{
              path: Enum.join(next_path, "."),
              op: "add",
              before: nil,
              after: Map.get(after_value, key)
            }
          ]
      end
    end)
  end

  defp deep_changes(before_value, after_value, path)
       when is_list(before_value) and is_list(after_value) do
    if before_value == after_value do
      []
    else
      [%{path: Enum.join(path, "."), op: "replace", before: before_value, after: after_value}]
    end
  end

  defp deep_changes(before_value, after_value, path) do
    if before_value == after_value do
      []
    else
      [%{path: Enum.join(path, "."), op: "replace", before: before_value, after: after_value}]
    end
  end

  defp write_snapshot(sha, commit_date, manifest_generated_at, models, events, output_dir) do
    snapshot = %{
      schema_version: 1,
      snapshot_id: sha,
      source_commit: sha,
      captured_at: commit_date,
      manifest_generated_at: manifest_generated_at,
      model_count: map_size(models),
      digest: snapshot_digest(models),
      event_count: length(events)
    }

    path = Path.join(output_dir, "snapshots.ndjson")
    append_ndjson(path, snapshot)
  end

  defp write_events(sha, commit_date, events, output_dir) do
    Enum.with_index(events, 1)
    |> Enum.each(fn {event, idx} ->
      year = String.slice(commit_date, 0, 4)
      path = Path.join([output_dir, "events", "#{year}.ndjson"])
      provider_model = String.split(event.model_key, ":", parts: 2)

      event_record = %{
        schema_version: 1,
        event_id: "#{sha}:#{idx}",
        snapshot_id: sha,
        source_commit: sha,
        captured_at: commit_date,
        type: event.type,
        model_key: event.model_key,
        lineage_key: Map.get(event, :lineage_key, event.model_key),
        provider: Enum.at(provider_model, 0),
        model_id: Enum.at(provider_model, 1),
        changes: event.changes
      }

      append_ndjson(path, event_record)
    end)
  end

  defp write_meta(summary, output_dir) do
    path = Path.join(output_dir, "meta.json")
    File.write!(path, Jason.encode!(summary, pretty: true))
  end

  defp read_meta(output_dir) do
    path = Path.join(output_dir, "meta.json")

    cond do
      not File.exists?(path) ->
        {:ok, nil}

      true ->
        with {:ok, content} <- File.read(path),
             {:ok, map} <- Jason.decode(content) do
          {:ok, map}
        else
          {:error, reason} ->
            {:error, "failed to read #{path}: #{inspect(reason)}"}
        end
    end
  end

  defp meta_value(meta, key) when is_map(meta) and is_binary(key) do
    atom_key = meta_atom_key(key)
    Map.get(meta, key) || (atom_key && Map.get(meta, atom_key))
  end

  defp meta_count(meta, key) do
    case meta_value(meta, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp meta_atom_key("commits_scanned"), do: :commits_scanned
  defp meta_atom_key("commits_processed"), do: :commits_processed
  defp meta_atom_key("snapshots_written"), do: :snapshots_written
  defp meta_atom_key("events_written"), do: :events_written
  defp meta_atom_key("output_dir"), do: :output_dir
  defp meta_atom_key("from_commit"), do: :from_commit
  defp meta_atom_key("to_commit"), do: :to_commit
  defp meta_atom_key("generated_at"), do: :generated_at
  defp meta_atom_key("source_repo"), do: :source_repo
  defp meta_atom_key(_), do: nil

  defp load_lineage_overrides(output_dir) do
    path = Path.join(output_dir, @lineage_overrides_file)

    if not File.exists?(path) do
      {:ok, %{}}
    else
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           {:ok, overrides} <- parse_lineage_overrides(decoded) do
        {:ok, overrides}
      else
        {:error, reason} ->
          {:error, "invalid lineage overrides at #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp parse_lineage_overrides(%{"lineage" => lineage}) when is_map(lineage),
    do: validate_lineage_overrides(lineage)

  defp parse_lineage_overrides(map) when is_map(map), do: validate_lineage_overrides(map)
  defp parse_lineage_overrides(_), do: {:error, :invalid_format}

  defp validate_lineage_overrides(lineage_overrides) do
    Enum.reduce_while(lineage_overrides, {:ok, %{}}, fn {from, to}, {:ok, acc} ->
      if is_binary(from) and is_binary(to) do
        {:cont, {:ok, Map.put(acc, from, to)}}
      else
        {:halt, {:error, :non_string_keys_or_values}}
      end
    end)
  end

  defp event_paths(output_dir) do
    output_dir
    |> Path.join("events/*.ndjson")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp append_ndjson(path, map) do
    line = Jason.encode!(map) <> "\n"
    File.write!(path, line, [:append])
  end

  defp canonical_digest_term(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {key, canonical_digest_term(nested)} end)
      |> Enum.sort_by(fn {key, _nested} -> canonical_sort_key(key) end)

    {:map, entries}
  end

  defp canonical_digest_term(value) when is_list(value) do
    {:list, Enum.map(value, &canonical_digest_term/1)}
  end

  defp canonical_digest_term(value), do: value

  defp canonical_sort_key(value) when is_binary(value), do: {0, value}
  defp canonical_sort_key(value) when is_atom(value), do: {1, Atom.to_string(value)}
  defp canonical_sort_key(value) when is_integer(value), do: {2, value}
  defp canonical_sort_key(value) when is_float(value), do: {3, value}
  defp canonical_sort_key(value) when is_boolean(value), do: {4, value}
  defp canonical_sort_key(nil), do: {5, nil}
  defp canonical_sort_key(value), do: {6, inspect(value)}

  defp commit_date_iso8601(sha) do
    case git(["show", "-s", "--format=%cI", sha]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp manifest_generated_at(sha) do
    case git(["show", "#{sha}:#{@manifest_path}"]) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} -> Map.get(manifest, "generated_at")
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp source_repo do
    case git(["remote", "get-url", "origin"]) do
      {:ok, url} -> String.trim(url)
      _ -> nil
    end
  end

  defp parse_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
