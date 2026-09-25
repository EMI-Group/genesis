defmodule EvoGit.Agent.ToolOutput do
  @moduledoc """
  Structured tool output: plain text plus optional multimodal attachments.

  A tool result has historically been a plain `String.t()` threaded through
  `EvoGit.Agent.ToolDispatch`. `%ToolOutput{}` is the structured superset that
  lets a tool result ALSO carry images/audio as real LLM content parts, WITHOUT
  changing the byte-identity of the all-text path.

  ## The all-text invariant

  An all-text output materializes IDENTICALLY to today's binary path:

      EvoGit.Agent.ToolOutput.wrap("x") |> EvoGit.Agent.ToolOutput.to_content_parts()
      #=> [ReqLLM.Message.ContentPart.text("x")]
  `wrap/1` of a binary yields `attachments: nil`, and `to_content_parts/1`
  then delegates to `EvoGit.Attachments.to_content_parts/2` with nil
  attachments, which returns exactly one leading text part. `nil` attachments
  and `[]` attachments are equivalent (no media).

  ## Wrap boundary invariant (pinned)

  `EvoGit.Agent.OutputSanitizer`, `EvoGit.Agent.TruncationFeedback` and
  `EvoGit.Agent.DelegationHints` keep their BINARY-ONLY contract
  (`sanitize_and_truncate/3`, `append_truncation_feedback/3` and
  `maybe_append_delegation_hint/4` all take a string and return a string). The
  wrap/unwrap between a binary and a `%ToolOutput{}` happens ONLY inside
  `EvoGit.Agent.ToolDispatch`: a tool's raw return value is wrapped (`wrap/1`),
  its media is preserved across sanitization (`with_text/2` after sanitizing
  `text/1`), and it is materialized exactly once at the message-construction
  site (`to_content_parts/1`). No sanitizer ever sees or returns a
  `%ToolOutput{}`.

  ## Pinned decisions

  FROZEN contract decisions later phases must not re-litigate:

    * (a) Media stay the base64 STRING maps defined by `EvoGit.Attachments` —
      raw non-UTF-8 bytes never ride the struct, so a `%ToolOutput{}` can cross
      node/`:erpc` and `EvoGit.Store.Codec` boundaries.
    * (b) Materialization produces a plain content-part LIST
      (`[ReqLLM.Message.ContentPart.t()]`) — NEVER a `ReqLLM.ToolResult` (that
      struct stamps extra metadata and would break byte-identity).
    * (c) The `:attachments` TASK-OPT root-only gate is unchanged; the
      generalized capability enters through tool results (this struct) and
      injected user messages.
    * (d) The `EvoGit.Attachments` caps (at most 4 attachments, at most 15 MiB
      raw each) apply PER TOOL OUTPUT — `new/2` enforces them at construction.

  ## Accessors

  `new/2`, `wrap/1`, `text/1`, `with_text/2`, `media?/1` and
  `to_content_parts/1` are the ONLY sanctioned accessors the pipeline may use.
  """

  alias EvoGit.Attachments
  alias ReqLLM.Message.ContentPart

  @enforce_keys [:text]
  defstruct [:text, attachments: nil]

  @type t :: %__MODULE__{
          text: String.t(),
          attachments: [Attachments.t()] | nil
        }

  @doc """
  Builds a `%ToolOutput{}` from `text` and `attachments`, validating the media
  via `EvoGit.Attachments.validate/1` at CONSTRUCTION time — so the caps (at
  most 4 attachments, at most 15 MiB raw each) are enforced at construction and
  propagate a descriptive `ArgumentError` (spec-error style, no swallowing).

  `attachments` are stored verbatim; `nil` and `[]` both mean "no media".
  """
  @spec new(String.t(), [Attachments.t()] | nil) :: t()
  def new(text, attachments) when is_binary(text) do
    :ok = Attachments.validate(attachments)
    %__MODULE__{text: text, attachments: attachments}
  end

  @doc """
  Coerces a tool's raw return value into a `%ToolOutput{}`:

    * a binary `bin` → `%ToolOutput{text: bin, attachments: nil}` (the exact
      legacy all-text shape)
    * a `%ToolOutput{}` → itself (idempotent)
    * `nil` → `nil` (a tool that legitimately returns nothing stays nothing;
      callers decide how to render it)
  """
  @spec wrap(t() | String.t() | nil) :: t() | nil
  def wrap(nil), do: nil
  def wrap(%__MODULE__{} = output), do: output
  def wrap(bin) when is_binary(bin), do: %__MODULE__{text: bin, attachments: nil}

  @doc "Returns the text component of the output."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{text: text}), do: text

  @doc """
  Returns a `%ToolOutput{}` with the text REPLACED and the media PRESERVED —
  the seam used after sanitize/truncate (which stay binary-only and therefore
  only ever see `text/1`).
  """
  @spec with_text(t(), String.t()) :: t()
  def with_text(%__MODULE__{} = output, text) when is_binary(text) do
    %{output | text: text}
  end

  @doc "Returns `true` when the output carries attachments (media)."
  @spec media?(t()) :: boolean()
  def media?(%__MODULE__{attachments: attachments}),
    do: is_list(attachments) and attachments != []

  @doc """
  Materializes the output as a plain LLM content-part list via
  `EvoGit.Attachments.to_content_parts/2` —
  `[ContentPart.text(text) | image/file parts…]`. An all-text output yields
  exactly `[ContentPart.text(text)]`, byte-identical to the legacy binary path.
  """
  @spec to_content_parts(t()) :: [ContentPart.t()]
  def to_content_parts(%__MODULE__{text: text, attachments: attachments}),
    do: Attachments.to_content_parts(text, attachments)
end
