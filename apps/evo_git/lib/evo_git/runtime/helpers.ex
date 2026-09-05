defmodule EvoGit.Runtime.Helpers do
  @moduledoc "Shared helper functions for runtime phases."
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  require Logger

  @doc """
  Merges agent output and reports results. Creates a branch if changes were made.
  The `phase` argument should be "genesis" or "evolve" for logging and branch naming.

  The 3-arity variant is a delegating clause: it reports the primary repo only
  (equivalent to `merge_and_report/4` with an empty `foreign_repos` list).
  """
  def merge_and_report(repo_path, %Result{} = agent_output, phase) when is_binary(phase) do
    merge_and_report(repo_path, agent_output, phase, [])
  end

  @doc """
  Merges agent output and reports results, including per-repo branches for
  WRITABLE foreign repos.

  `agent_output` is a `%EvoGit.Agent.Result{}` (or a map-shaped result — Genesis
  Mode B merges two results and augments the struct with `foreign_repo_commits`
  via `Map.put`, which yields a plain map). `foreign_repos` is a list of
  `%EvoGit.Core.ForeignRepo{}` structs. ONE branch name is generated per task
  (via `generate_branch_name/1`) and REUSED for the primary repo AND every
  writable foreign repo that produced commits (per-repo data source:
  `result.foreign_repo_commits`, a map `repo_id => latest commit SHA in that
  repo` — read defensively with `Map.get/3`, the field may be absent). Branches
  are created with `Git.create_branch/3` — NEVER merged into a foreign repo's
  default branch. Read-only/unknown repo ids produce no entries. Branch-creation
  failure is tolerated (logged, `branch_name: nil`, entry kept) — same tolerance
  as the primary path. The returned report map carries a `repos` key (see
  `report_map/5`).
  """
  def merge_and_report(repo_path, agent_output, phase, foreign_repos)
      when is_binary(phase) and is_list(foreign_repos) and is_map(agent_output) do
    final_sha = agent_output.commit_sha

    Logger.info("#{String.capitalize(phase)}: Finalizing repo '#{repo_path}': resolving HEAD")

    with {:ok, base_sha} <- Git.rev_parse(repo_path) do
      if final_sha && final_sha != base_sha do
        Logger.info(
          "#{String.capitalize(phase)}: Agent produced changes (#{binary_part(base_sha, 0, 7)} -> #{binary_part(final_sha, 0, 7)})"
        )

        branch_name = generate_branch_name(phase)
        foreign_entries = build_foreign_branch_entries(agent_output, foreign_repos, branch_name)

        Logger.info(
          "#{String.capitalize(phase)}: Creating branch '#{branch_name}' at #{binary_part(final_sha, 0, 7)}"
        )

        case Git.create_branch(repo_path, branch_name, final_sha) do
          {:ok, _} ->
            Logger.info(
              "#{String.capitalize(phase)}: Created branch '#{branch_name}' at #{binary_part(final_sha, 0, 7)}"
            )

            {:ok, report_map(agent_output, final_sha, branch_name, false, foreign_entries)}

          error ->
            Logger.error(
              "#{String.capitalize(phase)}: Failed to create branch '#{branch_name}': #{inspect(error)}"
            )

            # Still return success — the agent's work is committed, we just couldn't
            # create a named branch. The commit_sha is still valid.
            {:ok, report_map(agent_output, final_sha, nil, false, foreign_entries)}
        end
      else
        Logger.info(
          "#{String.capitalize(phase)}: No changes detected (base and final commit are the same)"
        )

        # The primary produced no changes (no primary branch), but writable
        # foreign repos may still have commits — process them under a freshly
        # generated branch name when any foreign commits exist.
        foreign_entries =
          foreign_entries_for_unchanged_primary(agent_output, foreign_repos, phase)

        {:ok, report_map(agent_output, final_sha || base_sha, nil, true, foreign_entries)}
      end
    else
      error ->
        Logger.error("#{String.capitalize(phase)}: Failed to resolve base SHA: #{inspect(error)}")
        # Return the agent's result anyway — the work IS done, we just couldn't
        # do post-processing. Mark commit_sha as the agent's final_sha.
        foreign_entries =
          foreign_entries_for_unchanged_primary(agent_output, foreign_repos, phase)

        {:ok, report_map(agent_output, final_sha, nil, false, foreign_entries)}
    end
  end

  # Builds the `repos` report map. The primary entry is ALWAYS present (even in
  # the no-changes path — branch_name nil); `foreign_entries` are merged in
  # under their string repo ids. All keys are strings so the in-memory and
  # post-Codec (JSON) shapes match — plain maps only, no structs inside.
  defp report_map(
         agent_output,
         commit_sha,
         branch_name,
         no_changes,
         foreign_entries
       ) do
    base = %{
      commit_sha: commit_sha,
      result: agent_output.result,
      tag: agent_output.tag,
      branch_name: branch_name,
      pr_url: nil,
      pr_title: nil,
      usage: agent_output.usage,
      agent_count: agent_output.agent_count,
      archive_records: agent_output.archive_records,
      repos:
        Map.put(
          foreign_entries,
          ForeignRepo.primary_id(),
          %{commit_sha: commit_sha, branch_name: branch_name}
        )
    }

    if no_changes, do: Map.put(base, :no_changes, true), else: base
  end

  # Foreign-repo branch entries for the no-changes / rev_parse-error paths: a
  # branch name is generated ONLY when at least one foreign repo has a tracked
  # commit (the primary keeps branch_name nil / no primary branch). No foreign
  # commits → no entries.
  defp foreign_entries_for_unchanged_primary(agent_output, foreign_repos, phase) do
    if map_size(Map.get(agent_output, :foreign_repo_commits, %{})) > 0 do
      build_foreign_branch_entries(agent_output, foreign_repos, generate_branch_name(phase))
    else
      %{}
    end
  end

  # Creates branches for every WRITABLE foreign repo that has a tracked commit
  # in `result.foreign_repo_commits` (map repo_id => latest commit SHA in that
  # repo). One branch name is REUSED across all repos (uniform dashboard
  # merge/reject broadcast). Read-only or unknown repo ids produce no entries;
  # branch-creation failure keeps the entry with `branch_name: nil` (logged).
  defp build_foreign_branch_entries(agent_output, foreign_repos, branch_name) do
    commits = Map.get(agent_output, :foreign_repo_commits, %{})

    Enum.reduce(foreign_repos, %{}, fn %ForeignRepo{} = repo, acc ->
      case {repo.writable, Map.get(commits, repo.id)} do
        {true, sha} when is_binary(sha) ->
          Map.put(acc, repo.id, create_foreign_branch(repo, branch_name, sha))

        _ ->
          acc
      end
    end)
  end

  defp create_foreign_branch(%ForeignRepo{} = repo, branch_name, sha) do
    Logger.info("Creating branch '#{branch_name}' in foreign repo '#{repo.id}' at '#{repo.root}'")

    case Git.create_branch(repo.root, branch_name, sha) do
      {:ok, _} ->
        Logger.info(
          "Created branch '#{branch_name}' in foreign repo '#{repo.id}' at #{binary_part(sha, 0, 7)}"
        )

        %{commit_sha: sha, branch_name: branch_name}

      error ->
        Logger.error(
          "Failed to create branch '#{branch_name}' in foreign repo '#{repo.id}' " <>
            "at '#{repo.root}': #{inspect(error)}"
        )

        %{commit_sha: sha, branch_name: nil}
    end
  end

  def notify_finalizing(nil), do: :ok

  def notify_finalizing(task_id) when is_binary(task_id) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "tasks",
      {:task_updated, task_id, :finalizing, node()}
    )
  end

  def generate_branch_name(_prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "genesis/agent_#{short_id}"
  end

  def new_codebase?(repo_path) do
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md", ".genesis", ".gitignore"]
        _ -> []
      end

    Enum.empty?(files)
  end

  def validate_node_path("./", _repo_path), do: :ok

  def validate_node_path(node_path, repo_path) do
    if Path.type(node_path) == :absolute do
      {:error,
       {:invalid_node_path,
        "Node path must be relative to the repository root, got absolute path: #{node_path}"}}
    else
      normalized = EvoGit.Core.ContextNode.normalize_relpath(node_path)
      abs_path = Path.join(repo_path, String.trim_leading(normalized, "./"))

      cond do
        not File.dir?(abs_path) ->
          {:error, {:invalid_node_path, "Directory does not exist: #{node_path}"}}

        not File.exists?(Path.join(abs_path, "CONTEXT.md")) ->
          {:error, {:invalid_node_path, "No CONTEXT.md found at: #{node_path}"}}

        true ->
          :ok
      end
    end
  end

  @doc """
  Merges two foreign repo lists. CLI repos take precedence over TOML repos
  when there's an id conflict.

  Both lists are normalized via `EvoGit.Core.ForeignRepo.normalize/1` before
  merging — entries may arrive as `%ForeignRepo{}` structs, atom-keyed maps, or
  string-keyed maps (opts persisted to SQLite round-trip through JSON via
  `EvoGit.Store.Codec`, which turns structs into string-keyed maps), and
  dot-accessing `.id` on raw map entries would crash. Unparseable entries are
  dropped.
  """
  def merge_foreign_repos(toml_repos, cli_repos) do
    toml_repos = normalize_foreign_repos(toml_repos)
    cli_repos = normalize_foreign_repos(cli_repos)
    toml_map = Map.new(toml_repos, &{&1.id, &1})
    cli_map = Map.new(cli_repos, &{&1.id, &1})
    Map.merge(toml_map, cli_map) |> Map.values()
  end

  defp normalize_foreign_repos(repos) when is_list(repos) do
    repos
    |> Enum.map(&ForeignRepo.normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_foreign_repos(_other), do: []

  @doc """
  Raises `ArgumentError` when `repo_path` is a UNC / network-share root.

  Git worktrees — and therefore all worktree-based EvoGit tasks — are
  unsupported on UNC roots: git-for-Windows normalizes `\\\\server\\share` ↔
  `//server/share` inconsistently across the worktree metadata files (`.git`
  pointer + `.git/worktrees/<n>/gitdir`), so path-form comparison fails →
  cryptic "outside repository" errors deep in a run. Detecting the UNC share
  shape EARLY (via `EvoGit.Platform.unc_path?/1`) and raising here surfaces a
  clear, actionable error BEFORE any git/worktree I/O. The message names the
  offending path, the limitation, and concrete workarounds (clone/move the
  repo to a local drive, `subst X: \\\\server\\share\\proj` on Windows, or run
  inside WSL at the native Linux path).

  Spec-error style (raise, no `try/rescue`) — mirrors `validate_foreign_repo!/1`
  and `resolve_root_agent/2`. Returns `:ok` for non-UNC paths.
  """
  @spec validate_repo_path!(String.t()) :: :ok
  def validate_repo_path!(repo_path) when is_binary(repo_path) do
    if EvoGit.Platform.unc_path?(repo_path) do
      raise ArgumentError,
            "Repository root '#{repo_path}' is a UNC / network-share path. " <>
              "Git worktrees on UNC/network-share roots are unsupported: " <>
              "git-for-Windows normalizes \\\\server\\share and //server/share " <>
              "inconsistently across worktree metadata files, causing " <>
              "\"outside repository\" errors. Move or clone the repository to " <>
              "a local drive, map the share with " <>
              "`subst X: \\\\server\\share\\proj` on Windows, or run inside " <>
              "WSL at the native Linux path."
    else
      :ok
    end
  end

  @doc """
  Loads foreign repos for a runtime phase: `genesis.toml` defaults merged with
  CLI-provided repos (CLI takes precedence).

  Every merged entry is validated UP FRONT (spec-error style, no `try/rescue` —
  this runs in the task process before any agent spawns, mirroring
  `resolve_root_agent/2`'s raise): the path must exist AND be a git repository,
  and a non-nil `base_sha` must resolve in that repository. A UNC / network-share
  root is rejected early via `validate_repo_path!/1` (worktree-unsupported
  diagnostic). On failure an `ArgumentError` is raised naming the repo id, the
  path, and the problem. Returns the validated (normalized) list of
  `%EvoGit.Core.ForeignRepo{}`.
  """
  def load_foreign_repos(repo_path, opts) do
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    repos = merge_foreign_repos(toml_repos, cli_repos)
    validate_foreign_repos!(repos)
  end

  defp validate_foreign_repos!(repos) do
    Enum.each(repos, &validate_foreign_repo!/1)
    repos
  end

  defp validate_foreign_repo!(%ForeignRepo{} = repo) do
    # UNC / network-share roots are unsupported for worktree-based tasks —
    # reject early with the actionable diagnostic instead of a rev-parse failure.
    validate_repo_path!(repo.root)

    case Git.rev_parse(repo.root) do
      {:ok, _} ->
        validate_foreign_repo_base_sha!(repo)

      error ->
        raise ArgumentError,
              "Foreign repo '#{repo.id}' at '#{repo.root}' is not a valid git repository: " <>
                inspect(error)
    end
  end

  defp validate_foreign_repo_base_sha!(%ForeignRepo{base_sha: nil}), do: :ok

  defp validate_foreign_repo_base_sha!(%ForeignRepo{} = repo) do
    case Git.rev_parse(repo.root, repo.base_sha) do
      {:ok, _} ->
        :ok

      error ->
        raise ArgumentError,
              "Foreign repo '#{repo.id}' at '#{repo.root}': base_sha '#{repo.base_sha}' " <>
                "does not resolve in the repository (#{inspect(error)})"
    end
  end

  @doc """
  Loads the rendered git-submodules note block for a repo tree, or `nil` when
  the repo has no gitlink (submodule) entries or detection fails (graceful
  degradation — never crashes, no `try/rescue`).

  The returned value is the ALREADY-RENDERED markdown block consumed by
  `EvoGit.Agent.ContextBuilder.build_repo_notes_section/1`. Root spec builders
  pass it to `AgentSpec.new(..., repo_notes: ...)` so every LLM agent working in
  a repo with git submodules sees a concise note in its `<context>` block
  (subagents inherit it — no re-detection).

  ## Rendered note text

      ## Git Submodules

      This repository has git submodules at:
      - `<path1>`
      - `<path2>`

      In agent worktrees these paths arrive as **empty placeholder directories** (same as native `git worktree add`). If your task needs their content, populate them with:

          git submodule update --init [--recursive]

      (requires network; the clone is shared across worktrees in `.git/modules`). Never delete the placeholder dirs — they are tracked gitlinks (`git clean -fd` won't remove them) — and do not create files inside them to "fill in" content. Changes inside a submodule belong to the submodule repo itself, not the superproject: do not commit inside submodules as part of this task.
  """
  @spec load_repo_notes(String.t(), String.t()) :: String.t() | nil
  def load_repo_notes(repo_path, treeish)
      when is_binary(repo_path) and is_binary(treeish) do
    case Git.ls_tree_gitlinks(repo_path, treeish) do
      {:ok, []} -> nil
      {:ok, paths} -> render_repo_notes(paths)
      {:error, _} -> nil
    end
  end

  # Renders the git-submodules note block from gitlink paths. Single source of
  # truth for the note text — root spec build sites go through load_repo_notes/2.
  defp render_repo_notes(paths) do
    bullets = paths |> Enum.map(&"- `#{&1}`") |> Enum.join("\n")

    """
    ## Git Submodules

    This repository has git submodules at:
    #{bullets}

    In agent worktrees these paths arrive as **empty placeholder directories** (same as native `git worktree add`). If your task needs their content, populate them with:

        git submodule update --init [--recursive]

    (requires network; the clone is shared across worktrees in `.git/modules`). Never delete the placeholder dirs — they are tracked gitlinks (`git clean -fd` won't remove them) — and do not create files inside them to "fill in" content. Changes inside a submodule belong to the submodule repo itself, not the superproject: do not commit inside submodules as part of this task.
    """
  end

  def resolve_starting_commit(repo_path, nil) do
    EvoGit.Core.PhyloGraphNode.current_head(repo_path)
  end

  def resolve_starting_commit(repo_path, ref) do
    case Git.rev_parse(repo_path, ref) do
      {:ok, sha} ->
        {:ok, sha}

      error ->
        Logger.error("Invalid starting commit '#{ref}': #{inspect(error)}")
        error
    end
  end

  @doc """
  Resolves the per-repo starting commit for a foreign repo entry.

  Returns `{:ok, sha}` where `sha` is:
  - the commit `entry.base_sha` resolves to (`Git.rev_parse`) when `base_sha` is
    set — up-front validation in `load_foreign_repos/2` guarantees it exists; or
  - the repo's HEAD (`EvoGit.Core.PhyloGraphNode.current_head/1`) when
    `base_sha` is `nil` (default — start from the foreign repo's current tip).

  Mirrors `resolve_starting_commit/2`: errors pass through unchanged (with a
  `Logger.error` for the ref-resolve path) instead of raising.
  """
  @spec resolve_foreign_repo_starting_commit(EvoGit.Core.ForeignRepo.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_foreign_repo_starting_commit(%ForeignRepo{} = entry, repo_root) do
    resolve_starting_commit(repo_root, entry.base_sha)
  end

  @doc """
  Resolves the root-agent module and opts for a runtime phase.

  - `:agent` absent (nil) or an empty string → `{default_module, []}` — the
    phase's built-in root agent runs unchanged.
  - `:agent` set to a custom agent id → `{EvoGit.Agents.Custom, [custom_agent_id: id]}` —
    the generic `EvoGit.Agents.Custom` module runs as the root agent and resolves
    the definition from `agents.toml` at run time.
  - `:agent` set to an UNKNOWN id → raises `ArgumentError` with a descriptive
    message. Crashing loudly is intentional: this runs in the task process (not a
    GenServer), and a bad agent id is a spec error — a silent fallback to the
    default agent would run the task with the wrong agent.
  """
  @spec resolve_root_agent(keyword(), module()) :: {module(), keyword()}
  def resolve_root_agent(opts, default_module) do
    case Keyword.get(opts, :agent) do
      id when id in [nil, ""] ->
        {default_module, []}

      id ->
        case EvoGit.CustomAgents.get(id) do
          nil ->
            config_dir = EvoGit.Config.config_dir()

            raise ArgumentError,
                  "Unknown custom agent id '#{id}'. Define it in " <>
                    "#{config_dir}/agents.toml (config dir: #{config_dir})."

          _definition ->
            {EvoGit.Agents.Custom, [custom_agent_id: id]}
        end
    end
  end

  @doc """
  Determines whether the model-selection script must be skipped for this task.

  Returns true when either:
  - `:model_id` is a non-nil value — a non-nil `:model_id` in runtime opts means
    a user/dashboard explicitly chose a model, so the model-selection script must
    NOT override it; or
  - `:model_id_locked` is explicitly true — a pass-through for cases where the
    lock exists without an id (e.g. the CLI `-m` bare-model override).
  """
  @spec model_id_locked?(keyword()) :: boolean()
  def model_id_locked?(opts) do
    Keyword.get(opts, :model_id_locked, false) || not is_nil(Keyword.get(opts, :model_id))
  end

  @doc """
  Builds the resolved root-agent `%EvoGit.AgentSpec{}` for a runtime phase.

  Resolves the root agent via `resolve_root_agent/2` — `default_module`, or an
  agents.toml custom agent when `opts[:agent]` is set (unknown ids raise). The
  resolved `custom_agent_id` is folded into the spec opts BEFORE
  `AgentSpec.new/5` (appended at the end of the keyword list): since
  `AgentSpec.new/5` stores opts verbatim and the base list never carries a
  `:custom_agent_id` key, this is byte-identical to the former
  `%{spec | opts: Keyword.merge(spec.opts, agent_opts)}` post-step — ordering
  in the merged opts list is unchanged.
  """
  @spec build_root_agent_spec(
          EvoGit.Core.ContextNode.t(),
          EvoGit.Core.PhyloGraphNode.t(),
          module(),
          String.t(),
          keyword(),
          [ForeignRepo.t()],
          String.t() | nil
        ) :: AgentSpec.t()
  def build_root_agent_spec(
        context_node,
        phylo_node,
        default_module,
        objective,
        opts,
        foreign_repos,
        repo_notes
      ) do
    {agent_module, agent_opts} = resolve_root_agent(opts, default_module)

    spec_opts =
      [
        foreign_repos: foreign_repos,
        repo_notes: repo_notes,
        archive: Keyword.get(opts, :archive, false),
        task_id: Keyword.get(opts, :task_id),
        model_id: Keyword.get(opts, :model_id),
        model_id_locked: model_id_locked?(opts)
      ] ++ agent_opts

    AgentSpec.new(context_node, phylo_node, agent_module, objective, spec_opts)
  end
end
