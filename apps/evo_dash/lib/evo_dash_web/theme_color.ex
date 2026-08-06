defmodule EvoDashWeb.ThemeColor do
  @moduledoc """
  Computes deterministic accent colors for the dashboard theme.

  Two independent color sources:

  * `accent_color/1` — a deterministic color derived from hashing a project
    name with `:erlang.phash2/2`, mapping the hash to a hue (0-360), then
    converting HSL → hex. The same project always gets the same color while
    different projects get visually distinct colors. Used for the top-bar
    project ring (`--project-ring-accent`).
  * `accent_color_for_mode/1,2` — a task-mode → accent color palette used
    for the objective box (`--project-accent`): create-new → red,
    initialize-existing → blue, evolution → green, resumed evolution →
    lighter green.
  """

  @default_color "#6366f1"
  # Vibrant but not neon: good saturation and lightness for accent use.
  @saturation 70
  @lightness 54

  @doc """
  Returns a hex color string like `"#4f46e5"` for the given project name.

  Returns the default color (`"#{@default_color}"`) for `nil` or empty input.
  """
  @spec accent_color(nil | String.t()) :: String.t()
  def accent_color(nil), do: default_color()
  def accent_color(""), do: default_color()

  def accent_color(name) when is_binary(name) do
    # Hash the name to a hue in the full 0-360 range.
    hue = :erlang.phash2(name, 360)
    hsl_to_hex(hue, @saturation, @lightness)
  end

  @doc """
  Maps a task mode to its accent color.

  The palette mirrors the `[data-mode]` hover colors in `assets/css/app.css`,
  so the objective-box accent matches the launch-button hover ring for the
  same mode:

    * `"genesis_new"` (and any other `"genesis*"` mode) → red `oklch(0.62 0.19 25)`
    * `"genesis_existing"` → blue `oklch(0.62 0.19 255)`
    * `"evolve_simple"` (and any other `"evolve*"` mode) → green `oklch(0.72 0.17 152)`
    * `"evolve*"` with a non-blank resume → lighter green `oklch(0.78 0.16 152)`

  Accepts the mode as a binary or atom (atoms are normalized with
  `Atom.to_string/1`). `nil`, `""`, or any unknown mode falls back to
  `default_color/0` (`"#6366f1"`).

  This arity delegates to `accent_color_for_mode/2` with an empty resume, so
  existing callers keep getting the plain mode color.
  """
  @spec accent_color_for_mode(nil | binary | atom) :: String.t()
  def accent_color_for_mode(mode), do: accent_color_for_mode(mode, "")

  @doc """
  Maps a task mode to its accent color, honoring the resume flag.

  `resume` is a task id binary or `nil`; a non-blank (trimmed) string means
  the task is a resume run. Resume only affects the evolve family (resume is
  an evolve-only concept): a resumed evolve task gets a distinct, lighter
  green of the same family. Genesis-family modes ignore resume entirely.
  """
  @spec accent_color_for_mode(nil | binary | atom, nil | binary) :: String.t()
  def accent_color_for_mode(nil, _resume), do: default_color()
  def accent_color_for_mode("", _resume), do: default_color()

  def accent_color_for_mode(mode, resume) when is_atom(mode) do
    accent_color_for_mode(Atom.to_string(mode), resume)
  end

  def accent_color_for_mode(mode, resume) when is_binary(mode) do
    resume? = is_binary(resume) and String.trim(resume) != ""

    case mode do
      "genesis_new" ->
        "oklch(0.62 0.19 25)"

      "genesis_existing" ->
        "oklch(0.62 0.19 255)"

      "evolve_simple" ->
        evolve_color(resume?)

      _ ->
        cond do
          String.starts_with?(mode, "genesis") -> "oklch(0.62 0.19 25)"
          String.starts_with?(mode, "evolve") -> evolve_color(resume?)
          true -> default_color()
        end
    end
  end

  # Plain evolve → saturated green; resumed evolve → lighter green of the
  # same family so the two states stay distinguishable.
  defp evolve_color(true), do: "oklch(0.78 0.16 152)"
  defp evolve_color(false), do: "oklch(0.72 0.17 152)"

  @doc "Returns the default accent color (indigo-500)."
  @spec default_color :: String.t()
  def default_color, do: @default_color

  # Converts HSL (h: 0-360, s/l: 0-100) to a hex color string.
  defp hsl_to_hex(h, s, l) do
    s_norm = s / 100.0
    l_norm = l / 100.0
    c = (1 - abs(2 * l_norm - 1)) * s_norm
    h_prime = h / 60.0
    x = c * (1 - abs(rem(trunc(h_prime), 2) - 1))

    {r1, g1, b1} =
      cond do
        h_prime < 1 -> {c, x, 0.0}
        h_prime < 2 -> {x, c, 0.0}
        h_prime < 3 -> {0.0, c, x}
        h_prime < 4 -> {0.0, x, c}
        h_prime < 5 -> {x, 0.0, c}
        h_prime < 6 -> {c, 0.0, x}
        true -> {0.0, 0.0, 0.0}
      end

    m = l_norm - c / 2
    r = round((r1 + m) * 255)
    g = round((g1 + m) * 255)
    b = round((b1 + m) * 255)

    "##{pad(r)}#{pad(g)}#{pad(b)}"
  end

  defp pad(n) do
    n
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end
end
