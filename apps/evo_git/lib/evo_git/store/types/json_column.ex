defmodule EvoGit.Store.Types.JsonColumn do
  @moduledoc """
  `use` macro generating the invariant `Ecto.Type` skeleton of a JSON TEXT column.

  Every JSON column type under `EvoGit.Store.Types` is the same five-function
  `Ecto.Type`: `type/0` is `:string`, `embed_as/1` is `:self`, `equal?/2` is
  `==`, and `cast/1`/`dump/1`/`load/1` differ only by their guard and by which
  module performs the encoding. This macro emits that skeleton ONCE.

  ## Shapes

    * `:strict` — the five `tasks` columns delegated to `EvoGit.Store.Codec`.
      `cast/1` accepts `nil` or a value matching `:cast_guard`; `dump/1` wraps
      `encoder.(value)` in `{:ok, _}` and answers `:error` past the guard;
      `load/1` wraps `decoder.(text)` in `{:ok, _}` and answers `:error` for a
      non-binary stored value — LETTING the Codec's `ArgumentError` propagate
      on non-canonical stored text (that is the Codec's documented contract).
    * `:lenient` — the four `task_agent_archives` columns over
      `EvoGit.Store.Types.ArchiveColumns`. `dump/1` is the encoder's own
      `{:ok, json} | :error` result (it handles `nil`), and `load/1` is TOTAL:
      `{:ok, term}`, so corrupt text loads as `nil` instead of raising.

  ## Options

    * `:shape` (required) — `:strict` | `:lenient`.
    * `:cast_guard` — the guard expression over `value`, e.g. `is_list(value)`
      or `is_map(value) or is_list(value)`. A `use` argument is never
      evaluated, so this is quoted AST by construction. Absent ⇒ every value
      is accepted (`cast/1` is total and, for `:strict`, `dump/1` has no
      `:error` arm), which is the `tasks.result` `term()` column.
    * `:encoder` (required) — `{module, function}` producing the stored TEXT.
      `:strict` returns a bare `String.t() | nil` the macro wraps in `{:ok, _}`;
      `:lenient` returns `{:ok, json} | :error` and is spliced into `dump/1`
      verbatim.
    * `:decoder` (required) — `{module, function}` reading a stored TEXT value.
      `:strict` returns the bare decoded term the macro wraps in `{:ok, _}`;
      `:lenient` returns the bare (possibly `nil`) term.
    * `:nil_as` (`:strict` only) — `:null` (default) keeps `nil` ⇄ SQL NULL
      without consulting the Codec; `:delegate` also hands `nil` to the
      encoder/decoder (the `logs` column, whose `nil` wire form is `"[]"`).

  Pure module — no Repo, no GenServer, no I/O.
  """

  defmacro __using__(opts) do
    encoder = Keyword.fetch!(opts, :encoder)
    decoder = Keyword.fetch!(opts, :decoder)
    guard = rehygienize(Keyword.get(opts, :cast_guard), __MODULE__)

    body =
      case Keyword.fetch!(opts, :shape) do
        :strict ->
          strict_body(guard, encoder, decoder, Keyword.get(opts, :nil_as, :null))

        :lenient ->
          lenient_body(guard, encoder, decoder)

        other ->
          raise ArgumentError, "unknown JsonColumn shape: #{inspect(other)}"
      end

    quote do
      @behaviour Ecto.Type

      @impl Ecto.Type
      def type, do: :string

      @impl Ecto.Type
      def equal?(term1, term2), do: term1 == term2

      @impl Ecto.Type
      def embed_as(_format), do: :self

      unquote(body)
    end
  end

  defp strict_body(guard, encoder, decoder, nil_as) do
    quote do
      @impl Ecto.Type
      unquote_splicing(cast_clauses(guard))

      @impl Ecto.Type
      unquote_splicing(dump_clauses(guard, encoder, nil_as))

      @impl Ecto.Type
      unquote_splicing(load_clauses(decoder, nil_as))
    end
  end

  defp lenient_body(guard, encoder, decoder) do
    quote do
      @impl Ecto.Type
      unquote_splicing(cast_clauses(guard))

      @impl Ecto.Type
      def dump(value), do: unquote(call(encoder, quote(do: value)))

      @impl Ecto.Type
      def load(value), do: {:ok, unquote(call(decoder, quote(do: value)))}
    end
  end

  # No guard means a `term()` column that accepts anything (including `nil`,
  # which the total clause already returns).
  defp cast_clauses(nil) do
    [
      quote do
        def cast(value), do: {:ok, value}
      end
    ]
  end

  defp cast_clauses(guard) do
    [
      quote do
        def cast(nil), do: {:ok, nil}
      end,
      quote do
        def cast(value) when unquote(guard), do: {:ok, value}
      end,
      quote do
        def cast(_), do: :error
      end
    ]
  end

  defp dump_clauses(guard, encoder, nil_as) do
    encoded = quote(do: {:ok, unquote(call(encoder, quote(do: value)))})

    value_clauses =
      case guard do
        nil ->
          [
            quote do
              def dump(value), do: unquote(encoded)
            end
          ]

        guard ->
          [
            quote do
              def dump(value) when unquote(guard), do: unquote(encoded)
            end,
            quote do
              def dump(_), do: :error
            end
          ]
      end

    [nil_dump_clause(nil_as, encoder) | value_clauses]
  end

  defp nil_dump_clause(nil_as, encoder) do
    result = nil_clause_body(nil_as, encoder)

    quote do
      def dump(nil), do: unquote(result)
    end
  end

  defp load_clauses(decoder, nil_as) do
    decoded = call(decoder, quote(do: text))

    [
      nil_load_clause(nil_as, decoder),
      quote do
        def load(text) when is_binary(text), do: {:ok, unquote(decoded)}
      end,
      quote do
        def load(_), do: :error
      end
    ]
  end

  defp nil_load_clause(nil_as, decoder) do
    result = nil_clause_body(nil_as, decoder)

    quote do
      def load(nil), do: unquote(result)
    end
  end

  # `:null` keeps `nil` as SQL NULL without consulting the codec; `:delegate`
  # hands `nil` to it (the `logs` column, whose nil wire form is `"[]"`).
  defp nil_clause_body(:null, _codec), do: quote(do: {:ok, nil})

  defp nil_clause_body(:delegate, {_module, _function} = codec) do
    quote(do: {:ok, unquote(call(codec, quote(do: nil)))})
  end

  defp call({module, function}, arg) do
    quote do
      unquote(module).unquote(function)(unquote(arg))
    end
  end

  # A `use` argument is never evaluated, so the guard arrives as AST whose
  # `value` variable carries the CALLER's hygiene context while the generated
  # clause's `value` carries this macro's — rebind it so the guard sees the
  # clause's variable.
  defp rehygienize(nil, _context), do: nil

  defp rehygienize(guard, context) do
    Macro.prewalk(guard, fn
      {:value, meta, var_context} when is_atom(var_context) -> {:value, meta, context}
      other -> other
    end)
  end
end
