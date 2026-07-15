defmodule EvoGit.Config.Schema.Definitions do
  @moduledoc """
  Schema definitions — pure data describing every config key.
  """

  @doc """
  Returns all configuration key schemas as a flat list of maps.

  Each schema map contains:
  - `:key_path` — the full path as a list of atoms
  - `:type` — the expected value type (`:pos_integer`, `:string`, `:atom`, etc.)
  - `:default` — the default value (or nil if none)
  - `:validation` — a keyword list of validation rules (`min:`, `max:`, `in:`)
  - `:category` — the top-level config category
  - `:sub_category` — sub-category within sandbox (`:resources`, `:process`, or `:linux`); nil otherwise
  - `:description` — human-readable description string
  """
  @spec schemas() :: [EvoGit.Config.Schema.schema_map()]
  def schemas do
    [
      # ── Scheduler ──────────────────────────────────────────────────────
      %{
        key_path: [:scheduler, :max_concurrency],
        type: :pos_integer,
        default: 3,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum number of concurrent LLM API calls. Controls how many agents can make API calls simultaneously. Lower values reduce API rate-limit pressure but slow down overall progress."
      },
      %{
        key_path: [:scheduler, :max_tool_concurrency],
        type: :pos_integer,
        default: 2,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum number of concurrent tool executions. Controls how many tool calls (bash, file operations, etc.) can run in parallel. Reduce if you encounter system resource pressure."
      },
      %{
        key_path: [:scheduler, :agent_max_retries],
        type: :non_neg_integer,
        default: 3,
        validation: [min: 0],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum number of crash-retries per agent. When an agent crashes due to an unexpected error, the scheduler will restart it up to this many times. Set to 0 to disable retries."
      },
      %{
        key_path: [:scheduler, :max_agent_depth],
        type: :pos_integer,
        default: 8,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum subagent recursion depth. Prevents infinite delegation chains. A manager can spawn sub-managers, who can spawn further managers, up to this many levels deep."
      },
      %{
        key_path: [:scheduler, :max_retries],
        type: :pos_integer,
        default: 15,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum total LLM API retries across all agents. When the system encounters rate-limit errors or transient API failures, it will retry up to this many times before giving up."
      },
      %{
        key_path: [:scheduler, :max_turns],
        type: :pos_integer,
        default: 128,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum number of agent turns. An agent turn consists of one LLM call followed by tool execution. This limit prevents runaway loops from consuming excessive API credits."
      },
      %{
        key_path: [:scheduler, :max_turns_root],
        type: :pos_integer,
        default: 128,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum number of turns for the root (top-level) agent only. " <>
            "This is separate from `max_turns` which controls sub-agents. " <>
            "The root agent is special because when it exits, the entire task ends — " <>
            "unlike sub-agents which can be respawned by their parent. Use a higher value " <>
            "here if you want the root agent to have more room to complete complex tasks."
      },
      %{
        key_path: [:scheduler, :delegation_hint_threshold],
        type: :pos_integer,
        default: 5,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Number of write-tool calls to the same child directory before the agent is nudged to spawn a subagent. " <>
            "When an agent edits files in a child directory this many times, a friendly hint is appended to the tool output " <>
            "suggesting it delegate to a subagent at that path. Set to 0 to disable delegation hints."
      },
      %{
        key_path: [:scheduler, :read_delegation_hint_threshold],
        type: :pos_integer,
        default: 8,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Number of read-tool calls (read_file, rg, glob, list_dir) to the same child directory before the agent is nudged to delegate investigation to a subagent. " <>
            "When a high-level agent reads files in a child directory this many times, a hint is appended to the tool output " <>
            "suggesting it spawn a subagent_codebase_investigator at that path. Set to 0 to disable read delegation hints."
      },
      %{
        key_path: [:scheduler, :max_tool_timeout],
        type: :pos_integer,
        default: 1_800_000,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Maximum tool execution timeout in milliseconds (hard cap). Any tool timeout requested by an agent is capped at this value to prevent runaway executions."
      },
      %{
        key_path: [:scheduler, :default_tool_timeout],
        type: :pos_integer,
        default: 10_000,
        validation: [min: 1],
        category: :scheduler,
        sub_category: nil,
        description:
          "Default tool execution timeout in milliseconds (used when the agent omits the timeout argument). Normally applies to simple tools that should respond quickly."
      },
      # ── LLM ────────────────────────────────────────────────────────────
      %{
        key_path: [:llm, :model],
        type: :model_spec,
        default: nil,
        validation: [],
        category: :llm,
        sub_category: nil,
        description:
          "The LLM model identifier in 'provider:model' format. Examples: 'anthropic:claude-sonnet-4-20250514', 'google:gemini-2.0-flash-exp', 'zai:glm-5.1'. The provider portion determines which API key is used. This setting is required for Genesis to function. Alternatively, a map may be used for OpenAI-compatible providers: {provider = \"openai\", id = \"my-model\", base_url = \"https://...\"}."
      },
      %{
        key_path: [:llm, :compression_threshold_tokens],
        type: :pos_integer,
        default: 100_000,
        validation: [min: 1],
        category: :llm,
        sub_category: nil,
        description:
          "Token count threshold that triggers context compression. When an agent's accumulated context (system prompt, conversation history, tool outputs) exceeds this token count, older context is compressed to avoid hitting the LLM's context window limit."
      },
      %{
        key_path: [:llm, :temperature],
        type: :float,
        default: nil,
        validation: [min: 0.0, max: 2.0],
        category: :llm,
        sub_category: nil,
        description:
          "Controls randomness in LLM responses. Lower values make output more focused and deterministic, while higher values make it more creative and varied. Range: 0.0–2.0. Normally you should leave this unset — modern LLMs perform best with their default temperature and changing it may degrade output quality."
      },
      %{
        key_path: [:llm, :max_tokens],
        type: :pos_integer,
        default: nil,
        validation: [min: 1],
        category: :llm,
        sub_category: nil,
        description:
          "Maximum number of tokens in the LLM response. Limits the length of generated text. Leave unset to use the provider's default (typically the model's maximum)."
      },
      %{
        key_path: [:llm, :reasoning_effort],
        type: :string,
        default: nil,
        validation: [],
        category: :llm,
        sub_category: nil,
        description:
          "Controls how much effort the model spends reasoning before answering. Valid values: none, minimal, low, medium, high, xhigh, default (mapped to atoms in Elixir). Leave unset to use the provider's default."
      },
      %{
        key_path: [:llm, :top_p],
        type: :float,
        default: nil,
        validation: [min: 0.0, max: 1.0],
        category: :llm,
        sub_category: nil,
        description:
          "Nucleus sampling threshold. The model considers tokens with top_p probability mass. Range: 0.0–1.0. Normally you should leave this unset — modern LLMs perform best with their default value and changing it may degrade output quality."
      },
      %{
        key_path: [:llm, :top_k],
        type: :pos_integer,
        default: nil,
        validation: [min: 1],
        category: :llm,
        sub_category: nil,
        description:
          "Limits token selection to the K most probable tokens. Normally you should leave this unset — modern LLMs perform best with their default value and changing it may degrade output quality."
      },
      %{
        key_path: [:llm, :frequency_penalty],
        type: :float,
        default: nil,
        validation: [min: -2.0, max: 2.0],
        category: :llm,
        sub_category: nil,
        description:
          "Penalizes tokens based on their frequency in the generated text so far. Range: -2.0 to 2.0. Normally you should leave this unset — modern LLMs perform best with their default value and changing it may degrade output quality."
      },
      %{
        key_path: [:llm, :presence_penalty],
        type: :float,
        default: nil,
        validation: [min: -2.0, max: 2.0],
        category: :llm,
        sub_category: nil,
        description:
          "Penalizes tokens that have already appeared in the generated text. Range: -2.0 to 2.0. Normally you should leave this unset — modern LLMs perform best with their default value and changing it may degrade output quality."
      },
      %{
        key_path: [:llm, :models],
        type: :model_profiles,
        default: [],
        validation: [],
        category: :llm,
        sub_category: nil,
        description:
          "Array of model profiles, each defining an LLM model and its generation parameters. Each profile is a TOML table: id (required string), model (required, same format as [llm].model), concurrency (default 3), optional generation params (temperature, max_tokens, reasoning_effort, top_p, top_k, frequency_penalty, presence_penalty), and an optional provider_options map for provider-specific options (e.g. {store: false} for OpenAI). When absent, the flat [llm] fields are migrated into a single 'default' profile during resolution."
      },
      # ── User ───────────────────────────────────────────────────────────
      %{
        key_path: [:user, :github_username],
        type: :string,
        default: nil,
        validation: [],
        category: :user,
        sub_category: nil,
        description:
          "Your GitHub username. Used when creating pull requests to attribute the PR to your account. Optional but recommended if you plan to use the automated PR creation feature."
      },
      # ── Sandbox ────────────────────────────────────────────────────────
      %{
        key_path: [:sandbox, :mode],
        type: :atom,
        default: :auto,
        validation: [in: [:auto, :enabled, :disabled]],
        category: :sandbox,
        sub_category: nil,
        description:
          "Sandbox execution mode. 'auto' enables sandboxing on supported platforms (Linux with systemd-run, macOS with sandbox-exec) and falls back to direct execution on unsupported platforms. 'enabled' forces sandboxing and fails if unavailable. 'disabled' skips sandboxing entirely."
      },
      %{
        key_path: [:sandbox, :resources, :cpu_quota],
        type: :string,
        default: "1000%",
        validation: [],
        category: :sandbox,
        sub_category: :resources,
        description:
          "Aggregate CPU quota for all sandboxed processes combined. Uses systemd CPUQuota format (e.g., '1000%' = 10 CPU cores). This is the total CPU available across the entire sandbox slice."
      },
      %{
        key_path: [:sandbox, :resources, :cpu_weight],
        type: :pos_integer,
        default: 30,
        validation: [min: 1, max: 10_000],
        category: :sandbox,
        sub_category: :resources,
        description:
          "CPU allocation weight for the sandbox slice relative to other system workloads (1-10000). Higher values give Genesis processes more CPU time when the system is under contention. Default of 30 provides moderate priority."
      },
      %{
        key_path: [:sandbox, :resources, :memory_max],
        type: :string,
        default: "16G",
        validation: [],
        category: :sandbox,
        sub_category: :resources,
        description:
          "Total memory limit for all sandboxed processes combined. Uses systemd memory format (e.g., '16G', '8G', '512M'). When the aggregate memory usage exceeds this limit, the kernel's OOM killer may terminate processes."
      },
      %{
        key_path: [:sandbox, :resources, :tasks_max],
        type: :pos_integer,
        default: 8196,
        validation: [min: 1],
        category: :sandbox,
        sub_category: :resources,
        description:
          "Maximum number of tasks (processes and threads) allowed across the entire sandbox slice. Prevents fork bombs and runaway process creation from consuming system resources."
      },
      %{
        key_path: [:sandbox, :process, :cpu_quota],
        type: :string,
        default: "800%",
        validation: [],
        category: :sandbox,
        sub_category: :process,
        description:
          "Per-process CPU quota for individual tool executions. Uses systemd CPUQuota format (e.g., '800%' = 8 CPU cores). Each tool call (bash, compile, etc.) is limited to this amount of CPU time."
      },
      %{
        key_path: [:sandbox, :process, :memory_max],
        type: :string,
        default: "12G",
        validation: [],
        category: :sandbox,
        sub_category: :process,
        description:
          "Per-process memory limit for individual tool executions. Uses systemd memory format (e.g., '12G', '4G', '512M'). A single tool call that exceeds this limit will be killed."
      },
      %{
        key_path: [:sandbox, :process, :limit_nofile],
        type: :pos_integer,
        default: 65536,
        validation: [min: 1],
        category: :sandbox,
        sub_category: :process,
        description:
          "Maximum number of open file descriptors per sandboxed process. Limits how many files a single tool execution can have open simultaneously."
      },
      %{
        key_path: [:sandbox, :process, :oom_score_adjust],
        type: :integer,
        default: 1000,
        validation: [min: -1000, max: 1000],
        category: :sandbox,
        sub_category: :process,
        description:
          "OOM killer adjustment score per process (-1000 to 1000). Higher values make processes more likely to be killed when memory is exhausted. Default of 1000 means sandboxed processes are preferentially killed over system processes."
      },
      # ── Sandbox: Linux security features ──────────────────────────────
      %{
        key_path: [:sandbox, :linux, :protect_system],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable ProtectSystem=strict (systemd v214+). Makes /usr, /boot, and /etc read-only inside the sandbox."
      },
      %{
        key_path: [:sandbox, :linux, :protect_home],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable ProtectHome=read-only (systemd v214+). Makes /home read-only except for explicitly whitelisted ReadWritePaths."
      },
      %{
        key_path: [:sandbox, :linux, :protect_kernel_tunables],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable ProtectKernelTunables=yes (systemd v218+). Prevents modification of kernel tunables in /sys and /proc/sys."
      },
      %{
        key_path: [:sandbox, :linux, :protect_control_groups],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable ProtectControlGroups=yes (systemd v214+). Prevents the sandboxed process from modifying control group hierarchies."
      },
      %{
        key_path: [:sandbox, :linux, :system_call_filter],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable system call filtering (systemd v214+). Restricts which syscalls the sandboxed process can make. Controls SystemCallArchitectures=native, SystemCallErrorNumber=EPERM, and SystemCallFilter=~ @clock @module @mount @raw-io @reboot @swap."
      },
      %{
        key_path: [:sandbox, :linux, :no_new_privileges],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable NoNewPrivileges=yes (systemd v214+). Prevents the sandboxed process from gaining new privileges via setuid binaries or sudo."
      },
      %{
        key_path: [:sandbox, :linux, :private_pids],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable PrivatePIDs=yes (systemd v239+). Hides host processes from the sandboxed process's view via a private PID namespace."
      },
      %{
        key_path: [:sandbox, :linux, :protect_proc],
        type: :boolean,
        default: true,
        validation: [],
        category: :sandbox,
        sub_category: :linux,
        description:
          "Enable ProtectProc=invisible (systemd v247+). Hides processes of other users in /proc from the sandboxed process."
      },
      # ── Truncation ─────────────────────────────────────────────────────
      %{
        key_path: [:truncation, :tool_output_max_bytes],
        type: :pos_integer,
        default: 131_072,
        validation: [min: 1],
        category: :truncation,
        sub_category: nil,
        description:
          "Maximum tool output size in bytes before truncation is triggered. When a tool returns output larger than this threshold (default 128 KB), the output is truncated to avoid overwhelming the LLM context window."
      },
      %{
        key_path: [:truncation, :tool_output_default_max_bytes],
        type: :pos_integer,
        default: 16_384,
        validation: [min: 1],
        category: :truncation,
        sub_category: nil,
        description:
          "Default maximum output size in bytes for high-output tools. Used as the default truncation point for tools known to produce large outputs. Most tools use this value unless overridden per-tool."
      },
      %{
        key_path: [:truncation, :tool_output_truncate_size],
        type: :pos_integer,
        default: 8_192,
        validation: [min: 1],
        category: :truncation,
        sub_category: nil,
        description:
          "Size in bytes to which truncated output is reduced. When a tool's output exceeds the max bytes threshold, it is cut down to this size (default 8 KB). The truncated portion is replaced with a notice indicating how much was removed."
      },
      %{
        key_path: [:truncation, :context_max_bytes],
        type: :pos_integer,
        default: 65_536,
        validation: [min: 1],
        category: :truncation,
        sub_category: nil,
        description:
          "Maximum size in bytes for CONTEXT.md file content. When reading or writing CONTEXT.md files, content exceeding this limit (default 64 KB) is truncated to prevent context bloat."
      },
      # ── Task History ───────────────────────────────────────────────────
      %{
        key_path: [:task_history, :max_tasks],
        type: :pos_integer,
        default: 100,
        validation: [min: 1],
        category: :task_history,
        sub_category: nil,
        description:
          "Maximum number of recent tasks retained in the dashboard history. Older tasks beyond this limit are automatically purged to manage storage. Each task represents one top-level Genesis run."
      },
      %{
        key_path: [:task_history, :max_age_days],
        type: :pos_integer,
        default: 14,
        validation: [min: 1],
        category: :task_history,
        sub_category: nil,
        description:
          "Maximum age in days for retained task history entries. Tasks older than this are automatically purged regardless of the max_tasks limit. Keeps the task history dashboard manageable."
      },
      # ── Nix ────────────────────────────────────────────────────────────
      %{
        key_path: [:nix, :enabled],
        type: :boolean,
        default: false,
        validation: [],
        category: :nix,
        sub_category: nil,
        description:
          "When true, enables running all tool calls inside a cached Nix dev environment. The dev env is built once via `nix print-dev-env` and sourced per call. Requires the `nix` binary to be available and a `flake.nix` to exist in the config directory (e.g. ~/.config/genesis/flake.nix). When nix or the flake is unavailable, commands run normally regardless of this setting."
      },
      %{
        key_path: [:nix, :flake_output],
        type: :string,
        default: nil,
        validation: [],
        category: :nix,
        sub_category: nil,
        description:
          "Optional flake output attribute to use (e.g. \"devShells.x86_64-linux.default\"). When nil, uses the default devShell. Appended to the flake URI as \"#<output>\" for `nix print-dev-env`."
      },
      # ── Git ────────────────────────────────────────────────────────────
      %{
        key_path: [:git, :co_authored_by_enabled],
        type: :boolean,
        default: true,
        validation: [],
        category: :git,
        sub_category: nil,
        description:
          "When true, appends a 'Co-authored-by: Genesis <noreply@evogit.ai>' trailer to all agent-generated git commits. Disable to omit the co-author attribution."
      },
      # ── Tools ────────────────────────────────────────────────────────────
      %{
        key_path: [:tools, :search, :enabled],
        type: :boolean,
        default: false,
        validation: [],
        category: :tools,
        sub_category: nil,
        description:
          "Enable web search tool for agents. Requires a configured API key."
      },
      %{
        key_path: [:tools, :search, :provider],
        type: :atom,
        default: :tavily,
        validation: [in: [:tavily]],
        category: :tools,
        sub_category: nil,
        description:
          "Search service provider."
      },
      %{
        key_path: [:tools, :search, :tavily, :api_key_credential_key],
        type: :string,
        default: "TAVILY_API_KEY",
        validation: [],
        category: :tools,
        sub_category: nil,
        description:
          "Credential key name for the Tavily API key."
      },
      %{
        key_path: [:tools, :search, :tavily, :base_url],
        type: :string,
        default: "https://api.tavily.com/search",
        validation: [],
        category: :tools,
        sub_category: nil,
        description:
          "Tavily API endpoint URL."
      },
      %{
        key_path: [:tools, :search, :tavily, :search_depth],
        type: :atom,
        default: :basic,
        validation: [in: [:basic, :advanced]],
        category: :tools,
        sub_category: nil,
        description:
          "Search depth (basic or advanced)."
      },
      %{
        key_path: [:tools, :search, :tavily, :max_results],
        type: :pos_integer,
        default: 10,
        validation: [min: 1, max: 50],
        category: :tools,
        sub_category: nil,
        description:
          "Maximum number of search results (1-50)."
      },
      %{
        key_path: [:tools, :search, :tavily, :timeout],
        type: :pos_integer,
        default: 60000,
        validation: [],
        category: :tools,
        sub_category: nil,
        description:
          "Search request timeout in milliseconds."
      },
      %{
        key_path: [:tools, :search, :tavily, :max_bytes],
        type: :pos_integer,
        default: 16384,
        validation: [],
        category: :tools,
        sub_category: nil,
        description:
          "Maximum output size in bytes."
      },
      # ── Server ─────────────────────────────────────────────────────────
      %{
        key_path: [:server, :listen_ip],
        type: :string,
        default: "127.0.0.1",
        validation: [],
        category: :server,
        sub_category: nil,
        description:
          "IP address the web dashboard binds to. Defaults to loopback (127.0.0.1) for security — only local connections are accepted. Set to \"0.0.0.0\" to accept connections from any network interface."
      },
      %{
        key_path: [:server, :listen_port],
        type: :pos_integer,
        default: 9999,
        validation: [min: 1024, max: 65535],
        category: :server,
        sub_category: nil,
        description:
          "Port the web dashboard listens on. Must be between 1024 and 65535 (privileged ports below 1024 are not supported for security reasons)."
      },
      # ── Node / Distribution ─────────────────────────────────────────────
      %{
        key_path: [:node, :enabled],
        type: :boolean,
        default: false,
        validation: [],
        category: :node,
        sub_category: nil,
        description:
          "Enable distributed Erlang at application startup. When enabled, the node starts EPMD, sets a distributed node name, and sets the magic cookie, allowing the local dashboard to connect to remote genesis_remote daemons over SSH tunnels."
      },
      %{
        key_path: [:node, :node_name],
        type: :string,
        default: "genesis@127.0.0.1",
        validation: [],
        category: :node,
        sub_category: nil,
        description:
          "The distributed Erlang node name. For longnames mode this must include the hostname (e.g. 'genesis@127.0.0.1'); for shortnames mode it should be a short name (e.g. 'genesis')."
      },
      %{
        key_path: [:node, :shortnames],
        type: :boolean,
        default: false,
        validation: [],
        category: :node,
        sub_category: nil,
        description:
          "Whether to use short names (:shortnames) or long names (:longnames) distribution mode. Short names are suitable for single-host or local network setups; long names are required for cross-network distribution."
      },
      %{
        key_path: [:node, :cookie],
        type: :string,
        default: "genesis_cookie",
        validation: [],
        category: :node,
        sub_category: nil,
        description:
          "The Erlang magic cookie for distribution authentication. Must match the cookie used by remote nodes you want to connect to."
      },
      %{
        key_path: [:node, :dist_port],
        type: :pos_integer,
        default: 9000,
        validation: [min: 1024, max: 65535],
        category: :node,
        sub_category: nil,
        description:
          "Distribution port used for EPMD-less distribution or inet_dist_listen configuration. Must match the port used by remote nodes for SSH tunnel forwarding."
      },
      %{
        key_path: [:node, :start_epmd],
        type: :boolean,
        default: true,
        validation: [],
        category: :node,
        sub_category: nil,
        description:
          "Whether to start EPMD (Erlang Port Mapper Daemon) explicitly from the running ERTS. Set to false for EPMD-less distribution where nodes connect directly on a pinned port."
      }
    ]
  end
end
