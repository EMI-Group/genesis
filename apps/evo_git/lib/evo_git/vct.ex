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
  """

  use GenServer

  require Logger

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table

  @server_key :evogit_vct_server
  @context_file "CONTEXT.md"
  @global_context_commit_message "Update global context"

  # Any atomic-write temporaries must never enter the global context's git
  # history. The mount table itself is task-store state, not a file here.
  @gitignore_entries [
    "# Temporary files, never committed.",
    "*.tmp",
    "*.tmp.*"
  ]

  @call_timeout 30_000
  @default_max_projects 100

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
  def max_projects do
    case Application.get_env(:evo_git, :vct_max_projects) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_projects
    end
  end

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
    do: call({:mount, path, opts}, {:error, :vct_unavailable})

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

  Only a real change persists the whole table and broadcasts
  `{:vct_updated, node()}`. Returns `{:ok, mount}` or `{:error, reason}` (the
  validation errors above, a store error, or `:vct_unavailable`); a failed
  persist leaves the table untouched.
  """
  @spec ensure_mount(String.t() | VctPath.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, error_reason()}
  def ensure_mount(point, path, opts \\ []) when is_list(opts),
    do: call({:ensure_mount, point, path, opts}, {:error, :vct_unavailable})

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
    do: call({:create_workspace, name, members, opts}, {:error, :vct_unavailable})

  @doc """
  Returns every WORKSPACE mount, newest first (`last_opened_at` descending,
  `nil` LAST).

  Workspaces are neither project mounts nor reserved mounts, so this is the
  only listing that returns them.

  ## Options

    * `:limit` — positive integer cap on the returned list
  """
  @spec workspaces(keyword()) :: [t()]
  def workspaces(opts \\ []) when is_list(opts), do: call({:workspaces, opts}, [])

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
    do: call({:workspace_members, point_or_name}, {:error, :vct_unavailable})

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
  def workspaces_for(project), do: call({:workspaces_for, project}, [])

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
  def projects(opts \\ []) when is_list(opts), do: call({:projects, opts}, [])

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
  def search(query, opts \\ []) when is_list(opts), do: call({:search, query, opts}, [])

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
  def forget(key), do: call({:forget, key}, {:error, :vct_unavailable})

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
  def resolve(point_or_path), do: call({:resolve, point_or_path}, {:error, :vct_unavailable})

  @doc """
  Returns the mount containing `os_path` (longest OS-path prefix, path-boundary
  aware), or `nil`.

  Operates over EVERY mount, so a reserved (system) mount answers for the paths
  underneath it. A WORKSPACE mount has NO OS path, so it is never returned here
  (and never shadows a real file mount), whatever the requested path.
  """
  @spec mount_for_path(String.t()) :: t() | nil
  def mount_for_path(os_path), do: call({:mount_for_path, os_path}, nil)

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
    do: call({:vct_path_for, repo_root, relative_path}, nil)

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
    do: call({:workspace_entries, opts}, [])

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
    do: call({:workspace_entry, key}, {:error, :vct_unavailable})

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
  def vct_paths_for(repo_root, relative_paths) when is_list(relative_paths),
    do:
      call(
        {:vct_paths_for, repo_root, relative_paths},
        Enum.map(relative_paths, fn _path -> nil end)
      )

  @doc """
  Returns the global context file path (`<vct_dir>/CONTEXT.md`).

  Total: with no reachable server it returns the default path computed from the
  configured data directory.
  """
  @spec global_context_path() :: String.t()
  def global_context_path, do: call(:global_context_path, default_global_context_path())

  @doc """
  Returns the global context contents (`""` when absent or unreadable).
  """
  @spec global_context() :: String.t()
  def global_context do
    case global_context_path() do
      path when is_binary(path) -> read_file(path)
      _other -> ""
    end
  end

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
    do: call({:put_global_context, content}, {:error, :vct_unavailable})

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

    loaded = load_mounts(store)
    {mounts, merged?} = merge_system_mounts(loaded, Keyword.get(opts, :system_mounts, []))

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
        case persist(state, mounts) do
          :ok ->
            broadcast_mount_change(state)
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
    sync_boot_global_context(vct_dir)

    {:ok, state}
  end

  @impl true
  def handle_call({:mount, path, opts}, _from, state) do
    with {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(opts) do
      {:ok, registered, mount} = Table.register(state.mounts, os_path, name, DateTime.utc_now())
      mounts = Table.enforce_cap(registered, max_projects())

      case persist(state, mounts) do
        :ok ->
          broadcast_mount_change(state)
          {:reply, {:ok, mount}, %{state | mounts: mounts}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_mount, point, path, opts}, _from, state) do
    with {:ok, canonical} <- VctPath.canonical(point),
         {:ok, os_path} <- validate_os_path(path),
         {:ok, name} <- extract_name(opts),
         {:ok, ensured, mount, changed?} <-
           Table.ensure_mount(state.mounts, canonical, os_path, name) do
      mounts = Table.enforce_cap(ensured, max_projects())

      if changed? do
        case persist(state, mounts) do
          :ok ->
            broadcast_mount_change(state)
            {:reply, {:ok, mount}, %{state | mounts: mounts}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        # Nothing to write: no persist, no broadcast, no timestamp churn.
        {:reply, {:ok, mount}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_workspace, name, members, opts}, _from, state) do
    with {:ok, workspace_name} <- workspace_name(name),
         {:ok, point} <- workspace_point_for(workspace_name),
         {:ok, mounts, mount} <-
           Table.upsert_workspace(
             state.mounts,
             point,
             workspace_name,
             members,
             Keyword.get(opts, :description),
             DateTime.utc_now()
           ) do
      # A workspace never counts against the project cap, so `enforce_cap/2` is
      # deliberately NOT applied here.
      case persist(state, mounts) do
        :ok ->
          broadcast_mount_change(state)
          {:reply, {:ok, mount}, %{state | mounts: mounts}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:workspaces, opts}, _from, state) do
    mounts =
      state.mounts
      |> Table.workspace_mounts()
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  # ONE call answers the whole roster: every workspace's members are resolved
  # against the same in-memory table, so the caller pays no per-workspace round
  # trip.
  def handle_call({:workspace_entries, opts}, _from, state) do
    entries =
      state.mounts
      |> Table.workspace_mounts()
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))
      |> Enum.map(&workspace_entry(state.mounts, &1))

    {:reply, entries, state}
  end

  def handle_call({:workspace_entry, key}, _from, state) do
    reply =
      case resolve_workspace(state.mounts, key) do
        {:ok, resolution} -> {:ok, to_workspace_entry(resolution)}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:workspace_members, key}, _from, state),
    do: {:reply, resolve_workspace(state.mounts, key), state}

  def handle_call({:workspaces_for, project}, _from, state) do
    reply =
      case workspace_target(state.mounts, project) do
        {point, os_path} ->
          state.mounts
          |> Table.workspaces_containing(point, os_path)
          |> Table.sort_by_recency()

        :error ->
          []
      end

    {:reply, reply, state}
  end

  def handle_call({:projects, opts}, _from, state) do
    mounts =
      state.mounts
      |> listed_mounts(opts)
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  def handle_call({:search, query, opts}, _from, state) do
    mounts =
      state.mounts
      |> listed_mounts(opts)
      |> matching_mounts(query)
      |> Table.sort_by_recency()
      |> apply_limit(Keyword.get(opts, :limit))

    {:reply, mounts, state}
  end

  def handle_call({:forget, key}, _from, state) do
    case remove_from(state.mounts, key) do
      {:ok, mounts, _removed} ->
        case persist(state, mounts) do
          :ok ->
            broadcast_mount_change(state)
            {:reply, :ok, %{state | mounts: mounts}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, %VctPath{} = point}, _from, state) do
    {:reply, resolve_point(state.mounts, VctPath.format(point)), state}
  end

  def handle_call({:resolve, key}, _from, state) when is_binary(key) do
    reply =
      if point_string?(key) do
        case VctPath.parse(key) do
          {:ok, point} -> resolve_point(state.mounts, VctPath.format(point))
          {:error, _reason} -> {:error, :invalid_point}
        end
      else
        case Table.find_by_os_path(state.mounts, key) do
          nil -> {:error, :not_found}
          mount -> {:ok, mount}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:resolve, _other}, _from, state),
    do: {:reply, {:error, :not_found}, state}

  def handle_call({:mount_for_path, os_path}, _from, state),
    do: {:reply, Table.mount_for_path(state.mounts, os_path), state}

  # ONE pass: the containing mount is resolved ONCE, then every relative path is
  # mapped through the pure `Table.vct_path_for/2` (which answers `nil` for a
  # `nil` mount or an escaping path).
  def handle_call({:vct_path_for, repo_root, relative_path}, _from, state),
    do: {:reply, List.first(vct_paths(state.mounts, repo_root, [relative_path])), state}

  def handle_call({:vct_paths_for, repo_root, relative_paths}, _from, state),
    do: {:reply, vct_paths(state.mounts, repo_root, relative_paths), state}

  def handle_call(:global_context_path, _from, state),
    do: {:reply, Path.join(state.vct_dir, @context_file), state}

  def handle_call({:put_global_context, content}, _from, state) when is_binary(content) do
    case write_global_context(state, content) do
      :ok ->
        broadcast_mount_change(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_global_context, _content}, _from, state),
    do: {:reply, {:error, :invalid_content}, state}

  ## Boot: load the mount table from the task store

  # Total: a store that is absent, down or holding an undecodable row never
  # crashes boot. Invalid rows are dropped with a warning.
  defp load_mounts(store) do
    store
    |> store_mounts()
    |> Enum.flat_map(fn map ->
      case Mount.from_map(map) do
        {:ok, mount} ->
          [mount]

        {:error, reason} ->
          Logger.warning("VCT: dropping an invalid mount row: #{inspect({map, reason})}")
          []
      end
    end)
  end

  defp store_mounts(store) do
    EvoGit.Store.list_vct_mounts(store)
  rescue
    exception ->
      Logger.warning("VCT: could not load the mount table: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("VCT: could not load the mount table: #{inspect(reason)}")
      []
  end

  ## Boot: host-declared system mounts

  # Folds the `:system_mounts` entries through `Table.ensure_mount/4` IN ORDER,
  # so booting over an already-correct table changes nothing (no write, no
  # broadcast). A malformed entry is skipped with a warning: boot never fails on
  # host-provided metadata.
  defp merge_system_mounts(mounts, entries) when is_list(entries) do
    Enum.reduce(entries, {mounts, false}, fn entry, {acc, changed?} ->
      case system_mount(entry) do
        {:ok, point, path, name} ->
          case Table.ensure_mount(acc, point, path, name) do
            {:ok, ensured, _mount, entry_changed?} ->
              {ensured, changed? or entry_changed?}

            {:error, reason} ->
              warn_skipped_system_mount(entry, reason)
              {acc, changed?}
          end

        :error ->
          warn_skipped_system_mount(entry, :invalid_entry)
          {acc, changed?}
      end
    end)
  end

  defp merge_system_mounts(mounts, _entries), do: {mounts, false}

  defp warn_skipped_system_mount(entry, reason) do
    Logger.warning("VCT: skipping a malformed system mount: #{inspect({entry, reason})}")
  end

  defp system_mount(entry) when is_list(entry) or is_map(entry) do
    with point when is_binary(point) <- fetch_entry(entry, :point),
         {:ok, canonical} <- VctPath.canonical(point),
         path when is_binary(path) <- fetch_entry(entry, :path),
         {:ok, name} <- system_mount_name(fetch_entry(entry, :name)) do
      {:ok, canonical, path, name}
    else
      _reason -> :error
    end
  end

  defp system_mount(_entry), do: :error

  defp system_mount_name(nil), do: {:ok, nil}
  defp system_mount_name(name) when is_binary(name), do: {:ok, Table.normalize_name(name)}
  defp system_mount_name(_name), do: :error

  defp fetch_entry(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp fetch_entry(entry, key) when is_list(entry), do: Keyword.get(entry, key)

  ## Persistence + broadcasts

  # The WHOLE table is replaced atomically by the store, so the in-memory list
  # and the database can never disagree; a failed write leaves both untouched.
  defp persist(state, mounts) do
    EvoGit.Store.save_vct_mounts(state.store, Enum.map(mounts, &Mount.to_map/1))
  rescue
    exception ->
      Logger.warning("VCT: could not persist the mount table: #{Exception.message(exception)}")
      {:error, :store_unavailable}
  catch
    :exit, reason ->
      Logger.warning("VCT: could not persist the mount table: #{inspect(reason)}")
      {:error, :store_unavailable}
  end

  # ONE broadcast per successful mutation: the node-aware `"vct"` notification,
  # published on the instance's own PubSub (`:pubsub` init opt).
  defp broadcast_mount_change(state),
    do: safe_broadcast(state.pubsub, "vct", {:vct_updated, node()})

  # Best effort and deliberately swallowed: PubSub may be down or unreachable,
  # and a broadcast failure must NEVER fail a mutation that already persisted.
  defp safe_broadcast(pubsub, topic, message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  ## Input handling

  defp validate_os_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> {:error, :invalid_path}
      not EvoGit.Platform.absolute_path?(trimmed) -> {:error, :relative_path}
      true -> {:ok, trimmed}
    end
  end

  defp validate_os_path(_path), do: {:error, :invalid_path}

  defp extract_name(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:ok, nil}
      name when is_binary(name) -> {:ok, Table.normalize_name(name)}
      other -> {:error, {:invalid_name, other}}
    end
  end

  defp extract_name(other), do: {:error, {:invalid_name, other}}

  defp apply_limit(mounts, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(mounts, limit)

  defp apply_limit(mounts, _limit), do: mounts

  # Case-insensitive substring match over name, OS path and VCT point.
  defp matching_mounts(mounts, query) when is_binary(query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      mounts
    else
      Enum.filter(mounts, fn mount ->
        Enum.any?([mount.name, mount.path, mount.point], &contains?(&1, needle))
      end)
    end
  end

  defp matching_mounts(_mounts, _query), do: []

  defp contains?(value, needle) when is_binary(value),
    do: String.contains?(String.downcase(value), needle)

  defp contains?(_value, _needle), do: false

  # A RESERVED (system) mount can never be forgotten — neither by its point
  # (whether or not a row exists) nor by its OS path.
  defp remove_from(mounts, %VctPath{} = point),
    do: refuse_reserved_or_remove_by_point(mounts, VctPath.format(point))

  defp remove_from(mounts, key) when is_binary(key) do
    if point_string?(key) do
      case VctPath.parse(key) do
        {:ok, point} -> refuse_reserved_or_remove_by_point(mounts, VctPath.format(point))
        {:error, _reason} -> {:error, :invalid_point}
      end
    else
      # An OS path first (a workspace owns none), then a BARE WORKSPACE NAME.
      case refuse_reserved_or_remove_by_path(mounts, key) do
        {:error, :not_found} -> remove_workspace_by_name(mounts, key)
        other -> other
      end
    end
  end

  defp remove_from(_mounts, _key), do: {:error, :not_found}

  defp remove_workspace_by_name(mounts, key) do
    case find_workspace_by_name(mounts, String.trim(key)) do
      nil -> {:error, :not_found}
      %Mount{point: point} -> Table.remove_by_point(mounts, point)
    end
  end

  defp refuse_reserved_or_remove_by_point(mounts, point) do
    if Table.reserved?(point),
      do: {:error, :reserved_point},
      else: Table.remove_by_point(mounts, point)
  end

  defp refuse_reserved_or_remove_by_path(mounts, os_path) do
    case Table.find_by_os_path(mounts, os_path) do
      nil ->
        {:error, :not_found}

      mount ->
        if Table.reserved?(mount.point),
          do: {:error, :reserved_point},
          else: Table.remove_by_path(mounts, os_path)
    end
  end

  defp resolve_point(mounts, point) do
    case Table.find_by_point(mounts, point) do
      nil -> {:error, :not_found}
      mount -> {:ok, mount}
    end
  end

  # The ONE VCT-path derivation pass: the containing mount is resolved for
  # `repo_root` ONCE and every relative path is then mapped through the pure
  # `Table.vct_path_for/2`.
  defp vct_paths(mounts, repo_root, relative_paths) do
    mount = Table.mount_for_path(mounts, repo_root)
    Enum.map(relative_paths, fn relative_path -> Table.vct_path_for(mount, relative_path) end)
  end

  defp point_string?(value), do: String.starts_with?(value, "vct:")

  ## Workspaces

  defp workspace_name(name) do
    case Table.normalize_name(name) do
      nil -> {:error, :invalid_name}
      normalized -> {:ok, normalized}
    end
  end

  # The point derives from the SLUGIFIED name, so the display name is free text
  # while the point stays one valid segment. `point_segment/1` already maps
  # separators and control characters, so `format/1` cannot reject it; the
  # rescue keeps this total anyway (a raise would kill the caller's call).
  defp workspace_point_for(name) do
    {:ok, VctPath.format(VctPath.join(VctPath.workspaces(), [Table.point_segment(name)]))}
  rescue
    ArgumentError -> {:error, :invalid_name}
  end

  # A workspace is resolved through its POINT (canonicalized), never through an
  # OS path it does not have.
  defp resolve_workspace(mounts, %VctPath{} = point),
    do: resolve_workspace(mounts, VctPath.format(point))

  defp resolve_workspace(mounts, key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :invalid_point}

      point_string?(trimmed) ->
        with {:ok, point} <- VctPath.canonical(trimmed) do
          workspace_row(mounts, point)
        end

      path_like?(trimmed) ->
        {:error, :invalid_point}

      true ->
        case find_workspace_by_name(mounts, trimmed) do
          nil -> {:error, :not_found}
          %Mount{point: point} -> workspace_row(mounts, point)
        end
    end
  end

  defp resolve_workspace(_mounts, _key), do: {:error, :invalid_point}

  defp workspace_row(mounts, point) do
    case Table.find_by_point(mounts, point) do
      nil ->
        {:error, :not_found}

      %Mount{} = mount ->
        if Mount.workspace?(mount),
          do: {:ok, resolve_members(mounts, mount)},
          else: {:error, :not_a_workspace}
    end
  end

  # ONE member-resolution pass feeds every public shape, so `workspace_members/1`
  # (mount structs), `workspace_entries/1` and `workspace_entries/2` (flat
  # `member_entry` maps) can never disagree.
  defp workspace_entry(mounts, %Mount{} = workspace) do
    mounts
    |> resolve_members(workspace)
    |> to_workspace_entry()
  end

  defp to_workspace_entry(%{members: members} = resolution) do
    %{resolution | members: Enum.map(members, &member_entry/1)}
  end

  defp member_entry(%Mount{} = mount),
    do: %{point: mount.point, name: mount.name, path: mount.path}

  # Every member is resolved IN STORED ORDER; an unresolvable ref keeps its
  # STORED form (it is metadata, not a filesystem probe) and a ref naming
  # another workspace is reported as `nested` instead of being expanded.
  defp resolve_members(mounts, %Mount{members: members} = workspace) do
    {resolved, missing, nested} =
      members
      |> workspace_member_refs()
      |> Enum.reduce({[], [], []}, fn ref, {resolved, missing, nested} ->
        case Table.member_mount(mounts, ref) do
          {:ok, mount} -> {[mount | resolved], missing, nested}
          :missing -> {resolved, [ref | missing], nested}
          :nested -> {resolved, missing, [ref | nested]}
        end
      end)

    %{
      workspace: workspace,
      members: Enum.reverse(resolved),
      missing: Enum.reverse(missing),
      nested: Enum.reverse(nested)
    }
  end

  # A stored row is normally already normalized; a hand-written one is read
  # LENIENTLY so a single unusable ref reports itself as `missing` instead of
  # hiding the whole workspace.
  defp workspace_member_refs(members) when is_list(members) do
    case Mount.normalize_members(members) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> members
    end
  end

  defp workspace_member_refs(_members), do: []

  defp find_workspace_by_name(mounts, name) do
    mounts
    |> Table.workspace_mounts()
    |> Enum.filter(&workspace_name_match?(&1, name))
    |> Table.sort_by_recency()
    |> List.first()
  end

  defp workspace_name_match?(%Mount{point: point, name: display}, name),
    do: VctPath.last_segment(point) == name or display == name

  defp path_like?(key), do: String.contains?(key, ["/", "\\"])

  # The `{point, os_path}` pair a `workspaces_for/1` argument names, enriched
  # from the mount table: a project's point contributes its OS path and an OS
  # path contributes its point, so a member naming EITHER form matches.
  defp workspace_target(mounts, project) do
    case workspace_project_key(project) do
      {:ok, point, os_path} -> enrich_workspace_target(mounts, point, os_path)
      :error -> :error
    end
  end

  defp workspace_project_key(%VctPath{} = point), do: {:ok, VctPath.format(point), nil}

  defp workspace_project_key(project) when is_binary(project) do
    trimmed = String.trim(project)

    cond do
      trimmed == "" ->
        :error

      point_string?(trimmed) ->
        case VctPath.parse(trimmed) do
          {:ok, point} -> {:ok, VctPath.format(point), nil}
          {:error, _reason} -> :error
        end

      EvoGit.Platform.absolute_path?(trimmed) ->
        {:ok, nil, Table.normalize_os_path(trimmed)}

      true ->
        {:ok, project_point(trimmed), nil}
    end
  rescue
    ArgumentError -> :error
  end

  defp workspace_project_key(_project), do: :error

  defp project_point(name),
    do: VctPath.format(VctPath.join(VctPath.projects(), [Table.point_segment(name)]))

  defp enrich_workspace_target(mounts, point, os_path) do
    {point, os_path} = enrich_target_point(mounts, point, os_path)
    enrich_target_path(mounts, point, os_path)
  end

  defp enrich_target_point(_mounts, nil, os_path), do: {nil, os_path}

  defp enrich_target_point(mounts, point, os_path) do
    case Table.find_by_point(mounts, point) do
      %Mount{path: path} when is_binary(path) -> {point, os_path || path}
      _missing -> {point, os_path}
    end
  end

  defp enrich_target_path(_mounts, point, nil), do: {point, nil}

  defp enrich_target_path(mounts, point, os_path) do
    case Table.find_by_os_path(mounts, os_path) do
      %Mount{point: mounted_point} -> {point || mounted_point, os_path}
      nil -> {point, os_path}
    end
  end

  # Project mounts only, or project + workspace mounts when the caller opts in.
  defp listed_mounts(mounts, opts) do
    if include_workspaces?(opts),
      do: Table.project_mounts(mounts) ++ Table.workspace_mounts(mounts),
      else: Table.project_mounts(mounts)
  end

  defp include_workspaces?(opts), do: Keyword.get(opts, :include_workspaces, false) == true

  ## Global context

  # Boot-time counterpart of the lazy sync in `write_global_context/2`: when a
  # NON-BLANK global context file already exists (e.g. restored from a state
  # backup), commit it into its local git history now. An absent or blank file
  # initializes NOTHING (no empty repository), and the sync stays idempotent —
  # a clean tree stages no change, so HEAD is never moved. Every failure is
  # logged, never raised: git trouble must never crash boot.
  defp sync_boot_global_context(vct_dir) do
    context_path = Path.join(vct_dir, @context_file)

    if File.exists?(context_path) and not blank?(read_file(context_path)) do
      sync_context_repository(vct_dir)
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "VCT: boot-time global context git sync failed: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("VCT: boot-time global context git sync failed: #{inspect({kind, reason})}")
      :ok
  end

  defp write_global_context(state, content) do
    context_path = Path.join(state.vct_dir, @context_file)

    with :ok <- File.mkdir_p(state.vct_dir),
         :ok <- File.write(context_path, content, [:binary]) do
      unless blank?(content), do: sync_context_repository(state.vct_dir)
      :ok
    end
  end

  # Best effort: a git failure is logged and must NEVER lose the written file.
  defp sync_context_repository(vct_dir) do
    with :ok <- ensure_git_repository(vct_dir),
         :ok <- ensure_gitignore(vct_dir),
         :ok <- stage_context(vct_dir),
         {:ok, status} <- context_status(vct_dir) do
      maybe_commit_context(vct_dir, status)
    else
      {:error, reason} ->
        Logger.warning("VCT: global context git sync skipped: #{inspect(reason)}")
    end

    :ok
  end

  defp ensure_git_repository(vct_dir) do
    if File.exists?(Path.join(vct_dir, ".git")) do
      :ok
    else
      case EvoGit.Adapters.Git.init(vct_dir) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, {:git_init, reason}}
      end
    end
  end

  defp ensure_gitignore(vct_dir) do
    path = Path.join(vct_dir, ".gitignore")

    if File.exists?(path) do
      :ok
    else
      case File.write(path, Enum.join(@gitignore_entries, "\n") <> "\n") do
        :ok -> :ok
        {:error, reason} -> {:error, {:gitignore, reason}}
      end
    end
  end

  defp stage_context(vct_dir) do
    case EvoGit.Adapters.Git.add(vct_dir, ".") do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_add, reason}}
    end
  end

  defp context_status(vct_dir) do
    case EvoGit.Adapters.Git.status(vct_dir) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, {:git_status, reason}}
    end
  end

  # `{:ok, ""}` after staging means the working tree is clean: nothing to
  # commit, so HEAD is left untouched.
  defp maybe_commit_context(_vct_dir, ""), do: :ok

  defp maybe_commit_context(vct_dir, _status) do
    case EvoGit.Adapters.Git.commit(vct_dir, @global_context_commit_message) do
      {:ok, _output} -> :ok
      {:error, reason} -> Logger.warning("VCT: global context commit failed: #{inspect(reason)}")
    end
  end

  defp blank?(content), do: String.trim(content) == ""

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  defp default_global_context_path do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    Path.join([data_dir, "vct", @context_file])
  end

  ## Total client calls

  # Every client function routes through here so a missing/dead server (a read
  # from `EvoGit.Core.ContextNode`, a boot race, a crash) resolves to the
  # caller's documented value instead of an exit. The DEFAULT is the caller's
  # declared degradation, so an error-union read passes
  # `{:error, :vct_unavailable}` and a list/scalar read passes its empty shape;
  # either way a transport failure is announced once and never invented data.
  defp call(request, default) do
    GenServer.call(server(), request, @call_timeout)
  catch
    :exit, reason -> transport_failure(request, default, reason)
  end

  # ONE warning per failed call (no throttling state): a dead or absent VCT
  # server names itself and the request it could not serve.
  defp transport_failure(request, default, reason) do
    Logger.warning(
      "VCT: #{inspect(server())} unavailable for #{inspect(request)}: #{inspect(reason)}"
    )

    default
  end
end
