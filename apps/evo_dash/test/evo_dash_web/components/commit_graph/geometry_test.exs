defmodule EvoDashWeb.CommitGraphGeometryTest do
  @moduledoc """
  Unit tests for the jog-staggering of concurrent cross-lane edges in
  `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry`.

  Hand-built node/edge maps per the input contract documented in
  `apps/evo_dash/lib/evo_dash_web/components/agents_components/CONTEXT.md`:
  nodes `%{sha, column, row, ...}` + edges `%{from_sha, to_sha, from_column,
  from_row, to_column, to_row, kind}`.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsComponents.CommitGraphView.Geometry

  # 8-char shas, mirroring the renderer test fixtures.
  @sha_p1 "p1000000"
  @sha_b1 "b1000000"
  @sha_c1 "c1000000"
  @sha_d1 "d1000000"
  @sha_e1 "e1000000"

  # The canonical cross-lane route between lane 1 row 1 and lane 0 row 0
  # (fy 66 → ty 22, midpoint jog y 44) — the shape the renderer's existing
  # pins assert byte-for-byte; a lone edge must keep it EXACTLY.
  @canonical "M 48 66 L 48 51 Q 48 44 41 44 L 31 44 Q 24 44 24 37 L 24 22"

  defp node(sha, column, row) do
    %{sha: sha, column: column, row: row, kind: :commit, owner_id: nil}
  end

  defp edge(from_sha, to_sha, from_column, from_row, to_column, to_row, kind) do
    %{
      from_sha: from_sha,
      to_sha: to_sha,
      from_column: from_column,
      from_row: from_row,
      to_column: to_column,
      to_row: to_row,
      kind: kind
    }
  end

  # The base fixture: a two-lane graph. Lane 1 carries b1 (row 1) and c1
  # (row 2); lane 0 carries p1 (row 0). Both b1→p1 and c1→p1 cross the same
  # UNORDERED lane pair {0, 1}.
  defp base_nodes do
    [node(@sha_p1, 0, 0), node(@sha_b1, 1, 1), node(@sha_c1, 1, 2)]
  end

  defp base_pair_edges do
    [edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent), edge(@sha_c1, @sha_p1, 1, 2, 0, 0, :parent)]
  end

  # The jog y of a routed path = the y shared by its two Q control points.
  defp jog_y(d) do
    [q1, q2] = Regex.scan(~r/Q \S+ (\S+) /, d, capture: :all_but_first)
    [jog] = q1
    assert q2 == [jog], "expected both Q corners on the same horizontal: #{d}"
    {y, _} = Float.parse(jog)
    y
  end

  describe "single edge between a lane pair (canonical route)" do
    test "edge_geo/2 keeps the exact canonical midpoint route" do
      positions = Geometry.positions(base_nodes())

      assert Geometry.edge_geo(hd(base_pair_edges()), positions).d == @canonical
    end

    test "edge_geo/3 is pixel-identical to edge_geo/2 for a lone pair edge" do
      positions = Geometry.positions(base_nodes())
      edge = hd(base_pair_edges())

      assert Geometry.edge_geo(edge, positions, [edge]).d ==
               Geometry.edge_geo(edge, positions).d
    end

    test "a group's FIRST edge (in list order) is never staggered" do
      edges = base_pair_edges()

      assert Geometry.edge_geo(hd(edges), Geometry.positions(base_nodes()), edges).d ==
               @canonical
    end
  end

  describe "two concurrent edges sharing a lane pair" do
    test "produce distinct d paths" do
      edges = base_pair_edges()
      positions = Geometry.positions(base_nodes())
      [first, second] = edges

      d_first = Geometry.edge_geo(first, positions, edges).d
      d_second = Geometry.edge_geo(second, positions, edges).d

      assert d_first != d_second
      assert d_first == @canonical
    end

    test "the staggered edge keeps the rounded two-Q-corner shape" do
      edges = base_pair_edges()
      positions = Geometry.positions(base_nodes())
      d = Geometry.edge_geo(Enum.at(edges, 1), positions, edges).d

      assert String.contains?(d, "Q")
      # Never a sharp L..L..L double-corner signature.
      refute Regex.match?(~r/L \S+ \S+ L \S+ \S+ L \S+ \S+/, d)
    end

    test "the staggered jog stays inside the from/to span" do
      edges = base_pair_edges()
      positions = Geometry.positions(base_nodes())
      second = Enum.at(edges, 1)
      %{from: from, to: to, d: d} = Geometry.edge_geo(second, positions, edges)

      jog = jog_y(d)
      assert jog > min(from.y, to.y)
      assert jog < max(from.y, to.y)
    end

    test "placement is deterministic from the edge list order" do
      edges = base_pair_edges()
      positions = Geometry.positions(base_nodes())
      second = Enum.at(edges, 1)

      assert Geometry.edge_geo(second, positions, edges).d ==
               Geometry.edge_geo(second, positions, edges).d

      # Reversing the list flips WHICH edge carries the stagger: `second`
      # becomes the pair's first member → its own canonical (arity-2) route.
      reversed = Enum.reverse(edges)

      assert Geometry.edge_geo(second, positions, reversed).d ==
               Geometry.edge_geo(second, positions).d
    end

    test "four concurrent edges get four distinct routes" do
      nodes = [
        node(@sha_p1, 0, 0),
        node(@sha_b1, 1, 1),
        node(@sha_c1, 1, 2),
        node(@sha_d1, 1, 3),
        node(@sha_e1, 1, 4)
      ]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent),
        edge(@sha_c1, @sha_p1, 1, 2, 0, 0, :parent),
        edge(@sha_d1, @sha_p1, 1, 3, 0, 0, :parent),
        edge(@sha_e1, @sha_p1, 1, 4, 0, 0, :parent)
      ]

      positions = Geometry.positions(nodes)
      ds = Enum.map(edges, &Geometry.edge_geo(&1, positions, edges).d)

      assert length(Enum.uniq(ds)) == 4
      assert Enum.all?(ds, &String.contains?(&1, "Q"))
    end
  end

  describe "span clamping (short span, multiple edges)" do
    test "a staggered jog on a one-row span stays inside the span" do
      # fy = 66, ty = 22 (one row apart): jog zone [30, 58], midpoint 44.
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 1), node(@sha_c1, 1, 1)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent),
        edge(@sha_c1, @sha_p1, 1, 1, 0, 0, :parent)
      ]

      positions = Geometry.positions(nodes)
      ds = Enum.map(edges, &Geometry.edge_geo(&1, positions, edges).d)

      assert length(Enum.uniq(ds)) == 2

      for d <- ds do
        jog = jog_y(d)
        assert jog > 22 and jog < 66
      end
    end

    test "identical-endpoint edges never emit a sharp corner" do
      # Both edges resolve onto the SAME node endpoints (same span); the
      # stagger either finds room or clamps to canonical — never a sharp
      # L..L..L corner, and both stay well-formed routes.
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 0)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 0, 0, 0, :parent),
        edge(@sha_b1, @sha_p1, 1, 0, 0, 0, :merge)
      ]

      positions = Geometry.positions(nodes)
      ds = Enum.map(edges, &Geometry.edge_geo(&1, positions, edges).d)

      assert Enum.all?(ds, &is_binary/1)

      for d <- ds do
        assert String.contains?(d, "Q")
        refute Regex.match?(~r/L \S+ \S+ L \S+ \S+ L \S+ \S+/, d)
      end
    end

    test "a staggered jog never crosses into an interior row's dot band" do
      # Long span: lane 1 row 4 → lane 0 row 0. Interior rows 1..3 have dot
      # centers at y 66, 110, 154; a staggered jog keeps @jog_clear (8) away.
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 4), node(@sha_c1, 1, 4)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 4, 0, 0, :parent),
        edge(@sha_c1, @sha_p1, 1, 4, 0, 0, :parent)
      ]

      positions = Geometry.positions(nodes)
      second = Enum.at(edges, 1)
      d = Geometry.edge_geo(second, positions, edges).d
      jog = jog_y(d)

      for dot_y <- [66, 110, 154] do
        assert abs(jog - dot_y) >= 8
      end

      assert jog > 22 and jog < 198
    end

    test "a virtual landing (to_sha nil) participates in the stagger" do
      # A :merge_back whose to_sha is nil resolves via its own grid pair —
      # the fallback path — and still staggers against a same-lane-pair edge.
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 1), node(@sha_c1, 1, 2)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent),
        %{
          from_sha: @sha_c1,
          to_sha: nil,
          from_column: 1,
          from_row: 2,
          to_column: 0,
          to_row: 0,
          kind: :merge_back
        }
      ]

      positions = Geometry.positions(nodes)
      [first, second] = edges

      d_first = Geometry.edge_geo(first, positions, edges).d
      d_second = Geometry.edge_geo(second, positions, edges).d

      assert d_first == @canonical
      assert d_second != d_first
      assert String.contains?(d_second, "Q")
    end
  end

  describe "non-staggerable shapes" do
    test "same-lane edges keep straight vertical routes" do
      nodes = [node(@sha_b1, 1, 1), node(@sha_c1, 1, 2)]

      edges = [
        edge(@sha_b1, @sha_c1, 1, 1, 1, 2, :parent),
        edge(@sha_b1, @sha_c1, 1, 1, 1, 2, :merge)
      ]

      positions = Geometry.positions(nodes)
      ds = Enum.map(edges, &Geometry.edge_geo(&1, positions, edges).d)

      assert ds == ["M 48 22 L 48 66", "M 48 22 L 48 66"]
    end

    test "a non-list edges arg falls back to the canonical route" do
      positions = Geometry.positions(base_nodes())
      edge = hd(base_pair_edges())

      assert Geometry.edge_geo(edge, positions, :not_a_list).d ==
               Geometry.edge_geo(edge, positions).d
    end
  end
end
