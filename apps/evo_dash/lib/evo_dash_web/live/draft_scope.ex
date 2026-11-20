defmodule EvoDashWeb.DraftScope do
  @moduledoc """
  The ONE definition of browser-draft scope identity.

  A draft scope is `{node, token}`: the viewed node (an SSH target id or
  `"local"`) plus the selected project's VCT point (`vct:///projects/<name>`),
  a workspace point (`vct:///workspaces/<slug>`) or, for a project that is not
  mounted yet, the raw absolute OS path. `token/1` derives that token from a
  `%EvoGit.VCT.Mount{}`, a plain map (atom or string keys) or a bare binary, and
  `store_key/2` turns it into the exact `sessionStorage` key the browser uses.

  A token is a STORAGE/SCOPE identity only. Task admission, `mount_project` and
  interactive agent-session start always take the absolute OS path
  (`path/1`) — never a token. A workspace token in particular is a grouping
  identity: it has no OS path and must never be handed to `start_task`, which is
  why `path/1` answers nil for a workspace mount.

  The token is returned VERBATIM: the core already canonicalizes VCT points, and
  a raw path must survive a round-trip to a remote node unchanged (no
  `Path.expand/1`, no basename, no OS-specific mangling). Total: any other input
  (nil, `""`, a number, a keyword list) answers nil instead of raising.
  """

  alias EvoGit.VCT.Mount

  @type token :: String.t()
  @type node_id :: String.t() | atom() | nil
  @type selection :: Mount.t() | map() | String.t() | term()

  # Precedence for the VCT point: a Mount's `:point` first, then the string-keyed
  # form a JSON/param map carries, then the alternate `vct_path` spelling.
  @point_keys [:point, "point", :vct_path, "vct_path"]
  @path_keys [:path, "path"]
  @point_prefix "vct:///"
  @workspace_prefix "vct:///workspaces/"
  @key_prefix "dashboard_state:"
  @legacy_key "dashboard_state"

  @doc """
  Returns the scope token: the selection's VCT point, else its absolute path.

  A non-empty point wins over the path, so the same repo re-selected through a
  different path spelling (a symlink, a second mount, a workspace member) keeps
  ONE draft, while two points over the same OS path stay separate. nil when the
  selection carries neither.
  """
  @spec token(selection()) :: token() | nil
  def token(selection) do
    case selected_point(selection) do
      nil -> path(selection)
      point -> point
    end
  end

  @doc """
  Returns the token for a PROJECT selection (a `kind: "git"` mount or a bare
  path); nil for a workspace, whose grouping point is not an execution target.
  """
  @spec project(selection()) :: token() | nil
  def project(selection), do: if(workspace?(selection), do: nil, else: token(selection))

  @doc "Returns the token for a WORKSPACE selection, or nil for anything else."
  @spec workspace(selection()) :: token() | nil
  def workspace(selection), do: if(workspace?(selection), do: token(selection), else: nil)

  @doc "True only for a `vct:///…` token; false for a raw path or nil."
  @spec point?(term()) :: boolean()
  def point?(token), do: is_binary(token) and String.starts_with?(token, @point_prefix)

  @doc """
  Returns the absolute OS execution path of a selection — the value a task start,
  `mount_project` or an agent-session start takes.

  Never returns a `vct:` value: a selection that only carries a VCT point (a
  workspace mount has no path at all) answers nil.
  """
  @spec path(selection()) :: String.t() | nil
  def path(selection) when is_binary(selection), do: os_path(selection)

  def path(selection) when is_map(selection),
    do: selection |> first_present(@path_keys) |> os_path()

  def path(_selection), do: nil

  @doc """
  Returns the canonical draft key for `{node, token}`.

  A token yields `"dashboard_state:" <> json([node, token])` — byte-identical to
  the legacy path-keyed entry — while a nil/blank token yields the un-scoped
  legacy key `"dashboard_state"`.
  """
  @spec store_key(node_id(), term()) :: String.t()
  def store_key(node, token) do
    if present?(token) do
      @key_prefix <> Jason.encode!([node_name(node), token])
    else
      @legacy_key
    end
  end

  @doc """
  Returns the PATH-keyed draft key `{node, path}`, the key a VCT-scoped entry may
  be migrated from (nil when the selection has no OS path).
  """
  @spec legacy_store_key(node_id(), selection()) :: String.t() | nil
  def legacy_store_key(node, selection) do
    case path(selection) do
      nil -> nil
      path -> @key_prefix <> Jason.encode!([node_name(node), path])
    end
  end

  defp selected_point(selection) when is_map(selection),
    do: first_present(selection, @point_keys)

  # A bare binary may already BE a point (the token form later waves pass around).
  defp selected_point(selection) when is_binary(selection),
    do: if(point?(selection), do: selection)

  defp selected_point(_selection), do: nil

  defp first_present(selection, keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(selection, key)
      if present?(value), do: value
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # A VCT point is identity, not a path — and a workspace point never has a path.
  defp os_path(candidate) when is_binary(candidate) do
    trimmed = String.trim(candidate)

    if trimmed == "" or String.starts_with?(trimmed, "vct:"), do: nil, else: candidate
  end

  defp os_path(_candidate), do: nil

  defp workspace?(selection) do
    kind(selection) in ["workspace", :workspace] or
      String.starts_with?(selected_point(selection) || "", @workspace_prefix)
  end

  defp kind(selection) when is_map(selection),
    do: Map.get(selection, :kind) || Map.get(selection, "kind")

  defp kind(_selection), do: nil

  # Matches the browser hook's `dataset.nodeId || 'local'`.
  defp node_name(node) when is_binary(node) and node != "", do: node
  defp node_name(_node), do: "local"
end
