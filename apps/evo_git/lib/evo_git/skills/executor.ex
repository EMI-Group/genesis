defmodule EvoGit.Skills.Executor do
  @moduledoc """
  Skill execution — finds a skill by name, extracts bash blocks, substitutes
  parameters, and runs the script.
  """

  alias EvoGit.Skills

  # ---------------------------------------------------------------------------
  # Skill Execution
  # ---------------------------------------------------------------------------

  @doc """
  Executes a skill with the given arguments.

  1. Finds the skill in the loaded list
  2. Extracts the bash code block from the skill body
  3. Substitutes `{{param}}` placeholders with positional references
  4. Executes the script via bash (sandboxed on Linux/macOS)
  5. Returns stdout/stderr

  If no bash code block is found, returns the skill body as a text result
  (the agent can use it as instructions).
  """
  @spec execute([EvoGit.Skills.Skill.t()], String.t(), map(), String.t()) :: String.t()
  def execute(skills, skill_name, args, repo_path) do
    case Skills.find_skill(skills, skill_name) do
      nil ->
        "Error: Skill '#{skill_name}' not found. Available skills: #{inspect(Skills.skill_names(skills))}"

      skill ->
        execute_skill(skill, args, repo_path)
    end
  end

  @doc """
  Executes a loaded skill: extracts the bash block, substitutes parameters,
  and runs the resulting script.

  Parameter substitution uses the injection-safe positional scheme
  (`build_positional_script/3`): values are passed to bash as positional
  argv (`$1..$N`) and NEVER inlined into the script text.
  """
  def execute_skill(%EvoGit.Skills.Skill{body: body, parameters: params}, args, repo_path) do
    case extract_bash_block(body) do
      nil ->
        # No bash block — return the body text as instructions
        "Skill '#{skill_name(args)}' instructions:\n\n#{body}"

      script ->
        {script_with_refs, values} = build_positional_script(script, params, args)
        run_script(script_with_refs, values, repo_path)
    end
  end

  # Placeholder, not used
  @doc """
  Placeholder for extracting a skill name from arguments.
  Currently returns an empty string.
  """
  def skill_name(_args), do: ""

  @doc """
  Extracts the first ```bash code block from markdown content.
  Returns nil if no bash block is found.
  """
  def extract_bash_block(markdown) do
    case Regex.run(~r/```bash\s*\n(.*?)```/s, markdown) do
      [_, code] -> String.trim(code)
      nil -> nil
    end
  end

  @doc """
  Substitutes `{{param_name}}` placeholders in a script with actual argument values.

  ⚠️ **NOT SAFE for direct shell execution.** Values are inlined verbatim into
  the script text (raw `String.replace`), so LLM-controlled argument values
  containing shell metacharacters (`;`, backticks, `$(...)`, quotes, etc.)
  would execute. The runtime execution path does NOT use this function — see
  `build_positional_script/3` for the injection-safe scheme used by
  `execute_skill/3`. This function is kept byte-for-byte for API and test
  compatibility.

  Missing parameters are replaced with empty strings.
  """
  def substitute_params(script, parameters, args) do
    Enum.reduce(parameters, script, fn param, acc ->
      value = get_param_value(param, args)
      String.replace(acc, "{{#{param.name}}}", value)
    end)
  end

  @doc """
  Builds a positional-parameter version of the script — the injection-safe
  substitution scheme used by the runtime execution path.

  Each `{{param}}` placeholder is replaced with a double-quoted positional
  reference (`"$N"`, where N is the 1-indexed position of the parameter in
  `parameters` list order). The resolved values are returned separately as
  `values`, to be passed as argv (`$1..$N`) to bash. Values NEVER enter the
  script text, so no metacharacter in a value can execute.

  ## Returns

  `{script_with_refs, values}`:

  - `script_with_refs` — the script with every `{{param}}` occurrence replaced
    by `"$N"`. Bare tokens (`DEBUG={{debug}}` → `DEBUG="$1"`), placeholders
    inside double quotes (`echo "{{name}}"` → `echo ""$1""`), and partial-token
    concatenation all resolve correctly.
  - `values` — the resolved values in the same order as `parameters`, reusing
    `get_param_value/2` fallbacks (provided arg → default → empty string).

  ## Caveat

  A placeholder inside SINGLE quotes (`'{{name}}'`) now renders literally
  (the single-quoted string contains `"$N"` verbatim, not the value) — only
  bare and double-quoted contexts are supported.
  """
  @spec build_positional_script(String.t(), [map()], map()) :: {String.t(), [String.t()]}
  def build_positional_script(script, parameters, args) do
    {script_with_refs, _} =
      Enum.reduce(parameters, {script, 1}, fn param, {acc, i} ->
        {String.replace(acc, "{{#{param.name}}}", ~s("$#{i}")), i + 1}
      end)

    {script_with_refs, Enum.map(parameters, &get_param_value(&1, args))}
  end

  @doc """
  Retrieves the value for a parameter from the args map.
  Falls back to the parameter's default, or an empty string.
  """
  def get_param_value(param, args) do
    case Map.fetch(args, param.name) do
      {:ok, value} ->
        to_string(value)

      :error ->
        if Map.has_key?(param, :default) do
          to_string(param.default)
        else
          ""
        end
    end
  end

  @doc """
  Runs a bash script in the given repo path.

  Writes the script to a temporary file, makes it executable, executes it,
  and returns the output. The temporary file is cleaned up afterwards.

  The script file is written under `EvoGit.Sandbox.resolve_tmpdir/0` — a
  directory the sandbox profiles actually grant write access to (Linux
  systemd-run `ReadWritePaths`, macOS sandbox-exec tmp rules). Execution goes
  through `EvoGit.sandbox_run/4` (systemd-run on Linux, sandbox-exec on macOS),
  with the parameter values passed as positional argv (`$1..$N`) — they are
  never inlined into the script text.

  On Windows, bash may be available if Git for Windows is installed; the chmod
  step is skipped (Windows does not need/honor it) and the command runs
  directly via `System.cmd` (no sandbox on Windows; argv-style execution is
  injection-safe). If bash is not found on Windows, a clear error message is
  returned.
  """
  def run_script(script, values, repo_path) do
    if EvoGit.Platform.windows?() do
      run_script_windows(script, values, repo_path)
    else
      run_script_unix(script, values, repo_path)
    end
  end

  defp run_script_unix(script, values, repo_path) do
    tmp_file =
      Path.join(EvoGit.Sandbox.resolve_tmpdir(), "evogit_skill_#{System.unique_integer()}.sh")

    result =
      with :ok <- File.write(tmp_file, script),
           :ok <- File.chmod(tmp_file, 0o755) do
        # Values arrive as positional params through the sandbox's own
        # per-arg shell-escaping wrapper — injection-safe.
        case EvoGit.sandbox_run(repo_path, "bash", [tmp_file | values], nil) do
          {output, 0} ->
            "Skill executed successfully:\n#{String.trim(output)}"

          {output, exit_code} ->
            "Skill failed with exit code #{exit_code}:\n#{String.trim(output)}"
        end
      else
        {:error, reason} ->
          "Error setting up skill script at #{tmp_file}: #{:file.format_error(reason)}"
      end

    File.rm(tmp_file)
    result
  end

  defp run_script_windows(script, values, repo_path) do
    case System.find_executable("bash") do
      nil ->
        "Error: This skill uses a bash script, but bash is not available on this Windows installation. Install Git for Windows to enable bash skill execution."

      bash_path ->
        # Git for Windows ships bash — skip chmod (Windows does not need/honor it).
        tmp_file = Path.join(System.tmp_dir!(), "evogit_skill_#{System.unique_integer()}.sh")

        result =
          with :ok <- File.write(tmp_file, script) do
            # System.cmd with an arg list does NOT go through a shell, so values
            # as separate argv entries are injection-safe.
            case System.cmd(bash_path, [tmp_file | values],
                   cd: repo_path,
                   stderr_to_stdout: true,
                   parallelism: false
                 ) do
              {output, 0} ->
                "Skill executed successfully:\n#{String.trim(output)}"

              {output, exit_code} ->
                "Skill failed with exit code #{exit_code}:\n#{String.trim(output)}"
            end
          else
            {:error, reason} ->
              "Error setting up skill script at #{tmp_file}: #{:file.format_error(reason)}"
          end

        File.rm(tmp_file)
        result
    end
  end
end
