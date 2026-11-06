defmodule EvoGit.Agent.Tools.ElixirEval.RenderTest do
  @moduledoc "Async-safe pure rendering: UTF-8 validity, byte ceilings and bounded inspection."
  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.ElixirEval.Render

  @marker "\n[output truncated]"

  describe "text/2" do
    test "preserves fitting text byte-for-byte, including whitespace and empty input" do
      for input <- ["", " a\n\t", "é你好🙂", "a" <> <<0>> <> "b"] do
        assert Render.text(input, byte_size(input)) == input
        assert Render.text(input, byte_size(input) + 20) == input
      end

      assert Render.text("anything", 0) == ""
      assert Render.text("", 0) == ""
    end

    test "marker is included in the cap only when it fits" do
      input = String.duplicate("a", 100)
      marker_size = byte_size(@marker)
      assert Render.text(input, marker_size - 1) == String.duplicate("a", marker_size - 1)
      assert Render.text(input, marker_size) == @marker
      assert Render.text(input, marker_size + 1) == "a" <> @marker
      assert Render.text(input, 100) == input
    end

    test "every cap keeps a valid UTF-8 prefix and never splits a multibyte codepoint" do
      input = String.duplicate("aé你🙂", 20)

      for cap <- 0..(byte_size(input) + 1) do
        output = Render.text(input, cap)
        assert String.valid?(output)
        assert byte_size(output) <= cap

        prefix =
          if byte_size(input) > cap and cap >= byte_size(@marker) do
            assert String.ends_with?(output, @marker)
            binary_part(output, 0, byte_size(output) - byte_size(@marker))
          else
            output
          end

        assert String.starts_with?(input, prefix)
      end

      assert Render.text("éx", 1) == ""
      assert Render.text("a你x", 3) == "a"
      assert Render.text("🙂x", 4) == "🙂"
    end

    test "malformed and incomplete UTF-8 never escapes through the text channel" do
      for invalid <- [<<255>>, "safe" <> <<255>> <> "hidden", "safe" <> <<0xE2, 0x82>>] do
        for cap <- [0, 1, 5, 20, 100] do
          output = Render.text(invalid, cap)
          assert String.valid?(output)
          assert byte_size(output) <= cap
          refute output =~ "hidden"
        end
      end

      assert Render.text("safe" <> <<255>> <> "hidden", 100) == "safe"
    end

    test "small output does not retain the backing megabyte binary" do
      backing = String.duplicate("a", 1_000_000)
      slice = binary_part(backing, 0, 1_000)
      output = Render.text(slice, 100)
      assert byte_size(output) == 100
      # Concatenating the marker may leave a small writable-binary reserve;
      # it must not retain either the input slice or its megabyte backing store.
      assert :binary.referenced_byte_size(output) < byte_size(slice)

      fitting = Render.text(slice, 2_000)
      assert fitting == slice
      assert :binary.referenced_byte_size(fitting) == byte_size(fitting)
    end
  end

  describe "term/2" do
    test "renders charlists as lists and structs as maps instead of custom display" do
      assert Render.term(~c"abc", 1_000) == "[97, 98, 99]"
      rendered = Render.term(URI.parse("https://example.org/path"), 2_000)
      assert rendered =~ "__struct__: URI"
      assert rendered =~ "host: \"example.org\""
      refute rendered =~ "%URI{"
    end

    test "limits collection inspection to 100 entries" do
      rendered = Render.term(Enum.to_list(1..1_000), 65_536)
      assert rendered =~ "100, ..."
      refute rendered =~ "101,"
      refute rendered =~ "1000"
    end

    test "printable binaries have a 2048-character inspection limit even with a larger output cap" do
      rendered = Render.term(String.duplicate("x", 10_000), 65_536)
      assert rendered =~ "<> ..."
      refute rendered =~ String.duplicate("x", 2_049)
      assert byte_size(rendered) < 3_000
    end

    test "nested terms, invalid binaries and multibyte values obey byte caps" do
      for value <- [
            %{text: String.duplicate("你🙂", 1_000)},
            Enum.map(1..150, &%{entry: &1}),
            <<255, 0, 254>>,
            {:error, String.duplicate("é", 100)}
          ],
          cap <- [0, 1, 2, 17, 18, 19, 20, 63, 128, 2_048] do
        output = Render.term(value, cap)
        assert is_binary(output)
        assert String.valid?(output)
        assert byte_size(output) <= cap
      end
    end
  end
end

