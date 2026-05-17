defmodule EvoGit.Cluster.FilePuller do
  @moduledoc """
  Safely pulls a file from a remote node to the local node using Erlang Distribution.

  Uses `:erpc.call/4` to execute read operations on the remote node and stream
  the file contents back to the local node in chunks.
  """

  @chunk_size 1024 * 1024

  @doc """
  Pulls `remote_path` from `remote_node` and saves it to `local_path`.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Parameters

    * `remote_node` - the remote Erlang node to pull from
    * `remote_path` - the absolute path on the remote node
    * `local_path` - the absolute path to save the file locally
    * `timeout` - timeout in milliseconds for the operation (default: 15 minutes)

  ## Examples

      iex> FilePuller.pull(:remote@host, "/tmp/source.txt", "/tmp/dest.txt")
      :ok

      iex> FilePuller.pull(:remote@host, "/tmp/nonexistent.txt", "/tmp/dest.txt")
      {:error, :enoent}

  """
  def pull(remote_node, remote_path, local_path, timeout \\ :timer.minutes(15)) do
    case File.open(local_path, [:write, :exclusive, :binary]) do
      {:ok, local_io} ->
        task =
          Task.async(fn ->
            :erpc.call(remote_node, __MODULE__, :do_remote_read, [remote_path, local_io], timeout)
          end)

        result =
          try do
            Task.await(task, timeout)
          catch
            :exit, {:timeout, {Task, :await, [_task, ^timeout]}} ->
              {:error, :timeout}

            :exit, _other ->
              {:error, :erpc_failure}
          end

        File.close(local_io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def do_remote_read(remote_path, local_io) do
    case File.open(remote_path, [:read, :binary]) do
      {:ok, remote_io} ->
        result = stream_chunks(remote_io, local_io)
        File.close(remote_io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reads the file in chunks from remote_io and writes each chunk
  # to local_io via IO.binwrite/2. Since local_io is a PID from the
  # calling node, IO.binwrite sends the data back across the erpc connection.
  defp stream_chunks(remote_io, local_io) do
    case IO.binread(remote_io, @chunk_size) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      data when is_binary(data) ->
        case IO.binwrite(local_io, data) do
          :ok ->
            stream_chunks(remote_io, local_io)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
