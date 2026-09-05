defmodule EvoGit.CLI.Parser do
  @moduledoc """
  CLI argument parsing helpers.

  Extracted from `EvoGit.CLI` to separate parsing concerns from
  command dispatch.
  """

  @doc """
  Parses CLI arguments via `OptionParser.parse/3`.

  Returns `{opts, argv}` where `opts` is a keyword list of parsed
  options and `argv` is the list of remaining positional arguments.
  """
  @spec parse_args([String.t()]) :: {Keyword.t(), [String.t()]}
  def parse_args(args) do
    {opts, argv, _invalid} = parse_args_full(args)
    {opts, argv}
  end

  @doc """
  Parses CLI arguments, returning `{opts, argv, invalid}`.

  Same as `parse_args/1` but also surfaces OptionParser's third
  element (`invalid`) for callers that need it.
  """
  @spec parse_args_full([String.t()]) ::
          {Keyword.t(), [String.t()], [{String.t(), String.t() | nil}]}
  def parse_args_full(args) do
    OptionParser.parse(args,
      switches: [
        help: :boolean,
        version: :boolean,
        file: :string,
        path: :string,
        model: :string,
        mode: :string,
        foreign_repo: [:string, :keep],
        agent: :string,
        node: :string,
        starting_commit: :string,
        archive: :boolean,
        build_system: :string
      ],
      aliases: [
        h: :help,
        v: :version,
        f: :file,
        p: :path,
        m: :model,
        d: :mode,
        R: :foreign_repo,
        n: :node,
        b: :build_system
      ]
    )
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
  Parses `-R` / `--foreign-repo` CLI flag values into a list of
  `%EvoGit.Core.ForeignRepo{}` structs.

  Supports two formats:
    - `"id:path"` — explicit id and path
    - `"path"` — bare path, uses directory basename as id

  Windows drive-letter absolute paths (`C:\\...`, `D:/...`) are always treated
  as a bare `"path"` — the leading `C:` is NOT interpreted as an id prefix.

  ## Read-only by default

  `-R` foreign repos are **read-only** by default (`writable: false`,
  `base_sha: nil`). There is no CLI flag to mark a repo writable or pin its
  starting commit — the mechanism for that is the `genesis.toml`
  `[foreign_repos.<id>]` keys `writable = true` / `base_sha = "..."`.
  """
  def parse_foreign_repos(opts) do
    case Keyword.get_values(opts, :foreign_repo) do
      [] ->
        []

      values ->
        Enum.map(values, fn spec ->
          case split_foreign_repo_spec(spec) do
            {:bare, path} ->
              # No id specified, use directory basename
              id = path |> Path.basename()
              EvoGit.Core.ForeignRepo.new(id, path)

            {:id, id_str, path} ->
              EvoGit.Core.ForeignRepo.new(id_str, path)
          end
        end)
    end
  end

  # Splits an `-R` spec into `{:id, id, path}` or `{:bare, path}`.
  #
  # `"id:path"` → `{:id, "id", "path"}`; a bare `"path"` → `{:bare, path}`.
  # A Windows drive-letter absolute path (`C:\...`, `D:/...`) is a single path
  # token — the drive letter is never mistaken for an id.
  defp split_foreign_repo_spec(spec) do
    if drive_letter_abs_path?(spec) do
      {:bare, spec}
    else
      case String.split(spec, ":", parts: 2) do
        [path] -> {:bare, path}
        [id_str, path] -> {:id, id_str, path}
      end
    end
  end

  # Matches a Windows drive-letter absolute path prefix (`C:\`, `D:/`, ...).
  defp drive_letter_abs_path?(spec) do
    Regex.match?(~r/^[a-zA-Z]:[\\\/]/, spec)
  end

  @doc false
  def do_parse_foreign_repos(opts), do: parse_foreign_repos(opts)
end
