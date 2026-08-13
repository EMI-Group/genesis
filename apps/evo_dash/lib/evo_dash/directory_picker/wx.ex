defmodule EvoDash.DirectoryPicker.Wx do
  @moduledoc """
  Injectable seam around the optional `:wx` / `:wxDirDialog` / `:wxFileDialog`
  runtime backend used by `EvoDash.DirectoryPicker`.

  wx ships with OTP but is intentionally NOT a dependency of any umbrella app
  (only loaded in the `genesis`/`genesis_desktop` releases via `wx: :load` in
  the root mix.exs). This module exists so tests can substitute a deterministic
  fake (see `test/support/fake_directory_picker_wx.ex`) without a display.
  Select the backend with:

      config :evo_dash, :directory_picker_wx, MyFakeWx

  Every function delegates to `:wx` / `:wxDirDialog` / `:wxFileDialog`; a fake
  only needs to implement the same arities. All functions are plain delegations
  — the wx failure handling (catch/rescue → `:unavailable`) lives in
  `EvoDash.DirectoryPicker`, not here.
  """

  # wx is not a compile dependency (see moduledoc) — suppress the
  # undefined-module warnings for this optional runtime dependency. Availability
  # is checked at runtime via `available?/0` (`:code.which/1`).
  @compile {:no_warn_undefined, [:wx, :wxDirDialog, :wxFileDialog]}

  @doc """
  True when the native wx backend is compiled into this OTP build.

  `:code.which/1` returns the atom `:non_existing` (never `nil`) when the
  module cannot be found.
  """
  @spec available?() :: boolean()
  def available? do
    :code.which(:wx) != :non_existing
  end

  @doc "Starts the wx server and returns the wxApp object (see `:wx.new/0`)."
  def new, do: :wx.new()

  @doc "Returns the calling process's wx env (see `:wx.get_env/0`)."
  def get_env, do: :wx.get_env()

  @doc "Installs the wx env in the calling process (see `:wx.set_env/1`)."
  def set_env(env), do: :wx.set_env(env)

  @doc "Creates the native directory dialog (see `:wxDirDialog.new/2`)."
  def new_dir_dialog(wx_ref, opts), do: :wxDirDialog.new(wx_ref, opts)

  @doc "Creates the native file dialog (see `:wxFileDialog.new/2`)."
  def new_file_dialog(wx_ref, opts), do: :wxFileDialog.new(wx_ref, opts)

  @doc """
  Shows the modal dialog and returns the result code (see `:wxDirDialog.showModal/1`
  / `:wxFileDialog.showModal/1`).
  """
  def show_modal({:wx_ref, _, :wxDirDialog, _} = dialog), do: :wxDirDialog.showModal(dialog)
  def show_modal({:wx_ref, _, :wxFileDialog, _} = dialog), do: :wxFileDialog.showModal(dialog)

  @doc "Returns the selected path (see `:wxDirDialog.getPath/1` / `:wxFileDialog.getPath/1`)."
  def get_path({:wx_ref, _, :wxDirDialog, _} = dialog), do: :wxDirDialog.getPath(dialog)
  def get_path({:wx_ref, _, :wxFileDialog, _} = dialog), do: :wxFileDialog.getPath(dialog)

  @doc "Destroys the dialog (see `:wxDirDialog.destroy/1` / `:wxFileDialog.destroy/1`)."
  def destroy({:wx_ref, _, :wxDirDialog, _} = dialog), do: :wxDirDialog.destroy(dialog)
  def destroy({:wx_ref, _, :wxFileDialog, _} = dialog), do: :wxFileDialog.destroy(dialog)
end
