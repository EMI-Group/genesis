defmodule EvoGit.Attachments do
  @max_count 4
  @max_bytes 15 * 1024 * 1024
  @valid_types ~w(image audio)

  @moduledoc """
  Multi-modal data input for a task's INITIAL objective.

  Attachments (images and audio) are carried in the task data plane as an
  `:attachments` opt — a list of maps with STRING keys:

      %{
        "type" => "image" | "audio",
        "name" => <basename string>,
        "media_type" => <IANA media type, e.g. "image/png" / "audio/mpeg">,
        "data" => <base64-encoded file bytes (ASCII string)>
      }

  Base64 is MANDATORY at the opts layer: `EvoGit.Store.Codec` Jason-encodes
  whole opts, and raw non-UTF-8 binaries abort Jason (the encode fallback
  would silently drop the key). Raw bytes are decoded ONLY at LLM-message
  materialization time (`to_content_parts/2`).

  Caps (single core source): at most `#{@max_count}` attachments per task,
  each at most `#{@max_bytes}` RAW bytes.

  Deliberately NO model-capability checking (no llm_db modality gating, no
  codec-capability gating): if the user attaches data the chosen provider
  cannot handle, the provider erroring is the user's concern.

  ## Materialization contract

  `"image"` attachments become `ReqLLM.Message.ContentPart.image(raw,
  media_type)`; `"audio"` attachments ride as a `:file` part —
  `ContentPart.file(raw, name, media_type)` (per the req_llm survey: audio/*
  has no dedicated part type). The parts are appended to a leading
  `ContentPart.text(...)` of the objective text, in input order, and ride on
  the ROOT agent's first user message only (see
  `EvoGit.Agent.ContextBuilder.build_initial_messages/4`).
  """

  alias ReqLLM.Message.ContentPart

  @type t :: %{optional(String.t() | atom()) => String.t()}

  @doc "Maximum number of attachments allowed per task."
  def max_count, do: @max_count

  @doc "Maximum RAW byte size of a single attachment (before base64 encoding)."
  def max_bytes, do: @max_bytes

  @doc """
  Validates the `:attachments` task-opt value. `nil`/`[]` are valid (no
  attachments). Raises a descriptive `ArgumentError` for any malformed payload
  (spec-error style — NO try/rescue swallowing).

  Both string-keyed and atom-keyed maps are accepted (mirrors the
  `EvoGit.Core.ForeignRepo.normalize/1` idiom for persisted/CLI shapes;
  string keys are tried first). Validates per attachment: known `type`
  (`"image"`/`"audio"`), non-blank `name` and `media_type`, and `data` that is
  base64-parseable and no larger than `#{@max_bytes}` raw bytes.
  """
  @spec validate(term()) :: :ok
  def validate(nil), do: :ok
  def validate([]), do: :ok

  def validate(attachments) when is_list(attachments) do
    count = length(attachments)

    if count > @max_count do
      raise ArgumentError,
            "attachments: too many attachments (#{count}); at most #{@max_count} allowed"
    end

    attachments
    |> Enum.with_index()
    |> Enum.each(fn {attachment, index} -> validate_one(attachment, index) end)

    :ok
  end

  def validate(other) do
    raise ArgumentError,
          "attachments: expected a list of attachment maps, got: #{inspect(other)}"
  end

  @doc """
  Materializes a combined user-message content-part list from the objective
  `text` (a plain `String.t()`, preserved verbatim as the leading text part)
  and the validated `attachments` list. Returns
  `[ContentPart.text(text) | image/file parts…]` — raw bytes, base64-decoded
  via `Base.decode64!/1`, in stable input order. `nil`/`[]` attachments yield
  just the text part. Pure and unit-testable.
  """
  @spec to_content_parts(String.t(), [t()] | nil) :: [ContentPart.t()]
  def to_content_parts(text, attachments) when is_binary(text) do
    parts = Enum.map(attachments || [], &to_content_part/1)
    [ContentPart.text(text) | parts]
  end

  # --- Validation internals ---

  defp validate_one(attachment, index) when is_map(attachment) do
    type = fetch(attachment, :type)

    unless type in @valid_types do
      raise ArgumentError,
            "attachments[#{index}]: unknown type #{inspect(type)}; expected \"image\" or \"audio\""
    end

    name = fetch(attachment, :name)

    unless is_binary(name) and String.trim(name) != "" do
      raise ArgumentError,
            "attachments[#{index}]: missing or blank name (expected the file basename)"
    end

    media_type = fetch(attachment, :media_type)

    unless is_binary(media_type) and String.trim(media_type) != "" do
      raise ArgumentError, "attachments[#{index}]: missing or blank media_type"
    end

    data = fetch(attachment, :data)

    unless is_binary(data) do
      raise ArgumentError,
            "attachments[#{index}]: data must be a base64-encoded string, got: #{inspect(data)}"
    end

    case Base.decode64(data) do
      {:ok, raw} ->
        if byte_size(raw) > @max_bytes do
          raise ArgumentError,
                "attachments[#{index}]: data exceeds the #{@max_bytes}-byte raw size limit"
        end

      :error ->
        raise ArgumentError,
              "attachments[#{index}]: data is not valid base64"
    end

    :ok
  end

  defp validate_one(other, index) do
    raise ArgumentError,
          "attachments[#{index}]: expected a map, got: #{inspect(other)}"
  end

  # --- Materialization internals ---

  defp to_content_part(attachment) do
    type = fetch(attachment, :type)
    name = fetch(attachment, :name)
    media_type = fetch(attachment, :media_type)

    # Input is guaranteed validated by validate/1 (RuntimeOpts enforces it at
    # task start), so decode cannot fail here.
    raw = attachment |> fetch(:data) |> Base.decode64!()

    case type do
      "image" -> ContentPart.image(raw, media_type)
      "audio" -> ContentPart.file(raw, name, media_type)
    end
  end

  # Reads a key from a map that may be string- or atom-keyed (the Codec JSON
  # round-trip and task data-plane maps yield string keys; direct keyword-style
  # construction may use atoms). The string form is tried first, mirroring the
  # EvoGit.Core.ForeignRepo.normalize/1 fetch idiom.
  defp fetch(map, key) do
    Map.get(map, Atom.to_string(key)) || Map.get(map, key)
  end
end
