defmodule Mix.Tasks.LlmDb.Models do
  @shortdoc "List LLM models with optional spec filtering"

  @moduledoc """
  Lists all models from the LLMDB catalog with lifecycle status and aliases.

  ## Usage

      mix llmdb.models              # List all models
      mix llmdb.models "anthropic:*"     # List all Anthropic models
      mix llmdb.models "openai:gpt-4o"   # List specific model
      mix llmdb.models "*:*"             # List all models (explicit)

  ## Model Specs

  Supports glob-style filtering:

  - `provider:*` - All models for a provider (e.g., `"anthropic:*"`)
  - `provider:pattern` - Specific model or pattern (e.g., `"openai:gpt-4*"`)
  - `*:*` - All models across all providers

  Aliases are automatically resolved to canonical model IDs.

  ## Output Format

  Models are grouped by provider with lifecycle indicators:

  - ✓ (green) - Active model
  - ⚠ (yellow) - Deprecated model with retirement date
  - ❌ (red) - Retired model

  Each model shows its canonical ID, aliases (if any), lifecycle status,
  retirement date, and replacement model (if applicable).

  ## Examples

      # List all Anthropic models
      mix llmdb.models "anthropic:*"

      # List all OpenAI GPT-4 models
      mix llmdb.models "openai:gpt-4*"

      # List specific model by alias
      mix llmdb.models "anthropic:claude-3.5-haiku"

      # List all models
      mix llmdb.models
  """

  use Mix.Task
  alias LLMDB.{Model, Provider}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    spec = parse_args(args)
    models = get_models(spec)

    if Enum.empty?(models) do
      Mix.shell().error("No models found matching spec: #{spec || "all"}")
    else
      display_models(models)
    end
  end

  defp parse_args([]), do: nil
  defp parse_args([spec | _]), do: spec

  defp get_models(nil) do
    LLMDB.providers()
    |> Enum.map(fn %Provider{id: provider_id} = provider ->
      {provider, LLMDB.models(provider_id)}
    end)
    |> Enum.reject(fn {_provider, models} -> Enum.empty?(models) end)
  end

  defp get_models(spec) do
    case parse_spec(spec) do
      {:ok, {provider_id, model_pattern}} ->
        filter_by_spec(provider_id, model_pattern)

      {:error, reason} ->
        Mix.shell().error("Invalid spec format: #{reason}")
        []
    end
  end

  defp parse_spec(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, pattern] ->
        provider_atom =
          if provider == "*" do
            :*
          else
            String.to_existing_atom(provider)
          end

        {:ok, {provider_atom, pattern}}

      _ ->
        {:error, "Expected format 'provider:pattern'"}
    end
  rescue
    ArgumentError ->
      {:error, "Unknown provider"}
  end

  defp filter_by_spec(:*, "*"), do: get_models(nil)

  defp filter_by_spec(:*, pattern) do
    LLMDB.providers()
    |> Enum.map(fn %Provider{id: provider_id} = provider ->
      models = filter_models(LLMDB.models(provider_id), pattern)
      {provider, models}
    end)
    |> Enum.reject(fn {_provider, models} -> Enum.empty?(models) end)
  end

  defp filter_by_spec(provider_id, pattern) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} ->
        models = filter_models(LLMDB.models(provider_id), pattern)

        if Enum.empty?(models) do
          []
        else
          [{provider, models}]
        end

      _ ->
        []
    end
  end

  defp filter_models(models, "*"), do: models

  defp filter_models(models, pattern) do
    regex = glob_to_regex(pattern)

    Enum.filter(models, fn %Model{id: id, aliases: aliases} ->
      Regex.match?(regex, id) || Enum.any?(aliases, &Regex.match?(regex, &1))
    end)
  end

  defp glob_to_regex(pattern) do
    pattern
    |> String.replace(".", "\\.")
    |> String.replace("*", ".*")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end

  defp display_models(provider_models) do
    Mix.shell().info("")

    Enum.each(provider_models, fn {provider, models} ->
      display_provider(provider, models)
      Mix.shell().info("")
    end)
  end

  defp display_provider(%Provider{name: name}, models) do
    count = length(models)

    Mix.shell().info(
      IO.ANSI.cyan() <>
        IO.ANSI.bright() <> "#{name} (#{count} models)" <> IO.ANSI.reset()
    )

    models
    |> Enum.sort_by(& &1.id)
    |> Enum.each(&display_model/1)
  end

  defp display_model(%Model{} = model) do
    {indicator, color} = lifecycle_indicator(model)
    lifecycle_info = lifecycle_details(model)

    model_line = "  #{color}#{indicator} #{model.id}#{IO.ANSI.reset()}"
    model_line = if lifecycle_info, do: "#{model_line} #{lifecycle_info}", else: model_line

    Mix.shell().info(model_line)

    if model.aliases && !Enum.empty?(model.aliases) do
      aliases_str = Enum.join(model.aliases, ", ")

      Mix.shell().info(
        "      " <> IO.ANSI.faint() <> "aliases: #{aliases_str}" <> IO.ANSI.reset()
      )
    end

    if model.lifecycle && Map.get(model.lifecycle, :replacement) do
      Mix.shell().info(
        "      " <>
          IO.ANSI.faint() <>
          "replacement: #{model.lifecycle.replacement}" <> IO.ANSI.reset()
      )
    end
  end

  defp lifecycle_indicator(%Model{lifecycle: nil}), do: {"✓", IO.ANSI.green()}
  defp lifecycle_indicator(%Model{lifecycle: %{status: nil}}), do: {"✓", IO.ANSI.green()}
  defp lifecycle_indicator(%Model{lifecycle: %{status: "active"}}), do: {"✓", IO.ANSI.green()}

  defp lifecycle_indicator(%Model{lifecycle: %{status: "deprecated"}}),
    do: {"⚠", IO.ANSI.yellow()}

  defp lifecycle_indicator(%Model{lifecycle: %{status: "retired"}}), do: {"❌", IO.ANSI.red()}

  defp lifecycle_details(%Model{lifecycle: nil}), do: nil
  defp lifecycle_details(%Model{lifecycle: %{status: nil}}), do: nil
  defp lifecycle_details(%Model{lifecycle: %{status: "active"}}), do: nil

  defp lifecycle_details(%Model{lifecycle: %{status: "deprecated", retires_at: retires_at}})
       when is_binary(retires_at) do
    IO.ANSI.faint() <> "(deprecated, retires #{retires_at})" <> IO.ANSI.reset()
  end

  defp lifecycle_details(%Model{lifecycle: %{status: "deprecated"}}) do
    IO.ANSI.faint() <> "(deprecated)" <> IO.ANSI.reset()
  end

  defp lifecycle_details(%Model{lifecycle: %{status: "retired", retires_at: retires_at}})
       when is_binary(retires_at) do
    IO.ANSI.faint() <> "(retired #{retires_at})" <> IO.ANSI.reset()
  end

  defp lifecycle_details(%Model{lifecycle: %{status: "retired"}}) do
    IO.ANSI.faint() <> "(retired)" <> IO.ANSI.reset()
  end
end
