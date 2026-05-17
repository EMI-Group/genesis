defmodule EvoGit.Cluster.FilePullerTest do
  use ExUnit.Case, async: true

  alias EvoGit.Cluster.FilePuller

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_file_puller_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "do_remote_read/2" do
    test "reads source file and writes content to local IO device", %{tmp_dir: tmp_dir} do
      src_path = Path.join(tmp_dir, "source.txt")
      dest_path = Path.join(tmp_dir, "dest.txt")
      content = "Hello, this is test content from the remote node!\nSecond line here.\n"

      # Create the source file (simulating the remote file)
      File.write!(src_path, content)

      # Open local destination for writing (simulating local_io from pull/4)
      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      try do
        # Call the public function that runs on the remote node
        assert :ok = FilePuller.do_remote_read(src_path, local_io)
      after
        File.close(local_io)
      end

      # Verify the destination file has the correct content
      assert File.read!(dest_path) == content
    end

    test "returns {:error, :enoent} when source file does not exist", %{tmp_dir: tmp_dir} do
      dest_path = Path.join(tmp_dir, "dest.txt")
      nonexistent_path = Path.join(tmp_dir, "nonexistent.txt")

      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      result =
        try do
          FilePuller.do_remote_read(nonexistent_path, local_io)
        after
          File.close(local_io)
        end

      assert {:error, :enoent} = result
    end

    test "handles empty source files correctly", %{tmp_dir: tmp_dir} do
      src_path = Path.join(tmp_dir, "empty_source.txt")
      dest_path = Path.join(tmp_dir, "empty_dest.txt")

      # Create an empty source file
      File.write!(src_path, "")

      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      try do
        assert :ok = FilePuller.do_remote_read(src_path, local_io)
      after
        File.close(local_io)
      end

      # Destination should also be empty
      assert File.read!(dest_path) == ""
    end
  end

  describe "pull/4 failure cases" do
    test "returns {:error, :enoent} when local parent directory does not exist" do
      local_path = "/tmp/evo_git_nonexistent_dir_xyz123/dest.txt"

      result = FilePuller.pull(:fake_remote@localhost, "/some/source.txt", local_path, 1000)

      assert {:error, :enoent} = result
    end

    test "returns error when local_path is a directory not a file", %{tmp_dir: tmp_dir} do
      result = FilePuller.pull(:fake_remote@localhost, "/some/source.txt", tmp_dir, 1000)

      # File.open with :exclusive on a directory returns {:error, :eisdir}
      # or could be :eacces depending on OS — just verify it's an error tuple
      assert {:error, _reason} = result
    end
  end

  describe "chunked streaming via do_remote_read/2" do
    test "correctly streams files larger than the 1MB chunk size", %{tmp_dir: tmp_dir} do
      src_path = Path.join(tmp_dir, "large_source.bin")
      dest_path = Path.join(tmp_dir, "large_dest.bin")

      # Create ~2.5 MB of data with a repeating byte pattern for easy verification
      # Each chunk is 256 bytes, repeated 10,240 times = 2,621,440 bytes (~2.5 MB)
      pattern = :crypto.strong_rand_bytes(256)
      chunk_count = 10_240
      expected_size = 256 * chunk_count

      # Build and write the source file
      File.open(src_path, [:write, :binary], fn io ->
        Enum.each(1..chunk_count, fn _ ->
          IO.binwrite(io, pattern)
        end)
      end)

      # Verify source file size
      src_stat = File.stat!(src_path)
      assert src_stat.size == expected_size

      # Perform the remote read
      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      try do
        assert :ok = FilePuller.do_remote_read(src_path, local_io)
      after
        File.close(local_io)
      end

      # Verify destination file size matches
      dest_stat = File.stat!(dest_path)
      assert dest_stat.size == expected_size

      # Spot-check: the destination should match the source exactly
      assert File.read!(dest_path) == File.read!(src_path)
    end

    test "correctly streams files at exact chunk size boundary (1MB)", %{tmp_dir: tmp_dir} do
      src_path = Path.join(tmp_dir, "exact_mb_source.bin")
      dest_path = Path.join(tmp_dir, "exact_mb_dest.bin")

      # Create exactly 1 MB (1,048,576 bytes) — right at the chunk boundary
      exact_chunk_size = 1024 * 1024
      data = :crypto.strong_rand_bytes(exact_chunk_size)

      File.write!(src_path, data)

      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      try do
        assert :ok = FilePuller.do_remote_read(src_path, local_io)
      after
        File.close(local_io)
      end

      assert File.read!(dest_path) == data
      assert byte_size(File.read!(dest_path)) == exact_chunk_size
    end

    test "correctly streams files just over the 1MB chunk boundary", %{tmp_dir: tmp_dir} do
      src_path = Path.join(tmp_dir, "over_mb_source.bin")
      dest_path = Path.join(tmp_dir, "over_mb_dest.bin")

      # Create 1 MB + 1 byte — just over the chunk boundary (tests edge of the loop)
      chunk_size = 1024 * 1024
      data = :crypto.strong_rand_bytes(chunk_size + 1)

      File.write!(src_path, data)

      {:ok, local_io} = File.open(dest_path, [:write, :exclusive, :binary])

      try do
        assert :ok = FilePuller.do_remote_read(src_path, local_io)
      after
        File.close(local_io)
      end

      assert File.read!(dest_path) == data
      assert byte_size(File.read!(dest_path)) == chunk_size + 1
    end
  end
end
