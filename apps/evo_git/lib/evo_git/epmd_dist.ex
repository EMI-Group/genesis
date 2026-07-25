defmodule EvoGit.EpmdDist do
  @moduledoc """
  Custom EPMD-less distribution module for Erlang distribution.

  Implements the `erl_epmd` behaviour so the VM uses this module instead of
  the external `epmd` daemon. This enables distribution over SSH tunnels
  without requiring EPMD.

  ## How it works

  The VM references this module via `-epmd_module Elixir.EvoGit.EpmdDist` in
  vm.args. When the local dashboard wants to connect to a remote daemon, it:
  1. Opens an SSH tunnel mapping a local port → remote daemon's port 9000
  2. Calls `register_target("genesis_remote@127.0.0.1", local_port)` to tell
     EpmdDist which port to use for that node name
  3. Calls `Node.connect(:"genesis_remote@127.0.0.1")` — the VM calls
     `port_please/2` which returns the registered port

  The remote daemon side uses `register_node/3` at boot to register its own
  listen port (9000).

  ## Registry

  Uses `:persistent_term` as the node→port registry. This is ideal for
  read-heavy, rarely-written data — `port_please/2` is called on every
  distribution connection attempt, while registrations happen only at boot
  or when a user initiates a remote connection.

  ## erl_epmd interface

  This module follows the `erl_epmd` interface (callbacks: `start_link/0`,
  `register_node/3`, `port_please/2`, `names/1`) that the VM calls when
  `-epmd_module Elixir.EvoGit.EpmdDist` is set in vm.args. The Erlang
  `:erl_epmd` module does not export `@callback` attributes, so we cannot
  use `@behaviour :erl_epmd` — the function heads must simply match the
  expected signature.
  """

  @doc false
  def start_link, do: :ignore

  @doc false
  def port_please(node_name, _host) do
    # The VM's distribution layer splits the node name at @ and calls this
    # callback with just the name part (before @). The argument type varies
    # by OTP version and calling context (string, charlist, or atom), so
    # normalize it before lookup.
    normalized = normalize_node_name(node_name)

    case :persistent_term.get({:evogit_epmd, normalized}, nil) do
      nil -> :noport
      port -> {:port, port, 5}
    end
  end

  @doc false
  def names(_host) do
    {:ok, []}
  end

  @doc false
  def register_node(node_name, _port_no, _drv_data) do
    # When the local node registers itself at VM boot, store its own listen
    # port. We read the actual distribution listen port from the kernel
    # application env (set to 9100-9200 range in vm.args for the local side).
    #
    # The VM calls this with just the node's name part (before @), so
    # normalize to be safe regardless of the input form.
    listen_port = Application.get_env(:kernel, :inet_dist_listen_min, 9100)
    normalized = normalize_node_name(node_name)
    :persistent_term.put({:evogit_epmd, normalized}, listen_port)
    {:ok, 0}
  end

  @doc """
  Registers a remote node's SSH tunnel port so that `port_please/2` can
  resolve it when `Node.connect/1` is called.

  Called by `EvoGit.RemoteConnection` after opening the SSH tunnel and
  before `Node.connect/1`.

  ## Parameters
  - `node_string` — the remote node name as a string (e.g. `"genesis_remote@127.0.0.1"`)
  - `port` — the local port that the SSH tunnel listens on (maps to the remote daemon's port)
  """
  @spec register_target(String.t(), non_neg_integer()) :: :ok
  def register_target(node_string, port) do
    # Extract the name part before @ — the VM's port_please callback receives
    # just the name part, not the full "name@host". Store under both the short
    # name and the full name (as atoms) for robustness.
    short_name = node_string |> String.split("@") |> List.first() |> String.to_atom()
    full_atom = String.to_atom(node_string)

    :persistent_term.put({:evogit_epmd, short_name}, port)
    :persistent_term.put({:evogit_epmd, full_atom}, port)
    :ok
  end

  @doc """
  Removes a node from the port registry. Called on disconnect.

  Safe to call even if the node was never registered — checks existence
  before erasing (avoids the `ArgumentError` that `:persistent_term.erase/1`
  raises for missing keys).
  """
  @spec unregister_target(String.t()) :: :ok
  def unregister_target(node_string) do
    short_name = node_string |> String.split("@") |> List.first() |> String.to_atom()
    full_atom = String.to_atom(node_string)

    erase_if_exists({:evogit_epmd, short_name})
    erase_if_exists({:evogit_epmd, full_atom})
    :ok
  end

  @doc false
  defp erase_if_exists(key) do
    if :persistent_term.get(key, nil) != nil do
      :persistent_term.erase(key)
    end
  end

  # Normalize any input form (string, charlist, atom) to an atom of just the
  # name part (before @). The VM may pass the node name in any of these forms
  # depending on OTP version and calling context.
  defp normalize_node_name(node_name) when is_atom(node_name),
    do: normalize_node_name(Atom.to_string(node_name))

  defp normalize_node_name(node_name) when is_list(node_name),
    do: normalize_node_name(to_string(node_name))

  defp normalize_node_name(node_name) when is_binary(node_name),
    do: node_name |> String.split("@") |> List.first() |> String.to_atom()
end
