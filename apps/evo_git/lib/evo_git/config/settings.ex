defmodule EvoGit.Config.Settings do
  @moduledoc false

  alias EvoGit.Config
  alias EvoGit.Config.{Normalization, Schema}

  @spec list_settings() :: [Schema.schema_map()]
  def list_settings, do: Schema.all_schemas()

  # Thin alias of `EvoGit.Config.resolve/0` — one snapshot read, two readings.
  @spec show() :: map()
  def show, do: Config.resolve()

  @spec show(atom() | String.t() | [atom() | String.t()]) ::
          Config.config_value()
          | {:error, :invalid_path | {:unknown_setting, [String.t()]}}
  def show(path) do
    with {:ok, parts} <- parse_path(path) do
      fetch_path(show(), parts)
    end
  end

  @spec update(map()) :: :ok | {:error, term()}
  def update(patch) when is_map(patch) and not is_struct(patch) do
    schemas = Enum.map(list_settings(), &Enum.map(&1.key_path, fn key -> Atom.to_string(key) end))

    with {:ok, entries} <- expand(patch, [], schemas),
         :ok <- check_collisions(entries) do
      persist(entries)
    end
  end

  def update(_patch), do: {:error, :invalid_patch}

  defp persist([]), do: :ok

  defp persist(entries) do
    # Start from the USER snapshot, never the resolved/default-filled map.
    # String keys avoid atom/string shadows when overlaying parsed TOML.
    candidate =
      Enum.reduce(entries, Config.Cache.get().user_config, fn {path, value}, acc ->
        put_path(acc, path, value)
      end)

    with {:ok, _} <- Schema.validate(Normalization.resolve(candidate)) do
      # The complete normalized (atom-keyed) candidate was validated above, so
      # persistence runs WITHOUT a second validation pass and receives only user
      # data (no default materialization or derived model mirrors).
      Config.persist_user_config(candidate)
    end
  end

  defp expand(map, prefix, schemas) do
    Enum.reduce_while(map, {:ok, []}, fn {key, value}, {:ok, entries} ->
      with {:ok, parts} <- parse_path(key),
           path = prefix ++ parts,
           {:ok, next} <- expand_value(value, path, schemas) do
        {:cont, {:ok, entries ++ next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp expand_value(value, path, schemas) do
    cond do
      path in schemas ->
        with {:ok, value} <- normalize_payload(value) do
          {:ok, [{path, value}]}
        end

      Enum.any?(schemas, &prefix?(path, &1)) ->
        if is_map(value) and not is_struct(value) and map_size(value) > 0 do
          expand(value, path, schemas)
        else
          {:error, {:invalid_section, path}}
        end

      true ->
        {:error, {:unknown_setting, path}}
    end
  end

  # Leaf containers (provider inventories, model maps and options) retain their
  # own schema and use literal string keys, not dotted settings paths.
  defp normalize_payload(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- payload_key(key),
           false <- Map.has_key?(acc, key),
           {:ok, value} <- normalize_payload(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, {:error, :colliding_patch_paths}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_payload(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_payload(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_payload(value) when is_struct(value), do: {:error, :invalid_patch}
  defp normalize_payload(value), do: {:ok, value}

  defp payload_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp payload_key(key) when is_binary(key) and byte_size(key) > 0, do: {:ok, key}
  defp payload_key(_key), do: {:error, :invalid_path}

  defp check_collisions(entries) do
    paths = Enum.map(entries, &elem(&1, 0))

    if length(paths) == length(Enum.uniq(paths)) do
      :ok
    else
      {:error, :colliding_patch_paths}
    end
  end

  defp prefix?(prefix, path), do: Enum.take(path, length(prefix)) == prefix

  defp parse_path(key) when is_atom(key), do: parse_path(Atom.to_string(key))
  defp parse_path(key) when is_binary(key), do: validate_parts(String.split(key, "."))

  defp parse_path(parts) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))) do
      validate_parts(
        Enum.map(parts, fn
          part when is_atom(part) -> Atom.to_string(part)
          part -> part
        end)
      )
    else
      {:error, :invalid_path}
    end
  end

  defp parse_path(_path), do: {:error, :invalid_path}

  defp validate_parts(parts) do
    if Enum.all?(parts, &(&1 != "" and String.trim(&1) == &1 and not String.contains?(&1, "."))) do
      {:ok, parts}
    else
      {:error, :invalid_path}
    end
  end

  defp fetch_path(value, []), do: value

  defp fetch_path(map, [part | rest]) when is_map(map) do
    # Compare existing keys instead of creating (or interning) any atom.
    case Enum.find(map, fn {key, _value} ->
           key == part or (is_atom(key) and Atom.to_string(key) == part)
         end) do
      {_key, value} -> fetch_path(value, rest)
      nil -> {:error, {:unknown_setting, [part | rest]}}
    end
  end

  defp fetch_path(_value, path), do: {:error, {:unknown_setting, path}}

  defp put_path(map, [key], value) do
    Map.update(map, key, value, &merge_user_value(&1, value))
  end

  defp put_path(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    child = if is_map(child), do: child, else: %{}
    Map.put(map, key, put_path(child, rest, value))
  end

  # A map-valued setting is also a partial patch; inventories/lists are whole
  # replacements because account ids/indices are not settings paths.
  defp merge_user_value(current, patch) when is_map(current) and is_map(patch) do
    Map.merge(current, patch, fn _key, old, new -> merge_user_value(old, new) end)
  end

  defp merge_user_value(_current, patch), do: patch
end
