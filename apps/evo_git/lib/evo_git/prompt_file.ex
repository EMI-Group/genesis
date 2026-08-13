defmodule EvoGit.PromptFile do
  @moduledoc """
  Reads prompt/objective files for the CLI `-f`/`--file` option.

  Plain text only: any extension (`.txt`, `.md`, ...) is read verbatim and
  trimmed. Files that are not valid UTF-8 plain text — binaries, PDFs, DOCX
  archives — are rejected with `{:error, {:not_text, extension}}` so binary
  garbage is never injected into an LLM objective.

  Error shapes from `read/1`:
    * bare POSIX atom (`:enoent`, `:eacces`, ...) — file read failed
      (propagated from `File.read/1`)
    * `{:not_text, extension}` — the file is not valid UTF-8 plain text
      (e.g. a binary/PDF/DOCX). `extension` is the downcased file extension
      (`".pdf"`, `".docx"`, or `""` when the file has none).

  .docx/.pdf conversion is a FRONTEND feature in the dashboard app
  (`EvoDash.AttachedFile`); it is deliberately not part of the core so the
  `genesis_remote` release stays lean. Core users can bring their own
  read/convert script and pipe the result into `-f`.
  """

  @doc """
  Reads a prompt file.

  Returns `{:ok, text}` or `{:error, reason}`. `reason` is a bare POSIX atom
  (`:enoent`, `:eacces`, ...) propagated from `File.read/1`, or
  `{:not_text, extension}` when the file is not valid UTF-8 plain text.
  """
  def read(path) do
    case read_text(path) do
      {:ok, binary} ->
        if String.valid?(binary) do
          {:ok, String.trim(binary)}
        else
          {:error, {:not_text, extension(path)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds a user-ready error message for a `read/1` error."
  def describe_error(error, path) do
    case error do
      :enoent ->
        "File not found: #{path}"

      :enotdir ->
        "File not found: #{path}"

      {:not_text, ext} ->
        suffix = if ext == "", do: " (binary/PDF/DOCX)", else: " (#{ext})"

        "File is not plain text#{suffix} — the core CLI supports plain text " <>
          "only; convert the file to text first or attach it via the dashboard"

      reason when is_atom(reason) ->
        "Failed to read file: #{path} (#{inspect(reason)})"

      reason ->
        "Failed to read file: #{path} (#{inspect(reason)})"
    end
  end

  ## Plain text

  defp read_text(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension(path) do
    path |> Path.extname() |> String.downcase()
  end
end
