defmodule EvoDashWeb.ThemeColorTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ThemeColor

  # Unit tests for `accent_color_for_mode/1,2` — the task-mode → accent color
  # mapping that mirrors the `[data-mode]` hover ring colors in
  # `assets/css/app.css`. Palette: genesis_new (Create New) → red, genesis_existing
  # (Initialize Existing) → blue, evolve* (Evolution) → green, with a lighter
  # green variant when a resume task id is set (resume is an evolve-only
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
  # name; nil/"" fall back to the default indigo; output is "#rrggbb".
  #
  # NOTE: hsl_to_hex quantizes the hue to one of six 60° sectors (trunc/1 on
  # h_prime), so only ~6 distinct colors are produced — pick test names whose
  # phash2 hues land in different sectors ("alpha" hue 10 vs "gamma" hue 271).
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
  end
end
