defmodule Mix.Tasks.Store.Maintenance do
  @moduledoc """
  On-demand SQLite maintenance for the EvoGit task database (`tasks.sqlite`).

  The store's boot path already runs a best-effort `PRAGMA optimize`
  (`EvoGit.Store.Boot.start_dynamic/2`) and a supervised
  `EvoGit.Store.Maintenance` repeats it every 60 minutes, so this task is for
  the manual cases:

    * reclaiming disk space — the live database accumulates free pages from
      deleted/rewritten task rows and SQLite never returns them to the OS on
      its own (`--vacuum`);
    * refreshing planner statistics after a large import/purge
      (`--optimize`, on by default).

  ## Usage

      mix store.maintenance [--data-dir <path>] [--vacuum] [--optimize | --no-optimize]

  `--data-dir` points at the directory holding `tasks.sqlite` (default:
  `EvoGit.Platform.data_dir/0`). `--vacuum` first switches the database to
  `PRAGMA auto_vacuum = INCREMENTAL` when it is not already incremental (the
  header change only takes effect after a `VACUUM`, which this flag then
  runs), then `VACUUM`s. `--optimize` is ON by default; `--no-optimize`
  disables it.

  ## What it prints

  The main file size before and after (the file size is measured AFTER the
  private repo instance closes, so the final WAL checkpoint is included), plus
  `PRAGMA page_size` / `page_count` / `freelist_count` / `auto_vacuum` before
  and after, and a one-line summary of what was reclaimed.

  ## Safety

  Like `mix migrate.store`, the task does NOT start the `:evo_git`
  application: it boots a private UNNAMED dynamic `EvoGit.Repo` instance on the
  target database (`pool_size: 1`, so nothing else is connected to it) and
  stops it afterwards. `VACUUM` is NEVER run at boot or by the supervised
  maintenance process — it rewrites the whole file and needs exclusive access,
  so it stays an explicit operator action.
  """

  use Mix.Task

  @shortdoc "Run on-demand SQLite maintenance (optimize / vacuum) for the task database"

  @requirements ["app.config"]

  alias EvoGit.Store.Boot
  alias EvoGit.Store.Maintenance
  alias EvoGit.Store.RepoScope

  @repo EvoGit.Repo

  @switches [data_dir: :string, vacuum: :boolean, optimize: :boolean]

  # `PRAGMA auto_vacuum` value for INCREMENTAL mode.
  @auto_vacuum_incremental 2

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown or invalid option(s): #{inspect(invalid)}\n\n#{usage()}")
    end

    if rest != [] do
      Mix.raise("Unexpected argument(s): #{inspect(rest)}\n\n#{usage()}")
    end

    data_dir = Keyword.get(opts, :data_dir, EvoGit.Platform.data_dir())
    db_path = Path.join(Path.expand(data_dir), "tasks.sqlite")
    vacuum? = Keyword.get(opts, :vacuum, false)
    optimize? = Keyword.get(opts, :optimize, true)

    unless File.exists?(db_path) do
      Mix.raise("No task database found at #{db_path}")
    end

    # Mix-task context: the :evo_git app is NOT started (app.config only loads
    # + compiles), and the repo needs the Ecto/DBConnection runtime apps up.
    # Idempotent when they are already running (test context).
    Application.ensure_all_started(:ecto_sql)

    Mix.shell().info("==> Task database: #{db_path}")

    size_before = file_size(db_path)

    case Boot.start_dynamic(db_path, pool_size: 1) do
      {:ok, pid} ->
        report =
          try do
            maintain(pid, optimize?: optimize?, vacuum?: vacuum?)
          after
            # Closing the single connection checkpoints the WAL, so the file
            # size measured AFTER this reflects the post-maintenance state.
            Boot.stop(pid)
          end

        print_report(size_before, file_size(db_path), report)
        :ok

      {:error, reason} ->
        Mix.raise("Failed to open SQLite database #{db_path}: #{inspect(reason)}")
    end
  end

  @doc false
  def usage do
    "Usage: mix store.maintenance [--data-dir <path>] [--vacuum] [--optimize | --no-optimize]"
  end

  ## Maintenance steps

  defp maintain(pid, opts) do
    stats_before = db_stats(pid)

    optimize_result =
      if Keyword.get(opts, :optimize?, true) do
        Maintenance.optimize(pid)
      else
        :skipped
      end

    vacuum_result =
      if Keyword.get(opts, :vacuum?, false) do
        vacuum!(pid)
      else
        :skipped
      end

    stats_after = db_stats(pid)

    %{
      stats_before: stats_before,
      stats_after: stats_after,
      optimize: optimize_result,
      vacuum: vacuum_result
    }
  end

  # `VACUUM` cannot run inside a transaction and rewrites the whole file, so it
  # is only ever reached through the explicit `--vacuum` flag. `auto_vacuum` is
  # a HEADER setting: changing it needs a VACUUM to take effect, so an
  # existing `none`-mode database is switched AND vacuumed in one go (exactly
  # what the flag asks for), and a report says which case applied.
  defp vacuum!(pid) do
    auto_vacuum = db_stats(pid).auto_vacuum
    switched? = auto_vacuum != @auto_vacuum_incremental

    if switched? do
      RepoScope.with_repo(pid, fn ->
        @repo.query!("PRAGMA auto_vacuum = INCREMENTAL")
      end)
    end

    RepoScope.with_repo(pid, fn -> @repo.query!("VACUUM") end)

    %{auto_vacuum_before: auto_vacuum, switched_to_incremental: switched?}
  end

  defp db_stats(pid) do
    RepoScope.with_repo(pid, fn ->
      %{
        page_size: pragma_int("PRAGMA page_size"),
        page_count: pragma_int("PRAGMA page_count"),
        freelist_count: pragma_int("PRAGMA freelist_count"),
        auto_vacuum: pragma_int("PRAGMA auto_vacuum")
      }
    end)
  end

  defp pragma_int(sql) do
    case @repo.query!(sql).rows do
      [[value] | _] -> value
      _other -> nil
    end
  end

  ## Reporting

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  defp print_report(size_before, size_after, report) do
    shell = Mix.shell()

    shell.info("")
    shell.info("Before: #{describe_stats(size_before, report.stats_before)}")
    shell.info("After:  #{describe_stats(size_after, report.stats_after)}")
    shell.info("")
    shell.info("PRAGMA optimize: #{describe_optimize(report.optimize)}")
    shell.info("VACUUM:          #{describe_vacuum(report.vacuum)}")
    shell.info("")
    shell.info(summary(size_before, size_after, report))
  end

  defp describe_stats(size, stats) do
    [
      "main file #{human_size(size)}",
      "pages #{inspect(stats.page_count)} × #{inspect(stats.page_size)} B",
      "freelist #{inspect(stats.freelist_count)} pages",
      "auto_vacuum #{auto_vacuum_name(stats.auto_vacuum)}"
    ]
    |> Enum.join(" · ")
  end

  defp describe_optimize(:skipped), do: "skipped (--no-optimize)"
  defp describe_optimize(:ok), do: "ok (planner statistics refreshed)"
  defp describe_optimize({:error, reason}), do: "FAILED (ignored): #{inspect(reason)}"

  defp describe_vacuum(:skipped), do: "skipped (pass --vacuum to reclaim space)"

  defp describe_vacuum(%{auto_vacuum_before: before, switched_to_incremental: switched?}) do
    base = "VACUUMed (auto_vacuum #{auto_vacuum_name(before)} before)"

    if switched? do
      base <> "; auto_vacuum switched to incremental (takes effect now, after the VACUUM)"
    else
      base
    end
  end

  defp summary(size_before, size_after, report) do
    reclaimed =
      if is_integer(size_before) and is_integer(size_after) do
        size_before - size_after
      end

    case reclaimed do
      reclaimed when is_integer(reclaimed) and reclaimed > 0 ->
        "Done — reclaimed #{human_size(reclaimed)} " <>
          "(#{percent(reclaimed, size_before)}% of #{human_size(size_before)})." <>
          incremental_note(report)

      reclaimed when reclaimed == 0 or is_nil(reclaimed) ->
        "Done — no space reclaimed; the database was already compact." <>
          incremental_note(report)

      reclaimed ->
        "Done — the file GREW by #{human_size(-reclaimed)}; nothing to reclaim " <>
          "(pages were still in the WAL when the before-size was measured)." <>
          incremental_note(report)
    end
  end

  defp incremental_note(%{vacuum: %{switched_to_incremental: true}}) do
    " auto_vacuum is now INCREMENTAL: future deletions return pages to the freelist incrementally."
  end

  defp incremental_note(_report), do: ""

  defp auto_vacuum_name(0), do: "none"
  defp auto_vacuum_name(1), do: "full"
  defp auto_vacuum_name(2), do: "incremental"
  defp auto_vacuum_name(other), do: inspect(other)

  defp percent(_part, nil), do: "0.0"
  defp percent(_part, 0), do: "0.0"
  defp percent(part, whole), do: :erlang.float_to_binary(part / whole * 100, decimals: 1)

  defp human_size(nil), do: "unknown"
  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp human_size(bytes) do
    "#{:erlang.float_to_binary(bytes / 1024 / 1024, decimals: 1)} MiB (#{bytes} B)"
  end
end
