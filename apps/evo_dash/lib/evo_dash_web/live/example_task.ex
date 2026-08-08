defmodule EvoDashWeb.ExampleTask do
  @moduledoc """
  Shared "example task" teaching content used by the onboarding surfaces: the
  Welcome page (`EvoDashWeb.WelcomeLive`) and the dashboard's no-project empty
  state (`EvoDashWeb.DashboardLive`).

  Single source of truth for the demo objective text shown to new users — the
  two onboarding surfaces render the same example, so the text lives here
  instead of being duplicated in each LiveView.
  """

  @example_objective """
Build a simulated, web-based Windows desktop environment using a single browser page.

Desktop Environment & Shell
* Custom background / wallpaper.
* Desktop icons and shortcuts.
* Taskbar containing a Start button, open application indicators, and a clock.
* Start menu overlay to launch applications.
* Custom right-click context menu on the desktop.

Window Management
* Draggable title bar for repositioning windows.
* Resizable edges and corners for adjusting window dimensions.
* Control buttons for Minimize, Maximize/Restore, and Close.
* Z-index and focus handling so clicking any window brings it to the front.
* Active state syncing with the taskbar icons.

Starter Fake Apps
* Notepad: A simple text editor.
* File Explorer: A simulated file system viewer.
* Calculator: A basic functional calculator.
* Terminal / Command Prompt: A simple interactive mock CLI.
* Tic-Tac-Toe / Minesweeper: Simple retro browser mini-games.
* Paint / Canvas: A basic drawing app with brush and color choices.
* Media Player: A basic video/audio player with mock controls.
* Settings / Control Panel: An app to customize desktop wallpaper and themes.
* Feel free to add more creative apps.

Iconography & Styling
* Use drop-in CDN icon libraries (e.g., Font Awesome, Bootstrap Icons, or Lucide Icons via `<link>` or `<script>` tags) to render interface and app icons seamlessly without local image assets.

Implementation Constraint: Use only pure `.html` and `.js` files (along with standard `.css`). Do not use Node.js, `npm`, frameworks, or any build tools.
"""

  @doc """
  The example end-goal objective shown to new users (verbatim demo text).
  """
  def example_objective, do: String.trim_trailing(@example_objective)
end
