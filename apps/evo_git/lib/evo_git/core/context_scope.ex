defmodule EvoGit.Core.ContextScope do
  @moduledoc """
  Two-scope `CONTEXT.md` support: **Shared** versus **Local** text.

  ## The two scopes

  A `CONTEXT.md` file may carry ONE divider line, the literal
  `<!-- genesis:local -->`, which splits the file into two independent scopes:

    * **Shared** — everything BEFORE the divider line. It applies to the node
      that owns the file AND to all of its descendants, so it is what a deep
      agent inherits from an ancestor directory.
    * **Local** — everything AFTER the divider line. It applies ONLY to agents
      ASSIGNED to that exact directory; it is never inherited downwards.

  The divider line itself is never content: it belongs to neither scope and is
  never rendered. Headings and the document layout stay free-form — the divider
  is the only structural requirement.

  A file WITHOUT a divider is entirely Shared (its Local scope is empty), and a
  file whose first content is the divider has an empty Shared scope. Leading and
  trailing whitespace on the divider line is tolerated.

  ## First occurrence wins

  Only the FIRST divider line in a file splits it. A second occurrence is
  ordinary text belonging to the Local scope, exactly as written.

  ## No fence awareness

  There is deliberately NO Markdown fence awareness: a divider line written
  inside a fenced code block still splits the file. A `CONTEXT.md` that needs to
  SHOW the divider as documentation must alter the literal itself (break it
  across lines, or write it with a different spelling) — indenting does NOT
  help, because a whitespace-padded divider line still counts.

  ## Purity and ordering

  This module is PURE — no file or system I/O, no configuration reads — so it is
  safe to call from anywhere and trivial to test in isolation.

  Scope selection must happen on the RAW file content, BEFORE YAML front-matter
  stripping (`EvoGit.Skills.strip_front_matter/1`) and BEFORE size truncation:
  front matter therefore lives in the Shared part, and truncation applies to
  whichever scope was actually selected.

  Prompt rendering uses exactly that order: the VCT global stage and every
  ancestor stage are rendered `:shared` while the assigned node is rendered
  `:all` (`EvoGit.Core.ContextNode.build_context/2`). The user-facing design
  record is `docs/context-scopes.md`.
  """

  @marker "<!-- genesis:local -->"

  # ONE line-anchored matcher for the divider line:
  #   * `^` under the `m` (multiline) modifier anchors at a LINE start, so only
  #     a whole line can be a divider;
  #   * `[ \t]*` on both sides tolerates indentation and trailing whitespace;
  #   * `\r?\n?` swallows the line ending (LF, CRLF, or none at end of file) so
  #     the divider line — with its exact ending — never leaks into a scope.
  # Compiled once at compile time and always run with `return: :index`, so the
  # scopes are exact BYTE slices of the original binary (never a split on "\n"
  # followed by a re-join, which would mutate or drop line endings).
  @divider ~r/^[ \t]*<!-- genesis:local -->[ \t]*\r?\n?/m

  @scope_error_message ~s(invalid scope: expected one of "shared", "local" or "all")

  @typedoc "The three selectable regions of a `CONTEXT.md` file."
  @type scope :: :shared | :local | :all

  @doc """
  Returns the literal divider line that separates the Shared and Local scopes.

  A matching LINE (leading/trailing whitespace tolerated) in a `CONTEXT.md` file
  is the one structural requirement of this module.
  """
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Splits RAW `CONTEXT.md` content into its `:shared` and `:local` scopes.

  The divider LINE is excluded from both values and the line endings of the
  surrounding text are preserved byte-for-byte, so a CRLF file round-trips
  exactly. A content without a divider is `%{shared: content, local: ""}`.

  No YAML front-matter stripping is performed here: front matter stays part of
  the Shared scope.
  """
  @spec split(String.t()) :: %{shared: String.t(), local: String.t()}
  def split(content) when is_binary(content) do
    case regions(content) do
      {:ok, shared, _divider, local} -> %{shared: shared, local: local}
      :none -> %{shared: content, local: ""}
    end
  end

  @doc """
  Returns the text of `scope` with the divider line excluded.

  `:all` is `shared <> local`, i.e. the original content minus the divider line,
  and is BYTE-IDENTICAL to the input when there is no divider. `:shared` and
  `:local` return just their own region: with no divider the whole file is the
  Shared scope and the Local scope is EMPTY, so `:shared` is the input while
  `:local` is `""`.
  """
  @spec scope_content(String.t(), scope()) :: String.t()
  def scope_content(content, scope)
      when is_binary(content) and scope in [:shared, :local, :all] do
    case regions(content) do
      {:ok, shared, _divider, local} -> select(shared, local, scope)
      # No divider: everything is Shared, nothing is Local (see `split/1`).
      :none -> select(content, "", scope)
    end
  end

  @doc """
  Rebuilds the FULL content with the selected region replaced by `new_region`.

  The divider line and the OTHER region survive byte-for-byte: the divider line
  is re-emitted from the original match, including its exact line ending (LF,
  CRLF, or no ending at end of file). `:all` therefore replaces the whole text
  and drops nothing, because the divider is never content.

  With NO divider, `:all` and `:shared` replace the entire file (the file IS the
  Shared scope) while `:local` returns the content UNCHANGED — there is no Local
  region to replace, so callers must guard with `has_local?/1` first.
  """
  @spec splice(String.t(), scope(), String.t()) :: String.t()
  def splice(content, scope, new_region)
      when is_binary(content) and is_binary(new_region) and scope in [:shared, :local, :all] do
    case regions(content) do
      {:ok, shared, divider, local} ->
        case scope do
          :shared -> new_region <> divider <> local
          :local -> shared <> divider <> new_region
          :all -> new_region
        end

      :none ->
        case scope do
          :local -> content
          _ -> new_region
        end
    end
  end

  @doc """
  Returns `true` when a divider line is present (i.e. the file has a Local scope).
  """
  @spec has_local?(String.t()) :: boolean()
  def has_local?(content) when is_binary(content), do: locate(content) != :none

  @doc """
  Normalizes an UNTRUSTED scope argument (`"shared"`, `"local"`, `"all"`, or the
  matching atom) into a `scope/0`.

  Never raises: anything else answers `{:error, message}`, where the message
  names all three accepted values so a caller can surface it verbatim.
  """
  @spec parse_scope(term()) :: {:ok, scope()} | {:error, String.t()}
  def parse_scope(scope) when scope in ["shared", :shared], do: {:ok, :shared}
  def parse_scope(scope) when scope in ["local", :local], do: {:ok, :local}
  def parse_scope(scope) when scope in ["all", :all], do: {:ok, :all}
  def parse_scope(_other), do: {:error, @scope_error_message}

  # Locates the FIRST divider line in the raw binary and returns its byte
  # offset + byte length. `return: :index` keeps everything in bytes, which is
  # precisely what `binary_part/3` and `byte_size/1` need below.
  defp locate(content) do
    case Regex.run(@divider, content, return: :index) do
      [{start, length}] -> {:ok, start, length}
      nil -> :none
    end
  end

  # Turns the located divider into the three exact byte slices of the file: the
  # Shared text, the divider line ITSELF (so a splice can restore it verbatim)
  # and the Local text. `:none` means no divider line is present.
  defp regions(content) do
    case locate(content) do
      {:ok, start, length} ->
        local_start = start + length

        {:ok, binary_part(content, 0, start), binary_part(content, start, length),
         binary_part(content, local_start, byte_size(content) - local_start)}

      :none ->
        :none
    end
  end

  defp select(shared, _local, :shared), do: shared
  defp select(_shared, local, :local), do: local
  defp select(shared, local, :all), do: shared <> local
end
