defmodule EvoGit.SSHConfig do
  @moduledoc """
  Parses `~/.ssh/config` and provides lookups for host-specific configuration.

  Best-effort: returns empty results if the file is missing or unparseable.

  The parser handles:
    * `Host` — starts a block; multiple space-separated patterns allowed
    * `HostName` — actual hostname to connect to
    * `User` — SSH user
    * `Port` — SSH port
    * `IdentityFile` — path to SSH key (tilde-expanded)
    * `ProxyJump` — jump host(s)
    * `ProxyCommand` — proxy command
    * `Include` — includes other files (with simple glob support)
    * Comments (lines starting with `#`) and blank lines are ignored
    * All directive names and Host patterns are matched case-insensitively
  """

  @known_directives ~w(host hostname user port identityfile proxyjump proxycommand include)

  # Map from internal (lowercase-directive) atoms to the public API atoms
  # that lookup/2 returns.
  @key_atom_map %{
    hostname: :hostname,
    user: :user,
    port: :port,
    identityfile: :identity_file,
    proxyjump: :proxy_jump,
    proxycommand: :proxy_command
  }

  @typedoc """
  A parsed SSH config: a list of `{patterns, entries}` tuples where
  `patterns` is a list of lowercase host pattern strings and `entries`
  is a keyword list of `{directive_atom, value}` pairs.
  """
  @type parsed_block :: {[String.t()], keyword()}

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Looks up SSH config for the given hostname.

  Returns a map with any of: `:user`, `:port`, `:hostname`, `:identity_file`,
  `:proxy_jump`, `:proxy_command`. Returns `%{}` if nothing is found or the
  config file does not exist.

  ## Merging rules (OpenSSH-style)

  1. All `Host` blocks whose patterns match `host` are collected **in file
     order** (first match wins for each key).
  2. `Host *` blocks are applied **last** so they act as a fallback.

  Pattern matching: exact string match or `*` (matches everything).
  """
  @spec lookup(String.t()) :: map()
  def lookup(host) when is_binary(host) do
    lookup(host, parse())
  end

  @doc """
  Looks up SSH config for the given hostname using a pre-parsed config.

  Useful for testing or when the config was already parsed.
  """
  @spec lookup(String.t(), [parsed_block()]) :: map()
  def lookup(host, blocks) when is_binary(host) and is_list(blocks) do
    host_lower = String.downcase(host)

    # Collect matching blocks in order, separating wildcards
    {explicit, wildcards} =
      Enum.split_with(blocks, fn {patterns, _entries} ->
        patterns != ["*"]
      end)

    matching_explicit =
      Enum.filter(explicit, fn {patterns, _entries} ->
        Enum.any?(patterns, &pattern_match?(&1, host_lower))
      end)

    matching_wildcards =
      Enum.filter(wildcards, fn {patterns, _entries} ->
        Enum.any?(patterns, &pattern_match?(&1, host_lower))
      end)

    # Explicit matches first, then wildcard fallback
    all_matching = matching_explicit ++ matching_wildcards

    # Merge: first match wins per key. Map internal atoms to public API atoms.
    merged =
      Enum.reduce(all_matching, %{}, fn {_patterns, entries}, acc ->
        Enum.reduce(entries, acc, fn {key, value}, inner_acc ->
          public_key = Map.get(@key_atom_map, key)

          if public_key != nil and is_nil(Map.get(inner_acc, public_key)) do
            Map.put(inner_acc, public_key, value)
          else
            inner_acc
          end
        end)
      end)

    # Convert port to integer if present
    merged =
      case Map.get(merged, :port) do
        port when is_binary(port) ->
          case Integer.parse(port) do
            {int_port, ""} -> Map.put(merged, :port, int_port)
            _ -> Map.delete(merged, :port)
          end

        _ ->
          merged
      end

    merged
  end

  # ── Parsing ───────────────────────────────────────────────────────────

  @doc false
  @spec parse() :: [parsed_block()]
  def parse do
    parse(System.user_home!() |> Path.join(".ssh/config"))
  end

  @doc false
  @spec parse(Path.t()) :: [parsed_block()]
  def parse(path) when is_binary(path) do
    parse_file(path, MapSet.new())
  end

  # ── Private: File Parsing ─────────────────────────────────────────────

  defp parse_file(path, visited) do
    expanded = expand_tilde(path)

    if MapSet.member?(visited, expanded) do
      []
    else
      visited = MapSet.put(visited, expanded)

      case File.read(expanded) do
        {:ok, contents} ->
          parse_lines(contents, expanded, visited)

        {:error, _reason} ->
          []
      end
    end
  end

  defp parse_lines(contents, base_dir, visited) do
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)

    parse_lines_loop(lines, base_dir, visited, _blocks = [], _current = nil)
  end

  defp parse_lines_loop([], _base_dir, _visited, blocks, current) do
    finalize_blocks(blocks, current)
  end

  defp parse_lines_loop([line | rest], base_dir, visited, blocks, current) do
    case split_directive(line) do
      {"host", value} ->
        # New Host block — finalize the previous one
        blocks = finalize_blocks(blocks, current)
        patterns = parse_host_patterns(value)
        parse_lines_loop(rest, base_dir, visited, blocks, {patterns, []})

      {"include", value} ->
        # Finalize the current block (if any) so included blocks appear after
        # the preceding Host block, preserving file order.
        blocks = finalize_blocks(blocks, current)
        included_blocks = handle_include(value, base_dir, visited)
        parse_lines_loop(rest, base_dir, visited, blocks ++ included_blocks, nil)

      {directive, value} when current != nil ->
        atom = String.to_existing_atom(directive)
        {patterns, entries} = current
        current = {patterns, Keyword.put(entries, atom, value)}
        parse_lines_loop(rest, base_dir, visited, blocks, current)

      _ ->
        # Directive outside a Host block (ignored) or unknown directive
        parse_lines_loop(rest, base_dir, visited, blocks, current)
    end
  end

  defp finalize_blocks(blocks, nil), do: blocks

  defp finalize_blocks(blocks, {_patterns, []}), do: blocks

  defp finalize_blocks(blocks, current) do
    # Expand tilde in IdentityFile values
    current = expand_identity_file(current)
    blocks ++ [current]
  end

  # ── Private: Include Handling ─────────────────────────────────────────

  defp handle_include(value, base_dir, visited) do
    patterns =
      value
      |> String.trim()
      |> expand_tilde()
      |> String.split()

    Enum.flat_map(patterns, fn pattern ->
      # If pattern is relative, resolve against base_dir
      resolved =
        if Path.type(pattern) == :relative do
          Path.join(Path.dirname(base_dir), pattern)
        else
          pattern
        end

      # Use Path.wildcard for glob expansion; if no matches, Path.wildcard returns []
      matched = Path.wildcard(resolved)

      if matched == [] and not String.contains?(pattern, "*") do
        # Single file — try to parse it even if it doesn't match wildcard
        parse_file(resolved, visited)
      else
        Enum.flat_map(matched, &parse_file(&1, visited))
      end
    end)
  end

  # ── Private: Pattern Matching ─────────────────────────────────────────

  defp parse_host_patterns(value) do
    value
    |> String.trim()
    |> String.split()
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp pattern_match?("*", _host), do: true
  defp pattern_match?(pattern, host), do: pattern == host

  # ── Private: Line Parsing Helpers ─────────────────────────────────────

  defp split_directive(line) do
    # Remove inline comments (but respect quoted strings simply — a "#" inside
    # quotes is still part of the value; we don't need full quoting support)
    # For simplicity: strip trailing comments only when # is preceded by
    # whitespace or at start of a token.
    {key, rest} =
      case String.split(line, ~r/\s+/, parts: 2) do
        [k, r] -> {k, r}
        [k] -> {k, ""}
      end

    key = String.downcase(key)

    if key in @known_directives do
      # Trim inline comment from value (simplistic: split on " #" and take first)
      value = strip_inline_comment(rest)
      {key, value}
    else
      {key, rest}
    end
  end

  defp strip_inline_comment(value) do
    # Remove trailing comment. We split on " #" (space-hash) which is the
    # convention for inline comments in SSH config. If the value starts with
    # a quote, we leave it alone (it's a quoted value).
    trimmed = String.trim(value)

    cond do
      String.starts_with?(trimmed, "\"") -> trimmed
      true -> trimmed |> String.split(" #", parts: 2) |> hd() |> String.trim()
    end
  end

  # ── Private: Tilde & Path Expansion ───────────────────────────────────

  defp expand_tilde(path) when is_binary(path) do
    home = System.user_home!()

    cond do
      path == "~" -> home
      String.starts_with?(path, "~/") -> Path.join(home, String.replace_leading(path, "~/", ""))
      true -> path
    end
  end

  defp expand_identity_file({patterns, entries}) do
    updated =
      Enum.map(entries, fn
        {:identityfile, value} -> {:identityfile, expand_tilde(value)}
        other -> other
      end)

    {patterns, updated}
  end
end
