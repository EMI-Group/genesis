defmodule EvoDashWeb.TaskCardComponents.Errors do
  @moduledoc """
  Guarded readers for a failed task's structured error record
  (`%{kind:, source:, message:, stacktrace:}`) plus the collapsed-card line
  built from it.

  Every read here is TOTAL: legacy failed rows (`error` nil / non-map), all
  non-failed statuses and odd shapes yield nil, so a card without a structured
  error record renders exactly as it did before the record existed.
  """

  import EvoDashWeb.Helpers, only: [task_error_kind_label: 1, truncate_string: 2]

  # Failed tasks persist a structured error record on the decoded TaskInfo
  # `error` field: `%{kind:, source:, message:, stacktrace:}` — ATOM keys after
  # the lenient Store Codec decode (`Codec.decode_error/1`, applied to BOTH the
  # full `%TaskInfo{}` path and the 16-key summary projection); nil unless
  # `status == :failed`. This is a NEW record SEPARATE from the legacy
  # `{:error, _}` task RESULT rendered by render_result/2 — a failed task may
  # carry either, both, or neither. Every read below is guarded and
  # atom/string-key tolerant: legacy failed rows (`error` nil/non-map) and all
  # non-failed statuses return nil, so every render site stays byte-identical
  # to the pre-feature behavior for them.

  # Returns the structured error map only when the task is failed AND the
  # `error` value is a map; nil otherwise (legacy rows, non-failed statuses,
  # bad shapes — summary maps and full structs both safe).
  def task_error(task) do
    with true <- is_map(task),
         true <- Map.get(task, :status) in [:failed, "failed"],
         error when is_map(error) <- Map.get(task, :error) do
      error
    else
      _ -> nil
    end
  end

  # Atom/string-key tolerant read of one error-record field (the Codec emits
  # atom keys, but some consumer paths may hand string-keyed maps).
  def error_field(error, key) do
    Map.get(error, key) || Map.get(error, to_string(key))
  end

  # `message` is a String.t() by contract, but decoded data is untrusted —
  # only non-empty binaries are usable; nil otherwise (graceful fallback).
  def error_message(error) do
    case error_field(error, :message) do
      message when is_binary(message) and message != "" -> message
      _ -> nil
    end
  end

  # `stacktrace` is [String.t()] by contract; defensively keep only binary
  # frames and show the LAST ≤8 (most recent) frames in the expanded block.
  def error_stacktrace(error) do
    case error_field(error, :stacktrace) do
      frames when is_list(frames) ->
        case Enum.filter(frames, &is_binary/1) do
          [] -> nil
          frames -> Enum.take(frames, -8)
        end

      _ ->
        nil
    end
  end

  # Collapsed-line text: the truncated error.message (~160 chars); when the
  # message is not a usable binary, fall back to the kind label so a failed
  # card without a message still communicates why it failed.
  def collapsed_error_text(error) do
    case error_message(error) do
      nil -> task_error_kind_label(error_field(error, :kind))
      message -> truncate_string(message, 160)
    end
  end
end