defmodule EvoGit.Agent.Tools.ElixirEval.BoundedIOTest do
  @moduledoc """
  Async-safe native IO protocol tests with private, unregistered processes.
  No evaluator, broker, authorization, approval or app-global state is involved.
  """
  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.ElixirEval.{BoundedIO, Render}

  describe "native character output" do
    test "supports real IO writes, unicode/latin1 conversion and protocol getopts" do
      io = start_io(100)
      assert IO.write(io, "hello ") == :ok
      assert request(io, {:put_chars, :unicode, [0x4F60, 0x597D]}) == :ok
      assert request(io, {:put_chars, :latin1, <<233>>}) == :ok
      assert request(io, {:put_chars, ~c"!"}) == :ok
      assert request(io, :getopts) == [binary: true, encoding: :unicode]
      assert BoundedIO.output(io) == {:ok, "hello 你好é!"}
      # Reading does not drain the channel or reset its cumulative budget.
      assert BoundedIO.output(io) == {:ok, "hello 你好é!"}
    end

    test "combined writes fit exactly, overflow returns enospc and cannot grow the output" do
      io = start_io(5)
      assert request(io, {:put_chars, :unicode, "abc"}) == :ok
      assert request(io, {:put_chars, :unicode, "de"}) == :ok
      assert request(io, {:put_chars, :unicode, "f"}) == {:error, :enospc}
      assert request(io, {:put_chars, :unicode, "more"}) == {:error, :enospc}
      assert request(io, {:put_chars, :unicode, ""}) == :ok
      assert BoundedIO.output(io) == {:ok, "abcde"}
    end

    test "oversized native writes use the same bounded UTF-8 rendering contract" do
      for cap <- [0, 1, 3, 18, 19, 20, 64] do
        io = start_io(cap)
        input = String.duplicate("你🙂", 100)
        assert request(io, {:put_chars, :unicode, input}) == {:error, :enospc}
        assert {:ok, output} = BoundedIO.output(io)
        assert output == Render.text(input, cap)
        assert String.valid?(output)
        assert byte_size(output) <= cap
      end
    end

    test "bad character data returns a normal IO error and leaves the channel usable" do
      io = start_io(100)
      assert request(io, {:put_chars, :unicode, "before"}) == :ok

      for chars <- [<<255>>, <<0xE2, 0x82>>, [0x110000], {:not, :iodata}, ["valid", %{}]] do
        assert request(io, {:put_chars, :unicode, chars}) == {:error, :put_chars}
      end

      assert request(io, {:put_chars, :unicode, "after"}) == :ok
      assert BoundedIO.output(io) == {:ok, "beforeafter"}
    end

    test "batched requests preserve order and stop at the first unsupported operation" do
      io = start_io(100)
      assert request(io, {:requests, []}) == :ok
      assert request(io, {:requests, [{:put_chars, "a"}, {:put_chars, :unicode, "b"}]}) == :ok

      assert request(
               io,
               {:requests,
                [{:put_chars, "c"}, {:get_line, :unicode, ">"}, {:put_chars, "not written"}]}
             ) ==
               {:error, :enotsup}

      assert BoundedIO.output(io) == {:ok, "abc"}
    end

    test "batch overflow also stops later writes" do
      io = start_io(3)

      assert request(
               io,
               {:requests, [{:put_chars, "ab"}, {:put_chars, "cd"}, {:put_chars, "later"}]}
             ) ==
               {:error, :enospc}

      assert BoundedIO.output(io) == {:ok, "abc"}
    end
  end

  describe "denied IO operations" do
    test "never executes arbitrary MFA callbacks, including callbacks hidden in a batch" do
      io = start_io(100)
      callback = {:put_chars, :unicode, __MODULE__, :unexpected_callback, [self()]}
      legacy_callback = {:put_chars, __MODULE__, :unexpected_callback, [self()]}

      for operation <- [callback, legacy_callback, {:requests, [callback]}] do
        assert request(io, operation) == {:error, :enotsup}
      end

      assert BoundedIO.output(io) == {:ok, ""}
      refute_received :io_callback_executed
    end

    test "refuses input, file requests, unsupported encodings and option changes" do
      io = start_io(100)

      for operation <- [
            {:get_chars, :unicode, ">", 10},
            {:get_line, ">"},
            {:get_until, :unicode, ">", __MODULE__, :unexpected_callback, [self()]},
            {:setopts, [encoding: :latin1]},
            {:open, "secret", [:read]},
            {:position, 0},
            {:put_chars, :utf16, "data"},
            :eof,
            :unknown
          ] do
        assert request(io, operation) == {:error, :enotsup}
      end

      assert BoundedIO.output(io) == {:ok, ""}
      refute_received :io_callback_executed
    end
  end

  describe "process lifetime" do
    test "stop reaps the private IO process and subsequent output reports unavailable" do
      io = start_io(100)
      monitor = Process.monitor(io)
      assert BoundedIO.stop(io) == true
      assert_receive {:DOWN, ^monitor, :process, ^io, :killed}, 5_000
      assert BoundedIO.output(io) == {:error, :unavailable}
    end

    test "owner-monitor teardown follows normal exit and abrupt owner death without stop" do
      observer = self()

      for owner_exit <- [:normal, :killed] do
        {owner, owner_monitor} =
          spawn_monitor(fn ->
            {:ok, io} = BoundedIO.start(100)
            send(observer, {:owned_io, self(), io})

            receive do
              :finish -> :ok
            end
          end)

        on_exit(fn -> Process.exit(owner, :kill) end)
        assert_receive {:owned_io, ^owner, io}, 5_000
        on_exit(fn -> BoundedIO.stop(io) end)
        io_monitor = Process.monitor(io)
        # This reply proves the owner monitor is installed before the owner dies.
        assert request(io, {:put_chars, :unicode, "held by owner"}) == :ok

        if owner_exit == :normal, do: send(owner, :finish), else: Process.exit(owner, :kill)

        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, ^owner_exit}, 5_000
        assert_receive {:DOWN, ^io_monitor, :process, ^io, :normal}, 5_000
        refute Process.alive?(io)
      end
    end
  end

  # This callback is deliberately observable; no rejected MFA request may run it.
  def unexpected_callback(observer) do
    send(observer, :io_callback_executed)
    "secret callback output"
  end

  defp start_io(cap) do
    {:ok, io} = BoundedIO.start(cap)
    on_exit(fn -> BoundedIO.stop(io) end)
    io
  end

  defp request(io, operation) do
    ref = make_ref()
    send(io, {:io_request, self(), ref, operation})
    assert_receive {:io_reply, ^ref, reply}, 5_000
    reply
  end
end
