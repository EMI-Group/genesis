defmodule EvoGit.Sandbox.BehaviourTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.{Behaviour, Linux, MacOS, None}

  describe "behaviour conformance" do
    test "all backends declare @behaviour EvoGit.Sandbox.Behaviour" do
      for module <- [Linux, MacOS, None] do
        behaviours = module.module_info(:attributes)[:behaviour] || []

        assert Behaviour in behaviours,
               "#{inspect(module)} must declare @behaviour #{inspect(Behaviour)}"
      end
    end

    test "all backends export the required callbacks" do
      required_callbacks = Behaviour.behaviour_info(:callbacks)

      for module <- [Linux, MacOS, None] do
        module_callbacks = module.module_info(:functions)

        for {name, arity} <- required_callbacks do
          assert {name, arity} in module_callbacks,
                 "#{inspect(module)} must export #{name}/#{arity} to satisfy the behaviour"
        end
      end
    end

    test "all backends export all optional callbacks (run_with_partial/6)" do
      for module <- [Linux, MacOS, None] do
        functions = module.module_info(:functions)

        assert {:run_with_partial, 6} in functions,
               "#{inspect(module)} must export run_with_partial/6"
      end
    end
  end
end
