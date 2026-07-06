defmodule EvoGit.Runtime.Evolution.SeedFragments.Generators.WebProtocols do
  @moduledoc """
  Web and protocol-oriented seed fragments: HTTP handlers, binary encoding, and middleware chains.
  """

  alias EvoGit.Runtime.Evolution.Fragment

  def http_handler_fragment do
    Fragment.new(
      ~S"""
      defmodule HTTPHandler do
        @moduledoc "HTTP request handler with pattern matching on routes."

        defstruct method: :get, path: "/", headers: %{}, body: "", params: %{}

        def handle(%__MODULE__{method: :get, path: "/api/users"} = req) do
          users = list_users(req.params)
          json_response(200, %{users: users, count: length(users)})
        end

        def handle(%__MODULE__{method: :get, path: "/api/users/" <> id} = _req) do
          case find_user(id) do
            nil -> json_response(404, %{error: "User not found"})
            user -> json_response(200, user)
          end
        end

        def handle(%__MODULE__{method: :post, path: "/api/users", body: body} = _req) do
          with {:ok, params} <- parse_body(body),
               :ok <- validate_user_params(params) do
            user = create_user(params)
            json_response(201, user)
          else
            {:error, :invalid_json} -> json_response(400, %{error: "Invalid JSON"})
            {:error, {:missing_field, f}} -> json_response(422, %{error: "Missing field: #{f}"})
          end
        end

        def handle(%__MODULE__{method: :delete, path: "/api/users/" <> id} = _req) do
          case delete_user(id) do
            :ok -> json_response(200, %{deleted: true})
            {:error, :not_found} -> json_response(404, %{error: "Not found"})
          end
        end

        def handle(%__MODULE__{method: :get, path: "/health"} = _req) do
          json_response(200, %{status: "ok", timestamp: System.system_time(:second)})
        end

        def handle(%__MODULE__{path: path} = _req) do
          json_response(404, %{error: "No route matches #{path}"})
        end

        def json_response(status, body) do
          %{status: status, headers: %{"content-type" => "application/json"}, body: Jason.encode!(body)}
        end

        def list_users(%{"role" => role}), do: Enum.filter(mock_users(), &(&1.role == role))
        def list_users(_params), do: mock_users()

        def find_user(id), do: Enum.find(mock_users(), &(&1.id == id))
        def delete_user(id), do: if(find_user(id), do: :ok, else: {:error, :not_found})

        def create_user(params), do: Map.put(params, "id", generate_id())
        def generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

        def validate_user_params(params) do
          required = ["name", "email"]
          missing = Enum.reject(required, &Map.has_key?(params, &1))
          if missing == [], do: :ok, else: {:error, {:missing_field, hd(missing)}}
        end

        def parse_body(body) do
          case Jason.decode(body) do
            {:ok, _} = ok -> ok
            {:error, _} -> {:error, :invalid_json}
          end
        end

        def mock_users do
          [%{id: "a1", name: "Alice", role: "admin"}, %{id: "b2", name: "Bob", role: "user"}]
        end
      end
      """,
      language: "elixir",
      domain: "http_handler"
    )
  end

  def encoding_fragment do
    Fragment.new(
      ~S"""
      defmodule Encoding.BinaryProtocol do
        @moduledoc "Custom binary serialization and deserialization."

        @type tag :: :uint8 | :uint16 | :uint32 | :string | :bool | :float64 | :list | :map

        def serialize(data) when is_integer(data) and data >= 0 and data <= 255, do: <<1, data::unsigned-8>>
        def serialize(data) when is_integer(data) and data >= 0 and data <= 65535, do: <<2, data::unsigned-big-16>>
        def serialize(data) when is_integer(data) and data >= 0, do: <<3, data::unsigned-big-32>>
        def serialize(data) when is_integer(data), do: <<4, data::signed-big-64>>
        def serialize(data) when is_binary(data) do
          len = byte_size(data)
          <<5, len::unsigned-big-16, data::binary>>
        end
        def serialize(true), do: <<6, 1>>
        def serialize(false), do: <<6, 0>>
        def serialize(data) when is_float(data), do: <<7, data::float-big-64>>
        def serialize(data) when is_atom(data), do: serialize(Atom.to_string(data))
        def serialize(data) when is_list(data) do
          encoded = Enum.map(data, &serialize/1)
          len = length(encoded)
          iolist = [<<8, len::unsigned-big-16>> | encoded]
          IO.iodata_to_binary(iolist)
        end
        def serialize(data) when is_map(data) do
          entries = Enum.map(data, fn {k, v} -> [serialize(k), serialize(v)] end)
          len = map_size(data)
          IO.iodata_to_binary([<<9, len::unsigned-big-16>> | List.flatten(entries)])
        end
        def serialize(nil), do: <<0>>

        def deserialize(<<0, rest::binary>>), do: {:ok, nil, rest}
        def deserialize(<<1, val::unsigned-8, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<2, val::unsigned-big-16, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<3, val::unsigned-big-32, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<4, val::signed-big-64, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<5, len::unsigned-big-16, str::binary-size(len), rest::binary>>) do
          {:ok, str, rest}
        end
        def deserialize(<<6, 1, rest::binary>>), do: {:ok, true, rest}
        def deserialize(<<6, 0, rest::binary>>), do: {:ok, false, rest}
        def deserialize(<<7, val::float-big-64, rest::binary>>), do: {:ok, val, rest}
        def deserialize(<<8, count::unsigned-big-16, rest::binary>>) do
          deserialize_list(rest, count, [])
        end
        def deserialize(<<9, count::unsigned-big-16, rest::binary>>) do
          deserialize_map(rest, count, %{})
        end
        def deserialize(_), do: {:error, :invalid_data}

        def deserialize_list(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
        def deserialize_list(data, count, acc) do
          with {:ok, val, rest} <- deserialize(data) do
            deserialize_list(rest, count - 1, [val | acc])
          end
        end

        def deserialize_map(rest, 0, acc), do: {:ok, acc, rest}
        def deserialize_map(data, count, acc) do
          with {:ok, key, rest1} <- deserialize(data),
               {:ok, val, rest2} <- deserialize(rest1) do
            deserialize_map(rest2, count - 1, Map.put(acc, key, val))
          end
        end

        def encode!(data), do: serialize(data)
        def decode!(binary) do
          case deserialize(binary) do
            {:ok, value, ""} -> value
            {:ok, value, rest} -> {value, rest}
            {:error, reason} -> raise "Decode error: #{inspect(reason)}"
          end
        end

        def roundtrip?(data) do
          encoded = serialize(data)
          {:ok, decoded, ""} = deserialize(encoded)
          decoded == data
        end
      end
      """,
      language: "elixir",
      domain: "encoding"
    )
  end

  def middleware_fragment do
    Fragment.new(
      ~S"""
      defmodule Middleware do
        @moduledoc "Plug-like middleware chain with composition."

        defstruct stack: [], handler: nil

        @type next :: (map() -> map())
        @type middleware :: (map(), next -> map())

        def new(handler \\ &Function.identity/1) do
          %__MODULE__{handler: handler}
        end

        def use(%__MODULE__{stack: stack} = mw, middleware) do
          %{mw | stack: stack ++ [middleware]}
        end

        def call(%__MODULE__{stack: stack, handler: handler}, request) do
          chain = Enum.reverse([handler | stack])
          composed = compose(chain)
          composed.(request)
        end

        def compose([final]), do: final
        def compose([mw | rest]) do
          next = compose(rest)
          fn req -> mw.(req, next) end
        end

        # Built-in middlewares

        def logger(request, next) do
          start = System.monotonic_time(:microsecond)
          request = Map.put_new(request, :logs, [])
          response = next.(request)
          elapsed = System.monotonic_time(:microsecond) - start
          log_entry = %{at: elapsed, method: request[:method], path: request[:path]}
          Map.update!(response, :logs, &[log_entry | &1])
        end

        def add_headers(defaults), do: fn request, next ->
          headers = Map.merge(defaults, Map.get(request, :headers, %{}))
          next.(Map.put(request, :headers, headers))
        end

        def require_auth(request, next) do
          case Map.get(request, :auth) do
            nil -> Map.put(request, :status, 401)
            _ -> next.(request)
          end
        end

        def rate_limit(max_rps), do: fn request, next ->
          key = {request[:ip], System.system_time(:second)}
          request = ensure_rate_state(request, key, max_rps)
          state = request[:rate_limit_state]
          if state.count < max_rps do
            response = next.(request)
            Map.put(response, :rate_limit_state, %{state | count: state.count + 1})
          else
            Map.put(request, :status, 429)
          end
        end

        def transform_response(transformer) do
          fn request, next ->
            response = next.(request)
            transformer.(response)
          end
        end

        def ensure_rate_state(request, key, max_rps) do
          state = Map.get(request, :rate_limit_state, %{key: key, count: 0, max: max_rps})
          if state.key != key, do: Map.put(request, :rate_limit_state, %{key: key, count: 0, max: max_rps}), else: request
        end
      end
      """,
      language: "elixir",
      domain: "middleware"
    )
  end
end
