defmodule EvoGit.VCT.Path do
  @moduledoc """
  Canonical value object for Virtual Context Tree (VCT) URLs.

  A VCT path is a pure in-memory namespace address — it is NOT a filesystem
  path and never implies a symlink, mount or junction. The canonical forms are:

      vct:///                     # the VCT root
      vct:///projects             # the projects folder
      vct:///projects/foo         # a project mount point
      vct:///projects/foo/bar     # a nested node under a mount

  Only LOCAL addressing is supported: the authority must be empty, so
  `vct://host/projects/foo` is rejected with `{:error, :non_local_authority}`
  (reserved for a future remote `vct://<host>/<path>` form).

  Parsing normalizes duplicate and trailing slashes, and the formatted output is
  always canonical: one slash between segments and no trailing slash except for
  the root (`vct:///`). Segments may not be empty, `.`, `..`, contain a `/`, or
  contain control characters (`\\x00`–`\\x1F`, `\\x7F`).
  """

  defstruct segments: []

  @type t :: %__MODULE__{segments: [String.t()]}

  @scheme "vct://"
  @scheme_size byte_size(@scheme)
  @max_control 0x1F
  @del 0x7F

  @doc """
  Returns the VCT root (`vct:///`).

  ## Examples

      iex> EvoGit.VCT.Path.root()
      %EvoGit.VCT.Path{segments: []}
  """
  @spec root() :: t()
  def root, do: %__MODULE__{segments: []}

  @doc """
  Returns the projects folder (`vct:///projects`).
  """
  @spec projects() :: t()
  def projects, do: %__MODULE__{segments: ["projects"]}

  @doc """
  Parses a VCT URL into a `t:t/0`.

  Returns `{:ok, path}` on success, otherwise one of:

    * `{:error, :invalid_scheme}` — the input is not a `vct://` URL
    * `{:error, :non_local_authority}` — the URL carries a host authority
    * `{:error, :invalid_path}` — the input is not a binary or carries no path
    * `{:error, {:invalid_segment, segment}}` — a rejected segment
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, atom() | {atom(), term()}}
  def parse(url) when is_binary(url) do
    with {:ok, rest} <- strip_scheme(url),
         {:ok, path} <- split_authority(rest),
         {:ok, segments} <- parse_segments(path) do
      {:ok, %__MODULE__{segments: segments}}
    end
  end

  def parse(_url), do: {:error, :invalid_path}

  @doc """
  Parses a VCT URL, raising `ArgumentError` when it is invalid.
  """
  @spec parse!(String.t()) :: t()
  def parse!(url) do
    case parse(url) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, invalid_url_message(url, reason)
    end
  end

  @doc """
  Formats a path (or a plain segment list) as its canonical VCT URL.

  Raises `ArgumentError` when any segment is invalid — this is a programmer
  error, not user-input validation (use `parse/1` for user input).
  """
  @spec format(t() | [String.t()]) :: String.t()
  def format(%__MODULE__{segments: segments}), do: format(segments)

  def format(segments) when is_list(segments) do
    segments = Enum.map(segments, &validate_segment!/1)
    @scheme <> "/" <> Enum.join(segments, "/")
  end

  @doc """
  Appends one or more segments to a path.

  The left-hand side may be a `t:t/0` or a VCT URL string (parsed with
  `parse!/1`). A binary right-hand side is a SINGLE segment; use a list to
  append several. Raises `ArgumentError` on invalid segments.
  """
  @spec join(t() | String.t(), String.t() | [String.t()]) :: t()
  def join(base, segment) when is_binary(segment), do: join(base, [segment])

  def join(base, extra) when is_list(extra) do
    %__MODULE__{segments: to_segments(base) ++ Enum.map(extra, &validate_segment!/1)}
  end

  @doc """
  Returns the segments of a path (parsing strings first).
  """
  @spec segments(t() | String.t()) :: [String.t()]
  def segments(path), do: to_segments(path)

  @doc """
  Returns the last segment of a path, or `nil` for the root.
  """
  @spec name(t() | String.t()) :: String.t() | nil
  def name(path), do: path |> to_segments() |> List.last()

  @doc """
  Returns `true` when `a` is a STRICT ancestor (segment prefix) of `b`.

  The root is an ancestor of every non-root path, and no path is an ancestor of
  itself.
  """
  @spec ancestor?(t() | String.t(), t() | String.t()) :: boolean()
  def ancestor?(a, b) do
    a_segments = to_segments(a)
    b_segments = to_segments(b)

    length(a_segments) < length(b_segments) and List.starts_with?(b_segments, a_segments)
  end

  @doc """
  Returns `true` when `a` is a prefix of `b`, INCLUDING equality.
  """
  @spec under?(t() | String.t(), t() | String.t()) :: boolean()
  def under?(a, b), do: List.starts_with?(to_segments(b), to_segments(a))

  @doc """
  Returns the segments of `path` relative to `base`.

  Returns `{:ok, []}` when the two are equal and `{:error, :not_under}` when
  `path` does not live under `base`.
  """
  @spec relative_to(t() | String.t(), t() | String.t()) ::
          {:ok, [String.t()]} | {:error, :not_under}
  def relative_to(path, base) do
    path_segments = to_segments(path)
    base_segments = to_segments(base)

    if List.starts_with?(path_segments, base_segments) do
      {:ok, Enum.drop(path_segments, length(base_segments))}
    else
      {:error, :not_under}
    end
  end

  ## Parsing helpers

  defp strip_scheme(url) do
    if String.starts_with?(url, @scheme) do
      {:ok, binary_part(url, @scheme_size, byte_size(url) - @scheme_size)}
    else
      {:error, :invalid_scheme}
    end
  end

  # An empty remainder means the URL carried no path at all (`vct://`).
  defp split_authority(""), do: {:error, :invalid_path}
  defp split_authority(<<"/", path::binary>>), do: {:ok, path}

  # A remainder that does not start with "/" is a host authority: `vct://host/…`.
  defp split_authority(rest) do
    case String.split(rest, "/", parts: 2) do
      [authority | _] when authority != "" -> {:error, :non_local_authority}
      _ -> {:error, :invalid_path}
    end
  end

  defp parse_segments(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while([], fn segment, acc ->
      if valid_segment?(segment) do
        {:cont, [segment | acc]}
      else
        {:halt, {:error, {:invalid_segment, segment}}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      segments -> {:ok, Enum.reverse(segments)}
    end
  end

  ## Segment validation

  defp valid_segment?(segment) when is_binary(segment) do
    segment != "" and segment not in [".", ".."] and not String.contains?(segment, "/") and
      not control_chars?(segment)
  end

  defp valid_segment?(_segment), do: false

  defp control_chars?(segment) do
    segment
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= @max_control or byte == @del end)
  end

  defp validate_segment!(segment) do
    if valid_segment?(segment) do
      segment
    else
      raise ArgumentError,
            "invalid VCT path segment: #{inspect(segment)} " <>
              "(must be a non-empty string other than \".\"/\"..\" without \"/\" or control characters)"
    end
  end

  defp to_segments(%__MODULE__{segments: segments}), do: segments
  defp to_segments(url) when is_binary(url), do: parse!(url).segments

  defp invalid_url_message(url, reason) do
    "invalid VCT URL: #{inspect(url)} (#{format_error(reason)})"
  end

  defp format_error(:invalid_scheme), do: "expected the vct:// scheme"
  defp format_error(:invalid_path), do: "expected a non-empty path"
  defp format_error(:non_local_authority), do: "only local VCT URLs (vct:///) are supported"
  defp format_error({:invalid_segment, segment}), do: "invalid segment #{inspect(segment)}"
  defp format_error(reason), do: inspect(reason)
end

defimpl String.Chars, for: EvoGit.VCT.Path do
  def to_string(path), do: EvoGit.VCT.Path.format(path)
end
