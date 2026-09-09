defmodule EvoGit.AttachmentsTest do
  @moduledoc """
  Unit tests for `EvoGit.Attachments` — the single source of truth for the
  multi-modal `:attachments` task-opt contract (validation + LLM content-part
  materialization).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Attachments
  alias ReqLLM.Message.ContentPart

  @png_raw <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03>>
  @png_b64 Base.encode64(@png_raw)
  @audio_raw <<0xFF, 0xF3, 0x84, 0xC0, 0x00, 0x00, 0x00>>
  @audio_b64 Base.encode64(@audio_raw)

  defp image_attachment(overrides \\ %{}) do
    Map.merge(
      %{"type" => "image", "name" => "diagram.png", "media_type" => "image/png", "data" => @png_b64},
      overrides
    )
  end

  defp audio_attachment(overrides \\ %{}) do
    Map.merge(
      %{"type" => "audio", "name" => "note.mp3", "media_type" => "audio/mpeg", "data" => @audio_b64},
      overrides
    )
  end

  describe "validate/1" do
    test "accepts nil and []" do
      assert Attachments.validate(nil) == :ok
      assert Attachments.validate([]) == :ok
    end

    test "accepts a valid image attachment (string keys)" do
      assert Attachments.validate([image_attachment()]) == :ok
    end

    test "accepts a valid audio attachment" do
      assert Attachments.validate([audio_attachment()]) == :ok
    end

    test "accepts atom-keyed maps (normalization)" do
      atom_keyed = %{
        type: "image",
        name: "diagram.png",
        media_type: "image/png",
        data: @png_b64
      }

      assert Attachments.validate([atom_keyed]) == :ok
    end

    test "accepts a mixed list of image and audio attachments" do
      assert Attachments.validate([image_attachment(), audio_attachment()]) == :ok
    end

    test "rejects non-list values" do
      assert_raise ArgumentError, ~r/expected a list of attachment maps/, fn ->
        Attachments.validate("nope")
      end

      assert_raise ArgumentError, ~r/expected a list of attachment maps/, fn ->
        Attachments.validate(%{"type" => "image"})
      end
    end

    test "rejects more than 4 attachments" do
      five = Enum.map(1..5, fn i -> image_attachment(%{"name" => "img#{i}.png"}) end)

      assert_raise ArgumentError, ~r/at most 4 allowed/, fn ->
        Attachments.validate(five)
      end
    end

    test "rejects an unknown type" do
      assert_raise ArgumentError, ~r/unknown type "video"/, fn ->
        Attachments.validate([image_attachment(%{"type" => "video"})])
      end
    end

    test "rejects a missing or blank name" do
      assert_raise ArgumentError, ~r/missing or blank name/, fn ->
        Attachments.validate([image_attachment(%{"name" => nil})])
      end

      assert_raise ArgumentError, ~r/missing or blank name/, fn ->
        Attachments.validate([image_attachment(%{"name" => "  "})])
      end
    end

    test "rejects a missing or blank media_type" do
      assert_raise ArgumentError, ~r/missing or blank media_type/, fn ->
        Attachments.validate([image_attachment(%{"media_type" => nil})])
      end

      assert_raise ArgumentError, ~r/missing or blank media_type/, fn ->
        Attachments.validate([image_attachment(%{"media_type" => ""})])
      end
    end

    test "rejects data that is not valid base64" do
      assert_raise ArgumentError, ~r/not valid base64/, fn ->
        Attachments.validate([image_attachment(%{"data" => "!!!not-base64!!!"})])
      end
    end

    test "rejects a non-binary data value" do
      assert_raise ArgumentError, ~r/data must be a base64-encoded string/, fn ->
        Attachments.validate([image_attachment(%{"data" => 123})])
      end
    end

    test "rejects oversize data (over the 15 MiB raw cap)" do
      # 15 MiB raw is the cap; 15 MiB + 1 raw byte must be rejected. The
      # base64 of that payload is ~20 MiB.
      oversize_raw = :binary.copy(<<0xAB>>, Attachments.max_bytes() + 1)
      oversize = image_attachment(%{"data" => Base.encode64(oversize_raw)})

      assert_raise ArgumentError, ~r/exceeds the .* raw size limit/, fn ->
        Attachments.validate([oversize])
      end
    end

    test "accepts data exactly at the raw size cap" do
      at_cap_raw = :binary.copy(<<0xAB>>, Attachments.max_bytes())
      at_cap = image_attachment(%{"data" => Base.encode64(at_cap_raw)})
      assert Attachments.validate([at_cap]) == :ok
    end

    test "rejects a non-map entry inside the list" do
      assert_raise ArgumentError, ~r/expected a map/, fn ->
        Attachments.validate(["not-a-map"])
      end
    end
  end

  describe "to_content_parts/2" do
    test "returns just the text part for nil or [] attachments" do
      assert Attachments.to_content_parts("objective", nil) == [ContentPart.text("objective")]
      assert Attachments.to_content_parts("objective", []) == [ContentPart.text("objective")]
    end

    test "materializes an image as ContentPart.image with decoded raw bytes" do
      [text_part, image_part] = Attachments.to_content_parts("text", [image_attachment()])

      assert text_part == ContentPart.text("text")
      assert image_part.type == :image
      assert image_part.data == @png_raw
      assert image_part.media_type == "image/png"
    end

    test "materializes audio as a ContentPart.file (:file part) with decoded raw bytes" do
      [text_part, file_part] = Attachments.to_content_parts("text", [audio_attachment()])

      assert text_part == ContentPart.text("text")
      assert file_part.type == :file
      assert file_part.data == @audio_raw
      assert file_part.filename == "note.mp3"
      assert file_part.media_type == "audio/mpeg"
    end

    test "preserves input order with a leading text part" do
      parts =
        Attachments.to_content_parts("objective", [
          image_attachment(%{"name" => "a.png"}),
          audio_attachment(%{"name" => "b.mp3"}),
          image_attachment(%{"name" => "c.png"})
        ])

      assert [text, a, b, c] = parts
      assert text == ContentPart.text("objective")
      assert a.type == :image and a.data == @png_raw
      assert b.type == :file and b.filename == "b.mp3" and b.data == @audio_raw
      assert c.type == :image and c.data == @png_raw
    end

    test "accepts atom-keyed attachment maps (fetch normalization)" do
      atom_keyed = %{
        type: "image",
        name: "diagram.png",
        media_type: "image/png",
        data: @png_b64
      }

      [text_part, image_part] = Attachments.to_content_parts("t", [atom_keyed])
      assert text_part == ContentPart.text("t")
      assert image_part == ContentPart.image(@png_raw, "image/png")
    end

    test "content parts are ReqLLM.ContentPart.t() values usable by ReqLLM.Context.user/1" do
      parts = Attachments.to_content_parts("objective", [image_attachment()])
      message = ReqLLM.Context.user(parts)

      assert %ReqLLM.Message{role: :user} = message
      assert message.content == parts
    end
  end

  describe "caps" do
    test "module attribute caps are exposed as the single core source" do
      assert Attachments.max_count() == 4
      assert Attachments.max_bytes() == 15 * 1024 * 1024
    end
  end
end
