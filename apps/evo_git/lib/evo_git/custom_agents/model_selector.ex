defmodule EvoGit.CustomAgents.ModelSelector do
  @moduledoc """
  Compiles and evaluates the user-provided Elixir **model-selection script**
  from `[model_selection] script` in `agents.toml` (owned by `EvoGit.CustomAgents`).

  The script is a plain Elixir expression body evaluated once per agent spawn
  to pick which LLM model the agent should use. It runs in the scheduler
  GenServer process (`EvoGit.AgentScheduler.Dispatch` calls `select_model/1`),
  so ordinary compilation and runtime exceptions are returned as error tuples
  and the caller falls back to the default model. This is trusted user code,
  not a sandbox: throws, exits, blocking code and side effects are not contained.

  ## The `agent` map

  The script body is evaluated as the body of `fn agent -> ... end`, so the
  variable `agent` is in scope — a plain map with these fields:

    * `agent.agent_type` — the agent behaviour module (`module()`), or `:custom`
      for custom agents defined in `agents.toml`
    * `agent.custom_agent_id` — the custom agent id (`String.t()`) or `nil`
    * `agent.depth` — agent nesting depth (`non_neg_integer()`, `0` for roots)
    * `agent.parent_id` — parent agent id (`pos_integer()`) or `nil`
    * `agent.task_id` — task id string or `nil`
    * `agent.objective` — the task objective string

  ## Return contract

  The value of the **last expression** in the script is the result:

    * a nonempty binary → legacy model/profile id: `{:ok, model_id}`
    * a map with nonempty binary `provider_profile_id` and `model` fields →
      `{:ok, selection}` with atom keys; atom or string input keys are accepted
    * optional `reasoning_effort` → a nonempty string or atom, normalized to a
      string; absent/nil effort is omitted so the schema uses its configured default
    * `nil`, `""` or `false` → default model: `{:ok, nil}`
    * anything else → `{:error, {:invalid_result, inspect(value)}}` (default model)

  Only selection fields are retained from maps; atom keys take precedence when
  both key forms are present. Profile/model existence and supported effort
  inventories are checked later by the configuration schema,
  not by this evaluator (just as with legacy ids).

  Example script (replace the account/model names with configured values):

      if agent.depth == 0 do
        %{provider_profile_id: "primary-account", model: "reasoner", reasoning_effort: :high}
      else
        %{provider_profile_id: "fast-account", model: "fast-model"}
      end

  ## Caching

  Compilation happens **lazily on the first `select_model/1` / `status/0` /
  `enabled?/0` call — never at app boot** — so a broken script can never
  prevent the scheduler from starting (dispatch sees `{:error, ...}` and falls
  back to the default model with a log warning). The compiled script is cached
  in `:persistent_term`, keyed by `{__MODULE__, :cache, path}` and storing
  `{mtime, size, entry}`, mirroring `EvoGit.Config.cached_file_read/2`: every
  call stats `agents.toml` and reuses the cache only when both mtime and size
  match, so external edits are picked up automatically. This makes the
  per-spawn dispatch cost exactly one `File.stat` + one `:persistent_term.get`
  after the first call (the TOML parse is not repeated). `invalidate/0` erases
  the cache entry (called by `EvoGit.CustomAgents.reload/0`).
  """

  alias EvoGit.Config.Schema.ProviderProfiles.Normalize

  @type selection :: %{
          required(:provider_profile_id) => String.t(),
          required(:model) => String.t(),
          optional(:reasoning_effort) => String.t()
        }

  @doc """
  Compiles a script body into a callable function.

  The body is wrapped as the body of `fn agent -> ... end`, so the variable
  `agent` is in scope and the value of the last expression is the result.
  Compile failures (syntax errors etc.) are returned as
  `{:error, {:compile_error, message}}`.
  """
  @spec compile_script(String.t()) :: {:ok, fun()} | {:error, {:compile_error, String.t()}}
  def compile_script(script_body) when is_binary(script_body) do
    # `_ = agent` keeps the variable in scope while suppressing the spurious
    # "variable agent is unused" warning for scripts that pick a model without
    # inspecting the agent map (e.g. a constant `"fast"` body).
    source = "fn agent ->\n  _ = agent\n" <> script_body <> "\nend"

    # try/rescue is justified here: the body is USER-PROVIDED code, so compile
    # errors (SyntaxError, TokenMissingError, ...) are an expected input, not a
    # bug. They must surface as `{:error, {:compile_error, msg}}` and never
    # crash the caller — the same way the config parser treats corrupt config
    # files as error results instead of raising.
    try do
      {fun, _binding} = Code.eval_string(source)
      {:ok, fun}
    rescue
      error ->
        # Exception.format/3 is always a String (bare exceptions can have a
        # nil message), so the returned tuple always carries a displayable msg.
        {:error, {:compile_error, Exception.format(:error, error)}}
    end
  end

  @doc """
  Evaluates the configured model-selection script for one agent spawn.

  `agent` is the attributes map passed through to the script:

      %{
        agent_type: module() | :custom,
        custom_agent_id: String.t() | nil,
        depth: non_neg_integer(),
        parent_id: pos_integer() | nil,
        task_id: String.t() | nil,
        objective: String.t()
      }

  Returns `{:ok, model_id}` for a legacy binary or `{:ok, selection}` for a
  canonical account/model map (see the module return contract).
  Returns `{:ok, nil}` when no script is configured (missing/blank) or the
  script yields `nil`/`""`/`false` (default model), and an error tuple otherwise.
  Ordinary user-script exceptions are returned as `{:error, ...}`; throws and
  exits retain the trusted-script behavior and are not caught.
  """
  @spec select_model(map()) ::
          {:ok, String.t() | selection() | nil}
          | {:error,
             {:script_raised, String.t()}
             | {:invalid_result, String.t()}
             | {:compile_error, String.t()}}
  def select_model(agent_attrs) when is_map(agent_attrs) do
    case cached_entry() do
      :none ->
        {:ok, nil}

      {:ok, fun} ->
        evaluate_script(fun, agent_attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current compile status of the configured script.

  `:ok` when no script is configured (or it compiles cleanly);
  `{:error, {:compile_error, msg}}` when a script is configured but broken.
  Used by the dashboard to surface script errors in the UI.
  """
  @spec status() :: :ok | {:error, {:compile_error, String.t()}}
  def status do
    case cached_entry() do
      {:error, reason} -> {:error, reason}
      _other -> :ok
    end
  end

  @doc """
  Returns whether a model-selection script is configured.

  Uses the cached path — no compile is forced, so a configured-but-broken
  script still counts as enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    cached_entry() != :none
  end

  @doc """
  Returns a human-readable description of the script contract (the `agent` map
  fields and the return contract), used as UI help text.
  """
  @spec describe_contract() :: String.t()
  def describe_contract do
    """
    The script is evaluated per agent spawn as the body of an anonymous
    function with a single `agent` variable in scope — a plain map:

      agent.agent_type       the agent module (or :custom for custom agents)
      agent.custom_agent_id  the custom agent id, or nil
      agent.depth            nesting depth (0 for root agents)
      agent.parent_id        parent agent id, or nil
      agent.task_id          task id string, or nil
      agent.objective        the task objective string

    The value of the LAST expression is the result:
      a binary            → legacy model/profile id
      a selection map     → provider_profile_id and model (nonempty strings),
                            optional reasoning_effort (nonempty string or atom)
      nil, "" or false    → default model
      anything else       → invalid_result error (default model is used)

    Selection maps accept atom or string keys and return only atom-keyed selection
    fields, with effort normalized to a string (absent/nil effort is omitted).
    The configuration schema checks account/model existence and supported efforts.

    Example (use your configured account/model names):
      if agent.depth == 0 do
        %{provider_profile_id: "primary-account", model: "reasoner", reasoning_effort: :high}
      else
        %{provider_profile_id: "fast-account", model: "fast-model"}
      end
    """
  end

  @doc """
  Erases the compiled-script cache entry for the current `agents.toml` path.

  Called by `EvoGit.CustomAgents.reload/0` so the next
  `select_model/1`/`status/0`/`enabled?/0` call re-reads and re-compiles.
  """
  @spec invalidate() :: :ok
  def invalidate do
    path = EvoGit.CustomAgents.path()
    :persistent_term.erase(cache_key(path))
    :ok
  end

  # --- Script evaluation ---

  defp evaluate_script(fun, agent_attrs) do
    # try/rescue is justified here: the compiled function is USER-PROVIDED code
    # that can raise at run time (bad map access, explicit raise, ...). The
    # exception must NEVER crash the scheduler GenServer that calls
    # select_model/1, so it is caught and surfaced as
    # {:error, {:script_raised, msg}} — the caller falls back to the default
    # model, mirroring how the config parser treats corrupt config files.
    result =
      try do
        fun.(agent_attrs)
      rescue
        error ->
          # Exception.format/3 is always a String (bare exceptions can have a
          # nil message), so the returned tuple always carries a displayable msg.
          {:raised, Exception.format(:error, error)}
      end

    normalize_result(result)
  end

  defp normalize_result({:raised, message}), do: {:error, {:script_raised, message}}
  defp normalize_result(nil), do: {:ok, nil}
  defp normalize_result(""), do: {:ok, nil}
  defp normalize_result(false), do: {:ok, nil}
  defp normalize_result(model) when is_binary(model), do: {:ok, model}

  defp normalize_result(%{} = selection) do
    profile_id = selection_field(selection, :provider_profile_id)
    model = selection_field(selection, :model)
    effort = selection_field(selection, :reasoning_effort)
    normalized_effort = Normalize.string_effort(effort)

    if is_binary(profile_id) and profile_id != "" and is_binary(model) and model != "" and
         (is_nil(effort) or not is_nil(normalized_effort)) do
      normalized = %{provider_profile_id: profile_id, model: model}

      {:ok,
       if(is_nil(normalized_effort),
         do: normalized,
         else: Map.put(normalized, :reasoning_effort, normalized_effort)
       )}
    else
      {:error, {:invalid_result, inspect(selection)}}
    end
  end

  defp normalize_result(other), do: {:error, {:invalid_result, inspect(other)}}

  defp selection_field(selection, key) do
    Map.get(selection, key, Map.get(selection, Atom.to_string(key)))
  end

  # --- Caching (stat-validated, mirroring EvoGit.Config.cached_file_read/2) ---

  defp cache_key(path), do: {__MODULE__, :cache, path}

  defp cached_entry do
    path = EvoGit.CustomAgents.path()

    case File.stat(path) do
      {:ok, stat} ->
        key = cache_key(path)

        case :persistent_term.get(key, :not_cached) do
          {mtime, size, entry} when mtime == stat.mtime and size == stat.size ->
            entry

          _miss_or_stale ->
            entry = build_entry()
            :persistent_term.put(key, {stat.mtime, stat.size, entry})
            entry
        end

      {:error, _reason} ->
        # Missing or unreadable agents.toml — same as no script configured.
        :none
    end
  end

  defp build_entry do
    case EvoGit.CustomAgents.model_selection_script() do
      nil ->
        :none

      script ->
        if String.trim(script) == "" do
          :none
        else
          compile_script(script)
        end
    end
  end
end
