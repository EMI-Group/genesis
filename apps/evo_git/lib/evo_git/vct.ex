defmodule EvoGit.VCT do
  @moduledoc """
  The Virtual Context Tree (VCT) mount store.

  The VCT is a **pure in-memory namespace** layered over the local filesystem:
  a mount binds a canonical VCT point (`vct:///projects/foo`, see
  `EvoGit.VCT.Path`) to an absolute OS path (see `EvoGit.VCT.Mount`). It is NOT
  a filesystem — this module never creates a directory for a point, never
  requires a mount's OS path to exist, and never creates a symlink, bind mount,
  junction or FUSE mount. No on-disk layout changes on the agent side.

  This GenServer owns:

    * the mount table (rules in `EvoGit.VCT.Table`), persisted in the SQLite
      task store's `vct_mounts` table (`EvoGit.Store.list_vct_mounts/1` /
      `EvoGit.Store.save_vct_mounts/2`). The in-memory list is a READ CACHE of
      that table; every mutation writes the WHOLE table back before the state
      changes;
    * the GLOBAL context file (`<data_dir>/vct/CONTEXT.md`) and its local git
      history, so a global context edit is a committed, auditable change; a
      NON-BLANK file that already exists at boot is synced then, too.

  ## Project mounts, workspace mounts and reserved (system) mounts

  A point under `vct:///projects/<name>` is a PROJECT mount: it is what
  `projects/1` and `search/2` list, what the dashboard palette and the task
  flows see, and what the cap evicts. Every other point — `vct:///`,
  `vct:///projects` and any other top-level namespace such as
  `vct:///genesis-source` — is a RESERVED (system) mount (see
  `EvoGit.VCT.Table.reserved?/1`).

  A point under `vct:///workspaces/<name>` is a WORKSPACE mount: a pure
  GROUPING point with no OS path (`create_workspace/3`, `workspaces/1`,
  `workspace_members/1`, `workspaces_for/1`). A workspace is neither a project
  nor a reserved mount: the cap never evicts it, `mount_for_path/1` /
  `vct_path_for/2` never answer with one, it is listed only by `workspaces/1`
  (or an explicit `:include_workspaces`), `forget/1` removes it, and workspaces
  never nest (a workspace point is refused as a member).

  Reserved mounts are real mounts for resolution: `resolve/1`,
  `mount_for_path/1`, `vct_path_for/2` and `put_global_context/1` see them
  exactly like project mounts. They differ in three ways: they are invisible to
  `projects/1`/`search/2`, `forget/1` refuses them with
  `{:error, :reserved_point}`, and the capacity cap never evicts them.

  System mounts are declared by the HOST (e.g. a runtime-provided source
  checkout) and ensured at boot through the `:system_mounts` init option, and
  can be ensured at runtime with `ensure_mount/3`.

  ## Capacity

  `max_projects/0` (100 by default, overridable through the app env
  `:vct_max_projects`) caps the PROJECT mounts only. Registering a path beyond
  the cap EVICTS the oldest project mounts, so the table never grows unbounded
  while staying newest-first; reserved mounts are always retained and do not
  count against the cap.

  ## Client reads are TOTAL

  `EvoGit.Core.ContextNode` and other callers may ask the VCT for data from any
  process, including during boot or after a crash, so every read resolves a
  missing/dead server to its documented value instead of raising: a LIST or
  SCALAR read answers its empty shape (`[]`, `nil`, `""`), while a read whose
  return type is an error union (`resolve/1`, `workspace_members/1`,
  `workspace_entries/2`) answers `{:error, :vct_unavailable}`, exactly like a
  mutation. A transport failure is therefore never disguised as data: a
  `{:error, :not_found}` from this module means ONE thing — the point, path or
  workspace genuinely has no row. A store that is down or unavailable never
  crashes the init or a caller: the mount list loads as `[]` and a mutation
  returns an error.

  ## Instance seam

  `server/0` is read at CALL time from the `:evogit_vct_server` process
  dictionary key (set by `init/1` for self-calls, exactly like
  `EvoGit.TaskRegistry.server/0`), falling back to the registered singleton
  `__MODULE__`. Tests start isolated instances with a unique `:name`,
  `:data_dir` and `:store`.

  ## Broadcasts

  Every successful mount mutation publishes `{:vct_updated, node()}` on
  `"vct"` — exactly one broadcast per mutation — through the PubSub instance
  named by the `:pubsub` init option (default `EvoGit.PubSub`). Tests inject an
  ISOLATED instance, so a concurrently running case can never deliver its own
  `{:vct_updated, node}` into a `refute_receive` window.

  ## Internals

  This module stays the ONE module a consumer needs: it owns the state, the
  public API and the `handle_call/3` clauses.
  Its helpers live beside it as INTERNAL modules: `EvoGit.VCT.Call` (transport
  and the one best-effort broadcast), `EvoGit.VCT.Mounts` (mount-table loading,
  validation, listing, resolution, removal and the persist-plus-broadcast
  funnel), `EvoGit.VCT.Workspaces` (workspace resolution and entry builders) and
  `EvoGit.VCT.GlobalContext` (the global context file and its lazy git
  repository).
  The pure list rules stay in `EvoGit.VCT.Table` and the mount value object in
  `EvoGit.VCT.Mount`.
  """

  use GenServer

  require Logger

  alias EvoGit.VCT.Call
  alias EvoGit.VCT.GlobalContext
  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Mounts
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table
  alias EvoGit.VCT.Workspaces

  @server_key :evogit_vct_server

  @type state :: %{
          name: term(),
          data_dir: String.t(),
          vct_dir: String.t(),
          store: term(),
          pubsub: term(),
          mounts: [Mount.t()]
        }

  @typedoc """
  A mount value object — the shape most reads return.

  See `EvoGit.VCT.Mount` for the fields (`point`, `path`, `name`, `kind`,
  `last_opened_at`, `members`, `description`); `workspace?/1` and `git?/1`
  classify it.
  """
  @type t :: Mount.t()

  @typedoc """
  A canonical VCT point — the formatted `vct:///…` URL.

  The ONE spelling shared by a mount's `point`, a workspace point and a member
  ref's `point`. A point is a NAMESPACE ADDRESS, never an OS path.
  """
  @type point :: EvoGit.VCT.Path.point()

  @typedoc """
  Every failure reason this module's error tuples carry.

  The validation/state reasons (`:invalid_point`, `:invalid_path`,
  `:relative_path`, `:invalid_name`, `:invalid_members`, `:invalid_content`,
  `:not_found`, `:not_a_workspace`, `:reserved_point`, `:nested`,
  `:cap_reached`), the persistence reason `:store_unavailable` and the
  TRANSPORT reason `:vct_unavailable` — the last one meaning only "no VCT
  server answered", never "no such row".
  """
  @type error_reason ::
          :not_found
          | :vct_unavailable
          | :invalid_point
          | :not_a_workspace
          | :nested
          | :cap_reached
          | :store_unavailable
          | :reserved_point
          | :relative_path
          | :invalid_path
          | :invalid_name
          | :invalid_members
          | :invalid_content
          | {:invalid_name, term()}
          | {:member_is_workspace, point()}
          | {:invalid_member, member_ref()}

  @typedoc """
  A workspace resolved against the CURRENT mount table.

    * `:workspace` — the workspace mount itself;
    * `:members` — the member mounts that resolve, in stored member order;
    * `:missing` — the STORED member refs that resolve to nothing (a member's
      target need not exist);
    * `:nested` — the STORED member refs that resolve to a WORKSPACE (never
      expanded: workspaces do not nest).
  """
  @type workspace_resolution :: %{
          workspace: t(),
          members: [t()],
          missing: [member_ref()],
          nested: [member_ref()]
        }

  @typedoc """
  A workspace member ref exactly as STORED: a STRING-KEYED map carrying
  `"point"` and `"path"` (both keys present after normalization, at least one
  non-nil). Order is significant and a member's target need not exist.
  """
  @type member_ref :: Mount.member()

  @typedoc """
  ONE resolved workspace member, flattened for consumers that only display or
  address it.

    * `:point` — the resolved mount's canonical point (`nil` when the ref
      resolved by OS path to no mount, which a resolved member cannot be);
    * `:name` — the resolved mount's display name;
    * `:path` — the resolved mount's absolute OS path, or `nil`.
  """
  @type member_entry :: %{point: point() | nil, name: String.t(), path: String.t() | nil}

  @typedoc """
  ONE workspace resolved against the CURRENT mount table, with every member
  flattened into a `t:member_entry/0` — the `workspace_entries/1,2` shape.

    * `:workspace` — the workspace mount itself;
    * `:members` — the resolved members, in STORED member order;
    * `:missing` — the STORED refs that resolve to nothing (unexpanded);
    * `:nested` — the STORED refs naming another workspace (never expanded).
  """
  @type workspace_entry :: %{
          workspace: t(),
          members: [member_entry()],
          missing: [member_ref()],
          nested: [member_ref()]
        }

  ## Client API

  @doc """
  Resolves the VCT server name for the CURRENT process.

  Reads the `:evogit_vct_server` process dictionary key at CALL time (an
  isolated instance started with a custom `:name`), falling back to the
  registered singleton `__MODULE__`.
  """
  @spec server() :: term()
  def server, do: Process.get(@server_key) || __MODULE__

  @doc """
  Starts the mount store.

  ## Options

    * `:name` — registered name (default `__MODULE__`)
    * `:data_dir` — data directory holding the `vct/` folder (default
      `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`)
    * `:store` — the task store owning the `vct_mounts` table (default
      `EvoGit.Store`)
    * `:system_mounts` — host-declared RESERVED mounts to ensure at boot: a list
      of maps or keyword lists with `:point`, `:path` and an optional `:name`
      (default `[]`)
    * `:pubsub` — the PubSub instance `"vct"` notifications are broadcast on
      (default `EvoGit.PubSub`); tests pass an ISOLATED instance so their
      `refute_receive` windows observe only this server's broadcasts

  Each `:system_mounts` entry is merged with `EvoGit.VCT.Table.ensure_mount/4`
  IN ORDER, so boot is idempotent: an already-mounted point/path is a no-op, a
  changed path re-points, a path moved between points is moved. A malformed
  entry is skipped with a `Logger.warning` (boot never fails), the merged table
  is persisted ONLY when it actually changed, and a successful change broadcasts
  exactly ONE `{:vct_updated, node()}`. A persist failure is logged and leaves
  the LOADED table in state, so memory and the database never disagree.

  ONE carve-out, for the path a user also opens as a project: a system mount
  NEVER takes over an OS path owned by a PROJECT mount. Such an entry is skipped
  (logged at info, not a warning — it is expected host state), leaving both the
  project row and the entry's own point binding exactly as they were; a
  reserved→reserved move is still performed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the maximum number of PROJECT mounts the table may hold.

  `100` by default, overridable through the app env `:vct_max_projects` (a
  non-positive or non-integer value falls back to the default). RESERVED
  (system) mounts are always retained and do not count against this cap.
  """
  @spec max_projects() :: pos_integer()
  def max_projects, do: Mounts.max_projects()

  @doc """
  Mounts an absolute OS path, returning the created or refreshed mount.

  `path` must be an absolute OS path (`{:error, :relative_path}` otherwise) and
  is normalized (trimmed, trailing separators dropped). It is NEVER required to
  exist on disk, and no directory is created.

  ## Options

    * `:name` — display name (a blank or absent name keeps the derived basename)

  Registering an already-mounted OS path is idempotent: it refreshes
  `last_opened_at` (and a non-blank `:name`) and KEEPS its point. A new path
  that matches the name and point basename of a mount whose recorded OS path is
  gone RE-POINTS that mount (same point, new path) instead of accumulating a
  second one — the portability rule for a mount table carried across machines.

  Returns `{:ok, mount}` or `{:error, reason}` (`:relative_path`,
  `:invalid_path`, `{:invalid_name, term}`, a store error, or
  `:vct_unavailable`).
  """
  @spec mount(String.t(), keyword()) :: {:ok, t()} | {:error, error_reason()}
  def mount(path, opts \\ []) when is_list(opts),
    do: Call.call(server(), {:mount, path, opts}, {:error, :vct_unavailable})

  @doc """
  Ensures `path` is mounted at exactly `point` — the POINT-first rule used for
  reserved (system) mounts.

  `point` must be a valid VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`,
  `{:error, :invalid_point}` otherwise) and is canonicalized; `path` follows the
  rules of `mount/2` (`{:error, :relative_path}` / `{:error, :invalid_path}`)
  and is NEVER required to exist on disk — a reserved mount may point at a path
  that is absent (e.g. before a runtime checkout is provisioned).

  ## Options

    * `:name` — display name; a non-blank name always wins, an absent/blank one
      keeps the existing name (or the OS-path basename when inserting)

  The mount is deterministic and idempotent (`EvoGit.VCT.Table.ensure_mount/4`):

    * the same point already holding the same OS path is a NO-OP — the existing
      mount is returned and nothing is persisted, broadcast or re-timestamped;
    * the point holding a DIFFERENT path is re-pointed to `path` (point and
      `last_opened_at` kept, a row mounting that path elsewhere removed);
    * the path mounted at ANOTHER point is MOVED to `point` (path, name and
      `last_opened_at` preserved) so one OS path never has two rows;
    * otherwise a new mount is inserted at `point`.

  This is the DELIBERATE point-first override path, so it has NO no-steal guard: a
  caller that names a point (such as
  `EvoGit.SelfReflectiveSource.ensure_mount/0`) re-points the path as asked. The
  single exception lives in the boot-time `:system_mounts` merge
  (`EvoGit.VCT.Mounts.merge_system_mounts/2`), which refuses to move an OS path
  owned by a PROJECT mount onto a system mount's point.

  Only a real change persists the whole table and broadcasts
  `{:vct_updated, node()}`. Returns `{:ok, mount}` or `{:error, reason}` (the
  validation errors above, a store error, or `:vct_unavailable`); a failed
  persist leaves the table untouched.
  """
  @spec ensure_mount(String.t() | VctPath.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, error_reason()}
  def ensure_mount(point, path, opts \\ []) when is_list(opts),
    do: Call.call(server(), {:ensure_mount, point, path, opts}, {:error, :vct_unavailable})

  @doc """
  Creates or REPLACES a WORKSPACE mount named `name` over `members`.

  A workspace is a pure GROUPING point (`vct:///workspaces/<slug>`): it has no
  OS path, no directory is created, and nothing is required to exist. `name`
  must be a non-blank binary (`{:error, :invalid_name}` otherwise); its point is
  derived from the SLUGIFIED name
  (`EvoGit.VCT.Table.point_segment/1`, so spaces and separators are folded into
  the point while the supplied name stays the display name).

  `members` is an ORDERED list of member refs — maps (atom- or string-keyed)
  carrying `"point"` and/or `"path"`; see `EvoGit.VCT.Mount.member/1`.

  ## Options

    * `:description` — free-form text (normalized; blank becomes `nil`)

  This is an IDEMPOTENT UPSERT by point, the seed/dashboard path: creating the
  same name again REPLACES the name, members and description and refreshes
  `last_opened_at` instead of adding a second row, and every call persists the
  table once and broadcasts exactly ONE `{:vct_updated, node()}` on `"vct"`.

  Workspaces are UNCAPPED (`max_projects/0` never evicts them). Validation
  errors are propagated verbatim: `{:error, {:member_is_workspace, point}}` (a
  workspace point is never a member — workspaces do not nest),
  `{:error, {:invalid_member, ref}}` and `{:error, :invalid_members}`.

  Returns `{:ok, mount}`, or `{:error, reason}` (the validation errors above, a
  store error, or `:vct_unavailable`).
  """
  @spec create_workspace(term(), term(), keyword()) :: {:ok, t()} | {:error, error_reason()}
  def create_workspace(name, members, opts \\ []) when is_list(opts),
    do: Call.call(server(), {:create_workspace, name, members, opts}, {:error, :vct_unavailable})

  @doc """
  Returns every WORKSPACE mount, newest first (`last_opened_at` descending,
  `nil` LAST).

  Workspaces are neither project mounts nor reserved mounts, so this is the
  only listing that returns them.

  ## Options

    * `:limit` — positive integer cap on the returned list
  """
  @spec workspaces(keyword()) :: [t()]
  def workspaces(opts \\ []) when is_list(opts), do: Call.call(server(), {:workspaces, opts}, [])

  @doc """
  Resolves a workspace and its members against the CURRENT mount table.

  This is the MOUNT-STRUCT form; `workspace_entries/2` answers the same facts
  with each member flattened into a `t:member_entry/0`, and
  `workspace_entries/1` resolves a whole roster in one call.

  Accepts:

    * a workspace POINT — a `vct:///workspaces/<name>` binary or a
      `%EvoGit.VCT.Path{}`;
    * a BARE workspace name — a binary with no `vct:` prefix and no path
      separator, matched against a workspace's point segment
      (`EvoGit.VCT.Path.last_segment/1`) or its display name (the newest wins
      when several match).

  A point that resolves to an EXISTING non-workspace mount answers
  `{:error, :not_a_workspace}`; a workspace point (or bare name) with no row
  answers `{:error, :not_found}`; anything else (a non-binary, an unparseable
  `vct:` point, an OS path) answers `{:error, :invalid_point}`.
  An unreachable VCT server answers `{:error, :vct_unavailable}` — never
  `:not_found`, which stays reserved for a genuinely absent workspace.

  Returns `{:ok, %{workspace: mount, members: [...], missing: [...], nested:
  [...]}}` — every member is resolved IN STORED ORDER with
  `EvoGit.VCT.Table.member_mount/2`: a resolved git mount goes to `:members`,
  an unresolvable ref to `:missing` (the STORED ref), and a ref naming another
  workspace to `:nested` (the STORED ref, never expanded).
  """
  @spec workspace_members(String.t() | VctPath.t()) ::
          {:ok, workspace_resolution()}
          | {:error, :not_found | :not_a_workspace | :invalid_point | :vct_unavailable}
  def workspace_members(point_or_name),
    do: Call.call(server(), {:workspace_members, point_or_name}, {:error, :vct_unavailable})

  @doc """
  Returns the WORKSPACE mounts whose membership covers `project`, newest first
  (`[]` when none, or when the argument names nothing usable).

  `project` may be:

    * a PROJECT point — `vct:///projects/<name>` as a binary or a
      `%EvoGit.VCT.Path{}`;
    * a BARE project name — a binary with no `vct:` prefix and no leading
      separator/drive, derived to `vct:///projects/<Table.point_segment/1>`;
    * an ABSOLUTE OS path.

  The candidate is matched as BOTH a point and an OS path (a project mount
  contributes its point for its path and its path for its point), so a member
  that names either form of the same project matches. A workspace whose member
  names a missing mount still covers it: membership is metadata, not a
  filesystem probe.
  """
  @spec workspaces_for(term()) :: [t()]
  def workspaces_for(project), do: Call.call(server(), {:workspaces_for, project}, [])

  @doc """
  Returns `true` when `point` is a WORKSPACE point
  (`vct:///workspaces/<name>` and anything nested below it).

  The TOTAL, PROCESS-FREE delegate to `EvoGit.VCT.Table.workspace_point?/1`:
  it reads no mount table, needs no running VCT and never raises — an
  unparseable, non-path or `nil` input is `false`. This is the predicate the
  execution guard uses on a raw path-like argument.
  """
  @spec workspace_point?(term()) :: boolean()
  def workspace_point?(point), do: Table.workspace_point?(point)

  @doc """
  Returns every PROJECT mount, newest first (`last_opened_at` descending, `nil`
  LAST).

  RESERVED (system) mounts are never listed — they are not part of the user's
  project list (use `resolve/1` or `mount_for_path/1` to reach them).
  WORKSPACE mounts are excluded too unless `:include_workspaces` is `true`.

  ## Options

    * `:limit` — positive integer cap on the returned list (the table itself
      keeps up to `max_projects/0` project mounts)
    * `:include_workspaces` — `true` merges the WORKSPACE mounts into the
      result, sorted by the same recency rule (default `false`: projects only)
  """
  @spec projects(keyword()) :: [t()]
  def projects(opts \\ []) when is_list(opts), do: Call.call(server(), {:projects, opts}, [])

  @doc """
  Returns the mounts matching `query`, newest first.

  The match is a CASE-INSENSITIVE SUBSTRING search over the display name, the
  OS path and the VCT point — the autocomplete interface. A blank query matches
  every eligible mount; a non-binary query matches none. RESERVED (system)
  mounts never appear, not even for a blank query. WORKSPACE mounts are
  searched only with `:include_workspaces` (a workspace has no OS path, so only
  its name and point can match).

  ## Options

    * `:limit` — positive integer cap on the returned list
    * `:include_workspaces` — `true` searches the WORKSPACE mounts as well and
      merges them with the project matches, sorted by the same recency rule
      (default `false`: projects only)
  """
  @spec search(term(), keyword()) :: [t()]
  def search(query, opts \\ []) when is_list(opts),
    do: Call.call(server(), {:search, query, opts}, [])

  @doc """
  Forgets a mount by VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`), by
  OS path (any other binary), or by BARE WORKSPACE NAME.

  Returns `:ok`, `{:error, :not_found}`, `{:error, :invalid_point}` for an
  unparseable point, `{:error, :reserved_point}` when the key resolves to a
  RESERVED (system) mount — whether the key is a reserved point (with or without
  a row) or the OS path of a reserved mount — or another `{:error, reason}`.

  A WORKSPACE point is removable like any other non-reserved mount point. A
  bare binary that matches no OS path falls back to a WORKSPACE lookup: a
  workspace whose point segment or display name equals it is removed (the
  newest wins when several match), and `{:error, :not_found}` when none does.
  """
  @spec forget(String.t() | VctPath.t()) :: :ok | {:error, error_reason()}
  def forget(key), do: Call.call(server(), {:forget, key}, {:error, :vct_unavailable})

  @doc """
  Resolves a VCT point (`"vct:..."` binary or `%EvoGit.VCT.Path{}`) — or an
  exact OS path — to its mount.

  Operates over EVERY mount, so RESERVED (system) mounts resolve exactly like
  project mounts, and a WORKSPACE POINT resolves to its workspace mount. A
  workspace owns no OS path, so an OS-path lookup never answers a workspace
  (`{:error, :not_found}` unless a real file mount holds that path).
  An unreachable VCT server answers `{:error, :vct_unavailable}`, never
  `:not_found`: absence of a row and absence of a server are different facts.
  """
  @spec resolve(String.t() | VctPath.t()) ::
          {:ok, t()} | {:error, :not_found | :invalid_point | :vct_unavailable}
  def resolve(point_or_path),
    do: Call.call(server(), {:resolve, point_or_path}, {:error, :vct_unavailable})

  @doc """
  Returns the mount containing `os_path` (longest OS-path prefix, path-boundary
  aware), or `nil`.

  Operates over EVERY mount, so a reserved (system) mount answers for the paths
  underneath it. A WORKSPACE mount has NO OS path, so it is never returned here
  (and never shadows a real file mount), whatever the requested path.
  """
  @spec mount_for_path(String.t()) :: t() | nil
  def mount_for_path(os_path), do: Call.call(server(), {:mount_for_path, os_path}, nil)

  @doc """
  Returns the canonical VCT URL for `relative_path` inside `repo_root`'s mount,
  or `nil` when no mount contains `repo_root` (or the relative path is invalid).

  Operates over EVERY mount, so a path under a reserved (system) mount yields a
  URL under that reserved point (e.g. `vct:///genesis-source/src`). A WORKSPACE
  mount owns no OS path, so it never answers for a repo root and never yields a
  `vct:///workspaces/...` URL for a file — workspace points are grouping
  metadata, never file paths.
  """
  @spec vct_path_for(String.t(), String.t()) :: String.t() | nil
  def vct_path_for(repo_root, relative_path),
    do: Call.call(server(), {:vct_path_for, repo_root, relative_path}, nil)

  ## Batched reads

  # Two reads a per-item caller would otherwise turn into an N+1: ONE
  # `GenServer.call` returns a whole workspace roster with its members already
  # resolved, and ONE returns every VCT path of a repo.

  @doc """
  Returns EVERY workspace with its members already resolved — one
  `GenServer.call` for the whole roster, in the same order and through the same
  rules as `workspaces/1`.

  This is the batched companion of `workspace_members/1`: a roster screen that
  needs the members of every workspace must NOT call the single-workspace form
  once per entry.

  ## Options

    * `:limit` — positive integer cap applied to the WORKSPACE list, exactly
      like `workspaces/1`

  A dead or absent VCT server degrades to `[]`, like every other list read.
  """
  @spec workspace_entries(keyword()) :: [workspace_entry()]
  def workspace_entries(opts \\ []) when is_list(opts),
    do: Call.call(server(), {:workspace_entries, opts}, [])

  @doc """
  Resolves ONE workspace and its members against the CURRENT mount table — the
  single-workspace form of `workspace_entries/1`.

  Acceptance and error rules are exactly `workspace_members/1`'s: a workspace
  POINT (`vct:///workspaces/<name>` binary or `%EvoGit.VCT.Path{}`) or a BARE
  workspace name, with `{:error, :not_found}` for an absent workspace,
  `{:error, :not_a_workspace}` for an existing non-workspace mount,
  `{:error, :invalid_point}` for an unusable key and
  `{:error, :vct_unavailable}` when no VCT server answers.

  Only the `:members` shape differs: each resolved member is a FLAT
  `t:member_entry/0` map (`:point`, `:name`, `:path`) instead of a full
  `%EvoGit.VCT.Mount{}`. Members keep STORED order and `:missing`/`:nested` are
  the STORED member refs, unexpanded.

  `opts` exists for call-site symmetry with `workspace_entries/1`; no option is
  currently defined for this form.
  """
  @spec workspace_entries(String.t() | VctPath.t(), keyword()) ::
          {:ok, workspace_entry()}
          | {:error, :not_found | :not_a_workspace | :invalid_point | :vct_unavailable}
  def workspace_entries(key, opts) when is_list(opts),
    do: Call.call(server(), {:workspace_entry, key}, {:error, :vct_unavailable})

  @doc """
  Returns the canonical VCT URL of EVERY path in `relative_paths` inside
  `repo_root`'s mount — ONE `GenServer.call` for the whole list.

  The containing mount is resolved ONCE for `repo_root` and each relative path
  is then mapped through `EvoGit.VCT.Table.vct_path_for/2`, so the result
  carries exactly `length(relative_paths)` entries in INPUT order: `nil` means
  the repo is unmounted or that path escapes the mount (the same rules as
  `vct_path_for/2`).

  The list is NEVER shortened: a dead or absent VCT server degrades to one `nil`
  per input path.
  """
  @spec vct_paths_for(String.t(), [String.t()]) :: [String.t() | nil]
  def vct_paths_for(repo_root, relative_paths) when is_list(relative_paths) do
    # Length-preserving degradation: ONE `nil` per input path, never a short list.
    fallback = Enum.map(relative_paths, fn _path -> nil end)
    Call.call(server(), {:vct_paths_for, repo_root, relative_paths}, fallback)
  end

  @doc """
  Returns the global context file path (`<vct_dir>/CONTEXT.md`).

  Total: with no reachable server it returns the default path computed from the
  configured data directory.
  """
  @spec global_context_path() :: String.t()
  def global_context_path,
    do: Call.call(server(), :global_context_path, GlobalContext.default_path())

  @doc """
  Returns the global context contents (`""` when absent or unreadable).
  """
  @spec global_context() :: String.t()
  def global_context, do: GlobalContext.read(global_context_path())

  @doc """
  Writes the global context verbatim.

  After a successful write with NON-BLANK content it lazily initializes the VCT
  directory as a git repository and commits the context files. A blank content
  never initializes a repository. Git failures are logged and never lose the
  written file.

  Broadcasts `{:vct_updated, node()}` on `"vct"` after a successful write.
  """
  @spec put_global_context(term()) :: :ok | {:error, error_reason()}
  def put_global_context(content),
    do: Call.call(server(), {:put_global_context, content}, {:error, :vct_unavailable})

  ## Server callbacks

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Process.put(@server_key, name)

    data_dir =
      Keyword.get(opts, :data_dir) ||
        Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())

    vct_dir = Path.join(data_dir, "vct")

    # The VCT directory only — never a mount point.
    File.mkdir_p!(vct_dir)

    store = Keyword.get(opts, :store, EvoGit.Store)
    pubsub = Keyword.get(opts, :pubsub, EvoGit.PubSub)

    loaded = Mounts.load_mounts(store)

    {mounts, merged?} =
      Mounts.merge_system_mounts(loaded, Keyword.get(opts, :system_mounts, []))

    state = %{
      name: name,
      data_dir: data_dir,
      vct_dir: vct_dir,
      store: store,
      pubsub: pubsub,
      mounts: mounts
    }

    # Host-declared system mounts are persisted ONLY when the merge changed
    # something, so a boot over an already-correct table writes (and announces)
    # nothing. A failed persist reverts the cache to the LOADED table: memory
    # and the database must never disagree, and boot must never fail.
    state =
      if merged? do
        case Mounts.persist(state.store, mounts) do
          :ok ->
            Mounts.broadcast_mount_change(state.pubsub)
            state

          {:error, reason} ->
            Logger.warning("VCT: could not persist system mounts: #{inspect(reason)}")
            %{state | mounts: loaded}
        end
      else
        state
      end

    # A global context restored from a state backup is already on disk but its
    # lazy git repository may not be: sync it now instead of waiting for the
    # first `put_global_context/1`. Best effort — a git failure never fails boot.
    GlobalContext.sync_boot(GlobalContext.path_for(vct_dir))

    {:ok, state}
  end

  @impl true
  def handle_call({:mount, path, opts}, _from, state),
    do: Mounts.handle_mount(state, path, opts)

  def handle_call({:ensure_mount, point, path, opts}, _from, state),
    do: Mounts.handle_ensure_mount(state, point, path, opts)

  def handle_call({:create_workspace, name, members, opts}, _from, state),
    do: Workspaces.handle_create(state, name, members, opts)

  def handle_call({:workspaces, opts}, _from, state),
    do: {:reply, Workspaces.list(state.mounts, opts), state}

  # ONE call answers the whole roster: every workspace's members are resolved
  # against the same in-memory table, so the caller pays no per-workspace round
  # trip.
  def handle_call({:workspace_entries, opts}, _from, state),
    do: {:reply, Workspaces.entries(state.mounts, opts), state}

  def handle_call({:workspace_entry, key}, _from, state),
    do: {:reply, Workspaces.entry(state.mounts, key), state}

  def handle_call({:workspace_members, key}, _from, state),
    do: {:reply, Workspaces.resolve(state.mounts, key), state}

  def handle_call({:workspaces_for, project}, _from, state),
    do: {:reply, Workspaces.containing(state.mounts, project), state}

  def handle_call({:projects, opts}, _from, state),
    do: {:reply, Mounts.list(state.mounts, opts), state}

  def handle_call({:search, query, opts}, _from, state),
    do: {:reply, Mounts.search(state.mounts, query, opts), state}

  def handle_call({:forget, key}, _from, state),
    do: Mounts.handle_forget(state, key)

  def handle_call({:resolve, key}, _from, state),
    do: {:reply, Mounts.resolve(state.mounts, key), state}

  def handle_call({:mount_for_path, os_path}, _from, state),
    do: {:reply, Mounts.mount_for_path(state.mounts, os_path), state}

  # ONE pass: the containing mount is resolved ONCE, then every relative path is
  # mapped through the pure `Table.vct_path_for/2` (which answers `nil` for a
  # `nil` mount or an escaping path).
  def handle_call({:vct_path_for, repo_root, relative_path}, _from, state),
    do: {:reply, List.first(Mounts.vct_paths(state.mounts, repo_root, [relative_path])), state}

  def handle_call({:vct_paths_for, repo_root, relative_paths}, _from, state),
    do: {:reply, Mounts.vct_paths(state.mounts, repo_root, relative_paths), state}

  def handle_call(:global_context_path, _from, state),
    do: {:reply, GlobalContext.path_for(state.vct_dir), state}

  def handle_call({:put_global_context, content}, _from, state) when is_binary(content) do
    case GlobalContext.write(GlobalContext.path_for(state.vct_dir), content) do
      :ok ->
        Mounts.broadcast_mount_change(state.pubsub)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_global_context, _content}, _from, state),
    do: {:reply, {:error, :invalid_content}, state}
end
