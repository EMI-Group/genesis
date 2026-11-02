defmodule EvoGit.Bench do
  @moduledoc """
  Self-contained filesystem/git I/O benchmark over a throw-away synthetic repo.

  This is a measurement tool only. It never requires the Genesis application
  to be booted: every step is a plain function call (no GenServer start, no
  Store/TaskRegistry access, no dependency on the config cache being primed).
  It seeds `<dir>/genesis-bench-<os_pid>-<unique>/repo`, measures a fixed list
  of worktree/file/git phases over `iterations` cycles, and always removes the
  whole root via `try/after` unless `keep: true`.

  `run/1` prints nothing — rendering belongs to the caller.
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.WorktreeRetry
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.Bench.Stats
  alias EvoGit.Bench.SystemInfo

  @phases [
    :worktree_add,
    :file_read,
    :file_write,
    :git_status,
    :git_add,
    :git_commit,
    :worktree_remove,
    :worktree_prune
  ]

  @seed_dirs ["lib", "src", "test", "docs"]

  @type result :: map()

  @doc """
  Returns the default option keyword list.

  Keys: `dir` (the host temp dir), `iterations` 5, `warmup` 1, `files` 200,
  `writes` 20, `reads` 20, `file_size` 4096, `seed` 42, `label` the hostname,
  `fsync` false, `keep` false.
  """
  @spec defaults() :: keyword()
  def defaults do
    [
      dir: System.tmp_dir!(),
      iterations: 5,
      warmup: 1,
      files: 200,
      writes: 20,
      reads: 20,
      file_size: 4096,
      seed: 42,
      label: default_label(),
      fsync: false,
      keep: false
    ]
  end

  @doc """
  Merges `opts` over `defaults/0` and validates the known options.

  Returns `{:ok, opts}` on success or a one-line `{:error, message}` naming the
  offending option. `iterations`, `files`, `writes`, `reads` and `file_size`
  must be integers `>= 1`; `warmup` an integer `>= 0`; `seed` an integer;
  `fsync` and `keep` booleans; `dir` a non-empty binary; `label` a binary.
  Unknown keys are allowed and ignored.
  """
  @spec validate(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> then(&Keyword.merge(defaults(), &1))
      |> validate_merged()
    else
      {:error, "options must be a keyword list"}
    end
  end

  def validate(_opts), do: {:error, "options must be a keyword list"}

  @doc """
  Runs the benchmark and returns its result map.

  Flow: validate, seed the synthetic repository, run the discarded warmup
  cycles, run the counted cycles, and build the report. The bench root is
  removed in a `try/after` unless `keep: true`.

  Returns `{:ok, result_map}` or `{:error, {phase, detail}}` where `phase` is
  `:validation` (bad options), `:setup` (seed failures) or the failing counted
  phase name. A failed git call in a counted phase never raises; cleanup-phase
  failures are best-effort and still report.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, {atom(), term()}}
  def run(opts) do
    case validate(opts) do
      {:ok, opts} ->
        root = bench_root(opts)

        try do
          execute(opts, root)
        after
          unless opts[:keep], do: File.rm_rf(root)
        end

      {:error, message} ->
        {:error, {:validation, message}}
    end
  end

  @doc false
  # Builds a cycling pick closure over a pre-shuffled, non-empty list: index
  # `reads`/`writes`/`files`-independent, so counts greater than the file count
  # wrap instead of running out.
  @spec picker([String.t()]) :: (non_neg_integer() -> String.t())
  def picker([_ | _] = files) do
    tuple = List.to_tuple(files)
    size = tuple_size(tuple)

    fn index -> elem(tuple, rem(index, size)) end
  end

  # ── Validation ────────────────────────────────────────────────────────────

  defp validate_merged(opts) do
    with :ok <- check_min_int(opts, :iterations, 1),
         :ok <- check_min_int(opts, :warmup, 0),
         :ok <- check_min_int(opts, :files, 1),
         :ok <- check_min_int(opts, :writes, 1),
         :ok <- check_min_int(opts, :reads, 1),
         :ok <- check_min_int(opts, :file_size, 1),
         :ok <- check_int(opts, :seed),
         :ok <- check_boolean(opts, :fsync),
         :ok <- check_boolean(opts, :keep),
         :ok <- check_dir(opts),
         :ok <- check_label(opts) do
      {:ok, opts}
    end
  end

  defp check_min_int(opts, key, min) do
    case opts[key] do
      value when is_integer(value) and value >= min -> :ok
      value -> {:error, "#{key} must be an integer >= #{min} (got #{inspect(value)})"}
    end
  end

  defp check_int(opts, key) do
    case opts[key] do
      value when is_integer(value) -> :ok
      value -> {:error, "#{key} must be an integer (got #{inspect(value)})"}
    end
  end

  defp check_boolean(opts, key) do
    case opts[key] do
      value when is_boolean(value) -> :ok
      value -> {:error, "#{key} must be a boolean (got #{inspect(value)})"}
    end
  end

  defp check_dir(opts) do
    case opts[:dir] do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, "dir must be a non-empty string (got #{inspect(value)})"}
    end
  end

  defp check_label(opts) do
    case opts[:label] do
      value when is_binary(value) -> :ok
      value -> {:error, "label must be a string (got #{inspect(value)})"}
    end
  end

  # ── Execution ─────────────────────────────────────────────────────────────

  defp bench_root(opts) do
    Path.join(
      opts[:dir],
      "genesis-bench-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp execute(opts, root) do
    repo = Path.join(root, "repo")

    case seed_repo(repo, opts) do
      {:ok, setup, base_sha, rel_files} ->
        # One seeded RNG stream for the whole measurement section and one
        # shuffling of the picker list, so reads/writes are reproducible and
        # independent of the RNG state consumed while seeding.
        :rand.seed(:exsss, {opts[:seed], opts[:seed] + 1, opts[:seed] + 2})
        pick = picker(Enum.shuffle(rel_files))

        with {:ok, _warmup_acc} <-
               run_cycles(empty_acc(), opts, repo, base_sha, pick, cycle_indexes(opts[:warmup])),
             {:ok, acc} <-
               run_cycles(
                 empty_acc(),
                 opts,
                 repo,
                 base_sha,
                 pick,
                 cycle_indexes(opts[:iterations])
               ) do
          {:ok, build_result(opts, root, setup, acc)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp seed_repo(repo, opts) do
    files = opts[:files]
    file_size = opts[:file_size]

    {us, result} =
      :timer.tc(fn ->
        File.mkdir_p!(repo)

        with {:ok, _output} <- Git.run(["init", "-b", "main"], repo),
             :ok <- File.write(Path.join(repo, ".gitignore"), ".genesis/\n"),
             {:ok, rel_files} <- write_seed_files(repo, files, file_size),
             {:ok, _output} <- Git.add(repo),
             {:ok, _output} <- Git.commit(repo, "bench seed"),
             {:ok, sha} <- Git.rev_parse(repo, "HEAD") do
          {:ok, rel_files, sha}
        end
      end)

    case result do
      {:ok, rel_files, sha} ->
        {:ok, %{us: us, files: files, bytes: files * file_size}, sha, rel_files}

      {:error, detail} ->
        {:error, {:setup, detail}}

      other ->
        {:error, {:setup, other}}
    end
  end

  defp write_seed_files(repo, count, file_size) do
    dir_count = length(@seed_dirs)

    rel_files =
      for i <- 0..(count - 1) do
        dir = Enum.at(@seed_dirs, rem(i, dir_count))

        name =
          "f_" <> String.pad_leading(Integer.to_string(div(i, dir_count) + 1), 4, "0") <> ".bin"

        Path.join(dir, name)
      end

    with :ok <- ensure_dirs(repo, @seed_dirs),
         :ok <- write_seed_contents(repo, rel_files, file_size) do
      {:ok, rel_files}
    end
  end

  defp ensure_dirs(repo, dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, _acc ->
      case File.mkdir_p(Path.join(repo, dir)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_seed_contents(repo, rel_files, file_size) do
    Enum.reduce_while(rel_files, :ok, fn rel_file, _acc ->
      case File.write(Path.join(repo, rel_file), :rand.bytes(file_size)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── Cycles ────────────────────────────────────────────────────────────────

  defp cycle_indexes(0), do: []

  defp cycle_indexes(count) when is_integer(count) and count > 0,
    do: Enum.to_list(0..(count - 1))

  defp run_cycles(acc, _opts, _repo, _base_sha, _pick, []), do: {:ok, acc}

  defp run_cycles(acc, opts, repo, base_sha, pick, [index | rest]) do
    case run_cycle(opts, repo, base_sha, pick, index) do
      {:ok, phases, total} ->
        run_cycles(accumulate(acc, phases, total), opts, repo, base_sha, pick, rest)

      {:error, _phase} = error ->
        error
    end
  end

  defp run_cycle(opts, repo, base_sha, pick, index) do
    worktree = Path.join([repo, ".genesis", "workers", "bench-#{index}"])
    branch = "evogit-bench-#{index}"

    File.mkdir_p!(Path.dirname(worktree))

    with {:ok, add_us} <-
           measure(:worktree_add, fn -> Git.add_worktree(repo, worktree, base_sha, branch) end),
         {:ok, read_us} <-
           measure(:file_read, fn -> read_files(worktree, pick, opts[:reads]) end),
         {:ok, write_us} <-
           measure(:file_write, fn ->
             write_files(worktree, pick, opts[:writes], opts[:file_size], opts[:fsync])
           end),
         {:ok, status_us} <- measure(:git_status, fn -> Git.status(worktree) end),
         {:ok, add_git_us} <- measure(:git_add, fn -> Git.add(worktree) end),
         {:ok, commit_us} <-
           measure(:git_commit, fn -> Git.commit(worktree, "bench cycle #{index}") end) do
      remove_us =
        measure_best_effort(:worktree_remove, fn -> WorktreeRetry.rm_rf_retry(worktree) end)

      prune_us =
        measure_best_effort(:worktree_prune, fn -> prune_and_delete(repo, branch) end)

      phases = %{
        worktree_add: add_us,
        file_read: read_us,
        file_write: write_us,
        git_status: status_us,
        git_add: add_git_us,
        git_commit: commit_us,
        worktree_remove: remove_us,
        worktree_prune: prune_us
      }

      {:ok, phases, Enum.sum(Map.values(phases))}
    end
  end

  # A counted phase: a git/file failure becomes `{:error, {phase, detail}}`
  # for the whole run (never raises for a returned error tuple).
  defp measure(phase, fun) do
    {us, result} = :timer.tc(fun)

    case result do
      :ok -> {:ok, us}
      {:ok, _value} -> {:ok, us}
      {:error, detail} -> {:error, {phase, detail}}
    end
  end

  # A cleanup phase: the measurement is always recorded, and a failure is
  # logged at :debug rather than aborting the report.
  defp measure_best_effort(phase, fun) do
    {us, result} = :timer.tc(fun)
    log_best_effort(phase, result)
    us
  end

  defp log_best_effort(_phase, :ok), do: :ok
  defp log_best_effort(_phase, {:ok, _value}), do: :ok

  defp log_best_effort(phase, other) do
    Logger.debug("EvoGit.Bench: #{phase} cleanup reported #{inspect(other)}")
  end

  # Mirrors WorktreeManager.destroy_worktree/3's teardown order: the directory
  # is already removed by the caller, so prune stale registrations and then
  # delete the branch tolerantly.
  defp prune_and_delete(repo, branch) do
    _ = Git.prune_worktrees(repo)
    Worktrees.delete_branch_tolerant(repo, branch)
  end

  defp read_files(worktree, pick, count) do
    Enum.each(0..(count - 1), fn index ->
      File.read!(Path.join(worktree, pick.(index)))
    end)
  end

  defp write_files(worktree, pick, count, file_size, fsync) do
    Enum.each(0..(count - 1), fn index ->
      path = Path.join(worktree, pick.(index))
      write_file(path, :rand.bytes(file_size), fsync)
    end)
  end

  defp write_file(path, data, false), do: File.write!(path, data)

  defp write_file(path, data, true) do
    case :file.open(String.to_charlist(path), [:write, :raw, :binary]) do
      {:ok, device} ->
        try do
          :ok = :file.write(device, data)
          :ok = :file.sync(device)
        after
          :file.close(device)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open for writing", path: path
    end
  end

  # ── Result assembly ───────────────────────────────────────────────────────

  defp empty_acc do
    @phases
    |> Map.new(fn phase -> {phase, []} end)
    |> Map.put(:totals, [])
  end

  defp accumulate(acc, phases, total) do
    acc =
      Enum.reduce(@phases, acc, fn phase, acc ->
        Map.update!(acc, phase, fn samples -> [Map.fetch!(phases, phase) | samples] end)
      end)

    Map.update!(acc, :totals, fn totals -> [total | totals] end)
  end

  defp build_result(opts, root, setup, acc) do
    cycles = opts[:iterations]
    totals = Enum.reverse(acc.totals)
    cycle_stats = Stats.summarize(totals) |> Map.put(:samples_us, totals)
    wall_us = cycle_stats.total_us

    phases =
      Map.new(@phases, fn phase ->
        samples = acc |> Map.fetch!(phase) |> Enum.reverse()
        {phase, phase_stats(samples, wall_us)}
      end)

    files_written = cycles * opts[:writes]
    bytes_written = files_written * opts[:file_size]
    files_read = cycles * opts[:reads]
    bytes_read = files_read * opts[:file_size]

    %{
      label: opts[:label],
      dir: root,
      kept: opts[:keep],
      settings: %{
        iterations: opts[:iterations],
        warmup: opts[:warmup],
        files: opts[:files],
        writes: opts[:writes],
        reads: opts[:reads],
        file_size: opts[:file_size],
        seed: opts[:seed],
        fsync: opts[:fsync]
      },
      system: SystemInfo.collect(root),
      setup: setup,
      phases: phases,
      cycle: cycle_stats,
      overall: %{
        cycles: cycles,
        wall_us: wall_us,
        cycles_per_sec: Stats.ops_per_sec(cycles, wall_us)
      },
      throughput: %{
        files_written: files_written,
        bytes_written: bytes_written,
        write_mib_per_sec: mib_per_sec(bytes_written, Enum.sum(acc.file_write)),
        files_read: files_read,
        bytes_read: bytes_read,
        read_mib_per_sec: mib_per_sec(bytes_read, Enum.sum(acc.file_read))
      }
    }
  end

  defp phase_stats(samples, wall_us) do
    total = Enum.sum(samples)

    samples
    |> Stats.summarize()
    |> Map.put(:samples_us, samples)
    |> Map.put(:share, share(total, wall_us))
  end

  defp share(_total, 0), do: 0.0
  defp share(total, wall_us), do: total / wall_us

  defp mib_per_sec(_bytes, 0), do: 0.0
  defp mib_per_sec(bytes, us), do: bytes * 1_000_000 / (1_048_576 * us)

  defp default_label do
    case :inet.gethostname() do
      {:ok, host} -> List.to_string(host)
      _ -> "unknown"
    end
  end
end
