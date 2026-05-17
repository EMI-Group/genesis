defmodule LLMDB.Packaged do
  @moduledoc """
  Provides access to the packaged base snapshot.

  This is NOT a Source - it returns the pre-processed, version-stable snapshot
  that ships with each release. The snapshot has already been through the full
  ETL pipeline (normalize → validate → merge → enrich → filter → index).

  Sources (ModelsDev, Local, Config) provide raw data that gets merged ON TOP
  of this base snapshot.

  ## Loading Strategy

  Behavior controlled by `:compile_embed` configuration option:
  - `true` - Snapshot embedded at compile-time (zero runtime IO, recommended for production)
  - `false` - Snapshot loaded at runtime from priv directory with integrity checking

  ## Security

  Production deployments should use `compile_embed: true` to eliminate runtime atom
  creation and file I/O. Runtime mode includes SHA-256 integrity verification to
  prevent tampering with the snapshot file.

  ### Integrity Policy

  The `:integrity_policy` config option controls integrity check behavior:
  - `:strict` (default) - Fail on hash mismatch, treating it as tampering
  - `:warn` - Log warning and continue, useful in dev when snapshot regenerates frequently
  - `:off` - Skip mismatch warnings entirely

  In development, use `:warn` mode. The snapshot file is marked as an `@external_resource`,
  so Mix automatically recompiles the module when it changes, refreshing the hash.
  """

  require Logger
  alias LLMDB.Snapshot

  @snapshot_filename "priv/llm_db/snapshot.json"
  @snapshot_compile_path Path.join([Application.app_dir(:llm_db), @snapshot_filename])

  @external_resource @snapshot_compile_path

  @doc """
  Returns the absolute path to the packaged snapshot file.

  ## Returns

  String path to `priv/llm_db/snapshot.json` within the application directory.
  """
  @spec snapshot_path() :: String.t()
  def snapshot_path, do: Snapshot.packaged_path()

  if Application.compile_env(:llm_db, :compile_embed, false) do
    @snapshot if File.exists?(@snapshot_compile_path),
                do: Jason.decode!(File.read!(@snapshot_compile_path)),
                else: nil

    @doc """
    Returns the packaged base snapshot (compile-time embedded).

    This snapshot is the pre-processed output of the ETL pipeline and serves
    as the stable foundation for this package version.

    ## Returns

    Fully indexed snapshot map with providers, models, and indexes, or `nil` if not available.
    """
    @spec snapshot() :: map() | nil
    def snapshot, do: @snapshot
  else
    @doc """
    Returns the packaged base snapshot (runtime loaded with integrity check).

    This snapshot is the pre-processed output of the ETL pipeline and serves
    as the stable foundation for this package version.

    Includes SHA-256 integrity verification to prevent tampering.

    ## Returns

    Fully indexed snapshot map with providers, models, and indexes, or `nil` if not available.
    """
    @spec snapshot() :: map() | nil
    def snapshot do
      with {:ok, content} <- File.read(snapshot_path()) do
        case Snapshot.decode(content) do
          {:ok, snapshot} ->
            validate_schema(snapshot)
            snapshot

          {:error, reason} ->
            load_unverified_snapshot(content, reason)
        end
      else
        {:error, :enoent} ->
          # Snapshot doesn't exist yet (e.g., during build process)
          nil

        {:error, reason} ->
          Logger.warning("llm_db: failed to load snapshot: #{inspect(reason)}")
          nil
      end
    end

    defp integrity_policy do
      Application.get_env(:llm_db, :integrity_policy, :strict)
    end

    defp load_unverified_snapshot(content, reason) do
      case integrity_policy() do
        :strict ->
          Logger.error(
            "llm_db: snapshot integrity check failed - refusing to load packaged snapshot: #{inspect(reason)}"
          )

          nil

        mode when mode in [:warn, :off] ->
          if mode == :warn do
            Logger.warning(
              "llm_db: snapshot integrity check failed in warn mode: #{inspect(reason)}. " <>
                "Loading unverified snapshot content."
            )
          end

          case Jason.decode(content) do
            {:ok, snapshot} ->
              validate_schema(snapshot)
              snapshot

            {:error, decode_reason} ->
              Logger.warning(
                "llm_db: failed to decode unverified snapshot: #{inspect(decode_reason)}"
              )

              nil
          end
      end
    end

    defp validate_schema(snapshot) do
      providers =
        case snapshot do
          %{"providers" => providers} when is_map(providers) -> providers
          %{providers: providers} when is_map(providers) -> providers
          _ -> %{}
        end

      # Lightweight schema checks to prevent atom/memory exhaustion
      provider_count = map_size(providers)

      if provider_count > 1000 do
        Logger.warning(
          "llm_db: snapshot contains unusually large number of providers: #{provider_count}. " <>
            "Expected < 1000. Potential DoS attempt."
        )
      end

      # Check provider IDs match safe regex
      Enum.each(providers, fn {provider_id, _data} ->
        provider_id_str = to_string(provider_id)

        unless provider_id_str =~ ~r/^[a-z0-9][a-z0-9_:-]{0,63}$/ do
          Logger.warning(
            "llm_db: snapshot contains suspicious provider ID: #{inspect(provider_id)}"
          )
        end
      end)

      :ok
    end
  end
end
