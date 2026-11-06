defmodule EvoGit.Agent.Tools.ElixirEval.BoundedIO do
  @moduledoc """
  Dedicated, bounded group leader for approved native evaluation.

  Supports character writes, not input, file operations or arbitrary IO MFA callbacks.
  It never uses StringIO, evaluates supplied code or invokes an attacker-supplied MFA.
  The evaluator's process-tree guardian also owns this process; its own owner monitor
  covers a worker dying while blocked in IO.
  """
  alias EvoGit.Agent.Tools.ElixirEval.Render

  def start(cap) do
    owner = self()

    pid =
      :erlang.spawn_opt(
        fn -> loop(%{owner: Process.monitor(owner), cap: cap, size: 0, chunks: []}) end,
        max_heap_size: %{
          size: 1_000_000,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        }
      )

    {:ok, pid}
  end

  def output(pid) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:output, self(), ref})

    receive do
      {^ref, binary} ->
        Process.demonitor(monitor, [:flush])
        {:ok, binary}

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :unavailable}
    after
      1_000 ->
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  def stop(pid), do: Process.exit(pid, :kill)

  defp loop(state) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, state} = request(request, state)
        send(from, {:io_reply, reply_as, reply})
        loop(state)

      {:output, from, ref} ->
        send(from, {ref, IO.iodata_to_binary(Enum.reverse(state.chunks))})
        loop(state)

      {:DOWN, ref, :process, _, _} when ref == state.owner ->
        :ok

      _ ->
        loop(state)
    end
  end

  defp request({:put_chars, encoding, chars}, state) when encoding in [:unicode, :latin1],
    do: put_chars(chars, encoding, state)

  defp request({:put_chars, chars}, state), do: put_chars(chars, :latin1, state)
  defp request(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp request({:requests, requests}, state) when is_list(requests), do: requests(requests, state)
  defp request(_, state), do: {{:error, :enotsup}, state}

  defp requests([], state), do: {:ok, state}

  defp requests([head | tail], state) do
    case request(head, state) do
      {:ok, state} -> requests(tail, state)
      other -> other
    end
  end

  # IO data is untrusted even on the sudo path; conversion errors are normal IO errors.
  defp put_chars(chars, encoding, state) do
    try do
      case :unicode.characters_to_binary(chars, encoding, :utf8) do
        binary when is_binary(binary) -> append(binary, state)
        _ -> {{:error, :put_chars}, state}
      end
    rescue
      ArgumentError -> {{:error, :put_chars}, state}
    end
  end

  defp append(binary, state) do
    remaining = max(state.cap - state.size, 0)
    chunk = Render.text(binary, remaining)
    chunks = if chunk == "", do: state.chunks, else: [chunk | state.chunks]
    state = %{state | size: state.size + byte_size(chunk), chunks: chunks}
    reply = if byte_size(binary) > remaining, do: {:error, :enospc}, else: :ok
    {reply, state}
  end
end
