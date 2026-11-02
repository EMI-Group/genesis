defmodule Mix.Tasks.Bench.Io do
  @moduledoc """
  Measure filesystem and git I/O over a throw-away synthetic repository.

  The benchmark seeds `<dir>/genesis-bench-<os_pid>-<unique>/repo`, measures a
  fixed phase list over `--iterations` cycles (plus discarded `--warmup`
  cycles) and removes the whole root again unless `--keep` is passed. It
  measures the I/O paths Genesis agents exercise — worktree add/remove, file
  read/write and `git status` / `git add` / `git commit` — and does NOT boot
  the Genesis application: no Store, no TaskRegistry and no scheduler are
  started, so it is safe to run against any working copy.

  Measurement only: nothing is written outside the bench root.

  ## Usage

      mix bench.io [options]
      mix bench.io
      mix bench.io --dir ~/bench --iterations 10 --json

  ## Options

    * `--dir PATH` — directory the throw-away bench root is created in
      (default: `System.tmp_dir!()`); it decides filesystem locality, so
      results are comparable only on the same mount
    * `--iterations N` (alias `-n`) — counted cycles (default: 5)
    * `--warmup N` — discarded cycles run before the counted ones (default: 1)
    * `--files N` — synthetic seed files in the repository (default: 200)
    * `--writes N` — files written per cycle (default: 20)
    * `--reads N` — files read per cycle (default: 20)
    * `--file-size BYTES` — payload size of each written file (default: 4096)
    * `--seed N` — seed of the synthetic repository and the pick order
      (default: 42)
    * `--label STRING` — label recorded in the report (default: the hostname)
    * `--fsync` — `:file.sync` every written file (measures durable writes)
    * `--keep` — keep the bench root after the run (default: remove it)
    * `--json` — print ONLY the JSON report on stdout, for scripts and
      regression tracking (nothing else is written to stdout)
    * `--help` (alias `-h`) — print this usage and exit

  `iterations`, `files`, `writes`, `reads` and `file_size` must be `>= 1`;
  `warmup` must be `>= 0`. Values are validated by `EvoGit.Bench.validate/1`
  before anything is written to disk.

  ## What it prints

  The human report from `EvoGit.Bench.Report.render_text/1` (settings, host,
  per-phase timings, per-cycle totals and throughput), or with `--json` only
  the single JSON document from `EvoGit.Bench.Report.render_json/1` — no
  banner, no log lines.
  """

  use Mix.Task

  @shortdoc "Measure filesystem and git I/O (worktrees, file read/write, git)"

  # `app.config` loads + compiles only — never `:app.start`: the benchmark
  # must run with NO Genesis application (no Store, TaskRegistry or scheduler).
  @requirements ["app.config"]

  @switches [
    dir: :string,
    iterations: :integer,
    warmup: :integer,
    files: :integer,
    writes: :integer,
    reads: :integer,
    file_size: :integer,
    seed: :integer,
    label: :string,
    fsync: :boolean,
    keep: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @aliases [n: :iterations, h: :help]

  @usage """
  Usage: mix bench.io [options]

    --dir PATH         bench root parent (default: the system temp dir)
    --iterations N, -n counted cycles (default: 5)
    --warmup N         discarded cycles before the counted ones (default: 1)
    --files N          seed files in the synthetic repository (default: 200)
    --writes N         files written per cycle (default: 20)
    --reads N          files read per cycle (default: 20)
    --file-size BYTES  bytes written per file (default: 4096)
    --seed N           seed of the repository and pick order (default: 42)
    --label STRING     label recorded in the report (default: the hostname)
    --fsync            fsync every written file
    --keep             keep the bench root after the run
    --json             print ONLY the JSON report on stdout
    --help, -h         print this usage and exit
  """

  @impl Mix.Task
  def run(argv) do
    case parse_args(argv) do
      {:help} ->
        Mix.shell().info(@usage)
        :ok

      {:error, message} ->
        Mix.raise(message)

      {:ok, opts} ->
        run_bench(opts)
    end
  end

  @doc """
  Parses command-line arguments into a validated `EvoGit.Bench` option list.

  Pure: it never prints and never raises, so it is unit-testable. Returns
  `{:ok, opts}` (the parsed flags merged over `EvoGit.Bench.defaults/0`, with
  `:json` still present for `run/1` to consume), `{:error, message}` for an
  unexpected argument, an invalid option or a rejected setting, or `{:help}`
  when `--help` / `-h` appears anywhere (it wins over every other token).
  """
  @spec parse_args([String.t()]) :: {:ok, keyword()} | {:error, String.t()} | {:help}
  def parse_args(argv) when is_list(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) ->
        {:help}

      invalid != [] ->
        {:error, "invalid option: " <> Enum.map_join(invalid, ", ", &format_invalid/1)}

      rest != [] ->
        {:error, "unexpected argument: " <> Enum.join(rest, ", ")}

      true ->
        opts |> Keyword.delete(:help) |> EvoGit.Bench.validate()
    end
  end

  ## Execution

  defp run_bench(opts) do
    json? = Keyword.get(opts, :json, false)
    bench_opts = Keyword.delete(opts, :json)

    case EvoGit.Bench.run(bench_opts) do
      {:ok, result} ->
        if json? do
          IO.puts(render_json(result))
        else
          Mix.shell().info(render_text(result))
        end

        :ok

      {:error, {phase, detail}} ->
        Mix.raise("bench.io failed in phase #{phase}: #{inspect(detail)}")
    end
  end

  ## Rendering
  #
  # `EvoGit.Bench.Report` is called through `apply/3` so this module compiles
  # without an "undefined function" warning whenever the renderer is not yet
  # compiled into the tree; a direct remote call would fail the
  # `--warnings-as-errors` build.

  defp render_text(result), do: apply(EvoGit.Bench.Report, :render_text, [result])

  defp render_json(result), do: apply(EvoGit.Bench.Report, :render_json, [result])

  ## Parsing helpers

  defp format_invalid({option, nil}), do: option
  defp format_invalid({option, value}), do: option <> "=" <> value
end
