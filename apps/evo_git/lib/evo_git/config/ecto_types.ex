defmodule EvoGit.Config.EctoTypes do
  @moduledoc """
  Custom `Ecto.Type` modules reproducing the `EvoGit.Config.Schema` DSL type
  vocabulary.

  Each nested module below is a strict **decision oracle**: its `cast/1`
  accepts exactly the values the hand-written `schema.ex` type checks used to
  accept, with **no coercion** and **no empty-value stripping**. In
  particular, numeric strings (`"3"`) are rejected for integer types
  (Ecto's built-in `:integer`/`:float` casts would coerce them — see the
  Ecto quirk notes in the `EctoValidation` moduledoc), and `""` remains a
  meaningful string value (never treated as absent).

  These types are invoked through Ecto's own type system —
  `Ecto.Type.cast(module, value)` dispatches straight to `module.cast/1`
  (no base-type coercion). `EctoValidation` routes every scalar DSL-type
  pass/fail decision through `EctoTypes.valid?/2` (a `match?({:ok, _},
  cast(type, value))`). Ecto is used strictly as a casting oracle — no
  `Ecto.Changeset` is ever built and the config map is never rebuilt or
  transformed by Ecto (see `EctoValidation`'s moduledoc).

  The 10-atom DSL vocabulary maps onto these modules as follows:

      :pos_integer      → EvoGit.Config.EctoTypes.PosInteger
      :non_neg_integer  → EvoGit.Config.EctoTypes.NonNegInteger
      :integer          → EvoGit.Config.EctoTypes.Integer
      :string           → EvoGit.Config.EctoTypes.String
      :list_of_strings  → EvoGit.Config.EctoTypes.ListOfStrings
      :float            → EvoGit.Config.EctoTypes.Float
      :atom             → EvoGit.Config.EctoTypes.Atom
      :boolean          → EvoGit.Config.EctoTypes.Boolean

  The two composite vocabulary types (`:model_spec`, `:model_profiles`) are
  NOT single-module types: their validation produces multiple, sub-path-aware
  errors (e.g. one per `llm.models` list index) that a single `cast/1`
  cannot express. They are handled by explicit recursive logic in
  `EvoGit.Config.EctoValidation` whose leaf scalar decisions go through the
  modules above.
  """

  @typedoc "The scalar half of the DSL type vocabulary (module-backed)"
  @type scalar_type ::
          :pos_integer
          | :non_neg_integer
          | :integer
          | :string
          | :list_of_strings
          | :float
          | :atom
          | :boolean

  @doc "Returns the custom Ecto.Type module implementing the given scalar DSL type."
  @spec type_for(scalar_type()) :: module()
  # NOTE: the nested `defmodule`s below are declared AFTER this function, so a
  # bare `PosInteger` reference here would NOT be alias-expanded to
  # `EvoGit.Config.EctoTypes.PosInteger` (Elixir only establishes the nested
  # alias for code lexically after the nested `defmodule`). `__MODULE__.X` is
  # expanded at compile time regardless of order — Ecto's runtime module
  # dispatch needs the fully-qualified atom.
  def type_for(:pos_integer), do: __MODULE__.PosInteger
  def type_for(:non_neg_integer), do: __MODULE__.NonNegInteger
  def type_for(:integer), do: __MODULE__.Integer
  def type_for(:string), do: __MODULE__.String
  def type_for(:list_of_strings), do: __MODULE__.ListOfStrings
  def type_for(:float), do: __MODULE__.Float
  def type_for(:atom), do: __MODULE__.Atom
  def type_for(:boolean), do: __MODULE__.Boolean

  @doc """
  Casts `value` through the custom Ecto.Type for the scalar DSL `type`.

  Delegates to `Ecto.Type.cast/2`, which for custom module types calls the
  module's own `cast/1` — so the outcome is the module's strict decision
  (`{:ok, value}` or `:error`), never a coerced value.
  """
  @spec cast(scalar_type(), term()) :: {:ok, term()} | :error
  def cast(type, value) do
    Ecto.Type.cast(type_for(type), value)
  end

  @doc "True when `value` passes the custom Ecto.Type for scalar DSL `type`."
  @spec valid?(scalar_type(), term()) :: boolean()
  def valid?(type, value) do
    match?({:ok, _}, cast(type, value))
  end

  defmodule PosInteger do
    @moduledoc "Strict positive integer Ecto.Type — integers strictly greater than 0."
    use Ecto.Type

    def type, do: :integer

    def cast(value) when is_integer(value) and value > 0, do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_integer(value) and value > 0, do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_integer(value) and value > 0, do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule NonNegInteger do
    @moduledoc "Strict non-negative integer Ecto.Type — integers >= 0 (0 is valid)."
    use Ecto.Type

    def type, do: :integer

    def cast(value) when is_integer(value) and value >= 0, do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_integer(value) and value >= 0, do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_integer(value) and value >= 0, do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Integer do
    @moduledoc "Strict integer Ecto.Type — any integer, no numeric-string coercion."
    use Ecto.Type

    def type, do: :integer

    def cast(value) when is_integer(value), do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_integer(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_integer(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule String do
    @moduledoc "Strict string Ecto.Type — any binary, including \"\" (never stripped to nil)."
    use Ecto.Type

    def type, do: :string

    def cast(value) when is_binary(value), do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_binary(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_binary(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule ListOfStrings do
    @moduledoc "Strict list-of-strings Ecto.Type — a list whose elements are all binaries."
    use Ecto.Type

    def type, do: {:array, :string}

    def cast(value) when is_list(value) do
      if Enum.all?(value, &is_binary/1) do
        {:ok, value}
      else
        :error
      end
    end

    def cast(_value), do: :error

    def load(value) when is_list(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_list(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Float do
    @moduledoc """
    Strict float Ecto.Type — accepts floats OR integers (the DSL `:float` type
    is satisfied by both; no numeric-string coercion, no int→float widening).
    """
    use Ecto.Type

    def type, do: :float

    def cast(value) when is_float(value), do: {:ok, value}
    def cast(value) when is_integer(value), do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_float(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_float(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Atom do
    @moduledoc "Strict atom Ecto.Type — any atom (no string→atom casting)."
    use Ecto.Type

    def type, do: :any

    def cast(value) when is_atom(value), do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_atom(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_atom(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Boolean do
    @moduledoc "Strict boolean Ecto.Type — true or false only."
    use Ecto.Type

    def type, do: :boolean

    def cast(value) when is_boolean(value), do: {:ok, value}
    def cast(_value), do: :error

    def load(value) when is_boolean(value), do: {:ok, value}
    def load(_value), do: :error

    def dump(value) when is_boolean(value), do: {:ok, value}
    def dump(_value), do: :error
  end
end
