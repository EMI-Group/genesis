defmodule Mix.Tasks.LlmDb.Version do
  @moduledoc """
  Updates the version in mix.exs to CalVer format (YYYY.M.PATCH).

  - If current version is from a different month, resets to YYYY.M.0
  - If current version is from the same month, increments PATCH

  ## Usage

      mix llm_db.version

  ## Examples

      # Current: 2025.11.5, Today: December 2025
      # Result:  2025.12.0

      # Current: 2025.12.0, Today: December 2025  
      # Result:  2025.12.1
  """

  use Mix.Task

  @shortdoc "Bump version using CalVer (YYYY.M.PATCH)"

  @impl Mix.Task
  def run(_args) do
    mix_exs_path = "mix.exs"
    content = File.read!(mix_exs_path)

    current_version = extract_version(content)
    new_version = compute_next_version(current_version)

    updated = Regex.replace(~r/@version ".*"/, content, "@version \"#{new_version}\"")

    File.write!(mix_exs_path, updated)
    Mix.shell().info("Updated version: #{current_version} → #{new_version}")
  end

  defp extract_version(content) do
    case Regex.run(~r/@version "([^"]+)"/, content) do
      [_, version] -> version
      _ -> "0.0.0"
    end
  end

  defp compute_next_version(current_version) do
    today = Date.utc_today()
    current_year = today.year
    current_month = today.month

    case parse_calver(current_version) do
      {:ok, ^current_year, ^current_month, patch} ->
        # Same month: increment patch
        "#{current_year}.#{current_month}.#{patch + 1}"

      _ ->
        # Different month or invalid: start fresh
        "#{current_year}.#{current_month}.0"
    end
  end

  defp parse_calver(version) do
    # Handle versions like "2025.12.5" or "2025.12.5-preview"
    case Regex.run(~r/^(\d{4})\.(\d{1,2})\.(\d+)/, version) do
      [_, year, month, patch] ->
        {:ok, String.to_integer(year), String.to_integer(month), String.to_integer(patch)}

      _ ->
        :error
    end
  end
end
