defmodule Mix.Tasks.Vct.Workspace do
  @moduledoc """
  Seed and inspect Virtual Context Tree (VCT) workspaces in the task database.

  A **workspace** is the VCT's one grouping layer: a `vct:///workspaces/<name>`
  mount with NO OS path, an ORDERED member list and an optional description
  (`EvoGit.VCT.create_workspace/3`). Members are project mount points
  (`vct:///projects/<name>`) or absolute OS paths, kept in the order they were
  given, and workspaces never nest.

  This task is the operator path for the two things a workspace needs outside
  the dashboard: seeding one (`create`) and looking at what is in it (`list`,
  `show`) — including members whose target no longer resolves. It NEVER writes
  SQLite rows itself: every command goes through `EvoGit.VCT.create_workspace/3`,
  `EvoGit.VCT.workspaces/1` and `EvoGit.VCT.workspace_members/1`, so it cannot
  produce a row the runtime would not.

  ## Usage

      mix vct.workspace list [--data-dir <path>]

      mix vct.workspace create <name> --member <POINT_OR_PATH> [--member <POINT_OR_PATH> ...]
                                  [--description <text>] [--data-dir <path>]

      mix vct.workspace show <name> [--data-dir <path>]

  `--data-dir` points at the directory holding `tasks.sqlite`; it defaults to
  `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`.

  ## `list`

  Prints every workspace, newest first (`last_opened_at` descending), as one
  block per workspace: its point, name, description, then one `- <point>` line
  per RESOLVED member in stored order and one `MISSING: <stored ref>` line per
  member ref that resolves to nothing (plus `NESTED:` for a legacy
  nested-workspace ref). A missing member is reported, never silently dropped.

  ## `create`

  `--member` takes a `vct:///…` point or an OS path (a `~`-prefixed or
  relative path is expanded against the home / current working directory) and
  must be repeated at least once; the repeats build the ordered member list.
  `--description` is optional free-form text. The command prints the resulting
  point, name, description and STORED members (in order).

  The point is derived from the SLUGIFIED name (its separators fold into the
  point segment), so `create "Web / App"` writes `vct:///workspaces/Web - App`
  while the display name stays exactly what was typed.

  ## `show`

  Resolves one workspace (by point or bare name) against the CURRENT mount
  table and prints the same block as `create`, but with the resolved members
  and their `MISSING:` / `NESTED:` lines. A name that is not a workspace raises
  with the real reason instead of printing an empty block.

  ## Safety

  The task does NOT start the `:evo_git` application (no scheduler, no
  dashboard, no watcher). It boots a private, uniquely-named
  `EvoGit.Store` (`pool_size: 1`) and a private `EvoGit.VCT` on an isolated
  PubSub instance, and stops the whole stack again before it returns. The
  configured database is therefore reached through the ordinary store/WAL path
  — bounded connections, the app's 30 s busy timeout — instead of hand-editing
  rows, so a concurrently running Genesis instance and its files keep working.

  The store auto-migrates, so a fresh `--data-dir` is created and initialized
  on demand.

  ## Idempotence

  `create` is an UPSERT keyed by the workspace point
  (`EvoGit.VCT.create_workspace/3`): repeating the exact same command replaces
  the same row (same name, members and order, refreshed `last_opened_at`) and
  prints byte-identical output, so it is safe to re-run as a seed step.
  """

  use Mix.Task

  @shortdoc "Seed and inspect VCT workspaces (list, create, show) in the task database"

  @requirements ["app.config"]

  alias EvoGit.VCT
  alias EvoGit.VCT.Mount

  @switches [member: :keep, description: :string, data_dir: :string]

  # The Ecto/DBConnection and PubSub runtime apps the private stack needs. The
  # xqlite driver app is started by Ecto itself when the repo starts
  # (`Ecto.Adapters.SQL.ensure_all_started/3`). Idempotent in a test context.
  @runtime_apps [:ecto_sql, :phoenix_pubsub]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown or invalid option(s): #{inspect(invalid)}\n\n#{usage()}")
    end

    command = command!(argv)
    raw_members = Keyword.get_values(opts, :member)
    description = Keyword.get(opts, :description)

    validate_options!(command, raw_members, description)

    # Fail on a bad member BEFORE the store boots: a mistyped ref must never
    # create/migrate a database.
    members = Enum.map(raw_members, &member_ref/1)

    data_dir = data_dir(opts)

    with_stack(data_dir, fn ->
      execute(command, %{data_dir: data_dir, members: members, description: description})
    end)
  end

  @doc false
  def usage do
    """
    Usage:
      mix vct.workspace list [--data-dir <path>]
      mix vct.workspace create <name> --member <POINT_OR_PATH> [--member <POINT_OR_PATH> ...] [--description <text>] [--data-dir <path>]
      mix vct.workspace show <name> [--data-dir <path>]\
    """
  end

  ## Argument parsing

  defp command!([]), do: Mix.raise("Missing subcommand.\n\n#{usage()}")

  defp command!([subcommand | rest]) do
    case {subcommand, rest} do
      {"list", []} ->
        :list

      {"create", [name]} ->
        {:create, name}

      {"show", [name]} ->
        {:show, name}

      {"create", []} ->
        Mix.raise("Missing <name> for `create`.\n\n#{usage()}")

      {"show", []} ->
        Mix.raise("Missing <name> for `show`.\n\n#{usage()}")

      {sub, extra} when sub in ["list", "create", "show"] ->
        Mix.raise("Unexpected argument(s) for `#{sub}`: #{inspect(extra)}\n\n#{usage()}")

      {other, _rest} ->
        Mix.raise("Unknown subcommand #{inspect(other)}.\n\n#{usage()}")
    end
  end

  defp validate_options!({:create, _name}, members, _description) do
    if members == [] do
      Mix.raise("`create` needs at least one --member <POINT_OR_PATH>.\n\n#{usage()}")
    end

    :ok
  end

  defp validate_options!(command, members, description) do
    subcommand = subcommand_name(command)

    if members != [] do
      Mix.raise(
        "`--member` is only valid with `create` (got it for `#{subcommand}`).\n\n#{usage()}"
      )
    end

    if description != nil do
      Mix.raise(
        "`--description` is only valid with `create` (got it for `#{subcommand}`).\n\n#{usage()}"
      )
    end

    :ok
  end

  defp subcommand_name(:list), do: "list"
  defp subcommand_name({:show, _name}), do: "show"

  defp data_dir(opts) do
    opts
    |> Keyword.get(
      :data_dir,
      Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    )
    |> expand_path()
  end

  ## Subcommands

  defp execute(:list, _ctx), do: list_workspaces()
  defp execute({:create, name}, ctx), do: create_workspace(name, ctx)
  defp execute({:show, name}, ctx), do: show_workspace(name, ctx)

  defp list_workspaces do
    case VCT.workspaces() do
      [] ->
        shell().info("No workspaces.")

      workspaces ->
        shell().info("Workspaces: #{length(workspaces)}")
        Enum.each(workspaces, &print_list_entry/1)
    end
  end

  defp print_list_entry(%Mount{} = workspace) do
    shell().info("")
    print_workspace_header(workspace)

    case VCT.workspace_members(workspace.point) do
      {:ok, resolution} -> print_resolved_members(resolution)
      {:error, reason} -> shell().info("  members unavailable: #{describe_error(reason)}")
    end
  end

  defp create_workspace(name, ctx) do
    opts =
      case ctx.description do
        nil -> []
        description -> [description: description]
      end

    case VCT.create_workspace(name, ctx.members, opts) do
      {:ok, %Mount{} = workspace} ->
        print_workspace_header(workspace)
        print_stored_members(workspace)

      {:error, reason} ->
        Mix.raise(
          "Could not create workspace #{inspect(name)} in #{db_path(ctx.data_dir)}: " <>
            describe_error(reason)
        )
    end
  end

  defp show_workspace(name, ctx) do
    case VCT.workspace_members(name) do
      {:ok, resolution} ->
        print_workspace_header(resolution.workspace)
        print_resolved_members(resolution)

      {:error, reason} ->
        Mix.raise(
          "No workspace #{inspect(name)} in #{db_path(ctx.data_dir)}: " <> describe_error(reason)
        )
    end
  end

  ## Printing

  defp print_workspace_header(%Mount{} = workspace) do
    shell().info("Workspace: #{workspace.point}")
    shell().info("  name: #{workspace.name}")
    shell().info("  description: #{describe_description(workspace.description)}")
  end

  defp print_stored_members(%Mount{members: []}), do: shell().info("  members: (none)")

  defp print_stored_members(%Mount{members: members}) do
    shell().info("  members (stored order):")
    Enum.each(members, fn ref -> shell().info("    - #{ref_label(ref)}") end)
  end

  defp print_resolved_members(%{members: [], missing: [], nested: []}) do
    shell().info("  members: (none)")
  end

  defp print_resolved_members(%{members: members, missing: missing, nested: nested}) do
    shell().info("  members (resolved, stored order):")
    Enum.each(members, fn mount -> shell().info("    - #{mount.point}") end)
    Enum.each(missing, fn ref -> shell().info("    MISSING: #{ref_label(ref)}") end)
    Enum.each(nested, fn ref -> shell().info("    NESTED: #{ref_label(ref)}") end)
  end

  defp describe_description(nil), do: "(none)"
  defp describe_description(description), do: description

  # A STORED member ref as one readable token: the point when it has one (the
  # resolution rule is point-first), else the OS path.
  defp ref_label(%{"point" => point, "path" => nil}) when is_binary(point), do: point
  defp ref_label(%{"point" => nil, "path" => path}) when is_binary(path), do: path

  defp ref_label(%{"point" => point, "path" => path}) when is_binary(point),
    do: "#{point} (#{path})"

  defp ref_label(other), do: inspect(other)

  ## Members

  defp member_ref(value) do
    case String.trim(value) do
      "" ->
        Mix.raise("Empty --member value; pass a vct:/// point or an absolute OS path.")

      member ->
        if String.starts_with?(member, "vct:"),
          do: %{"point" => member},
          else: %{"path" => expand_path(member)}
    end
  end

  defp expand_path("~"), do: home_dir()

  defp expand_path("~" <> <<separator, rest::binary>>) when separator in [?/, ?\\],
    do: Path.expand(rest, home_dir())

  defp expand_path(path), do: Path.expand(path)

  defp home_dir do
    System.user_home() || Mix.raise("Cannot expand `~`: the home directory is unknown.")
  end

  ## Isolated stack

  # One throw-away supervisor per run: an isolated PubSub, ONE uniquely-named
  # single-connection `EvoGit.Store` on the target database (it creates the
  # directory and auto-migrates) and ONE uniquely-named `EvoGit.VCT` bound to
  # that store. The VCT client calls resolve their target through the
  # `:evogit_vct_server` process-dictionary seam, so this process is pointed at
  # the private instance for the duration of the command.
  defp with_stack(data_dir, fun) do
    db_path = db_path(data_dir)

    Enum.each(@runtime_apps, &ensure_runtime_app!/1)

    unique = System.unique_integer([:positive])
    store = :"vct_workspace_task_store_#{unique}"
    vct = :"vct_workspace_task_vct_#{unique}"
    pubsub = :"vct_workspace_task_pubsub_#{unique}"

    children = [
      {Phoenix.PubSub, name: pubsub},
      Supervisor.child_spec({EvoGit.Store, data_dir: db_path, name: store, pool_size: 1},
        id: store
      ),
      Supervisor.child_spec(
        {EvoGit.VCT, name: vct, data_dir: data_dir, store: store, pubsub: pubsub},
        id: vct
      )
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor} ->
        previous = Process.put(:evogit_vct_server, vct)

        try do
          fun.()
        after
          Process.put(:evogit_vct_server, previous)
          stop_stack(supervisor)
        end

      {:error, reason} ->
        Mix.raise("Failed to start the task-store stack on #{db_path}: #{inspect(reason)}")
    end
  end

  defp ensure_runtime_app!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("Could not start #{inspect(app)}: #{inspect(reason)}")
    end
  end

  # The stack is best-effort teardown: a command that already raised must keep
  # its ORIGINAL error, so a dead/never-started supervisor is not an error.
  defp stop_stack(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  defp db_path(data_dir), do: Path.join(data_dir, "tasks.sqlite")

  ## Error messages

  defp describe_error({:member_is_workspace, point}) do
    "a workspace cannot be a member (workspaces never nest): #{point}"
  end

  defp describe_error({:invalid_member, ref}) do
    "invalid member ref (needs a vct:/// point and/or an absolute OS path): #{inspect(ref)}"
  end

  defp describe_error(:invalid_members), do: "members must be a list of member refs"
  defp describe_error(:invalid_name), do: "the workspace name must be a non-blank string"

  defp describe_error(:not_found),
    do: "no workspace row with that point or name exists"

  defp describe_error(:not_a_workspace),
    do:
      "that key resolves to a mount that is NOT a workspace (workspaces are vct:///workspaces/<name>)"

  defp describe_error(:invalid_point),
    do: "that key is neither a vct:///workspaces/<name> point nor a bare workspace name"

  defp describe_error(:vct_unavailable), do: "the VCT server is unavailable"

  defp describe_error(other), do: inspect(other)

  defp shell, do: Mix.shell()
end
