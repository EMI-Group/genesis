defmodule EvoDashWeb.DashboardComponents do
  @moduledoc """
  Re-exporting proxy module. Dashboard components have been split into
  focused sub-modules:

    - `EvoDashWeb.ProjectComponents` — project selector and settings panel
    - `EvoDashWeb.TaskFormComponents` — task form with mode/model selectors
    - `EvoDashWeb.TaskCardComponents` — task cards, result/option rendering
    - `EvoDashWeb.ArchiveComponents` — archive details, tree, and node
  """
  use EvoDashWeb, :html
end
