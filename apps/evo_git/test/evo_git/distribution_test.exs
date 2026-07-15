defmodule EvoGit.DistributionTest do
  use ExUnit.Case, async: true

  alias EvoGit.Distribution

  describe "distributed?/0" do
    test "returns a boolean" do
      assert is_boolean(Distribution.distributed?())
    end

    test "returns false for nonode@nohost" do
      # In the test environment the node is typically :nonode@nohost.
      # We can't force a different state without starting distribution,
      # so we just assert the function matches the raw Node check.
      assert Distribution.distributed?() == (node() != :nonode@nohost)
    end
  end

  describe "maybe_enable/0" do
    test "returns :ok when distribution is disabled (default config)" do
      # By default, node.enabled is false, so maybe_enable should be a no-op.
      assert :ok = Distribution.maybe_enable()
    end
  end
end
