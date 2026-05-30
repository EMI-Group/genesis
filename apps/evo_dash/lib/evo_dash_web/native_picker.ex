defmodule EvoDashWeb.NativePicker do
  @moduledoc """
  Provides a native OS directory picker dialog for selecting project paths.

  This only works when the server and browser are on the same machine,
  since the dialog opens on the server side.
  """

  @doc """
  Opens a native OS directory picker dialog and returns the selected path.

  ## Returns

    * `{:ok, path}` — the absolute path of the selected directory
    * `{:error, reason}` — if the picker failed or is unavailable
  """
  def pick_directory do
    case :os.type() do
      {:unix, :darwin} -> pick_macos()
      {:unix, _} -> pick_linux()
      {:win32, _} -> {:error, "Native directory picker not available on Windows"}
    end
  end

  # -- Linux: try zenity first, then kdialog, then fallback --------------------

  defp pick_linux do
    cond do
      System.find_executable("zenity") ->
        pick_with_zenity()

      System.find_executable("kdialog") ->
        pick_with_kdialog()

      true ->
        {:error, "No native directory picker available. Install zenity or kdialog."}
    end
  end

  defp pick_with_zenity do
    case System.cmd("zenity", [
           "--file-selection",
           "--directory",
           "--title=Select Project Directory"
         ]) do
      {path, 0} ->
        {:ok, String.trim(path)}

      {_, 1} ->
        {:error, :cancelled}

      {error, code} ->
        {:error, "zenity exited with code #{code}: #{String.trim(error)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "zenity failed: #{Exception.message(e)}"}
  end

  defp pick_with_kdialog do
    case System.cmd("kdialog", [
           "--getexistingdirectory",
           File.cwd!(),
           "--title",
           "Select Project Directory"
         ]) do
      {path, 0} ->
        {:ok, String.trim(path)}

      {_, 1} ->
        {:error, :cancelled}

      {error, code} ->
        {:error, "kdialog exited with code #{code}: #{String.trim(error)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "kdialog failed: #{Exception.message(e)}"}
  end

  # -- macOS: use osascript (AppleScript) --------------------------------------

  defp pick_macos do
    script = ~s|POSIX path of (choose folder with prompt "Select Project Directory")|

    case System.cmd("osascript", ["-e", script]) do
      {path, 0} ->
        trimmed = String.trim(path)

        if trimmed == "" do
          {:error, :cancelled}
        else
          {:ok, trimmed}
        end

      {_, 1} ->
        {:error, :cancelled}

      {error, code} ->
        {:error, "osascript exited with code #{code}: #{String.trim(error)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "osascript failed: #{Exception.message(e)}"}
  end
end
