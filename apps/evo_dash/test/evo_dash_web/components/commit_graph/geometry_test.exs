defmodule EvoDashWeb.CommitGraphGeometryTest do
  @moduledoc """
  Unit tests for the edge routing of
  `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry`:

    * the jog-staggering of concurrent cross-lane edges (`edge_geo/3` vs the
      canonical `edge_geo/2`);
    * the ROUNDED SHELF a same-row cross-lane edge (`fy == ty`, different lanes)
      routes — never the bare two-point horizontal it used to emit.

  Nodes are `%{sha, column, row, ...}` and edges `%{from_sha, to_sha,
  from_column, from_row, to_column, to_row, kind}`. `positions/1` derives each
  row from the node's INDEX, so node-list order IS the rendered row order;
  edges whose sha is absent from the nodes take their own grid pair instead.
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
  # (fy 66 → ty 22, midpoint jog y 44) — a lone edge (and a lane-pair group's
  # FIRST member) must keep it byte-for-byte.
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

  # N :parent edges from lane 1 rows 1..n onto p1 (lane 0 row 0): they all
  # share the UNORDERED lane pair {0, 1}.
  defp pair_fixture(n) do
    shas = Enum.take([@sha_b1, @sha_c1, @sha_d1, @sha_e1], n)

    nodes =
      [node(@sha_p1, 0, 0) | Enum.map(Enum.with_index(shas, 1), fn {s, r} -> node(s, 1, r) end)]

    edges =
      Enum.map(Enum.with_index(shas, 1), fn {s, r} -> edge(s, @sha_p1, 1, r, 0, 0, :parent) end)

    {nodes, edges}
  end

  # The routed jog y = the y shared by both Q control points.
  defp jog_y(d) do
    [q1, q2] = Regex.scan(~r/Q \S+ (\S+) /, d, capture: :all_but_first)
    [jog] = q1
    assert q2 == [jog], "expected both Q corners on the same horizontal: #{d}"
    {y, _} = Float.parse(jog)
    y
  end

  # The `M x y` start of a path — the dot the route leaves.
  defp path_start(d) do
    [_, x, y] = Regex.run(~r/^M (\S+) (\S+)/, d)
    {String.to_integer(x), String.to_integer(y)}
  end

  # The coordinate a path ENDS on (the last two tokens of `d`, the final `L`
  # endpoint) — the dot the route lands on.
  defp path_end(d) do
    [x, y] = d |> String.split(" ") |> Enum.take(-2)
    {String.to_integer(x), String.to_integer(y)}
  end

  defp assert_rounded(d) do
    assert String.contains?(d, "Q")
    refute Regex.match?(~r/L \S+ \S+ L \S+ \S+ L \S+ \S+/, d), "sharp corner in #{d}"
  end

  defp routes(edges, positions), do: Enum.map(edges, &Geometry.edge_geo(&1, positions, edges).d)

  # `positions/1` derives each row from the node's INDEX, so a row cannot be
  # shared by two RENDERED nodes — this hand-built map states a same-row grid
  # pair directly (the renderer resolves endpoints node-first, and the geometry
  # accepts any `%{sha => %{col:, row:}}` map).
  defp same_row_positions(row) do
    %{@sha_b1 => %{col: 1, row: row}, @sha_p1 => %{col: 0, row: row}}
  end

  describe "canonical route (lone edge, group's first edge, no batch)" do
    test "every call shape keeps the exact canonical midpoint route" do
      {nodes, edges} = pair_fixture(2)
      positions = Geometry.positions(nodes)
      [edge | _] = edges

      assert Geometry.edge_geo(edge, positions).d == @canonical
      assert Geometry.edge_geo(edge, positions, [edge]).d == @canonical
      assert Geometry.edge_geo(edge, positions, edges).d == @canonical
      # A non-list batch falls back to the per-edge (canonical) route.
      assert Geometry.edge_geo(edge, positions, :not_a_list).d == @canonical
    end
  end

  describe "concurrent edges sharing a lane pair" do
    test "n concurrent edges get n distinct routes, all rounded, the first canonical" do
      for n <- [1, 2, 4] do
        {nodes, edges} = pair_fixture(n)
        ds = routes(edges, Geometry.positions(nodes))

        assert length(Enum.uniq(ds)) == n
        assert hd(ds) == @canonical
        Enum.each(ds, &assert_rounded/1)
      end
    end

    test "the staggered jog stays strictly inside its own from/to span" do
      # The second fixture is a genuine ONE-ROW span: c1 is absent from the
      # nodes, so its edge falls back to its own grid pair (also row 1).
      one_row = [
        node(@sha_p1, 0, 0),
        node(@sha_b1, 1, 1)
      ]

      one_row_edges = [
        edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent),
        edge(@sha_c1, @sha_p1, 1, 1, 0, 0, :parent)
      ]

      for {nodes, edges} <- [pair_fixture(2), {one_row, one_row_edges}] do
        positions = Geometry.positions(nodes)
        assert length(Enum.uniq(routes(edges, positions))) == 2

        for e <- edges do
          %{from: from, to: to, d: d} = Geometry.edge_geo(e, positions, edges)
          jog = jog_y(d)
          assert jog > min(from.y, to.y) and jog < max(from.y, to.y)
        end
      end
    end

    test "placement is deterministic from the edge list order" do
      {nodes, edges} = pair_fixture(2)
      positions = Geometry.positions(nodes)
      second = Enum.at(edges, 1)
      staggered = Geometry.edge_geo(second, positions, edges).d

      assert staggered == Geometry.edge_geo(second, positions, edges).d
      assert staggered != Geometry.edge_geo(second, positions).d
      # Reversed, `second` becomes the group's first member → canonical again.
      assert Geometry.edge_geo(second, positions, Enum.reverse(edges)).d ==
               Geometry.edge_geo(second, positions).d
    end

    test "a virtual landing (to_sha nil) participates in the stagger" do
      # A :merge_back whose to_sha is nil resolves via its own grid pair —
      # the fallback path — and still staggers against a same-lane-pair edge.
      {nodes, [first | _]} = pair_fixture(1)
      edges = [first, edge(@sha_c1, nil, 1, 2, 0, 0, :merge_back)]
      [d_first, d_second] = routes(edges, Geometry.positions(nodes))

      assert d_first == @canonical
      assert d_second != d_first
      assert_rounded(d_second)
    end

    test "a staggered jog never enters an interior row's dot band" do
      # lane 1 row 4 → lane 0 row 0: interior rows 1..3 have dots at 66, 110,
      # 154; a staggered jog keeps @jog_clear (8) clear of each (and lands on
      # 102 here — exactly 8 from the row-2 dot).
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 1)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 1, 0, 0, :parent),
        edge(@sha_c1, @sha_p1, 1, 4, 0, 0, :parent)
      ]

      [d_first, d_second] = routes(edges, Geometry.positions(nodes))
      jog = jog_y(d_second)

      assert d_first == @canonical
      for dot_y <- [66, 110, 154], do: assert(abs(jog - dot_y) >= 8, "dot row at #{dot_y}")
      assert jog > 22 and jog < 198
    end
  end

  describe "same-row cross-lane edges (rounded shelf)" do
    test "the route leaves the source dot, crosses BELOW the row and ends on the target dot" do
      positions = same_row_positions(2)
      edge = edge(@sha_b1, @sha_p1, 1, 2, 0, 2, :parent)

      assert %{d: d} = Geometry.edge_geo(edge, positions)

      # NEVER the bare two-point horizontal this used to emit — it ran straight
      # through every dot sitting between the two lanes on that row.
      refute d == "M 48 110 L 24 110"
      assert String.contains?(d, "Q")
      assert_rounded(d)

      # It STARTS on the source dot (lane 1 → x 48, row 2 → y 110) and ENDS
      # exactly on the target dot (lane 0 → x 24, the row's own y 110).
      assert path_start(d) == {48, 110}
      assert path_end(d) == {24, 110}

      # The shelf sits deterministically BELOW the row (never flipping above),
      # so both Q corners share y = dot_y(row) + 2 * @bend_r = 110 + 14 = 124.
      assert jog_y(d) == 124
      assert d == "M 48 110 L 48 117 Q 48 124 41 124 L 31 124 Q 24 124 24 117 L 24 110"
    end

    test "the shelf is mirrored for a rightward same-row edge" do
      positions = same_row_positions(1)
      edge = edge(@sha_p1, @sha_b1, 0, 1, 1, 1, :parent)

      assert %{d: d} = Geometry.edge_geo(edge, positions)

      assert path_start(d) == {24, 66}
      assert path_end(d) == {48, 66}
      assert jog_y(d) == 66 + 2 * 7

      assert d == "M 24 66 L 24 73 Q 24 80 31 80 L 41 80 Q 48 80 48 73 L 48 66"
    end

    test "a same-row shelf is never staggered, even as a lane pair's later member" do
      positions = same_row_positions(2)

      first = edge(@sha_b1, @sha_p1, 1, 2, 0, 2, :parent)
      second = edge(@sha_b1, @sha_p1, 1, 2, 0, 2, :merge)

      # A same-row cross-lane edge has no vertical span to stagger inside, so
      # the batch-aware form returns exactly the canonical shelf for BOTH
      # members (and for a lone edge).
      canonical = Geometry.edge_geo(first, positions).d
      assert canonical == Geometry.edge_geo(first, positions, [first, second]).d
      assert Geometry.edge_geo(second, positions, [first, second]).d == canonical
      assert Geometry.edge_geo(second, positions).d == canonical
    end

    test "a normal cross-lane pair still staggers exactly as before" do
      # The shelf change is confined to `fy == ty`: a different-row lone edge
      # stays pixel-identical to `edge_geo/2`, and a pair's second member still
      # walks off the midpoint.
      {nodes, [first, second]} = pair_fixture(2)
      positions = Geometry.positions(nodes)

      assert Geometry.edge_geo(first, positions, [first]).d == @canonical
      assert Geometry.edge_geo(first, positions).d == @canonical

      assert Geometry.edge_geo(second, positions, [first, second]).d !=
               Geometry.edge_geo(second, positions).d
    end
  end

  describe "non-staggerable shapes" do
    test "same-lane edges keep straight vertical routes" do
      nodes = [node(@sha_b1, 1, 1), node(@sha_c1, 1, 2)]

      edges = [
        edge(@sha_b1, @sha_c1, 1, 1, 1, 2, :parent),
        edge(@sha_b1, @sha_c1, 1, 1, 1, 2, :merge)
      ]

      assert routes(edges, Geometry.positions(nodes)) == ["M 48 22 L 48 66", "M 48 22 L 48 66"]
    end

    test "edges resolving onto the SAME endpoints never emit a sharp corner" do
      # A SAME-ROW cross-lane pair: both members route the identical rounded
      # SHELF (there is no vertical span to stagger inside) — never a sharp
      # L..L..L corner, and both stay well-formed rounded routes.
      nodes = [node(@sha_p1, 0, 0), node(@sha_b1, 1, 0)]

      edges = [
        edge(@sha_b1, @sha_p1, 1, 0, 0, 0, :parent),
        edge(@sha_b1, @sha_p1, 1, 0, 0, 0, :merge)
      ]

      ds = routes(edges, Geometry.positions(nodes))

      assert Enum.all?(ds, &is_binary/1)
      Enum.each(ds, &assert_rounded/1)
    end
  end
end
