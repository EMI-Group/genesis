defmodule EvoGit.Agent.ToolOutputTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.ToolOutput
  alias EvoGit.Attachments
  alias ReqLLM.Message.ContentPart

  @png_raw <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03>>
  @png_b64 Base.encode64(@png_raw)
  @audio_raw <<0xFF, 0xF3, 0x84, 0xC0, 0x00, 0x00, 0x00>>
  @audio_b64 Base.encode64(@audio_raw)

  defp image_attachment(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "image",
        "name" => "diagram.png",
        "media_type" => "image/png",
        "data" => @png_b64
      },
      overrides
    )
  end

  defp audio_attachment(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "audio",
        "name" => "note.mp3",
        "media_type" => "audio/mpeg",
        "data" => @audio_b64
      },
      overrides
    )
  end

  describe "new/2" do
    test "builds a struct with text and nil attachments" do
      assert ToolOutput.new("plain", nil) == %ToolOutput{text: "plain", attachments: nil}
    end

    test "builds a struct carrying attachments verbatim" do
      attachment = image_attachment()

      assert ToolOutput.new("see this", [attachment]) == %ToolOutput{
               text: "see this",
               attachments: [attachment]
             }
    end

    test "accepts an empty attachment list (equivalent to no media)" do
      output = ToolOutput.new("plain", [])
      assert output == %ToolOutput{text: "plain", attachments: []}
      refute ToolOutput.media?(output)
    end

    test "enforces the raw-size cap at construction (oversized attachment)" do
      oversize_raw = :binary.copy(<<0xAB>>, Attachments.max_bytes() + 1)
      oversize = image_attachment(%{"data" => Base.encode64(oversize_raw)})

      assert_raise ArgumentError, ~r/exceeds the .* raw size limit/, fn ->
        ToolOutput.new("too big", [oversize])
      end
    end

    test "enforces the count cap at construction" do
      too_many = Enum.map(1..5, fn i -> image_attachment(%{"name" => "img#{i}.png"}) end)

      assert_raise ArgumentError, ~r/at most 4 allowed/, fn ->
        ToolOutput.new("too many", too_many)
      end
    end

    test "enforces attachment validity at construction" do
      assert_raise ArgumentError, ~r/unknown type "video"/, fn ->
        ToolOutput.new("nope", [image_attachment(%{"type" => "video"})])
      end

      assert_raise ArgumentError, ~r/expected a list of attachment maps/, fn ->
        ToolOutput.new("nope", "not-a-list")
      end
    end

    test "accepts media exactly at the raw size cap" do
      at_cap_raw = :binary.copy(<<0xAB>>, Attachments.max_bytes())
      at_cap = image_attachment(%{"data" => Base.encode64(at_cap_raw)})
      assert %ToolOutput{} = ToolOutput.new("at cap", [at_cap])
    end
  end

  describe "wrap/1" do
    test "wraps a binary into the legacy all-text shape" do
      assert ToolOutput.wrap("tool says hi") == %ToolOutput{
               text: "tool says hi",
               attachments: nil
             }
    end

    test "wraps an empty binary" do
      assert ToolOutput.wrap("") == %ToolOutput{text: "", attachments: nil}
    end

    test "returns a %ToolOutput{} unchanged (idempotent)" do
      output = ToolOutput.new("see this", [image_attachment()])
      assert ToolOutput.wrap(output) == output
      assert ToolOutput.wrap(ToolOutput.wrap(output)) == output
    end

    test "is idempotent for a wrapped binary too" do
      wrapped = ToolOutput.wrap("x")
      assert ToolOutput.wrap(wrapped) == wrapped
    end

    test "returns nil for nil" do
      assert ToolOutput.wrap(nil) == nil
    end
  end

  describe "text/1 and with_text/2" do
    test "text/1 returns the text component" do
      assert ToolOutput.text(ToolOutput.new("hello", nil)) == "hello"
      assert ToolOutput.text(ToolOutput.wrap("hello")) == "hello"
    end

    test "with_text/2 replaces the text and preserves the media" do
      attachment = image_attachment()
      output = ToolOutput.new("original", [attachment])
      updated = ToolOutput.with_text(output, "sanitized+truncated")

      assert ToolOutput.text(updated) == "sanitized+truncated"
      assert updated.attachments == [attachment]
      assert ToolOutput.media?(updated)
      assert ToolOutput.text(output) == "original"
    end

    test "with_text/2 on an all-text output keeps it media-free" do
      updated = ToolOutput.wrap("original") |> ToolOutput.with_text("replaced")
      assert updated == %ToolOutput{text: "replaced", attachments: nil}
      refute ToolOutput.media?(updated)
    end
  end

  describe "media?/1" do
    test "is false for nil and [] attachments" do
      refute ToolOutput.media?(ToolOutput.new("x", nil))
      refute ToolOutput.media?(ToolOutput.new("x", []))
      refute ToolOutput.media?(ToolOutput.wrap("x"))
    end

    test "is true when attachments are present" do
      assert ToolOutput.media?(ToolOutput.new("x", [image_attachment()]))
      assert ToolOutput.media?(ToolOutput.new("x", [audio_attachment()]))
    end
  end

  describe "to_content_parts/1" do
    test "an ALL-TEXT output materializes byte-identically to the legacy binary path" do
      assert ToolOutput.wrap("x") |> ToolOutput.to_content_parts() == [ContentPart.text("x")]
    end

    test "an all-text output built via new/2 also materializes to a single text part" do
      assert ToolOutput.new("x", nil) |> ToolOutput.to_content_parts() == [ContentPart.text("x")]
      assert ToolOutput.new("x", []) |> ToolOutput.to_content_parts() == [ContentPart.text("x")]
    end

    test "materializes an image after the leading text part" do
      [text_part, image_part] =
        ToolOutput.new("look", [image_attachment()]) |> ToolOutput.to_content_parts()

      assert text_part == ContentPart.text("look")
      assert image_part.type == :image
      assert image_part.data == @png_raw
      assert image_part.media_type == "image/png"
    end

    test "materializes audio as a ContentPart.file part" do
      [text_part, file_part] =
        ToolOutput.new("listen", [audio_attachment()]) |> ToolOutput.to_content_parts()

      assert text_part == ContentPart.text("listen")
      assert file_part.type == :file
      assert file_part.data == @audio_raw
      assert file_part.filename == "note.mp3"
      assert file_part.media_type == "audio/mpeg"
    end

    test "preserves input order with a leading text part" do
      output =
        ToolOutput.new("mixed", [
          image_attachment(%{"name" => "a.png"}),
          audio_attachment(%{"name" => "b.mp3"})
        ])

      assert [text, a, b] = ToolOutput.to_content_parts(output)
      assert text == ContentPart.text("mixed")
      assert a.type == :image
      assert b.type == :file and b.filename == "b.mp3"
    end
  end
end
