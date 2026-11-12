defmodule EvoGit.Sandbox.Spec do
  @moduledoc """
  The ONE platform-neutral sandbox policy spec.

  Genesis sandbox semantics live here and ONLY here: which roots are readable
  and writable, the credential deny list, the default package-manager cache
  dirs, the git metadata dir, the managed per-task tmpdir and the Genesis
  config/data dirs. Renderers (`EvoGit.Sandbox.MacOS`, `EvoGit.Sandbox.Linux`,
  `EvoGit.Sandbox.Bwrap`) translate a `%Spec{}` into their own mechanism —
  SBPL text, `systemd-run` properties, bwrap argv — and add no policy of their
  own: one list, one builder, renderers only render.

  `build/2` is TOTAL: a `nil` `repo_root`, an absent managed per-task tmpdir,
  a cache dir that does not exist and `write_paths: nil | [] | [...]` are all
  handled, no path is required to exist, and no value has to be a valid
  filesystem object. The only required input is `cwd`.

  ## System aliases

  A path can be visible under more than one spelling: on macOS `/tmp` is a
  symlink to `/private/tmp`, so Seatbelt — which matches RESOLVED vnodes —
  never matches a rule written with the logical spelling. `aliases/1` answers
  the spelling pair and `resolve_alias/2` does the ONE-hop resolution (see
  Codex `utils/absolute-path/src/system_aliases.rs`, `normalize_system_aliases`);
  a renderer that can hit a resolvable component emits its rules once per
  spelling. Resolution that would NEST is refused (`nil`), so a helper built on
  it can never loop.

  ## Injection seams (test seams)

  Every input can be injected per call, so a test can pin ONE value without
  touching a BEAM-global (app env / `:persistent_term`). An ABSENT option
  means "resolve it live, exactly as production does":

    * `:cwd` — REQUIRED, absolute working directory of the sandboxed command.
    * `:repo_root` — repo boundary for git-metadata resolution (default `nil`).
    * `:home` — default `System.user_home!()`.
    * `:tmp_paths` — default `EvoGit.Platform.tmp_paths/0`.
    * `:task_tmpdir` — default `EvoGit.Sandbox.Helpers.task_tmpdir_path/0`
      (`nil` when no per-task dir is installed).
    * `:write_paths` — the RAW `[sandbox] write_paths` config value
      (default `EvoGit.Config.resolve([:sandbox, :write_paths])`), resolved
      through `EvoGit.Sandbox.Helpers.resolve_write_paths/3`.
    * `:nix_enabled?` — default `EvoGit.Nix.enabled?/0`.
    * `:config_dir` / `:data_dir` — defaults `EvoGit.Platform.config_dir/0`
      and `EvoGit.Platform.data_dir/0`.
    * `:host_tmpdir` — the macOS host `$TMPDIR` read rule source (default: a
      macOS-only `System.get_env("TMPDIR")` read, `nil` on every other
      backend).
    * `:network` — default `:allow`.
    * `:max_processes` — default `200`.
    * `:git_metadata` — the ONE place a call site pins its historical
      git-metadata input (a path, a one-element list or `nil`); default
      `EvoGit.Sandbox.Helpers.git_metadata_dir(cwd, repo_root)`. The systemd
      renderer's foreground and detached shapes resolve DIFFERENT inputs
      (foreground: `<repo_root>/.git` when a repo root is given; detached:
      `git_metadata_dir(cwd, nil)`), and that asymmetry must not silently
      unify.
  """

  alias EvoGit.{Config, Nix, Platform}
  alias EvoGit.Sandbox.Helpers

  @typedoc "Backends that render a spec today (Windows/MXC is future work)."
  @type backend :: :macos | :linux | :bwrap

  @typedoc """
  The rendered-agnostic policy.

    * `backend` — which renderer consumes this spec.
    * `cwd` — absolute working directory of the sandboxed command.
    * `repo_root` — repo boundary used to resolve `git_metadata_dir`.
    * `home` — home directory every home-relative rule is anchored to.
    * `read_roots` — recursive read allowances (`["/"]`: the whole filesystem
      is readable, protection comes from `deny_paths` + the credential denies).
    * `write_roots` — recursive write allowances that are structural rather
      than configurable (today only `cwd`).
    * `read_only_subpaths` — paths granted READ-ONLY access although an
      enclosing deny root would hide them (macOS: the two SSH host-verification
      files under the otherwise denied `~/.ssh`).
    * `deny_paths` — absolute paths denied for READ (system-level credential
      stores and user databases; macOS-only content).
    * `deny_write_paths` — absolute paths denied for WRITE (always the
      canonical credential list joined to `home`).
    * `credential_paths` — the canonical home-relative credential list, in
      canonical order.
    * `credential_deny_paths` — `credential_paths` joined to `home`, absolute,
      same order.
    * `cache_write_paths` — resolved `[sandbox] write_paths` cache dirs
      (absolute; the built-in default list when the config value is unset).
    * `tmp_paths` — system temp dirs (read+write).
    * `nix_paths` — `/nix/store` + `/nix/var` when nix is enabled, else `[]`.
    * `git_metadata_dir` — git metadata dir that must be writable, or `nil`.
    * `task_tmpdir` — managed per-task tmpdir that must be writable, or `nil`.
    * `config_dir` / `data_dir` — Genesis runtime dirs (read+write).
    * `host_tmpdir` — macOS host `$TMPDIR` read source, `nil` elsewhere.
    * `git_binary_dir` — directory of a VENDORED git binary that needs a read
      rule (macOS only), `nil` when git comes from `PATH`.
    * `network` — `:allow` (Genesis tools need `git fetch/push`, `mix deps.get`,
      `curl`, web tools).
    * `env` — the environment a backend re-injects EXPLICITLY, already filtered
      of `nil` values (the systemd backend re-creates a clean environment, bwrap
      inherits and only needs `TMPDIR`, macOS carries env outside the profile).
    * `max_processes` — process-count limit for renderers that can enforce one.
    * `resources` — backend-neutral resource policy; `%{}` today, because the
      systemd backend resolves its own `[:sandbox, :process]` limits at render
      time (runtime-override precedence) inside `EvoGit.Sandbox.Linux`.
  """
  @type t :: %__MODULE__{
          backend: backend(),
          cwd: String.t(),
          repo_root: String.t() | nil,
          home: String.t(),
          read_roots: [String.t()],
          write_roots: [String.t()],
          read_only_subpaths: [String.t()],
          deny_paths: [String.t()],
          deny_write_paths: [String.t()],
          credential_paths: [String.t()],
          credential_deny_paths: [String.t()],
          cache_write_paths: [String.t()],
          tmp_paths: [String.t()],
          nix_paths: [String.t()],
          git_metadata_dir: String.t() | nil,
          task_tmpdir: String.t() | nil,
          config_dir: String.t(),
          data_dir: String.t(),
          host_tmpdir: String.t() | nil,
          git_binary_dir: String.t() | nil,
          network: :allow | :deny,
          env: [{String.t(), String.t()}],
          max_processes: pos_integer(),
          resources: map()
        }

  defstruct backend: nil,
            cwd: nil,
            repo_root: nil,
            home: nil,
            read_roots: [],
            write_roots: [],
            read_only_subpaths: [],
            deny_paths: [],
            deny_write_paths: [],
            credential_paths: [],
            credential_deny_paths: [],
            cache_write_paths: [],
            tmp_paths: [],
            nix_paths: [],
            git_metadata_dir: nil,
            task_tmpdir: nil,
            config_dir: nil,
            data_dir: nil,
            host_tmpdir: nil,
            git_binary_dir: nil,
            network: :allow,
            env: [],
            max_processes: 200,
            resources: %{}

  @backends [:macos, :linux, :bwrap]

  # THE canonical ordered home-relative credential deny list — the single
  # source for the macOS deny-read/deny-write rules, the systemd
  # `InaccessiblePaths` properties and the bwrap deny-tmpfs overlays.
  # `Library/Keychains` is deliberately NOT here: it is macOS-only and the
  # macOS renderer appends it itself (immediately after `.password-store`).
  @credential_paths [
    ".ssh",
    ".gnupg",
    ".aws",
    ".kube",
    ".config/sops",
    ".git-credentials",
    ".netrc",
    ".password-store",
    ".npmrc",
    ".pypirc",
    ".docker",
    ".gem"
  ]

  # THE canonical ordered default writable cache dirs (home-relative) for
  # package managers and toolchains (`mix deps.get`, `npm install`,
  # `cargo build`). Used when the user has NOT set `[sandbox] write_paths`;
  # a set value (even `[]`) REPLACES this list wholesale — see
  # `EvoGit.Sandbox.Helpers.resolve_write_paths/3`.
  @default_cache_dirs [
    # Universal cache (Python pip, Go build, C/C++ ccache)
    ".cache",
    # Universal local share (pnpm state, generic tools)
    ".local/share",
    # Universal local state
    ".local/state",
    # Rust packages
    ".cargo",
    # Rust toolchains
    ".rustup",
    # Elixir Mix
    ".mix",
    # Elixir Hex
    ".hex",
    # Node.js npm
    ".npm",
    # Node.js yarn
    ".yarn",
    # Bun JS
    ".bun",
    # Java Maven
    ".m2",
    # Java Gradle
    ".gradle",
    # Golang workspace (default GOPATH)
    "go"
  ]

  # System-level sensitive locations (defense in depth for the macOS root-wide
  # read allow): most are root-only-readable anyway, but denying them
  # explicitly guarantees it. Both symlink spellings are covered
  # (/etc ↔ /private/etc and /var ↔ /private/var). ABSOLUTE, not home-relative.
  @system_deny_paths [
    "/etc/ssh",
    "/private/etc/ssh",
    "/var/root",
    "/private/var/root",
    "/etc/master.passwd",
    "/private/etc/master.passwd",
    "/var/db/dslocal",
    "/private/var/db/dslocal",
    "/var/db/Keychains",
    "/private/var/db/Keychains"
  ]

  # SSH host-verification files (home-relative): `git fetch/push` over SSH must
  # read them, while private keys stay unreadable by design (key auth goes
  # through ssh-agent). Granted as read-only carveouts inside the denied `.ssh`.
  @ssh_read_subpaths [".ssh/known_hosts", ".ssh/config"]

  @nix_paths ["/nix/store", "/nix/var"]

  @default_max_processes 200

  @doc """
  The canonical ordered home-relative credential deny list (12 entries).

  `Library/Keychains` is NEVER part of it — it is macOS-only and the macOS
  renderer appends it itself.
  """
  @spec credential_paths() :: [String.t()]
  def credential_paths, do: @credential_paths

  @doc "The canonical ordered default cache dirs (13 entries, home-relative)."
  @spec default_cache_dirs() :: [String.t()]
  def default_cache_dirs, do: @default_cache_dirs

  @doc "The backends `build/2` accepts today."
  @spec backends() :: [backend()]
  def backends, do: @backends

  @doc """
  Every spelling `path` may be visible under inside the sandbox.

  `[path]` when the path's top-level component is not a symlink, else
  `[path, resolved]` — the LOGICAL spelling first, the resolved one second,
  deduped. See `resolve_alias/2`.
  """
  @spec aliases(String.t()) :: [String.t()]
  def aliases(path) when is_binary(path) do
    case resolve_alias(path) do
      nil -> [path]
      resolved -> [path, resolved]
    end
  end

  def aliases(path), do: [path]

  @doc """
  Resolves the FIRST component of `path` through a symlink, ONE hop only.

  `"/tmp/x"` splits into the top-level component `"/tmp"` and the suffix
  `"/x"`; when `<root>/tmp` is a symlink, appending the suffix verbatim to its
  resolved target gives the second spelling (`"/private/tmp/x"`).

  Returns `nil` when there is nothing to resolve:

    * `path` is not absolute, or is `"/"` (no top-level component);
    * `<root>/<first component>` is not a symlink (missing, unreadable, or a
      real file/dir);
    * resolution would NEST — the resolved top-level component is itself a
      symlink. `normalize_system_aliases` iterates; this helper deliberately
      refuses instead of following a second hop;
    * the resolved spelling equals `path`.

  A relative link target is expanded against the component's PARENT (`root`);
  an absolute target is kept as-is. Total: never raises, for any input shape.

  ## Options

    * `:root` — the directory the top-level component is read from. Default
      `"/"`. It exists as a TEST SEAM, so a fixture tree can stand in for `/`
      and a fake `tmp` symlink can be exercised without touching the host;
      production always resolves against `"/"`.
  """
  @spec resolve_alias(String.t(), keyword()) :: String.t() | nil
  def resolve_alias(path, opts \\ [])

  def resolve_alias(path, opts) when is_binary(path) and is_list(opts) do
    root = alias_root(opts)

    with true <- is_binary(root) and String.starts_with?(path, "/"),
         [top | rest] <- String.split(path, "/", trim: true),
         {:ok, target} <- read_link(Path.join(root, top)),
         resolved when is_binary(resolved) <- expand_link_target(target, root),
         false <- symlink?(resolved),
         resolved_path = spelling(resolved, suffix(rest)),
         false <- resolved_path == path do
      resolved_path
    else
      _other -> nil
    end
  end

  def resolve_alias(_path, _opts), do: nil

  @doc """
  Builds the policy spec for `backend`.

  `:cwd` is required; every other option is a default-inert test seam (see the
  moduledoc). Never raises for a `nil`/missing value — only a missing `:cwd`
  raises (`KeyError`).
  """
  @spec build(backend(), keyword()) :: t()
  def build(backend, opts) when backend in @backends and is_list(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    repo_root = Keyword.get(opts, :repo_root)
    home = Keyword.get(opts, :home) || System.user_home!()
    credential_deny_paths = Enum.map(@credential_paths, &Path.join(home, &1))

    %__MODULE__{
      backend: backend,
      cwd: cwd,
      repo_root: repo_root,
      home: home,
      read_roots: ["/"],
      write_roots: [cwd],
      read_only_subpaths: read_only_subpaths(backend, home),
      deny_paths: deny_paths(backend),
      deny_write_paths: credential_deny_paths,
      credential_paths: @credential_paths,
      credential_deny_paths: credential_deny_paths,
      cache_write_paths: cache_write_paths(opts, home),
      tmp_paths: Keyword.get(opts, :tmp_paths) || Platform.tmp_paths(),
      nix_paths: if(nix_enabled?(opts), do: @nix_paths, else: []),
      git_metadata_dir: git_metadata_dir(opts, cwd, repo_root),
      task_tmpdir: Keyword.get_lazy(opts, :task_tmpdir, &Helpers.task_tmpdir_path/0),
      config_dir: Keyword.get(opts, :config_dir) || Platform.config_dir(),
      data_dir: Keyword.get(opts, :data_dir) || Platform.data_dir(),
      host_tmpdir: host_tmpdir(backend, opts),
      git_binary_dir: git_binary_dir(backend),
      network: Keyword.get(opts, :network, :allow),
      env: env(backend),
      max_processes: Keyword.get(opts, :max_processes, @default_max_processes),
      resources: %{}
    }
  end

  # macOS alone grants the SSH host-verification files: its `.ssh` is denied by
  # a deny-read rule (denies beat allows), so the two files need explicit
  # read-only carveouts. The systemd/bwrap backends hide `.ssh` entirely, so
  # there is nothing to carve out.
  defp read_only_subpaths(:macos, home) do
    Enum.map(@ssh_read_subpaths, &Path.join(home, &1))
  end

  defp read_only_subpaths(_backend, _home), do: []

  defp deny_paths(:macos), do: @system_deny_paths
  defp deny_paths(_backend), do: []

  # The user-configurable cache list: unset (`nil`) → the built-in defaults;
  # set (even `[]`) → REPLACES them. The config schema validates a string list,
  # so any other shape degrades to the defaults instead of raising.
  defp cache_write_paths(opts, home) do
    raw =
      case Keyword.fetch(opts, :write_paths) do
        {:ok, value} -> value
        :error -> Config.resolve([:sandbox, :write_paths])
      end

    Helpers.resolve_write_paths(normalize_write_paths(raw), @default_cache_dirs, home)
  end

  defp normalize_write_paths(paths) when is_list(paths), do: paths
  defp normalize_write_paths(_other), do: nil

  defp nix_enabled?(opts) do
    case Keyword.fetch(opts, :nix_enabled?) do
      {:ok, value} -> value == true
      :error -> Nix.enabled?()
    end
  end

  # `:git_metadata` pins the EXACT historical input of a call site (a binary, a
  # one-element list or `nil`); absent means "resolve it here", the shared
  # default used by the macOS and bwrap renderers.
  defp git_metadata_dir(opts, cwd, repo_root) do
    value =
      case Keyword.fetch(opts, :git_metadata) do
        {:ok, value} -> value
        :error -> Helpers.git_metadata_dir(cwd, repo_root)
      end

    case List.wrap(value) do
      [] -> nil
      [path | _rest] -> path
    end
  end

  defp host_tmpdir(:macos, opts) do
    value =
      case Keyword.fetch(opts, :host_tmpdir) do
        {:ok, value} -> value
        :error -> System.get_env("TMPDIR")
      end

    case value do
      dir when is_binary(dir) and dir != "" -> dir
      _other -> nil
    end
  end

  defp host_tmpdir(_backend, _opts), do: nil

  # Vendored git (desktop bundle): when git is NOT on PATH,
  # `Executable.resolve/1` returns the absolute path of the bundled binary, and
  # its dirname needs a read rule. When git IS on PATH the bare name comes back
  # and no rule is needed. macOS-only: the other backends read the root
  # read-only, which already covers the release tree.
  defp git_binary_dir(:macos) do
    case EvoGit.Executable.resolve("git") do
      binary when is_binary(binary) and binary != "git" -> Path.dirname(binary)
      _other -> nil
    end
  end

  defp git_binary_dir(_backend), do: nil

  # `systemd-run --user` starts a nearly clean environment, so the systemd
  # backend re-injects PATH/HOME/TMPDIR; bwrap inherits them and only needs
  # TMPDIR pointed at a writable path; the macOS profile carries no env (env is
  # passed to `sandbox-exec` at run time).
  defp env(:macos), do: []

  defp env(:linux) do
    [
      {"PATH", System.get_env("PATH")},
      {"HOME", System.get_env("HOME")},
      {"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}
    ]
    |> reject_nil_env()
  end

  defp env(_backend) do
    [{"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}]
    |> reject_nil_env()
  end

  defp reject_nil_env(env), do: Enum.reject(env, fn {_key, value} -> is_nil(value) end)

  # --- System aliases (see `resolve_alias/2`) ---

  defp alias_root(opts) do
    case Keyword.get(opts, :root, "/") do
      root when is_binary(root) and root != "" -> root
      _other -> nil
    end
  end

  # `:file.read_link_all/1` returns the RAW link target (never a resolved
  # path) and does not reject a target that is not a valid filename, so the
  # one hop stays exactly one hop. The Erlang file driver may answer a charlist
  # even for a binary path, so both name types are normalized to a binary. Any
  # non-link — a real dir/file, a missing or unreadable path — is
  # `{:error, reason}`.
  defp read_link(path) do
    case :file.read_link_all(path) do
      {:ok, target} when is_binary(target) -> {:ok, target}
      {:ok, target} when is_list(target) -> {:ok, List.to_string(target)}
      _other -> :error
    end
  rescue
    # A malformed path makes the file driver raise `badarg`; `resolve_alias/2`
    # is contractually total, so a raise becomes "nothing to resolve".
    _error -> :error
  end

  defp symlink?(path), do: match?({:ok, _target}, read_link(path))

  defp expand_link_target(target, root) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      :relative -> Path.expand(target, root)
      _other -> nil
    end
  end

  defp suffix([]), do: ""
  defp suffix(rest), do: Enum.map_join(rest, "", &("/" <> &1))

  # A component resolving to "/" must not produce a "//" prefix.
  defp spelling(resolved, ""), do: resolved
  defp spelling("/", suffix), do: suffix
  defp spelling(resolved, suffix), do: resolved <> suffix
end
