defmodule EvoGit.CLI.Parser do
  @moduledoc """
  CLI argument parsing and scheduler configuration helpers.

  Extracted from `EvoGit.CLI` to separate parsing concerns from
  command dispatch.
  """
  require Logger

  @doc """
  Parses CLI arguments via `OptionParser.parse/3`.

  Returns `{opts, argv}` where `opts` is a keyword list of parsed
  options and `argv` is the list of remaining positional arguments.
  """
  @spec parse_args([String.t()]) :: {Keyword.t(), [String.t()]}
  def parse_args(args) do
    {opts, argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          version: :boolean,
          file: :string,
          concurrency: :integer,
          tool_concurrency: :integer,
          retries: :integer,
          max_turns: :integer,
          max_turns_root: :integer,
          path: :string,
          model: :string,
          mode: :string,
          foreign_repo: [:string, :keep],
          node: :string,
          starting_commit: :string,
          archive: :boolean,
          build_system: :string
        ],
        aliases: [
          h: :help,
          v: :version,
          f: :file,
          c: :concurrency,
          r: :retries,
          t: :max_turns,
          p: :path,
          m: :model,
          d: :mode,
          R: :foreign_repo,
          n: :node,
          b: :build_system
        ]
      )

    {opts, argv}
  end

  @doc """
  Applies CLI option overrides to the running AgentScheduler config.

  Called from `EvoGit.CLI.main/1` before command dispatch so that
  concurrency, retry, turn-limit, and model overrides take effect
  for the duration of the session.
  """
  def configure_scheduler(opts) do
    scheduler_opts =
      []
      |> maybe_put(:max_concurrency, opts[:concurrency])
      |> maybe_put(:max_tool_concurrency, opts[:tool_concurrency])
      |> maybe_put(:max_retries, opts[:retries])
      |> maybe_put(:max_turns, opts[:max_turns])
      |> maybe_put(:max_turns_root, opts[:max_turns_root])
      |> maybe_put_model_override(opts[:model])

    if scheduler_opts != [] do
      Logger.info("Applying session-level config overrides: #{inspect(scheduler_opts)}")
      EvoGit.AgentScheduler.update_config(scheduler_opts)
    end
  end

  # Parses the -m/--model CLI flag value into scheduler override opts.
  #
  # The flag accepts two formats:
  #   1. A bare model string (e.g., "anthropic:claude-sonnet-4-20250514")
  #      → overrides the default profile's model. Passes `{:llm_model, model}`
  #      to update_config (backward-compatible).
  #   2. An "id:model" prefixed string (e.g., "fast:anthropic:claude-haiku")
  #      → targets a specific profile by id. Currently only the default
  #      profile's model is live in AgentScheduler, so the id prefix is
  #      passed as `:model_id` for the runtime to bind to a specific profile.
  defp maybe_put_model_override(keyword, nil), do: keyword

  defp maybe_put_model_override(keyword, model_flag) do
    {model_id, model_string} = parse_model_flag(model_flag)

    keyword
    |> maybe_put(:llm_model, model_string)
    |> maybe_put(:model_id, model_id)
  end

  # Parses the -m flag value into {model_id :: String.t() | nil, model_string :: String.t()}.
  #
  # "id:provider:model" → {"id", "provider:model"} (two colons = id prefix present)
  # "provider:model"     → {nil, "provider:model"} (one colon = bare model string)
  # A bare string with no colon is treated as a model string with nil id.
  @spec parse_model_flag(String.t()) :: {String.t() | nil, String.t()}
  def parse_model_flag(value) when is_binary(value) do
    parts = String.split(value, ":", parts: 3)

    case parts do
      # Three parts: "id:provider:model"
      [id, provider, model] when id != "" and provider != "" and model != "" ->
        {id, "#{provider}:#{model}"}

      # Everything else is treated as a bare model string (no id prefix)
      _ ->
        {nil, value}
    end
  end

  @doc false
  # Public test wrapper for parse_model_flag/1
  def do_parse_model_flag(value), do: parse_model_flag(value)

  @doc """
  Conditionally puts a key/value pair into a keyword list.

  When `val` is `nil`, the keyword list is returned unchanged.
  """
  def maybe_put(keyword, _key, nil), do: keyword
  def maybe_put(keyword, key, val), do: Keyword.put(keyword, key, val)

  @doc """
  Passes model_id into runtime_opts when -m uses "id:provider:model" syntax.

  A bare model string (no id prefix) passes model_id as nil — the default
  profile (already overridden via update_config) is used.
  """
  def maybe_put_model_id(keyword, nil), do: keyword

  def maybe_put_model_id(keyword, model_flag) do
    {model_id, _model_string} = parse_model_flag(model_flag)
    maybe_put(keyword, :model_id, model_id)
  end

  @doc """
  Parses `-R` / `--foreign-repo` CLI flag values into a list of
  `%EvoGit.Core.ForeignRepo{}` structs.

  Supports two formats:
    - `"id:path"` — explicit id and path
    - `"path"` — bare path, uses directory basename as id
  """
  def parse_foreign_repos(opts) do
    case Keyword.get_values(opts, :foreign_repo) do
      [] ->
        []

      values ->
        Enum.map(values, fn spec ->
          case String.split(spec, ":", parts: 2) do
            [path] ->
              # No id specified, use directory basename
              id = path |> Path.basename()
              EvoGit.Core.ForeignRepo.new(id, path)

            [id_str, path] ->
              EvoGit.Core.ForeignRepo.new(id_str, path)
          end
        end)
    end
  end

  @doc false
  def do_parse_foreign_repos(opts), do: parse_foreign_repos(opts)
end
