defmodule EvoDashWeb.ThemeColorTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ThemeColor

  # Unit tests for `accent_color_for_mode/1,2` — the task-mode → accent color
  # mapping that mirrors the `[data-mode]` hover ring colors in
  # `assets/css/app.css`. Palette: genesis_new (Create New) → red, genesis_existing
  # (Initialize Existing) → blue, evolve* (Evolution) → green, custom_agent
  # (Custom Agent) → violet; evolve* and custom_agent get a lighter variant of
  # their family color when a resume task id is set (resume is an evolve-family
  # concept — genesis ignores it). Any other "genesis*" mode falls back to the
  # family red; any other "evolve*" mode falls back to the family green;
  # nil/""/unknown fall back to the default indigo.
  describe "accent_color_for_mode/1" do
    test "genesis_new maps to red" do
      assert ThemeColor.accent_color_for_mode("genesis_new") == "oklch(0.62 0.19 25)"
    end

    test "genesis_existing maps to blue" do
      assert ThemeColor.accent_color_for_mode("genesis_existing") == "oklch(0.62 0.19 255)"
    end

    test "evolve_simple maps to green" do
      assert ThemeColor.accent_color_for_mode("evolve_simple") == "oklch(0.72 0.17 152)"
    end

    test "custom_agent maps to violet" do
      assert ThemeColor.accent_color_for_mode("custom_agent") == "oklch(0.68 0.17 290)"
    end

    test "other genesis* modes fall back to red" do
      assert ThemeColor.accent_color_for_mode("genesis_fancy") == "oklch(0.62 0.19 25)"
      assert ThemeColor.accent_color_for_mode("genesis") == "oklch(0.62 0.19 25)"
    end

    test "other evolve* modes fall back to green" do
      assert ThemeColor.accent_color_for_mode("evolve_advanced") == "oklch(0.72 0.17 152)"
      assert ThemeColor.accent_color_for_mode("evolve") == "oklch(0.72 0.17 152)"
    end

    test "atom modes are converted via Atom.to_string/1" do
      assert ThemeColor.accent_color_for_mode(:genesis_new) == "oklch(0.62 0.19 25)"
      assert ThemeColor.accent_color_for_mode(:genesis_existing) == "oklch(0.62 0.19 255)"
      assert ThemeColor.accent_color_for_mode(:evolve_simple) == "oklch(0.72 0.17 152)"
      assert ThemeColor.accent_color_for_mode(:evolve_custom) == "oklch(0.72 0.17 152)"
      assert ThemeColor.accent_color_for_mode(:custom_agent) == "oklch(0.68 0.17 290)"
    end

    test "nil, empty string, and unknown modes fall back to the default color" do
      assert ThemeColor.accent_color_for_mode(nil) == ThemeColor.default_color()
      assert ThemeColor.accent_color_for_mode("") == ThemeColor.default_color()
      assert ThemeColor.accent_color_for_mode("unknown_mode") == ThemeColor.default_color()
      assert ThemeColor.default_color() == "#6366f1"
    end
  end

  describe "accent_color_for_mode/2 (resume variant)" do
    test "evolve with nil or blank resume gets the plain evolve green" do
      assert ThemeColor.accent_color_for_mode("evolve_simple", nil) == "oklch(0.72 0.17 152)"
      assert ThemeColor.accent_color_for_mode("evolve_simple", "") == "oklch(0.72 0.17 152)"
      assert ThemeColor.accent_color_for_mode("evolve_simple", "   ") == "oklch(0.72 0.17 152)"
    end

    test "evolve family with a non-blank resume gets the lighter resume green" do
      assert ThemeColor.accent_color_for_mode("evolve_simple", "a1b2c3d4") ==
               "oklch(0.78 0.16 152)"

      assert ThemeColor.accent_color_for_mode("evolve_advanced", "a1b2c3d4") ==
               "oklch(0.78 0.16 152)"
    end

    test "custom_agent with a non-blank resume gets the lighter resume violet" do
      assert ThemeColor.accent_color_for_mode("custom_agent", "a1b2c3d4") ==
               "oklch(0.78 0.16 290)"

      # nil/blank resume keeps the plain custom violet.
      assert ThemeColor.accent_color_for_mode("custom_agent", nil) == "oklch(0.68 0.17 290)"
      assert ThemeColor.accent_color_for_mode("custom_agent", "") == "oklch(0.68 0.17 290)"
      assert ThemeColor.accent_color_for_mode("custom_agent", "   ") == "oklch(0.68 0.17 290)"
    end

    test "genesis modes ignore resume entirely" do
      assert ThemeColor.accent_color_for_mode("genesis_new", "a1b2c3d4") == "oklch(0.62 0.19 25)"

      assert ThemeColor.accent_color_for_mode("genesis_existing", "a1b2c3d4") ==
               "oklch(0.62 0.19 255)"

      assert ThemeColor.accent_color_for_mode("genesis_fancy", "a1b2c3d4") ==
               "oklch(0.62 0.19 25)"
    end

    test "atom modes with resume are normalized via Atom.to_string/1" do
      assert ThemeColor.accent_color_for_mode(:evolve_simple, "a1b2c3d4") ==
               "oklch(0.78 0.16 152)"

      assert ThemeColor.accent_color_for_mode(:evolve_custom, "a1b2c3d4") ==
               "oklch(0.78 0.16 152)"

      assert ThemeColor.accent_color_for_mode(:genesis_new, "a1b2c3d4") == "oklch(0.62 0.19 25)"
    end

    test "nil, empty string, and unknown modes fall back to the default regardless of resume" do
      assert ThemeColor.accent_color_for_mode(nil, "a1b2c3d4") == ThemeColor.default_color()
      assert ThemeColor.accent_color_for_mode("", "a1b2c3d4") == ThemeColor.default_color()

      assert ThemeColor.accent_color_for_mode("unknown_mode", "a1b2c3d4") ==
               ThemeColor.default_color()
    end

    test "accent_color_for_mode/1 delegates to /2 with an empty resume" do
      assert ThemeColor.accent_color_for_mode("evolve_simple") ==
               ThemeColor.accent_color_for_mode("evolve_simple", "")

      assert ThemeColor.accent_color_for_mode("evolve_simple") ==
               ThemeColor.accent_color_for_mode("evolve_simple", nil)
    end
  end

  # Unit tests for `accent_color/1` — the project-name-hash accent used for
  # the top-bar project ring (`--project-ring-accent`). Deterministic per
  # name; nil/"" fall back to the default indigo; output is "#rrggbb". The
  # phash2 hash maps to a continuous 0-360 hue (no sector quantization), so
  # different names land on a full spectrum of distinct colors.
  describe "accent_color/1" do
    test "is deterministic: the same name always yields the same color" do
      assert ThemeColor.accent_color("my-project") == ThemeColor.accent_color("my-project")

      assert ThemeColor.accent_color("another-project") ==
               ThemeColor.accent_color("another-project")
    end

    test "nil and empty string fall back to the default color" do
      assert ThemeColor.accent_color(nil) == ThemeColor.default_color()
      assert ThemeColor.accent_color("") == ThemeColor.default_color()
    end

    test "returns a #rrggbb hex string" do
      color = ThemeColor.accent_color("my-project")
      assert String.starts_with?(color, "#")
      assert Regex.match?(~r/^#[0-9a-f]{6}$/, color)
    end

    test "different project names yield different colors" do
      assert ThemeColor.accent_color("alpha") != ThemeColor.accent_color("gamma")
    end

    test "the palette is spread across the hue range (far more than ~6 distinct colors)" do
      # A representative spread of project names whose phash2 hues span the
      # full 0-360 range. Under the old sector-quantized conversion these
      # collapsed to ~6 colors; the continuous conversion keeps them distinct.
      names = for i <- 0..39, do: "project-#{i}"
      hues = Enum.map(names, &:erlang.phash2(&1, 360))
      assert Enum.min(hues) < 60
      assert Enum.max(hues) >= 300

      distinct_colors =
        names
        |> Enum.map(&ThemeColor.accent_color/1)
        |> MapSet.new()
        |> MapSet.size()

      assert distinct_colors >= 25
    end
  end

  # Direct unit tests for `hsl_to_hex/3` — the continuous HSL→hex conversion
  # behind `accent_color/1`. Because the function takes the raw hue, these
  # pin the fractional (non-quantized) math: adjacent hues stay close but
  # distinct, and colors change continuously across the 60° sector borders.
  describe "hsl_to_hex/3" do
    @sat 70
    @light 54

    test "hues in different sectors yield different colors" do
      # Mid-sector hues of each of the six 60° sectors: red, yellow, green,
      # cyan, blue, magenta families — all mutually distinct.
      hues = [30, 90, 150, 210, 270, 330]
      colors = Enum.map(hues, &ThemeColor.hsl_to_hex(&1, @sat, @light))
      assert length(Enum.uniq(colors)) == 6
    end

    test "sector boundary hues 0/60/120/180/240/300 are valid and mutually distinct" do
      hues = [0, 60, 120, 180, 240, 300]
      colors = Enum.map(hues, &ThemeColor.hsl_to_hex(&1, @sat, @light))

      assert Enum.all?(colors, &Regex.match?(~r/^#[0-9a-f]{6}$/, &1))
      assert length(Enum.uniq(colors)) == 6
    end

    test "adjacent-integer hues map to distinct hexes across the whole hue range" do
      distinct =
        Enum.map(0..359, &ThemeColor.hsl_to_hex(&1, @sat, @light))
        |> MapSet.new()
        |> MapSet.size()

      # A continuous (non-quantized) conversion yields a distinct color for
      # every one of the 360 integer hues; quantization collapsed these to ~6.
      assert distinct == 360
    end

    test "neighbouring hues are close but non-identical" do
      # Parse "#rrggbb" into channel tuples for perceptual-proximity checks.
      parse = fn hex ->
        <<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex
        {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
      end

      for h <- [10, 59, 90, 179, 240, 300] do
        {r1, g1, b1} = parse.(ThemeColor.hsl_to_hex(h, @sat, @light))
        {r2, g2, b2} = parse.(ThemeColor.hsl_to_hex(h + 1, @sat, @light))

        assert ThemeColor.hsl_to_hex(h, @sat, @light) !=
                 ThemeColor.hsl_to_hex(h + 1, @sat, @light)

        # One hue step moves each channel by at most a few units.
        assert abs(r1 - r2) <= 4
        assert abs(g1 - g2) <= 4
        assert abs(b1 - b2) <= 4
      end
    end

    test "colors are continuous across each 60° sector boundary" do
      parse = fn hex ->
        <<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex
        {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
      end

      # Hues just below and just above each 60° boundary must be near-identical
      # (one hue step either way from the boundary), not quantized jumps.
      for boundary <- [60, 120, 180, 240, 300] do
        below = parse.(ThemeColor.hsl_to_hex(boundary - 1, @sat, @light))
        above = parse.(ThemeColor.hsl_to_hex(boundary + 1, @sat, @light))

        {r1, g1, b1} = below
        {r2, g2, b2} = above

        assert ThemeColor.hsl_to_hex(boundary - 1, @sat, @light) !=
                 ThemeColor.hsl_to_hex(boundary + 1, @sat, @light)

        assert abs(r1 - r2) <= 3
        assert abs(g1 - g2) <= 3
        assert abs(b1 - b2) <= 3
      end

      # The 360°/0° wrap: hues just below 360 behave like hues just above 0.
      low = parse.(ThemeColor.hsl_to_hex(359, @sat, @light))
      high = parse.(ThemeColor.hsl_to_hex(1, @sat, @light))

      {r1, g1, b1} = low
      {r2, g2, b2} = high

      assert abs(r1 - r2) <= 3
      assert abs(g1 - g2) <= 3
      assert abs(b1 - b2) <= 3
    end

    test "mid-sector hues sit between their two sector boundaries" do
      # A hue in the middle of a sector must differ from both of the pure
      # boundary hues that flank it (e.g. hue 30 lies between red 0 and
      # yellow 60), proving the in-sector ramp is honored.
      for {mid, lo, hi} <- [
            {30, 0, 60},
            {90, 60, 120},
            {150, 120, 180},
            {210, 180, 240},
            {270, 240, 300},
            {330, 300, 360}
          ] do
        color = ThemeColor.hsl_to_hex(mid, @sat, @light)
        assert color != ThemeColor.hsl_to_hex(lo, @sat, @light)
        assert color != ThemeColor.hsl_to_hex(hi, @sat, @light)
      end
    end

    test "the original alpha/gamma colors are no longer the two quantized wheel colors" do
      # "alpha" hashes to hue 10 (sector 0) and "gamma" to hue 271 (sector 4).
      # Under quantization these were two of the six pure wheel colors; with
      # continuous conversion they are distinct, non-pure, in-between colors.
      alpha = ThemeColor.accent_color("alpha")
      gamma = ThemeColor.accent_color("gamma")

      assert alpha != gamma
      # Hue 10 → mostly-red with a noticeable green component (orange-ish),
      # i.e. NOT a pure primary/secondary wheel color like "#ff0000"-family.
      assert alpha != ThemeColor.hsl_to_hex(0, @sat, @light)
      assert alpha != ThemeColor.hsl_to_hex(60, @sat, @light)
      # Hue 271 → blue-violet, not the pure sector-4 wheel color.
      assert gamma != ThemeColor.hsl_to_hex(240, @sat, @light)
      assert gamma != ThemeColor.hsl_to_hex(300, @sat, @light)
    end
  end
end
