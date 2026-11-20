defmodule EvoDashWeb.ConfigIssues do
  @moduledoc """
  Formats the detail lines of the dashboard's "Missing Configuration" banners
  from an `EvoGit.Config.config_status/0` result.

  PURE, total helper: no side effects, no RPC and no gettext — all user-facing
  wording (titles, call-to-action sentences) stays in the two banners.

  The core reports TWO kinds of problem: plain `:warnings` (human-readable
  strings) and schema `:validation_errors` (structs with a `:key_path` and a
  `:message`). A validation error alone is enough to make `ok?: false`, so a
  banner that renders only `:warnings` shows a title, zero detail lines and an
  unfounded accusation that the model is unconfigured.

  Consumers (keep them on this module so the formatting cannot drift): the
  settings page banner in `EvoDashWeb.SettingsLive` and the fixed bottom-right
  banner in `EvoDashWeb.Layouts`.
  """

  @doc """
  Returns the detail lines both banners render: the core's `:warnings` first,
  verbatim and in order, then one line per schema `:validation_errors` entry
  (same order as the core list).

  Total: a status that is not a map, or one missing `:warnings` /
  `:validation_errors`, degrades to the parts it does have (`[]` when none).
  Entries that cannot be formatted are skipped rather than rendered blank.
  """
  @spec lines(term()) :: [String.t()]
  def lines(status) when is_map(status) do
    warnings(status) ++ (status |> validation_errors() |> Enum.flat_map(&format_entry/1))
  end

  def lines(_status), do: []

  @doc """
  Formats ONE schema validation error as a single detail line:
  the dotted `:key_path` and the `:message` joined by `": "`.

  Returns `nil` when the entry yields nothing usable (no path AND no message),
  so callers can skip it instead of emitting an empty line.

  ## Examples

      format_error(%{key_path: [:llm, :providers, 0, :timezone], message: "invalid timezone"})
      #=> "llm.providers.0.timezone: invalid timezone"

      format_error(%{key_path: nil, message: "invalid configuration"})
      #=> "invalid configuration"
  """
  @spec format_error(term()) :: String.t() | nil
  def format_error(entry) when is_map(entry) do
    [path_line(entry), message_line(entry)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ": ")
    end
  end

  def format_error(_entry), do: nil

  @doc """
  Whether the status reports the LLM model itself as MISSING (`:llm_model` in
  `:missing`) — the only case in which a model-specific call to action is
  honest.

  A schema validation error (for example a bad timezone) leaves the model
  configured, so this returns `false` for it.
  """
  @spec model_unconfigured?(term()) :: boolean()
  def model_unconfigured?(status) when is_map(status) do
    case get(status, :missing) do
      missing when is_list(missing) -> Enum.any?(missing, &model_key?/1)
      _missing -> false
    end
  end

  def model_unconfigured?(_status), do: false

  # ── helpers ──────────────────────────────────────────────────────────

  defp model_key?(:llm_model), do: true
  defp model_key?("llm_model"), do: true
  defp model_key?(_other), do: false

  defp warnings(status) do
    status
    |> get(:warnings)
    |> as_list()
    |> Enum.flat_map(&string_line/1)
  end

  defp validation_errors(status) do
    status
    |> get(:validation_errors)
    |> as_list()
  end

  defp format_entry(entry) do
    case format_error(entry) do
      nil -> []
      line -> [line]
    end
  end

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  # Warnings are plain strings; a scalar is stringified, anything unreadable is
  # dropped (never rendered as `inspect/1` noise).
  defp string_line(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      _ -> [value]
    end
  end

  defp string_line(value) when is_atom(value) and not is_nil(value), do: [Atom.to_string(value)]
  defp string_line(value) when is_number(value), do: [to_string(value)]
  defp string_line(_value), do: []

  defp path_line(entry) do
    case get(entry, :key_path) do
      path when is_list(path) ->
        path
        |> Enum.map(&segment/1)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          segments -> Enum.join(segments, ".")
        end

      _path ->
        nil
    end
  end

  defp segment(segment) when is_binary(segment) do
    case String.trim(segment) do
      "" -> nil
      _ -> segment
    end
  end

  defp segment(segment) when is_atom(segment) and not is_nil(segment), do: Atom.to_string(segment)
  defp segment(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp segment(_segment), do: nil

  defp message_line(entry) do
    case get(entry, :message) do
      message when is_binary(message) ->
        case String.trim(message) do
          "" -> nil
          _ -> message
        end

      _message ->
        nil
    end
  end

  # Atom-keyed native statuses and string-keyed wire maps are both accepted; the
  # atom key wins when both are present.
  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp get(_map, _key), do: nil
end
