defmodule EvoGit.Config.EctoValidationTest do
  @moduledoc """
  Focused tests for the Ecto-backed config validation engine:
  `EvoGit.Config.EctoTypes` (strict custom `Ecto.Type` modules for the scalar
  DSL vocabulary) and `EvoGit.Config.EctoValidation` (the per-key error
  collector beneath `EvoGit.Config.Schema.validate/1`).

  The neighboring `schema_test.exs` pins the historical end-to-end contract of
  `Schema.validate/1`; this file drills into the Ecto layer itself plus the
  guarantees the refactor must preserve: strict no-coercion casting,
  nil ≡ absent, type-then-rule error ordering, byte-exact messages/rules/
  key_paths, unknown-key survival, integer-indexed profile recursion with
  PeakHours-delegated peak fields, crash resilience, and public-API stability.
  All modules under test are pure (no ETS, processes, or shared-state
  mutation — the timezone-database lookup is a read-only app-env default), so
  this file mirrors `schema_test.exs`'s `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Config.EctoTypes
  alias EvoGit.Config.EctoValidation
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.ValidationError

  @accent_palette ~w(blue teal green yellow orange red pink purple brown slate)

  describe "EctoTypes custom-type strictness" do
    test "numeric strings are rejected for every integer type (no coercion)" do
      for type <- [:pos_integer, :non_neg_integer, :integer] do
        assert EctoTypes.cast(type, "3") == :error
        assert EctoTypes.cast(type, "0") == :error
      end

      # genuine integers still pass
      assert EctoTypes.cast(:pos_integer, 3) == {:ok, 3}
      assert EctoTypes.cast(:non_neg_integer, 0) == {:ok, 0}
      assert EctoTypes.cast(:integer, -5) == {:ok, -5}
    end

    test "integers satisfy the :float type; numeric strings do not" do
      assert EctoTypes.cast(:float, 3) == {:ok, 3}
      assert EctoTypes.cast(:float, 3.5) == {:ok, 3.5}
      assert EctoTypes.cast(:float, 0) == {:ok, 0}
      assert EctoTypes.cast(:float, "3") == :error
    end

    test "empty string is a valid :string (never stripped to absent)" do
      assert EctoTypes.cast(:string, "") == {:ok, ""}
      assert EctoTypes.cast(:string, "auto") == {:ok, "auto"}
      assert EctoTypes.cast(:string, :auto) == :error
      assert EctoTypes.cast(:string, 42) == :error
    end

    test ":atom accepts only atoms (booleans are atoms in Elixir)" do
      assert EctoTypes.cast(:atom, :auto) == {:ok, :auto}
      assert EctoTypes.cast(:atom, :anything) == {:ok, :anything}
      # true/false ARE atoms in Elixir, so they pass the :atom type
      assert EctoTypes.cast(:atom, true) == {:ok, true}
      assert EctoTypes.cast(:atom, false) == {:ok, false}
      assert EctoTypes.cast(:atom, "auto") == :error
      assert EctoTypes.cast(:atom, 1) == :error
    end

    test ":boolean accepts only true and false" do
      assert EctoTypes.cast(:boolean, true) == {:ok, true}
      assert EctoTypes.cast(:boolean, false) == {:ok, false}
      assert EctoTypes.cast(:boolean, 1) == :error
      assert EctoTypes.cast(:boolean, "true") == :error
      assert EctoTypes.cast(:boolean, :yes) == :error
    end

    test ":list_of_strings rejects mixed lists and non-lists" do
      assert EctoTypes.cast(:list_of_strings, ["/a", "/b"]) == {:ok, ["/a", "/b"]}
      assert EctoTypes.cast(:list_of_strings, []) == {:ok, []}
      assert EctoTypes.cast(:list_of_strings, ["/a", 1]) == :error
      assert EctoTypes.cast(:list_of_strings, ["/a", :sym]) == :error
      assert EctoTypes.cast(:list_of_strings, "/single/string") == :error
      assert EctoTypes.cast(:list_of_strings, 42) == :error
    end
  end

  describe "Ecto.Type nil handling (EctoTypes)" do
    test "Ecto.Type.cast of nil returns {:ok, nil} for a custom type (nil convention)" do
      # Pinned empirical outcome: Ecto intercepts nil before dispatching to the
      # module's own cast/1, so nil never reaches the strict guards.
      assert Ecto.Type.cast(EctoTypes.type_for(:pos_integer), nil) == {:ok, nil}
      assert EctoTypes.cast(:pos_integer, nil) == {:ok, nil}
      assert EctoTypes.cast(:string, nil) == {:ok, nil}
      assert EctoTypes.cast(:list_of_strings, nil) == {:ok, nil}
      # valid?/2 therefore never flags nil — nil ≡ absent at the type level.
      assert EctoTypes.valid?(:pos_integer, nil)
      assert EctoTypes.valid?(:atom, nil)
    end
  end

  describe "nil ≡ absent in Schema.validate/1" do
    test "nil values pass for representative keys across categories" do
      config = %{
        scheduler: %{default_llm_max_concurrency: nil, max_tool_concurrency: nil},
        llm: %{model: nil, temperature: nil, max_tokens: nil, models: nil},
        sandbox: %{mode: nil, write_paths: nil, backend: nil},
        user: %{github_username: nil},
        tools: %{shell: nil},
        truncation: %{tool_output_max_bytes: nil},
        appearance: %{accent_color: nil},
        data: %{dir: nil}
      }

      assert {:ok, ^config} = Schema.validate(config)
    end

    test "absent keys pass — an empty map and sparsely populated maps validate" do
      assert {:ok, %{}} = Schema.validate(%{})
      assert {:ok, %{llm: %{model: nil}}} = Schema.validate(%{llm: %{model: nil}})

      assert {:ok, %{sandbox: %{write_paths: nil}}} =
               Schema.validate(%{sandbox: %{write_paths: nil}})

      # Schema.defaults() itself (nil defaults for optional keys) is valid.
      assert {:ok, _} = Schema.validate(Schema.defaults())
    end
  end

  describe "type + rule error ordering" do
    test "default_llm_max_concurrency = 0 yields exactly two errors, type first, rule second" do
      assert {:error, [type_err, rule_err]} =
               Schema.validate(%{scheduler: %{default_llm_max_concurrency: 0}})

      assert type_err.key_path == [:scheduler, :default_llm_max_concurrency]
      assert type_err.rule == :pos_integer
      assert type_err.value == 0
      assert type_err.message == "must be a positive integer (greater than 0), got 0"

      assert rule_err.key_path == [:scheduler, :default_llm_max_concurrency]
      assert rule_err.rule == {:min, 1}
      assert rule_err.value == 0
      assert rule_err.message == "must be >= 1, got 0"
    end

    test "errors_for/4 produces the same type-then-rule ordering at the engine level" do
      errors =
        EctoValidation.errors_for(
          [:scheduler, :default_llm_max_concurrency],
          :pos_integer,
          [min: 1],
          0
        )

      assert [%ValidationError{rule: :pos_integer}, %ValidationError{rule: {:min, 1}}] = errors
    end
  end

  describe "error adapter parity edges" do
    test "[:sandbox, :mode] bad atom surfaces an {:in, [...]} rule error" do
      assert {:error, [error]} = Schema.validate(%{sandbox: %{mode: :bogus}})

      assert error.key_path == [:sandbox, :mode]
      assert error.rule == {:in, [:auto, :enabled, :disabled]}
      assert error.value == :bogus
      assert error.message == "must be one of [:auto, :enabled, :disabled], got :bogus"
    end

    test "[:sandbox, :mode] raw non-atom string surfaces a type error first, then the in rule" do
      # A bad enum STRING that survived Config.resolve's atomization reaches
      # Schema.validate as a string: the :atom type check fails first, then the
      # in-rule check (whitelist holds atoms).
      assert {:error, [type_err, rule_err]} = Schema.validate(%{sandbox: %{mode: "bogus"}})

      assert type_err.key_path == [:sandbox, :mode]
      assert type_err.rule == :atom
      assert type_err.value == "bogus"
      assert type_err.message == "must be an atom, got \"bogus\""

      assert rule_err.key_path == [:sandbox, :mode]
      assert rule_err.rule == {:in, [:auto, :enabled, :disabled]}
    end

    test "[:sandbox, :write_paths] non-list non-string is a :list_of_strings type error" do
      assert {:error, [error]} = Schema.validate(%{sandbox: %{write_paths: 42}})

      assert error.key_path == [:sandbox, :write_paths]
      assert error.rule == :list_of_strings
      assert error.value == 42
      assert error.message == "must be a list of strings, got 42"
    end

    test "[:sandbox, :write_paths] a bare string is also a :list_of_strings type error" do
      assert {:error, [error]} = Schema.validate(%{sandbox: %{write_paths: "/single/string"}})

      assert error.key_path == [:sandbox, :write_paths]
      assert error.rule == :list_of_strings
      assert error.value == "/single/string"
    end

    test "[:appearance, :accent_color] non-palette STRING is an in-rule error (string enum)" do
      # The accent_color schema entry is type: :string with a string-typed
      # `in:` palette — atomization does NOT apply to it (unlike sandbox.mode),
      # so "neon" passes the type check and fails the in-rule check.
      assert {:error, [error]} = Schema.validate(%{appearance: %{accent_color: "neon"}})

      assert error.key_path == [:appearance, :accent_color]
      assert error.rule == {:in, @accent_palette}
      assert error.value == "neon"

      assert error.message ==
               "must be one of #{inspect(@accent_palette)}, got \"neon\""
    end

    test "profile-level :concurrency is NOT validated — a numeric string passes" do
      # Empirical pin: per-profile generation params (concurrency, temperature,
      # ...) have no schema descriptors; only id/model/provider_options and the
      # peak fields are validated inside a profile. A string concurrency is
      # therefore accepted (this is the current engine behavior).
      config = %{llm: %{models: [%{id: "x", model: "a:b", concurrency: "3"}]}}
      assert {:ok, ^config} = Schema.validate(config)
    end

    test "peak_concurrency numeric string IS a type error at the indexed path (no coercion)" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{models: [%{id: "x", model: "a:b", peak_concurrency: "3"}]}
               })

      assert error.key_path == [:llm, :models, 0, :peak_concurrency]
      assert error.rule == :integer
      assert error.value == "3"
      assert error.message == "peak_concurrency must be a non-negative integer, got \"3\""
    end
  end

  describe "unknown keys survive validation" do
    test "unknown sections and keys are never rejected and the map passes through unchanged" do
      config = %{
        llm: %{model: "a:b"},
        totally_unknown_section: %{x: 1},
        unknown_key: 2
      }

      assert {:ok, ^config} = Schema.validate(config)
    end
  end

  describe "model profile recursion + integer-indexed key paths" do
    test "missing id surfaces at [:llm, :models, 0, :id]" do
      assert {:error, [error]} = Schema.validate(%{llm: %{models: [%{model: "a:b"}]}})

      assert error.key_path == [:llm, :models, 0, :id]
      assert error.rule == :string
      assert error.message == "profile must have a non-empty 'id' string, got nil"
    end

    test "missing model surfaces at [:llm, :models, 0, :model]" do
      assert {:error, [error]} = Schema.validate(%{llm: %{models: [%{id: "x"}]}})

      assert error.key_path == [:llm, :models, 0, :model]
      assert error.rule == :model_spec
      assert error.message == "profile must have a 'model' field"
    end

    test "invalid timezone surfaces at [:llm, :models, 0, :timezone] (PeakHours-delegated)" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{models: [%{id: "x", model: "a:b", timezone: "Not/AZone"}]}
               })

      assert error.key_path == [:llm, :models, 0, :timezone]
      assert error.rule == :timezone
      assert error.value == "Not/AZone"
      assert error.message =~ "invalid timezone:"
    end

    test "invalid off_peak_days surfaces at [:llm, :models, 0, :off_peak_days]" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{models: [%{id: "x", model: "a:b", off_peak_days: ["noday"]}]}
               })

      assert error.key_path == [:llm, :models, 0, :off_peak_days]
      assert error.rule == :off_peak_days
      assert error.value == "noday"
      assert error.message =~ "off_peak_days must be a list of day names"
    end

    test "peak_hours that is not a list surfaces at [:llm, :models, 0, :peak_hours]" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{models: [%{id: "x", model: "a:b", peak_hours: "09:00-12:00"}]}
               })

      assert error.key_path == [:llm, :models, 0, :peak_hours]
      assert error.rule == :peak_hours
      assert error.message =~ "peak_hours must be a list of"
    end

    test "a peak_hours window with a bad time format gets an indexed sub-path" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{
                   models: [
                     %{id: "x", model: "a:b", peak_hours: [%{start: "25:00", end: "26:00"}]}
                   ]
                 }
               })

      assert error.key_path == [:llm, :models, 0, :peak_hours, 0]
      assert error.rule == :peak_hours
      assert error.value == %{start: "25:00", end: "26:00"}
      assert error.message =~ "peak_hours window has invalid"
    end

    test "a peak_hours window with invalid days gets the :days rule at the window-days path" do
      assert {:error, [error]} =
               Schema.validate(%{
                 llm: %{
                   models: [
                     %{
                       id: "x",
                       model: "a:b",
                       peak_hours: [%{start: "09:00", end: "12:00", days: ["funday"]}]
                     }
                   ]
                 }
               })

      assert error.key_path == [:llm, :models, 0, :peak_hours, 0, :days]
      assert error.rule == :days
      assert error.value == ["funday"]
      assert error.message =~ "peak_hours window has invalid days"
    end

    test "a fully valid peak-hours profile passes (atom- and string-keyed)" do
      atom_keyed = %{
        id: "glm",
        model: "zai:glm-5",
        concurrency: 4,
        peak_concurrency: 0,
        peak_hours: [
          %{start: "09:00", end: "12:00", days: ["mon", "wed"]},
          %{start: "22:00", end: "06:00"}
        ],
        timezone: "Asia/Shanghai",
        off_peak_days: ["weekends"]
      }

      assert {:ok, _} = Schema.validate(%{llm: %{models: [atom_keyed]}})

      string_keyed = %{
        "id" => "glm",
        "model" => "zai:glm-5",
        "peak_concurrency" => 2,
        "peak_hours" => [%{"start" => "09:00", "end" => "12:00", "days" => ["weekdays"]}],
        "timezone" => "America/New_York",
        "off_peak_days" => ["Mon"]
      }

      assert {:ok, _} = Schema.validate(%{llm: %{models: [string_keyed]}})
    end
  end

  describe "crash resilience on garbage nested structures" do
    test "validate/1 never raises and returns {:ok, _} or {:error, [ValidationError.t()]}" do
      garbage = %{
        scheduler: "string",
        llm: %{models: "notalist"},
        tools: 42,
        sandbox: %{resources: %{cpu_quota: :atom}}
      }

      result = Schema.validate(garbage)

      assert match?({:ok, _}, result) or match?({:error, list} when is_list(list), result)

      case result do
        {:error, errors} ->
          assert length(errors) == 2

          assert Enum.any?(
                   errors,
                   &(&1.key_path == [:llm, :models] and &1.rule == :model_profiles)
                 )

          assert Enum.any?(
                   errors,
                   &(&1.key_path == [:sandbox, :resources, :cpu_quota] and &1.rule == :string)
                 )

          assert Enum.all?(errors, &match?(%ValidationError{}, &1))

        {:ok, _} ->
          flunk("expected garbage config to produce validation errors")
      end
    end

    test "a category holding a non-map (plain string) is skipped without crashing" do
      # safe_get_in returns nil for non-traversable intermediates, so the
      # scheduler subtree contributes no errors at all.
      assert {:ok, %{scheduler: "string"}} = Schema.validate(%{scheduler: "string"})
    end

    test "a bare list profile entry is reported as a non-map profile at the indexed path" do
      assert {:error, [error]} = Schema.validate(%{llm: %{models: ["not-a-map"]}})

      assert error.key_path == [:llm, :models, 0]
      assert error.rule == :model_profiles
      assert error.message == "profile must be a map/table, got \"not-a-map\""
    end
  end

  describe "public API stability" do
    test "type_for/1 returns the custom module for all 8 scalar types" do
      assert EctoTypes.type_for(:pos_integer) == EctoTypes.PosInteger
      assert EctoTypes.type_for(:non_neg_integer) == EctoTypes.NonNegInteger
      assert EctoTypes.type_for(:integer) == EctoTypes.Integer
      assert EctoTypes.type_for(:string) == EctoTypes.String
      assert EctoTypes.type_for(:list_of_strings) == EctoTypes.ListOfStrings
      assert EctoTypes.type_for(:float) == EctoTypes.Float
      assert EctoTypes.type_for(:atom) == EctoTypes.Atom
      assert EctoTypes.type_for(:boolean) == EctoTypes.Boolean
    end

    test "cast/2 and valid?/2 dispatch consistently through the custom types" do
      assert EctoTypes.valid?(:pos_integer, 1)
      refute EctoTypes.valid?(:pos_integer, 0)
      refute EctoTypes.valid?(:pos_integer, "1")
      assert EctoTypes.valid?(:non_neg_integer, 0)
      refute EctoTypes.valid?(:non_neg_integer, -1)
      assert EctoTypes.valid?(:integer, -10)
      assert EctoTypes.valid?(:string, "")
      refute EctoTypes.valid?(:string, 1)
      assert EctoTypes.valid?(:list_of_strings, [])
      refute EctoTypes.valid?(:list_of_strings, [1])
      assert EctoTypes.valid?(:float, 2)
      assert EctoTypes.valid?(:float, 2.5)
      refute EctoTypes.valid?(:float, "2")
      assert EctoTypes.valid?(:atom, :anything)
      refute EctoTypes.valid?(:atom, "anything")
      assert EctoTypes.valid?(:boolean, false)
      refute EctoTypes.valid?(:boolean, 1)
      refute EctoTypes.valid?(:boolean, "true")
      refute EctoTypes.valid?(:boolean, :yes)
    end

    test "ValidationError struct carries exactly key_path/message/value/rule" do
      assert %ValidationError{} |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:key_path, :message, :rule, :value]
    end
  end
end
