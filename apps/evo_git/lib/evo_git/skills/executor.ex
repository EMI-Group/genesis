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
  3. Substitutes `{{param}}` placeholders with actual values
  4. Executes the script via bash
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
  """
  def execute_skill(%EvoGit.Skills.Skill{body: body, parameters: params}, args, repo_path) do
    case extract_bash_block(body) do
      nil ->
        # No bash block — return the body text as instructions
        "Skill '#{skill_name(args)}' instructions:\n\n#{body}"

      script ->
        substituted = substitute_params(script, params, args)
        run_script(substituted, repo_path)
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

  Missing parameters are replaced with empty strings.
  """
  def substitute_params(script, parameters, args) do
    Enum.reduce(parameters, script, fn param, acc ->
      value = get_param_value(param, args)
      String.replace(acc, "{{#{param.name}}}", value)
    end)
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
  """
  def run_script(script, repo_path) do
    tmp_file = Path.join(System.tmp_dir!(), "evogit_skill_#{System.unique_integer()}.sh")

    result =
      with :ok <- File.write(tmp_file, script),
           :ok <- File.chmod(tmp_file, 0o755) do
        case System.cmd("bash", [tmp_file],
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
