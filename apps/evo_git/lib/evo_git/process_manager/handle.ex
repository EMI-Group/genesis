defmodule EvoGit.ProcessManager.Handle do
  @moduledoc """
  Normalized OS handle for one tracked execution.

  `EvoGit.ProcessManager` tracks WHAT an agent/task is running; this struct
  describes HOW that execution is anchored to the operating system, so the
  control layer (`EvoGit.ProcessManager.Control`) never has to branch on the
  legacy, backend-shaped maps that `EvoGit.Sandbox.Background` returns
  (`%{kind: :unit, …}` / `%{kind: :port, …}`). `normalize/1` converts either
  form into ONE struct, and everything downstream — stats probes, signals,
  kills — reads only these fields.

  ## Kinds

    * `:systemd_unit` — a transient systemd USER unit (`systemd-run`). Control
      runs through `systemctl --user …`, `unit` names the unit and `port` (when
      present) is the `systemd-run --wait` observer port.
    * `:posix` — a raw process on Linux/macOS, addressed by `os_pid` and
      optionally a `pgid` (process group) that owns the whole sandbox tree.
    * `:windows` — a raw process on Windows, addressed by `os_pid`; tree kills
      go through `taskkill /T /F`.

  ## Fields

    * `:kind` — the addressing mode above (never nil for a valid handle).
    * `:os_pid` — the OS process id, when known.
    * `:pgid` — the process group id, when known (a sandboxed tree leader).
      Kept here rather than on `EvoGit.ProcessManager.Execution` because the
      execution record models the AGENT-visible identity, not OS addressing.
    * `:unit` — the systemd unit name, for `:systemd_unit`.
    * `:backend` — the sandbox backend module that produced the handle (e.g.
      `EvoGit.Sandbox.Linux`), kept for diagnostics only.
    * `:port` — the observer port, kept open/owned by whoever spawned it.
    * `:pending_exit_code` — an exit status the backend already observed for
      the handle (systemd `--wait` clients report it), recorded on the
      execution when the handle is killed/finished.
  """

  @type kind :: :systemd_unit | :posix | :windows
  @type t :: %__MODULE__{
          kind: kind() | nil,
          os_pid: integer() | nil,
          pgid: integer() | nil,
          unit: String.t() | nil,
          backend: atom() | nil,
          port: port() | nil,
          pending_exit_code: integer() | nil
        }

  defstruct kind: nil,
            os_pid: nil,
            pgid: nil,
            unit: nil,
            backend: nil,
            port: nil,
            pending_exit_code: nil

  @doc """
  Builds a handle from a kind and an attribute list/map.
  """
  @spec new(kind(), keyword() | map()) :: t()
  def new(kind, attrs \\ [])

  def new(kind, attrs) when is_list(attrs), do: new(kind, Map.new(attrs))

  def new(kind, attrs) when is_map(attrs) do
    %__MODULE__{
      kind: kind,
      os_pid: get_int(attrs, :os_pid),
      pgid: get_int(attrs, :pgid),
      unit: get_string(attrs, :unit),
      backend: Map.get(attrs, :backend),
      port: Map.get(attrs, :port),
      pending_exit_code: get_int(attrs, :pending_exit_code)
    }
  end

  @doc "A `:posix` handle for a raw Linux/macOS process (optionally in `pgid`)."
  @spec posix(integer() | nil, keyword() | map()) :: t()
  def posix(os_pid, attrs \\ []), do: new(:posix, Map.new(attrs) |> Map.put(:os_pid, os_pid))

  @doc "A `:windows` handle for a raw Windows process."
  @spec windows(integer() | nil, keyword() | map()) :: t()
  def windows(os_pid, attrs \\ []),
    do: new(:windows, Map.new(attrs) |> Map.put(:os_pid, os_pid))

  @doc "A `:systemd_unit` handle for a transient systemd user unit."
  @spec systemd_unit(String.t(), keyword() | map()) :: t()
  def systemd_unit(unit, attrs \\ []),
    do: new(:systemd_unit, Map.new(attrs) |> Map.put(:unit, unit))

  @doc """
  Normalizes a `%Handle{}` (returned as-is) or a LEGACY backend handle map into
  `{:ok, %Handle{}}`.

  Legacy shapes understood — exactly what `EvoGit.Sandbox.Background.spawn/1`
  answers:

    * `%{kind: :unit, unit: unit, backend: mod, port: port, …}` →
      `%Handle{kind: :systemd_unit, …}`
    * `%{kind: :port, port: port, os_pid: pid, backend: mod}` →
      `%Handle{kind: :posix | :windows, …}` (Windows when the platform is
      Windows, otherwise POSIX)

  Anything else is `{:error, :invalid_handle}` — never an exception, so a
  caller with an unexpected backend handle degrades instead of crashing.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, :invalid_handle}
  def normalize(%__MODULE__{kind: kind} = handle) when kind in [:systemd_unit, :posix, :windows],
    do: {:ok, handle}

  def normalize(%__MODULE__{kind: :unit} = handle),
    do: {:ok, %{handle | kind: :systemd_unit}}

  def normalize(%__MODULE__{kind: :port} = handle),
    do: {:ok, %{handle | kind: legacy_port_kind()}}

  def normalize(%{} = map) do
    case legacy_kind(map) do
      nil ->
        {:error, :invalid_handle}

      kind ->
        {:ok,
         new(kind,
           os_pid: Map.get(map, :os_pid),
           pgid: Map.get(map, :pgid),
           unit: Map.get(map, :unit),
           backend: Map.get(map, :backend),
           port: Map.get(map, :port),
           pending_exit_code: Map.get(map, :pending_exit_code)
         )}
    end
  end

  def normalize(_handle), do: {:error, :invalid_handle}

  @doc """
  Maps the sandbox backend MODULE carried on a legacy handle to the execution's
  `backend` vocabulary (`:systemd | :bwrap | :sandbox_exec | :none`).
  Returns `nil` for an unknown/absent module, so the caller keeps whatever it
  already recorded.
  """
  @spec execution_backend(t() | nil) :: :systemd | :bwrap | :sandbox_exec | :none | nil
  def execution_backend(%__MODULE__{backend: nil}), do: nil
  def execution_backend(%__MODULE__{backend: backend}), do: backend_atom(backend)
  def execution_backend(_handle), do: nil

  @doc """
  The pid a control operation should target: the OS pid, falling back to the
  process-group id when only that is known.
  """
  @spec target_pid(t() | nil) :: integer() | nil
  def target_pid(%__MODULE__{os_pid: pid}) when is_integer(pid), do: pid
  def target_pid(%__MODULE__{pgid: pgid}) when is_integer(pgid), do: pgid
  def target_pid(_handle), do: nil

  ## Internal

  defp legacy_kind(%{kind: :unit}), do: :systemd_unit
  defp legacy_kind(%{kind: :systemd_unit}), do: :systemd_unit
  defp legacy_kind(%{kind: :posix}), do: :posix
  defp legacy_kind(%{kind: :windows}), do: :windows
  defp legacy_kind(%{kind: :port}), do: legacy_port_kind()
  defp legacy_kind(_map), do: nil

  defp legacy_port_kind do
    if EvoGit.Platform.windows?(), do: :windows, else: :posix
  end

  defp backend_atom(EvoGit.Sandbox.Linux), do: :systemd
  defp backend_atom(EvoGit.Sandbox.Bwrap), do: :bwrap
  defp backend_atom(EvoGit.Sandbox.MacOS), do: :sandbox_exec
  defp backend_atom(EvoGit.Sandbox.None), do: :none
  defp backend_atom(atom) when atom in [:systemd, :bwrap, :sandbox_exec, :none], do: atom
  defp backend_atom(_backend), do: nil

  defp get_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
