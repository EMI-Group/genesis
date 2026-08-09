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

  defp filter_macos_sandbox(schemas) do
    Enum.filter(schemas, &(Map.get(&1, :sub_category) == nil))
  end
end
