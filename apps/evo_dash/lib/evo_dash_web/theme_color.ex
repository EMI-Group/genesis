defmodule EvoDashWeb.ThemeColor do
  @moduledoc """
  Computes a deterministic theme accent color from a project name hash.

  The color is derived by hashing the project name with `:erlang.phash2/2`,
  mapping the hash to a hue (0-360), then converting HSL → hex. This ensures
  the same project always gets the same color while different projects get
  visually distinct colors.
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
