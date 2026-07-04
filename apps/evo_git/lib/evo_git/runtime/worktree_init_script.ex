defmodule EvoGit.Runtime.WorktreeInitScript do
  @moduledoc """
  Generates a "Worktree Init Script" via a one-shot LLM query at the start of
  Genesis Mode B (new codebase).

  The generated script is written into `genesis.toml` at the repo root under
  `[worktree].script` so that the existing per-worktree init-script infrastructure
  (`EvoGit.ProjectConfig.worktree_script/2` → `EvoGit.AgentScheduler.Worktrees.run_init_script/3`)
  picks it up and runs it on every newly-created worktree. This speeds up builds by
  copying dependencies, build cache, or build results from the source repo into the
  new worktree (avoiding re-downloading/recompiling from scratch).

  This runs BEFORE any agent is spawned, so there is no slot acquisition — it is a
  single standalone LLM call.
  """

  require Logger

  alias EvoGit.Config

  @doc """
  Generates a worktree init script for the project being created in Genesis Mode B.

  Returns:
    * `{:ok, script_content}` — the generated script content (shell code).
    * `:skip` — no LLM model is configured; generation was skipped.
    * `{:error, reason}` — the LLM call failed or returned no usable text.
  """
  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | :skip | {:error, term()}
  def generate(objective, _repo_path) do
    model = Config.resolve([:llm, :model])

    if is_nil(model) or model == "" do
      Logger.info("WorktreeInitScript: No LLM model configured, skipping generation")
      :skip
    else
      system_prompt = build_system_prompt()
      user_prompt = build_user_prompt(objective)

      do_generate(system_prompt, user_prompt, model)
    end
  end

  defp do_generate(system_prompt, user_prompt, model) do
    alias ReqLLM.Context, as: C

    context = C.new([C.system(system_prompt), C.user(user_prompt)])

    with {:ok, stream_response} <- ReqLLM.stream_text(model, context),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
         {:ok, script} <- extract_script_from_response(response) do
      {:ok, script}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Extracts and validates script text from the LLM response.
  # Returns {:ok, script} for non-empty text, {:error, :empty_response} otherwise.
  defp extract_script_from_response(response) do
    case ReqLLM.Response.text(response) do
      text when is_binary(text) and text != "" -> {:ok, extract_script(text)}
      _ -> {:error, :empty_response}
    end
  end

  @doc """
  Builds the system prompt describing how worktree init scripts work.

  Made public so the prompt content can be tested without an LLM call.
  """
  @spec build_system_prompt() :: String.t()
  def build_system_prompt do
    """
    You are an expert DevOps engineer. Your task is to generate a **Worktree Init Script**
    that runs immediately after a new git worktree is created, copying dependencies, build
    cache, or build results from a source repository into the new worktree. This avoids
    re-downloading and recompiling everything from scratch, dramatically speeding up builds.

    ## Environment Variables

    The script receives three environment variables:

    - `$SOURCE_REPO_PATH` — The main repository checkout where `genesis.toml` lives.
    - `$SOURCE_WORKTREE_PATH` — The parent agent's worktree path. Equals `$SOURCE_REPO_PATH`
      for top-level agents.
    - `$TARGET_WORKTREE_PATH` — The newly created worktree where files should be copied TO.

    ## Examples by Ecosystem

    - **Elixir**: `cp --reflink=auto -r $SOURCE_REPO_PATH/deps $TARGET_WORKTREE_PATH/`
      (also copy `_build` for compiled artifacts)
    - **Node.js**: `cp --reflink=auto -r $SOURCE_REPO_PATH/node_modules $TARGET_WORKTREE_PATH/`
    - **Python**: `cp --reflink=auto -r $SOURCE_REPO_PATH/.venv $TARGET_WORKTREE_PATH/`
    - **Rust**: `cp --reflink=auto -r $SOURCE_REPO_PATH/target $TARGET_WORKTREE_PATH/`
    - **Go**: `cp --reflink=auto -r $SOURCE_REPO_PATH/vendor $TARGET_WORKTREE_PATH/` (if present)

    ## Guidelines

    - Use `cp --reflink=auto` (Copy-on-Write) for speed and disk efficiency.
    - Only include the copy commands needed for the detected ecosystem.
    - Start the script with a `#!/bin/bash` or `#!/bin/sh` shebang.
    - Keep it simple — just the essential copy commands.
    - If you are unsure about the ecosystem, output a minimal generic script or nothing.

    ## Output Format

    Output ONLY the script content, optionally wrapped in a ```bash or ```sh code fence.
    Do not include any explanation or commentary outside the script.
    """
    |> String.trim()
  end

  @doc """
  Builds the user prompt containing the genesis objective.

  Made public so it can be referenced in tests.
  """
  @spec build_user_prompt(String.t()) :: String.t()
  def build_user_prompt(objective) do
    """
    Generate a worktree init script for a new codebase being created with the following objective:

    #{objective}

    Determine the most likely ecosystem/language from the objective and generate the appropriate
    copy commands. Output only the script.
    """
    |> String.trim()
  end

  @doc """
  Extracts the script content from an LLM response.

  If the response contains a code fence (```bash, ```sh, or plain ```),
  extracts just the code inside. Otherwise returns the trimmed response as-is.

  Made public so the extraction logic can be tested without an LLM call.
  """
  @spec extract_script(String.t()) :: String.t()
  def extract_script(response) when is_binary(response) do
    cond do
      match = Regex.run(~r/```(?:bash|sh)?\s*\n([\s\S]*?)```/m, response) ->
        match |> List.wrap() |> List.last() |> String.trim()

      true ->
        String.trim(response)
    end
  end

  def extract_script(_response), do: ""
end
