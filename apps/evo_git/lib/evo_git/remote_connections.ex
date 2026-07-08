defmodule EvoGit.RemoteConnections do
  @moduledoc """
  Manages SSH remote connection targets as a TOML file store.

  Connection targets are persisted to `~/.config/genesis/remote_connections.toml`
  as an array-of-tables (`[[connections]]`). Each target describes an SSH host
  that the runtime can connect to (e.g. for remote deployment or distribution
  tunneling).

  This module is a collection of **pure functions** — it is NOT a GenServer.
  Every call reads from / writes to the TOML file directly.

  ## Connection fields

  | Field | Type | Required | Default | Description |
  |---|---|---|---|---|
  | `id` | string | no | auto-generated | Unique identifier (slugified from host/user) |
  | `name` | string | no | `host` | Display name |
  | `host` | string | **yes** | — | SSH host (`user@example.com` or `example.com`) |
  | `user` | string | no | extracted from host | SSH user |
  | `port` | integer | no | `22` | SSH port |
  | `dist_port` | integer | no | `9000` | Erlang distribution port for tunneling |
  | `identity_file` | string | no | `nil` | Path to SSH key |
  | `remote_path` | string | no | `/tmp/genesis_engine` | Where to place the binary on the remote |
  | `last_connected` | string | no | `nil` | ISO8601 timestamp of last successful connection |

  Connection maps use **atom keys** internally; keys are stringified only when
  serialized to TOML.
  """

  @config_filename "remote_connections.toml"

  @default_port 22
  @default_dist_port 9000
  @default_remote_path "/tmp/genesis_engine"

  # Maps TOML string keys to atoms for the known connection schema. Unknown
  # keys are left as strings so we never raise on unexpected data.
  @key_map %{
    "id" => :id,
    "name" => :name,
    "host" => :host,
    "user" => :user,
    "port" => :port,
    "dist_port" => :dist_port,
    "identity_file" => :identity_file,
    "remote_path" => :remote_path,
    "last_connected" => :last_connected
  }

  @non_alnum_re ~r/[^a-z0-9]+/
  @trim_underscore_re ~r/(?:^_+|_+$)/

  @type t :: map()

  # --- Public API ---

  @doc """
  Lists all stored connection targets.

  Reads the TOML file and returns a list of atom-keyed connection maps.
  Returns `[]` if the file does not exist or is empty.
  """
  @spec list() :: [map()]
  def list do
    data = EvoGit.Config.read_toml_file(path(), %{}, description: "remote connections")

    case Map.get(data, "connections") do
      connections when is_list(connections) ->
        Enum.map(connections, &atomize_connection/1)

      _ ->
        []
    end
  end

  @doc """
  Fetches a single connection target by its id.

  Returns `{:ok, map}` if found, otherwise `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Enum.find(list(), fn conn -> conn.id == id end) do
      nil -> {:error, :not_found}
      conn -> {:ok, conn}
    end
  end

  @doc """
  Saves a connection target, creating or updating it.

  Validates that `:host` is present and non-empty. When missing, returns
  `{:error, :missing_host}`. Otherwise:

    * extracts `:user` from `host` when `host` contains `@` and no `:user`
      is provided,
    * auto-generates `:id` (slugified from host/user) when missing,
    * defaults `:name` to `host` when missing,
    * applies defaults for `:port` (22), `:dist_port` (9000), and
      `:remote_path` (`/tmp/genesis_engine`) when absent.

  If an existing connection shares the same id it is updated; otherwise the
  connection is appended. Returns `{:ok, target}` on success.
  """
  @spec save(map()) :: {:ok, map()} | {:error, term()}
  def save(target) when is_map(target) do
    conn = atomize_connection(target)
    host = Map.get(conn, :host)

    cond do
      is_nil(host) or host == "" ->
        {:error, :missing_host}

      true ->
        normalized = normalize_target(conn, host)
        connections = list()

        updated_connections =
          if Enum.any?(connections, fn c -> c.id == normalized.id end) do
            Enum.map(connections, fn c ->
              if c.id == normalized.id, do: normalized, else: c
            end)
          else
            connections ++ [normalized]
          end

        case write_connections(updated_connections) do
          :ok -> {:ok, normalized}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Deletes the connection target with the given id.

  Returns `:ok` on success, or `{:error, :not_found}` if no connection has
  that id.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) when is_binary(id) do
    connections = list()

    if Enum.any?(connections, fn c -> c.id == id end) do
      updated = Enum.reject(connections, fn c -> c.id == id end)

      case write_connections(updated) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Updates the `last_connected` timestamp of a connection target.

  Sets `last_connected` to the current UTC time as an ISO8601 string and
  persists the change. Returns `:ok` on success, or `{:error, :not_found}`
  if no connection has that id.
  """
  @spec touch(String.t()) :: :ok | {:error, :not_found}
  def touch(id) when is_binary(id) do
    case get(id) do
      {:ok, conn} ->
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = Map.put(conn, :last_connected, timestamp)

        case save(updated) do
          {:ok, _target} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private Helpers ---

  defp path do
    Path.join(EvoGit.Config.config_dir(), @config_filename)
  end

  # Normalizes a raw connection map into a fully-populated target with all
  # defaults applied. `host` is the already-extracted host value.
  defp normalize_target(conn, host) do
    user =
      case Map.get(conn, :user) do
        nil -> extract_user_from_host(host)
        "" -> extract_user_from_host(host)
        user -> user
      end

    %{
      id: Map.get(conn, :id) || slugify_host(host, user),
      name: Map.get(conn, :name) || host,
      host: host,
      user: user,
      port: get_or_default(conn, :port, @default_port),
      dist_port: get_or_default(conn, :dist_port, @default_dist_port),
      identity_file: Map.get(conn, :identity_file),
      remote_path: get_or_default(conn, :remote_path, @default_remote_path),
      last_connected: Map.get(conn, :last_connected)
    }
  end

  # Returns the value for `key` if present and non-nil, otherwise `default`.
  defp get_or_default(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      value -> value
    end
  end

  # Extracts the SSH user from a "user@host" style string. Returns nil when
  # the host has no `@`.
  defp extract_user_from_host(host) do
    case String.split(host, "@", parts: 2) do
      [user, _host] -> user
      [_host] -> nil
    end
  end

  # Builds a slug id from the host (and optional user), joining them and
  # slugifying. Modeled on `slugify_domain/1` in ConceptExpander.
  defp slugify_host(host, nil), do: slugify(host)
  defp slugify_host(host, ""), do: slugify(host)
  defp slugify_host(host, user), do: slugify("#{host}-#{user}")

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.replace(@non_alnum_re, "_")
    |> String.replace(@trim_underscore_re, "")
    |> String.slice(0, 40)
  end

  # Converts a string-keyed connection map (as decoded from TOML) into an
  # atom-keyed map. Unknown string keys are left as-is.
  defp atomize_connection(conn) when is_map(conn) do
    Map.new(conn, fn
      {key, value} when is_binary(key) ->
        {Map.get(@key_map, key, key), value}

      {key, value} ->
        {key, value}
    end)
  end

  # Recursively converts atom keys to string keys and drops nil values.
  # Modeled on `stringify_keys/1` in EvoGit.Config.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(nil), do: nil
  defp stringify_keys(value), do: value

  # Serializes the connection list to TOML and writes it to disk.
  defp write_connections(connections) do
    dir = EvoGit.Config.config_dir()
    data = %{"connections" => Enum.map(connections, &stringify_keys/1)}

    with :ok <- File.mkdir_p(dir),
         {:ok, toml} <- TomlElixir.encode(data) do
      File.write(path(), toml)
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
