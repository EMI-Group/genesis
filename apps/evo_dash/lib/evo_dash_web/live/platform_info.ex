defmodule EvoDashWeb.PlatformInfo do
  @moduledoc """
  Platform detection for LiveViews, with remote-node support.

  Provides the OS for the currently-viewed node (local or remote) plus pure
  predicates and schema-filtering helpers so Settings/System pages can gate
  platform-specific UI (e.g. the Linux-only sandbox sub-sections).
  """

  @type os :: :linux | :macos | :windows | :unknown

  @doc """
  Returns the OS for the given node: `:linux | :macos | :windows | :unknown`.

  - Testability override FIRST: `Application.get_env(:evo_dash, :platform_os_override, nil)`
    — when set to a known OS atom it is returned directly (the injection seam
    for tests; `:os.type/0` is not injectable, and `config/test.exs` already
    uses app-env overrides as the established pattern).
  - Local node (`current_node` is nil or `node()`) → `EvoGit.Platform.os()`.
  - Remote node → `:os.type/0` via `EvoDash.NodeContext.call_remote/4`, mapped
    to our OS atoms. Any other result (including `{:error, _}`) → `:unknown`.
    Always total — never raises.
  """
  @spec os_for_node(node() | nil) :: os()
  def os_for_node(current_node) do
    case Application.get_env(:evo_dash, :platform_os_override, nil) do
      os when os in [:linux, :macos, :windows, :unknown] -> os
      _ -> detect_os(current_node)
    end
  end

  # Local node — detect from the local VM.
  defp detect_os(current_node) when current_node in [nil, node()], do: EvoGit.Platform.os()

  # Remote node — resolve via a cross-node RPC. Justified try/catch: this is
  # the cross-node RPC boundary — a disconnected or fake node name (e.g. in
  # tests) can raise ArgumentError/badrpc exits, and the platform is a display
  # concern, so we degrade to :unknown instead of crashing the LiveView.
  # (Precedent: `EvoDash.NodeContext.call_remote/4`'s catch at the same
  # boundary.)
  defp detect_os(current_node) do
    try do
      case EvoDash.NodeContext.call_remote(current_node, :os, :type, []) do
        {:ok, {:unix, :darwin}} -> :macos
        {:ok, {:unix, _}} -> :linux
        {:ok, {:win32, _}} -> :windows
        _ -> :unknown
      end
    catch
      :exit, _ -> :unknown
      :error, _ -> :unknown
    end
  end

  @doc "True when the given OS atom is Windows."
  @spec windows?(os()) :: boolean()
  def windows?(os), do: os == :windows

  @doc "True when the given OS atom is macOS."
  @spec macos?(os()) :: boolean()
  def macos?(os), do: os == :macos

  @doc "True when the given OS atom is Linux."
  @spec linux?(os()) :: boolean()
  def linux?(os), do: os == :linux

  @doc """
  Whether the sandbox UI should be shown for the given OS.

  Conservative: false for `:windows` and `:unknown` — Windows-irrelevant
  sandbox info is never shown when the platform cannot be determined.
  """
  @spec show_sandbox?(os()) :: boolean()
  def show_sandbox?(os), do: os in [:linux, :macos]

  @doc """
  The sandbox backend banner to display for the given OS.

  - `:linux` → `:systemd_run`
  - `:macos` → `:sandbox_exec`
  - anything else → `:none`
  """
  @spec sandbox_backend_for(os()) :: :systemd_run | :sandbox_exec | :none
  def sandbox_backend_for(os) do
    case os do
      :linux -> :systemd_run
      :macos -> :sandbox_exec
      _ -> :none
    end
  end

  @doc """
  Filters `schemas_by_category` for the given OS.

  - `:windows` or `:unknown` → the whole `:sandbox` category is removed.
  - `:macos` → only `sub_category == nil` schemas are kept in `:sandbox`
    (`:resources`/`:process`/`:linux` are dropped — they are consumed only by
    the Linux/systemd-run machinery).
  - `:linux` → unchanged.

  Other categories are always untouched. Schemas without a `sub_category` key
  (non-sandbox categories) are unaffected — `Map.get/2` treats them as nil.
  """
  @spec filter_schemas_by_category(map(), os()) :: map()
  def filter_schemas_by_category(schemas_by_category, os) do
    case os do
      os when os in [:windows, :unknown] ->
        Map.delete(schemas_by_category, :sandbox)

      :macos ->
        Map.put(
          schemas_by_category,
          :sandbox,
          filter_macos_sandbox(Map.get(schemas_by_category, :sandbox, []))
        )

      :linux ->
        schemas_by_category
    end
  end

  @doc """
  Returns whether the `nix` binary is available on the given node.

  - Testability override FIRST: `Application.get_env(:evo_dash, :nix_available_override, nil)`
    — when set to a boolean it is returned directly (the injection seam for
    tests, mirroring the `:platform_os_override` seam in `os_for_node/1`).
  - Local node (`current_node` is nil or `node()`) → `EvoGit.Platform.nix_available?/0`.
  - Remote node → `EvoGit.Platform.nix_available?/0` via
    `EvoDash.NodeContext.call_remote/4`. `{:ok, true}` → true; anything else
    (including `{:error, _}`) → false. Degrades conservatively (nix UI hidden
    when the platform cannot be determined), the same stance `os_for_node/1`
    takes by degrading to `:unknown`. Always total — never raises.
  """
  @spec nix_available_for_node(node() | nil) :: boolean()
  def nix_available_for_node(current_node) do
    case Application.get_env(:evo_dash, :nix_available_override, nil) do
      bool when is_boolean(bool) -> bool
      _ -> detect_nix(current_node)
    end
  end

  # Local node — detect from the local VM.
  defp detect_nix(current_node) when current_node in [nil, node()],
    do: EvoGit.Platform.nix_available?()

  # Remote node — resolve via a cross-node RPC. No try/rescue needed:
  # `EvoDash.NodeContext.call_remote/4` is total (`EvoGit.RemoteNode.call_remote/4`
  # catches everything at the erpc boundary) and returns `{:ok, _} | {:error, _}`.
  defp detect_nix(current_node) do
    case EvoDash.NodeContext.call_remote(current_node, EvoGit.Platform, :nix_available?, []) do
      {:ok, true} -> true
      _ -> false
    end
  end

  @doc """
  Whether `[nix] enabled` is explicitly set in a raw user-config map.

  Pure predicate over the RAW `EvoGit.Config.user_config/0` output — NEVER the
  merged `resolve()`/`defaults()` result (the schema default for
  `[:nix, :enabled]` is `false`, so an absent key and an explicit `false` are
  indistinguishable after merge; only a raw read can tell whether the user
  actually configured the section).

  Checks BOTH the atom-keyed path (`[:nix, :enabled]`) and the string-keyed
  path (`["nix", "enabled"]`): `TomlElixir.decode` returns STRING keys, so the
  raw map is string-keyed in practice, but atom-keyed maps (e.g. if a caller
  passes an atomized map) are handled as well. An explicit `true` OR `false`
  keeps the section visible; an absent key (or a present `[nix]` table without
  an `enabled` key) returns false. Never raises — `get_in/2` returns nil for
  missing paths.
  """
  @spec nix_enabled_explicitly?(map()) :: boolean()
  def nix_enabled_explicitly?(user_config) do
    get_in(user_config, [:nix, :enabled]) != nil or
      get_in(user_config, ["nix", "enabled"]) != nil
  end

  # Whether `[nix] enabled` is explicitly set for the given node.
  #
  # Local node → the raw local user config. Remote node → the REMOTE machine's
  # raw config via `EvoDash.NodeContext.call_remote/4` (correct semantics: we
  # configure the remote VM, so we must read the remote machine's config.toml).
  # `EvoGit.Config.user_config/0` never raises (returns `%{}` on unreadable),
  # so no try/rescue is needed.
  defp nix_enabled_explicitly_for_node(current_node) when current_node in [nil, node()] do
    nix_enabled_explicitly?(EvoGit.Config.user_config())
  end

  defp nix_enabled_explicitly_for_node(current_node) do
    case EvoDash.NodeContext.call_remote(current_node, EvoGit.Config, :user_config, []) do
      {:ok, raw} when is_map(raw) -> nix_enabled_explicitly?(raw)
      _ -> false
    end
  end

  @doc """
  Whether the Nix settings category should be shown for the given node.

  Shown when EITHER the `nix` binary is available on the node OR the user has
  explicitly configured `[nix] enabled` in the raw config file (an explicit
  `false` still counts as "configured" — the section must stay editable so the
  user can turn the feature on). Hidden only when the nix binary is missing
  AND the raw config says nothing about `[nix] enabled`.
  """
  @spec show_nix_category?(node() | nil) :: boolean()
  def show_nix_category?(current_node) do
    nix_available_for_node(current_node) or nix_enabled_explicitly_for_node(current_node)
  end

  @doc """
  Filters `schemas_by_category` for the Nix category on the given node.

  When `show_nix_category?/1` is false (nix binary missing AND `[nix] enabled`
  not explicitly configured in the raw user config), the whole `:nix` category
  is removed — hiding it from the sidebar, the collapsible section, and search
  results alike. Otherwise the map is returned unchanged.
  """
  @spec filter_nix_category(map(), node() | nil) :: map()
  def filter_nix_category(schemas_by_category, current_node) do
    if show_nix_category?(current_node) do
      schemas_by_category
    else
      Map.delete(schemas_by_category, :nix)
    end
  end

  defp filter_macos_sandbox(schemas) do
    Enum.filter(schemas, &(Map.get(&1, :sub_category) == nil))
  end
end
