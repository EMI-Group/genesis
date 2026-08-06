defmodule EvoDashWeb.ThemeColorTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ThemeColor

  # Unit tests for `accent_color_for_mode/1` — the task-mode → accent color
  # mapping that mirrors the `[data-mode]` hover ring colors in
  # `assets/css/app.css` (~lines 1555-1571). The three exact modes map to
  # their oklch color; any other "genesis*"/"evolve*" mode falls back to the
  # family color; nil/""/unknown fall back to the default indigo.
  describe "accent_color_for_mode/1" do
    test "genesis_new maps to blue" do
      assert ThemeColor.accent_color_for_mode("genesis_new") == "oklch(0.62 0.19 255)"
    end

    test "genesis_existing maps to green" do
      assert ThemeColor.accent_color_for_mode("genesis_existing") == "oklch(0.72 0.15 162)"
    end

    test "evolve_simple maps to amber" do
      assert ThemeColor.accent_color_for_mode("evolve_simple") == "oklch(0.8 0.16 80)"
    end

    test "other genesis* modes fall back to blue" do
      assert ThemeColor.accent_color_for_mode("genesis_fancy") == "oklch(0.62 0.19 255)"
      assert ThemeColor.accent_color_for_mode("genesis") == "oklch(0.62 0.19 255)"
    end

    test "other evolve* modes fall back to amber" do
      assert ThemeColor.accent_color_for_mode("evolve_advanced") == "oklch(0.8 0.16 80)"
      assert ThemeColor.accent_color_for_mode("evolve") == "oklch(0.8 0.16 80)"
    end

    test "atom modes are converted via Atom.to_string/1" do
      assert ThemeColor.accent_color_for_mode(:genesis_new) == "oklch(0.62 0.19 255)"
      assert ThemeColor.accent_color_for_mode(:evolve_simple) == "oklch(0.8 0.16 80)"
      assert ThemeColor.accent_color_for_mode(:evolve_custom) == "oklch(0.8 0.16 80)"
    end

    test "nil, empty string, and unknown modes fall back to the default color" do
      assert ThemeColor.accent_color_for_mode(nil) == ThemeColor.default_color()
      assert ThemeColor.accent_color_for_mode("") == ThemeColor.default_color()
      assert ThemeColor.accent_color_for_mode("unknown_mode") == ThemeColor.default_color()
      assert ThemeColor.default_color() == "#6366f1"
    end
  end
end
