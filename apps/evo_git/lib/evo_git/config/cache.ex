defmodule EvoGit.Config.Cache do
  @moduledoc """
  RAM-resident snapshot of the global Genesis configuration, one per config
  directory.

  Every read of `config.toml`/`credentials.toml` used to stat (and often
  re-read) the files on the calling process's stack. The snapshot keeps the
  parsed maps, the resolved config and the validation errors in
  `:persistent_term` under `{EvoGit.Config.Cache, dir}`, so a read is a plain
  term lookup with ZERO file I/O.

  Freshness is event-driven, never polled: a save (`EvoGit.Config.save_user_config/1`,
  `save_credentials/1`) reloads synchronously, and `EvoGit.Config.Watcher`
  reloads when the directory reports a change. A reload replaces the snapshot
  only when the raw bytes' fingerprint changed, and bumps the snapshot
  `generation`, broadcasting `{:config_reloaded, node, dir, generation}` on the
  `"config"` PubSub topic (best-effort — a not-started PubSub is skipped).

  The config directory is resolved at CALL time in the calling process through
  `EvoGit.Config.config_dir/0`, so the default-inert per-process
  `:config_dir_fun` test seam keeps working.
  """

  require Logger

  @topic "config"

  @type snapshot :: %{
          dir: String.t(),
          user_config: map(),
          credentials: map(),
          resolved: map(),
          validation_errors: [EvoGit.Config.Schema.ValidationError.t()],
          generation: pos_integer(),
          fingerprint: term()
        }

  @doc """
  Returns the snapshot for the current config directory.

  On a miss the snapshot is built once through `EvoGit.Config.build_snapshot/1`
  and stored. Never touches the filesystem on a hit.
  """
  @spec get() :: snapshot()
  def get, do: get(EvoGit.Config.config_dir())

  @doc """
  Returns the snapshot for an explicit config directory.

  On a miss the snapshot is built once and stored with `generation: 1`.
  """
  @spec get(String.t()) :: snapshot()
  def get(dir) when is_binary(dir) do
    case :persistent_term.get(key(dir), :missing) do
      :missing ->
        snapshot = EvoGit.Config.build_snapshot(dir)
        :persistent_term.put(key(dir), snapshot)
        snapshot

      %{dir: _} = snapshot ->
        snapshot
    end
  end

  @doc """
  Re-reads the config files for the current directory and stores the result
  when its fingerprint changed.

  Returns the resulting snapshot (`contents unchanged` returns the existing one).
  """
  @spec reload() :: snapshot()
  def reload, do: reload([])

  @doc """
  Re-reads the config files for `dir` (a directory binary or `dir: <binary>`).

  `:persistent_term` is written at most once per actual change, and the
  `"config"` broadcast is attempted only on a change.
  """
  @spec reload(String.t() | keyword()) :: snapshot()
  def reload(dir) when is_binary(dir), do: reload(dir: dir)

  def reload(opts) when is_list(opts) do
    dir = Keyword.get(opts, :dir) || EvoGit.Config.config_dir()
    built = EvoGit.Config.build_snapshot(dir)

    case :persistent_term.get(key(dir), :missing) do
      %{fingerprint: fingerprint} = previous when fingerprint == built.fingerprint ->
        previous

      %{generation: generation} ->
        store(Map.put(built, :generation, generation + 1), dir)

      :missing ->
        store(Map.put(built, :generation, 1), dir)
    end
  end

  @doc """
  Erases the snapshot for the current config directory (test seam / explicit reset).
  """
  @spec invalidate() :: :ok
  def invalidate, do: invalidate(EvoGit.Config.config_dir())

  @doc """
  Erases the snapshot for an explicit config directory.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(dir) when is_binary(dir) do
    :persistent_term.erase(key(dir))
    :ok
  end

  defp store(%{dir: dir} = snapshot, dir) do
    :persistent_term.put(key(dir), snapshot)
    broadcast(dir, snapshot.generation)
    snapshot
  end

  defp key(dir) when is_binary(dir), do: {__MODULE__, dir}

  # Best-effort only: a missing/restarting PubSub must never turn a config
  # reload into a crash of the caller (a save handler or the watcher).
  defp broadcast(dir, generation) do
    if Process.whereis(EvoGit.PubSub) do
      try do
        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          @topic,
          {:config_reloaded, node(), dir, generation}
        )
      rescue
        error -> Logger.debug("Config reload broadcast failed: #{inspect(error)}")
      catch
        kind, reason -> Logger.debug("Config reload broadcast failed: #{inspect({kind, reason})}")
      end
    end

    :ok
  end
end
