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
  | `id` | string | no | auto-generated | Unique identifier (slugified from name/ssh_target, max 40 chars) |
  | `name` | string | no | `ssh_target` | Display name |
  | `ssh_target` | string | **yes** | — | The SSH host string (e.g. `gpu-server`, `user@192.168.1.10`) — just what you'd type after `ssh`. Port/keys handled by `~/.ssh/config` |
  | `local_binary_path` | string | **yes** | — | Path to local `genesis_remote` binary to upload (e.g. `burrito_out/genesis_remote_linux_x64`) |
  | `dist_port` | integer | no | `9000` | Erlang distribution port for tunneling |
  | `remote_path` | string | no | `/tmp/genesis_remote` | Where to place the binary on the remote |
  | `last_connected` | string | no | `nil` | ISO8601 timestamp of last successful connection |

  Connection maps use **atom keys** internally; keys are stringified only when
  serialized to TOML.
  """

  @config_filename "remote_connections.toml"

  @default_dist_port 9000
  @default_remote_path "/tmp/genesis_remote"

  # Maps TOML string keys to atoms for the known connection schema. Unknown
  # keys are left as strings so we never raise on unexpected data.
  @key_map %{
    "id" => :id,
    "name" => :name,
    "ssh_target" => :ssh_target,
    "local_binary_path" => :local_binary_path,
    "dist_port" => :dist_port,
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

  Validates that `:ssh_target` is present and non-empty. When missing, returns
  `{:error, :missing_ssh_target}`. Otherwise:

    * auto-generates `:id` (slugified from name/ssh_target) when missing,
    * defaults `:name` to `ssh_target` when missing,
    * applies defaults for `:dist_port` (9000) and `:remote_path`
      (`/tmp/genesis_remote`) when absent.

  If an existing connection shares the same id it is updated; otherwise the
  connection is appended. Returns `{:ok, target}` on success.
  """
  @spec save(map()) :: {:ok, map()} | {:error, term()}
  def save(target) when is_map(target) do
    conn = atomize_connection(target)

    # Backward compatibility: migrate old host/user fields to ssh_target.
    conn = migrate_old_fields(conn)

    ssh_target = Map.get(conn, :ssh_target)

    cond do
      is_nil(ssh_target) or ssh_target == "" ->
        {:error, :missing_ssh_target}

      true ->
        normalized = normalize_target(conn)

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

  # Backward compatibility: if a loaded/saved target has the old `host` field
  # but no `ssh_target`, construct `ssh_target` from the old fields.
  # If `user` is present → "user@host", else just "host".
  # Old `port` and `identity_file` are ignored (user should configure these
  # in ~/.ssh/config).
  defp migrate_old_fields(conn) do
    ssh_target = Map.get(conn, :ssh_target)
    host = Map.get(conn, :host)

    if (is_nil(ssh_target) or ssh_target == "") and is_binary(host) and host != "" do
      user = Map.get(conn, :user)

      constructed =
        case user do
          u when is_binary(u) and u != "" -> "#{u}@#{host}"
          _ -> host
        end

      conn
      |> Map.put(:ssh_target, constructed)
      |> Map.delete(:host)
      |> Map.delete(:user)
      |> Map.delete(:port)
      |> Map.delete(:identity_file)
    else
      # Drop old fields if ssh_target is already present.
      conn
      |> Map.delete(:host)
      |> Map.delete(:user)
      |> Map.delete(:port)
      |> Map.delete(:identity_file)
    end
  end

  # Normalizes a raw connection map into a fully-populated target with all
  # defaults applied.
  defp normalize_target(conn) do
    ssh_target = Map.get(conn, :ssh_target)
    name = Map.get(conn, :name) || ssh_target

    %{
      id: Map.get(conn, :id) || slugify(name),
      name: name,
      ssh_target: ssh_target,
      local_binary_path: Map.get(conn, :local_binary_path),
      dist_port: get_or_default(conn, :dist_port, @default_dist_port),
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
